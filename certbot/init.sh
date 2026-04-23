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

# ── 1. Устанавливаем certbot на хост если нет ─────────────────
if ! command -v certbot &>/dev/null; then
  log "Устанавливаем certbot..."
  apt-get install -y -qq certbot
fi

# ── 2. Останавливаем nginx чтобы освободить порт 80 ───────────
log "Останавливаем nginx на время получения сертификата..."
docker compose -f "$ROOT/docker-compose.yml" stop nginx 2>/dev/null || true

# ── 3. Выпускаем сертификаты (standalone — certbot сам слушает :80) ──
issue_cert() {
  local domain="$1"
  # Если сертификат уже есть и не истекает — пропускаем
  if certbot certificates 2>/dev/null | grep -q "Domains: .*${domain}"; then
    warn "Сертификат для ${domain} уже существует, пропускаем."
    return 0
  fi
  log "Выпускаем сертификат для: $domain"
  certbot certonly --standalone \
    --email "$EMAIL" \
    --agree-tos \
    --no-eff-email \
    --non-interactive \
    -d "$domain"
}

issue_cert "$DOMAIN"
issue_cert "$HUI_SUBDOMAIN"

# ── 4. Подставляем домены в конфиги nginx (идемпотентно) ──────
log "Обновляем конфиги nginx..."
sed -i "s/DOMAIN_PLACEHOLDER/$DOMAIN/g"               "$ROOT/nginx/conf.d/default.conf"
sed -i "s/HUI_SUBDOMAIN_PLACEHOLDER/$HUI_SUBDOMAIN/g" "$ROOT/nginx/conf.d/h-ui.conf"

# ── 5. Настраиваем автообновление через cron ──────────────────
CRON_JOB="0 3 * * * certbot renew --quiet --pre-hook 'docker compose -f $ROOT/docker-compose.yml stop nginx' --post-hook 'docker compose -f $ROOT/docker-compose.yml start nginx'"
{ crontab -l 2>/dev/null || true; } | grep -v 'certbot renew' | { cat; echo "$CRON_JOB"; } | crontab -
log "Автообновление сертификатов настроено (cron, каждую ночь в 03:00)"

# ── 6. Запускаем nginx с HTTPS ────────────────────────────────
log "Запускаем nginx..."
docker compose -f "$ROOT/docker-compose.yml" start nginx

echo ""
echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}  SSL готов!${NC}"
echo -e "  Основной домен : https://${DOMAIN}"
echo -e "  h-ui панель    : https://${HUI_SUBDOMAIN}"
echo -e "${GREEN}======================================${NC}"
