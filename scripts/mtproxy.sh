#!/bin/bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

[ "$(id -u)" != "0" ] && die "Запускай от root"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/.env"

# MTProxy слушает на loopback — снаружи доступен через nginx :443
MTPROXY_PORT=2083

warn "Когда установщик спросит порт — введи: ${MTPROXY_PORT}"
echo ""

curl -o /tmp/MTProtoProxyInstall.sh -L \
    https://raw.githubusercontent.com/HirbodBehnam/MTProtoProxyInstaller/master/MTProtoProxyInstall.sh
bash /tmp/MTProtoProxyInstall.sh
rm -f /tmp/MTProtoProxyInstall.sh

# ─── Читаем секрет из systemd-сервиса, строим ссылку с портом 443 ─────────────
MT_SECRET=$(systemctl cat MTProxy 2>/dev/null | grep -oP '(?<=-S )\S+' | head -1 || true)

echo ""
if [ -n "$MT_SECRET" ]; then
    log "Ссылка для Telegram (порт 443 через nginx):"
    echo ""
    echo "  tg://proxy?server=${DOMAIN}&port=443&secret=${MT_SECRET}"
    echo "  https://t.me/proxy?server=${DOMAIN}&port=443&secret=${MT_SECRET}"
    echo ""
    if [[ "$MT_SECRET" != ee* ]]; then
        warn "Секрет не начинается с 'ee' — fake-TLS не активен."
        warn "Для fake-TLS переустанови и введи секрет вручную: ee$(openssl rand -hex 16)"
    fi

    [ -f ~/INSTALL_INFO.txt ] && {
        echo "" >> ~/INSTALL_INFO.txt
        echo "MTProxy: tg://proxy?server=${DOMAIN}&port=443&secret=${MT_SECRET}" >> ~/INSTALL_INFO.txt
    }
else
    warn "Не удалось прочитать секрет из сервиса MTProxy."
    warn "Возьми секрет из вывода установщика и замени порт на 443:"
    echo "  tg://proxy?server=${DOMAIN}&port=443&secret=<секрет>"
fi

echo ""
echo "  systemctl status MTProxy   — статус"
echo "  journalctl -u MTProxy -f   — логи"
