# Прокси-сервер: VLESS+XHTTP + MTProxy

**Что получим в итоге:**
- VLESS+XHTTP — прокси с защитой от DPI (Xray через 3x-ui)
- MTProxy — прокси для Telegram с fake-TLS
- nginx — reverse proxy, stub-сайт, Let's Encrypt
- Fail2ban, UFW — защита сервера

**Архитектура:**
```
:80   → nginx → certbot webroot + редирект на HTTPS
:443  → nginx stream (SNI routing)
         ├── SNI = домен     → nginx http → /xhttp-path (Xray)
         │                              → /panel-path/ (3x-ui)
         └── SNI = bing.com  → MTProxy (fake-TLS)
```

Один порт, три сервиса. Снаружи выглядит как обычный HTTPS-сайт.

**Что нужно заранее:**
- VPS с Ubuntu 24.04, порты 80 и 443 открыты у провайдера
- Домен с A-записью на IP сервера

---

## Шаг 1. Настройка DNS

| Тип | Имя | Значение | TTL |
|-----|-----|----------|-----|
| A | `@` или `sub` | `IP_сервера` | 300 |

> Если домен на Cloudflare — режим **DNS only** (серое облако). Proxied ломает certbot.

**Проверить:**
```bash
dig +short твойдомен.com @8.8.8.8
# Должен вернуть IP сервера
```

---

## Шаг 2. Подключение к серверу

```bash
ssh root@IP_сервера
```

---

## Шаг 3. Клонировать репозиторий

```bash
apt-get install -y git
git clone https://github.com/vyacheslavshtyrlin/hystria2
cd ~/hystria2
```

---

## Шаг 4. Настроить .env

```bash
cp .env.example .env
nano .env
```

```env
DOMAIN=твойдомен.com
EMAIL=твой@email.com
SSH_PORT=2222
TZ=Europe/Moscow
```

### SSH: не потерять доступ

Перед деплоем добавь свой публичный ключ:

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
nano ~/.ssh/authorized_keys   # вставь свой публичный ключ
chmod 600 ~/.ssh/authorized_keys
```

Проверь вход по ключу в новом окне — только потом запускай деплой.

---

## Шаг 5. Деплой

```bash
sudo bash scripts/deploy.sh
```

Что делает (~10 мин):
1. Устанавливает nginx, certbot, fail2ban
2. Hardening SSH, sysctl, swap
3. Настраивает UFW (открыты только 80 и 443)
4. Получает SSL-сертификат через certbot webroot
5. nginx: stream на 443 + http за ним
6. Устанавливает 3x-ui
7. Настраивает fail2ban

> После деплоя SSH работает на новом порту: `ssh -p 2222 root@IP_сервера`

В конце скрипт выведет:
- URL панели 3x-ui
- Параметры для создания inbound

---

## Шаг 6. Создать inbound в 3x-ui

Зайди в панель по URL из вывода деплоя (логин/пароль: `admin` / `admin` — смени сразу).

Добавить inbound:

| Параметр | Значение |
|---|---|
| Protocol | VLESS |
| Listen IP | `127.0.0.1` |
| Port | `2096` |
| Transport | XHTTP |
| Path | (из вывода деплоя) |
| TLS | None |

3x-ui сгенерирует ссылку вида:
```
vless://UUID@твойдомен.com:443?security=tls&type=xhttp&path=%2Fабцдеф12#name
```

### Сертификаты для панели

Settings → Panel Settings:
- SSL Certificate: `/etc/letsencrypt/live/твойдомен.com/fullchain.pem`
- SSL Key: `/etc/letsencrypt/live/твойдомен.com/privkey.pem`

---

## Шаг 7. Подключение клиентов

Импортируй ссылку из 3x-ui в любой клиент:

| Платформа | Клиент |
|---|---|
| Windows / Mac / Linux | [Hiddify](https://github.com/hiddify/hiddify-app/releases) |
| Android | [Hiddify](https://play.google.com/store/apps/details?id=app.hiddify.com) |
| iOS | [Streisand](https://apps.apple.com/app/streisand/id6450534064) |

---

## Шаг 8. MTProxy (Telegram)

```bash
sudo bash scripts/mtproxy.sh
```

| Вопрос установщика | Ответ |
|---|---|
| Реализация | `2` — Official C |
| Порт | `2083` |
| Секрет | Enter (автогенерация) или введи `ee` + 32 hex-символа |
| Tag | опционально |

Скрипт выведет готовую ссылку с портом 443:
```
tg://proxy?server=твойдомен.com&port=443&secret=ee...
```

Секрет должен начинаться с `ee` — это fake-TLS (маскировка под bing.com).

---

## Управление

```bash
# 3x-ui
systemctl status x-ui
x-ui                        # интерактивное меню

# nginx
systemctl reload nginx
nginx -t                    # проверить конфиг
journalctl -u nginx -f

# MTProxy
systemctl status MTProxy
journalctl -u MTProxy -f

# fail2ban
fail2ban-client status
fail2ban-client status sshd

# Обновить сертификат вручную
certbot renew --dry-run
```

---

## Частые проблемы

**Сертификат не выдаётся**
- DNS ещё не обновился: `dig +short твойдомен.com @8.8.8.8`
- Порт 80 занят: `ss -tlnp | grep :80`

**Прокси не подключается**
- Проверь что inbound создан в 3x-ui на `127.0.0.1:2096`
- nginx конфиг: `nginx -t && systemctl status nginx`
- Логи Xray: `x-ui` → Xray logs

**MTProxy не работает**
- `systemctl status MTProxy`
- Убедись что порт в ссылке 443, не 2083

**Забыл SSH порт**
- VNC/Console в панели хостинга
- `grep ^Port /etc/ssh/sshd_config`

**Панель 3x-ui недоступна**
- `systemctl status x-ui`
- Путь сохранён в `/etc/proxy-stack.env`
