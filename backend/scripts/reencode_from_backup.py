#!/usr/bin/env python3
"""Re-encode the image library from a pristine backup, at the current settings.

Why not just re-run recompress_images.py? Because the files on disk have already
been through one lossy pass. Re-encoding them again cannot recover detail and
only adds generation loss. The untouched source lives in the backup, so quality
has to come from there.

For each row in the DB it finds the matching backup file by (cloth dir, stem),
re-encodes it with the current ORIGINAL_*/CUTOUT_* settings, writes it into
place and repoints the row. Background removal is NOT re-run — an existing
cut-out is only re-encoded, so the visual result is unchanged apart from being
sharper.

Safe by default: reports and changes nothing until given --apply.

    python scripts/reencode_from_backup.py --backup ../../clothes-app-backup-...
    python scripts/reencode_from_backup.py --backup ... --apply
"""
import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from PIL import Image  # noqa: E402

import images as img_mod  # noqa: E402
from config import IMAGES_DIR  # noqa: E402
from db import get_conn  # noqa: E402


def _human(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if abs(n) < 1024 or unit == "GB":
            return f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} GB"


def _index_backup(backup_images: Path) -> dict:
    """(parent dir name, file stem) -> pristine file. The stem is stable across
    the extension changes, which is exactly what has to be matched through."""
    index = {}
    for p in backup_images.rglob("*"):
        if p.is_file():
            index[(p.parent.name, p.stem)] = p
    return index


class Stats:
    def __init__(self):
        self.before = self.after = 0
        self.rewritten = self.no_source = self.failed = 0


def _reencode(src: Path, kind: str):
    """Return (bytes, extension) at the current quality settings."""
    if kind == "cutout":
        with Image.open(src) as im:
            im = im.convert("RGBA")
            im = img_mod._downscale(im, img_mod.CUTOUT_MAX_PX)
            return img_mod._encode_cutout(im, Path("x.webp")), "webp"
    return img_mod._encode_original(src.read_bytes())


def _process(stored: str, kind: str, index: dict, stats: Stats, apply: bool):
    """Rebuild one file from its backup twin. Returns the new path, or None."""
    current = Path(stored)
    pristine = index.get((current.parent.name, current.stem))
    if pristine is None:
        stats.no_source += 1
        return None
    try:
        payload, ext = _reencode(pristine, kind)
    except Exception as e:
        print(f"  ! {pristine.name}: {e}")
        stats.failed += 1
        return None

    new_path = current.with_name(current.stem + "." + ext)
    stats.rewritten += 1
    stats.before += current.stat().st_size if current.exists() else 0
    stats.after += len(payload)
    if not apply:
        return str(new_path) if new_path != current else None

    new_path.parent.mkdir(parents=True, exist_ok=True)
    img_mod.link_bytes(payload, new_path)
    if new_path != current:
        try:
            current.unlink(missing_ok=True)
        except OSError:
            pass
    return str(new_path)


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--backup", required=True,
                    help="backup directory (the one containing images/)")
    ap.add_argument("--apply", action="store_true",
                    help="actually rewrite (default: report only)")
    args = ap.parse_args()

    backup_images = Path(args.backup).expanduser().resolve()
    if backup_images.name != "images":
        backup_images = backup_images / "images"
    if not backup_images.is_dir():
        print(f"no images/ directory under {args.backup}")
        return 1

    index = _index_backup(backup_images)
    print(f"=== {'REWRITING' if args.apply else 'DRY RUN — nothing changes'} ===")
    print(f"pristine files indexed: {len(index)}")
    print(f"settings: originals <= {img_mod.ORIGINAL_MAX_PX}px q{img_mod.ORIGINAL_JPEG_QUALITY}, "
          f"cut-outs <= {img_mod.CUTOUT_MAX_PX}px webp q{img_mod.CUTOUT_WEBP_QUALITY}\n")

    stats = Stats()
    with get_conn() as conn:
        for table, cols in (
            ("cloth_images", ("original_path", "cutout_path", "enhanced_path")),
            ("model_images", ("original_path", "cutout_path")),
        ):
            rows = conn.execute(f"SELECT * FROM {table}").fetchall()
            print(f"{table}: {len(rows)} rows")
            for r in rows:
                updates = {}
                aliased = r["cutout_path"] == r["original_path"]
                new_original = _process(r["original_path"], "original", index,
                                        stats, args.apply)
                if new_original:
                    updates["original_path"] = new_original
                if aliased:
                    # bg-removal rejected: the cut-out IS the original.
                    if new_original:
                        updates["cutout_path"] = new_original
                else:
                    new_cutout = _process(r["cutout_path"], "cutout", index,
                                          stats, args.apply)
                    if new_cutout:
                        updates["cutout_path"] = new_cutout
                if "enhanced_path" in cols and r["enhanced_path"]:
                    new_enh = _process(r["enhanced_path"], "cutout", index,
                                       stats, args.apply)
                    if new_enh:
                        updates["enhanced_path"] = new_enh
                if updates and args.apply:
                    sets = ", ".join(f"{k} = ?" for k in updates)
                    conn.execute(f"UPDATE {table} SET {sets} WHERE id = ?",
                                 list(updates.values()) + [r["id"]])

    print()
    print(f"rebuilt from pristine source : {stats.rewritten}")
    print(f"no backup twin found         : {stats.no_source}")
    print(f"failed to decode             : {stats.failed}")
    print(f"disk before                  : {_human(stats.before)}")
    print(f"disk after                   : {_human(stats.after)}")

    if args.apply:
        freed = img_mod.gc_orphan_blobs()
        print(f"orphan blobs reclaimed       : {freed}")
        thumbs = Path(IMAGES_DIR).parent / "thumbs"
        if thumbs.is_dir():
            import shutil
            shutil.rmtree(thumbs, ignore_errors=True)
            thumbs.mkdir(parents=True, exist_ok=True)
            print("thumbnail cache cleared (regenerates from the new sources)")
    else:
        print("\nRe-run with --apply to perform the rewrite.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
