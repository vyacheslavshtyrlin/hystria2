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
WS_PORT=2097
XHTTP_CDN_PORT=2100
PANEL_PORT=2053
SUB_PORT=2095
MTPROXY_PORT=2083
NGINX_HTTP_PORT=4433
WS_HTTP_PORT=4434
CDN="${CDN:-}"   # опционально в .env; если пусто — CDN-блоки пропускаются

# Пути inbound генерируем сами
if [ -f /etc/proxy-stack.env ]; then
    source /etc/proxy-stack.env
    warn "Конфиг загружен из /etc/proxy-stack.env (предыдущая установка)"
fi
[ -z "${XHTTP_PATH:-}" ] && XHTTP_PATH="/$(openssl rand -hex 8)"
if [ -n "$CDN" ]; then
    [ -z "${WS_PATH:-}" ]        && WS_PATH="/$(openssl rand -hex 8)"
    [ -z "${XHTTP_CDN_PATH:-}" ] && XHTTP_CDN_PATH="/$(openssl rand -hex 8)"
else
    WS_PATH=""
    XHTTP_CDN_PATH=""
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

# ─── 4. SSL — standalone ─────────────────────────────────────────────────────
log "[4/7] SSL-сертификат (standalone)"
# apt install nginx запускает nginx автоматически — останавливаем перед certbot
systemctl stop nginx 2>/dev/null || true

if [ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]; then
    warn "Сертификат уже существует, пропускаем выпуск"
else
    certbot certonly \
        --standalone \
        -d "$DOMAIN" \
        --non-interactive \
        --agree-tos \
        --email "$EMAIL"
fi

# При обновлении: остановить nginx → обновить → запустить
cat > /etc/letsencrypt/renewal-hooks/pre/stop-nginx.sh <<'EOF'
#!/bin/bash
systemctl stop nginx
EOF
cat > /etc/letsencrypt/renewal-hooks/post/start-nginx.sh <<'EOF'
#!/bin/bash
systemctl start nginx
EOF
chmod +x /etc/letsencrypt/renewal-hooks/pre/stop-nginx.sh \
         /etc/letsencrypt/renewal-hooks/post/start-nginx.sh

# ─── 5. 3x-ui — до nginx, порт 80 свободен для его acme.sh ──────────────────
log "[5/7] 3x-ui"
bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh) || true
command -v x-ui >/dev/null 2>&1 || die "3x-ui не установился — проверь вывод установщика выше"

# Задаём порт напрямую в БД (x-ui setting -port ненадёжен)
sqlite3 /etc/x-ui/x-ui.db \
    "UPDATE settings SET value='${PANEL_PORT}' WHERE key='webPort';" 2>/dev/null || true
# Указываем 3x-ui использовать сертификаты certbot (иначе он сгенерирует self-signed)
sqlite3 /etc/x-ui/x-ui.db \
    "UPDATE settings SET value='/etc/letsencrypt/live/${DOMAIN}/fullchain.pem' WHERE key='webCertFile';" 2>/dev/null || true
sqlite3 /etc/x-ui/x-ui.db \
    "UPDATE settings SET value='/etc/letsencrypt/live/${DOMAIN}/privkey.pem' WHERE key='webKeyFile';" 2>/dev/null || true
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
install -m 600 /dev/null /etc/proxy-stack.env
printf 'XHTTP_PATH="%s"\nWS_PATH="%s"\nXHTTP_CDN_PATH="%s"\nPANEL_PATH="%s"\n' \
    "$XHTTP_PATH" "$WS_PATH" "$XHTTP_CDN_PATH" "$PANEL_PATH" > /etc/proxy-stack.env

# ─── 6. nginx — единый финальный конфиг ──────────────────────────────────────
log "[6/7] nginx"
mkdir -p /var/www/html
cp -r "$ROOT/www/." /var/www/html/

if [ -n "$CDN" ]; then
cat > /etc/nginx/nginx.conf <<NGINX
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

worker_rlimit_nofile 65535;

events { worker_connections 4096; }

stream {
    map \$ssl_preread_server_name \$backend {
        ${DOMAIN}   127.0.0.1:${NGINX_HTTP_PORT};
        ${CDN}      127.0.0.1:${WS_HTTP_PORT};
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
        server_name ${DOMAIN} ${CDN};

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
            try_files \$uri \$uri/ /index.html;
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
            client_max_body_size         0;
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

    server {
        listen 127.0.0.1:${WS_HTTP_PORT} ssl;
        server_name ${CDN};

        ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
        ssl_protocols       TLSv1.2 TLSv1.3;
        ssl_ciphers         HIGH:!aNULL:!MD5;

        location / {
            root  /var/www/html;
            index index.html;
            try_files \$uri \$uri/ /index.html;
        }

        location ${WS_PATH} {
            proxy_pass              http://127.0.0.1:${WS_PORT};
            proxy_http_version      1.1;
            proxy_set_header        Upgrade    \$http_upgrade;
            proxy_set_header        Connection "upgrade";
            proxy_set_header        Host       \$host;
            proxy_set_header        X-Real-IP  \$http_cf_connecting_ip;
            proxy_buffering         off;
            proxy_request_buffering off;
            proxy_read_timeout      86400s;
            proxy_send_timeout      86400s;
        }

        location ${XHTTP_CDN_PATH} {
            proxy_pass                   http://127.0.0.1:${XHTTP_CDN_PORT};
            proxy_http_version           1.1;
            proxy_set_header Host        \$host;
            proxy_set_header X-Real-IP   \$http_cf_connecting_ip;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_buffering              off;
            proxy_request_buffering      off;
            proxy_read_timeout           86400s;
            proxy_send_timeout           86400s;
            client_max_body_size         0;
        }
    }
}
NGINX
else
cat > /etc/nginx/nginx.conf <<NGINX
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

worker_rlimit_nofile 65535;

events { worker_connections 4096; }

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
            try_files \$uri \$uri/ /index.html;
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
            client_max_body_size         0;
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
fi

nginx -t && systemctl enable --now nginx

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

  Inbound 1 — VLESS+XHTTP (создать в 3x-ui):
    Protocol:       VLESS
    Listen IP:      пусто
    Port:           ${XHTTP_PORT}
    Transport:      XHTTP
    Path:           ${XHTTP_PATH}
    TLS:            None
    External Proxy: ${DOMAIN}:443 TLS

$([ -n "$CDN" ] && cat <<CDN_SUMMARY

  Inbound 2 — VLESS+WebSocket CDN (создать в 3x-ui):
    Protocol:       VLESS
    Listen IP:      пусто
    Port:           ${WS_PORT}
    Transport:      WebSocket
    Path:           ${WS_PATH}
    TLS:            None
    External Proxy: ${CDN}:443 TLS
    (Cloudflare: ${CDN} → orange cloud, SSL Full)

  Inbound 3 — VLESS+XHTTP CDN (создать в 3x-ui):
    Protocol:       VLESS
    Listen IP:      пусто
    Port:           ${XHTTP_CDN_PORT}
    Transport:      XHTTP
    Path:           ${XHTTP_CDN_PATH}
    TLS:            None
    External Proxy: ${CDN}:443 TLS
    (Cloudflare: ${CDN} → orange cloud, SSL Full)
CDN_SUMMARY
)
  Inbound $([ -n "$CDN" ] && echo 4 || echo 2) — Hysteria2 (создать в 3x-ui):
    Protocol:       Hysteria2
    Port:           443
    Listen IP:      пусто
    TLS cert:       ${CERT_PATH}/fullchain.pem
    TLS key:        ${CERT_PATH}/privkey.pem
    SNI:            ${DOMAIN}
    Obfs type:      salamander
    Obfs password:  (Generate в панели)
    (UDP:443 открыт в UFW — nginx не конфликтует, он TCP)

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
