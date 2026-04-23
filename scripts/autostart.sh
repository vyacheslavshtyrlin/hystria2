#!/bin/bash
# Регистрируем systemd сервис для автостарта docker compose после ребута
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GREEN='\033[0;32m'; NC='\033[0m'
log() { echo -e "${GREEN}[+]${NC} $*"; }

SERVICE_FILE="/etc/systemd/system/proxy-stack.service"

log "Создаём systemd unit: proxy-stack..."

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Proxy Stack (nginx + h-ui + mtproxy + fail2ban)
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${ROOT}
ExecStart=/usr/bin/docker compose up -d --remove-orphans
ExecStop=/usr/bin/docker compose down
ExecReload=/usr/bin/docker compose pull && /usr/bin/docker compose up -d --remove-orphans
TimeoutStartSec=120
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable proxy-stack.service
systemctl start  proxy-stack.service

log "Сервис зарегистрирован и запущен."
echo ""
echo "  systemctl status proxy-stack   — статус"
echo "  systemctl restart proxy-stack  — перезапуск"
echo "  journalctl -u proxy-stack -f   — логи"
