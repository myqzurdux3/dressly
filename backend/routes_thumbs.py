"""On-demand thumbnails for the wardrobe/history grids.

The collection screen renders two cards per row on a phone — roughly 200 logical
pixels each — but was downloading the full 1600 px cut-out for every one of
them. This serves a resized copy instead, generated once and cached on disk.

Deliberately unauthenticated, exactly like the /images and /generated static
mounts it shadows: the paths are already public and are guessable only if you
know the filename. Adding auth here without adding it there would be theatre.
"""
import logging
import os
from functools import lru_cache
from pathlib import Path

from fastapi import APIRouter, HTTPException, Response, status
from fastapi.responses import FileResponse
from PIL import Image
from starlette.exceptions import HTTPException as StarletteHTTPException

import imagesign
from config import IMAGES_DIR, OUTFITS_DIR, THUMBS_DIR

router = APIRouter(tags=["images"])
log = logging.getLogger(__name__)

# A fixed ladder, so a caller cannot make us generate (and cache) an unbounded
# number of variants of every photo.
ALLOWED_WIDTHS = (160, 240, 400, 800)

# Grid thumbnails are the most-looked-at images in the app.
THUMB_WEBP_QUALITY = int(os.environ.get("CLOTHESAPP_THUMB_QUALITY", "90"))
# Encoder effort. Anything above 4 costs an order of magnitude more time for a
# few percent of size — and this runs while someone is looking at a blank grid.
THUMB_WEBP_METHOD = int(os.environ.get("CLOTHESAPP_THUMB_METHOD", "4"))

# Sources we are willing to resize, keyed by the URL prefix they are served on.
_ROOTS = {"images": IMAGES_DIR, "generated": OUTFITS_DIR}

# Every URL carries ?v=<mtime>, so a given URL's bytes never change. Let clients
# keep them for a year instead of revalidating on each grid scroll.
IMMUTABLE_CACHE = "public, max-age=31536000, immutable"


def _safe_source(root_key: str, rel_path: str) -> Path:
    """Resolve a request path inside its root, or 404.

    ``rel_path`` comes straight from the URL, so it is untrusted: resolve it and
    confirm the result is still under the root before touching the filesystem.
    """
    root = _ROOTS.get(root_key)
    if root is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Unknown image root")
    root = root.resolve()
    try:
        src = (root / rel_path).resolve()
    except (OSError, ValueError):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Image not found")
    if src != root and root not in src.parents:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Image not found")
    resolved = resolve_legacy_extension(src)
    if resolved is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Image not found")
    return resolved


def resolve_legacy_extension(path: Path) -> Path | None:
    """Find the current file for a request naming an old extension.

    Cut-outs used to be PNG and are WebP now. A client that cached the old URL
    (or an old JSON payload) keeps asking for `foo_cutout.png` after the file
    became `foo_cutout.webp`, and every image 404s at once. Rather than make the
    user clear their cache, serve whatever sibling actually exists.
    """
    if path.is_file():
        return path
    for ext in (".webp", ".png", ".jpg", ".jpeg"):
        candidate = path.with_suffix(ext)
        if candidate.is_file():
            return candidate
    return None


def _thumb_path(root_key: str, rel_path: str, width: int) -> Path:
    return THUMBS_DIR / str(width) / root_key / (rel_path + ".webp")


# The widths the app actually asks for: 400 in the grids, 800 on the detail
# screens. Generating the whole ALLOWED_WIDTHS ladder up front would spend time
# on variants nothing requests.
PREWARM_WIDTHS = (400, 800)


def prewarm(source: Path, root_key: str = "images") -> int:
    """Render this image's grid thumbnails now, off the request path.

    Measured at 99 ms per 400 px thumbnail and 165 ms at 800 px on this
    hardware — so a cold thirty-garment grid spent about three seconds encoding
    inside the requests somebody was waiting on. The cut-out already runs as a
    background job and already holds the file, so this costs the user nothing.

    Best effort: a thumbnail that fails to render is regenerated on demand
    exactly as before, so nothing here is allowed to raise.
    """
    root = _ROOTS.get(root_key)
    if root is None:
        return 0
    try:
        rel = source.resolve().relative_to(root.resolve()).as_posix()
    except (ValueError, OSError):
        return 0
    made = 0
    for width in PREWARM_WIDTHS:
        dst = _thumb_path(root_key, rel, width)
        # The same freshness rule the serving path uses (line ~166), not a bare
        # "does it exist": a cut-out is rewritten by redo-bg, by accept-after-
        # reject and by a crop, and the thumbnail sitting at that canonical name
        # is then stale. Skipping it because the file exists would leave the
        # slow on-demand re-render for exactly the cases pre-warming is for.
        if dst.is_file() and dst.stat().st_mtime >= source.stat().st_mtime:
            continue
        try:
            _render(source, dst, width)
            made += 1
        except Exception as e:  # noqa: BLE001 - a missing thumbnail is not an error
            log.info("could not pre-render %s at %s: %s", rel, width, e)
    return made


def _render(src: Path, dst: Path, width: int) -> None:
    """Resize preserving aspect ratio and alpha. WebP for both, so a cut-out
    keeps its transparency and a photo still compresses well."""
    dst.parent.mkdir(parents=True, exist_ok=True)
    with Image.open(src) as im:
        im = im.convert("RGBA")
        if im.width > width:
            height = max(1, round(im.height * width / im.width))
            im = im.resize((width, height), Image.LANCZOS)
        tmp = dst.with_name(dst.name + ".tmp")
        # method=4, NOT 6. Measured on this library at 400 px: method 6 takes
        # 1677 ms per thumbnail against 127 ms for method 4 — thirteen times the
        # work — and produces a file 3.5% smaller (25.1 KB vs 26.0 KB). These
        # are generated on demand while the user waits at the grid, so that
        # trade is the wrong way round by a wide margin.
        im.save(tmp, format="WEBP", quality=THUMB_WEBP_QUALITY,
                method=THUMB_WEBP_METHOD)
        tmp.replace(dst)


@router.get("/thumb/{root_key}/{width}/{rel_path:path}")
def thumbnail(root_key: str, width: int, rel_path: str,
              e: str | None = None, s: str | None = None):
    """Serve `rel_path` resized to `width`, generating + caching on first hit.

    Sync `def` on purpose: FastAPI runs it in the threadpool, so the PIL resize
    never touches the event loop.
    """
    # Signed over the source path, so one grant covers the image and all of its
    # thumbnail widths. 404 rather than 403: an unsigned guess must not confirm
    # that the path exists.
    if not imagesign.verify(f"{root_key}/{rel_path}", e, s):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Image not found")
    if width not in ALLOWED_WIDTHS:
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST,
            f"Unsupported width; allowed: {', '.join(map(str, ALLOWED_WIDTHS))}",
        )
    src = _safe_source(root_key, rel_path)
    dst = _thumb_path(root_key, rel_path, width)

    # Regenerate when the source has been rewritten (crop, redo-bg, enhance...).
    if not dst.exists() or dst.stat().st_mtime < src.stat().st_mtime:
        try:
            _render(src, dst, width)
        except Exception as e:
            # A thumbnail is an optimisation, never a hard failure: fall back to
            # the full-size original so the grid still shows something.
            log.warning("thumbnail failed for %s: %s", src, e)
            return FileResponse(src, headers={"Cache-Control": IMMUTABLE_CACHE})
    return FileResponse(
        dst, media_type="image/webp", headers={"Cache-Control": IMMUTABLE_CACHE}
    )


@lru_cache(maxsize=8192)
def _rel_under_roots(file_path: str):
    """(root key, relative posix path) for a stored file, or None.

    Cached because the answer depends only on the path and the mount roots,
    which are fixed for the process — while a wardrobe listing asks for the
    SAME file at five widths, and the try/except relative_to loop was the bulk
    of the URL-building cost (measured: 14 ms of a 16 ms hydrate for 60
    garments). The mtime below is still read on every call, so cache-busting
    stays correct.
    """
    p = Path(file_path)
    for key, root in _ROOTS.items():
        try:
            return key, p.relative_to(root).as_posix()
        except ValueError:
            continue
    return None


def thumb_url_for(file_path: str, width: int = 400) -> str:
    """Public thumbnail URL for a stored absolute path. Empty when the file is
    outside the servable roots, so callers can fall back to the full image."""
    if not file_path:
        return ""
    resolved = _rel_under_roots(file_path)
    if resolved:
        key, rel_posix = resolved
        url = f"/thumb/{key}/{width}/{rel_posix}"
        params = []
        try:
            # os.stat on the string: constructing a Path here cost more than the
            # syscall, and this runs five times per garment photo.
            params.append(f"v={os.stat(file_path).st_mtime_ns}")
        except OSError:
            pass
        # Signed over the SOURCE path, the same string the static mount signs,
        # so one grant covers an image and its thumbnails.
        signed = imagesign.sign_query(f"{key}/{rel_posix}")
        if signed:
            params.append(signed)
        return url + ("?" + "&".join(params) if params else "")
    return ""


class CachedStaticFiles:
    """Mixin for the /images and /generated mounts.

    Two jobs:

    * tag responses as immutable — the URLs already carry ?v=<mtime>, so their
      bytes never change, and without this the client revalidated every image on
      every screen open;
    * transparently serve a renamed file. Cut-outs moved from PNG to WebP, and
      any client still holding an old URL would otherwise 404 on every single
      image at once until it cleared its cache.
    """

    #: URL prefix this mount is served under, used as the signing namespace.
    sign_root: str = ""

    async def get_response(self, path: str, scope):  # pragma: no cover - I/O
        if imagesign.enabled():
            expires, signature = imagesign.parse_query(
                scope.get("query_string", b""))
            rel = f"{self.sign_root}/{path.lstrip('/')}"
            if not imagesign.verify(rel, expires, signature):
                # 404, not 403: an unsigned guess should not confirm that the
                # path exists.
                raise StarletteHTTPException(status_code=404)
        try:
            return await super().get_response(path, scope)
        except StarletteHTTPException as e:
            # Starlette raises rather than returning a 404 response, so the
            # retry has to happen here. It raises its OWN HTTPException class,
            # which fastapi.HTTPException subclasses — catching the subclass
            # would silently never match.
            if e.status_code != status.HTTP_404_NOT_FOUND:
                raise
            alt = resolve_legacy_extension(Path(self.directory) / path)
            if alt is None:
                raise
            return await super().get_response(
                alt.relative_to(Path(self.directory)).as_posix(), scope)

    def file_response(self, *args, **kwargs) -> Response:  # pragma: no cover
        resp = super().file_response(*args, **kwargs)
        resp.headers["Cache-Control"] = IMMUTABLE_CACHE
        return resp
