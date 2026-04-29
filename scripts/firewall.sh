#!/bin/bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/.env"

SSH_PORT="${SSH_PORT:-2222}"

log "Сбрасываем UFW..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw default deny forward

log "SSH (rate-limited) на порту ${SSH_PORT}..."
ufw limit "${SSH_PORT}/tcp" comment 'SSH rate-limited'

log "Публичные порты..."
ufw allow 80/tcp  comment 'HTTP (certbot + редирект)'
ufw allow 443/tcp comment 'HTTPS + MTProxy (nginx stream)'
ufw allow 8443/tcp comment 'VLESS REALITY'
ufw allow 8443/udp comment 'Hysteria2 QUIC'

log "Включаем UFW..."
ufw --force enable
ufw status verbose

echo ""
log "Фаервол настроен."
echo "  ${SSH_PORT}/tcp  — SSH (rate-limited)"
echo "  80/tcp    — HTTP"
echo "  443/tcp   — HTTPS + MTProxy (через nginx stream)"
echo "  8443/tcp  — VLESS REALITY"
echo "  8443/udp  — Hysteria2 QUIC"
warn "Все остальные порты закрыты. MTProxy и 3x-ui доступны только через nginx :443"
