#!/bin/bash
# Установка CrowdSec — IDS с общей базой репутации IP
# Работает параллельно с fail2ban, дополняет его
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }

[ "$(id -u)" != "0" ] && { echo "Нужен root"; exit 1; }

# ── Установка ─────────────────────────────────────────────────
log "Устанавливаем CrowdSec..."
curl -s https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | bash
apt-get install -y crowdsec crowdsec-firewall-bouncer-iptables

# ── Коллекции (наборы правил) ─────────────────────────────────
log "Добавляем коллекции правил..."
cscli collections install \
  crowdsecurity/nginx \
  crowdsecurity/sshd \
  crowdsecurity/linux \
  crowdsecurity/base-http-scenarios

# ── Bouncer (блокировщик через iptables) ─────────────────────
log "Настраиваем iptables bouncer..."
systemctl enable --now crowdsec
systemctl enable --now crowdsec-firewall-bouncer

# ── Подключаем к nginx логам ──────────────────────────────────
# CrowdSec автоматически найдёт /var/log/nginx/access.log
# Если nginx в Docker — нужно пробросить логи на хост
NGINX_LOG_DIR="/var/log/nginx"
if [ ! -d "$NGINX_LOG_DIR" ]; then
  warn "Логи nginx не найдены в $NGINX_LOG_DIR"
  warn "Добавь volume в docker-compose: - /var/log/nginx:/var/log/nginx"
fi

# ── Статус ────────────────────────────────────────────────────
echo ""
log "CrowdSec установлен."
echo ""
echo "  cscli decisions list          — кто заблокирован"
echo "  cscli alerts list             — последние инциденты"
echo "  cscli metrics                 — статистика"
echo "  cscli hub update && cscli hub upgrade — обновить правила"
echo ""
warn "Зарегистрируй аккаунт на app.crowdsec.net для доступа к"
warn "глобальной базе репутации IP (Community Blocklist)."
