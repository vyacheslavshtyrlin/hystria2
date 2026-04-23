#!/bin/bash
# Initial Let's Encrypt certificate issue for Ubuntu 22.04.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/.env"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }

[ "$(id -u)" != "0" ] && die "Run as root: sudo bash certbot/init.sh"
[ "${DOMAIN:-}" = "example.com" ] && die "Set DOMAIN in .env"
: "${DOMAIN:?Set DOMAIN in .env}"
: "${HUI_SUBDOMAIN:?Set HUI_SUBDOMAIN in .env}"
: "${EMAIL:?Set EMAIL in .env}"

DOCKER_BIN="$(command -v docker || true)"
[ -z "$DOCKER_BIN" ] && die "Docker is not installed"

CERTBOT_CONFIG_DIR="$ROOT/certbot/conf"
CERTBOT_WORK_DIR="$ROOT/certbot/work"
CERTBOT_LOGS_DIR="$ROOT/certbot/logs"
mkdir -p "$CERTBOT_CONFIG_DIR" "$CERTBOT_WORK_DIR" "$CERTBOT_LOGS_DIR"

if ! command -v certbot >/dev/null 2>&1; then
  log "Installing certbot..."
  apt-get update -qq
  apt-get install -y -qq certbot
fi

if ! command -v crontab >/dev/null 2>&1; then
  log "Installing cron..."
  apt-get update -qq
  apt-get install -y -qq cron
fi

systemctl enable --now cron >/dev/null 2>&1 || service cron start >/dev/null 2>&1 || warn "Could not start cron service automatically"

log "Stopping nginx before standalone certbot..."
"$DOCKER_BIN" compose -f "$ROOT/docker-compose.yml" stop nginx >/dev/null 2>&1 || true

issue_cert() {
  local domain="$1"

  if certbot --config-dir "$CERTBOT_CONFIG_DIR" certificates 2>/dev/null | grep -q "Domains: .*${domain}"; then
    warn "Certificate for ${domain} already exists, skipping."
    return 0
  fi

  log "Issuing certificate for: $domain"
  certbot certonly --standalone \
    --config-dir "$CERTBOT_CONFIG_DIR" \
    --work-dir "$CERTBOT_WORK_DIR" \
    --logs-dir "$CERTBOT_LOGS_DIR" \
    --email "$EMAIL" \
    --agree-tos \
    --no-eff-email \
    --non-interactive \
    -d "$domain"
}

issue_cert "$DOMAIN"
issue_cert "$HUI_SUBDOMAIN"

log "Updating nginx configs..."
sed -i "s/DOMAIN_PLACEHOLDER/$DOMAIN/g" "$ROOT/nginx/conf.d/default.conf"
sed -i "s/HUI_SUBDOMAIN_PLACEHOLDER/$HUI_SUBDOMAIN/g" "$ROOT/nginx/conf.d/h-ui.conf"

log "Configuring certbot renewal in crontab..."
CRON_JOB="0 3 * * * certbot renew --quiet --config-dir $CERTBOT_CONFIG_DIR --work-dir $CERTBOT_WORK_DIR --logs-dir $CERTBOT_LOGS_DIR --pre-hook '$DOCKER_BIN compose -f $ROOT/docker-compose.yml stop nginx' --post-hook '$DOCKER_BIN compose -f $ROOT/docker-compose.yml up -d nginx'"
{ crontab -l 2>/dev/null || true; } | { grep -v 'certbot renew' || true; } | { cat; echo "$CRON_JOB"; } | crontab -
log "Certificate auto-renewal configured in cron at 03:00"

log "Starting nginx..."
"$DOCKER_BIN" compose -f "$ROOT/docker-compose.yml" up -d nginx

echo ""
echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN} SSL is ready${NC}"
echo -e " Main domain : https://${DOMAIN}"
echo -e " h-ui panel  : https://${HUI_SUBDOMAIN}"
echo -e "${GREEN}======================================${NC}"
