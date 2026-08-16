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
PORT="${CLOTHESAPP_PORT:-80}"
# The counters and job ownership live in SQLite, so several workers stay
# consistent with each other. Workers are cheap now (~40 MB each): background
# removal runs in a short-lived child process, so no worker holds the 660 MB
# that onnxruntime never gives back. See cutout.py.
WORKERS="${CLOTHESAPP_WORKERS:-3}"

# Thread count for background removal, passed down to the cut-out child process
# (cutout.py). Set here because only the launcher knows how many workers there
# will be, and each worker can spawn a child of its own. Left unset, three
# workers each grabbing every core turned a 2 s cut-out into 30 s of context
# switching.
#
# Naming it at all is also what stops onnxruntime pinning threads to cores,
# which a VPS cgroup refuses:
#   pthread_setaffinity_np failed for thread: ..., error code: 22
if [[ -z "${OMP_NUM_THREADS:-}" ]]; then
  if [[ -n "${CLOTHESAPP_REMBG_THREADS:-}" ]]; then
    OMP_NUM_THREADS="$CLOTHESAPP_REMBG_THREADS"
  else
    # nproc honours the cgroup quota and the CPU affinity mask; /proc/cpuinfo
    # does not, and reports the whole host on a VPS.
    cpus="$(nproc 2>/dev/null || echo 2)"
    OMP_NUM_THREADS=$(( cpus / WORKERS ))
    (( OMP_NUM_THREADS < 1 )) && OMP_NUM_THREADS=1
  fi
fi
export OMP_NUM_THREADS OMP_THREAD_LIMIT="$OMP_NUM_THREADS"
echo "Threads: $OMP_NUM_THREADS per worker for background removal ($WORKERS workers)"

# Can we actually take the port? Asked by opening it, not by reasoning about it.
#
# An earlier version predicted the answer: "port < 1024 and not root, unless the
# python binary carries cap_net_bind_service". That was wrong under systemd,
# where the capability is granted to the PROCESS (AmbientCapabilities) and the
# binary has no file capability at all. So it refused to start a service that
# would have worked, Restart=always retried it every five seconds, and
# `systemctl start dressly` hung forever waiting for a unit that never settled.
#
# Opening the socket answers the real question and catches the other reason a
# start fails — something is already listening — which no amount of reasoning
# about capabilities would have found.
probe=$(python3 - "$HOST" "$PORT" <<'PY'
import socket, sys
host, port = sys.argv[1], int(sys.argv[2])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind((host, port))
    print("ok")
except PermissionError:
    print("denied")
except OSError as e:
    print("inuse" if e.errno in (98, 48) else f"error:{e}")
finally:
    s.close()
PY
) || probe="error:could not probe"

case "$probe" in
  ok) ;;
  denied)
    cat >&2 <<EOF
Cannot listen on port $PORT as $(whoami): ports below 1024 are privileged.

uvicorn reports this as "[Errno 13] Permission denied", which never mentions the
port. Pick one:

  1. Run it as a systemd service, which grants the permission to this service
     alone — and restarts it on boot and after a crash, so it stops dying with
     the terminal it was started from:

       sudo scripts/install_service.sh

  2. Let this interpreter bind low ports. One command, but it applies to every
     python3 script on the machine:

       sudo setcap cap_net_bind_service=+ep \$(readlink -f \$(command -v python3))

  3. Use a high port and map it in the proxy in front. With Cloudflare, add an
     Origin Rule rewriting the destination port:

       CLOTHESAPP_PORT=8443    in .env
EOF
    exit 1 ;;
  inuse)
    cat >&2 <<EOF
Port $PORT on $HOST is already taken — most likely this server is already
running somewhere else.

  ss -ltnp | grep :$PORT        who has it
  tmux ls                       an older copy left in a terminal session
  systemctl status dressly      one started as a service

Stop that one before starting this one. Starting a second copy would fail the
same way every five seconds, and under systemd that makes \`systemctl start\`
hang rather than report anything.
EOF
    exit 1 ;;
  *)
    echo "Could not check whether port $PORT is free (${probe#error:})." >&2
    echo "Continuing; uvicorn will report the real error." >&2 ;;
esac

TLS_ARGS=()
if [[ -f certs/server.crt && -f certs/server.key ]]; then
  TLS_ARGS=(--ssl-certfile certs/server.crt --ssl-keyfile certs/server.key)
  echo "TLS: serving https://$HOST:$PORT with certs/server.crt"
  if [[ "${CLOTHESAPP_TLS_SELF_SIGNED:-1}" != "0" ]]; then
    echo "     self-signed — the app must pin its fingerprint, see"
    echo "     scripts/make_cert.py and apiCertSha256 in api_config.dart"
  fi
elif [[ "${CLOTHESAPP_ALLOW_PLAINTEXT:-0}" == "1" ]]; then
  echo "WARNING: no certificate — serving plain HTTP on $HOST:$PORT." >&2
  echo "         Logins, tokens and photos travel in clear." >&2
else
  # Refuse rather than quietly downgrade. Falling back to HTTP looks like it
  # worked, then the app — which speaks HTTPS — fails with an opaque
  # "handshake error ... wrong version number", pointing nowhere near the cause.
  cat >&2 <<'EOF'
No TLS certificate found (certs/server.crt + certs/server.key).

Refusing to start in plain HTTP: the app connects over HTTPS, so it would fail
with "Handshake error in client (wrong version number)" — an error that says
nothing about the real problem, which is here.

Generate one:

  python scripts/make_cert.py --host <this server's public IP>

then put the fingerprint it prints into apiCertSha256 in
dressly/lib/config/api_config.dart and rebuild the app.

To run without TLS anyway (local testing only):

  CLOTHESAPP_ALLOW_PLAINTEXT=1 ./run-prod.sh
EOF
  exit 1
fi

# Pre-flight: run every check above and stop, without taking the port. Lets you
# validate a .env change before restarting a server people are using, and lets
# the tests exercise the refusals without one of them starting a real server and
# hanging the suite.
if [[ "${CLOTHESAPP_CHECK_ONLY:-0}" == "1" ]]; then
  echo "Configuration looks startable (checked, not started)."
  exit 0
fi

exec python3 -m uvicorn main:app \
  --host "$HOST" \
  --port "$PORT" \
  --workers "$WORKERS" \
  --proxy-headers \
  --forwarded-allow-ips="${CLOTHESAPP_TRUSTED_PROXIES:-127.0.0.1}" \
  "${TLS_ARGS[@]}"
