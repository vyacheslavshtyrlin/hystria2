#!/bin/bash
# Full deploy for a clean Ubuntu 22.04 host.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }

[ "$(id -u)" != "0" ] && die "Run as root: sudo bash scripts/deploy.sh"
export DEBIAN_FRONTEND=noninteractive

[ ! -f "$ROOT/.env" ] && die ".env not found. Create it first: cp .env.example .env"
source "$ROOT/.env"

[ "${DOMAIN:-}" = "example.com" ] && die "Set DOMAIN in .env"
: "${DOMAIN:?Set DOMAIN in .env}"
: "${HUI_SUBDOMAIN:?Set HUI_SUBDOMAIN in .env}"
: "${EMAIL:?Set EMAIL in .env}"

log "Installing Ubuntu base packages..."
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg lsb-release ufw cron openssh-server

if ! command -v docker >/dev/null 2>&1; then
  log "Installing Docker..."
  curl -fsSL https://get.docker.com | sh
fi

systemctl enable --now docker

if ! docker compose version >/dev/null 2>&1; then
  log "Installing Docker Compose plugin..."
  apt-get install -y -qq docker-compose-plugin || die "Docker Compose plugin is not installed. Check Docker apt repository."
fi

TARGET_USER="${SUDO_USER:-${USER:-root}}"
if [ "$TARGET_USER" != "root" ]; then
  usermod -aG docker "$TARGET_USER" && warn "User $TARGET_USER added to docker group. Re-login is required for non-sudo docker."
fi

chmod +x "$ROOT/scripts/"*.sh "$ROOT/certbot/init.sh"

log "Running hardening..."
bash "$ROOT/scripts/harden.sh"

log "Configuring firewall..."
bash "$ROOT/scripts/firewall.sh"

log "Pulling Docker images..."
docker compose -f "$ROOT/docker-compose.yml" pull nginx certbot h-ui fail2ban watchtower

log "Starting services without nginx before SSL issue..."
docker compose -f "$ROOT/docker-compose.yml" up -d h-ui fail2ban watchtower

log "Issuing SSL certificates..."
bash "$ROOT/certbot/init.sh"

log "Starting full compose stack..."
docker compose -f "$ROOT/docker-compose.yml" up -d --remove-orphans

log "Registering systemd autostart..."
bash "$ROOT/scripts/autostart.sh"

log "Waiting for h-ui..."
for _ in $(seq 1 30); do
  if curl -sf "http://127.0.0.1:8081" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

cat > "$ROOT/INSTALL_INFO.txt" <<EOF
Deploy date: $(date)

h-ui panel: https://${HUI_SUBDOMAIN}
Login: admin
Password: sysadmin - CHANGE IT IMMEDIATELY

Hysteria2: configure via h-ui panel (UDP 443)
MTProxy: run bash scripts/mtproxy.sh
EOF

echo ""
echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN} Deploy completed successfully${NC}"
echo -e " h-ui panel: https://${HUI_SUBDOMAIN}"
echo -e " Login: admin"
echo -e " Password: ${RED}sysadmin${NC} - CHANGE IT IMMEDIATELY"
echo -e "${GREEN}======================================${NC}"
echo ""
warn "INSTALL_INFO.txt created. Delete it after first login."
