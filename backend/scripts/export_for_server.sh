#!/usr/bin/env bash
# Package the backend for deployment onto a server.
#
# Use tar, not zip. Image files are stored once on disk and hard-linked into
# two places (data/images/<cloth_id>/… and the content-addressed data/blobs/…),
# so there are ~1000 paths for ~550 real files. tar records the second path as a
# link and restores it as one; zip has no concept of hard links and copies the
# bytes again, which is why a 400 MB directory becomes an 800 MB zip.
#
# Nothing here is compressed further by default: JPEG and WebP are already
# compressed, so gzip costs minutes and saves almost nothing. Pass --gzip if the
# transfer is slower than the CPU.
#
#   ./scripts/export_for_server.sh                  # -> dressly-backend.tar
#   ./scripts/export_for_server.sh --no-data        # code only
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${OUT:-$PWD/../dressly-backend.tar}"
COMPRESS=""
INCLUDE_DATA=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --gzip) COMPRESS="z"; OUT="${OUT%.tar}.tar.gz" ;;
    --no-data) INCLUDE_DATA=0 ;;
    --out) OUT="$2"; shift ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

# Excluded on purpose:
#   thumbs/, staging/  derived or transient — regenerated on demand
#   logs/              belong to the machine that produced them
#   certs/, .env       secrets. The certificate must be regenerated on the
#                      server anyway (it is issued for that host's address),
#                      and the .env carries CLOTHESAPP_SECRET, which should
#                      travel through a password manager rather than a tarball.
EXCLUDES=(
  --exclude=./data/thumbs
  --exclude=./data/staging
  --exclude=./data/logs
  --exclude=./certs
  --exclude=./.env
  --exclude=./__pycache__
  --exclude=./tests/__pycache__
  --exclude=./.pytest_cache
  --exclude='*.pyc'
)
[[ $INCLUDE_DATA -eq 1 ]] || EXCLUDES+=(--exclude=./data)

echo "packing $PWD -> $OUT"
# GNU tar detects hard links and stores the later ones as links by default.
tar -c${COMPRESS}f "$OUT" "${EXCLUDES[@]}" -C "$PWD" .

real=$(du -sh --exclude=data/thumbs --exclude=data/logs . | cut -f1)
size=$(du -h "$OUT" | cut -f1)
echo
echo "source (real disk usage) : $real"
echo "archive                  : $size"
echo
cat <<EOF
On the server:

  mkdir -p /opt/dressly && tar -x${COMPRESS}f $(basename "$OUT") -C /opt/dressly
  cd /opt/dressly
  pip install -r requirements.txt

  # Secrets are NOT in the archive — recreate them there:
  cp .env.example .env
  python -c 'import secrets; print(secrets.token_urlsafe(48))'   # CLOTHESAPP_SECRET
  python scripts/make_cert.py --host <the server's public IP>    # prints the pin

  # Image locations are stored as absolute paths, so the database still points
  # at the old machine. Without this every image 404s.
  python scripts/relocate_paths.py            # check
  python scripts/relocate_paths.py --apply

  ./run-prod.sh

Then put the printed pin in clothesapp/lib/config/api_config.dart
(apiCertSha256) and rebuild the app.

Verify the hard links survived — the two numbers should differ by roughly 2x:
  du -sh data                                  # real
  du -sh --apparent-size --count-links data    # if links were lost, this is what you get
EOF
