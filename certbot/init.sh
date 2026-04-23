#!/bin/bash
# Первичный выпуск SSL сертификатов через Let's Encrypt
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/.env"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

[ "$DOMAIN" = "example.com" ] && die "Заполни .env: DOMAIN не настроен"
[ -z "$EMAIL" ]               && die "Заполни .env: EMAIL не задан"

# Скачиваем рекомендуемые параметры SSL если их нет
if [ ! -f "$ROOT/certbot/conf/options-ssl-nginx.conf" ]; then
  log "Скачиваем параметры SSL..."
  mkdir -p "$ROOT/certbot/conf"
  curl -fsSL \
    "https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf" \
    -o "$ROOT/certbot/conf/options-ssl-nginx.conf"
  openssl dhparam -out "$ROOT/certbot/conf/ssl-dhparams.pem" 2048
fi

log "Запускаем nginx (только HTTP) для прохождения challenge..."
docker compose -f "$ROOT/docker-compose.yml" up -d nginx

sleep 3

issue_cert() {
  local domain="$1"
  log "Выпускаем сертификат для: $domain"
  docker compose -f "$ROOT/docker-compose.yml" run --rm certbot certonly \
    --webroot \
    --webroot-path=/var/www/certbot \
    --email "$EMAIL" \
    --agree-tos \
    --no-eff-email \
    --force-renewal \
    -d "$domain"
}

issue_cert "$DOMAIN"
issue_cert "$HUI_SUBDOMAIN"

log "Подставляем домены в конфиги nginx..."
sed -i "s/DOMAIN_PLACEHOLDER/$DOMAIN/g"               "$ROOT/nginx/conf.d/default.conf"
sed -i "s/HUI_SUBDOMAIN_PLACEHOLDER/$HUI_SUBDOMAIN/g" "$ROOT/nginx/conf.d/h-ui.conf"

log "Перезапускаем nginx с HTTPS..."
docker compose -f "$ROOT/docker-compose.yml" restart nginx

echo ""
echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}  SSL готов!${NC}"
echo -e "  Основной домен : https://${DOMAIN}"
echo -e "  h-ui панель    : https://${HUI_SUBDOMAIN}"
echo -e "${GREEN}======================================${NC}"
