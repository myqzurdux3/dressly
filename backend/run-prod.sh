#!/usr/bin/env bash
# Production launcher.
#
# Differs from run.sh in that it does not enable --reload (which watches the
# filesystem and restarts on any change) and it refuses to start unless the
# security-relevant environment is set — see config.py's _check_production_config.
#
# Serves HTTPS directly when backend/certs/ holds a certificate:
#   python scripts/make_cert.py --host <your-public-ip>
#
# Usage:
#   cp .env.example .env && $EDITOR .env
#   ./run-prod.sh
set -euo pipefail
cd "$(dirname "$0")"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

: "${CLOTHESAPP_ENV:=prod}"
export CLOTHESAPP_ENV

if [[ "${CLOTHESAPP_SECRET:-}" == "" ]]; then
  cat >&2 <<'EOF'
CLOTHESAPP_SECRET is not set.

It is the key that signs login tokens. Any random string of 32+ bytes will do —
it just has to stay secret and stay the same (changing it logs everyone out).

  python -c 'import secrets; print(secrets.token_urlsafe(48))'
EOF
  exit 1
fi

HOST="${CLOTHESAPP_HOST:-0.0.0.0}"
PORT="${CLOTHESAPP_PORT:-8000}"
# The counters and job ownership live in SQLite, so several workers stay
# consistent with each other. Keep it modest: background image generation is
# CPU-bound and every worker holds its own rembg model in memory (~200 MB).
WORKERS="${CLOTHESAPP_WORKERS:-3}"

TLS_ARGS=()
if [[ -f certs/server.crt && -f certs/server.key ]]; then
  TLS_ARGS=(--ssl-certfile certs/server.crt --ssl-keyfile certs/server.key)
  echo "TLS: serving https://$HOST:$PORT with certs/server.crt"
  if [[ "${CLOTHESAPP_TLS_SELF_SIGNED:-1}" != "0" ]]; then
    echo "     self-signed — the app must pin its fingerprint, see"
    echo "     scripts/make_cert.py and apiCertSha256 in api_config.dart"
  fi
else
  echo "WARNING: no certs/server.crt — serving plain HTTP on $HOST:$PORT." >&2
  echo "         Logins, tokens and photos will travel in clear." >&2
  echo "         Generate one with: python scripts/make_cert.py" >&2
fi

exec python -m uvicorn main:app \
  --host "$HOST" \
  --port "$PORT" \
  --workers "$WORKERS" \
  --proxy-headers \
  --forwarded-allow-ips="${CLOTHESAPP_TRUSTED_PROXIES:-127.0.0.1}" \
  "${TLS_ARGS[@]}"
