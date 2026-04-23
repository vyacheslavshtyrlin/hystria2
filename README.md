# Гайд по запуску прокси-сервера

**Что получим в итоге:**
- 🌐 Hysteria2 — быстрый прокси с защитой от DPI
- 🖥 Blitz — веб-панель для управления Hysteria2
- 📱 MTProxy — прокси для Telegram
- 🔒 Nginx + Let's Encrypt — HTTPS и заглушка-сайт
- 🛡 Fail2ban, UFW — защита сервера

**Что нужно заранее:**
- VPS с Ubuntu 22.04 — порты 80, 443 (TCP+UDP), 8443, 2096 открыты
- Свой домен, например `vpn.твойдомен.com` — заглушка-сайт

---

## Шаг 1. Настройка DNS

В панели управления доменом добавить **A-запись**:

| Тип | Имя | Значение | TTL |
|-----|-----|----------|-----|
| A | `vpn` | `IP_твоего_сервера` | 300 |

> ⚠️ **Если домен на Cloudflare** — обязательно поставить режим **DNS only** (серое облако),
> не Proxied (оранжевое). Иначе certbot не выдаст сертификат, а Hysteria2 UDP не заработает —
> Cloudflare не проксирует UDP трафик.

**Проверить что DNS смотрит на твой сервер:**
```bash
# Должен вернуть IP твоего сервера, а не 104.x.x.x / 172.x.x.x
dig +short vpn.твойдомен.com @8.8.8.8
```

> ⏳ После смены DNS записей подождать до 5 минут (TTL=300) перед запуском деплоя.

---

## Шаг 2. Подключение к серверу

### Windows
```
Win + R → cmd → Enter
ssh root@IP_сервера
```

### Mac / Linux
```bash
ssh root@IP_сервера
```

> При первом подключении появится вопрос `Are you sure you want to continue?` — пишем `yes`.

---

## Шаг 3. Скачать проект с git

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

Заполнить файл (стрелки для перемещения, `Ctrl+O` сохранить, `Ctrl+X` выйти):

```env
DOMAIN=vpn.твойдомен.com  # основной домен (заглушка-сайт)
EMAIL=твой@email.com       # для уведомлений Let's Encrypt
TZ=Europe/Moscow           # часовой пояс
MTPROXY_PORT=8443          # порт MTProxy (можно оставить)
BLITZ_PORT=2096            # порт веб-панели Blitz
SSH_PORT=2222              # новый порт SSH (запомни!)
```

> ⚠️ Запомни `SSH_PORT` — после деплоя SSH будет работать на этом порту!

### SSH: не потерять доступ

Перед запуском деплоя добавь SSH-ключ и проверь вход по ключу в отдельной сессии.

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
nano ~/.ssh/authorized_keys   # вставь свой публичный ключ (ssh-ed25519 ...)
chmod 600 ~/.ssh/authorized_keys
```

Проверь в новом окне терминала:
```bash
ssh -p 22 root@IP_сервера
```

После деплоя SSH переедет на порт из `.env`:
```bash
ssh -p 2222 root@IP_сервера
```

---

## Шаг 5. Запуск деплоя

```bash
cd ~/hystria2
sudo bash scripts/deploy.sh
```

Скрипт сделает всё автоматически (~10-15 минут):

```
[+] Устанавливаем базовые пакеты...
[+] Устанавливаем Docker...
[+] Запускаем hardening...
[+] Настраиваем фаервол...
[+] Скачиваем образы...
[+] Выпускаем SSL сертификат...
[+] Устанавливаем Blitz...
[+] Регистрируем автостарт...
```

В конце появится итоговый блок с дальнейшими шагами.

> ⚠️ После деплоя SSH работает на новом порту: `ssh -p 2222 root@IP_сервера`

---

## Шаг 6. Настройка Hysteria2 через Blitz

### 6.1 Запустить меню Blitz

После деплоя в любой момент:

```bash
hys2
```

Откроется интерактивное меню управления.

---

### 6.2 Настроить Hysteria2

В главном меню выбрать **Hysteria2 Menu** и настроить:
- Порт: `443`
- Сертификат: `/etc/letsencrypt/live/vpn.твойдомен.com/fullchain.pem`
- Ключ: `/etc/letsencrypt/live/vpn.твойдомен.com/privkey.pem`
- Obfuscation: `salamander` + случайный пароль (`openssl rand -base64 24`)
- Masquerade: `proxy`, URL `https://microsoft.com/`

---

### 6.3 Включить веб-панель

1. `hys2` → **Advanced Menu** → **Web Panel** → **Start WebPanel**
2. Ввести домен для панели (можно поддомен, например `panel.твойдомен.com`)
3. Порт: **2096** (или что задано в `.env`)
4. Придумать логин и пароль

После запуска получишь URL вида:
```
https://panel.твойдомен.com:2096/abc123def456/
```

> ⚠️ Blitz использует **Caddy** для SSL панели — он сам получит сертификат для поддомена панели. DNS-запись для поддомена панели должна указывать на IP сервера.

---

### 6.4 Создание пользователя

В веб-панели или через `hys2` → Users → Add user.

После создания пользователя получишь ссылку подключения:
```
hysteria2://ПАРОЛЬ@vpn.твойдомен.com:443?obfs=salamander&obfs-password=...
```

---

## Шаг 7. Подключение клиентов

### Windows / Mac / Linux — Hiddify
1. Скачать [Hiddify](https://github.com/hiddify/hiddify-app/releases)
2. Добавить конфиг → вставить ссылку из Blitz
3. Нажать Connect ✅

### Android — Hiddify
- [Hiddify](https://play.google.com/store/apps/details?id=app.hiddify.com)
- Добавить профиль → вставить ссылку

### iOS — Streisand
- [Streisand](https://apps.apple.com/app/streisand/id6450534064) — бесплатный
- Добавить конфиг → вставить ссылку

> 💡 В Blitz можно нажать QR-код — отсканировать с телефона вместо копирования ссылки.

---

## Шаг 8. Установка MTProxy

MTProxy устанавливается как systemd сервис на хосте.

```bash
cd ~/hystria2
bash scripts/mtproxy.sh
```

Установщик задаст несколько вопросов:

| Вопрос | Ответ |
|--------|-------|
| Реализация | `2` — Official C (рекомендуется) |
| Порт | `8443` (или что задано в `.env`) |
| Секрет | Enter — сгенерирует автоматически |
| Tag | опционально, для статистики в @MTProxybot |

В конце установщик покажет ссылку вида:
```
tg://proxy?server=vpn.твойдомен.com&port=8443&secret=ee...
```

> ⚠️ Убедись что секрет начинается с `ee` — это fake-TLS режим, трафик
> маскируется под обычный TLS и не виден DPI.

**Добавить в Telegram:** открой ссылку в браузере — Telegram предложит добавить прокси автоматически.

---

## Управление сервером

### Базовые команды

```bash
cd ~/hystria2

# Статус Docker контейнеров
docker compose ps

# Логи в реальном времени
docker compose logs -f

# Логи конкретного сервиса
docker compose logs -f nginx

# Перезапустить всё
docker compose restart

# Управление Blitz/Hysteria2
hys2
```

### Если что-то сломалось

```bash
# Проверить что слушает на портах
ss -tulnp | grep -E '80|443|2096|8443'

# Проверить сертификаты
certbot certificates

# Принудительно обновить сертификат
certbot renew --force-renewal

# Перезапустить nginx
docker compose restart nginx

# Посмотреть кто заблокирован fail2ban
docker compose exec fail2ban fail2ban-client status
```

### После перезагрузки сервера

Всё поднимается **автоматически** — systemd сервис `proxy-stack` запускает Docker Compose при старте системы. Blitz (Hysteria2) также стартует автоматически.

---

## Частые проблемы

**❌ Сертификат не выдаётся**
- Проверь что DNS указывает на IP сервера: `dig +short vpn.твойдомен.com @8.8.8.8`
- DNS мог ещё не обновиться — подождать и попробовать снова:
  ```bash
  cd ~/hystria2 && bash certbot/init.sh
  ```

**❌ Hysteria2 не подключается**
- Убедись что в клиенте указан тот же `obfs-password` что задан в Blitz
- Запусти `hys2` и проверь статус Hysteria2
- Проверь UFW: `ufw status` — должна быть строка `443/udp ALLOW`

**❌ Веб-панель Blitz не открывается**
- DNS для поддомена панели должен указывать на IP сервера
- Caddy должен быть запущен: `hys2` → Advanced → Web Panel → Services Status
- Порт должен быть открыт: `ufw status | grep 2096`

**❌ Забыл SSH порт / заблокировал себя**
- В панели хостинга есть **VNC/Console** — доступ к серверу без SSH
- Войти через консоль и исправить: `nano /etc/ssh/sshd_config`

**❌ После деплоя SSH не работает**
- Порт сменился на тот что указан в `.env` (`SSH_PORT=2222`)
- Подключаться: `ssh -p 2222 root@IP_сервера`
