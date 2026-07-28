"""Upload encoding, blob dedup, and the vectorised colour classifier."""
import io
import itertools
import os

import numpy as np
import pytest
from PIL import Image

import images


def _png(color=(200, 30, 30), size=(64, 64), mode="RGB") -> bytes:
    buf = io.BytesIO()
    Image.new(mode, size, color).save(buf, "PNG")
    return buf.getvalue()


def _jpeg(color=(10, 120, 200), size=(3000, 2000)) -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", size, color).save(buf, "JPEG", quality=95)
    return buf.getvalue()


# --- colour classification ------------------------------------------------

def test_vectorised_classifier_matches_the_scalar_reference():
    """The numpy path must agree with _classify_color on every colour, or the
    palette silently drifts. Sweeps the RGB cube at a step of 8 (~35k combos)."""
    vals = list(range(0, 256, 8)) + [255]
    rgb = np.array(list(itertools.product(vals, vals, vals)), dtype=np.uint8)
    fast = images._classify_colors_array(rgb)
    slow = np.array([
        images._CODE[images._classify_color(int(r), int(g), int(b))]
        for r, g, b in rgb
    ])
    mismatched = np.nonzero(fast != slow)[0]
    assert len(mismatched) == 0, (
        f"{len(mismatched)} disagreements, first at rgb={rgb[mismatched[0]]}"
    )


def test_detect_colors_ignores_transparent_pixels(tmp_path):
    im = Image.new("RGBA", (100, 100), (0, 0, 0, 0))       # transparent bg
    im.paste((200, 20, 20, 255), (0, 0, 100, 50))          # solid red half
    p = tmp_path / "c.png"
    im.save(p)
    colors = images.detect_colors(p)
    assert colors and colors[0]["color"] == "Red"
    # Red covers every opaque pixel, so it reads as fully dominant.
    assert colors[0]["dominance"] == "full"


def test_detect_colors_on_fully_transparent_image(tmp_path):
    p = tmp_path / "empty.png"
    Image.new("RGBA", (40, 40), (0, 0, 0, 0)).save(p)
    assert images.detect_colors(p) == []


# --- upload encoding ------------------------------------------------------

def test_save_original_downscales_and_shrinks(tmp_path):
    raw = _jpeg()
    out = images.save_original(raw, tmp_path / "front_0")
    assert out.suffix == ".jpg"
    with Image.open(out) as im:
        assert max(im.size) <= images.ORIGINAL_MAX_PX
    assert out.stat().st_size < len(raw)


def test_save_original_keeps_alpha_as_png(tmp_path):
    out = images.save_original(_png(mode="RGBA", color=(0, 0, 0, 0)),
                               tmp_path / "front_0")
    assert out.suffix == ".png"
    with Image.open(out) as im:
        assert im.mode in ("RGBA", "LA", "P")


def test_save_original_bakes_in_exif_orientation(tmp_path):
    """A phone photo tagged 'rotate 90' must be stored upright, otherwise the
    cut-out is computed on sideways pixels."""
    im = Image.new("RGB", (200, 100), (10, 10, 200))
    exif = im.getexif()
    exif[274] = 6  # Orientation: rotate 90 CW
    buf = io.BytesIO()
    im.save(buf, "JPEG", exif=exif)
    out = images.save_original(buf.getvalue(), tmp_path / "front_0")
    with Image.open(out) as saved:
        assert saved.size == (100, 200), "orientation was not applied"


def test_unreadable_upload_is_stored_verbatim(tmp_path):
    out = images.save_original(b"not an image at all", tmp_path / "front_0")
    assert out.read_bytes() == b"not an image at all"


# --- content-addressed dedup ---------------------------------------------

def test_identical_uploads_share_one_inode(tmp_path):
    raw = _jpeg(color=(3, 200, 90))
    a = images.save_original(raw, tmp_path / "cloth_a")
    b = images.save_original(raw, tmp_path / "cloth_b")
    assert a != b
    assert a.stat().st_ino == b.stat().st_ino, "duplicate photo stored twice"


def test_different_uploads_do_not_share_an_inode(tmp_path):
    a = images.save_original(_jpeg(color=(1, 2, 3)), tmp_path / "a")
    b = images.save_original(_jpeg(color=(250, 250, 250)), tmp_path / "b")
    assert a.stat().st_ino != b.stat().st_ino


def test_deleting_one_link_keeps_the_other_readable(tmp_path):
    raw = _jpeg(color=(9, 9, 200))
    a = images.save_original(raw, tmp_path / "a")
    b = images.save_original(raw, tmp_path / "b")
    a.unlink()
    with Image.open(b) as im:      # must still decode
        assert im.size[0] > 0


def test_gc_reclaims_only_unreferenced_blobs(tmp_path):
    kept = images.save_original(_jpeg(color=(1, 250, 1)), tmp_path / "kept")
    doomed = images.save_original(_jpeg(color=(250, 1, 1)), tmp_path / "doomed")
    doomed.unlink()
    freed = images.gc_orphan_blobs()
    assert freed >= 1
    with Image.open(kept) as im:   # the surviving link is untouched
        assert im.size[0] > 0


# --- cut-out encoding -----------------------------------------------------

def test_cutout_encoder_picks_format_from_suffix(tmp_path):
    img = Image.new("RGBA", (50, 50), (200, 10, 10, 255))
    webp = images._encode_cutout(img, tmp_path / "x.webp")
    png = images._encode_cutout(img, tmp_path / "x.png")
    assert Image.open(io.BytesIO(webp)).format == "WEBP"
    assert Image.open(io.BytesIO(png)).format == "PNG"


def test_webp_cutout_is_smaller_than_png(tmp_path):
    """The whole point of the format switch — verify it on a realistic,
    photo-like cut-out rather than a flat colour that compresses to nothing."""
    rng = np.random.default_rng(0)
    noise = rng.integers(60, 200, size=(600, 600, 3), dtype=np.uint8)
    alpha = np.zeros((600, 600, 1), dtype=np.uint8)
    alpha[100:500, 100:500] = 255
    img = Image.fromarray(np.concatenate([noise, alpha], axis=2), "RGBA")
    webp = images._encode_cutout(img, tmp_path / "x.webp")
    png = images._encode_cutout(img, tmp_path / "x.png")
    assert len(webp) < len(png)


def test_transform_image_caps_output_size(tmp_path):
    src = tmp_path / "src.png"
    Image.new("RGBA", (4000, 3000), (10, 200, 10, 255)).save(src)
    dst = tmp_path / "out.webp"
    images.transform_image(src, dst, rotate=90, rgba=True)
    with Image.open(dst) as im:
        assert max(im.size) <= images.CUTOUT_MAX_PX


@pytest.mark.skipif(os.name != "posix", reason="hard links are POSIX-only here")
def test_blob_store_lives_outside_the_public_images_dir():
    """Blobs must not be reachable through the /images static mount."""
    from config import BLOBS_DIR, IMAGES_DIR

    assert BLOBS_DIR.resolve() not in IMAGES_DIR.resolve().parents
    assert not str(BLOBS_DIR.resolve()).startswith(str(IMAGES_DIR.resolve()))
