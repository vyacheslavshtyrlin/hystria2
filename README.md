# Гайд по запуску прокси-сервера

**Что получим в итоге:**
- 🌐 Hysteria2 — быстрый прокси с защитой от DPI
- 🖥 Blitz — веб-панель управления (Caddy + автоматический SSL)
- 📱 MTProxy — прокси для Telegram
- 🔒 Caddy — HTTPS, stub-сайт, Let's Encrypt автоматически
- 🛡 Fail2ban, UFW — защита сервера

**Архитектура:**
```
Caddy  → 80/443 TCP → https://vpn.домен.com        (stub-сайт)
Caddy  → 2096        → https://api.домен.com:2096/  (панель Blitz)
Hysteria2 → 443 UDP  → клиенты
MTProxy   → 8443 TCP → Telegram
```

**Что нужно заранее:**
- VPS с Ubuntu 22.04 — порты 80, 443 (TCP+UDP), 2096, 8443 открыты
- Свой домен с двумя A-записями

---

## Шаг 1. Настройка DNS

| Тип | Имя | Значение | TTL |
|-----|-----|----------|-----|
| A | `vpn` | `IP_сервера` | 300 |
| A | `api` | `IP_сервера` | 300 |

> ⚠️ **Если домен на Cloudflare** — режим **DNS only** (серое облако). Proxied ломает certbot и UDP.

**Проверить:**
```bash
dig +short vpn.твойдомен.com @8.8.8.8
dig +short api.твойдомен.com @8.8.8.8
# Обе должны вернуть IP сервера
```

---

## Шаг 2. Подключение к серверу

```bash
ssh root@IP_сервера
```

---

## Шаг 3. Скачать проект

```bash
apt-get install -y git
git clone https://github.com/vyacheslavshtyrlin/hystria2
```

---

## Шаг 4. Настройка конфига

```bash
cd ~/hystria2
cp .env.example .env
nano .env
```

```env
DOMAIN=vpn.твойдомен.com   # основной домен (stub-сайт)
EMAIL=твой@email.com        # для уведомлений Let's Encrypt
TZ=Europe/Moscow
MTPROXY_PORT=8443
BLITZ_PORT=2096             # порт веб-панели Blitz
SSH_PORT=2222               # запомни!
```

### SSH: не потерять доступ

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
nano ~/.ssh/authorized_keys   # вставь свой публичный ключ
chmod 600 ~/.ssh/authorized_keys
```

Проверь вход по ключу в новом окне перед деплоем.

---

## Шаг 5. Запуск деплоя

```bash
cd ~/hystria2
sudo bash scripts/deploy.sh
```

Деплой делает (~10-15 мин):
- Docker + fail2ban + watchtower
- Hardening SSH, sysctl, swap
- UFW фаервол
- Устанавливает Blitz
- Настраивает Caddy для stub-сайта

> ⚠️ После деплоя SSH работает на новом порту: `ssh -p 2222 root@IP_сервера`

---

## Шаг 6. Настройка Hysteria2 через Blitz

```bash
hys2
```

### 6.1 Настроить Hysteria2

Hysteria2 Menu → Configure:
- Порт: `443`
- SNI: `microsoft.com`
- Сертификат домена: `vpn.твойдомен.com`
- Obfuscation: `salamander` + случайный пароль (`openssl rand -base64 24`)

### 6.2 Включить веб-панель

```bash
hys2
# Advanced Menu → Web Panel → Start WebPanel
# Домен: api.твойдомен.com
# Порт: 2096
# Придумать логин и пароль
```

После запуска Blitz покажет URL вида:
```
https://api.твойдомен.com:2096/RANDOM_HASH/
```

### 6.3 Добавить stub-сайт в Caddyfile

После запуска панели Blitz перезаписывает `/etc/caddy/Caddyfile`. Восстанови stub-сайт:

```bash
bash ~/hystria2/scripts/caddy-restore.sh
```

Или вручную — добавь в начало `/etc/caddy/Caddyfile` перед блоком панели:

```
vpn.твойдомен.com {
    root * /root/hystria2/www
    file_server
    encode gzip
    header { -Server }
}
```

Затем:
```bash
systemctl restart caddy
```

### 6.4 Создать пользователей

Через веб-панель или `hys2` → Users → Add.

Получишь ссылку подключения:
```
hysteria2://ПАРОЛЬ@vpn.твойдомен.com:443?obfs=salamander&obfs-password=...
```

---

## Шаг 7. Подключение клиентов

### Windows / Mac / Linux — Hiddify
1. Скачать [Hiddify](https://github.com/hiddify/hiddify-app/releases)
2. Добавить конфиг → вставить ссылку
3. Connect ✅

### Android — Hiddify
- [Google Play](https://play.google.com/store/apps/details?id=app.hiddify.com)

### iOS — Streisand
- [App Store](https://apps.apple.com/app/streisand/id6450534064)

---

## Шаг 8. MTProxy (Telegram)

```bash
cd ~/hystria2
bash scripts/mtproxy.sh
```

| Вопрос | Ответ |
|--------|-------|
| Реализация | `2` — Official C |
| Порт | `8443` |
| Секрет | Enter (автогенерация) |

Получишь ссылку `tg://proxy?...&secret=ee...` — секрет должен начинаться с `ee` (fake-TLS).

---

## Управление

```bash
# Статус Docker сервисов
docker compose ps

# Управление Hysteria2 / Blitz
hys2

# Статус Caddy
systemctl status caddy
journalctl -u caddy -f

# Перезапустить Caddy
systemctl restart caddy

# Блокировки fail2ban
docker compose exec fail2ban fail2ban-client status
```

### После перезагрузки

Docker сервисы (fail2ban, watchtower) — systemd `proxy-stack` поднимает автоматически.
Blitz (Hysteria2 + Caddy) — стартует автоматически через свои systemd сервисы.

---

## Частые проблемы

**❌ Сертификат Caddy не выдаётся**
- Проверь DNS: `dig +short vpn.твойдомен.com @8.8.8.8`
- Порт 80 должен быть открыт и не занят: `ss -tlnp | grep :80`

**❌ Stub-сайт не работает после настройки панели**
- Blitz перезаписал Caddyfile — восстанови: `bash ~/hystria2/scripts/caddy-restore.sh`

**❌ Hysteria2 не подключается**
- Проверь obfs-password в клиенте
- `hys2` → статус Hysteria2
- `ufw status` — должна быть строка `443/udp ALLOW`

**❌ Забыл SSH порт**
- Используй VNC/Console в панели хостинга
- `nano /etc/ssh/sshd_config`

**❌ После деплоя SSH не работает**
- Порт сменился: `ssh -p 2222 root@IP_сервера`
