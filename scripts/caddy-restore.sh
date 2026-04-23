#!/bin/bash
# Добавляет stub-сайт в Caddyfile (запускать после hys2 → Web Panel → Start)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/.env"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }

CADDYFILE="/etc/caddy/Caddyfile"

if grep -q "$DOMAIN" "$CADDYFILE" 2>/dev/null; then
  warn "Stub-сайт уже есть в Caddyfile, пропускаем."
  exit 0
fi

chmod o+rx "$ROOT" "$ROOT/www"

STUB_BLOCK="${DOMAIN} {
    root * ${ROOT}/www
    file_server
    encode gzip
    header {
        X-Frame-Options DENY
        X-Content-Type-Options nosniff
        Referrer-Policy no-referrer
        -Server
    }
}"

EXISTING=$(cat "$CADDYFILE")
cat > "$CADDYFILE" <<EOF
${STUB_BLOCK}

${EXISTING}
EOF

log "Stub-сайт добавлен. Перезапускаем Caddy..."
systemctl restart caddy
log "Готово. Проверь: https://${DOMAIN}"
