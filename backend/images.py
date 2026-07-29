import hashlib
import logging
import os
import shutil
import threading
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter, ImageOps
from rembg import remove as rembg_remove

import imagesign
from config import BLOBS_DIR, IMAGES_DIR, REMBG_MODEL

log = logging.getLogger(__name__)

# Lazy-loaded rembg session, so we only pay the model-load cost once per process.
_SESSION = {"session": None}
# A single ONNX session is not guaranteed thread-safe; requests run on a thread
# pool, so serialize inference to avoid concurrent-upload races/crashes.
_INFER_LOCK = threading.Lock()

# --- encoding budgets -----------------------------------------------------
# Tuned for visual transparency, not for the smallest possible file. Measured
# against the pristine originals, these land around 48-49 dB PSNR — the point
# where a re-encode is indistinguishable from the source by eye.
#
# An earlier, more aggressive pass (2000/1600 px at quality 88) was visibly
# soft. Almost all of that loss came from the RESOLUTION cap, not the codec:
# compression at 88 already scored 44 dB, while shrinking a 4000 px photo to
# 1600 px is what destroyed the detail. Hence generous caps here — the grids no
# longer load these files anyway, they load /thumb variants.
#
# The cap exists only to stop a pathological import (a 12000 px scan) from
# being stored whole; a normal phone photo passes through untouched.
ORIGINAL_MAX_PX = int(os.environ.get("CLOTHESAPP_ORIGINAL_MAX_PX", "4000"))
ORIGINAL_JPEG_QUALITY = int(os.environ.get("CLOTHESAPP_ORIGINAL_QUALITY", "95"))
# Cut-outs are what the app renders on almost every screen, so they are stored
# LOSSLESS: bit-for-bit identical to the PNGs that came before, with none of a
# codec's judgement applied to the user's garments. Lossless WebP is still ~44%
# smaller than the equivalent PNG, so the saving comes purely from the container.
#
# Lossy WebP was measured at 42.5 dB (q95) and plateaus around 43.4 dB even at
# q100 — its chroma subsampling puts a ceiling on it — so paying 2.5x the bytes
# for genuinely zero loss is the better trade here.
# 1600, not 2400. This is what every cut-out in the library already was before
# the quality pass touched it, and nothing displays more: the grids use 400 px
# copies and the detail screens 800 px, so the stored file is only ever seen
# through the fullscreen zoom — where 1600 px already exceeds a phone screen.
#
# The cost of 2400 was not storage but latency, on the one path where the user
# is actively waiting: measured on a real photo, encoding a cut-out losslessly
# takes 2745 ms at 2400 px against 1130 ms at 1600 px, for 3.8 MB against
# 1.8 MB. Adding a garment runs that twice, front and back.
CUTOUT_MAX_PX = int(os.environ.get("CLOTHESAPP_CUTOUT_MAX_PX", "1600"))
CUTOUT_WEBP_LOSSLESS = os.environ.get(
    "CLOTHESAPP_CUTOUT_LOSSLESS", "1").strip().lower() not in ("0", "false", "")
# Only consulted when lossless is turned off.
CUTOUT_WEBP_QUALITY = int(os.environ.get("CLOTHESAPP_CUTOUT_QUALITY", "95"))
# WebP effort. For LOSSLESS output the setting barely matters — measured at
# 1042 ms (method 4) against 1171 ms (method 6) for the same 1004 KB — so there
# is nothing to buy by going higher. Lossy thumbnails are a different story;
# see THUMB_WEBP_METHOD in routes_thumbs.py.
CUTOUT_WEBP_METHOD = int(os.environ.get("CLOTHESAPP_CUTOUT_METHOD", "4"))


def _classify_color(r: int, g: int, b: int) -> str:
    """Map an RGB pixel to one of the app's named colors using HSV, which keeps
    dark chromatic colors (navy, forest green, dark grey) from all collapsing to
    black the way a plain RGB distance does. Names must match kColorOptions."""
    import colorsys

    h, s, v = colorsys.rgb_to_hsv(r / 255.0, g / 255.0, b / 255.0)
    hue = h * 360.0
    warm = hue < 50 or hue >= 330  # reds / oranges / yellows (brown & beige live here)

    # Near-white: bright with little saturation (a faint warm tint is still white,
    # so off-whites don't read as beige).
    if v >= 0.83 and s < 0.20:
        return "White"
    # Near-black: very dark regardless of a faint hue.
    if v < 0.20:
        return "Black"
    # Low-saturation mid tones are grey — not black or brown.
    if s < 0.15:
        return "White" if v > 0.80 else "Grey"
    # Beige: pale warm; Brown: darker warm with real saturation.
    if warm and v >= 0.62 and s < 0.42:
        return "Beige"
    if warm and v < 0.55 and s >= 0.30:
        return "Brown"
    # Everything else is chromatic — bucket by hue.
    if hue < 15 or hue >= 345:
        return "Red"
    if hue < 45:
        return "Orange"
    if hue < 68:
        return "Yellow"
    if hue < 170:
        return "Green"
    if hue < 255:
        return "Blue"
    if hue < 290:
        return "Purple"
    return "Pink"


# Palette order is an implementation detail (it only indexes the vectorised
# classifier's output); the names are the contract and must match kColorOptions.
_COLOR_NAMES = ("White", "Black", "Grey", "Beige", "Brown", "Red", "Orange",
                "Yellow", "Green", "Blue", "Purple", "Pink")
_CODE = {name: i for i, name in enumerate(_COLOR_NAMES)}


def _classify_colors_array(rgb: np.ndarray) -> np.ndarray:
    """Vectorised twin of [_classify_color] over an (N, 3) uint8 array.

    Same HSV thresholds, same precedence — the per-pixel Python version is kept
    as the readable reference and the two are pinned together by a test. Doing
    this per pixel in Python cost ~25k interpreter round-trips per detection.
    """
    arr = rgb.astype(np.float64) / 255.0
    r, g, b = arr[:, 0], arr[:, 1], arr[:, 2]
    mx = arr.max(axis=1)
    mn = arr.min(axis=1)
    rng = mx - mn
    chromatic = rng > 0
    v = mx
    s = np.divide(rng, mx, out=np.zeros_like(mx), where=mx > 0)
    # colorsys.rgb_to_hsv, term for term.
    safe = np.where(chromatic, rng, 1.0)
    rc, gc, bc = (mx - r) / safe, (mx - g) / safe, (mx - b) / safe
    h = np.where(r == mx, bc - gc, np.where(g == mx, 2.0 + rc - bc, 4.0 + gc - rc))
    h = np.where(chromatic, (h / 6.0) % 1.0, 0.0)
    hue = h * 360.0

    warm = (hue < 50) | (hue >= 330)
    # np.select takes the first matching condition, mirroring the if/elif chain.
    conditions = [
        (v >= 0.83) & (s < 0.20),          # near-white
        v < 0.20,                          # near-black
        (s < 0.15) & (v > 0.80),           # washed-out bright -> white
        s < 0.15,                          # washed-out mid -> grey
        warm & (v >= 0.62) & (s < 0.42),   # beige
        warm & (v < 0.55) & (s >= 0.30),   # brown
        (hue < 15) | (hue >= 345),
        hue < 45,
        hue < 68,
        hue < 170,
        hue < 255,
        hue < 290,
    ]
    choices = [_CODE["White"], _CODE["Black"], _CODE["White"], _CODE["Grey"],
               _CODE["Beige"], _CODE["Brown"], _CODE["Red"], _CODE["Orange"],
               _CODE["Yellow"], _CODE["Green"], _CODE["Blue"], _CODE["Purple"]]
    return np.select(conditions, choices, default=_CODE["Pink"])


def detect_colors(cutout_path, *, max_colors: int = 3):
    """Best-effort dominant colors of a cut-out (transparent-background) image,
    mapped to the app's named palette with a 'full'/'part'/'little' dominance.
    Only opaque (garment) pixels count, so the background never pollutes it.
    Returns a list of {"color", "dominance"} — empty if nothing detectable."""
    with Image.open(cutout_path) as im:
        im = im.convert("RGBA")
        im.thumbnail((160, 160))  # downscale for speed
        arr = np.asarray(im)
    opaque = arr[..., 3] >= 200  # skip (semi-)transparent background pixels
    total = int(opaque.sum())
    if not total:
        return []
    counts = np.bincount(
        _classify_colors_array(arr[..., :3][opaque]), minlength=len(_COLOR_NAMES)
    )
    out = []
    for code in np.argsort(-counts, kind="stable"):
        share = int(counts[code]) / total
        if share < 0.10:  # ignore trace colors
            break
        dominance = "full" if share >= 0.5 else ("part" if share >= 0.2 else "little")
        out.append({"color": _COLOR_NAMES[code], "dominance": dominance})
        if len(out) >= max_colors:
            break
    return out


def _get_session():
    if _SESSION["session"] is None:
        # rembg.new_session handles downloading the model on first call.
        from rembg import new_session

        _SESSION["session"] = new_session(REMBG_MODEL)
    return _SESSION["session"]


# --- content-addressed storage -------------------------------------------

def _blob_path(digest: str, ext: str) -> Path:
    """Two-level fan-out so one directory never holds 100k entries."""
    return BLOBS_DIR / digest[:2] / f"{digest}.{ext}"


def link_bytes(data: bytes, dst: Path) -> Path:
    """Store ``data`` once in the blob store and hard-link ``dst`` to it.

    Two clothes photographed with the same picture then cost one copy on disk.
    Hard links are safe against deletion: ``remove_cloth_files`` drops a link,
    not the inode, and the bytes survive for whoever still references them.
    Falls back to a plain write if the filesystem refuses the link.
    """
    digest = hashlib.sha256(data).hexdigest()
    blob = _blob_path(digest, dst.suffix.lstrip(".") or "bin")
    try:
        if not blob.exists():
            blob.parent.mkdir(parents=True, exist_ok=True)
            # Write to a temp name then rename, so a crash mid-write can never
            # leave a truncated blob that later uploads would link against.
            tmp = blob.with_name(blob.name + ".tmp")
            tmp.write_bytes(data)
            tmp.replace(blob)
        dst.unlink(missing_ok=True)
        os.link(blob, dst)
        return dst
    except OSError as e:  # different filesystem, no link support, ...
        log.debug("blob link failed (%s); writing a plain copy", e)
        dst.write_bytes(data)
        return dst


def gc_orphan_blobs() -> int:
    """Delete blobs nothing links to any more. A blob with a link count of 1 is
    referenced only by the blob store itself, so no cloth still uses it.
    Cheap enough to run at startup; returns how many were reclaimed."""
    freed = 0
    if not BLOBS_DIR.exists():
        return 0
    for shard in BLOBS_DIR.iterdir():
        if not shard.is_dir():
            continue
        for blob in shard.iterdir():
            try:
                if blob.is_file() and blob.stat().st_nlink <= 1:
                    blob.unlink()
                    freed += 1
            except OSError:
                pass
        try:
            shard.rmdir()  # only succeeds when the shard is now empty
        except OSError:
            pass
    return freed


# --- upload encoding ------------------------------------------------------

def _encode_original(data: bytes) -> tuple[bytes, str]:
    """Re-encode an uploaded photo to a sane size/format.

    Returns ``(encoded_bytes, extension)``. Images carrying transparency stay
    PNG (a JPEG would flatten the alpha onto black); everything else becomes a
    JPEG, which is what phone photos already are. EXIF orientation is baked in
    while we still have it, so the stored pixels are upright — the background
    removal downstream reads raw pixels and would otherwise cut out a sideways
    garment while the app displayed it upright.
    """
    import io

    with Image.open(io.BytesIO(data)) as im:
        im = ImageOps.exif_transpose(im) or im
        has_alpha = im.mode in ("RGBA", "LA") or (
            im.mode == "P" and "transparency" in im.info
        )
        im = _downscale(im, ORIGINAL_MAX_PX)
        buf = io.BytesIO()
        if has_alpha:
            im.convert("RGBA").save(buf, format="PNG", optimize=True)
            return buf.getvalue(), "png"
        im.convert("RGB").save(
            buf, format="JPEG", quality=ORIGINAL_JPEG_QUALITY, optimize=True,
            progressive=True,
        )
        return buf.getvalue(), "jpg"


def save_original(data: bytes, dst_stem: Path) -> Path:
    """Persist an uploaded photo next to ``dst_stem`` (a path with no suffix).

    The extension is chosen by the encoder, so the caller must use the returned
    path rather than assuming one. Unreadable uploads are stored verbatim so a
    format PIL doesn't know still reaches the user instead of 500-ing.
    """
    try:
        encoded, ext = _encode_original(data)
    except Exception as e:
        log.warning("could not re-encode upload (%s); storing as-is", e)
        encoded, ext = data, "bin"
    return link_bytes(encoded, dst_stem.with_suffix(f".{ext}"))


# Suffix every freshly-written cut-out uses. Historical rows keep their .png
# path until something regenerates them.
CUTOUT_SUFFIX = ".webp"


def canonical_cutout_path(original) -> Path:
    """The cut-out file that belongs to ``original``.

    Centralised because accept / reject / redo-bg / replace all regenerate it:
    if any of them picked a different name, a reject→accept round-trip would
    move the file and the app's URL-keyed image cache would show a stale photo.
    """
    original = Path(original)
    return original.with_name(original.stem + "_cutout" + CUTOUT_SUFFIX)


def cloth_dir(cloth_id: int) -> Path:
    d = IMAGES_DIR / str(cloth_id)
    d.mkdir(parents=True, exist_ok=True)
    return d


VALID_TOLERANCES = {"low", "medium", "high"}


def _apply_tolerance(cutout: Image.Image, tolerance: str) -> Image.Image:
    """Adjust how aggressively the background is removed by morphing the alpha
    mask. 'low' grows the kept region (keeps more — good when the cut clips the
    garment); 'high' shrinks + hardens it (removes more — good for stray bg);
    'medium' is rembg's own output."""
    if tolerance not in ("low", "high"):
        return cutout
    r, g, b, a = cutout.split()
    if tolerance == "low":
        # Keep as MUCH as possible (softest): treat even the faintest edge pixels
        # as garment (very low threshold), ramp up sub-threshold alpha hard so
        # wisps and fuzz become near-solid, then grow the mask outward generously
        # (three dilation passes) so soft edges, fuzz and shadows all survive.
        a = a.point(lambda v: 255 if v >= 4 else min(255, v * 40))
        a = a.filter(ImageFilter.MaxFilter(9))
        a = a.filter(ImageFilter.MaxFilter(9))
        a = a.filter(ImageFilter.MaxFilter(9))
    else:  # high — remove MORE (clearly stronger than Balanced)
        # Demand a strong alpha to keep a pixel (kills halos/semi-transparent
        # fringe), then erode the mask inward to shave off stray background.
        a = a.point(lambda v: 255 if v >= 210 else 0)
        a = a.filter(ImageFilter.MinFilter(9))
    return Image.merge("RGBA", (r, g, b, a))


def _trim_transparent(cutout: Image.Image, *, pad_frac: float = 0.04) -> Image.Image:
    """Crop away the fully-transparent margins so the garment fills the frame
    instead of floating in a big void. Keeps a small padding proportional to the
    content size. No-op when the image is (nearly) empty."""
    if cutout.mode != "RGBA":
        return cutout
    alpha = cutout.split()[3]
    # Ignore near-transparent speckle so a couple of stray pixels don't defeat
    # the trim; fall back to the raw bbox if thresholding wipes everything.
    solid = alpha.point(lambda v: 255 if v >= 16 else 0)
    bbox = solid.getbbox() or alpha.getbbox()
    if not bbox:
        return cutout
    left, top, right, bottom = bbox
    w, h = cutout.size
    pad = int(round(max(right - left, bottom - top) * pad_frac))
    box = (max(0, left - pad), max(0, top - pad),
           min(w, right + pad), min(h, bottom + pad))
    if box == (0, 0, w, h):
        return cutout
    return cutout.crop(box)


def _downscale(img: Image.Image, max_side: int = 1600) -> Image.Image:
    """Shrink so the longest edge is at most ``max_side``. A 4000px phone photo
    becomes a few hundred KB instead of several MB — much faster to load over
    the network — with no visible loss at the sizes the app renders."""
    w, h = img.size
    longest = max(w, h)
    if longest <= max_side:
        return img
    scale = max_side / longest
    return img.resize((max(1, round(w * scale)), max(1, round(h * scale))))


def _encode_cutout(img: Image.Image, dst_path: Path) -> bytes:
    """Serialise a transparent cut-out, format picked from the destination
    suffix. ``.webp`` is what new code writes (3-5x smaller than PNG at the same
    perceived quality); ``.png`` stays supported so historical paths and the
    re-generation of an existing row keep working unchanged."""
    import io

    buf = io.BytesIO()
    if dst_path.suffix.lower() == ".webp":
        if CUTOUT_WEBP_LOSSLESS:
            img.save(buf, format="WEBP", lossless=True,
                     method=CUTOUT_WEBP_METHOD)
        else:
            img.save(buf, format="WEBP", quality=CUTOUT_WEBP_QUALITY,
                     method=CUTOUT_WEBP_METHOD)
    else:
        img.save(buf, format="PNG", optimize=True)
    return buf.getvalue()


def remove_background(src_path: Path, dst_path: Path,
                      tolerance: str = "medium") -> Path:
    """Run rembg on the saved file and write a transparent cutout. The
    ``tolerance`` level tunes how much is removed (see _apply_tolerance)."""
    if tolerance not in VALID_TOLERANCES:
        tolerance = "medium"
    dst_path = Path(dst_path)
    with Image.open(src_path) as img:
        img = ImageOps.exif_transpose(img) or img
        # rembg.remove accepts a PIL image or bytes; bytes path also works.
        # Serialize inference — the shared ONNX session isn't thread-safe.
        with _INFER_LOCK:
            cutout = rembg_remove(img, session=_get_session())
    cutout = _apply_tolerance(cutout.convert("RGBA"), tolerance)
    # Tighten to the garment so it isn't a small item lost in empty space.
    cutout = _trim_transparent(cutout)
    # Cap the size so first load isn't a multi-MB transfer.
    cutout = _downscale(cutout, CUTOUT_MAX_PX)
    return link_bytes(_encode_cutout(cutout, dst_path), dst_path)


def transform_image(src_path: Path, dst_path: Path, *, rotate: int = 0,
                    crop=None, rgba: bool = False) -> Path:
    """Apply a rotation (clockwise degrees) and/or a normalized crop rectangle
    to an image and write it to ``dst_path``. Works for both the RGB original
    (white fill) and the RGBA cut-out (transparent fill), so a garment photo
    and its background-removed version stay geometrically in sync.

    ``crop`` is (left, top, right, bottom) each in 0..1 of the (rotated) image.
    """
    with Image.open(src_path) as im:
        im = im.convert("RGBA" if rgba else "RGB")
        if rotate % 360 != 0:
            fill = (0, 0, 0, 0) if rgba else (255, 255, 255)
            # PIL rotates counter-clockwise; negate for clockwise degrees.
            im = im.rotate(-rotate, expand=True, fillcolor=fill)
        if crop is not None:
            w, h = im.size
            left, top, right, bottom = crop
            box = (
                max(0, min(w, round(left * w))),
                max(0, min(h, round(top * h))),
                max(0, min(w, round(right * w))),
                max(0, min(h, round(bottom * h))),
            )
            # Guard against a degenerate (zero-area) selection.
            if box[2] - box[0] >= 2 and box[3] - box[1] >= 2:
                im = im.crop(box)
        # Same size cap as the upload path — a rotate/crop used to write back a
        # full-resolution PNG, which is how single 7 MB files ended up on disk.
        im = _downscale(im, CUTOUT_MAX_PX if rgba else ORIGINAL_MAX_PX)
        if rgba:
            payload = _encode_cutout(im, Path(dst_path))
        else:
            import io

            buf = io.BytesIO()
            im.save(buf, format="JPEG", quality=ORIGINAL_JPEG_QUALITY,
                    optimize=True, progressive=True)
            payload = buf.getvalue()
    return link_bytes(payload, Path(dst_path))


def remove_cloth_files(cloth_id: int) -> None:
    d = IMAGES_DIR / str(cloth_id)
    if d.exists():
        shutil.rmtree(d, ignore_errors=True)


def public_url_for(file_path: str) -> str:
    """Convert a stored absolute path into the public URL the client uses.

    Appends ``?v=<mtime>`` so the URL changes whenever the file's *content*
    changes — even when the filename is reused (e.g. a re-generated cut-out).
    Without this, the app's image cache keeps serving the old picture after a
    crop/enhance until a manual refresh.
    """
    p = Path(file_path)
    # Strip everything up to /images/, since the static mount lives at /images.
    try:
        rel = p.relative_to(IMAGES_DIR)
    except ValueError:
        # Already relative or outside: treat as-is.
        rel = Path(p.name)
    rel_posix = rel.as_posix()
    url = f"/images/{rel_posix}"
    params = []
    try:
        # Nanosecond mtime so even a same-second rewrite changes the URL.
        params.append(f"v={p.stat().st_mtime_ns}")
    except OSError:
        pass  # file missing — serve the bare URL
    # Authorises this exact path for a limited time; empty when signing is off.
    # The namespace prefix must match what the mount verifies, so that a grant
    # for /images cannot be replayed against /generated.
    signed = imagesign.sign_query(f"images/{rel_posix}")
    if signed:
        params.append(signed)
    return url + ("?" + "&".join(params) if params else "")
