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
5. Устанавливает 3x-ui (см. ниже — вопросы установщика)
6. nginx: stream на 443 + http за ним
7. Настраивает fail2ban

> После деплоя SSH работает на новом порту: `ssh -p 2222 root@IP_сервера`

### Вопросы установщика 3x-ui

**Порт панели** — жми Enter (оставь дефолт, скрипт перезапишет на 2053 через SQLite напрямую)

**SSL** — выбирай **Let's Encrypt** (опция Custom не имеет варианта None — нужен именно Let's Encrypt)

> После установки скрипт автоматически:
> - Устанавливает порт панели `2053` через SQLite (команда `x-ui setting -port` ненадёжна)
> - Сбрасывает логин/пароль на `admin` / `admin`

Логин/пароль после деплоя: `admin` / `admin` — **смени сразу**.

В конце скрипт выведет URL панели и параметры для создания inbound.

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
| Path | значение XHTTP_PATH из `/etc/proxy-stack.env` |
| TLS | **None** |

> **Важно про Path:** вставляй именно значение пути, не имя файла.
> Правильно: `/dc85f473edcb8f85` — узнать: `cat /etc/proxy-stack.env`

> **Важно про TLS:** в inbound ставь **None** — nginx уже снимает TLS. Если поставить TLS здесь, Xray попытается слушать 443 и упадёт с ошибкой `address already in use`.

### External Proxy — обязательно!

Без этой настройки 3x-ui генерирует ссылку с внутренним адресом `127.0.0.1:2096` вместо публичного домена.

В настройках inbound прокрути вниз → **External Proxy** → включи → добавь запись:

| Поле | Значение |
|---|---|
| Адрес | `твойдомен.com` |
| Порт | `443` |
| Безопасность | **TLS** |

> TLS здесь — не противоречие. Inbound TLS=None означает что Xray принимает трафик от nginx без TLS (nginx уже снял). External Proxy TLS=TLS означает что клиент подключается к nginx по HTTPS. Это разные вещи.

После сохранения 3x-ui сгенерирует правильную ссылку:
```
vless://UUID@твойдомен.com:443?security=tls&type=xhttp&path=%2Fabcdef12#name
```

### Подписка

Порт подписки (2095) закрыт снаружи — доступ только через nginx по пути `/sub/`.

В 3x-ui Settings → Subscription → порт поставь `2095`, путь `/sub`.

Ссылка подписки: `https://твойдомен.com/sub/UUID` (без порта в URL).

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
