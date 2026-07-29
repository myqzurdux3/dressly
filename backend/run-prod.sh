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

# Load .env as DEFAULTS: a variable already exported in the shell wins.
#
# `source .env` would do the opposite. Since .env.example ships
# CLOTHESAPP_SECRET= (empty, to be filled in), sourcing it silently wiped a
# secret the operator had just exported, and the script then reported it as
# unset — confusing, and exactly the wrong way round.
load_env_defaults() {
  local file="$1" line key value
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%$'\r'}"                       # tolerate CRLF
    [[ "$line" =~ ^[[:space:]]*# ]] && continue  # comment
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue  # blank
    [[ "$line" != *=* ]] && continue
    key="${line%%=*}"
    key="${key#"${key%%[![:space:]]*}"}"         # trim leading space
    key="${key%"${key##*[![:space:]]}"}"         # trim trailing space
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    value="${line#*=}"
    # Strip one layer of surrounding quotes, if present.
    if [[ "$value" == \"*\" || "$value" == \'*\' ]]; then
      value="${value:1:${#value}-2}"
    fi
    # Only fill in what the environment has not already provided.
    if [[ -z "${!key:-}" ]]; then
      export "$key=$value"
    fi
  done < "$file"
}

load_env_defaults .env

: "${CLOTHESAPP_ENV:=prod}"
export CLOTHESAPP_ENV

if [[ "${CLOTHESAPP_SECRET:-}" == "" ]]; then
  cat >&2 <<'EOF'
CLOTHESAPP_SECRET is not set.

It is the key that signs login tokens. Any random string of 32+ bytes will do —
it just has to stay secret and stay the same (changing it signs everyone out).

  python -c 'import secrets; print(secrets.token_urlsafe(48))'

Put it in .env (CLOTHESAPP_SECRET=...) or export it before running this script.
An exported value takes precedence over .env, so a blank line in .env will not
override one you set by hand.
EOF
  exit 1
fi

if (( ${#CLOTHESAPP_SECRET} < 32 )); then
  echo "CLOTHESAPP_SECRET is only ${#CLOTHESAPP_SECRET} characters; it needs 32+." >&2
  echo "The server would refuse to start anyway — see config.py." >&2
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
