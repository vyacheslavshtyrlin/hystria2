#!/bin/bash
# Register systemd autostart for docker compose stack.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GREEN='\033[0;32m'; NC='\033[0m'
log() { echo -e "${GREEN}[+]${NC} $*"; }

[ "$(id -u)" != "0" ] && { echo "Run as root"; exit 1; }

DOCKER_BIN="$(command -v docker)"
SERVICE_FILE="/etc/systemd/system/proxy-stack.service"

log "Creating systemd unit: proxy-stack..."

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Proxy Stack (fail2ban + watchtower)
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${ROOT}
ExecStart=${DOCKER_BIN} compose up -d --remove-orphans
ExecStop=${DOCKER_BIN} compose down
ExecReload=/bin/sh -c '${DOCKER_BIN} compose pull && ${DOCKER_BIN} compose up -d --remove-orphans'
TimeoutStartSec=180
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable proxy-stack.service
systemctl restart proxy-stack.service

log "Service registered and started."
echo ""
echo "  systemctl status proxy-stack"
echo "  systemctl restart proxy-stack"
echo "  journalctl -u proxy-stack -f"
