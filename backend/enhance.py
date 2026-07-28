"""Garment photo enhancement.

Two modes:

* ``deterministic`` — free, offline, no hallucination. Uses the rembg cutout to
  crop tightly to the garment, fixes orientation, does a gentle gray-world white
  balance + auto-contrast, and lays the item centered on a clean white canvas.
  Handles "brighter / straighter framing / clean background".

* ``ai`` — sends the photo to FLUX with an edit instruction to remove wrinkles
  and flatten the garment while keeping colors/details. Costs one generation
  call and can subtly alter the item, so it's opt-in and reviewed.
"""
import logging
from pathlib import Path

import numpy as np
from PIL import Image, ImageOps

log = logging.getLogger(__name__)

OUT_PX = 1024

def _ai_prompt(name: str = "", category: str = "", role: str = "") -> str:
    """Build the FLUX edit instruction, folding in what the item is (type + the
    user's name) and which side the photo shows (front/back). The extra context
    helps the model edit the right garment and not invent a design from the
    other side. All fields are optional — with none it's the generic prompt."""
    cat = (category or "").strip().replace("-", " ").lower()
    nm = (name or "").strip()
    side = (role or "").strip().lower()
    side = side if side in ("front", "back") else ""

    desc = ""
    if cat:
        desc += f", a {cat}"
    if nm:
        desc += f' named "{nm}"'
    if side:
        desc += f" (this photo shows the {side} of the garment)"
    side_hint = (f" Keep it as the {side} of the item — do not add details from "
                 f"the other side." if side else "")
    return (
        f"Clean product photo of the exact same clothing item{desc}: remove all "
        f"wrinkles and creases, smooth and lay the fabric flat, straighten and "
        f"center it, even soft studio lighting, pure white background.{side_hint} "
        f"Keep the exact same colors, pattern, text, logos and shape — do not "
        f"redesign the garment."
    )


# Generic fallback (no per-item context).
_AI_PROMPT = _ai_prompt()


def _subject_bbox(cutout_path: str, ref_size) -> tuple | None:
    """Bounding box of the garment from the cutout's alpha, if it matches the
    original's size. Returns None when there's no usable transparency."""
    try:
        cut = Image.open(cutout_path)
    except Exception:
        return None
    if cut.size != ref_size or cut.mode != "RGBA":
        return None
    alpha = cut.split()[3]
    # Fully-opaque cutout (e.g. bg-removal rejected/failed) → no meaningful crop.
    if alpha.getextrema() == (255, 255):
        return None
    return alpha.getbbox()


def _gray_world(im: Image.Image) -> Image.Image:
    """Mild gray-world white balance — neutralizes color casts from bad lighting
    without pushing the image to extremes."""
    arr = np.asarray(im).astype(np.float32)
    avg = arr.reshape(-1, 3).mean(axis=0)
    avg = np.where(avg == 0, 1.0, avg)
    scale = avg.mean() / avg
    scale = np.clip(scale, 0.7, 1.4)  # keep the correction gentle
    arr = np.clip(arr * scale, 0, 255).astype(np.uint8)
    return Image.fromarray(arr)


def _open_rgb_on_white(path: str) -> Image.Image:
    """Open an image as RGB. A transparent cut-out is flattened onto white (not
    black) so enhancing 'the cropped one' keeps the garment on a clean bg."""
    im = Image.open(path)
    if im.mode in ("RGBA", "LA") or (im.mode == "P" and "transparency" in im.info):
        rgba = im.convert("RGBA")
        bg = Image.new("RGB", rgba.size, (255, 255, 255))
        bg.paste(rgba, mask=rgba.split()[3])
        return bg
    return im.convert("RGB")


def enhance_deterministic(src_path: str, cutout_path: str, dst_path: str) -> str:
    im = _open_rgb_on_white(src_path)
    bbox = _subject_bbox(cutout_path, im.size)
    if bbox:
        pad = int(0.04 * max(im.size))
        left = max(0, bbox[0] - pad)
        top = max(0, bbox[1] - pad)
        right = min(im.width, bbox[2] + pad)
        bottom = min(im.height, bbox[3] + pad)
        if right > left and bottom > top:
            im = im.crop((left, top, right, bottom))
    # Fix phone orientation after cropping (bbox was in raw space).
    im = ImageOps.exif_transpose(im)
    im = _gray_world(im)
    im = ImageOps.autocontrast(im, cutoff=1)
    # Center on a clean white square for a tidy, uniform product look.
    im.thumbnail((OUT_PX, OUT_PX), Image.LANCZOS)
    canvas = Image.new("RGB", (OUT_PX, OUT_PX), (255, 255, 255))
    canvas.paste(im, ((OUT_PX - im.width) // 2, (OUT_PX - im.height) // 2))
    canvas.save(dst_path, "JPEG", quality=92)
    return dst_path


def enhance_ai(src_path: str, dst_path: str, tier: str = "flex", *,
               name: str = "", category: str = "", role: str = "") -> str:
    """Run a FLUX image edit starting at ``tier`` (the caller steps the tier up
    on demand, like outfit generation). Returns the tier actually used. With no
    BFL key configured this returns the mock placeholder. A transparent cut-out
    source is flattened onto white first so the model sees the garment (not a
    black square) — this respects the user's crop choice.

    ``name``/``category``/``role`` (front/back) are woven into the prompt so the
    model knows exactly what garment and which side it's editing."""
    import os
    import tempfile

    from bfl import generate

    prompt = _ai_prompt(name=name, category=category, role=role)

    src = src_path
    tmp = None
    with Image.open(src_path) as probe:
        needs_flatten = probe.mode in ("RGBA", "LA") or (
            probe.mode == "P" and "transparency" in probe.info
        )
    if needs_flatten:
        flat = _open_rgb_on_white(src_path)
        fd = tempfile.NamedTemporaryFile(suffix=".jpg", delete=False)
        flat.save(fd, "JPEG", quality=92)
        fd.close()
        src = fd.name
        tmp = src
    try:
        image_bytes, tier_used, _slug = generate(prompt, [src], start_tier=tier)
        Path(dst_path).write_bytes(image_bytes)
    finally:
        if tmp:
            try:
                os.unlink(tmp)
            except OSError:
                pass
    return tier_used
