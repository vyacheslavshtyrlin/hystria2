#!/bin/bash
# Настройка UFW с фиксом обхода через Docker
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/.env"
MTPROXY_PORT_VAL="${MTPROXY_PORT:-8443}"
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
ufw allow 443/tcp comment 'HTTPS (nginx)'
ufw allow 443/udp comment 'Hysteria2 QUIC'
ufw allow "${MTPROXY_PORT_VAL}/tcp" comment 'MTProxy Telegram'

# ── 4. Фикс Docker + UFW ──────────────────────────────────────
# Docker напрямую пишет в iptables и обходит UFW.
# Решение: запрещаем Docker управлять iptables для внешних интерфейсов,
# оставляем только localhost и docker-внутренние сети.
log "Применяем фикс Docker + UFW..."

UFW_AFTER="/etc/ufw/after.rules"

# Убираем наш блок если уже есть (идемпотентность)
sed -i '/# DOCKER-UFW-FIX-BEGIN/,/# DOCKER-UFW-FIX-END/d' "$UFW_AFTER"

# Получаем внешний интерфейс (eth0, ens3, enp0s3 и т.д.)
EXT_IF=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
log "Внешний интерфейс: $EXT_IF"

cat >> "$UFW_AFTER" <<EOF

# DOCKER-UFW-FIX-BEGIN
# Блокируем прямой доступ к Docker-портам извне, кроме разрешённых UFW
*filter
:DOCKER-USER - [0:0]
-A DOCKER-USER -i $EXT_IF -p tcp --dport 8081 -j DROP   # h-ui: только через nginx
-A DOCKER-USER -i $EXT_IF -p tcp --dport 2398 -j DROP   # MTProxy internal
-A DOCKER-USER -i $EXT_IF -j RETURN
COMMIT
# DOCKER-UFW-FIX-END
EOF

# ── 5. Daemon Docker — отключаем userland-proxy для чистоты ───
log "Настраиваем Docker daemon..."
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "userland-proxy": false
}
EOF

# ── 6. Включаем UFW ────────────────────────────────────────────
log "Включаем UFW..."
ufw --force enable
ufw status verbose

# ── 7. Перезапускаем Docker чтобы подхватил daemon.json ───────
if systemctl is-active --quiet docker; then
  log "Перезапускаем Docker..."
  systemctl restart docker
fi

echo ""
echo -e "${GREEN}Фаервол настроен.${NC}"
echo -e "Открытые порты:"
echo -e "  22/tcp   — SSH (rate-limited)"
echo -e "  80/tcp   — HTTP"
echo -e "  443/tcp  — HTTPS"
echo -e "  443/udp  — Hysteria2"
echo -e "  ${MTPROXY_PORT_VAL}/tcp  — MTProxy"
echo -e ""
echo -e "Закрыто снаружи (только через nginx/localhost):"
echo -e "  8081     — h-ui панель"
echo -e "  2398     — MTProxy internal"
