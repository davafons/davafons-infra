#!/bin/bash

# Production Docker Host Setup Script (idempotent — safe to re-run)
# For Ubuntu Server 24.04 LTS (Noble)
# Based on: https://gist.github.com/rameerez/238927b78f9108a71a77aed34208de11
# Customized with Tailscale + Tailscale-only SSH

set -euo pipefail
IFS=$'\n\t'

# --- Constants ---
REQUIRED_OS="Ubuntu"
REQUIRED_VERSION="24.04"
MIN_RAM_MB=1024
MIN_DISK_GB=20

SETUP_BASE_URL="https://setup.davafons.cc/hetzner"

# When run from the repo, use local files. When run via curl, download them.
if [[ -f "$(dirname "$0")/scripts/server-notify" ]]; then
  BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
else
  BASE_DIR=$(mktemp -d)
  CLEANUP_BASE_DIR=true

  mkdir -p "$BASE_DIR/scripts" "$BASE_DIR/config"

  for f in server-notify server-status docker-cleanup login-notify update-cloudflare-ips security-audit aide-check; do
    curl -fsSL "$SETUP_BASE_URL/scripts/$f" -o "$BASE_DIR/scripts/$f" || { echo "Failed to download scripts/$f"; exit 1; }
  done
  for f in daemon.json jail.local audit.rules sysctl-security.conf docker-limits.conf docker-logrotate.conf unattended-upgrades.conf kernel-modules-blacklist.conf sudoers-hardening coredump.conf pwquality.conf issue; do
    curl -fsSL "$SETUP_BASE_URL/config/$f" -o "$BASE_DIR/config/$f" || { echo "Failed to download config/$f"; exit 1; }
  done
fi

SCRIPT_DIR="$BASE_DIR/scripts"
CONFIG_DIR="$BASE_DIR/config"

# --- Logging ---
# Usage: log "message" [color]
# Colors: red, green, yellow (default)
SETUP_COMPLETED=false
HEARTBEAT_FILE=$(mktemp)
echo "starting" > "$HEARTBEAT_FILE"
HEARTBEAT_PID=""

log() {
  local msg="$1"
  local color="${2:-yellow}"
  case "$color" in
    red)    echo -e "\033[0;31m=> $msg\033[0m" >&2 ;;
    green)  echo -e "\033[0;32m=> $msg\033[0m" ;;
    yellow) echo -e "\033[1;33m=> $msg\033[0m" ;;
  esac

  echo "$msg" > "$HEARTBEAT_FILE"
  server-notify "$msg" "$color" "Server Setup" >/dev/null 2>&1 || true
}

die() { log "$1" red; exit 1; }

handle_exit() {
  [[ -n "$HEARTBEAT_PID" ]] && kill "$HEARTBEAT_PID" 2>/dev/null || true
  if [ "$SETUP_COMPLETED" = false ]; then
    log "Setup did not complete successfully.\nLast step: $(cat "$HEARTBEAT_FILE")\nCheck logs: \`cat /var/log/cloud-init-output.log\`" red
  fi
  rm -f "$HEARTBEAT_FILE"
  [[ "${CLEANUP_BASE_DIR:-}" == true ]] && rm -rf "$BASE_DIR" || true
}
trap handle_exit EXIT

# ERR trap sets flag so handle_exit knows to notify, then exits
trap 'echo -e "\033[0;31m=> ERROR: Script failed at line ${LINENO}: $BASH_COMMAND\033[0m" >&2; exit 1' ERR

# --- Pre-flight Checks ---
log "Running pre-flight checks..."

[[ $EUID -eq 0 ]] || die "Must run as root"
command -v curl >/dev/null && command -v jq >/dev/null || { apt-get update && apt-get install -y curl jq; }

# Load secrets from tmpfs (cloud-init) or env vars (manual run)
SECRETS_FILE="/run/setup-secrets"
if [[ -f "$SECRETS_FILE" ]]; then
  source "$SECRETS_FILE"
  rm -f "$SECRETS_FILE"
fi

os_name=$(lsb_release -is 2>/dev/null) || die "lsb_release not found"
os_version=$(lsb_release -rs)
[[ "$os_name" == "$REQUIRED_OS" ]] || die "Requires $REQUIRED_OS (found $os_name)"
[[ "$os_version" == "$REQUIRED_VERSION" ]] || die "Requires Ubuntu $REQUIRED_VERSION (found $os_version)"

total_ram_mb=$(free -m | awk '/^Mem:/{print $2}')
total_disk_gb=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
(( total_ram_mb >= MIN_RAM_MB )) || die "Need ${MIN_RAM_MB}MB RAM, found ${total_ram_mb}MB"
(( total_disk_gb >= MIN_DISK_GB )) || die "Need ${MIN_DISK_GB}GB disk, found ${total_disk_gb}GB"

# TAILSCALE_AUTHKEY is only required on first run (when Tailscale is not yet connected)
if ! command -v tailscale >/dev/null || ! tailscale status >/dev/null 2>&1; then
  [[ -n "${TAILSCALE_AUTHKEY:-}" ]] || die "TAILSCALE_AUTHKEY is required on first run (set env var or /run/setup-secrets)"
fi

# Fall back to previously saved webhook on re-runs
if [[ -z "${DISCORD_WEBHOOK_URL:-}" ]] && [[ -f /etc/server-discord-webhook ]]; then
  DISCORD_WEBHOOK_URL=$(cat /etc/server-discord-webhook)
fi
[[ -n "${DISCORD_WEBHOOK_URL:-}" ]] || die "DISCORD_WEBHOOK_URL is required (set env var or /run/setup-secrets)"

# Install server-notify early so all setup messages go through it
echo "$DISCORD_WEBHOOK_URL" > /etc/server-discord-webhook
chmod 600 /etc/server-discord-webhook
install -m 755 "$SCRIPT_DIR/server-notify" /usr/local/bin/server-notify

# Start heartbeat
heartbeat() {
  while true; do
    sleep 30
    server-notify "Still working on: $(cat "$HEARTBEAT_FILE")..." blue "Server Setup" >/dev/null 2>&1 || true
  done
}
heartbeat &
HEARTBEAT_PID=$!

log "Provisioning started"

# --- System Updates ---
log "Updating system packages..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

# --- Essential Packages ---
log "Installing essential packages..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ufw \
    fail2ban \
    curl \
    wget \
    gnupg \
    lsb-release \
    ca-certificates \
    software-properties-common \
    sysstat \
    auditd \
    audispd-plugins \
    unattended-upgrades \
    acl \
    apparmor \
    apparmor-utils \
    aide \
    rkhunter \
    lynis \
    needrestart \
    acct \
    libpam-pwquality \
    jq \
    git

# --- Time Synchronization ---
log "Configuring time synchronization..."
systemctl stop systemd-timesyncd 2>/dev/null || true
systemctl disable systemd-timesyncd 2>/dev/null || true
apt-get remove -y systemd-timesyncd 2>/dev/null || true
DEBIAN_FRONTEND=noninteractive apt-get install -y chrony

# --- System Hardening ---
log "Hardening system (AppArmor, AIDE, sysctl)..."

# Exclude noisy/ephemeral paths from AIDE
cat > /etc/aide/aide.conf.d/99-exclusions.conf <<'AIDE_CONF'
!/var/lib/docker
!/var/lib/containerd
!/run
!/tmp
!/var/tmp
!/var/log
!/var/cache
!/var/spool
AIDE_CONF

if [[ ! -f /var/lib/aide/aide.db ]]; then
  aide --config=/etc/aide/aide.conf --init
  mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
else
  log "AIDE database already exists, skipping init"
fi
if [[ ! -f /var/lib/rkhunter/db/rkhunter.dat ]]; then
  rkhunter --propupd
else
  log "rkhunter database already exists, skipping propupd"
fi

install -m 644 "$CONFIG_DIR/sysctl-security.conf" /etc/sysctl.d/99-security.conf
sysctl --system

install -m 644 "$CONFIG_DIR/docker-limits.conf" /etc/security/limits.d/docker.conf

# Disable unused kernel modules
install -m 644 "$CONFIG_DIR/kernel-modules-blacklist.conf" /etc/modprobe.d/cis-hardening.conf

# Filesystem mount hardening (/tmp and /dev/shm with noexec)
if ! grep -q '^tmpfs /tmp ' /etc/fstab; then
  echo "tmpfs /tmp tmpfs defaults,noexec,nosuid,nodev,mode=1777 0 0" >> /etc/fstab
fi
if ! grep -q '^tmpfs /dev/shm ' /etc/fstab; then
  echo "tmpfs /dev/shm tmpfs defaults,noexec,nosuid,nodev 0 0" >> /etc/fstab
fi
mount -o remount /tmp 2>/dev/null || mount /tmp 2>/dev/null || true
mount -o remount /dev/shm 2>/dev/null || mount /dev/shm 2>/dev/null || true

# Sudoers hardening
install -m 440 "$CONFIG_DIR/sudoers-hardening" /etc/sudoers.d/hardening

# Core dump restriction (systemd level)
install -m 644 "$CONFIG_DIR/coredump.conf" /etc/systemd/coredump.conf

# Restrict cron/at access to root only
rm -f /etc/cron.deny /etc/at.deny
echo "root" > /etc/cron.allow
echo "root" > /etc/at.allow
chmod 600 /etc/cron.allow /etc/at.allow

# Login banner (generate ASCII hostname with figlet)
log "Configuring login banner..."
DEBIAN_FRONTEND=noninteractive apt-get install -y figlet >/dev/null 2>&1
{
  echo ""
  figlet -f slant "$(hostname)" | sed 's/^/  /'
  echo ""
  cat "$CONFIG_DIR/issue"
} > /etc/issue
cp /etc/issue /etc/issue.net

# --- Login Defaults (umask, password aging) ---
log "Configuring login defaults..."
sed -i 's/^UMASK.*/UMASK\t\t027/' /etc/login.defs
sed -i 's/^PASS_MIN_DAYS.*/PASS_MIN_DAYS\t1/' /etc/login.defs
sed -i 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS\t365/' /etc/login.defs
grep -q '^umask 027' /etc/bash.bashrc || echo 'umask 027' >> /etc/bash.bashrc
grep -q '^umask 027' /etc/profile || echo 'umask 027' >> /etc/profile

# --- Docker ---
if ! command -v docker >/dev/null; then
  log "Installing Docker..."
  curl -fsSL https://get.docker.com -o get-docker.sh
  sh get-docker.sh
  rm get-docker.sh
else
  log "Docker already installed, skipping installation"
fi

log "Configuring Docker..."
mkdir -p /etc/docker
install -m 644 "$CONFIG_DIR/daemon.json" /etc/docker/daemon.json

# --- User Setup ---
if ! id docker &>/dev/null; then
  log "Creating docker user..."
  adduser --system --group --shell /bin/bash --home /home/docker --disabled-password docker
else
  log "Docker user already exists, ensuring group membership"
fi
usermod -aG docker docker
chown -R docker:docker /home/docker
chmod 750 /home/docker

# --- Tailscale ---
if ! command -v tailscale >/dev/null; then
  log "Installing Tailscale..."
  curl -fsSL https://tailscale.com/install.sh | sh
else
  log "Tailscale already installed, skipping installation"
fi

if tailscale status >/dev/null 2>&1; then
  log "Tailscale already connected, ensuring SSH is enabled"
  tailscale set --ssh
else
  log "Connecting to Tailscale..."
  tailscale up --authkey="$TAILSCALE_AUTHKEY" --ssh
fi
log "Tailscale is up" green

# --- Firewall ---
# Tailscale is up, so we can safely lock out port 22
log "Configuring firewall (Tailscale-only SSH)..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow in on tailscale0        # Allow all traffic over Tailscale
# NOTE: Port 22 is intentionally NOT opened. SSH only via Tailscale.
# NOTE: HTTP/HTTPS restricted to Cloudflare IPs only (added below).
ufw --force enable

# Allow HTTP/HTTPS only from Cloudflare IP ranges
log "Configuring Cloudflare-only HTTP/HTTPS access..."
install -m 755 "$SCRIPT_DIR/update-cloudflare-ips" /usr/local/bin/update-cloudflare-ips
ln -sf /usr/local/bin/update-cloudflare-ips /etc/cron.weekly/update-cloudflare-ips
/usr/local/bin/update-cloudflare-ips

# --- SSH Hardening (defense-in-depth, even though OpenSSH is disabled) ---
log "Hardening SSH config..."
sed -i 's/^#\?MaxAuthTries.*/MaxAuthTries 3/' /etc/ssh/sshd_config
sed -i 's/^#\?MaxSessions.*/MaxSessions 2/' /etc/ssh/sshd_config
sed -i 's/^#\?AllowTcpForwarding.*/AllowTcpForwarding no/' /etc/ssh/sshd_config

# --- Disable OpenSSH (Tailscale SSH handles all access) ---
log "Disabling OpenSSH (using Tailscale SSH instead)..."
systemctl disable ssh 2>/dev/null || true
systemctl stop ssh 2>/dev/null || true

# --- Configuration Files ---
log "Installing configuration files..."
install -m 644 "$CONFIG_DIR/jail.local" /etc/fail2ban/jail.local
install -m 644 "$CONFIG_DIR/audit.rules" /etc/audit/rules.d/audit.rules
# Rules are loaded by auditd on restart; -e 2 makes them immutable until reboot
install -m 644 "$CONFIG_DIR/docker-logrotate.conf" /etc/logrotate.d/docker-logs
install -m 644 "$CONFIG_DIR/unattended-upgrades.conf" /etc/apt/apt.conf.d/50unattended-upgrades

# --- Postfix Hardening ---
log "Hardening Postfix..."
postconf -e "smtpd_banner = \$myhostname ESMTP"
postconf -e "disable_vrfy_command = yes"

# --- needrestart: auto-restart services after updates ---
log "Configuring needrestart..."
sed -i "s/^#\?\$nrconf{restart}.*\$/\$nrconf{restart} = 'a';/" /etc/needrestart/needrestart.conf 2>/dev/null || true

# --- Password quality ---
log "Configuring password quality..."
install -m 644 "$CONFIG_DIR/pwquality.conf" /etc/security/pwquality.conf

# --- Home Directory Permissions ---
log "Tightening home directory permissions..."
find /home -maxdepth 1 -mindepth 1 -type d -exec chmod 750 {} \;

# --- Scripts ---
log "Installing scripts..."
install -m 755 "$SCRIPT_DIR/docker-cleanup" /usr/local/bin/docker-cleanup
install -m 755 "$SCRIPT_DIR/server-status" /usr/local/bin/server-status
install -m 755 "$SCRIPT_DIR/security-audit" /usr/local/bin/security-audit
install -m 755 "$SCRIPT_DIR/aide-check" /usr/local/bin/aide-check
ln -sf /usr/local/bin/docker-cleanup /etc/cron.daily/docker-cleanup
ln -sf /usr/local/bin/server-status /etc/cron.daily/server-status
ln -sf /usr/local/bin/aide-check /etc/cron.weekly/aide-check
install -m 644 "$SCRIPT_DIR/login-notify" /etc/profile.d/login-notify.sh

# --- Enable Services ---
log "Starting services..."
systemctl enable apparmor chrony docker fail2ban auditd postfix
systemctl restart apparmor chrony docker fail2ban auditd postfix

# --- Cleanup ---
apt-get autoremove -y
apt-get clean

# --- Done ---
echo ""
echo "  Docker:     $(docker --version)"
echo "  Tailscale:  $(tailscale version | head -1)"
echo "  Kernel:     $(uname -r)"
echo "  AppArmor:   $(aa-status --enabled 2>/dev/null && echo 'Enabled' || echo 'Disabled')"
echo "  UFW:        $(ufw status | grep Status)"
echo "  fail2ban:   $(fail2ban-client status 2>/dev/null | grep 'Number of jail:' || echo 'running')"
echo ""
echo "  IMPORTANT: Reboot the server to apply all kernel settings"
echo "  Port 22 is NOT open. SSH access is Tailscale-only."

# --- Verify health check works ---
log "Running health check test..."
server-status

SETUP_COMPLETED=true
log "Setup complete! Docker $(docker --version | awk '{print $3}' | tr -d ','), Tailscale $(tailscale version | head -1). Reboot to apply kernel settings." green
