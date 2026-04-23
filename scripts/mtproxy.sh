#!/bin/bash
# Установка MTProtoProxy через HirbodBehnam/MTProtoProxyInstaller
# Создаёт systemd сервис напрямую на хосте (без Docker)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/.env"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }

MTPROXY_PORT_VAL="${MTPROXY_PORT:-8443}"

# ── Открываем порт в UFW ───────────────────────────────────────
log "Открываем порт ${MTPROXY_PORT_VAL}/tcp в UFW..."
ufw allow "${MTPROXY_PORT_VAL}/tcp" comment 'MTProxy Telegram'

# ── Скачиваем и запускаем установщик ──────────────────────────
log "Запускаем MTProtoProxyInstaller..."
warn "Установщик задаст несколько вопросов:"
warn "  - Какую реализацию использовать → рекомендуем [2] Official C (стабильная)"
warn "  - Порт → введи: ${MTPROXY_PORT_VAL}"
warn "  - Секрет → нажми Enter для автогенерации (или введи свой ee-секрет)"
warn "  - Tag → опционально, для статистики в @MTProxybot"
echo ""

curl -o /tmp/MTProtoProxyInstall.sh -L \
  https://raw.githubusercontent.com/HirbodBehnam/MTProtoProxyInstaller/master/MTProtoProxyInstall.sh

bash /tmp/MTProtoProxyInstall.sh

rm -f /tmp/MTProtoProxyInstall.sh

echo ""
log "MTProxy установлен как systemd сервис."
echo ""
echo "  systemctl status MTProxy   — статус"
echo "  systemctl restart MTProxy  — перезапуск"
echo "  journalctl -u MTProxy -f   — логи"
echo ""
warn "Ссылку для подключения установщик показал выше."
warn "Убедись что секрет начинается с 'ee' — это fake-TLS режим (защита от DPI)."
