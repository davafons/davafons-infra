#!/bin/bash

# Provision a new Hetzner server with Docker + Tailscale
# Usage: hetzner-provision [server-name] [server-type] [location]

set -euo pipefail

# --- Config ---
SERVER_NAME="${1:-wariwari-prod}"
SERVER_TYPE="${2:-cx23}"
LOCATION="${3:-hel1}"
IMAGE="ubuntu-24.04"
SSH_KEY_NAME="hetzner-$SERVER_NAME"
SSH_KEY_PATH="$HOME/.ssh/$SSH_KEY_NAME"
SETUP_URL="https://setup.davafons.cc/hetzner/setup.sh"

# --- Colors ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()    { echo -e "${YELLOW}=> $1${NC}"; }
success() { echo -e "${GREEN}=> $1${NC}"; }
error()   { echo -e "${RED}=> ERROR: $1${NC}" >&2; exit 1; }

# --- Preflight ---
command -v hcloud >/dev/null || error "hcloud CLI not installed. Run: sudo pacman -S hcloud"
hcloud server list >/dev/null 2>&1 || error "hcloud not configured. Run: hcloud context create wariwari"

# --- SSH key ---
if [ ! -f "$SSH_KEY_PATH" ]; then
  info "Generating SSH key at $SSH_KEY_PATH"
  ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N "" -C "hetzner-provisioning"
  success "SSH key created"
fi

# Ensure key exists in hcloud
if ! hcloud ssh-key describe "$SSH_KEY_NAME" >/dev/null 2>&1; then
  info "Uploading SSH key to Hetzner"
  hcloud ssh-key create --name "$SSH_KEY_NAME" --public-key-from-file "${SSH_KEY_PATH}.pub"
  success "SSH key uploaded"
else
  info "SSH key '$SSH_KEY_NAME' already exists in Hetzner"
fi

# --- Tailscale auth key ---
echo ""
echo "You need a Tailscale auth key for non-interactive setup."
echo "Generate one at: https://login.tailscale.com/admin/settings/keys"
echo "(Use a reusable key if you provision servers often)"
echo ""
read -rp "Tailscale auth key: " TAILSCALE_AUTHKEY
[ -n "$TAILSCALE_AUTHKEY" ] || error "Tailscale auth key is required"

# --- Check for existing server ---
if hcloud server describe "$SERVER_NAME" >/dev/null 2>&1; then
  error "Server '$SERVER_NAME' already exists. Delete it first: hcloud server delete $SERVER_NAME"
fi

# --- Create server ---
info "Creating server: $SERVER_NAME ($SERVER_TYPE, $IMAGE, $LOCATION)"
hcloud server create \
  --name "$SERVER_NAME" \
  --type "$SERVER_TYPE" \
  --image "$IMAGE" \
  --location "$LOCATION" \
  --ssh-key "$SSH_KEY_NAME"

IP=$(hcloud server ip "$SERVER_NAME")
success "Server created at $IP"

# --- Wait for SSH ---
info "Waiting for SSH to become available..."
for i in $(seq 1 30); do
  if ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"$IP" true 2>/dev/null; then
    break
  fi
  if [ "$i" -eq 30 ]; then
    error "SSH never became available"
  fi
  sleep 2
done
success "SSH is ready"

# --- Run setup ---
info "Running setup script from $SETUP_URL..."
ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no root@"$IP" \
  "curl -fsSL '$SETUP_URL' | TAILSCALE_AUTHKEY='$TAILSCALE_AUTHKEY' bash"

# --- SSH config ---
info "Adding SSH config entry..."
SSH_CONFIG="$HOME/.ssh/config"

if grep -q "^Host $SERVER_NAME$" "$SSH_CONFIG" 2>/dev/null; then
  info "SSH config entry for '$SERVER_NAME' already exists, skipping"
else
  cat >> "$SSH_CONFIG" <<EOF

Host $SERVER_NAME
  Hostname $SERVER_NAME
  User root
  IdentityFile $SSH_KEY_PATH
  AddKeysToAgent yes
EOF
  chmod 600 "$SSH_CONFIG"
  success "SSH config entry added"
fi

# --- Done ---
echo ""
success "Server '$SERVER_NAME' is ready!"
echo ""
echo "  Public IP:    $IP"
echo "  SSH:          ssh $SERVER_NAME  (via Tailscale)"
echo ""
echo "  Port 22 is closed. Access is Tailscale-only."
echo "  Reboot the server to apply all kernel settings:"
echo "    hcloud server reboot $SERVER_NAME"
