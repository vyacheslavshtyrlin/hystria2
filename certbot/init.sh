#!/bin/bash
# Первичный выпуск SSL сертификата через Let's Encrypt (standalone)
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

# ── 3. Выпускаем сертификат (standalone — certbot сам слушает :80) ──
if certbot certificates 2>/dev/null | grep -q "Domains: .*${DOMAIN}"; then
  warn "Сертификат для ${DOMAIN} уже существует, пропускаем."
else
  log "Выпускаем сертификат для: $DOMAIN"
  certbot certonly --standalone \
    --email "$EMAIL" \
    --agree-tos \
    --no-eff-email \
    --non-interactive \
    -d "$DOMAIN"
fi

# ── 4. Подставляем домен в конфиг nginx (идемпотентно) ────────
log "Обновляем конфиг nginx..."
sed -i "s/DOMAIN_PLACEHOLDER/$DOMAIN/g" "$ROOT/nginx/conf.d/default.conf"

# ── 5. Настраиваем автообновление через cron ──────────────────
CRON_JOB="0 3 * * * certbot renew --quiet --pre-hook 'docker compose -f $ROOT/docker-compose.yml stop nginx' --post-hook 'docker compose -f $ROOT/docker-compose.yml start nginx'"
EXISTING_CRON=$(crontab -l 2>/dev/null || true)
FILTERED_CRON=$(printf '%s' "$EXISTING_CRON" | grep -v 'certbot renew' || true)
printf '%s\n%s\n' "$FILTERED_CRON" "$CRON_JOB" | crontab -
log "Автообновление сертификата настроено (cron, каждую ночь в 03:00)"

# ── 6. Запускаем nginx с HTTPS ────────────────────────────────
log "Запускаем nginx..."
docker compose -f "$ROOT/docker-compose.yml" start nginx

echo ""
echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}  SSL готов!${NC}"
echo -e "  Домен : https://${DOMAIN}"
echo -e "${GREEN}======================================${NC}"
