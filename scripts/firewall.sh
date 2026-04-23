#!/bin/bash
# Настройка UFW
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/.env"
MTPROXY_PORT_VAL="${MTPROXY_PORT:-8443}"
BLITZ_PORT_VAL="${BLITZ_PORT:-2096}"
SSH_PORT="${SSH_PORT:-22}"

# ── 1. Дефолтные политики ──────────────────────────────────────
log "Устанавливаем политики по умолчанию..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw default deny forward

# ── 2. SSH с rate limiting ─────────────────────────────────────
log "Разрешаем SSH на порту $SSH_PORT с rate limiting..."
ufw limit "${SSH_PORT}/tcp" comment 'SSH rate-limited'

# ── 3. Публичные порты ─────────────────────────────────────────
log "Разрешаем публичные порты..."
ufw allow 80/tcp  comment 'HTTP (certbot + редирект)'
ufw allow 443/tcp comment 'HTTPS (nginx stub site)'
ufw allow 443/udp comment 'Hysteria2 QUIC'
ufw allow "${MTPROXY_PORT_VAL}/tcp" comment 'MTProxy Telegram'
ufw allow "${BLITZ_PORT_VAL}/tcp"   comment 'Blitz panel'

# ── 4. Docker daemon — логи ────────────────────────────────────
log "Настраиваем Docker daemon..."
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF

# ── 5. Включаем UFW ────────────────────────────────────────────
log "Включаем UFW..."
ufw --force enable
ufw status verbose

# ── 6. Перезапускаем Docker чтобы подхватил daemon.json ───────
if systemctl is-active --quiet docker; then
  log "Перезапускаем Docker..."
  systemctl restart docker
fi

echo ""
echo -e "${GREEN}Фаервол настроен.${NC}"
echo -e "Открытые порты:"
echo -e "  ${SSH_PORT}/tcp        — SSH (rate-limited)"
echo -e "  80/tcp         — HTTP"
echo -e "  443/tcp        — HTTPS (stub site)"
echo -e "  443/udp        — Hysteria2"
echo -e "  ${MTPROXY_PORT_VAL}/tcp  — MTProxy"
echo -e "  ${BLITZ_PORT_VAL}/tcp    — Blitz panel"
