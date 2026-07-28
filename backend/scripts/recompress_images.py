#!/usr/bin/env python3
"""Re-encode images already on disk to the sizes/formats the upload path now uses.

New uploads are downscaled, EXIF-corrected and stored as JPEG (originals) /
WebP (cut-outs). Everything uploaded before that change is still a full-size
phone photo or an unoptimised PNG. This walks the DB, rewrites those files, and
repoints the rows at the new paths.

Safe by default: prints what it would do and changes nothing. Pass --apply to
actually rewrite. Background removal is NOT re-run — existing cut-outs are only
re-encoded, so the visual result is unchanged.

    python scripts/recompress_images.py             # report only
    python scripts/recompress_images.py --apply     # rewrite
"""
import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from PIL import Image  # noqa: E402

import images as img_mod  # noqa: E402
from db import get_conn  # noqa: E402


def _human(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if abs(n) < 1024 or unit == "GB":
            return f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} GB"


def _reencode_original(path: Path) -> tuple[bytes, str] | None:
    """Returns (bytes, ext), or None if the file is already fine / unreadable."""
    try:
        return img_mod._encode_original(path.read_bytes())
    except Exception as e:
        print(f"  ! skip {path.name}: {e}")
        return None


def _reencode_cutout(path: Path) -> bytes | None:
    """Re-encode a cut-out to WebP at the current size cap, alpha preserved."""
    try:
        with Image.open(path) as im:
            im = im.convert("RGBA")
            im = img_mod._downscale(im, img_mod.CUTOUT_MAX_PX)
            return img_mod._encode_cutout(im, Path("x.webp"))
    except Exception as e:
        print(f"  ! skip {path.name}: {e}")
        return None


def _oversized(path: Path, cap: int) -> bool:
    """True when the image is larger than the cap in *pixels*.

    Byte size alone is not enough to decide: an already well-compressed 4000 px
    phone photo can weigh less than its own 2000 px re-encode, yet it still
    costs the client 12 megapixels to decode. Those files must be rewritten
    even though the rewrite saves no disk.
    """
    try:
        with Image.open(path) as im:
            return max(im.size) > cap
    except Exception:
        return False


class Stats:
    def __init__(self):
        self.before = 0
        self.after = 0
        self.files = 0
        self.skipped = 0
        self.resized_only = 0


def _process(path_str: str, kind: str, stats: Stats, apply: bool) -> str | None:
    """Rewrite one file. Returns the new path when it changed, else None."""
    path = Path(path_str)
    if not path.exists():
        stats.skipped += 1
        return None
    before = path.stat().st_size

    if kind == "cutout":
        payload = _reencode_cutout(path)
        ext = "webp"
        cap = img_mod.CUTOUT_MAX_PX
    else:
        result = _reencode_original(path)
        payload, ext = result if result else (None, None)
        cap = img_mod.ORIGINAL_MAX_PX
    if payload is None:
        stats.skipped += 1
        return None

    new_path = path.with_name(path.stem + "." + ext)
    too_many_pixels = _oversized(path, cap)
    # Rewrite when it saves real bytes, when the format changes, or when the
    # image is still over the pixel cap — the last case saves no disk but is
    # what keeps the client from decoding a 12 megapixel photo per card.
    if (len(payload) >= before * 0.95 and new_path == path
            and not too_many_pixels):
        stats.skipped += 1
        return None
    if too_many_pixels and len(payload) >= before:
        stats.resized_only += 1

    stats.files += 1
    stats.before += before
    stats.after += len(payload)
    if not apply:
        return str(new_path) if new_path != path else None

    img_mod.link_bytes(payload, new_path)
    if new_path != path:
        try:
            path.unlink(missing_ok=True)
        except OSError:
            pass
    return str(new_path)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--apply", action="store_true",
                    help="actually rewrite files (default: report only)")
    args = ap.parse_args()

    stats = Stats()
    mode = "REWRITING" if args.apply else "DRY RUN — nothing will be changed"
    print(f"=== {mode} ===\n")

    with get_conn() as conn:
        rows = conn.execute(
            "SELECT id, original_path, cutout_path, enhanced_path FROM cloth_images"
        ).fetchall()
        print(f"cloth_images: {len(rows)} rows")
        for r in rows:
            updates = {}
            aliased = r["cutout_path"] == r["original_path"]
            new_original = _process(r["original_path"], "original", stats, args.apply)
            if new_original:
                updates["original_path"] = new_original
            if aliased:
                # bg-removal was rejected: the cut-out is the original. Keep the
                # alias pointing at wherever the original ended up.
                if new_original:
                    updates["cutout_path"] = new_original
            else:
                new_cutout = _process(r["cutout_path"], "cutout", stats, args.apply)
                if new_cutout:
                    updates["cutout_path"] = new_cutout
            if r["enhanced_path"]:
                new_enh = _process(r["enhanced_path"], "cutout", stats, args.apply)
                if new_enh:
                    updates["enhanced_path"] = new_enh
            if updates and args.apply:
                sets = ", ".join(f"{k} = ?" for k in updates)
                conn.execute(f"UPDATE cloth_images SET {sets} WHERE id = ?",
                             list(updates.values()) + [r["id"]])

        mrows = conn.execute(
            "SELECT id, original_path, cutout_path FROM model_images"
        ).fetchall()
        print(f"model_images: {len(mrows)} rows")
        for r in mrows:
            updates = {}
            aliased = r["cutout_path"] == r["original_path"]
            new_original = _process(r["original_path"], "original", stats, args.apply)
            if new_original:
                updates["original_path"] = new_original
            if aliased:
                if new_original:
                    updates["cutout_path"] = new_original
            else:
                new_cutout = _process(r["cutout_path"], "cutout", stats, args.apply)
                if new_cutout:
                    updates["cutout_path"] = new_cutout
            if updates and args.apply:
                sets = ", ".join(f"{k} = ?" for k in updates)
                conn.execute(f"UPDATE model_images SET {sets} WHERE id = ?",
                             list(updates.values()) + [r["id"]])

    saved = stats.before - stats.after
    pct = (100 * saved / stats.before) if stats.before else 0
    print()
    print(f"files rewritten : {stats.files}")
    print(f"  of which resized for pixel count, not disk: {stats.resized_only}")
    print(f"files skipped   : {stats.skipped} (missing, unreadable, or already small)")
    print(f"before          : {_human(stats.before)}")
    print(f"after           : {_human(stats.after)}")
    print(f"saved           : {_human(saved)}  ({pct:.0f}%)")

    if args.apply:
        freed = img_mod.gc_orphan_blobs()
        print(f"orphan blobs reclaimed: {freed}")
    else:
        print("\nRe-run with --apply to perform the rewrite.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
