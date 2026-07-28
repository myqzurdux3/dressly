"""On-demand thumbnails for the wardrobe/history grids.

The collection screen renders two cards per row on a phone — roughly 200 logical
pixels each — but was downloading the full 1600 px cut-out for every one of
them. This serves a resized copy instead, generated once and cached on disk.

Deliberately unauthenticated, exactly like the /images and /generated static
mounts it shadows: the paths are already public and are guessable only if you
know the filename. Adding auth here without adding it there would be theatre.
"""
import logging
from pathlib import Path

from fastapi import APIRouter, HTTPException, Response, status
from fastapi.responses import FileResponse
from PIL import Image

from config import IMAGES_DIR, OUTFITS_DIR, THUMBS_DIR

router = APIRouter(tags=["images"])
log = logging.getLogger(__name__)

# A fixed ladder, so a caller cannot make us generate (and cache) an unbounded
# number of variants of every photo.
ALLOWED_WIDTHS = (160, 240, 400, 800)

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
    if not src.is_file():
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Image not found")
    return src


def _thumb_path(root_key: str, rel_path: str, width: int) -> Path:
    return THUMBS_DIR / str(width) / root_key / (rel_path + ".webp")


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
        im.save(tmp, format="WEBP", quality=82, method=4)
        tmp.replace(dst)


@router.get("/thumb/{root_key}/{width}/{rel_path:path}")
def thumbnail(root_key: str, width: int, rel_path: str):
    """Serve `rel_path` resized to `width`, generating + caching on first hit.

    Sync `def` on purpose: FastAPI runs it in the threadpool, so the PIL resize
    never touches the event loop.
    """
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


def thumb_url_for(file_path: str, width: int = 400) -> str:
    """Public thumbnail URL for a stored absolute path. Empty when the file is
    outside the servable roots, so callers can fall back to the full image."""
    if not file_path:
        return ""
    p = Path(file_path)
    for key, root in _ROOTS.items():
        try:
            rel = p.relative_to(root)
        except ValueError:
            continue
        url = f"/thumb/{key}/{width}/{rel.as_posix()}"
        try:
            url += f"?v={p.stat().st_mtime_ns}"
        except OSError:
            pass
        return url
    return ""


class CachedStaticFiles:
    """Mixin adding immutable cache headers to a StaticFiles mount.

    The app's URLs already carry ?v=<mtime>, so the bytes behind any given URL
    are immutable — without this the client revalidated every image on every
    screen open.
    """

    def file_response(self, *args, **kwargs) -> Response:  # pragma: no cover
        resp = super().file_response(*args, **kwargs)
        resp.headers["Cache-Control"] = IMMUTABLE_CACHE
        return resp
