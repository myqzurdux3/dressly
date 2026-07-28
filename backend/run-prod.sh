#!/usr/bin/env bash
# Production launcher. Unlike run.sh it does not enable --reload (which watches
# the filesystem and restarts on any change) and it refuses to start unless the
# security-relevant environment is set — see config.py's _check_production_config.
#
# Usage:
#   cp .env.example .env && $EDITOR .env      # fill in the secrets
#   ./run-prod.sh
set -euo pipefail
cd "$(dirname "$0")"

# Load .env if present, without exporting stray shell state.
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

: "${CLOTHESAPP_ENV:=prod}"
export CLOTHESAPP_ENV

if [[ "${CLOTHESAPP_SECRET:-}" == "" ]]; then
  echo "CLOTHESAPP_SECRET is not set." >&2
  echo "Generate one with:" >&2
  echo "  python -c 'import secrets; print(secrets.token_urlsafe(48))'" >&2
  exit 1
fi

# ONE worker on purpose. The rate limiter counts in process memory and the
# generation queue is in-process too, so a second worker would silently double
# every quota and lose track of running jobs. Scaling out needs a shared store
# (Redis) first.
exec python -m uvicorn main:app \
  --host "${CLOTHESAPP_HOST:-127.0.0.1}" \
  --port "${CLOTHESAPP_PORT:-8000}" \
  --workers 1 \
  --proxy-headers \
  --forwarded-allow-ips="${CLOTHESAPP_TRUSTED_PROXIES:-127.0.0.1}"
