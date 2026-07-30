#!/usr/bin/env bash
# Install the backend as a systemd service.
#
# Solves three things at once:
#
#   1. Port 80/443. systemd grants CAP_NET_BIND_SERVICE to THIS service only,
#      so the app can listen on a privileged port without running as root and
#      without giving every python3 script on the machine that power.
#   2. It survives. Running it in tmux means the server dies with the session,
#      and stays dead after a reboot until someone notices.
#   3. It comes back. Restart=always covers the crash nobody is watching.
#
# Usage, from the backend directory:
#
#     sudo scripts/install_service.sh
#
# Afterwards:
#
#     systemctl status dressly
#     journalctl -u dressly -f      # the log run-prod.sh used to print in tmux
#     sudo systemctl restart dressly
set -euo pipefail

BACKEND="$(cd "$(dirname "$0")/.." && pwd)"
UNIT=/etc/systemd/system/dressly.service
SERVICE_USER="${SUDO_USER:-$(whoami)}"

if [[ "$(id -u)" != "0" ]]; then
  echo "Run with sudo: sudo scripts/install_service.sh" >&2
  exit 1
fi

if [[ ! -x "$BACKEND/run-prod.sh" ]]; then
  echo "run-prod.sh is not executable at $BACKEND" >&2
  exit 1
fi

if [[ "$SERVICE_USER" == "root" ]]; then
  echo "Refusing to run the server as root: the whole point of the capability" >&2
  echo "below is that it does not have to. Run this with sudo from the account" >&2
  echo "that owns $BACKEND." >&2
  exit 1
fi

echo "Installing $UNIT"
echo "  directory: $BACKEND"
echo "  user:      $SERVICE_USER"

cat > "$UNIT" <<EOF
[Unit]
Description=Dressly backend
After=network-online.target
Wants=network-online.target

[Service]
Type=exec
User=$SERVICE_USER
WorkingDirectory=$BACKEND
ExecStart=$BACKEND/run-prod.sh

# Lets it bind 80/443 without being root. Ambient is the part that matters:
# Capability alone would be dropped the moment the process stops being root,
# which it never is here.
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

Restart=always
RestartSec=5
# Do not give up after a burst of quick failures — a misconfigured .env would
# otherwise leave the server permanently down after five minutes of retries.
StartLimitIntervalSec=0

# The data directory is the only thing it needs to write. ProtectSystem=full
# leaves /usr and /boot read-only; the cut-out child process still works, it
# writes under the data directory like everything else.
ProtectSystem=full
# Ambient capabilities are granted by systemd before exec, so this costs the
# service nothing and blocks a whole class of privilege escalation.
NoNewPrivileges=true

StandardOutput=journal
StandardError=journal
SyslogIdentifier=dressly

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable dressly >/dev/null
echo
echo "Installed. If the server is currently running in tmux, stop it there first"
echo "(Ctrl-C), or this will fail to bind the port:"
echo
echo "    sudo systemctl start dressly"
echo "    systemctl status dressly"
echo "    journalctl -u dressly -f"
