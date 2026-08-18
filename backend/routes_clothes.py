import json
import logging
import os
import shutil
import tempfile
from pathlib import Path
from typing import List, Optional

from fastapi import (
    APIRouter,
    BackgroundTasks,
    Depends,
    File,
    Form,
    HTTPException,
    UploadFile,
    status,
)
from fastapi.concurrency import run_in_threadpool
from pydantic import BaseModel

from audit import record as audit_record
from auth import get_current_user
from bfl import next_tier
from db import clamp_page, get_conn
from generator import (KNOWN_CATEGORIES, has_cut, is_multi_angle,
                       normalize_category)
from config import STAGING_DIR
from ratelimit import enhance_guard
from routes_thumbs import thumb_url_for
from uploads import UploadBudget, check_count, read_capped, verify_image
from images import (
    canonical_cutout_path,
    cloth_dir,
    detect_colors,
    link_bytes,
    public_url_for,
    remove_background,
    remove_cloth_files,
    save_original,
    transform_image,
)

router = APIRouter(prefix="/clothes", tags=["clothes"])
log = logging.getLogger(__name__)

VALID_CUTS = {"slim", "normal", "large", "oversize"}
VALID_DOMINANCE = {"full", "part", "little"}
VALID_ROLES = {"front", "back", "extra"}


def _norm_brand(brand: Optional[str]) -> str:
    """Brands are stored UPPERCASE so 'nike', 'Nike' and 'NIKE' are one brand."""
    return (brand or "").strip().upper()


def _norm_name(name: Optional[str]) -> str:
    """Cloth names are stored lowercase for a consistent, tidy wardrobe."""
    return (name or "").strip().lower()


def _parse_list(raw: Optional[str]) -> List[str]:
    if not raw:
        return []
    try:
        v = json.loads(raw)
    except (ValueError, TypeError):
        return []
    if not isinstance(v, list):
        return []
    return [str(x).strip() for x in v if isinstance(x, (str, int, float)) and str(x).strip()]


def _parse_colors(raw: Optional[str]) -> List[dict]:
    """Colors arrive as a JSON list of {color, dominance}."""
    if not raw:
        return []
    try:
        v = json.loads(raw)
    except (ValueError, TypeError):
        return []
    out = []
    if not isinstance(v, list):
        return out
    for item in v:
        if not isinstance(item, dict):
            continue
        color = str(item.get("color", "")).strip()
        dominance = str(item.get("dominance", "")).strip().lower()
        if not color:
            continue
        if dominance not in VALID_DOMINANCE:
            dominance = "part"
        out.append({"color": color, "dominance": dominance})
    return out


def _encode_only(dest_dir: Path, role: str, slot, data: bytes) -> dict:
    """Encode one uploaded photo. No cut-out — that happens later, in the
    background (see _run_cutouts).

    ``slot`` is the filename discriminator — the sort order for a fresh upload,
    or a longer unique token when replacing an existing image.

    Still blocking: PIL re-encoding of a 12-megapixel photo is a few hundred
    milliseconds. Callers must run this in a worker thread and must not hold a
    DB transaction across it.
    """
    original = save_original(data, dest_dir / f"{role}_{slot}")
    return {"role": role, "sort_order": slot, "original": original,
            # Until the cut-out exists, the original stands in for it. The app
            # shows this, marked as still processing, instead of a blank card.
            "cutout": original}


def _process_upload(dest_dir: Path, role: str, slot, data: bytes) -> dict:
    """Encode one uploaded photo and produce its cut-out, synchronously.

    Kept for the paths where the caller genuinely has to wait for the result —
    replacing a single photo, where the app shows the new cut-out immediately.
    A fresh garment goes through _encode_only instead.
    """
    staged = _encode_only(dest_dir, role, slot, data)
    original = staged["original"]
    cutout = dest_dir / f"{role}_{slot}_cutout.webp"
    try:
        remove_background(original, cutout)
    except Exception as e:  # pragma: no cover - keep the upload either way
        log.warning("background removal failed for %s: %s", original.name, e)
        # Fall back to the encoded original. It is content-addressed, so this
        # links to the same inode rather than duplicating the bytes.
        cutout = link_bytes(original.read_bytes(), cutout.with_suffix(original.suffix))
    return {**staged, "cutout": cutout}


def _stage_uploads(stage: Path, payloads, *, with_cutout: bool = True) -> List[dict]:
    """Process every upload of a request into ``stage``.

    In parallel, because most of the work is not the part that has to be
    serialised. PIL releases the GIL while it re-encodes.

    ``with_cutout=False`` does the encoding only and leaves the cut-out to a
    background task — the fresh-garment path, where nobody should be made to
    wait ten seconds for a picture they already chose.
    """
    work = _process_upload if with_cutout else _encode_only
    if len(payloads) < 2:
        return [work(stage, role, idx, data) for role, idx, data in payloads]

    from concurrent.futures import ThreadPoolExecutor

    with ThreadPoolExecutor(max_workers=min(4, len(payloads))) as pool:
        futures = [pool.submit(work, stage, role, idx, data)
                   for role, idx, data in payloads]
        # Order matters: it decides front/back and the sort order.
        return [f.result() for f in futures]


def _run_cutouts(image_ids: List[int]) -> None:
    """Cut out photos that were uploaded without waiting, then mark them ready.

    Runs as a BackgroundTasks job, so it starts only after the response has
    reached the client — the point of the exercise.

    Each image is committed on its own: the front photo appears cut out while
    the back is still going, and one failure does not discard the other's work.
    """
    for image_id in image_ids:
        with get_conn() as conn:
            row = conn.execute(
                "SELECT original_path FROM cloth_images WHERE id = ?", (image_id,)
            ).fetchone()
        if not row:
            continue                       # deleted while we were queued
        original = Path(row["original_path"])
        dst = canonical_cutout_path(original)
        try:
            remove_background(original, dst)
            status_, path_ = "ready", str(dst)
        except Exception as e:
            # The garment keeps its original photo and says so. Losing the
            # cut-out is a degraded picture; losing the garment is losing data.
            log.warning("background removal failed for image %s: %s", image_id, e)
            status_, path_ = "failed", str(original)
        with get_conn() as conn:
            conn.execute(
                "UPDATE cloth_images SET cutout_path = ?, cutout_status = ? "
                "WHERE id = ?", (path_, status_, image_id))
        # Render the grid sizes here rather than on the first screen that asks
        # for them: this job is already off the request path and already has
        # the file open. ~99 ms a thumbnail is time the user does not spend
        # staring at an empty grid.
        try:
            from routes_thumbs import prewarm
            prewarm(Path(path_))
        except Exception as e:  # noqa: BLE001 - never fail a cut-out over this
            log.info("thumbnail pre-warm skipped for image %s: %s", image_id, e)


def _move_staged(cloth_id: int, staged: List[dict]) -> List[dict]:
    """Move staged files into the cloth's own directory. Same filesystem, so
    each move is a rename — instant, unlike the encoding that produced them."""
    cdir = cloth_dir(cloth_id)
    for s in staged:
        moved: dict[Path, Path] = {}
        for key in ("original", "cutout"):
            src = s[key]
            # An upload staged without its cut-out yet has both keys pointing at
            # the same file, and moving it twice raises FileNotFoundError on the
            # second go — the first rename already took the source away.
            if src in moved:
                s[key] = moved[src]
                continue
            dst = cdir / src.name
            os.replace(src, dst)
            moved[src] = dst
            s[key] = dst
    return staged


def _sweep_stalled_enhancements(conn) -> None:
    """Turn enhancements that are no longer running into 'failed', before the
    caller reads them.

    Runs on the read path on purpose. The app polls this endpoint while an
    enhancement is going, so a job whose worker died — or one that outlived its
    budget — becomes visibly failed on the next poll instead of spinning until
    somebody restarts the server. Cheap: an indexed scan of the rows that are
    'processing', which is normally none.
    """
    from config import CUTOUT_TIMEOUT_S, ENHANCE_TIMEOUT_S
    from db import fail_stale_cutouts, fail_stale_enhancements

    try:
        fail_stale_enhancements(conn, ENHANCE_TIMEOUT_S)
    except Exception as e:  # noqa: BLE001 - reading a cloth must not fail on this
        log.warning("stalled-enhancement sweep failed: %s", e)
    try:
        # Same treatment for background removal: its job can die the same way,
        # and a cut-out stuck on 'processing' keeps cutout_path aliased to the
        # original, which used to make rejecting the background destructive.
        fail_stale_cutouts(conn, CUTOUT_TIMEOUT_S)
    except Exception as e:  # noqa: BLE001
        log.warning("stalled-cutout sweep failed: %s", e)


def _load_cloth(conn, cloth_id: int, user_id: int) -> dict:
    _sweep_stalled_enhancements(conn)
    row = conn.execute(
        "SELECT * FROM clothes WHERE id = ? AND user_id = ?", (cloth_id, user_id)
    ).fetchone()
    if not row:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Cloth not found")
    return _hydrate(conn, row)


def _build_cloth(row, images, colors) -> dict:
    """Assemble the cloth response dict from an already-fetched row + its
    image/color rows. Shared by the single-item and batched (list) paths."""
    return {
        "id": row["id"],
        "user_id": row["user_id"],
        "name": row["name"],
        "brand": row["brand"],
        "cut": row["cut"],
        "category": row["category"],
        "custom_tags": json.loads(row["custom_tags"] or "[]"),
        "score": row["score"] if "score" in row.keys() else 0,
        "last_worn_at": row["last_worn_at"] if "last_worn_at" in row.keys() else None,
        "is_favorite": bool(row["is_favorite"]) if "is_favorite" in row.keys() else False,
        "exclude_from_algo": bool(row["exclude_from_algo"])
        if "exclude_from_algo" in row.keys() else False,
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
        "colors": [{"id": c["id"], "color": c["color"], "dominance": c["dominance"]}
                   for c in colors],
        "images": [
            {
                "id": im["id"],
                "role": im["role"],
                "sort_order": im["sort_order"],
                "bg_accepted": im["bg_accepted"],
                # 'processing' while the cut-out is still being made, so the app
                # can show the garment straight away and say what is happening
                # rather than holding the screen for it.
                "cutout_status": (im["cutout_status"]
                                  if "cutout_status" in im.keys() else None) or "ready",
                "bg_tolerance": im["bg_tolerance"]
                if "bg_tolerance" in im.keys() else "medium",
                "original_url": public_url_for(im["original_path"]),
                # If the background was rejected, the "cutout" is just the
                # original (no bg removal), so the app shows the untouched photo.
                "cutout_url": public_url_for(
                    im["cutout_path"] if im["bg_accepted"] != "rejected" else im["original_path"]
                ),
                # Grid-sized copy of whatever cutout_url points at. The wardrobe
                # grid renders ~200 logical px per card but was pulling the full
                # 1600 px image for each one.
                "thumb_url": thumb_url_for(
                    im["cutout_path"] if im["bg_accepted"] != "rejected" else im["original_path"],
                    400,
                ),
                # Detail-screen size. A phone shows this at most a screen wide,
                # where 800 px is indistinguishable from the stored image —
                # 86 KB against 1005 KB for the lossless original.
                "preview_url": thumb_url_for(
                    im["cutout_path"] if im["bg_accepted"] != "rejected" else im["original_path"],
                    800,
                ),
                # The two sides of the keep-cut-out-or-original comparison, at
                # screen size. Shown as a pair of small panels, so pulling the
                # stored files for them cost about 2 MB per decision.
                "original_preview_url": thumb_url_for(im["original_path"], 800),
                "cutout_preview_url": thumb_url_for(im["cutout_path"], 800),
                "enhanced_url": public_url_for(im["enhanced_path"])
                if ("enhanced_path" in im.keys() and im["enhanced_path"]) else "",
                # The AI result, at screen size. It was the one image left
                # loading at full resolution after everything else moved to
                # /thumb: 413 KB against 75 KB, and it is the image someone is
                # actively waiting on to decide whether to keep it.
                "enhanced_preview_url": thumb_url_for(im["enhanced_path"], 800)
                if ("enhanced_path" in im.keys() and im["enhanced_path"]) else "",
                "enhance_status": im["enhance_status"]
                if "enhance_status" in im.keys() else None,
                "enhance_method": im["enhance_method"]
                if "enhance_method" in im.keys() else "none",
                "enhance_pending_method": im["enhance_pending_method"]
                if "enhance_pending_method" in im.keys() else None,
                "enhance_tier": im["enhance_tier"]
                if "enhance_tier" in im.keys() else None,
                "enhance_next_tier": next_tier(im["enhance_tier"])
                if ("enhance_tier" in im.keys() and im["enhance_tier"]) else None,
                # Why the last attempt failed, in the server's own words. Shown
                # to the user: "sans cesse fail" with no reason is unactionable.
                "enhance_error": (im["enhance_error"]
                                  if "enhance_error" in im.keys() else None),
                # NULL (never chosen) reads as the default, which is to describe.
                "enhance_describe": (
                    True if ("enhance_describe" not in im.keys()
                             or im["enhance_describe"] is None)
                    else bool(im["enhance_describe"])),
            }
            for im in images
        ],
    }


def _hydrate(conn, row) -> dict:
    cloth_id = row["id"]
    images = conn.execute(
        "SELECT id, role, original_path, cutout_path, sort_order, bg_accepted, bg_tolerance, "
        "enhanced_path, enhance_status, enhance_method, enhance_pending_method, enhance_tier, enhance_error, enhance_describe, cutout_status "
        "FROM cloth_images WHERE cloth_id = ? ORDER BY sort_order, id",
        (cloth_id,),
    ).fetchall()
    colors = conn.execute(
        "SELECT id, color, dominance FROM cloth_colors WHERE cloth_id = ? ORDER BY id",
        (cloth_id,),
    ).fetchall()
    return _build_cloth(row, images, colors)


def _hydrate_many(conn, rows) -> list:
    """Hydrate a list of cloth rows with just two grouped queries instead of the
    two-per-cloth the single-item path would issue (the collection screen loads
    the whole wardrobe, so this was the hottest N+1)."""
    if not rows:
        return []
    from collections import defaultdict

    ids = [r["id"] for r in rows]
    placeholders = ",".join("?" * len(ids))
    imgs_by = defaultdict(list)
    for im in conn.execute(
        "SELECT cloth_id, id, role, original_path, cutout_path, sort_order, bg_accepted, bg_tolerance, "
        "enhanced_path, enhance_status, enhance_method, enhance_pending_method, enhance_tier, enhance_error, enhance_describe, cutout_status "
        f"FROM cloth_images WHERE cloth_id IN ({placeholders}) ORDER BY sort_order, id",
        ids,
    ).fetchall():
        imgs_by[im["cloth_id"]].append(im)
    cols_by = defaultdict(list)
    for c in conn.execute(
        "SELECT cloth_id, id, color, dominance "
        f"FROM cloth_colors WHERE cloth_id IN ({placeholders}) ORDER BY id",
        ids,
    ).fetchall():
        cols_by[c["cloth_id"]].append(c)
    return [_build_cloth(r, imgs_by.get(r["id"], []), cols_by.get(r["id"], []))
            for r in rows]


def _build_query(user_id: int, params) -> tuple[str, list]:
    where = ["c.user_id = ?"]
    args: list = [user_id]

    search = params.get("search")
    if search:
        # Match the query against the name, brand, category key, and custom tags
        # (LIKE is case-insensitive for ASCII in SQLite).
        pat = f"%{search}%"
        where.append(
            "(c.name LIKE ? OR c.brand LIKE ? OR c.category LIKE ? "
            "OR c.custom_tags LIKE ?)")
        args += [pat, pat, pat, pat]

    brand = params.get("brand")
    if brand:
        where.append("UPPER(c.brand) = UPPER(?)")
        args.append(brand)

    cut = params.get("cut")
    if cut:
        where.append("c.cut = ?")
        args.append(cut)

    category = params.get("category")
    if category:
        where.append("c.category = ?")
        args.append(category)

    color = params.get("color")
    if color:
        where.append(
            "EXISTS (SELECT 1 FROM cloth_colors cc WHERE cc.cloth_id = c.id AND cc.color = ?)"
        )
        args.append(color)

    tag = params.get("tag")
    if tag:
        # JSON array stored as text — LIKE is good enough for tag matching.
        where.append("c.custom_tags LIKE ?")
        args.append(f'%"{tag}"%')

    order = "c.created_at DESC"
    join = ""
    sort = params.get("sort")
    if sort == "name":
        order = "c.name COLLATE NOCASE ASC"
    elif sort == "brand":
        order = "c.brand COLLATE NOCASE ASC, c.created_at DESC"
    elif sort == "score":
        order = "c.score DESC, c.created_at DESC"
    elif sort == "score_asc":
        order = "c.score ASC, c.created_at DESC"
    elif sort == "category":
        order = "c.category COLLATE NOCASE ASC, c.name COLLATE NOCASE ASC"
    elif sort in ("worn", "worn_asc"):
        # Times worn = number of recorded wear-days for the cloth. Aggregate
        # once and join, rather than a correlated COUNT(*) re-run per row.
        direction = "ASC" if sort == "worn_asc" else "DESC"
        join = (" LEFT JOIN (SELECT cloth_id, COUNT(*) AS wear_count "
                "FROM cloth_wears GROUP BY cloth_id) w ON w.cloth_id = c.id")
        order = f"COALESCE(w.wear_count, 0) {direction}, c.created_at DESC"

    # Rating filter: min_score>0 means "only clothes rated >= this" (excludes
    # unrated score-0 clothes). min_score==0 keeps everything.
    min_score = params.get("min_score")
    try:
        min_score = int(min_score) if min_score not in (None, "") else 0
    except (TypeError, ValueError):
        min_score = 0
    if min_score and min_score > 0:
        where.append("c.score >= ?")
        args.append(int(min_score))

    if params.get("favorite"):
        where.append("c.is_favorite = 1")

    sql = (
        "SELECT c.* FROM clothes c"
        + join
        + " WHERE "
        + " AND ".join(where)
        + f" ORDER BY {order}"
    )
    return sql, args


@router.get("")
def list_clothes(
    user=Depends(get_current_user),
    search: Optional[str] = None,
    brand: Optional[str] = None,
    color: Optional[str] = None,
    cut: Optional[str] = None,
    category: Optional[str] = None,
    tag: Optional[str] = None,
    sort: Optional[str] = None,
    min_score: Optional[int] = None,
    favorite: Optional[bool] = None,
    limit: Optional[int] = None,
    offset: int = 0,
):
    """List clothes. `limit`/`offset` page the result (omit `limit` for all);
    the client loads pages as the grid scrolls so a large wardrobe never ships
    in one unbounded response. `favorite=true` restricts to favorited clothes."""
    sql, args = _build_query(
        user["id"],
        {"search": search, "brand": brand, "color": color, "cut": cut,
         "category": category, "tag": tag, "sort": sort, "min_score": min_score,
         "favorite": favorite},
    )
    # Always bounded: "no limit" is a ceiling, not an invitation to build a
    # response of arbitrary size (see db.clamp_page).
    lim, off = clamp_page(limit, offset)
    sql += " LIMIT ? OFFSET ?"
    args += [lim, off]
    with get_conn() as conn:
        rows = conn.execute(sql, args).fetchall()
        return _hydrate_many(conn, rows)


# Clamped so a caller cannot ask for "dormant since 0 months ago", which would
# return the whole wardrobe under a name that means the opposite.
_DORMANT_MIN_MONTHS = 1
_DORMANT_MAX_MONTHS = 60
_DORMANT_DEFAULT_MONTHS = 6

# Never-worn clothes are judged on a different clock, and this is why:
#
# The first version ran ONE rule — "untouched since `months` ago, counting from
# the day it was added when it was never worn". On a wardrobe younger than the
# threshold that answers "nothing is forgotten" for every garment, including a
# hundred that have never once been put on. Reported, and correct: the screen is
# called "never worn" and it showed an empty list next to a full wardrobe.
#
# So: something never worn qualifies after a short grace period — long enough
# not to nag about this week's uploads, short enough that a new wardrobe still
# gets an answer. Something worn and then dropped is judged on `months`, which
# is the question that needs a real interval behind it.
_NEVER_WORN_GRACE_DAYS = 21


# Declared before /{cloth_id}: FastAPI matches in order, and "dormant" would
# otherwise be read as a cloth id and rejected as a bad integer.
@router.get("/dormant")
def dormant_clothes(
    user=Depends(get_current_user),
    months: int = _DORMANT_DEFAULT_MONTHS,
    limit: Optional[int] = None,
    offset: int = 0,
):
    """Clothes nobody is wearing, longest-forgotten first.

    Two kinds, on two clocks (see _NEVER_WORN_GRACE_DAYS):

      * never worn — in the wardrobe for more than the grace period and still
        never once put on;
      * worn, then dropped — last worn more than ``months`` ago.

    ``dormant_days`` counts from the last wear, or from the day it was added for
    something never worn, so both kinds sort on one axis.

    Returns the wardrobe totals alongside the items so the screen can say "38 of
    150" without a second request.
    """
    # A non-integer is rejected by FastAPI before this runs (422); an integer
    # outside the useful range is clamped rather than refused.
    months = max(_DORMANT_MIN_MONTHS, min(_DORMANT_MAX_MONTHS, months))

    # date(): created_at carries a time, last_worn_at does not — comparing them
    # as they are stored would make '2026-01-02 00:00:00' look later than
    # '2026-01-02'.
    since = "COALESCE(c.last_worn_at, date(c.created_at))"
    where = (
        "c.user_id = ? AND ("
        "  (c.last_worn_at IS NULL AND date(c.created_at) <= date('now', ?))"
        "  OR (c.last_worn_at IS NOT NULL AND c.last_worn_at <= date('now', ?))"
        ")"
    )
    filter_args = [user["id"], f"-{_NEVER_WORN_GRACE_DAYS} days", f"-{months} months"]
    sql = (
        f"SELECT c.*, {since} AS dormant_since, "
        f"CAST(julianday('now') - julianday({since}) AS INTEGER) AS dormant_days, "
        "c.last_worn_at IS NULL AS never_worn, "
        "COALESCE(w.n, 0) AS times_worn "
        "FROM clothes c "
        "LEFT JOIN (SELECT cloth_id, COUNT(*) AS n FROM cloth_wears "
        "           GROUP BY cloth_id) w ON w.cloth_id = c.id "
        f"WHERE {where} "
        "ORDER BY dormant_days DESC, c.name COLLATE NOCASE ASC"
    )
    args: list = list(filter_args)
    # Always bounded: "no limit" is a ceiling, not an invitation to build a
    # response of arbitrary size (see db.clamp_page).
    lim, off = clamp_page(limit, offset)
    sql += " LIMIT ? OFFSET ?"
    args += [lim, off]

    with get_conn() as conn:
        rows = conn.execute(sql, args).fetchall()
        items = _hydrate_many(conn, rows)
        # strict: a hydrate that dropped a row would otherwise attach
        # dormant_days to the WRONG garment, silently.
        for item, row in zip(items, rows, strict=True):
            item["dormant_days"] = int(row["dormant_days"] or 0)
            item["dormant_since"] = row["dormant_since"]
            item["never_worn"] = bool(row["never_worn"])
            item["times_worn"] = int(row["times_worn"] or 0)
        total = conn.execute(
            "SELECT COUNT(*) AS n FROM clothes WHERE user_id = ?", (user["id"],)
        ).fetchone()["n"]
        # Counted over everything that matches, which paging must not change:
        # the header says "38 dormant", not "38 on this page". Split by kind so
        # the screen can head each group without counting the page it was sent.
        counts = conn.execute(
            f"SELECT COUNT(*) AS n, "
            f"SUM(CASE WHEN c.last_worn_at IS NULL THEN 1 ELSE 0 END) AS never "
            f"FROM clothes c WHERE {where}",
            filter_args,
        ).fetchone()
        dormant_total = counts["n"] or 0
        never_total = counts["never"] or 0
    return {
        "months": months,
        "grace_days": _NEVER_WORN_GRACE_DAYS,
        "count": dormant_total,
        "never_worn_count": never_total,
        "stale_count": dormant_total - never_total,
        "wardrobe_count": total,
        "items": items,
    }


@router.get("/{cloth_id}")
def get_cloth(cloth_id: int, user=Depends(get_current_user)):
    with get_conn() as conn:
        return _load_cloth(conn, cloth_id, user["id"])


@router.post("")
async def create_cloth(
    background: BackgroundTasks,
    user=Depends(get_current_user),
    name: str = Form(...),
    brand: str = Form(""),
    cut: str = Form("normal"),
    category: str = Form(""),
    colors: str = Form("[]"),
    tags: str = Form("[]"),
    images: List[UploadFile] = File(...),
):
    name = _norm_name(name)
    if not name:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Name is required")
    category = normalize_category(category)
    if category and category not in KNOWN_CATEGORIES:
        # Not fatal: an older client may know a category this server does not.
        # But it lands in role "other", so it must be visible in the log rather
        # than silently changing the photo rule and the layering.
        log.warning("unknown category %r on create by user %s",
                    category, user["id"])
    # Shoes / bags / accessories are photographed from arbitrary angles, so they
    # only need one photo; regular garments still need a front + back pair (used
    # to render front and back outfit views).
    multi_angle = is_multi_angle(category)
    min_images = 1 if multi_angle else 2
    if len(images) < min_images:
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST,
            "At least one picture is required" if multi_angle
            else "Front and back pictures are required",
        )
    # Shoes / bags / accessories have no garment cut — store it empty. Otherwise
    # coerce an unrecognised value to 'normal'.
    if not has_cut(category):
        cut = ""
    elif cut not in VALID_CUTS:
        cut = "normal"

    color_list = _parse_colors(colors)
    tag_list = _parse_list(tags)

    # Multi-angle items: the first photo is the display anchor ("front"), the
    # rest are interchangeable angle shots. Garments keep the front/back pair.
    if multi_angle:
        roles = ["front"] + ["extra"] * max(0, len(images) - 1)
    else:
        roles = ["front", "back"] + ["extra"] * max(0, len(images) - 2)

    # Drain the uploads first: reading the request body is the only part that
    # genuinely belongs on the event loop.
    check_count(images)
    budget = UploadBudget()
    payloads = []
    for idx, (role, upload) in enumerate(zip(roles, images, strict=True)):
        data = await read_capped(upload, budget=budget)
        if data:
            verify_image(data)
            payloads.append((role, idx, data))
    if not payloads:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Empty image upload")

    # Encode + background-remove into a staging dir, off the event loop and
    # outside any transaction — this is seconds of ONNX inference per photo and
    # used to freeze the whole server (and hold the SQLite write lock) for it.
    stage = Path(tempfile.mkdtemp(dir=STAGING_DIR))
    try:
        # Encoding only. Background removal is ~5 s a photo on the deployment
        # server and a garment has two, which is the fifteen seconds the whole
        # screen used to sit frozen for. It is queued below instead.
        staged = await run_in_threadpool(_stage_uploads, stage, payloads,
                                         with_cutout=False)
        pending_ids = []
        with get_conn() as conn:
            cur = conn.execute(
                "INSERT INTO clothes (user_id, name, brand, cut, category, custom_tags) "
                "VALUES (?, ?, ?, ?, ?, ?)",
                (
                    user["id"],
                    name,
                    _norm_brand(brand),
                    cut,
                    category,
                    json.dumps(tag_list),
                ),
            )
            cloth_id = cur.lastrowid
            for s in _move_staged(cloth_id, staged):
                cur = conn.execute(
                    "INSERT INTO cloth_images "
                    "(cloth_id, role, original_path, cutout_path, sort_order, "
                    " cutout_status, cutout_started_at) "
                    "VALUES (?, ?, ?, ?, ?, 'processing', datetime('now'))",
                    (cloth_id, s["role"], str(s["original"]), str(s["cutout"]),
                     s["sort_order"]),
                )
                pending_ids.append(cur.lastrowid)
            for c in color_list:
                conn.execute(
                    "INSERT INTO cloth_colors (cloth_id, color, dominance) VALUES (?, ?, ?)",
                    (cloth_id, c["color"], c["dominance"]),
                )
            row = conn.execute(
                "SELECT * FROM clothes WHERE id = ?", (cloth_id,)
            ).fetchone()
            result = _hydrate(conn, row)
    finally:
        shutil.rmtree(stage, ignore_errors=True)
    audit_record(user, "cloth.create", f"#{cloth_id} {name!r}")
    # Queued after the transaction and after the response: BackgroundTasks runs
    # once the body has been sent, so the app already has its garment.
    background.add_task(_run_cutouts, pending_ids)
    return result


@router.put("/{cloth_id}")
async def update_cloth(
    cloth_id: int,
    user=Depends(get_current_user),
    name: Optional[str] = Form(None),
    brand: Optional[str] = Form(None),
    cut: Optional[str] = Form(None),
    category: Optional[str] = Form(None),
    colors: Optional[str] = Form(None),
    tags: Optional[str] = Form(None),
    score: Optional[int] = None,
):
    with get_conn() as conn:
        existing = conn.execute(
            "SELECT 1 FROM clothes WHERE id = ? AND user_id = ?", (cloth_id, user["id"])
        ).fetchone()
        if not existing:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Cloth not found")

        fields = []
        args = []
        if name is not None:
            fields.append("name = ?")
            args.append(_norm_name(name))
        if brand is not None:
            fields.append("brand = ?")
            args.append(_norm_brand(brand))
        if category is not None:
            category = normalize_category(category)
            if category and category not in KNOWN_CATEGORIES:
                log.warning("unknown category %r on update by user %s",
                            category, user["id"])
        # The cut is derived from the category, so it has to be recomputed when
        # EITHER changes. Recomputing only when the client also sent a cut left
        # a stale cut="normal" on a garment moved to a no-cut category — a
        # combination create_cloth refuses.
        if cut is not None or category is not None:
            eff_cat = category or conn.execute(
                "SELECT category FROM clothes WHERE id = ?", (cloth_id,)
            ).fetchone()["category"]
            if cut is None:
                cut = conn.execute(
                    "SELECT cut FROM clothes WHERE id = ?", (cloth_id,)
                ).fetchone()["cut"]
            if not has_cut(eff_cat or ""):
                cut = ""
            elif cut not in VALID_CUTS:
                cut = "normal"
            fields.append("cut = ?")
            args.append(cut)
        if category is not None:
            fields.append("category = ?")
            args.append(category)
        if tags is not None:
            fields.append("custom_tags = ?")
            args.append(json.dumps(_parse_list(tags)))
        if score is not None:
            if score < 0:
                score = 0
            if score > 5:
                score = 5
            fields.append("score = ?")
            args.append(int(score))
        if fields:
            fields.append("updated_at = CURRENT_TIMESTAMP")
            args.append(cloth_id)
            conn.execute(f"UPDATE clothes SET {', '.join(fields)} WHERE id = ?", args)

        if colors is not None:
            conn.execute("DELETE FROM cloth_colors WHERE cloth_id = ?", (cloth_id,))
            for c in _parse_colors(colors):
                conn.execute(
                    "INSERT INTO cloth_colors (cloth_id, color, dominance) VALUES (?, ?, ?)",
                    (cloth_id, c["color"], c["dominance"]),
                )

        row = conn.execute("SELECT * FROM clothes WHERE id = ?", (cloth_id,)).fetchone()
        return _hydrate(conn, row)


class ScoreRequest(BaseModel):
    score: int


@router.patch("/{cloth_id}/score")
def set_score(cloth_id: int, req: ScoreRequest, user=Depends(get_current_user)):
    s = max(0, min(5, int(req.score)))
    with get_conn() as conn:
        row = conn.execute(
            "SELECT id, score FROM clothes WHERE id = ? AND user_id = ?",
            (cloth_id, user["id"]),
        ).fetchone()
        if not row:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Cloth not found")
        conn.execute("UPDATE clothes SET score = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?",
                     (s, cloth_id))
    return {"ok": True, "score": s}


class WearRequest(BaseModel):
    day: Optional[str] = None  # 'YYYY-MM-DD'; defaults to today (server date)


def _today() -> str:
    from datetime import date
    return date.today().isoformat()


@router.post("/{cloth_id}/wear")
def wear_cloth(cloth_id: int, req: WearRequest, user=Depends(get_current_user)):
    """Record that the user wore this cloth on a given day (default today).
    Feeds the 'not worn recently' generator algorithm and logs a worn entry in
    the agenda for that day."""
    from agenda_store import upsert_worn, valid_day

    day = valid_day((req.day or "").strip() or _today())
    with get_conn() as conn:
        row = conn.execute(
            "SELECT id, name FROM clothes WHERE id = ? AND user_id = ?",
            (cloth_id, user["id"]),
        ).fetchone()
        if not row:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Cloth not found")
        conn.execute(
            "UPDATE clothes SET last_worn_at = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?",
            (day, cloth_id),
        )
        # Record the wear (deduped per day) so the detail can show a history.
        conn.execute(
            "INSERT OR IGNORE INTO cloth_wears (user_id, cloth_id, day) VALUES (?, ?, ?)",
            (user["id"], cloth_id, day),
        )
        # Show it on the agenda for that day (as a standalone worn item).
        upsert_worn(conn, user["id"], day, outfit_id=None, title=row["name"])
    return {"ok": True, "last_worn_at": day}


class FavoriteRequest(BaseModel):
    is_favorite: Optional[bool] = None  # None = toggle


@router.post("/{cloth_id}/favorite")
def toggle_cloth_favorite(cloth_id: int, req: FavoriteRequest,
                          user=Depends(get_current_user)):
    """Favorite/unfavorite a cloth (independent of outfit favorites)."""
    with get_conn() as conn:
        row = conn.execute(
            "SELECT is_favorite FROM clothes WHERE id = ? AND user_id = ?",
            (cloth_id, user["id"]),
        ).fetchone()
        if not row:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Cloth not found")
        new_val = (not bool(row["is_favorite"])) if req.is_favorite is None \
            else bool(req.is_favorite)
        conn.execute("UPDATE clothes SET is_favorite = ? WHERE id = ?",
                     (1 if new_val else 0, cloth_id))
    return {"ok": True, "is_favorite": new_val}


class ExcludeAlgoRequest(BaseModel):
    exclude: Optional[bool] = None  # None = toggle


@router.post("/{cloth_id}/exclude-algo")
def set_cloth_exclude_algo(cloth_id: int, req: ExcludeAlgoRequest,
                           user=Depends(get_current_user)):
    """Exclude/include a cloth in the outfit-generation algorithms. Excluded
    clothes are never pulled by an algorithm, but can still be added by hand."""
    with get_conn() as conn:
        row = conn.execute(
            "SELECT exclude_from_algo FROM clothes WHERE id = ? AND user_id = ?",
            (cloth_id, user["id"]),
        ).fetchone()
        if not row:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Cloth not found")
        new_val = (not bool(row["exclude_from_algo"])) if req.exclude is None \
            else bool(req.exclude)
        conn.execute("UPDATE clothes SET exclude_from_algo = ? WHERE id = ?",
                     (1 if new_val else 0, cloth_id))
    return {"ok": True, "exclude_from_algo": new_val}


@router.get("/{cloth_id}/wears")
def cloth_wears(cloth_id: int, user=Depends(get_current_user)):
    """Every day the cloth was worn (newest first) + count for the current year."""
    from datetime import date

    with get_conn() as conn:
        owned = conn.execute(
            "SELECT 1 FROM clothes WHERE id = ? AND user_id = ?", (cloth_id, user["id"])
        ).fetchone()
        if not owned:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Cloth not found")
        days = [r["day"] for r in conn.execute(
            "SELECT day FROM cloth_wears WHERE cloth_id = ? ORDER BY day DESC",
            (cloth_id,),
        ).fetchall()]
    year = str(date.today().year)
    return {
        "days": days,
        "total": len(days),
        "this_year": sum(1 for d in days if d.startswith(year)),
    }


@router.post("/{cloth_id}/detect-colors")
def detect_cloth_colors(cloth_id: int, user=Depends(get_current_user)):
    """Auto-detect the garment's dominant colors from its cut-out (needs the
    background removed). Returns suggestions only — the client merges them into
    the editable color list; nothing is saved automatically."""
    with get_conn() as conn:
        owned = conn.execute(
            "SELECT 1 FROM clothes WHERE id = ? AND user_id = ?", (cloth_id, user["id"])
        ).fetchone()
        if not owned:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Cloth not found")
        img = conn.execute(
            "SELECT cutout_path, bg_accepted FROM cloth_images WHERE cloth_id = ? "
            "ORDER BY CASE role WHEN 'front' THEN 0 ELSE 1 END, sort_order, id LIMIT 1",
            (cloth_id,),
        ).fetchone()
    if not img:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "This cloth has no photo yet")
    if img["bg_accepted"] == "rejected":
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST,
            "Color detection needs a background-removed (cut-out) image.",
        )
    try:
        colors = detect_colors(img["cutout_path"])
    except Exception as e:
        log.warning("color detection failed for cloth %s: %s", cloth_id, e)
        raise HTTPException(status.HTTP_400_BAD_REQUEST,
                            "Could not read the image") from e
    return {"colors": colors}


@router.post("/{cloth_id}/images")
async def add_cloth_image(
    cloth_id: int,
    user=Depends(get_current_user),
    image: UploadFile = File(...),
    role: str = Form("extra"),
):
    """Append a new photo to an existing cloth (used by the edit form)."""
    if role not in VALID_ROLES:
        role = "extra"
    data = await read_capped(image)
    if not data:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Empty image upload")

    # Short transaction: authorise and reserve the slot, then let go of the DB.
    with get_conn() as conn:
        owned = conn.execute(
            "SELECT 1 FROM clothes WHERE id = ? AND user_id = ?", (cloth_id, user["id"])
        ).fetchone()
        if not owned:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Cloth not found")
        next_order = conn.execute(
            "SELECT COALESCE(MAX(sort_order), -1) + 1 AS n FROM cloth_images WHERE cloth_id = ?",
            (cloth_id,),
        ).fetchone()["n"]

    # Encoding + background removal, off the event loop and outside the lock.
    processed = await run_in_threadpool(
        _process_upload, cloth_dir(cloth_id), role, next_order, data
    )

    with get_conn() as conn:
        conn.execute(
            "INSERT INTO cloth_images (cloth_id, role, original_path, cutout_path, sort_order) "
            "VALUES (?, ?, ?, ?, ?)",
            (cloth_id, role, str(processed["original"]), str(processed["cutout"]),
             next_order),
        )
        return _load_cloth(conn, cloth_id, user["id"])


@router.put("/{cloth_id}/images/{image_id}")
async def replace_cloth_image(
    cloth_id: int,
    image_id: int,
    user=Depends(get_current_user),
    image: UploadFile = File(...),
):
    """Replace the photo behind an existing image slot (same role/position),
    re-running background removal. This is what makes 'change the picture' in
    the edit screen actually work."""
    data = await read_capped(image)
    if not data:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Empty image upload")

    with get_conn() as conn:
        owned = conn.execute(
            "SELECT 1 FROM clothes WHERE id = ? AND user_id = ?", (cloth_id, user["id"])
        ).fetchone()
        if not owned:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Cloth not found")
        img = conn.execute(
            "SELECT id, role, original_path, cutout_path, sort_order FROM cloth_images "
            "WHERE id = ? AND cloth_id = ?",
            (image_id, cloth_id),
        ).fetchone()
        if not img:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Image not found")
        # A monotonic suffix keeps replacements from colliding with prior files.
        stamp = conn.execute("SELECT COUNT(*) AS n FROM cloth_images").fetchone()["n"]
        old_paths = (img["original_path"], img["cutout_path"])
        role, sort_order = img["role"], img["sort_order"]

    # The new photo gets a fresh name so image caches (keyed on the URL) can't
    # serve the stale picture.
    processed = await run_in_threadpool(
        _process_upload, cloth_dir(cloth_id), role,
        f"{sort_order}_r{image_id}_{stamp}", data,
    )

    with get_conn() as conn:
        # A freshly-replaced photo is no longer "enhanced" — reset the method
        # and drop any pending candidate.
        conn.execute(
            "UPDATE cloth_images SET original_path = ?, cutout_path = ?, "
            "bg_accepted = 'pending', enhance_method = 'none', "
            "enhance_pending_method = NULL, enhanced_path = NULL, enhance_status = NULL, "
            "enhance_tier = NULL WHERE id = ?",
            (str(processed["original"]), str(processed["cutout"]), image_id),
        )
        result = _load_cloth(conn, cloth_id, user["id"])
    # Only drop the old files once the row points at the new ones, so a failure
    # above never leaves the DB referencing deleted images.
    for old in old_paths:
        try:
            Path(old).unlink(missing_ok=True)
        except OSError:
            pass
    return result


@router.delete("/{cloth_id}/images/{image_id}")
def delete_cloth_image(cloth_id: int, image_id: int, user=Depends(get_current_user)):
    """Delete one photo from a cloth. Refuses to remove the last remaining
    image so a cloth always keeps at least one picture."""
    from pathlib import Path

    with get_conn() as conn:
        owned = conn.execute(
            "SELECT 1 FROM clothes WHERE id = ? AND user_id = ?", (cloth_id, user["id"])
        ).fetchone()
        if not owned:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Cloth not found")
        img = conn.execute(
            "SELECT id, role, original_path, cutout_path FROM cloth_images "
            "WHERE id = ? AND cloth_id = ?",
            (image_id, cloth_id),
        ).fetchone()
        if not img:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Image not found")
        # Front/back are structural — a cloth always keeps them. They can only
        # be *replaced*, never deleted; extra photos are freely removable.
        if img["role"] in ("front", "back"):
            raise HTTPException(
                status.HTTP_400_BAD_REQUEST,
                "The front and back pictures can't be deleted — replace them instead.",
            )
        total = conn.execute(
            "SELECT COUNT(*) AS n FROM cloth_images WHERE cloth_id = ?", (cloth_id,)
        ).fetchone()["n"]
        if total <= 1:
            raise HTTPException(
                status.HTTP_400_BAD_REQUEST,
                "A cloth must keep at least one picture.",
            )
        for f in (img["original_path"], img["cutout_path"]):
            try:
                Path(f).unlink(missing_ok=True)
            except Exception:
                pass
        conn.execute("DELETE FROM cloth_images WHERE id = ?", (image_id,))
        return _load_cloth(conn, cloth_id, user["id"])


@router.delete("/{cloth_id}")
def delete_cloth(cloth_id: int, user=Depends(get_current_user)):
    with get_conn() as conn:
        row = conn.execute(
            "SELECT 1 FROM clothes WHERE id = ? AND user_id = ?", (cloth_id, user["id"])
        ).fetchone()
        if not row:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Cloth not found")
        conn.execute("DELETE FROM clothes WHERE id = ?", (cloth_id,))
    remove_cloth_files(cloth_id)
    audit_record(user, "cloth.delete", f"#{cloth_id}")
    return {"ok": True}



@router.post("/{cloth_id}/images/{image_id}/accept")
def accept_image(cloth_id: int, image_id: int, user=Depends(get_current_user)):
    """User confirms the automatic background removal looks correct.

    If a prior ``reject`` deleted the cutout file and aliased ``cutout_path``
    to the original, regenerate the cutout from the original photo here so
    accept→reject→accept→reject cycles always end with a real cutout (and
    never leave the UI showing no image).
    """
    with get_conn() as conn:
        row = conn.execute(
            "SELECT id FROM clothes WHERE id = ? AND user_id = ?",
            (cloth_id, user["id"]),
        ).fetchone()
        if not row:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Cloth not found")
        img = conn.execute(
            "SELECT id, original_path, cutout_path, bg_accepted, bg_tolerance "
            "FROM cloth_images WHERE id = ? AND cloth_id = ?",
            (image_id, cloth_id),
        ).fetchone()
        if not img:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Image not found")
        original = Path(img["original_path"])
        current_cutout = Path(img["cutout_path"])
        tolerance = img["bg_tolerance"] or "medium"
        aliased = img["cutout_path"] == img["original_path"]

    # Only regenerate when there's no usable cut-out (a prior reject aliased it
    # to the original, or the file is gone). A valid distinct cut-out — e.g.
    # from redo-bg at a chosen tolerance — is kept as-is.
    #
    # Deliberately outside the transaction above: this is ONNX inference, and
    # holding the SQLite write lock across it blocks every other writer.
    canonical_cutout = None
    if aliased or not current_cutout.exists():
        canonical_cutout = canonical_cutout_path(original)
        try:
            remove_background(original, canonical_cutout, tolerance=tolerance)
        except Exception as e:  # pragma: no cover
            log.warning("bg re-removal failed for image %s: %s", image_id, e)
            canonical_cutout = link_bytes(
                original.read_bytes(),
                canonical_cutout.with_suffix(original.suffix))

    with get_conn() as conn:
        if canonical_cutout is not None:
            conn.execute(
                "UPDATE cloth_images SET bg_accepted = 'accepted', cutout_path = ? "
                "WHERE id = ?",
                (str(canonical_cutout), image_id),
            )
        else:
            conn.execute(
                "UPDATE cloth_images SET bg_accepted = 'accepted' WHERE id = ?",
                (image_id,),
            )
    return {"ok": True}


@router.post("/{cloth_id}/images/{image_id}/reject")
def reject_image(
    cloth_id: int,
    image_id: int,
    user=Depends(get_current_user),
):
    """User says the auto background-removal is wrong. We drop the cutout,
    fall back to the original photo on display, and create a notification so
    the app manager is warned and can re-run bg-removal later."""
    with get_conn() as conn:
        row = conn.execute(
            "SELECT id FROM clothes WHERE id = ? AND user_id = ?",
            (cloth_id, user["id"]),
        ).fetchone()
        if not row:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Cloth not found")
        img = conn.execute(
            "SELECT id, original_path, cutout_path FROM cloth_images "
            "WHERE id = ? AND cloth_id = ?",
            (image_id, cloth_id),
        ).fetchone()
        if not img:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Image not found")

        # Drop the (bad) cutout file and point cutout_path at the original so
        # the image displayed everywhere is the unprocessed photo.
        #
        # Only when it IS a cut-out. cutout_path aliases original_path while the
        # cut-out is still 'processing' (_encode_only) and after a previous
        # reject (the UPDATE below sets the alias) — unlinking there deleted the
        # user's only copy of the photo.
        if img["cutout_path"] != img["original_path"]:
            try:
                from pathlib import Path

                Path(img["cutout_path"]).unlink(missing_ok=True)
            except OSError as e:
                log.warning("could not remove rejected cutout %s: %s",
                            img["cutout_path"], e)
        conn.execute(
            "UPDATE cloth_images SET bg_accepted = 'rejected', cutout_path = original_path "
            "WHERE id = ?",
            (image_id,),
        )
        conn.execute(
            "INSERT INTO notifications (user_id, cloth_id, image_id, message) "
            "VALUES (?, ?, ?, ?)",
            (
                user["id"],
                cloth_id,
                image_id,
                "User reported background removal looks wrong — please review.",
            ),
        )
    # Push a real-time alert to admins (in addition to the DB record above).
    from notify import notify_admins
    notify_admins(
        "Background removal reported",
        f"{user['email']} reported the cut-out for cloth #{cloth_id} "
        f"(image #{image_id}) looks wrong. Review it in the notifications list.",
    )
    return {"ok": True}


class ReportImageRequest(BaseModel):
    message: str = ""


@router.post("/{cloth_id}/images/{image_id}/report")
def report_image(cloth_id: int, image_id: int, req: ReportImageRequest,
                 user=Depends(get_current_user)):
    """Flag a cut-out problem to the admins WITHOUT changing the displayed
    choice — 'warn admin about an error'."""
    with get_conn() as conn:
        img = conn.execute(
            "SELECT ci.id FROM cloth_images ci JOIN clothes c ON c.id = ci.cloth_id "
            "WHERE ci.id = ? AND ci.cloth_id = ? AND c.user_id = ?",
            (image_id, cloth_id, user["id"]),
        ).fetchone()
        if not img:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Image not found")
        msg = (req.message or "").strip() or "User reported a cut-out problem."
        conn.execute(
            "INSERT INTO notifications (user_id, cloth_id, image_id, message) "
            "VALUES (?, ?, ?, ?)",
            (user["id"], cloth_id, image_id, msg),
        )
    from notify import notify_admins
    notify_admins(
        "Cut-out problem reported",
        f"{user['email']} reported a cut-out problem on cloth #{cloth_id} "
        f"(image #{image_id}): {msg}",
    )
    audit_record(user, "cloth.image.report", f"cloth #{cloth_id} img #{image_id}")
    return {"ok": True}


# --- Manual crop / rotate ------------------------------------------------

class CropRect(BaseModel):
    left: float
    top: float
    right: float
    bottom: float


class TransformRequest(BaseModel):
    rotate: int = 0  # clockwise degrees: 0 | 90 | 180 | 270
    crop: Optional[CropRect] = None


@router.post("/{cloth_id}/images/{image_id}/transform")
def transform_cloth_image(cloth_id: int, image_id: int, req: TransformRequest,
                          user=Depends(get_current_user)):
    """Rotate and/or crop a photo. The same transform is applied to the original
    and the cut-out so background removal is preserved (no rembg re-run). Writes
    new files (cache-busted) and keeps the crop/enhance state."""
    from pathlib import Path

    rotate = req.rotate % 360
    if rotate not in (0, 90, 180, 270):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "rotate must be 0/90/180/270")
    crop = None
    if req.crop is not None:
        c = req.crop
        if not (0 <= c.left < c.right <= 1 and 0 <= c.top < c.bottom <= 1):
            raise HTTPException(status.HTTP_400_BAD_REQUEST, "invalid crop rectangle")
        crop = (c.left, c.top, c.right, c.bottom)
    if rotate == 0 and crop is None:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "nothing to transform")

    with get_conn() as conn:
        owned = conn.execute(
            "SELECT 1 FROM clothes WHERE id = ? AND user_id = ?", (cloth_id, user["id"])
        ).fetchone()
        if not owned:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Cloth not found")
        img = conn.execute(
            "SELECT original_path, cutout_path, bg_accepted FROM cloth_images "
            "WHERE id = ? AND cloth_id = ?",
            (image_id, cloth_id),
        ).fetchone()
        if not img:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Image not found")
        old_original = img["original_path"]
        old_cutout = img["cutout_path"]
        rejected = img["bg_accepted"] == "rejected"

    import secrets

    cdir = cloth_dir(cloth_id)
    tok = secrets.token_hex(4)
    new_original = cdir / f"orig_{image_id}_{tok}.jpg"
    transform_image(Path(old_original), new_original, rotate=rotate, crop=crop, rgba=False)
    # When the bg was rejected the cutout aliases the original; transform the
    # original again into the cutout slot so they match. The suffix has to match
    # what transform_image will actually encode — a rejected cut-out is a plain
    # JPEG, everything else keeps its alpha and goes to WebP.
    new_cutout = cdir / f"cut_{image_id}_{tok}{'.jpg' if rejected else '.webp'}"
    cutout_src = old_original if rejected else old_cutout
    transform_image(Path(cutout_src), new_cutout,
                    rotate=rotate, crop=crop, rgba=not rejected)

    with get_conn() as conn:
        conn.execute(
            "UPDATE cloth_images SET original_path = ?, cutout_path = ?, "
            "enhanced_path = NULL, enhance_status = NULL, enhance_pending_method = NULL, "
            "enhance_tier = NULL WHERE id = ?",
            (str(new_original), str(new_cutout), image_id),
        )
    for old in (old_original, old_cutout):
        if old and old not in (str(new_original), str(new_cutout)):
            try:
                Path(old).unlink(missing_ok=True)
            except Exception:
                pass
    audit_record(user, "cloth.image.transform",
                 f"cloth #{cloth_id} img #{image_id} rotate={rotate} crop={crop is not None}")
    with get_conn() as conn:
        return _load_cloth(conn, cloth_id, user["id"])


class RedoBgRequest(BaseModel):
    tolerance: str = "medium"  # 'low' (keep more) | 'medium' | 'high' (remove more)


@router.post("/{cloth_id}/images/{image_id}/redo-bg")
def redo_background(cloth_id: int, image_id: int,
                    req: RedoBgRequest = RedoBgRequest(),
                    user=Depends(get_current_user)):
    """Re-run background removal on the CURRENT original (e.g. after a crop or
    rotate) at the chosen tolerance and leave it pending for review."""
    import secrets
    from pathlib import Path

    tolerance = req.tolerance if req.tolerance in ("low", "medium", "high") else "medium"
    with get_conn() as conn:
        owned = conn.execute(
            "SELECT 1 FROM clothes WHERE id = ? AND user_id = ?", (cloth_id, user["id"])
        ).fetchone()
        if not owned:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Cloth not found")
        img = conn.execute(
            "SELECT original_path, cutout_path FROM cloth_images "
            "WHERE id = ? AND cloth_id = ?",
            (image_id, cloth_id),
        ).fetchone()
        if not img:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Image not found")
        original = img["original_path"]
        old_cutout = img["cutout_path"]

    new_cutout = cloth_dir(cloth_id) / f"cut_{image_id}_{secrets.token_hex(4)}.webp"
    try:
        remove_background(original, str(new_cutout), tolerance=tolerance)
    except Exception as e:  # pragma: no cover
        log.warning("redo bg-removal failed for image %s: %s", image_id, e)
        new_cutout.write_bytes(Path(original).read_bytes())

    with get_conn() as conn:
        conn.execute(
            "UPDATE cloth_images SET cutout_path = ?, bg_accepted = 'pending', "
            "bg_tolerance = ?, enhanced_path = NULL, enhance_status = NULL, "
            "enhance_pending_method = NULL, enhance_tier = NULL WHERE id = ?",
            (str(new_cutout), tolerance, image_id),
        )
    if old_cutout and old_cutout != original and old_cutout != str(new_cutout):
        try:
            Path(old_cutout).unlink(missing_ok=True)
        except Exception:
            pass
    audit_record(user, "cloth.image.redo_bg",
                 f"cloth #{cloth_id} img #{image_id} tol={tolerance}")
    with get_conn() as conn:
        return _load_cloth(conn, cloth_id, user["id"])


# --- Photo enhancement (opt-in, reviewed) --------------------------------

class EnhanceRequest(BaseModel):
    mode: str = "auto"  # 'auto' = deterministic (free) | 'ai' = FLUX edit
    tier: str = "flex"  # AI model tier to start at (steps up on 'try better')
    # Put what the owner typed about the garment — name, brand, cut, colours,
    # tags — into the AI prompt. Omitted keeps whatever the image was last set
    # to, so a retry repeats the same job rather than reverting to the default.
    describe: Optional[bool] = None


def _short_reason(exc: Exception) -> str:
    """One readable line for the app, out of an error that may be a whole
    cascade's worth of per-tier messages."""
    text = str(exc).strip() or type(exc).__name__
    # A cascade failure carries every tier's message joined by " | "; the first
    # one is the one that matters and the rest are the same story again.
    head = text.split(" | ")[0].strip()
    return head[:200]


def _run_enhance(cloth_id: int, image_id: int, mode: str, tier: str = "flex") -> None:
    """Background worker: produce an enhanced candidate for one image and stash
    it in enhanced_path (the user then accepts or rejects it)."""
    import secrets
    import time

    from enhance import enhance_ai, enhance_deterministic

    with get_conn() as conn:
        img = conn.execute(
            "SELECT original_path, cutout_path, bg_accepted, role, "
            "enhance_describe FROM cloth_images WHERE id = ? AND cloth_id = ?",
            (image_id, cloth_id),
        ).fetchone()
        cloth = conn.execute(
            "SELECT name, category, brand, cut, custom_tags FROM clothes "
            "WHERE id = ?", (cloth_id,)
        ).fetchone()
        colors = [r["color"] for r in conn.execute(
            "SELECT color FROM cloth_colors WHERE cloth_id = ? ORDER BY id",
            (cloth_id,))] if cloth else []
    if not img:
        return
    cloth_name = cloth["name"] if cloth else ""
    cloth_category = cloth["category"] if cloth else ""
    cloth_brand = (cloth["brand"] or "") if cloth else ""
    cloth_cut = (cloth["cut"] or "") if cloth else ""
    try:
        cloth_tags = json.loads(cloth["custom_tags"] or "[]") if cloth else []
    except (TypeError, ValueError):
        cloth_tags = []
    # NULL means the choice was never made for this image: describe, which is
    # what the prompt did before the switch existed.
    describe = True if img["enhance_describe"] is None \
        else bool(img["enhance_describe"])
    # Enhance the image the user actually kept: the cut-out when they kept it
    # ("the cropped one"), or the original when they rejected the cut-out.
    # Otherwise a wrinkle-fix would run on the uncropped photo.
    src = img["original_path"] if img["bg_accepted"] == "rejected" else img["cutout_path"]
    # Unique filename per run → the URL changes every time, so the client's
    # image cache can't serve a stale enhanced photo (the bug where a re-run
    # or an AI pass after an auto pass didn't visibly refresh).
    dst = cloth_dir(cloth_id) / (
        f"enhanced_{image_id}_{int(time.time() * 1000)}_{secrets.token_hex(3)}.jpg"
    )
    try:
        used_tier = None
        if mode == "ai":
            used_tier = enhance_ai(src, str(dst), tier=tier,
                                   name=cloth_name, category=cloth_category,
                                   role=img["role"], describe=describe,
                                   brand=cloth_brand, cut=cloth_cut,
                                   colors=colors, tags=cloth_tags)
        else:
            enhance_deterministic(src, img["cutout_path"], str(dst))
        with get_conn() as conn:
            conn.execute(
                "UPDATE cloth_images SET enhanced_path = ?, enhance_status = 'ready', "
                "enhance_tier = ?, enhance_started_at = NULL WHERE id = ?",
                (str(dst), used_tier, image_id),
            )
    except Exception as e:  # pragma: no cover - depends on rembg/bfl/PIL
        log.warning("enhance (%s) failed for image %s: %s", mode, image_id, e)
        with get_conn() as conn:
            conn.execute(
                # The tier that was tried is kept, not cleared: it is what lets
                # the app offer the NEXT one up instead of only "try the same
                # thing again", which is what a garment the cheap model keeps
                # refusing actually needs.
                "UPDATE cloth_images SET enhance_status = 'failed', "
                "enhance_tier = ?, enhance_error = ?, enhance_started_at = NULL "
                "WHERE id = ?",
                (tier if mode == "ai" else None, _short_reason(e), image_id),
            )


class EnhanceDescribeRequest(BaseModel):
    describe: bool = True


@router.patch("/{cloth_id}/images/{image_id}/enhance-describe")
def set_enhance_describe(cloth_id: int, image_id: int,
                         req: EnhanceDescribeRequest,
                         user=Depends(get_current_user)):
    """Record whether the AI prompt should name what the owner typed about this
    garment. Deliberately separate from starting a run: ticking a box is not
    asking for a paid render.
    """
    with get_conn() as conn:
        owned = conn.execute(
            "SELECT 1 FROM clothes WHERE id = ? AND user_id = ?",
            (cloth_id, user["id"]),
        ).fetchone()
        if not owned:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Cloth not found")
        cur = conn.execute(
            "UPDATE cloth_images SET enhance_describe = ? "
            "WHERE id = ? AND cloth_id = ?",
            (1 if req.describe else 0, image_id, cloth_id))
        if not cur.rowcount:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Image not found")
        return _load_cloth(conn, cloth_id, user["id"])


@router.post("/{cloth_id}/images/{image_id}/enhance")
def enhance_image(cloth_id: int, image_id: int, req: EnhanceRequest,
                  background: BackgroundTasks, user=Depends(enhance_guard)):
    """Kick off an enhancement (background). Returns the cloth with the image's
    enhance_status = 'processing'; the client polls until 'ready'/'failed', then
    shows the candidate for accept/reject."""
    mode = "ai" if req.mode == "ai" else "auto"
    with get_conn() as conn:
        owned = conn.execute(
            "SELECT 1 FROM clothes WHERE id = ? AND user_id = ?", (cloth_id, user["id"])
        ).fetchone()
        if not owned:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Cloth not found")
        img = conn.execute(
            "SELECT id, enhanced_path FROM cloth_images WHERE id = ? AND cloth_id = ?",
            (image_id, cloth_id),
        ).fetchone()
        if not img:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Image not found")
        old_enhanced = img["enhanced_path"]
        conn.execute(
            "UPDATE cloth_images SET enhance_status = 'processing', enhanced_path = NULL, "
            "enhance_pending_method = ?, enhance_tier = NULL, enhance_error = NULL, "
            "enhance_started_at = datetime('now') WHERE id = ?",
            (mode, image_id),
        )
        if req.describe is not None:
            conn.execute(
                "UPDATE cloth_images SET enhance_describe = ? WHERE id = ?",
                (1 if req.describe else 0, image_id))
    # Drop the previous candidate's file so they don't pile up on disk.
    if old_enhanced:
        from pathlib import Path
        try:
            Path(old_enhanced).unlink(missing_ok=True)
        except Exception:
            pass
    background.add_task(_run_enhance, cloth_id, image_id, mode, req.tier)
    with get_conn() as conn:
        return _load_cloth(conn, cloth_id, user["id"])


@router.post("/{cloth_id}/images/{image_id}/enhance/accept")
def accept_enhance(cloth_id: int, image_id: int, user=Depends(get_current_user)):
    """Adopt the enhanced candidate as the image's photo and re-run background
    removal on it (so the cutout matches). The choice is then re-reviewable."""
    from pathlib import Path

    with get_conn() as conn:
        owned = conn.execute(
            "SELECT 1 FROM clothes WHERE id = ? AND user_id = ?", (cloth_id, user["id"])
        ).fetchone()
        if not owned:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Cloth not found")
        img = conn.execute(
            "SELECT original_path, cutout_path, enhanced_path, enhance_pending_method "
            "FROM cloth_images "
            "WHERE id = ? AND cloth_id = ?",
            (image_id, cloth_id),
        ).fetchone()
        if not img or not img["enhanced_path"] or not Path(img["enhanced_path"]).exists():
            raise HTTPException(status.HTTP_400_BAD_REQUEST, "No enhanced image to accept")
        old_original = img["original_path"]
        old_cutout = img["cutout_path"]
        new_original = img["enhanced_path"]
        method = img["enhance_pending_method"] or "auto"

    new_cutout = canonical_cutout_path(new_original)
    try:
        remove_background(new_original, str(new_cutout))
    except Exception as e:  # pragma: no cover
        log.warning("bg removal after enhance failed for image %s: %s", image_id, e)
        new_cutout = Path(new_original)

    with get_conn() as conn:
        conn.execute(
            "UPDATE cloth_images SET original_path = ?, cutout_path = ?, "
            "bg_accepted = 'pending', enhanced_path = NULL, enhance_status = NULL, "
            "enhance_method = ?, enhance_pending_method = NULL, enhance_tier = NULL "
            "WHERE id = ?",
            (new_original, str(new_cutout), method, image_id),
        )
    # Drop the superseded files (best-effort; never the new original/cutout).
    for old in (old_original, old_cutout):
        if old and old not in (new_original, str(new_cutout)):
            try:
                Path(old).unlink(missing_ok=True)
            except Exception:
                pass
    with get_conn() as conn:
        return _load_cloth(conn, cloth_id, user["id"])


@router.post("/{cloth_id}/images/{image_id}/enhance/reject")
def reject_enhance(cloth_id: int, image_id: int, user=Depends(get_current_user)):
    """Discard the enhanced candidate, keep the current photo."""
    from pathlib import Path

    with get_conn() as conn:
        owned = conn.execute(
            "SELECT 1 FROM clothes WHERE id = ? AND user_id = ?", (cloth_id, user["id"])
        ).fetchone()
        if not owned:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Cloth not found")
        img = conn.execute(
            "SELECT enhanced_path FROM cloth_images WHERE id = ? AND cloth_id = ?",
            (image_id, cloth_id),
        ).fetchone()
        if not img:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Image not found")
        if img["enhanced_path"]:
            try:
                Path(img["enhanced_path"]).unlink(missing_ok=True)
            except Exception:
                pass
        conn.execute(
            "UPDATE cloth_images SET enhanced_path = NULL, enhance_status = NULL, "
            "enhance_pending_method = NULL, enhance_tier = NULL WHERE id = ?",
            (image_id,),
        )
        return _load_cloth(conn, cloth_id, user["id"])