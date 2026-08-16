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
from datetime import date, timedelta
from typing import Dict, List

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel

import weather as weather_mod
from auth import get_current_user
from db import get_conn
from generator import (
    ALGOS,
    GenerateRequest,
    layer_sorted,
    select as algo_select,
    theme_value_of,
)
from images import public_url_for
from routes_thumbs import thumb_url_for

router = APIRouter(prefix="/agenda/plan", tags=["agenda"])
log = logging.getLogger(__name__)

MAX_DAYS = 14


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


class ApplyRequest(BaseModel):
    days: Dict[str, List[int]]     # day -> cloth ids, as shown to the user
    replace: bool = False          # overwrite days that already have a plan


def _days(start_day: str, count: int) -> List[str]:
    try:
        start = date.fromisoformat(start_day) if start_day else date.today()
    except ValueError:
        raise HTTPException(status.HTTP_400_BAD_REQUEST,
                            f"'{start_day}' is not a date (YYYY-MM-DD)")
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
    images = {}
    for im in conn.execute(
        f"SELECT cloth_id, cutout_path, original_path, bg_accepted "
        f"FROM cloth_images WHERE cloth_id IN ({ph}) "
        f"ORDER BY CASE role WHEN 'front' THEN 0 ELSE 1 END DESC, sort_order DESC, id DESC",
        cloth_ids,
    ).fetchall():
        images[im["cloth_id"]] = im  # last write wins == the front photo
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
        path = ""
        if im:
            path = (im["original_path"] if im["bg_accepted"] == "rejected"
                    else (im["cutout_path"] or im["original_path"]))
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
          avoid_clothes: set, avoid_themes: set):
    return algo_select(GenerateRequest(
        algo=entry.algo, min_score=req.min_score, user_id=user_id,
        color=entry.color, brand=entry.brand, tag=entry.tag,
        weather=weather_mode, categories=req.categories,
        fill_gaps=req.fill_gaps,
        avoid_cloth_ids=avoid_clothes,
        avoid_theme_values=avoid_themes,
    ))


@router.post("/preview")
def preview_plan(req: PlanRequest, user=Depends(get_current_user)):
    """Propose an outfit per day. Writes nothing."""
    mix = _mix(req)
    days = _days(req.start_day, req.days)
    keep = {d: [int(x) for x in ids] for d, ids in (req.keep or {}).items()}

    # Locked days do not get re-drawn, but what they hold is off the table for
    # the others — otherwise regenerating around a pinned Monday hands its
    # t-shirt straight to Tuesday.
    used: set = set()
    for d in days:
        used.update(keep.get(d, []))
    # Themes already spent this week, per algorithm. Reported: "pour le mode
    # meme marque je ne veux pas que toute la semaine il y ait la meme chose".
    themes_by_algo: Dict[str, set] = {}

    out = []
    with get_conn() as conn:
        existing = _planned_days(conn, user["id"], days)
        for index, day in enumerate(days):
            forecast = _weather_for(conn, user["id"], req.weather, day)
            if day in keep:
                out.append({
                    "day": day, "weather": forecast, "locked": True,
                    "repeated": False, "algo": "",
                    "cloths": _cloth_cards(conn, user["id"], keep[day]),
                    "cloth_ids": keep[day],
                    "already_planned": day in existing,
                })
                continue

            entry = _algo_for_day(mix, index)
            avoid_themes = (set() if req.allow_repeat_theme
                            else themes_by_algo.get(entry.algo, set()))
            picked = _draw(user["id"], entry, req, forecast["mode"],
                           used, avoid_themes)
            repeated = False
            if not picked:
                # A wardrobe that cannot dress seven distinct days is the normal
                # case, not an error: drop the no-repeats rules for this day and
                # say so, rather than leaving a hole.
                picked = _draw(user["id"], entry, req, forecast["mode"],
                               set(), set())
                repeated = bool(picked)
            ids = [c["id"] for c in picked]
            used.update(ids)
            theme = theme_value_of(entry.algo, picked)
            if theme:
                themes_by_algo.setdefault(entry.algo, set()).add(theme)
            out.append({
                "day": day, "weather": forecast, "locked": False,
                "repeated": repeated,
                "algo": entry.algo,
                "theme": theme or "",
                "cloths": _cloth_cards(conn, user["id"], ids),
                "cloth_ids": ids,
                "already_planned": day in existing,
            })
    return {"algo": mix[0].algo, "algos": [e.algo for e in mix], "days": out}


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
        for day in days:
            try:
                date.fromisoformat(day)
            except ValueError:
                raise HTTPException(status.HTTP_400_BAD_REQUEST,
                                    f"'{day}' is not a date (YYYY-MM-DD)")
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

            outfit_id = conn.execute(
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
