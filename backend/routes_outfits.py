import json
from pathlib import Path
from types import SimpleNamespace
from typing import List, Optional

import io

from fastapi import (APIRouter, BackgroundTasks, Depends, File, Form,
                     HTTPException, UploadFile, status)
from PIL import Image
from pydantic import BaseModel

from audit import record as audit_record
from auth import get_current_user
from bfl import (
    BflError,
    TIER_MAX_IMAGES,
    generate_outfit as bfl_generate_outfit,
    make_labeled_collage,
    next_outfit_tier,
)
from config import OUTFITS_DIR
from db import get_conn
from routes_thumbs import thumb_url_for
import imagesign
from ratelimit import generation_guard, worker_id
from generator import (
    ALGOS,
    combo_key,
    explain as algo_explain,
    is_multi_angle,
    select as algo_select,
    why_empty as algo_why_empty,
)
from images import public_url_for  # noqa: F401  (shared helper, kept for parity)

router = APIRouter(prefix="/outfits", tags=["outfits"])


class GenerateRequest(BaseModel):
    model_id: Optional[int] = None  # None = no person → outfit-only generation
    # When true, the server picks a random model from the user's models for
    # each generation (so a batch can show the outfit on several people).
    random_model: bool = False
    # Restrict the random pick to 'male'/'female' models ('' = any).
    random_model_gender: str = ""
    cloth_ids: List[int] = []
    prompt: str = ""
    tier: str = "flex"
    view: str = "front"  # 'front' | 'back' (when a model is selected)
    # When true, auto-append a short description of the selected clothes (brand,
    # name and type) to the prompt so the model knows what it's rendering.
    describe_clothes: bool = False
    # 'collage' = tile all clothes into one reference image; 'separate' = one
    # image per garment, with the prompt describing what each image shows.
    image_mode: str = "collage"
    # Optional subset of cloth_ids to actually render (the rest stay in the
    # outfit but aren't drawn) — used to pick which top to show. [] = render all.
    render_cloth_ids: List[int] = []


class RegenerateRequest(BaseModel):
    tier: Optional[str] = None
    # When set, flip the "describe items to the AI" option and re-render (the
    # UI toggle). None = leave it unchanged.
    describe_clothes: Optional[bool] = None
    # Extra instruction to fold into the prompt (e.g. "hands in pockets, side
    # view"). Persisted so it sticks to the outfit.
    add_detail: Optional[str] = None
    # Change how clothes are sent ('collage' | 'separate') and which of the
    # outfit's clothes are actually drawn (the "which top to render" choice).
    # None = leave unchanged; both are persisted on the outfit.
    image_mode: Optional[str] = None
    render_cloth_ids: Optional[List[int]] = None


class ReportRequest(BaseModel):
    message: str = ""


class FavoriteRequest(BaseModel):
    is_favorite: Optional[bool] = None  # if None, toggle


class AlgoRequest(BaseModel):
    algo: str  # one of generator.ALGOS
    min_score: int = 0  # 0 = no rating filter; 1..5 = only clothes rated >= this
    color: str = ""  # for pick-by-color
    brand: str = ""  # for pick-by-brand
    tag: str = ""    # for pick-by-tag
    count: int = 1  # how many selections to propose (for batch generation)
    model_id: Optional[int] = None
    random_model: bool = False
    random_model_gender: str = ""  # '' any | 'male' | 'female'
    # "any" | "hot" | "cold" — restricts the pool (and the random algo's
    # completion logic) to light or warm outfits.
    weather: str = "any"
    # Explicit category list — picks one cloth per requested category from the
    # pool (e.g. ["tshirt","jeans","sneakers"]). Overrides weather.
    categories: List[str] = []
    view: str = "front"
    prompt: str = ""
    tier: str = "flex"
    describe_clothes: bool = False
    image_mode: str = "collage"  # 'collage' | 'separate'
    render_cloth_ids: List[int] = []
    # Clothes the user picked that must stay in the outfit; the algorithm fills
    # the remaining roles around them.
    locked_cloth_ids: List[int] = []
    # Fill missing core roles (top/bottom/shoes) from ANY cloth when the theme
    # (e.g. one brand or one colour) can't cover them.
    fill_gaps: bool = False


def _image_file_path(row) -> str:
    if row["bg_accepted"] == "rejected":
        return row["original_path"]
    return row["cutout_path"] or row["original_path"]


_ROLE_LABELS = {
    "top": "TOP", "outer": "OUTER", "bottom": "BOTTOM",
    "onepiece": "DRESS", "feet": "SHOES", "accessory": "ACC",
    "other": "",
}


def _cloth_items(conn, cloth_ids: List[int], view: str = "front") -> List[dict]:
    """One image per cloth, tagged with its role for the labeled collage. The
    role label on the collage is what lets the model tell tops from bottoms
    from shoes when several garments are composed together.

    ``view`` selects which cloth photo to use: 'front' (the default, used for
    front-view outfits) or 'back' (used when generating the back view, so the
    model sees the back of each garment and reads them as back-side clothing).
    Falls back to the front image if no back photo was uploaded."""
    from generator import role_of

    pref_role = view if view in ("front", "back") else "front"
    if not cloth_ids:
        return []

    # Three grouped queries instead of three per cloth. Ordering is applied in
    # SQL and the first row per cloth wins, which reproduces the old
    # "ORDER BY ... LIMIT 1" pick exactly.
    ph = ",".join("?" * len(cloth_ids))
    preferred: dict = {}
    for im in conn.execute(
        "SELECT cloth_id, original_path, cutout_path, bg_accepted, role "
        f"FROM cloth_images WHERE cloth_id IN ({ph}) AND role = ? "
        "ORDER BY sort_order DESC, id DESC",
        list(cloth_ids) + [pref_role],
    ).fetchall():
        preferred[im["cloth_id"]] = im  # last write wins == first in ASC order

    fallback: dict = {}
    for im in conn.execute(
        "SELECT cloth_id, original_path, cutout_path, bg_accepted, role "
        f"FROM cloth_images WHERE cloth_id IN ({ph}) "
        "ORDER BY CASE role WHEN 'front' THEN 0 ELSE 1 END DESC, "
        "sort_order DESC, id DESC",
        list(cloth_ids),
    ).fetchall():
        fallback[im["cloth_id"]] = im

    categories = {
        c["id"]: c["category"]
        for c in conn.execute(
            f"SELECT id, category FROM clothes WHERE id IN ({ph})", list(cloth_ids)
        ).fetchall()
    }

    out: List[dict] = []
    for cid in cloth_ids:
        row = preferred.get(cid) or fallback.get(cid)
        if not row:
            continue
        out.append({
            "id": cid,
            "path": _image_file_path(row),
            "label": _ROLE_LABELS.get(role_of(categories.get(cid, "")), ""),
        })
    return out


def _model_path(conn, model_id: int, user_id: int, view: str) -> Optional[str]:
    """Pick the model's photo for the requested view ('front' or 'back')."""
    row = conn.execute(
        "SELECT mi.original_path, mi.cutout_path, mi.bg_accepted "
        "FROM model_images mi JOIN models m ON m.id = mi.model_id "
        "WHERE mi.model_id = ? AND m.user_id = ? AND mi.role = ? "
        "ORDER BY mi.sort_order, mi.id LIMIT 1",
        (model_id, user_id, view),
    ).fetchone()
    return _image_file_path(row) if row else None


def _build_outfit(row, cloths, model_name, worn_today=False,
                  blacklisted=False) -> dict:
    tier = row["model_tier"] or "flex"
    return {
        "is_blacklisted": blacklisted,
        "id": row["id"],
        "model_id": row["model_id"],
        "model_name": model_name,
        "cloth_ids": json.loads(row["cloth_ids"] or "[]"),
        "cloths": cloths,
        "prompt": row["prompt"],
        "generated_url": public_url_for_outfit(row["generated_path"]),
        # Grid-sized copy for the history/favorites lists, which showed dozens
        # of full-resolution renders at thumbnail size.
        "thumb_url": thumb_url_for(row["generated_path"], 400),
        # Detail/dialog size — a screen-wide view, not the full render.
        "preview_url": thumb_url_for(row["generated_path"], 800),
        "status": row["status"],
        "is_mock": bool(row["is_mock"]),
        "model_tier": tier,
        "model_slug": row["model_slug"],
        "view": row["view"] or "front",
        "linked_id": row["linked_id"] if "linked_id" in row.keys() else None,
        "is_favorite": bool(row["is_favorite"]),
        "describe_clothes": bool(row["describe_clothes"])
        if "describe_clothes" in row.keys() else False,
        "image_mode": _outfit_image_mode(row),
        "render_cloth_ids": _outfit_render_ids(row),
        "worn_today": worn_today,
        "next_tier": next_outfit_tier(tier, can_vto=row["model_id"] is not None)
        if row["status"] == "done" and _outfit_kind(row) == "ai" else None,
        "error": row["error"],
        "kind": _outfit_kind(row),
        "layout": _outfit_layout(row),
        "created_at": row["created_at"],
    }


def _outfit_kind(row) -> str:
    return (row["kind"] if "kind" in row.keys() and row["kind"] else "ai")


def _outfit_layout(row):
    """The manual builder's layout as a parsed object (bg + placed items), or
    None for AI outfits / rows with no stored layout."""
    if "layout" not in row.keys() or not row["layout"]:
        return None
    try:
        return json.loads(row["layout"])
    except (ValueError, TypeError):
        return None


def _worn_today_ids(conn, outfit_ids: List[int]) -> set:
    """Outfit ids that have a 'worn' agenda entry for today."""
    if not outfit_ids:
        return set()
    ph = ",".join("?" * len(outfit_ids))
    rows = conn.execute(
        f"SELECT DISTINCT outfit_id FROM agenda WHERE worn = 1 AND day = ? "
        f"AND outfit_id IN ({ph})",
        [_today_iso()] + list(outfit_ids),
    ).fetchall()
    return {r["outfit_id"] for r in rows}


def _hydrate(conn, row) -> dict:
    cloth_ids = json.loads(row["cloth_ids"] or "[]")
    cloths = []
    if cloth_ids:
        placeholders = ",".join("?" * len(cloth_ids))
        rows = conn.execute(
            f"SELECT id, name, brand, category FROM clothes WHERE id IN ({placeholders})",
            cloth_ids,
        ).fetchall()
        by_id = {r["id"]: r for r in rows}
        # Preserve the outfit's cloth order (the IN query doesn't guarantee it).
        cloths = [{"id": by_id[i]["id"], "name": by_id[i]["name"],
                   "brand": by_id[i]["brand"], "category": by_id[i]["category"]}
                  for i in cloth_ids if i in by_id]
    model_name = None
    if row["model_id"] is not None:
        m = conn.execute("SELECT name FROM models WHERE id = ?", (row["model_id"],)).fetchone()
        if m:
            model_name = m["name"]
    worn = bool(_worn_today_ids(conn, [row["id"]]))
    blacklisted = combo_key(cloth_ids) in _blacklist_set(conn, row["user_id"]) \
        if cloth_ids else False
    return _build_outfit(row, cloths, model_name, worn_today=worn,
                         blacklisted=blacklisted)


def _blacklist_set(conn, user_id: int) -> set:
    return {r["combo"] for r in conn.execute(
        "SELECT combo FROM outfit_blacklist WHERE user_id = ?", (user_id,)
    ).fetchall()}


def _hydrate_many(conn, rows) -> list:
    """Hydrate many outfits with a fixed number of queries (two) instead of the
    ~2 per outfit the single path issues — used by the history + favorites
    lists, which can be long."""
    if not rows:
        return []
    all_cloth_ids = set()
    model_ids = set()
    for r in rows:
        all_cloth_ids.update(json.loads(r["cloth_ids"] or "[]"))
        if r["model_id"] is not None:
            model_ids.add(r["model_id"])
    cloth_by_id = {}
    if all_cloth_ids:
        ph = ",".join("?" * len(all_cloth_ids))
        for c in conn.execute(
            f"SELECT id, name, brand, category FROM clothes WHERE id IN ({ph})",
            list(all_cloth_ids),
        ).fetchall():
            cloth_by_id[c["id"]] = c
    model_name_by_id = {}
    if model_ids:
        ph = ",".join("?" * len(model_ids))
        for m in conn.execute(
            f"SELECT id, name FROM models WHERE id IN ({ph})", list(model_ids)
        ).fetchall():
            model_name_by_id[m["id"]] = m["name"]
    worn = _worn_today_ids(conn, [r["id"] for r in rows])
    blacklist = _blacklist_set(conn, rows[0]["user_id"])
    out = []
    for r in rows:
        cloth_ids = json.loads(r["cloth_ids"] or "[]")
        cloths = [{"id": cloth_by_id[i]["id"], "name": cloth_by_id[i]["name"],
                   "brand": cloth_by_id[i]["brand"],
                   "category": cloth_by_id[i]["category"]}
                  for i in cloth_ids if i in cloth_by_id]
        out.append(_build_outfit(
            r, cloths, model_name_by_id.get(r["model_id"]),
            worn_today=r["id"] in worn,
            blacklisted=bool(cloth_ids) and combo_key(cloth_ids) in blacklist))
    return out


def public_url_for_outfit(path: str) -> str:
    if not path:
        return ""
    p = Path(path)
    try:
        rel = p.relative_to(OUTFITS_DIR)
    except ValueError:
        rel = Path(p.name)
    rel_posix = rel.as_posix()
    url = f"/generated/{rel_posix}"
    params = []
    # Append ?v=<mtime> so the URL changes whenever the file is regenerated in
    # place (same {id}.png path) — e.g. after changing the model or clothes.
    # Without this the image cache keeps serving the previous render.
    try:
        params.append(f"v={p.stat().st_mtime_ns}")
    except OSError:
        pass
    signed = imagesign.sign_query(f"generated/{rel_posix}")
    if signed:
        params.append(signed)
    return url + ("?" + "&".join(params) if params else "")


def _validate_inputs(conn, req, user_id: int) -> None:
    for cid in req.cloth_ids:
        owned = conn.execute(
            "SELECT 1 FROM clothes WHERE id = ? AND user_id = ?", (cid, user_id)
        ).fetchone()
        if not owned:
            raise HTTPException(status.HTTP_404_NOT_FOUND, f"Cloth {cid} not found")
    # random_model: a concrete model is picked later, so no model_id to validate.
    if not getattr(req, "random_model", False):
        if getattr(req, "model_id", None) is not None:
            owned = conn.execute(
                "SELECT 1 FROM models WHERE id = ? AND user_id = ?", (req.model_id, user_id)
            ).fetchone()
            if not owned:
                raise HTTPException(status.HTTP_404_NOT_FOUND, "Model not found")


def _pick_random_model(conn, user_id: int, gender: str = "") -> Optional[int]:
    """A random model id owned by the user (so a batch can dress several people),
    or None if the user has no models. ``gender`` ('male'/'female') restricts the
    pick to models of that gender; anything else means any model."""
    gender = (gender or "").strip().lower()
    if gender in ("male", "female"):
        ids = [r["id"] for r in conn.execute(
            "SELECT id FROM models WHERE user_id = ? AND gender = ?",
            (user_id, gender),
        ).fetchall()]
        # Fall back to any model if the user has none of that gender, so a
        # generation never silently produces no person.
        if not ids:
            ids = [r["id"] for r in conn.execute(
                "SELECT id FROM models WHERE user_id = ?", (user_id,)
            ).fetchall()]
    else:
        ids = [r["id"] for r in conn.execute(
            "SELECT id FROM models WHERE user_id = ?", (user_id,)
        ).fetchall()]
    if not ids:
        return None
    import random as _r
    return _r.choice(ids)


# Injected when the user asked for a (random) person but no model photo is
# available, so bfl renders the outfit *on someone* instead of on a mannequin.
_RANDOM_PERSON_PROMPT = (
    "Full-body photo of this outfit worn by a realistic random fashion model "
    "(a real person), natural pose, neutral studio background."
)


def _join_prompt(*parts: str) -> str:
    """Join non-empty prompt fragments into one clean sentence stream."""
    return ". ".join(p.strip(". ").strip() for p in parts if p and p.strip())


def _norm_image_mode(mode) -> str:
    return "separate" if str(mode or "").strip().lower() == "separate" else "collage"


def _render_ids(cloth_ids: List[int], render_cloth_ids) -> List[int]:
    """The clothes actually rendered: the chosen subset (kept in cloth order) if
    one is set, else all of them. Never returns an empty list when clothes exist
    (an empty/garbage subset falls back to rendering everything)."""
    subset = {int(x) for x in (render_cloth_ids or [])}
    if not subset:
        return list(cloth_ids)
    keep = [c for c in cloth_ids if c in subset]
    return keep or list(cloth_ids)


def _garment_image_paths(conn, render_ids: List[int], view: str, image_mode: str,
                         *, person_reserved: bool) -> tuple[List[str], bool]:
    """Garment reference image(s): a single labeled collage ('collage') or one
    image per garment ('separate'). Returns (paths, is_separate). Falls back to
    a collage when 'separate' would need more input slots than the model accepts."""
    items = _cloth_items(conn, render_ids, view=view)
    if not items:
        return [], False
    if image_mode == "separate":
        budget = _MAX_INPUT_IMAGES - (1 if person_reserved else 0)
        if len(items) <= budget:
            return [it["path"] for it in items if it.get("path")], True
        # Too many garments for one-per-image — fall back to the collage.
    collage = make_labeled_collage(items)
    return ([collage] if collage else []), False


def _vto_inputs(conn, render_ids, view, image_mode, has_model, collage_prompt_fn):
    """The VTO slot's inputs when the FLUX tiers use SEPARATE images: VTO only
    accepts one garment, so it always needs a single labeled collage +
    a collage-style prompt. Returns (garment_collage_path, vto_prompt), or
    (None, None) in collage mode (the caller's collage/prompt already fit)."""
    if image_mode != "separate":
        return None, None
    paths, _ = _garment_image_paths(conn, render_ids, view, "collage",
                                    person_reserved=has_model)
    garment = paths[0] if paths else None
    return garment, collage_prompt_fn()


def _garment_descriptions(conn, cloth_ids: List[int]) -> List[str]:
    """Per-cloth short descriptions ('the Nike hoodie'), aligned with cloth_ids,
    for the 'separate images' prompt so the model knows what each image shows."""
    out: List[str] = []
    for cid in cloth_ids:
        row = conn.execute(
            "SELECT name, brand, category FROM clothes WHERE id = ?", (cid,)
        ).fetchone()
        if not row:
            out.append("a garment")
            continue
        name = (row["name"] or "").strip()
        brand = (row["brand"] or "").strip()
        kind = (row["category"] or "").strip().replace("-", " ")
        label = " ".join(w for w in (brand, name) if w)
        if kind and kind.lower() not in label.lower():
            label = f"{label} ({kind})" if label else kind
        out.append(f"the {label}" if label else "a garment")
    return out


def _garment_phrase(conn, cloth_ids: List[int]) -> str:
    """A concise garment description — brand, name and type — phrased to drop
    into the FLUX try-on formula (e.g. "the Nike oversized hoodie, the blue
    jeans and the white sneakers"). Falls back to "the garments"."""
    items: List[str] = []
    for cid in cloth_ids:
        row = conn.execute(
            "SELECT name, brand, category FROM clothes WHERE id = ?", (cid,)
        ).fetchone()
        if not row:
            continue
        name = (row["name"] or "").strip()
        brand = (row["brand"] or "").strip()
        kind = (row["category"] or "").strip().replace("-", " ")
        label = " ".join(w for w in (brand, name) if w)
        if kind and kind.lower() not in label.lower():
            label = f"{label} ({kind})" if label else kind
        if label:
            items.append(f"the {label}")
    if not items:
        return "the garments"
    if len(items) == 1:
        return items[0]
    return ", ".join(items[:-1]) + " and " + items[-1]


# The FLUX try-on formula (from the model docs): image 1 is the person, image 2
# is the garment reference (our labeled collage). Describing the garments —
# especially fit + category — measurably improves the result.
# Nudges the model to layer instead of stacking/duplicating tops, so an outfit
# with several upper garments renders as one coherent look.
_LAYER_HINT = ("Combine them into one coherent, well-fitted outfit with a single "
               "visible top layer; do not duplicate or stack garments.")


def _compose_prompt(conn, cloth_ids, *, user_prompt: str, has_model: bool,
                    is_back: bool, random_person: bool, describe: bool,
                    image_mode: str = "collage") -> str:
    parts: List[str] = []
    if user_prompt:
        parts.append(user_prompt)

    if image_mode == "separate" and cloth_ids:
        # Each garment is its own reference image — enumerate what each shows so
        # the model doesn't confuse them. Image 1 is the person (when present).
        start = 2 if has_model else 1
        descs = _garment_descriptions(conn, cloth_ids)
        listing = "; ".join(f"image {start + i} is {d}" for i, d in enumerate(descs))
        if has_model:
            pose = ("keeping exactly their body shape and pose, shown from behind"
                    if is_back else "maintaining exactly their face and pose")
            parts.append(
                f"The person of image 1, {pose}, wearing the garments shown in the "
                f"other images ({listing}). {_LAYER_HINT}")
        elif random_person:
            parts.append(
                f"Full-body photo of a realistic random fashion model (a real "
                f"person), natural pose, neutral studio background, wearing the "
                f"garments shown in the images ({listing}). {_LAYER_HINT}")
        else:
            parts.append(
                f"A clean, well-lit full-body photo of one complete outfit on a "
                f"plain neutral background, combining the garments shown in the "
                f"images ({listing}). {_LAYER_HINT}")
        return _join_prompt(*parts)

    # Collage mode (default): all garments tiled into one reference image.
    garments = _garment_phrase(conn, cloth_ids) if describe else "the garments"
    if has_model:
        pose = ("keeping exactly their body shape and pose, shown from behind"
                if is_back
                else "maintaining exactly their face and pose")
        parts.append(
            f"The person of image 1, {pose}, wearing {garments} of image 2.")
    elif random_person:
        parts.append(
            f"Full-body photo of a realistic random fashion model (a real "
            f"person), natural pose, neutral studio background, wearing "
            f"{garments} of image 1.")
    else:
        parts.append(
            f"A clean, well-lit full-body photo of {garments} arranged as one "
            f"complete outfit on a plain neutral background.")
    return _join_prompt(*parts)


def _build_inputs(conn, req, user_id: int, model_id=None):
    """Return (prompt, image_paths, person_path, vto_garment, vto_prompt) for bfl.
    Image order matters: the model (person) photo is image 1, the labeled cloth
    collage is image 2, and any extra-angle photos follow. ``person_path`` is the
    model photo when used (drives VTO). ``vto_garment``/``vto_prompt`` are set only
    in separate-image mode (VTO always needs one collage + collage prompt)."""
    user_prompt = (getattr(req, "prompt", "") or "").strip()
    view = getattr(req, "view", "front") or "front"
    cloth_ids = getattr(req, "cloth_ids", []) or []
    image_mode = _norm_image_mode(getattr(req, "image_mode", "collage"))
    render_ids = _render_ids(cloth_ids, getattr(req, "render_cloth_ids", []) or [])
    describe = getattr(req, "describe_clothes", False)
    random_model = getattr(req, "random_model", False)
    image_paths: List[str] = []
    person_path: Optional[str] = None
    if model_id is not None:
        mp = _model_path(conn, model_id, user_id, view)
        if mp:
            image_paths.append(mp)
            person_path = mp
    has_model = person_path is not None
    is_back = view == "back"
    random_person = not has_model and random_model
    garment_paths, _sep = _garment_image_paths(
        conn, render_ids, view, image_mode, person_reserved=has_model)
    image_paths += garment_paths
    prompt = _compose_prompt(
        conn, render_ids, user_prompt=user_prompt, has_model=has_model,
        is_back=is_back, random_person=random_person, describe=describe,
        image_mode=image_mode)
    vto_garment, vto_prompt = _vto_inputs(
        conn, render_ids, view, image_mode, has_model,
        lambda: _compose_prompt(
            conn, render_ids, user_prompt=user_prompt, has_model=has_model,
            is_back=is_back, random_person=random_person, describe=describe,
            image_mode="collage"))
    prompt, image_paths = _append_extra_refs(conn, render_ids, prompt, image_paths)
    return prompt, image_paths, person_path, vto_garment, vto_prompt


# The model accepts several input images; the collage uses one slot per outfit
# and the model photo another. Whatever is left we fill with the extra-angle
# photos of multi-angle items (shoes/bags/…), so the model sees every POV.
_MAX_INPUT_IMAGES = min(TIER_MAX_IMAGES.values())
_EXTRA_REF_HINT = (
    "Some items include extra reference photos showing other angles "
    "(e.g. sides, top, sole) — use them to render those items faithfully."
)


def _extra_reference_paths(conn, cloth_ids: List[int], budget: int) -> List[str]:
    """Full-resolution extra-angle photos for multi-angle clothes, skipping each
    item's primary photo (already in the collage). Capped at ``budget`` so the
    total never exceeds the model's input-image limit."""
    if budget <= 0:
        return []
    paths: List[str] = []
    for cid in cloth_ids:
        cat = conn.execute(
            "SELECT category FROM clothes WHERE id = ?", (cid,)
        ).fetchone()
        if not cat or not is_multi_angle(cat["category"] or ""):
            continue
        rows = conn.execute(
            "SELECT original_path, cutout_path, bg_accepted FROM cloth_images "
            "WHERE cloth_id = ? ORDER BY sort_order, id",
            (cid,),
        ).fetchall()
        for r in rows[1:]:  # skip the primary (in the collage already)
            if len(paths) >= budget:
                return paths
            paths.append(_image_file_path(r))
    return paths


def _append_extra_refs(conn, cloth_ids, prompt: str,
                       image_paths: List[str]) -> tuple[str, List[str]]:
    """Append multi-angle items' extra photos to the input list (budgeted) and,
    when any are added, hint the model about them."""
    extras = _extra_reference_paths(
        conn, cloth_ids or [], _MAX_INPUT_IMAGES - len(image_paths))
    if not extras:
        return prompt, image_paths
    # Guard against re-adding the hint when a stored prompt is reused (regenerate).
    if _EXTRA_REF_HINT not in (prompt or ""):
        prompt = (f"{prompt}. {_EXTRA_REF_HINT}".strip(". ").strip()) or _EXTRA_REF_HINT
    return prompt, image_paths + extras


# Everything the composer appends after the user's own text starts with one of
# these — so slicing at the first marker recovers just the user's prompt.
_GENERATED_MARKERS = (
    "The person of image 1",
    "Full-body photo of a realistic random",
    "A clean, well-lit full-body photo of",
    _EXTRA_REF_HINT,
    _RANDOM_PERSON_PROMPT,  # legacy stored prompts
)


def _user_prompt_of(prompt: str) -> str:
    """Recover the user's own text from a stored, composed prompt by cutting off
    the auto-generated try-on formula / hints — so re-composing for a new model
    doesn't stack redundant instructions."""
    p = (prompt or "").strip()
    cuts = [p.find(m) for m in _GENERATED_MARKERS if m and m in p]
    if not cuts:
        return p.strip(". ").strip()
    return p[: min(cuts)].strip(". ").strip()


def _outfit_describes(row) -> bool:
    return bool(row["describe_clothes"]) if "describe_clothes" in row.keys() else False


def _outfit_image_mode(row) -> str:
    return _norm_image_mode(row["image_mode"]) if "image_mode" in row.keys() else "collage"


def _outfit_render_ids(row) -> List[int]:
    if "render_cloth_ids" not in row.keys():
        return []
    try:
        return [int(x) for x in json.loads(row["render_cloth_ids"] or "[]")]
    except Exception:
        return []


def _recompose_for_row(conn, row, *, cloth_ids=None, view=None, model_id=None,
                       describe=None, add_detail=None, image_mode=None,
                       render_ids=None) -> str:
    """Rebuild an existing outfit's prompt from the user's own text plus the
    CURRENT model/view/clothes and describe flag — used by every re-render path
    (regenerate, swap clothes, change model, back view) so the description stays
    accurate and honours the toggle instead of reusing a stale prompt.
    ``add_detail`` appends extra user instructions (e.g. a specific pose).
    ``image_mode``/``render_ids`` override the stored values when the user
    changed them from the result dialog."""
    cids = cloth_ids if cloth_ids is not None else json.loads(row["cloth_ids"] or "[]")
    render = render_ids if render_ids is not None else _render_ids(cids, _outfit_render_ids(row))
    v = view if view is not None else (row["view"] or "front")
    mid = model_id if model_id is not None else row["model_id"]
    d = describe if describe is not None else _outfit_describes(row)
    im = image_mode if image_mode is not None else _outfit_image_mode(row)
    random_person = mid is None and "realistic random fashion model" in (row["prompt"] or "")
    base = _user_prompt_of(row["prompt"])
    if add_detail and add_detail.strip():
        base = _join_prompt(base, add_detail.strip())
    return _compose_prompt(
        conn, render,
        user_prompt=base,
        has_model=mid is not None,
        is_back=(v == "back"),
        random_person=random_person,
        describe=d,
        image_mode=im,
    )


def _fresh_start_tier(req_tier: Optional[str], person_path: Optional[str]) -> str:
    """Starting tier for a brand-new outfit render. Fresh renders start at flex
    (the first, fast tier); VTO try-on is the next step up via the "try a better
    model" button. An explicit higher tier (vto/pro/max) from the client is
    honoured. Regenerate/upgrade paths pass their own tier and don't use this."""
    if req_tier in ("vto", "pro", "max"):
        return req_tier if (req_tier != "vto" or person_path) else "flex"
    return "flex"


def _run_generation(outfit_id: int, prompt: str, image_paths: List[str],
                    start_tier: str, person_path: Optional[str] = None,
                    vto_garment_path: Optional[str] = None,
                    vto_prompt: Optional[str] = None) -> None:
    # VTO takes a person + ONE garment collage. In collage mode image_paths[1]
    # already IS that collage, so we derive it. In separate mode the caller
    # passes an explicit single-collage ``vto_garment_path`` (+ a collage-style
    # ``vto_prompt``) since VTO can't take the separate garment images.
    garment_path = vto_garment_path
    if garment_path is None and (person_path and image_paths
            and image_paths[0] == person_path and len(image_paths) >= 2):
        garment_path = image_paths[1]
    # Claim the row for THIS process. With several uvicorn workers, the startup
    # sweep uses this to tell a job whose owner died from one a sibling worker
    # is still running.
    with get_conn() as conn:
        conn.execute("UPDATE outfits SET worker_pid = ? WHERE id = ?",
                     (worker_id(), outfit_id))
    try:
        image_bytes, tier_used, slug = bfl_generate_outfit(
            prompt, image_paths, start_tier=start_tier,
            person_path=person_path if garment_path else None,
            garment_path=garment_path,
            vto_prompt=vto_prompt or prompt,
        )
    except BflError as e:
        with get_conn() as conn:
            conn.execute("UPDATE outfits SET status='failed', error=?, "
                         "worker_pid=NULL WHERE id=?", (str(e), outfit_id))
        return
    except Exception as e:
        with get_conn() as conn:
            conn.execute("UPDATE outfits SET status='failed', error=?, "
                         "worker_pid=NULL WHERE id=?",
                         (f"unexpected: {type(e).__name__}: {e}", outfit_id))
        return
    OUTFITS_DIR.mkdir(parents=True, exist_ok=True)
    out_path = OUTFITS_DIR / f"{outfit_id}.png"
    out_path.write_bytes(image_bytes)
    is_mock = 1 if slug == "mock" else 0
    with get_conn() as conn:
        conn.execute(
            "UPDATE outfits SET generated_path=?, status='done', is_mock=?, "
            "model_tier=?, model_slug=?, error='', worker_pid=NULL WHERE id=?",
            (str(out_path), is_mock, tier_used, slug, outfit_id),
        )


# Times an outfit was worn = number of confirmed ('worn') agenda entries for it.
_OUTFIT_WORN = "(SELECT COUNT(*) FROM agenda a WHERE a.outfit_id = o.id AND a.worn = 1)"


def _outfit_order(sort: str) -> str:
    return {
        "oldest": "o.created_at ASC",
        "most_worn": f"{_OUTFIT_WORN} DESC, o.created_at DESC",
        "least_worn": f"{_OUTFIT_WORN} ASC, o.created_at DESC",
    }.get(sort or "", "o.created_at DESC")


def _outfit_filters(favorite: bool, model: str) -> tuple[list, list]:
    where = ["o.user_id = ?", "NOT (o.view = 'back' AND o.linked_id IS NOT NULL)"]
    if favorite:
        where.append("o.is_favorite = 1")
    if model == "with":
        where.append("o.model_id IS NOT NULL")
    elif model == "none":
        where.append("o.model_id IS NULL")
    return where, []


@router.get("")
def list_outfits(
    user=Depends(get_current_user),
    limit: Optional[int] = None,
    offset: int = 0,
    sort: str = "newest",   # newest | oldest | most_worn | least_worn
    favorite: bool = False,  # only favorited outfits
    model: str = "any",      # any | with | none
):
    """Outfit history with sorting/filtering. `limit`/`offset` page it (omit
    `limit` for all) so a long history isn't returned in one unbounded response."""
    where, _ = _outfit_filters(favorite, model)
    sql = (f"SELECT o.* FROM outfits o WHERE {' AND '.join(where)} "
           f"ORDER BY {_outfit_order(sort)}")
    args: list = [user["id"]]
    if limit is not None:
        sql += " LIMIT ? OFFSET ?"
        args += [max(0, int(limit)), max(0, int(offset))]
    with get_conn() as conn:
        rows = conn.execute(sql, args).fetchall()
        return _hydrate_many(conn, rows)


@router.get("/{outfit_id}")
def get_outfit(outfit_id: int, user=Depends(get_current_user)):
    with get_conn() as conn:
        row = conn.execute(
            "SELECT * FROM outfits WHERE id = ? AND user_id = ?",
            (outfit_id, user["id"]),
        ).fetchone()
        if not row:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Outfit not found")
        return _hydrate(conn, row)


@router.post("/generate")
def generate_outfit(req: GenerateRequest, background: BackgroundTasks,
                    user=Depends(generation_guard)):
    """Kick off a generation and return immediately with status 'processing'.
    The heavy BFL call runs in the background; the client polls GET /outfits/{id}
    until status is 'done' or 'failed' (so no request hangs for a minute)."""
    if not req.cloth_ids:
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST, "Pick at least one cloth for the outfit"
        )
    with get_conn() as conn:
        _validate_inputs(conn, req, user["id"])
        # Resolve random_model to a concrete model_id (so regenerate/back can
        # reuse the picked model).
        model_id = req.model_id
        if req.random_model:
            model_id = _pick_random_model(conn, user["id"], req.random_model_gender)
        prompt, image_paths, person_path, vto_garment, vto_prompt = _build_inputs(
            conn, req, user["id"], model_id=model_id)
        view = (req.view or "front") if model_id is not None else "front"
        start_tier = _fresh_start_tier(req.tier, person_path)
        image_mode = _norm_image_mode(req.image_mode)
        render_ids = _render_ids(req.cloth_ids, req.render_cloth_ids)
        cur = conn.execute(
            "INSERT INTO outfits (user_id, model_id, cloth_ids, prompt, model_tier, "
            "view, status, describe_clothes, image_mode, render_cloth_ids) "
            "VALUES (?, ?, ?, ?, ?, ?, 'processing', ?, ?, ?)",
            (user["id"], model_id, json.dumps(req.cloth_ids), prompt, start_tier, view,
             1 if req.describe_clothes else 0, image_mode, json.dumps(render_ids)),
        )
        outfit_id = cur.lastrowid
        # Lifetime counter — stays even if the outfit is later deleted.
        conn.execute(
            "UPDATE users SET outfits_generated = outfits_generated + 1 WHERE id = ?",
            (user["id"],))

    background.add_task(_run_generation, outfit_id, prompt, image_paths, start_tier,
                        person_path, vto_garment, vto_prompt)
    audit_record(user, "outfit.generate",
                 f"#{outfit_id} tier={start_tier} clothes={len(req.cloth_ids)}")

    with get_conn() as conn:
        row = conn.execute("SELECT * FROM outfits WHERE id = ?", (outfit_id,)).fetchone()
        return _hydrate(conn, row)


# --- manual (non-AI) outfit builder -----------------------------------------

_MAX_MANUAL_PNG_BYTES = 12 * 1024 * 1024   # 12 MB composed canvas
_MAX_LAYOUT_CHARS = 200_000                # JSON layout guard


def _parse_id_list(raw: str) -> List[int]:
    try:
        v = json.loads(raw or "[]")
    except (ValueError, TypeError):
        return []
    out = []
    for x in v if isinstance(v, list) else []:
        try:
            out.append(int(x))
        except (ValueError, TypeError):
            continue
    return list(dict.fromkeys(out))  # dedupe, keep order


def _clean_layout(raw: str) -> str:
    """Keep only well-formed, size-bounded JSON; anything else stores as ''."""
    if not raw or len(raw) > _MAX_LAYOUT_CHARS:
        return ""
    try:
        json.loads(raw)
    except (ValueError, TypeError):
        return ""
    return raw


def _owned_cloth_ids(conn, user_id: int, ids: List[int]) -> List[int]:
    if not ids:
        return []
    ph = ",".join("?" * len(ids))
    owned = {r["id"] for r in conn.execute(
        f"SELECT id FROM clothes WHERE user_id = ? AND id IN ({ph})",
        [user_id] + ids).fetchall()}
    return [i for i in ids if i in owned]  # preserve caller order


async def _read_manual_png(image: UploadFile) -> bytes:
    data = await image.read()
    if not data:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Empty image")
    if len(data) > _MAX_MANUAL_PNG_BYTES:
        raise HTTPException(status.HTTP_413_REQUEST_ENTITY_TOO_LARGE, "Image too large")
    try:  # reject anything that isn't a real image
        with Image.open(io.BytesIO(data)) as im:
            im.verify()
    except Exception:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Not a valid image")
    return data


@router.post("/manual")
async def create_manual_outfit(
        image: UploadFile = File(...),
        cloth_ids: str = Form("[]"),
        layout: str = Form(""),
        user=Depends(get_current_user)):
    """Persist a non-AI, hand-composed outfit: the client rasterises its builder
    canvas (garment cutouts on a chosen background) and uploads the PNG plus the
    layout JSON so it can be re-opened for editing. No BFL / no model."""
    data = await _read_manual_png(image)
    with get_conn() as conn:
        ids = _owned_cloth_ids(conn, user["id"], _parse_id_list(cloth_ids))
        cur = conn.execute(
            "INSERT INTO outfits (user_id, cloth_ids, status, kind, layout) "
            "VALUES (?, ?, 'done', 'manual', ?)",
            (user["id"], json.dumps(ids), _clean_layout(layout)))
        outfit_id = cur.lastrowid
    OUTFITS_DIR.mkdir(parents=True, exist_ok=True)
    out_path = OUTFITS_DIR / f"{outfit_id}.png"
    out_path.write_bytes(data)
    with get_conn() as conn:
        conn.execute("UPDATE outfits SET generated_path=? WHERE id=?",
                     (str(out_path), outfit_id))
        conn.execute("UPDATE users SET outfits_generated = outfits_generated + 1 "
                     "WHERE id = ?", (user["id"],))
        row = conn.execute("SELECT * FROM outfits WHERE id = ?", (outfit_id,)).fetchone()
        result = _hydrate(conn, row)
    audit_record(user, "outfit.manual.create",
                 f"#{outfit_id} clothes={len(result['cloth_ids'])}")
    return result


@router.put("/{outfit_id}/manual")
async def update_manual_outfit(
        outfit_id: int,
        image: UploadFile = File(...),
        cloth_ids: str = Form("[]"),
        layout: str = Form(""),
        user=Depends(get_current_user)):
    """Re-save a manual outfit after the user edits its layout — OR convert an
    AI outfit into a manual one IN PLACE. Converting reuses the same row (flips
    kind to 'manual', drops the model, stores the composed canvas), so it never
    leaves a duplicate history entry beside the original."""
    with get_conn() as conn:
        row = conn.execute("SELECT * FROM outfits WHERE id = ? AND user_id = ?",
                           (outfit_id, user["id"])).fetchone()
        if not row:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Outfit not found")
    data = await _read_manual_png(image)
    OUTFITS_DIR.mkdir(parents=True, exist_ok=True)
    out_path = OUTFITS_DIR / f"{outfit_id}.png"
    out_path.write_bytes(data)
    with get_conn() as conn:
        ids = _owned_cloth_ids(conn, user["id"], _parse_id_list(cloth_ids))
        conn.execute(
            "UPDATE outfits SET kind='manual', model_id=NULL, linked_id=NULL, "
            "view='front', cloth_ids=?, layout=?, generated_path=?, "
            "status='done' WHERE id=?",
            (json.dumps(ids), _clean_layout(layout), str(out_path), outfit_id))
        row = conn.execute("SELECT * FROM outfits WHERE id = ?", (outfit_id,)).fetchone()
        return _hydrate(conn, row)


@router.post("/{outfit_id}/regenerate")
def regenerate(outfit_id: int, req: RegenerateRequest, background: BackgroundTasks,
               user=Depends(generation_guard)):
    """Re-render with the next tier in the cascade (or an explicit tier), using
    the same model view + cloth collage. Runs in the background; returns the
    outfit as 'processing' for the client to poll."""
    with get_conn() as conn:
        row = conn.execute(
            "SELECT * FROM outfits WHERE id = ? AND user_id = ?",
            (outfit_id, user["id"]),
        ).fetchone()
        if not row:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Outfit not found")
        prev_tier = row["model_tier"] or "flex"
        cloth_ids = json.loads(row["cloth_ids"] or "[]")
        view = row["view"] or "front"
        # Apply image-mode / render-subset changes from the result dialog, else
        # keep the outfit's stored choices.
        image_mode = _norm_image_mode(req.image_mode) if req.image_mode is not None \
            else _outfit_image_mode(row)
        render_subset = req.render_cloth_ids if req.render_cloth_ids is not None \
            else _outfit_render_ids(row)
        render_ids = _render_ids(cloth_ids, render_subset)
        image_paths: List[str] = []
        person_path: Optional[str] = None
        if row["model_id"] is not None:
            mp = _model_path(conn, row["model_id"], user["id"], view)
            if mp:
                image_paths.append(mp)
                person_path = mp
        garment_paths, _sep = _garment_image_paths(
            conn, render_ids, view, image_mode,
            person_reserved=person_path is not None)
        image_paths += garment_paths
        # Honour the describe toggle if the client flipped it, else keep it.
        describe = req.describe_clothes if req.describe_clothes is not None \
            else _outfit_describes(row)
        composed = _recompose_for_row(conn, row, describe=describe,
                                      add_detail=req.add_detail,
                                      image_mode=image_mode, render_ids=render_ids)
        vto_garment, vto_prompt = _vto_inputs(
            conn, render_ids, view, image_mode, person_path is not None,
            lambda: _recompose_for_row(conn, row, describe=describe,
                                       add_detail=req.add_detail,
                                       image_mode="collage", render_ids=render_ids))
        prompt, image_paths = _append_extra_refs(conn, render_ids, composed, image_paths)
        # Persist the recomposed prompt + choices so they stick to the outfit.
        conn.execute(
            "UPDATE outfits SET status='processing', describe_clothes=?, prompt=?, "
            "image_mode=?, render_cloth_ids=? WHERE id=?",
            (1 if describe else 0, composed, image_mode,
             json.dumps(render_ids), outfit_id))

    target_tier = req.tier or next_outfit_tier(
        prev_tier, can_vto=row["model_id"] is not None) or "max"
    background.add_task(_run_generation, outfit_id, prompt, image_paths, target_tier,
                        person_path, vto_garment, vto_prompt)
    with get_conn() as conn:
        row = conn.execute("SELECT * FROM outfits WHERE id = ?", (outfit_id,)).fetchone()
        return _hydrate(conn, row)


class ReplaceClothesRequest(BaseModel):
    cloth_ids: List[int]


def _rebuild_row_clothes(conn, row, cloth_ids: List[int], user_id: int):
    """Update one outfit row's cloth list (for its own view + model photo) and
    return the args needed to re-render it. Shared so a linked front/back pair
    both get the same clothes."""
    view = row["view"] or "front"
    tier = row["model_tier"] or "flex"
    image_mode = _outfit_image_mode(row)
    # Editing the cloth list re-picks the whole outfit, so render EVERY chosen
    # cloth (drop the stale per-cloth render subset — keeping it would exclude
    # anything just added, the "it removes instead of adding" bug).
    render_ids = list(dict.fromkeys(cloth_ids))
    image_paths: List[str] = []
    person_path: Optional[str] = None
    if row["model_id"] is not None:
        mp = _model_path(conn, row["model_id"], user_id, view)
        if mp:
            image_paths.append(mp)
            person_path = mp
    garment_paths, _sep = _garment_image_paths(
        conn, render_ids, view, image_mode, person_reserved=person_path is not None)
    image_paths += garment_paths
    # Recompose so the description reflects the NEW clothes (not the old set).
    prompt = _recompose_for_row(conn, row, cloth_ids=cloth_ids)
    vto_garment, vto_prompt = _vto_inputs(
        conn, render_ids, view, image_mode, person_path is not None,
        lambda: _recompose_for_row(conn, row, cloth_ids=cloth_ids,
                                   image_mode="collage", render_ids=render_ids))
    prompt, image_paths = _append_extra_refs(conn, render_ids, prompt, image_paths)
    conn.execute("UPDATE outfits SET cloth_ids = ?, prompt = ?, "
                 "render_cloth_ids = '[]', status='processing' WHERE id = ?",
                 (json.dumps(cloth_ids), prompt, row["id"]))
    return (row["id"], prompt, image_paths, tier, person_path, vto_garment, vto_prompt)


@router.post("/{outfit_id}/replace-clothes")
def replace_clothes(outfit_id: int, req: ReplaceClothesRequest,
                    background: BackgroundTasks,
                    user=Depends(generation_guard)):
    """Swap one or more clothes in an existing outfit and re-render. The
    selected-tier stays the same as the outfit's current model_tier. Used by
    the dialog's "Edit clothes" + per-item remove. A linked opposite-view outfit
    (front<->back) gets the SAME clothes and is re-rendered too, so editing on
    the back view also updates the front."""
    with get_conn() as conn:
        row = conn.execute(
            "SELECT * FROM outfits WHERE id = ? AND user_id = ?",
            (outfit_id, user["id"]),
        ).fetchone()
        if not row:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Outfit not found")
        for cid in req.cloth_ids:
            owned = conn.execute(
                "SELECT 1 FROM clothes WHERE id = ? AND user_id = ?", (cid, user["id"])
            ).fetchone()
            if not owned:
                raise HTTPException(status.HTTP_404_NOT_FOUND, f"Cloth {cid} not found")
        # Rebuild this outfit AND its linked opposite view (if any) with the same
        # clothes, so a change made on one view is reflected on the other.
        rows = [row]
        linked_id = row["linked_id"] if "linked_id" in row.keys() else None
        if linked_id is not None:
            linked = conn.execute(
                "SELECT * FROM outfits WHERE id = ? AND user_id = ?",
                (linked_id, user["id"])).fetchone()
            if linked:
                rows.append(linked)
        jobs = [_rebuild_row_clothes(conn, r, req.cloth_ids, user["id"]) for r in rows]

    for (oid, prompt, image_paths, tier, person_path, vto_garment, vto_prompt) in jobs:
        background.add_task(_run_generation, oid, prompt, image_paths, tier,
                            person_path, vto_garment, vto_prompt)
    with get_conn() as conn:
        row = conn.execute("SELECT * FROM outfits WHERE id = ?", (outfit_id,)).fetchone()
        return _hydrate(conn, row)


class ReplaceModelRequest(BaseModel):
    model_id: Optional[int] = None  # None = no person (outfit-only)
    random_model: bool = False      # server picks one of the user's models
    random_model_gender: str = ""   # '' any | 'male' | 'female'


@router.post("/{outfit_id}/replace-model")
def replace_model(outfit_id: int, req: ReplaceModelRequest,
                  background: BackgroundTasks,
                  user=Depends(generation_guard)):
    """Swap the person an existing outfit is rendered on (or drop the model for
    an outfit-only image) and re-render, keeping the same clothes + tier. The
    view resets to 'front' since the back view is a separate linked outfit."""
    with get_conn() as conn:
        row = conn.execute(
            "SELECT * FROM outfits WHERE id = ? AND user_id = ?",
            (outfit_id, user["id"]),
        ).fetchone()
        if not row:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Outfit not found")

        # Resolve the target model (validate ownership / random pick).
        model_id = req.model_id
        if req.random_model:
            model_id = _pick_random_model(conn, user["id"], req.random_model_gender)
        elif model_id is not None:
            owned = conn.execute(
                "SELECT 1 FROM models WHERE id = ? AND user_id = ?",
                (model_id, user["id"]),
            ).fetchone()
            if not owned:
                raise HTTPException(status.HTTP_404_NOT_FOUND, "Model not found")

        tier = row["model_tier"] or "flex"
        cloth_ids = json.loads(row["cloth_ids"] or "[]")
        base_prompt = _user_prompt_of(row["prompt"])

        # Rebuild prompt + images for the new person, from the front — keeping
        # the outfit's describe-clothes setting.
        req_ns = SimpleNamespace(prompt=base_prompt, view="front",
                                 cloth_ids=cloth_ids,
                                 random_model=req.random_model,
                                 describe_clothes=_outfit_describes(row),
                                 image_mode=_outfit_image_mode(row),
                                 render_cloth_ids=_outfit_render_ids(row))
        prompt, image_paths, person_path, vto_garment, vto_prompt = _build_inputs(
            conn, req_ns, user["id"], model_id=model_id)

        conn.execute(
            "UPDATE outfits SET model_id=?, prompt=?, view='front', "
            "linked_id=NULL, status='processing' WHERE id=?",
            (model_id, prompt, outfit_id),
        )

    background.add_task(_run_generation, outfit_id, prompt, image_paths, tier,
                        person_path, vto_garment, vto_prompt)
    with get_conn() as conn:
        row = conn.execute("SELECT * FROM outfits WHERE id = ?", (outfit_id,)).fetchone()
        return _hydrate(conn, row)


@router.post("/{outfit_id}/back")
def generate_back(outfit_id: int, background: BackgroundTasks,
                  user=Depends(generation_guard)):
    """Generate the BACK view of the same outfit (model's back photo + same
    clothes). Creates a new outfit row so both views are kept."""
    with get_conn() as conn:
        src = conn.execute(
            "SELECT * FROM outfits WHERE id = ? AND user_id = ?",
            (outfit_id, user["id"]),
        ).fetchone()
        if not src:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Outfit not found")
        if src["model_id"] is None:
            raise HTTPException(
                status.HTTP_400_BAD_REQUEST,
                "Back view needs a model — generate this outfit with a person first.",
            )
        # Confirm the model has a back photo.
        has_back = conn.execute(
            "SELECT 1 FROM model_images WHERE model_id = ? AND role = 'back'",
            (src["model_id"],),
        ).fetchone()
        if not has_back:
            raise HTTPException(
                status.HTTP_400_BAD_REQUEST,
                "This model has no back photo. Add one to generate the back view.",
            )
        back_cloth_ids = json.loads(src["cloth_ids"] or "[]")
        image_mode = _outfit_image_mode(src)
        render_ids = _render_ids(back_cloth_ids, _outfit_render_ids(src))
        image_paths: List[str] = []
        person_path: Optional[str] = None
        mp = _model_path(conn, src["model_id"], user["id"], "back")
        if mp:
            image_paths.append(mp)
            person_path = mp
        garment_paths, _sep = _garment_image_paths(
            conn, render_ids, "back", image_mode,
            person_reserved=person_path is not None)
        image_paths += garment_paths
        # Recompose from the user's text with the back-view formula ("shown from
        # behind"), keeping the describe-clothes setting.
        prompt = _recompose_for_row(conn, src, cloth_ids=back_cloth_ids, view="back")
        vto_garment, vto_prompt = _vto_inputs(
            conn, render_ids, "back", image_mode, person_path is not None,
            lambda: _recompose_for_row(conn, src, cloth_ids=back_cloth_ids,
                                       view="back", image_mode="collage",
                                       render_ids=render_ids))
        prompt, image_paths = _append_extra_refs(
            conn, render_ids, prompt, image_paths)
        # Match the front's quality tier (so an HQ front -> HQ back), falling
        # back to flex for legacy rows without one.
        start_tier = src["model_tier"] or "flex"
        cur = conn.execute(
            "INSERT INTO outfits (user_id, model_id, cloth_ids, prompt, model_tier, "
            "view, status, linked_id, describe_clothes, image_mode, render_cloth_ids) "
            "VALUES (?, ?, ?, ?, ?, 'back', 'processing', ?, ?, ?, ?)",
            (user["id"], src["model_id"], src["cloth_ids"], prompt, start_tier, outfit_id,
             1 if _outfit_describes(src) else 0, _outfit_image_mode(src),
             json.dumps(_outfit_render_ids(src))),
        )
        new_id = cur.lastrowid
        # Link both ways so the front and back are one outfit, not two.
        conn.execute("UPDATE outfits SET linked_id = ? WHERE id = ?",
                     (new_id, outfit_id))

    background.add_task(_run_generation, new_id, prompt, image_paths, start_tier,
                        person_path, vto_garment, vto_prompt)
    with get_conn() as conn:
        row = conn.execute("SELECT * FROM outfits WHERE id = ?", (new_id,)).fetchone()
        return _hydrate(conn, row)


@router.post("/{outfit_id}/favorite")
def toggle_favorite(outfit_id: int, req: FavoriteRequest, user=Depends(get_current_user)):
    with get_conn() as conn:
        row = conn.execute(
            "SELECT id, is_favorite FROM outfits WHERE id = ? AND user_id = ?",
            (outfit_id, user["id"]),
        ).fetchone()
        if not row:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Outfit not found")
        new_val = (not bool(row["is_favorite"])) if req.is_favorite is None else bool(req.is_favorite)
        conn.execute("UPDATE outfits SET is_favorite = ? WHERE id = ?", (1 if new_val else 0, outfit_id))
    return {"ok": True, "is_favorite": new_val}


class BlacklistRequest(BaseModel):
    blacklisted: Optional[bool] = None  # None = toggle


@router.post("/{outfit_id}/blacklist")
def toggle_blacklist(outfit_id: int, req: BlacklistRequest,
                     user=Depends(get_current_user)):
    """Ban (or un-ban) this outfit's exact cloth combination so the generator
    never proposes it again. Keyed by the set of clothes, not the outfit row."""
    with get_conn() as conn:
        row = conn.execute(
            "SELECT cloth_ids FROM outfits WHERE id = ? AND user_id = ?",
            (outfit_id, user["id"]),
        ).fetchone()
        if not row:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Outfit not found")
        cloth_ids = json.loads(row["cloth_ids"] or "[]")
        if not cloth_ids:
            raise HTTPException(status.HTTP_400_BAD_REQUEST, "Outfit has no clothes")
        combo = combo_key(cloth_ids)
        currently = conn.execute(
            "SELECT 1 FROM outfit_blacklist WHERE user_id = ? AND combo = ?",
            (user["id"], combo),
        ).fetchone() is not None
        want = (not currently) if req.blacklisted is None else bool(req.blacklisted)
        if want and not currently:
            conn.execute(
                "INSERT OR IGNORE INTO outfit_blacklist (user_id, combo) VALUES (?, ?)",
                (user["id"], combo),
            )
        elif not want and currently:
            conn.execute(
                "DELETE FROM outfit_blacklist WHERE user_id = ? AND combo = ?",
                (user["id"], combo),
            )
    audit_record(user, "outfit.blacklist", f"#{outfit_id} {'on' if want else 'off'}")
    return {"ok": True, "is_blacklisted": want}


class WearRequest(BaseModel):
    day: Optional[str] = None  # 'YYYY-MM-DD'; defaults to today


def _today_iso() -> str:
    from datetime import date
    return date.today().isoformat()


def _mark_clothes_worn(conn, cloth_ids: List[int], user_id: int, day: str) -> int:
    """Set last_worn_at=day on every owned cloth and record the wear (deduped
    per day) so each cloth's detail can show a wear history. Returns count."""
    n = 0
    for cid in cloth_ids:
        cur = conn.execute(
            "UPDATE clothes SET last_worn_at = ?, updated_at = CURRENT_TIMESTAMP "
            "WHERE id = ? AND user_id = ?",
            (day, cid, user_id),
        )
        if cur.rowcount:
            conn.execute(
                "INSERT OR IGNORE INTO cloth_wears (user_id, cloth_id, day) "
                "VALUES (?, ?, ?)",
                (user_id, cid, day),
            )
        n += cur.rowcount
    return n


@router.post("/{outfit_id}/wear")
def wear_outfit(outfit_id: int, req: WearRequest, user=Depends(get_current_user)):
    """Record that the user wore this outfit on a day (default today). Stamps
    last_worn_at on all of the outfit's clothes so the 'not worn recently'
    algorithm and the wardrobe reflect it."""
    from agenda_store import upsert_worn

    day = (req.day or "").strip() or _today_iso()
    with get_conn() as conn:
        row = conn.execute(
            "SELECT cloth_ids FROM outfits WHERE id = ? AND user_id = ?",
            (outfit_id, user["id"]),
        ).fetchone()
        if not row:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Outfit not found")
        cloth_ids = json.loads(row["cloth_ids"] or "[]")
        count = _mark_clothes_worn(conn, cloth_ids, user["id"], day)
        # Log the worn outfit on the agenda for that day.
        upsert_worn(conn, user["id"], day, outfit_id=outfit_id, title="")
    return {"ok": True, "day": day, "clothes_marked": count}


@router.get("/{outfit_id}/wears")
def outfit_wears(outfit_id: int, user=Depends(get_current_user)):
    """Every day the outfit was worn (newest first) + total and this-year count.
    Mirrors the per-cloth wear history."""
    from datetime import date

    with get_conn() as conn:
        owned = conn.execute(
            "SELECT 1 FROM outfits WHERE id = ? AND user_id = ?",
            (outfit_id, user["id"]),
        ).fetchone()
        if not owned:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Outfit not found")
        days = [r["day"] for r in conn.execute(
            "SELECT DISTINCT day FROM agenda "
            "WHERE outfit_id = ? AND worn = 1 ORDER BY day DESC",
            (outfit_id,),
        ).fetchall()]
    year = str(date.today().year)
    return {
        "days": days,
        "total": len(days),
        "this_year": sum(1 for d in days if d.startswith(year)),
    }


@router.get("/favorites/list")
def list_favorites(user=Depends(get_current_user), sort: str = "newest",
                   model: str = "any", limit: Optional[int] = None,
                   offset: int = 0):
    """Favorited outfits. `limit`/`offset` page it, like the history list."""
    where, _ = _outfit_filters(True, model)
    sql = (f"SELECT o.* FROM outfits o WHERE {' AND '.join(where)} "
           f"ORDER BY {_outfit_order(sort)}")
    args: list = [user["id"]]
    if limit is not None:
        sql += " LIMIT ? OFFSET ?"
        args += [max(0, int(limit)), max(0, int(offset))]
    with get_conn() as conn:
        rows = conn.execute(sql, args).fetchall()
        return _hydrate_many(conn, rows)


_ALGO_META = [
    {"id": "same-brand", "label": "Same brand", "needs": "none",
     "desc": "Pick clothes from one brand."},
    {"id": "single-color", "label": "One dominant color", "needs": "none",
     "desc": "Clothes sharing the most common color."},
    {"id": "color-match", "label": "Matching colors", "needs": "none",
     "desc": "Colors that pair well (neutrals, analogous, complementary)."},
    {"id": "matching-tag", "label": "Shared tag", "needs": "none",
     "desc": "Clothes linked by a common custom tag."},
    {"id": "same-cut", "label": "Same cut", "needs": "none",
     "desc": "Same fit: slim / normal / large / oversize."},
    {"id": "least-worn", "label": "Not worn recently", "needs": "none",
     "desc": "Clothes you haven't worn in the longest time (never-worn first)."},
    {"id": "pick-by-color", "label": "Pick a color", "needs": "color",
     "desc": "Only clothes of a color you choose."},
    {"id": "pick-by-brand", "label": "Pick a brand", "needs": "brand",
     "desc": "Only clothes of a brand you choose."},
    {"id": "pick-by-tag", "label": "Pick a tag", "needs": "tag",
     "desc": "Only clothes carrying a tag you choose."},
    {"id": "random", "label": "Random", "needs": "none",
     "desc": "A random wearable outfit."},
]


@router.get("/algos/list")
def list_algos(user=Depends(get_current_user)):
    """Describe the generator algorithms so the UI can render a picker without
    hardcoding them."""
    return {"algos": _ALGO_META, "algos_list": ALGOS}


def _preview_selection(conn, picked: List[dict]) -> List[dict]:
    """Attach a thumbnail URL + label to each picked cloth for the preview UI."""
    out = []
    for c in picked:
        img = conn.execute(
            "SELECT original_path, cutout_path, bg_accepted FROM cloth_images "
            "WHERE cloth_id = ? "
            "ORDER BY CASE role WHEN 'front' THEN 0 ELSE 1 END, sort_order, id LIMIT 1",
            (c["id"],),
        ).fetchone()
        url = public_url_for(_image_file_path(img)) if img else ""
        out.append({
            "id": c["id"], "name": c["name"], "brand": c.get("brand", ""),
            "category": c["category"], "role": c.get("role", ""),
            "thumb_url": url,
        })
    return out


@router.post("/preview-algo")
def preview_algo(req: AlgoRequest, user=Depends(get_current_user)):
    """Run the algorithm `count` times and return the proposed selections
    WITHOUT generating any image. The user confirms which ones to render, then
    the client calls /outfits/generate per selection. Re-running the algo
    yields different picks (for randomized algos), giving variety in a batch."""
    if req.algo not in ALGOS:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, f"Unknown algo '{req.algo}'")
    if req.algo == "pick-by-color" and not req.color.strip():
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "pick-by-color needs a color")
    if req.algo == "pick-by-brand" and not req.brand.strip():
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "pick-by-brand needs a brand")
    if req.algo == "pick-by-tag" and not req.tag.strip():
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "pick-by-tag needs a tag")
    count = max(1, min(int(req.count or 1), 8))
    from generator import GenerateRequest as GenReq
    seen_keys = set()
    selections: List[List[dict]] = []
    labels = []
    # Try up to count*4 draws to get `count` distinct selections.
    for _ in range(count * 4):
        picked = algo_select(GenReq(
            algo=req.algo, min_score=req.min_score, color=req.color,
            brand=req.brand, tag=req.tag, user_id=user["id"], weather=req.weather,
            categories=req.categories, locked_cloth_ids=req.locked_cloth_ids,
            fill_gaps=req.fill_gaps,
        ))
        if not picked:
            continue
        key = tuple(sorted(c["id"] for c in picked))
        if key in seen_keys:
            continue
        seen_keys.add(key)
        selections.append(picked)
        labels.append(algo_explain(picked, req.algo))
        if len(selections) >= count:
            break
    if not selections:
        raise HTTPException(
            status.HTTP_404_NOT_FOUND,
            algo_why_empty(GenReq(
                algo=req.algo, color=req.color, brand=req.brand,
                tag=req.tag, user_id=user["id"])),
        )
    out = []
    for sel in selections:
        with get_conn() as conn:
            out.append(_preview_selection(conn, sel))
    return {
        "algo": req.algo,
        "algo_label": labels[0] if labels else req.algo,
        "selections": out,
    }


@router.post("/generate-from-algo")
def generate_from_algo(req: AlgoRequest, background: BackgroundTasks,
                       user=Depends(get_current_user)):
    """Pick clothes with a generator algorithm, then generate the outfit image.
    The algorithm guarantees no two of the same clothing category, and (when a
    min_score is set) only uses clothes the user rated at or above that score.
    Generation runs in the background (status 'processing' → poll)."""
    if req.algo not in ALGOS:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, f"Unknown algo '{req.algo}'")
    if req.algo == "pick-by-color" and not req.color.strip():
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "pick-by-color needs a color")
    if req.algo == "pick-by-brand" and not req.brand.strip():
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "pick-by-brand needs a brand")
    if req.algo == "pick-by-tag" and not req.tag.strip():
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "pick-by-tag needs a tag")

    from generator import GenerateRequest as GenReq
    picked = algo_select(GenReq(
        algo=req.algo, min_score=req.min_score, color=req.color,
        brand=req.brand, tag=req.tag, user_id=user["id"], weather=req.weather,
        categories=req.categories, locked_cloth_ids=req.locked_cloth_ids,
        fill_gaps=req.fill_gaps,
    ))
    if len(picked) < 1:
        raise HTTPException(
            status.HTTP_404_NOT_FOUND,
            algo_why_empty(GenReq(
                algo=req.algo, color=req.color, brand=req.brand,
                tag=req.tag, user_id=user["id"])),
        )
    cloth_ids = [c["id"] for c in picked]

    with get_conn() as conn:
        model_id = req.model_id
        if req.random_model:
            model_id = _pick_random_model(conn, user["id"], req.random_model_gender)
        elif model_id is not None:
            owned = conn.execute(
                "SELECT 1 FROM models WHERE id = ? AND user_id = ?",
                (model_id, user["id"]),
            ).fetchone()
            if not owned:
                raise HTTPException(status.HTTP_404_NOT_FOUND, "Model not found")
        image_mode = _norm_image_mode(getattr(req, "image_mode", "collage"))
        render_ids = _render_ids(cloth_ids, getattr(req, "render_cloth_ids", []) or [])
        image_paths: List[str] = []
        person_path: Optional[str] = None
        model_used = False
        if model_id is not None:
            mp = _model_path(conn, model_id, user["id"], req.view)
            if mp:
                image_paths.append(mp)
                model_used = True
                person_path = mp
        garment_paths, _sep = _garment_image_paths(
            conn, render_ids, req.view, image_mode,
            person_reserved=person_path is not None)
        image_paths += garment_paths
        _algo_is_back = req.view == "back" and model_used
        _algo_random_person = not model_used and req.random_model
        prompt = _compose_prompt(
            conn, render_ids,
            user_prompt=(req.prompt or "").strip(),
            has_model=model_used,
            is_back=_algo_is_back,
            random_person=_algo_random_person,
            describe=req.describe_clothes,
            image_mode=image_mode,
        )
        vto_garment, vto_prompt = _vto_inputs(
            conn, render_ids, req.view, image_mode, model_used,
            lambda: _compose_prompt(
                conn, render_ids, user_prompt=(req.prompt or "").strip(),
                has_model=model_used, is_back=_algo_is_back,
                random_person=_algo_random_person, describe=req.describe_clothes,
                image_mode="collage"))
        prompt, image_paths = _append_extra_refs(conn, render_ids, prompt, image_paths)
        view = req.view if model_id is not None else "front"
        start_tier = _fresh_start_tier(req.tier, person_path)
        cur = conn.execute(
            "INSERT INTO outfits (user_id, model_id, cloth_ids, prompt, model_tier, "
            "view, status, describe_clothes, image_mode, render_cloth_ids) "
            "VALUES (?, ?, ?, ?, ?, ?, 'processing', ?, ?, ?)",
            (user["id"], model_id, json.dumps(cloth_ids), prompt, start_tier, view,
             1 if req.describe_clothes else 0, image_mode, json.dumps(render_ids)),
        )
        outfit_id = cur.lastrowid
        conn.execute(
            "UPDATE users SET outfits_generated = outfits_generated + 1 WHERE id = ?",
            (user["id"],))

    background.add_task(_run_generation, outfit_id, prompt, image_paths, start_tier,
                        person_path, vto_garment, vto_prompt)
    with get_conn() as conn:
        row = conn.execute("SELECT * FROM outfits WHERE id = ?", (outfit_id,)).fetchone()
        out = _hydrate(conn, row)
    out["algo"] = req.algo
    out["algo_label"] = algo_explain(picked, req.algo)
    out["picked_names"] = [c["name"] for c in picked]
    return out


@router.post("/{outfit_id}/report")
def report(outfit_id: int, req: ReportRequest, user=Depends(get_current_user)):
    """User reports a bad/failed generation to support."""
    with get_conn() as conn:
        row = conn.execute(
            "SELECT * FROM outfits WHERE id = ? AND user_id = ?",
            (outfit_id, user["id"]),
        ).fetchone()
        if not row:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Outfit not found")
        msg = (req.message or "").strip() or "User reported a bad/failed generation."
        conn.execute(
            "INSERT INTO outfit_reports (user_id, outfit_id, tier, slug, message) "
            "VALUES (?, ?, ?, ?, ?)",
            (user["id"], outfit_id, row["model_tier"], row["model_slug"], msg),
        )
        tier = row["model_tier"]
        stat = row["status"]
    # Push a real-time alert to admins (in addition to the DB record above).
    from notify import notify_admins
    notify_admins(
        "Outfit generation reported",
        f"{user['email']} reported outfit #{outfit_id} "
        f"(tier {tier}, status {stat}): {msg}",
    )
    return {"ok": True}


@router.delete("/{outfit_id}")
def delete_outfit(outfit_id: int, user=Depends(get_current_user)):
    with get_conn() as conn:
        row = conn.execute(
            "SELECT generated_path FROM outfits WHERE id = ? AND user_id = ?",
            (outfit_id, user["id"]),
        ).fetchone()
        if not row:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Outfit not found")
        path = row["generated_path"]
        conn.execute("DELETE FROM outfits WHERE id = ?", (outfit_id,))
    if path:
        Path(path).unlink(missing_ok=True)
    audit_record(user, "outfit.delete", f"#{outfit_id}")
    return {"ok": True}