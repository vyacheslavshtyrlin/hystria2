#!/bin/bash
# Базовый hardening сервера: SSH, sysctl, swap, unattended-upgrades
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

[ "$(id -u)" != "0" ] && die "Запускай от root (sudo)"

# SSH_PORT можно передать через .env или переменную окружения
source "$ROOT/.env" 2>/dev/null || true
SSH_PORT="${SSH_PORT:-22}"

# ── 1. SSH HARDENING ──────────────────────────────────────────
log "Хардening SSH (порт: $SSH_PORT)..."

SSHD=/etc/ssh/sshd_config
SSHD_BACKUP="${SSHD}.bak.$(date +%s)"
cp "$SSHD" "$SSHD_BACKUP"

set_sshd() {
  local key="$1" val="$2"
  # Точное совпадение ключа (слово целиком) — не трогаем PortForwarding при установке Port
  if grep -qE "^#?[[:space:]]*${key}[[:space:]]" "$SSHD"; then
    sed -i -E "s|^#?[[:space:]]*${key}[[:space:]].*|${key} ${val}|" "$SSHD"
  else
    echo "${key} ${val}" >> "$SSHD"
  fi
}

# Проверяем наличие SSH ключа именно у root перед отключением пароля.
ROOT_AUTHORIZED_KEYS="/root/.ssh/authorized_keys"
ROOT_KEYS_COUNT=0
if [ -f "$ROOT_AUTHORIZED_KEYS" ]; then
  ROOT_KEYS_COUNT=$(grep -Ec '^(ssh-|ecdsa-|sk-)' "$ROOT_AUTHORIZED_KEYS" 2>/dev/null || true)
fi

if [ "$ROOT_KEYS_COUNT" -eq 0 ]; then
  warn "У root не найден SSH ключ. Оставляем парольный вход включённым, чтобы не потерять доступ."
  warn "Добавь ключ: ssh-copy-id root@СЕРВЕР, проверь вход по ключу в новой сессии и только потом запускай harden.sh повторно."
  set_sshd Port                   "$SSH_PORT"
  set_sshd PermitRootLogin        yes
  set_sshd PasswordAuthentication yes
  set_sshd PubkeyAuthentication   yes
  set_sshd MaxAuthTries           3
  set_sshd LoginGraceTime         30
else
  set_sshd Port                   "$SSH_PORT"
  set_sshd PermitRootLogin        prohibit-password
  set_sshd PasswordAuthentication no
  set_sshd PubkeyAuthentication   yes
  set_sshd AuthenticationMethods  publickey
  set_sshd X11Forwarding          no
  set_sshd AllowTcpForwarding     no
  set_sshd MaxAuthTries           3
  set_sshd LoginGraceTime         30
  set_sshd ClientAliveInterval    300
  set_sshd ClientAliveCountMax    2
  warn "SSH: парольный вход отключён, root разрешён только по ключу."
fi

# Проверяем конфиг — если битый, восстанавливаем бэкап и падаем
if ! sshd -t 2>/tmp/sshd_test_err; then
  cat /tmp/sshd_test_err
  warn "Конфиг SSH повреждён — восстанавливаем бэкап..."
  cp "$SSHD_BACKUP" "$SSHD" 2>/dev/null || true
  die "SSH конфиг не прошёл проверку. Бэкап восстановлен."
fi

systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true

# ── 2. SYSCTL — сеть и безопасность ───────────────────────────
log "Настраиваем sysctl..."

cat > /etc/sysctl.d/99-server.conf <<'EOF'
# ── Сеть ──────────────────────────────────────────────────────

# BBR — современный алгоритм управления перегрузкой
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Буферы сокетов
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576

# TCP буферы
net.ipv4.tcp_rmem = 4096 1048576 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# Очередь соединений (против SYN-flood)
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_syncookies = 1

# TIME_WAIT оптимизация
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1

# ── Безопасность ──────────────────────────────────────────────

# Запрет IP spoofing
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Запрет ICMP редиректов
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0

# Запрет source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0

# Скрываем kernel pointer'ы из /proc
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1

# ICMP: не отвечаем на ping — сервер не виден на network scan
# (только ограничиваем, полный запрет ломает PMTUD)
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
EOF

sysctl --system >/dev/null
log "sysctl применён (BBR + буферы + защита)"

# ── 3. SWAP ────────────────────────────────────────────────────
log "Настраиваем swap..."

if ! swapon --show | grep -q /swapfile; then
  # Определяем размер: если RAM < 2GB → 2GB swap, иначе 1GB
  RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
  SWAP_SIZE="1G"
  [ "$RAM_MB" -lt 2048 ] && SWAP_SIZE="2G"

  fallocate -l "$SWAP_SIZE" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  log "Swap ${SWAP_SIZE} создан"
else
  log "Swap уже настроен, пропускаем"
fi

# Меньше агрессивный swappiness (не свопировать без нужды)
echo 'vm.swappiness = 10' > /etc/sysctl.d/99-swap.conf
sysctl vm.swappiness=10

# ── 4. UNATTENDED UPGRADES ─────────────────────────────────────
log "Настраиваем автоматические security-обновления..."

apt-get install -y -qq unattended-upgrades apt-listchanges

cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOF

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF

systemctl enable --now unattended-upgrades
log "Security-патчи будут применяться автоматически"

# ── 5. LIMITS ──────────────────────────────────────────────────
log "Настраиваем системные лимиты..."

cat > /etc/security/limits.d/99-server.conf <<'EOF'
* soft nofile 65535
* hard nofile 65535
* soft nproc  65535
* hard nproc  65535
EOF

grep -q 'DefaultLimitNOFILE' /etc/systemd/system.conf || \
  echo 'DefaultLimitNOFILE=65535' >> /etc/systemd/system.conf
systemctl daemon-reexec

echo ""
log "Hardening завершён."
warn "Обязательно проверь SSH доступ по ключу в новой сессии перед закрытием текущей!"
