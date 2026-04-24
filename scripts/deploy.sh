#!/bin/bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

[ "$(id -u)" != "0" ] && die "Запускай от root: sudo bash scripts/deploy.sh"
export DEBIAN_FRONTEND=noninteractive

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

[ ! -f "$ROOT/.env" ] && die ".env не найден — скопируй .env.example и заполни"
source "$ROOT/.env"

[ "${DOMAIN:-}" = "example.com" ] && die "Заполни DOMAIN в .env"
: "${DOMAIN:?Заполни DOMAIN в .env}"
: "${EMAIL:?Заполни EMAIL в .env}"
: "${SSH_PORT:?Заполни SSH_PORT в .env}"

chmod +x "$ROOT/scripts/"*.sh

# ─── Внутренние порты (снаружи недоступны) ───────────────────────────────────
XHTTP_PORT=2096
PANEL_PORT=2053
SUB_PORT=2095
MTPROXY_PORT=2083
NGINX_HTTP_PORT=4433
WEBROOT="/var/www/certbot"

# XHTTP_PATH генерируем сами — это путь inbound Xray, не путь панели
if [ -f /etc/proxy-stack.env ]; then
    source /etc/proxy-stack.env
    warn "Конфиг загружен из /etc/proxy-stack.env (предыдущая установка)"
else
    XHTTP_PATH="/$(openssl rand -hex 8)"
    install -m 600 /dev/null /etc/proxy-stack.env
    printf 'XHTTP_PATH="%s"\n' "$XHTTP_PATH" > /etc/proxy-stack.env
fi

# ─── 1. Зависимости ──────────────────────────────────────────────────────────
log "[1/7] Зависимости"
apt-get update -qq
apt-get install -y -qq nginx libnginx-mod-stream certbot fail2ban curl ufw cron openssh-server sqlite3

# ─── 2. Hardening ────────────────────────────────────────────────────────────
log "[2/7] Hardening"
bash "$ROOT/scripts/harden.sh"

# ─── 3. Firewall ─────────────────────────────────────────────────────────────
log "[3/7] Firewall"
bash "$ROOT/scripts/firewall.sh"

# ─── 4. nginx — начальный конфиг (HTTP + webroot) ────────────────────────────
log "[4/7] nginx — начальный конфиг"
mkdir -p "$WEBROOT" /var/www/html
cp -r "$ROOT/www/." /var/www/html/

cat > /etc/nginx/nginx.conf <<NGINX
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events { worker_connections 1024; }

http {
    include      /etc/nginx/mime.types;
    default_type application/octet-stream;
    sendfile     on;
    keepalive_timeout 65;

    server {
        listen 80;
        server_name ${DOMAIN};

        location /.well-known/acme-challenge/ {
            root ${WEBROOT};
        }

        location / {
            root  /var/www/html;
            index index.html;
        }
    }
}
NGINX

systemctl enable --now nginx
nginx -t && systemctl reload nginx

# ─── 5. SSL ──────────────────────────────────────────────────────────────────
log "[5/7] SSL-сертификат (webroot)"
certbot certonly \
    --webroot -w "$WEBROOT" \
    -d "$DOMAIN" \
    --non-interactive \
    --agree-tos \
    --email "$EMAIL"

cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'EOF'
#!/bin/bash
systemctl reload nginx
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

# ─── 6. 3x-ui — ставим первым, читаем его путь панели ───────────────────────
log "[6/7] 3x-ui"
bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh)

# Задаём порт напрямую в БД (x-ui setting -port ненадёжен)
sqlite3 /etc/x-ui/x-ui.db \
    "UPDATE settings SET value='${PANEL_PORT}' WHERE key='webPort';" 2>/dev/null || true
# Сбрасываем креды на admin/admin на случай если установщик задал другие
sqlite3 /etc/x-ui/x-ui.db \
    "UPDATE users SET username='admin', password='admin' WHERE id=1;" 2>/dev/null || true
systemctl restart x-ui

# Читаем путь панели из базы 3x-ui, убираем лишние слэши
PANEL_PATH=$(sqlite3 /etc/x-ui/x-ui.db \
    "SELECT value FROM settings WHERE key='webBasePath';" 2>/dev/null || true)
PANEL_PATH="/${PANEL_PATH#/}"   # убираем дубли слэша в начале
PANEL_PATH="${PANEL_PATH%/}"    # убираем слэш в конце

# Если не удалось прочитать — генерируем свой и устанавливаем
if [ -z "$PANEL_PATH" ]; then
    warn "Не удалось прочитать путь панели из БД, устанавливаем свой"
    PANEL_PATH="/$(openssl rand -hex 8)"
    x-ui setting -webBasePath "$PANEL_PATH" 2>/dev/null || true
    systemctl restart x-ui
fi

# Сохраняем финальные пути
printf 'XHTTP_PATH="%s"\nPANEL_PATH="%s"\n' "$XHTTP_PATH" "$PANEL_PATH" \
    > /etc/proxy-stack.env

# ─── nginx — финальный конфиг (теперь знаем PANEL_PATH) ─────────────────────
log "nginx — финальный конфиг (stream + http)"

cat > /etc/nginx/nginx.conf <<NGINX
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events { worker_connections 1024; }

stream {
    map \$ssl_preread_server_name \$backend {
        ${DOMAIN}   127.0.0.1:${NGINX_HTTP_PORT};
        default     127.0.0.1:${MTPROXY_PORT};
    }

    server {
        listen 443;
        ssl_preread on;
        proxy_pass  \$backend;
    }
}

http {
    include      /etc/nginx/mime.types;
    default_type application/octet-stream;
    sendfile     on;
    keepalive_timeout 65;
    access_log   /var/log/nginx/access.log;
    error_log    /var/log/nginx/error.log;

    server {
        listen 80;
        server_name ${DOMAIN};

        location /.well-known/acme-challenge/ {
            root ${WEBROOT};
        }

        location / {
            return 301 https://\$host\$request_uri;
        }
    }

    server {
        listen 127.0.0.1:${NGINX_HTTP_PORT} ssl http2;
        server_name ${DOMAIN};

        ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
        ssl_protocols       TLSv1.2 TLSv1.3;
        ssl_ciphers         HIGH:!aNULL:!MD5;

        location / {
            root  /var/www/html;
            index index.html;
            try_files \$uri \$uri/ =404;
        }

        location ${XHTTP_PATH} {
            proxy_pass                   http://127.0.0.1:${XHTTP_PORT};
            proxy_http_version           1.1;
            proxy_set_header Host        \$host;
            proxy_set_header X-Real-IP   \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_buffering              off;
            proxy_request_buffering      off;
            proxy_read_timeout           86400s;
            proxy_send_timeout           86400s;
        }

        location /sub/ {
            proxy_pass          https://127.0.0.1:${SUB_PORT};
            proxy_http_version  1.1;
            proxy_ssl_verify    off;
            proxy_set_header    Host \$host;
            proxy_set_header    X-Real-IP \$remote_addr;
        }

        location ${PANEL_PATH}/ {
            proxy_pass          https://127.0.0.1:${PANEL_PORT};
            proxy_http_version  1.1;
            proxy_ssl_verify    off;
            proxy_set_header    Host \$host;
            proxy_set_header    X-Real-IP \$remote_addr;
            proxy_set_header    Upgrade \$http_upgrade;
            proxy_set_header    Connection "upgrade";
        }
    }
}
NGINX

nginx -t && systemctl reload nginx

# ─── 7. fail2ban ─────────────────────────────────────────────────────────────
log "[7/7] fail2ban"
cp "$ROOT/fail2ban/jail.local" /etc/fail2ban/jail.local
systemctl enable --now fail2ban

# ─── Итог ────────────────────────────────────────────────────────────────────
CERT_PATH="/etc/letsencrypt/live/${DOMAIN}"

SUMMARY="
════════════════════════════════════════════════
  Установка завершена
════════════════════════════════════════════════

  Домен:        ${DOMAIN}

  3x-ui панель: https://${DOMAIN}${PANEL_PATH}/
  (логин/пароль по умолчанию: admin / admin)

  Xray inbound (создать в 3x-ui):
    Protocol:   VLESS
    Listen IP:  127.0.0.1
    Port:       ${XHTTP_PORT}
    Transport:  XHTTP
    Path:       ${XHTTP_PATH}
    TLS:        None

  Серты (Settings → Panel Settings):
    cert: ${CERT_PATH}/fullchain.pem
    key:  ${CERT_PATH}/privkey.pem

  MTProxy — запусти отдельно:
    sudo bash scripts/mtproxy.sh
    Порт при установке: ${MTPROXY_PORT}

════════════════════════════════════════════════"

echo "$SUMMARY"
echo "Дата: $(date)" > ~/INSTALL_INFO.txt
echo "$SUMMARY"      >> ~/INSTALL_INFO.txt
warn "Сохранено в ~/INSTALL_INFO.txt — удали после настройки!"
