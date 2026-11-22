"""A week of outfits, planned in one go.

Two steps on purpose: `preview` proposes and writes nothing, `apply` commits
what the user accepted. Anything else means a tap on "plan my week" silently
rewrites an agenda somebody had already filled in.

No image is generated here. A plan is a list of clothes per day — the garments'
cut-outs are what the screen shows — and rendering one costs a paid API call
that nobody asked for seven of. A planned day carries an outfit row with no
render, so pressing "generate" on the day it matters uses the ordinary
regenerate path and turns it into a normal outfit.
"""
import json
import logging
import random
from datetime import date, timedelta
from typing import Dict, List, Optional

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel

import weather as weather_mod
from auth import get_current_user
from db import display_path, front_images, get_conn
from generator import (
    ALGOS,
    AVOID_EXEMPT_ROLES,
    GenerateRequest,
    layer_sorted,
    role_of,
    select as algo_select,
    theme_value_of,
)
from images import public_url_for
from routes_thumbs import thumb_url_for

router = APIRouter(prefix="/agenda/plan", tags=["agenda"])
log = logging.getLogger(__name__)

MAX_DAYS = 14
# Longest a garment or an outfit may be held over consecutive days.
MAX_HOLD = 7
SOURCES = ("algo", "outfits", "mix")


class PlanAlgo(BaseModel):
    """One algorithm the week may draw on, with its own argument when it needs
    one (pick-by-colour/brand/tag). A week is a list of these, not a single
    algorithm: seven days of "same brand" is the complaint this answers."""
    algo: str = "random"
    color: str = ""
    brand: str = ""
    tag: str = ""


class PlanRequest(BaseModel):
    start_day: str = ""            # 'YYYY-MM-DD'; empty = today
    days: int = 7
    # The mix to draw from, one entry per algorithm the user ticked. Empty falls
    # back to ``algo`` so an older client keeps working.
    algos: List[PlanAlgo] = []
    algo: str = "random"
    min_score: int = 0
    fill_gaps: bool = True
    weather: str = "auto"          # 'auto' | 'any' | 'hot' | 'cold'
    categories: List[str] = []     # explicit clothing types, as in the sheet
    # Repeat the same theme across days (same brand all week) instead of asking
    # each day for a different one. Off by default — that was the report.
    allow_repeat_theme: bool = False
    # Days the user pinned, with what is on them. They come back untouched, and
    # their garments still count against the repeats — a locked Monday t-shirt
    # must not reappear on Thursday.
    keep: Dict[str, List[int]] = {}
    # Days pinned to one of the user's existing outfits (day -> outfit id).
    keep_outfits: Dict[str, int] = {}
    # Where a day's outfit comes from: drawn by the algorithms, taken from
    # outfits the user already made, or alternating between the two.
    source: str = "algo"
    favorites_only: bool = False   # with source outfits/mix: favourites only
    # How many consecutive days each pick is worn. ``hold_by_category``
    # overrides it per clothing type ("jogging 3 days, t-shirt 1 day"); it
    # applies to drawn days — an existing outfit is held as a whole.
    hold_days: int = 1
    hold_by_category: Dict[str, int] = {}


class ApplyRequest(BaseModel):
    days: Dict[str, List[int]]     # day -> cloth ids, as shown to the user
    replace: bool = False          # overwrite days that already have a plan
    # day -> existing outfit id: the agenda points at that outfit (and its
    # render) instead of a new clothes-only row.
    outfits: Dict[str, int] = {}


def _days(start_day: str, count: int) -> List[str]:
    try:
        start = date.fromisoformat(start_day) if start_day else date.today()
    except ValueError as e:
        raise HTTPException(status.HTTP_400_BAD_REQUEST,
                            f"'{start_day}' is not a date (YYYY-MM-DD)") from e
    count = max(1, min(int(count or 7), MAX_DAYS))
    return [(start + timedelta(days=i)).isoformat() for i in range(count)]


def _cloth_cards(conn, user_id: int, cloth_ids: List[int]) -> List[dict]:
    """Just enough per garment for a plan card: a name and a picture."""
    if not cloth_ids:
        return []
    ph = ",".join("?" * len(cloth_ids))
    rows = conn.execute(
        f"SELECT id, name, brand, category FROM clothes "
        f"WHERE id IN ({ph}) AND user_id = ?",
        list(cloth_ids) + [user_id],
    ).fetchall()
    by_id = {r["id"]: r for r in rows}
    images = front_images(conn, cloth_ids)
    # Shown the way the clothes are worn — shoes, bottom, t-shirt, jacket, cap —
    # not in the order the algorithm happened to pick them. Same LAYER_ORDER the
    # generated render and the manual canvas use, so a garment never appears in
    # one order here and another there.
    ordered = layer_sorted(
        [cid for cid in cloth_ids if cid in by_id],
        key=lambda cid: (by_id[cid]["category"] or ""))
    out = []
    for cid in ordered:
        row = by_id.get(cid)
        if not row:
            continue
        im = images.get(cid)
        path = display_path(im) if im else ""
        out.append({
            "id": cid,
            "name": row["name"],
            "brand": row["brand"] or "",
            "category": row["category"] or "",
            "thumb_url": thumb_url_for(path, 400) if path else "",
            "image_url": public_url_for(path) if path else "",
        })
    return out


def _weather_for(conn, user_id: int, requested: str, day: str) -> dict:
    """The day's forecast, or a blank one. Never raises: a plan must be usable
    with no location set and with the provider down."""
    mode = (requested or "any").strip().lower()
    if mode != "auto":
        return {"mode": mode if mode in ("hot", "cold") else "any",
                "available": False, "temp_max": None}
    row = conn.execute(
        "SELECT weather_lat, weather_lon FROM users WHERE id = ?", (user_id,)
    ).fetchone()
    if not row or row["weather_lat"] is None:
        return {"mode": "any", "available": False, "temp_max": None}
    try:
        got = weather_mod.forecast(row["weather_lat"], row["weather_lon"], day)
    except weather_mod.WeatherUnavailable:
        return {"mode": "any", "available": False, "temp_max": None}
    return {"mode": got["mode"], "available": True,
            "temp_max": got["temp_max"], "temp_min": got["temp_min"],
            "code": got["code"]}


def _planned_days(conn, user_id: int, days: List[str]) -> Dict[str, int]:
    """day -> agenda entry id, for the days already spoken for."""
    if not days:
        return {}
    ph = ",".join("?" * len(days))
    rows = conn.execute(
        f"SELECT id, day FROM agenda WHERE user_id = ? AND day IN ({ph})",
        [user_id] + days,
    ).fetchall()
    return {r["day"]: r["id"] for r in rows}


def _mix(req: PlanRequest) -> List[PlanAlgo]:
    """The algorithms this week may use, validated.

    An empty list means the caller is an older client that only knows how to
    send one ``algo``; a pick-by-* entry with no value is dropped rather than
    refused, so ticking "by colour" and forgetting to choose one does not fail
    the whole week.
    """
    entries = list(req.algos or [])
    if not entries:
        entries = [PlanAlgo(algo=req.algo)]
    out: List[PlanAlgo] = []
    for e in entries:
        if e.algo not in ALGOS:
            raise HTTPException(status.HTTP_400_BAD_REQUEST,
                                f"Unknown algo '{e.algo}'")
        if e.algo == "pick-by-color" and not e.color.strip():
            continue
        if e.algo == "pick-by-brand" and not e.brand.strip():
            continue
        if e.algo == "pick-by-tag" and not e.tag.strip():
            continue
        out.append(e)
    if not out:
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST,
            "Pick at least one algorithm — and give a colour, brand or tag for "
            "the 'by colour/brand/tag' ones.")
    return out


def _algo_for_day(mix: List[PlanAlgo], index: int) -> PlanAlgo:
    """Which algorithm dresses day ``index``.

    Round-robin, so a mix of three over seven days uses each roughly evenly and
    two neighbouring days never share one while an unused algorithm waits. Not
    random: "varied" that happens to pick the same algorithm four days running
    reads exactly like the bug this replaces.
    """
    return mix[index % len(mix)]


def _draw(user_id: int, entry: PlanAlgo, req: PlanRequest, weather_mode: str,
          avoid_clothes: set, avoid_themes: set, locked: List[int] = ()):
    return algo_select(GenerateRequest(
        locked_cloth_ids=list(locked),
        algo=entry.algo, min_score=req.min_score, user_id=user_id,
        color=entry.color, brand=entry.brand, tag=entry.tag,
        weather=weather_mode, categories=req.categories,
        fill_gaps=req.fill_gaps,
        avoid_cloth_ids=avoid_clothes,
        avoid_theme_values=avoid_themes,
    ))


def _hold(n) -> int:
    try:
        return max(1, min(int(n), MAX_HOLD))
    except (TypeError, ValueError):
        return 1


def _outfit_pool(conn, user_id: int, favorites_only: bool) -> List[dict]:
    """The user's finished outfits a plan may reuse, newest first: front views
    with a picture, never a clothes-only plan row."""
    rows = conn.execute(
        "SELECT id, cloth_ids, generated_path, is_favorite FROM outfits "
        "WHERE user_id = ? AND status = 'done' AND kind IN ('ai', 'manual') "
        "AND generated_path != '' "
        "AND NOT (view = 'back' AND linked_id IS NOT NULL) "
        + ("AND is_favorite = 1 " if favorites_only else "")
        + "ORDER BY id DESC",
        (user_id,),
    ).fetchall()
    out = []
    for r in rows:
        try:
            ids = [int(x) for x in json.loads(r["cloth_ids"] or "[]")]
        except (ValueError, TypeError):
            ids = []
        if ids:
            out.append({"id": r["id"], "cloth_ids": ids,
                        "path": r["generated_path"]})
    return out


def _outfit_card(conn, user_id: int, outfit_id: int) -> Optional[dict]:
    row = conn.execute(
        "SELECT id, cloth_ids, generated_path FROM outfits "
        "WHERE id = ? AND user_id = ?", (outfit_id, user_id)).fetchone()
    if not row:
        return None
    try:
        ids = [int(x) for x in json.loads(row["cloth_ids"] or "[]")]
    except (ValueError, TypeError):
        ids = []
    return {"id": row["id"], "cloth_ids": ids, "path": row["generated_path"]}


def _pick_outfit(pool: List[dict], used_clothes: set, used_outfits: set,
                 roles: Dict[int, str], rng: random.Random) -> Optional[dict]:
    """An outfit not used yet this week, preferring one that shares no garment
    (shoes and accessories aside) with the days already planned."""
    fresh = [o for o in pool if o["id"] not in used_outfits]
    if not fresh:
        return None
    clean = [o for o in fresh if not any(
        c in used_clothes and roles.get(c) not in AVOID_EXEMPT_ROLES
        for c in o["cloth_ids"])]
    return rng.choice(clean or fresh)


@router.post("/preview")
def preview_plan(req: PlanRequest, user=Depends(get_current_user)):
    """Propose an outfit per day. Writes nothing."""
    source = req.source if req.source in SOURCES else "algo"
    # Outfits-only still needs an algorithm for the days the pool runs dry.
    mix = _mix(req) if (source != "outfits" or req.algos) else [PlanAlgo()]
    days = _days(req.start_day, req.days)
    keep = {d: [int(x) for x in ids] for d, ids in (req.keep or {}).items()}
    keep_outfits = {d: int(o) for d, o in (req.keep_outfits or {}).items()}
    hold_default = _hold(req.hold_days)
    hold_by_cat = {k: _hold(v) for k, v in (req.hold_by_category or {}).items()}
    rng = random.Random()

    out = []
    with get_conn() as conn:
        cats = {r["id"]: (r["category"] or "") for r in conn.execute(
            "SELECT id, category FROM clothes WHERE user_id = ?", (user["id"],))}
        roles = {cid: role_of(cat) for cid, cat in cats.items()}

        def hold_of(cid: int) -> int:
            return hold_by_cat.get(cats.get(cid, ""), hold_default)

        pinned = {}
        for d in days:
            if d in keep_outfits:
                card = _outfit_card(conn, user["id"], keep_outfits[d])
                if card:
                    pinned[d] = card
        # Locked days do not get re-drawn, but what they hold is off the table
        # for the others — otherwise regenerating around a pinned Monday hands
        # its t-shirt straight to Tuesday.
        used: set = set()
        used_outfits: set = {c["id"] for c in pinned.values()}
        for d in days:
            used.update(keep.get(d, []))
            if d in pinned:
                used.update(pinned[d]["cloth_ids"])
        # Themes already spent this week, per algorithm. Reported: "pour le mode
        # meme marque je ne veux pas que toute la semaine il y ait la meme chose".
        themes_by_algo: Dict[str, set] = {}
        pool = (_outfit_pool(conn, user["id"], req.favorites_only)
                if source != "algo" else [])

        carry: Dict[int, int] = {}   # garment -> days it is still worn after today
        held: Optional[dict] = None  # outfit held over from an earlier day
        held_left = 0
        picks = 0                    # fresh picks so far, alternates the mix
        algo_index = 0
        existing = _planned_days(conn, user["id"], days)

        def update_carry(ids: List[int]):
            nonlocal carry
            nxt = {}
            for cid in ids:
                left = carry[cid] - 1 if carry.get(cid, 0) > 0 else hold_of(cid) - 1
                if left > 0:
                    nxt[cid] = left
            carry = nxt

        for day in days:
            forecast = _weather_for(conn, user["id"], req.weather, day)
            base = {"day": day, "weather": forecast,
                    "already_planned": day in existing}
            if day in pinned or day in keep:
                o = pinned.get(day)
                ids = o["cloth_ids"] if o else keep[day]
                out.append({**base, "locked": True, "repeated": False,
                            "algo": "", "theme": "", "source": "kept",
                            "outfit_id": o["id"] if o else None,
                            "outfit_thumb_url": thumb_url_for(o["path"], 400) if o else "",
                            "carried_ids": [],
                            "cloths": _cloth_cards(conn, user["id"], ids),
                            "cloth_ids": ids})
                # A pinned day starts its own hold, like any fresh pick.
                carry = {}
                held, held_left = (o, hold_default - 1) if o else (None, 0)
                if not o:
                    update_carry(ids)
                continue

            if held and held_left > 0:
                held_left -= 1
                ids = held["cloth_ids"]
                out.append({**base, "locked": False, "repeated": False,
                            "algo": "", "theme": "", "source": "outfit",
                            "outfit_id": held["id"],
                            "outfit_thumb_url": thumb_url_for(held["path"], 400),
                            "carried_ids": ids,
                            "cloths": _cloth_cards(conn, user["id"], ids),
                            "cloth_ids": ids})
                continue
            held = None

            carried = [cid for cid in carry if cid in cats]
            want_outfit = (source == "outfits"
                           or (source == "mix" and picks % 2 == 1))
            if want_outfit and not carried:
                o = _pick_outfit(pool, used, used_outfits, roles, rng)
                if o:
                    picks += 1
                    used_outfits.add(o["id"])
                    used.update(o["cloth_ids"])
                    held, held_left = o, hold_default - 1
                    carry = {}
                    out.append({**base, "locked": False, "repeated": False,
                                "algo": "", "theme": "", "source": "outfit",
                                "outfit_id": o["id"],
                                "outfit_thumb_url": thumb_url_for(o["path"], 400),
                                "carried_ids": [],
                                "cloths": _cloth_cards(conn, user["id"], o["cloth_ids"]),
                                "cloth_ids": o["cloth_ids"]})
                    continue

            entry = mix[algo_index % len(mix)]
            algo_index += 1
            picks += 1
            avoid_themes = (set() if req.allow_repeat_theme
                            else themes_by_algo.get(entry.algo, set()))
            avoid = used - set(carried)
            picked = _draw(user["id"], entry, req, forecast["mode"],
                           avoid, avoid_themes, carried)
            repeated = False
            if not picked:
                # A wardrobe that cannot dress seven distinct days is the normal
                # case, not an error: drop the no-repeats rules for this day and
                # say so, rather than leaving a hole.
                picked = _draw(user["id"], entry, req, forecast["mode"],
                               set(), set(), carried)
                repeated = bool(picked)
            ids = [c["id"] for c in picked]
            used.update(ids)
            theme = theme_value_of(entry.algo, picked)
            if theme:
                themes_by_algo.setdefault(entry.algo, set()).add(theme)
            update_carry(ids)
            out.append({**base, "locked": False, "repeated": repeated,
                        "algo": entry.algo, "theme": theme or "",
                        "source": "algo", "outfit_id": None,
                        "outfit_thumb_url": "",
                        "carried_ids": [c for c in carried if c in ids],
                        "cloths": _cloth_cards(conn, user["id"], ids),
                        "cloth_ids": ids})
    return {"algo": mix[0].algo, "algos": [e.algo for e in mix],
            "source": source, "days": out}


@router.get("/outfits")
def plan_outfits(favorites_only: bool = False, user=Depends(get_current_user)):
    """The outfits a day can be pinned to, newest first, with a thumbnail."""
    with get_conn() as conn:
        pool = _outfit_pool(conn, user["id"], favorites_only)
        fav = {r["id"] for r in conn.execute(
            "SELECT id FROM outfits WHERE user_id = ? AND is_favorite = 1",
            (user["id"],))}
        names = {r["id"]: r for r in conn.execute(
            "SELECT id, name, brand FROM clothes WHERE user_id = ?",
            (user["id"],))}
    return {"items": [{
        "id": o["id"], "cloth_ids": o["cloth_ids"],
        "is_favorite": o["id"] in fav,
        "thumb_url": thumb_url_for(o["path"], 400),
        "search": " ".join(
            f"{names[c]['name']} {names[c]['brand'] or ''}"
            for c in o["cloth_ids"] if c in names).lower(),
    } for o in pool]}


@router.post("/apply")
def apply_plan(req: ApplyRequest, user=Depends(get_current_user)):
    """Write the accepted plan into the agenda.

    One agenda entry per day, pointing at an outfit row that holds the clothes
    and no render. Days that already have an entry are left alone unless
    ``replace`` is set — a plan must not quietly delete something the user
    scheduled by hand.
    """
    days = sorted(d for d, ids in (req.days or {}).items() if ids)
    if not days:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Nothing to apply")
    if len(days) > MAX_DAYS:
        raise HTTPException(status.HTTP_400_BAD_REQUEST,
                            f"At most {MAX_DAYS} days at a time")

    created, skipped = [], []
    with get_conn() as conn:
        existing = _planned_days(conn, user["id"], days)
        owned = {
            r["id"] for r in conn.execute(
                "SELECT id FROM clothes WHERE user_id = ?", (user["id"],))
        }
        own_outfits = {
            r["id"] for r in conn.execute(
                "SELECT id FROM outfits WHERE user_id = ? AND status = 'done'",
                (user["id"],))
        }
        for day in days:
            try:
                date.fromisoformat(day)
            except ValueError as e:
                raise HTTPException(status.HTTP_400_BAD_REQUEST,
                                    f"'{day}' is not a date (YYYY-MM-DD)") from e
            # Somebody else's clothes cannot end up in this user's plan.
            ids = [int(c) for c in req.days[day] if int(c) in owned]
            if not ids:
                skipped.append({"day": day, "reason": "no clothes"})
                continue
            if day in existing:
                if not req.replace:
                    skipped.append({"day": day, "reason": "already planned"})
                    continue
                conn.execute("DELETE FROM agenda WHERE id = ?", (existing[day],))

            reuse = int((req.outfits or {}).get(day) or 0)
            outfit_id = reuse if reuse in own_outfits else conn.execute(
                "INSERT INTO outfits (user_id, cloth_ids, status, kind, "
                "model_tier, generated_path) "
                "VALUES (?, ?, 'done', 'plan', 'flex', '')",
                (user["id"], json.dumps(ids)),
            ).lastrowid
            entry_id = conn.execute(
                "INSERT INTO agenda (user_id, day, outfit_id, title, worn) "
                "VALUES (?, ?, ?, '', 0)",
                (user["id"], day, outfit_id),
            ).lastrowid
            created.append({"day": day, "entry_id": entry_id,
                            "outfit_id": outfit_id})
    log.info("planned %s day(s) for user %s (%s skipped)",
             len(created), user["id"], len(skipped))
    return {"created": created, "skipped": skipped}
