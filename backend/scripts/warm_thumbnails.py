#!/usr/bin/env python3
"""Pre-generate the grid thumbnails.

Thumbnails are built on first request and cached. That is fine in steady state
— a warm one is served in about 4 ms — but a cold cache means the person
opening the wardrobe waits for every image to be encoded, one screen at a time.

The cache is emptied whenever the stored images are rewritten (a re-encode, a
restore from backup, a move to another machine), so this should be run right
after any of those, and after a first deployment.

    python scripts/warm_thumbnails.py               # every width the app uses
    python scripts/warm_thumbnails.py --width 400   # just the grid size
"""
import argparse
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from db import get_conn  # noqa: E402
from routes_thumbs import (  # noqa: E402
    _render,
    _safe_source,
    _thumb_path,
)

# The widths the client actually asks for. Generating the whole ladder would
# triple the work for variants nothing requests.
DEFAULT_WIDTHS = (400,)


def _sources():
    """(root_key, relative path) for every image the app can display."""
    from config import IMAGES_DIR, OUTFITS_DIR

    out = []
    with get_conn() as conn:
        for table, cols in (
            ("cloth_images", ("original_path", "cutout_path")),
            ("model_images", ("cutout_path",)),
        ):
            for r in conn.execute(f"SELECT * FROM {table}"):
                for col in cols:
                    p = r[col]
                    if not p:
                        continue
                    try:
                        out.append(("images", Path(p).relative_to(IMAGES_DIR)))
                    except ValueError:
                        pass
        for r in conn.execute(
            "SELECT generated_path FROM outfits WHERE generated_path != ''"
        ):
            try:
                out.append(("generated",
                            Path(r["generated_path"]).relative_to(OUTFITS_DIR)))
            except ValueError:
                pass
    # Same file can back several rows; build each thumbnail once.
    return sorted(set(out))


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--width", type=int, action="append", default=[],
                    help="width to generate; repeatable (default: 400)")
    ap.add_argument("--force", action="store_true",
                    help="rebuild even when a current thumbnail exists")
    ap.add_argument("--jobs", type=int, default=4,
                    help="parallel encoders (default 4)")
    args = ap.parse_args()
    widths = args.width or list(DEFAULT_WIDTHS)

    sources = _sources()
    print(f"{len(sources)} source images x {len(widths)} width(s)")

    done = skipped = failed = 0
    started = time.perf_counter()

    def work(item):
        root_key, rel = item
        rel_posix = rel.as_posix()
        try:
            src = _safe_source(root_key, rel_posix)
        except Exception:
            return "failed"
        made = False
        for w in widths:
            dst = _thumb_path(root_key, rel_posix, w)
            if (not args.force and dst.exists()
                    and dst.stat().st_mtime >= src.stat().st_mtime):
                continue
            try:
                _render(src, dst, w)
                made = True
            except Exception as e:
                print(f"  ! {rel_posix}: {e}")
                return "failed"
        return "done" if made else "skipped"

    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        for i, result in enumerate(pool.map(work, sources), 1):
            if result == "done":
                done += 1
            elif result == "skipped":
                skipped += 1
            else:
                failed += 1
            if i % 50 == 0:
                print(f"  {i}/{len(sources)}...", flush=True)

    elapsed = time.perf_counter() - started
    print()
    print(f"generated : {done}")
    print(f"already up to date : {skipped}")
    print(f"failed    : {failed}")
    print(f"took      : {elapsed:.1f}s")
    if done:
        print(f"            ({elapsed / done * 1000:.0f} ms per thumbnail)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
