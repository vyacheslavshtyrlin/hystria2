#!/bin/bash
# Полный деплой на чистый Ubuntu 22.04
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

[ "$(id -u)" != "0" ] && die "Запускай от root: sudo bash scripts/deploy.sh"
export DEBIAN_FRONTEND=noninteractive

[ ! -f "$ROOT/.env" ] && die "Файл .env не найден. Создай: cp .env.example .env"
source "$ROOT/.env"

[ "${DOMAIN:-}" = "example.com" ] && die "Заполни DOMAIN в .env"
: "${DOMAIN:?Заполни DOMAIN в .env}"
: "${EMAIL:?Заполни EMAIL в .env}"

log "Устанавливаем базовые пакеты..."
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg lsb-release ufw cron openssh-server

if ! command -v docker >/dev/null 2>&1; then
  log "Устанавливаем Docker..."
  curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker

TARGET_USER="${SUDO_USER:-${USER:-root}}"
[ "$TARGET_USER" != "root" ] && usermod -aG docker "$TARGET_USER"

chmod +x "$ROOT/scripts/"*.sh "$ROOT/certbot/init.sh"

log "Запускаем hardening..."
bash "$ROOT/scripts/harden.sh"

log "Настраиваем фаервол..."
bash "$ROOT/scripts/firewall.sh"

log "Скачиваем образы..."
docker compose -f "$ROOT/docker-compose.yml" pull

log "Запускаем сервисы..."
docker compose -f "$ROOT/docker-compose.yml" up -d

log "Устанавливаем Blitz (Hysteria2 менеджер)..."
bash <(curl -fsSL https://raw.githubusercontent.com/ReturnFI/Blitz/main/install.sh)

# Даём Caddy права на директорию со stub-сайтом
chmod o+rx "$ROOT" "$ROOT/www"

log "Настраиваем Caddy (stub-сайт)..."
cat > /etc/caddy/Caddyfile <<CADDYEOF
{
    admin off
}

${DOMAIN} {
    root * ${ROOT}/www
    file_server
    encode gzip

    header {
        X-Frame-Options DENY
        X-Content-Type-Options nosniff
        Referrer-Policy no-referrer
        -Server
    }
}
CADDYEOF

systemctl enable caddy
systemctl restart caddy

log "Регистрируем автостарт..."
bash "$ROOT/scripts/autostart.sh"

BLITZ_PORT_VAL="${BLITZ_PORT:-2096}"

cat > "$ROOT/INSTALL_INFO.txt" <<EOF
Дата деплоя: $(date)

Stub-сайт: https://${DOMAIN}

Blitz (Hysteria2):
  Команда: hys2
  Включить панель: Advanced Menu → Web Panel → Start WebPanel
  Порт панели: ${BLITZ_PORT_VAL}
  URL: https://<panel-domain>:${BLITZ_PORT_VAL}/<random-string>/

MTProxy: bash scripts/mtproxy.sh
EOF

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║           ДЕПЛОЙ ЗАВЕРШЁН УСПЕШНО            ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}                                              ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Stub-сайт : https://${DOMAIN}"
echo -e "${GREEN}║${NC}                                              ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Hysteria2 (Blitz):                          ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}    Команда  : hys2                           ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}    Панель   : Advanced → Web Panel → Start   ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}    Порт     : ${BLITZ_PORT_VAL}                              ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}                                              ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  MTProxy: bash scripts/mtproxy.sh            ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}                                              ${GREEN}║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
echo ""
warn "Данные сохранены в INSTALL_INFO.txt — удали после настройки!"
