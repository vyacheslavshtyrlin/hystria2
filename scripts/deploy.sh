#!/bin/bash
# Полный деплой на чистый Ubuntu 22.04
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

# 1. Проверка .env
[ ! -f "$ROOT/.env" ] && die "Файл .env не найден. Скопируй: cp .env.example .env"
source "$ROOT/.env"
[ "$DOMAIN" = "example.com" ] && die "Заполни .env: DOMAIN не настроен"

# 2. Docker
if ! command -v docker &>/dev/null; then
  log "Устанавливаем Docker..."
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
  usermod -aG docker "$USER" && warn "Добавлен в группу docker. Перелогинься или используй sudo."
fi

# 3. Права на скрипты
chmod +x "$ROOT/scripts/"*.sh "$ROOT/certbot/init.sh"

# 4. Hardening: SSH, sysctl, swap, unattended-upgrades
log "Запускаем hardening..."
bash "$ROOT/scripts/harden.sh"

# 5. Фаервол
log "Настраиваем фаервол..."
bash "$ROOT/scripts/firewall.sh"

# 6. Поднимаем Docker-сервисы
log "Скачиваем образы..."
docker compose -f "$ROOT/docker-compose.yml" pull nginx certbot h-ui fail2ban watchtower

log "Запускаем сервисы без nginx до выпуска SSL..."
docker compose -f "$ROOT/docker-compose.yml" up -d h-ui fail2ban watchtower

# 7. SSL сертификаты
log "Выпускаем SSL сертификаты..."
bash "$ROOT/certbot/init.sh"

log "Запускаем полный compose stack..."
docker compose -f "$ROOT/docker-compose.yml" up -d --remove-orphans

# 8. Автостарт через systemd
log "Регистрируем автостарт..."
bash "$ROOT/scripts/autostart.sh"

# 9. Ждём старта h-ui
log "Ожидаем запуска h-ui..."
for i in $(seq 1 30); do
  if curl -sf "http://127.0.0.1:8081" >/dev/null 2>&1; then break; fi
  sleep 2
done

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║           ДЕПЛОЙ ЗАВЕРШЁН УСПЕШНО            ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}                                              ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  ${YELLOW}h-ui панель${NC}                                  ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  URL    : https://${HUI_SUBDOMAIN}           ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Логин  : admin                              ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Пароль : ${RED}sysadmin${NC} ← СМЕНИТЬ СРАЗУ!          ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}                                              ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  ${YELLOW}Hysteria2${NC} — настроить через h-ui           ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}                                              ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  ${YELLOW}MTProxy${NC} — установить отдельно:             ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  bash scripts/mtproxy.sh                     ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}                                              ${GREEN}║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}  docker compose ps       — статус            ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  docker compose logs -f  — логи              ${GREEN}║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
echo ""

cat > "$ROOT/INSTALL_INFO.txt" <<EOF
Дата деплоя: $(date)

h-ui панель: https://${HUI_SUBDOMAIN}
Логин: admin
Пароль: sysadmin  ← СМЕНИТЬ!

Hysteria2: настроить через h-ui панель (UDP 443)

MTProxy: запустить bash scripts/mtproxy.sh
EOF
warn "Данные сохранены в INSTALL_INFO.txt — удали после первого входа!"
