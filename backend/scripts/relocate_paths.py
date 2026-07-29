#!/usr/bin/env python3
"""Repoint the database at a new install directory.

Image locations are stored as absolute paths, so moving the installation —
copying it to a server, renaming the folder — leaves every row pointing at
somewhere that no longer exists. The symptom is not an error but a silent one:
`public_url_for` cannot make the path relative to IMAGES_DIR, falls back to the
bare filename, and every image in the app 404s at once.

Run this once after moving. It rewrites the stored prefix to wherever the data
directory now is, and only touches rows that actually need it.

    python scripts/relocate_paths.py                 # report
    python scripts/relocate_paths.py --apply

Idempotent: running it again after a successful move finds nothing to do.
"""
import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from config import IMAGES_DIR, OUTFITS_DIR  # noqa: E402
from db import get_conn  # noqa: E402

# (table, column, the directory that column's paths must sit under)
TARGETS = [
    ("cloth_images", "original_path", IMAGES_DIR),
    ("cloth_images", "cutout_path", IMAGES_DIR),
    ("cloth_images", "enhanced_path", IMAGES_DIR),
    ("model_images", "original_path", IMAGES_DIR),
    ("model_images", "cutout_path", IMAGES_DIR),
    ("outfits", "generated_path", OUTFITS_DIR),
]


def _relocated(stored: str, root: Path) -> str | None:
    """Where `stored` should point now, or None if it is already right.

    Matches on the tail of the path rather than a known old prefix, so it works
    regardless of where the data used to live.
    """
    if not stored:
        return None
    p = Path(stored)
    try:
        p.relative_to(root)
        return None                      # already under the current root
    except ValueError:
        pass
    # Everything after the last occurrence of the root's own name is the part
    # that stays: e.g. ".../data/images/3/front_0.jpg" -> "3/front_0.jpg".
    parts = p.parts
    name = root.name
    if name not in parts:
        return None                      # nothing recognisable to rebase
    tail = parts[len(parts) - 1 - parts[::-1].index(name) + 1:]
    return str(root.joinpath(*tail)) if tail else None


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--apply", action="store_true",
                    help="write the changes (default: report only)")
    args = ap.parse_args()

    print(f"images  -> {IMAGES_DIR}")
    print(f"outfits -> {OUTFITS_DIR}")
    print(f"=== {'REWRITING' if args.apply else 'DRY RUN'} ===\n")

    changed = already = missing = 0
    with get_conn() as conn:
        for table, column, root in TARGETS:
            rows = conn.execute(
                f"SELECT id, {column} AS p FROM {table} WHERE {column} IS NOT NULL "
                f"AND {column} != ''"
            ).fetchall()
            n = 0
            for r in rows:
                new = _relocated(r["p"], root)
                if new is None:
                    already += 1
                    continue
                if not Path(new).is_file():
                    missing += 1
                    if missing <= 5:
                        print(f"  ! no file at {new}")
                    continue
                n += 1
                if args.apply:
                    conn.execute(f"UPDATE {table} SET {column} = ? WHERE id = ?",
                                 (new, r["id"]))
            changed += n
            if n:
                print(f"  {table}.{column}: {n} row(s) repointed")

    print()
    print(f"repointed        : {changed}")
    print(f"already correct  : {already}")
    print(f"file not found   : {missing}")
    if not args.apply and changed:
        print("\nRe-run with --apply to write the changes.")
    elif not changed:
        print("\nNothing to do — the database already matches this install.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
