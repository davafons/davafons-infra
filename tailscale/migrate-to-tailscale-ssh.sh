#!/bin/bash

# Migrate an existing server from OpenSSH to Tailscale SSH
# Run this ON the server you want to migrate (as root)
#
# Usage: bash migrate-to-tailscale-ssh.sh

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()    { echo -e "${YELLOW}=> $1${NC}"; }
success() { echo -e "${GREEN}=> $1${NC}"; }
error()   { echo -e "${RED}=> ERROR: $1${NC}" >&2; exit 1; }

[[ $EUID -eq 0 ]] || error "Must run as root"

# --- Pre-flight checks ---
info "Checking Tailscale status..."
command -v tailscale >/dev/null || error "Tailscale is not installed"
tailscale status >/dev/null 2>&1 || error "Tailscale is not connected. Run: tailscale up --ssh"

# Check if Tailscale SSH is already enabled
if tailscale status --json | grep -q '"SSH":true' 2>/dev/null; then
  info "Tailscale SSH is already enabled"
else
  info "Enabling Tailscale SSH..."
  tailscale set --ssh
  success "Tailscale SSH enabled"
fi

# --- Verify Tailscale SSH works before disabling OpenSSH ---
TS_IP=$(tailscale ip -4)
info "Tailscale IP: $TS_IP"
info "IMPORTANT: Before continuing, verify you can SSH via Tailscale from another device:"
echo ""
echo "  ssh root@$(hostname)"
echo ""
read -rp "Can you SSH via Tailscale? (yes/no): " CONFIRM
[[ "$CONFIRM" == "yes" ]] || error "Aborting. Fix Tailscale SSH before disabling OpenSSH."

# --- Update firewall ---
info "Updating firewall rules..."
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  # Ensure Tailscale traffic is allowed
  ufw allow in on tailscale0 2>/dev/null || true
  # Remove any port 22 rules
  ufw delete allow ssh 2>/dev/null || true
  ufw delete allow 22 2>/dev/null || true
  ufw delete allow 22/tcp 2>/dev/null || true
  success "Firewall updated (port 22 closed, Tailscale allowed)"
else
  info "UFW not active, skipping firewall changes"
fi

# --- Disable OpenSSH ---
info "Disabling OpenSSH..."
systemctl disable ssh
systemctl stop ssh
success "OpenSSH disabled"

# --- Disable fail2ban sshd jail if present ---
if [ -f /etc/fail2ban/jail.local ]; then
  if grep -q "^\[sshd\]" /etc/fail2ban/jail.local; then
    info "Disabling fail2ban sshd jail..."
    sed -i '/^\[sshd\]/,/^$/{s/enabled = true/enabled = false/}' /etc/fail2ban/jail.local
    systemctl restart fail2ban 2>/dev/null || true
    success "fail2ban sshd jail disabled"
  fi
fi

# --- Done ---
echo ""
success "Migration complete!"
echo ""
echo "  SSH access is now Tailscale-only: ssh root@$(hostname)"
echo "  OpenSSH has been stopped and disabled."
echo ""
echo "  To re-enable OpenSSH in an emergency:"
echo "    systemctl start ssh  (via Hetzner console)"
