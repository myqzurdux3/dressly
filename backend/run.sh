#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
exec python -m uvicorn main:app --host 0.0.0.0 --port 80 --reload