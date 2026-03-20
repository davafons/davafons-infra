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

echo ""
echo "Discord webhook URL for server notifications."
echo "Create one at: Channel Settings > Integrations > Webhooks"
echo ""
read -rp "Discord webhook URL: " DISCORD_WEBHOOK_URL
[ -n "$DISCORD_WEBHOOK_URL" ] || error "Discord webhook URL is required"

# --- Check for existing server ---
if hcloud server describe "$SERVER_NAME" >/dev/null 2>&1; then
  error "Server '$SERVER_NAME' already exists. Delete it first: hcloud server delete $SERVER_NAME"
fi

# --- Build cloud-init user-data ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SCRIPT="$SCRIPT_DIR/setup.sh"
[ -f "$SETUP_SCRIPT" ] || error "setup.sh not found at $SETUP_SCRIPT"

USERDATA=$(mktemp)
trap "rm -f $USERDATA" EXIT
cat > "$USERDATA" <<CLOUDINIT
#!/bin/bash
export TAILSCALE_AUTHKEY='$TAILSCALE_AUTHKEY'
export DISCORD_WEBHOOK_URL='$DISCORD_WEBHOOK_URL'

$(cat "$SETUP_SCRIPT")
CLOUDINIT

# --- Create server ---
info "Creating server: $SERVER_NAME ($SERVER_TYPE, $IMAGE, $LOCATION)"
hcloud server create \
  --name "$SERVER_NAME" \
  --type "$SERVER_TYPE" \
  --image "$IMAGE" \
  --location "$LOCATION" \
  --ssh-key "$SSH_KEY_NAME" \
  --user-data-from-file "$USERDATA"

IP=$(hcloud server ip "$SERVER_NAME")
success "Server created at $IP"

# --- Notify Discord ---
curl -s -X POST "$DISCORD_WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  -d "{\"embeds\": [{\"title\": \"$SERVER_NAME - provisioning\", \"description\": \"Server created at \`$IP\` ($SERVER_TYPE, $LOCATION). Cloud-init setup starting...\", \"color\": 3447003}]}" >/dev/null 2>&1 || true
success "Discord notified - follow progress there"

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
success "Server '$SERVER_NAME' provisioned!"
echo ""
echo "  Public IP:    $IP"
echo "  SSH:          ssh $SERVER_NAME  (via Tailscale, once setup finishes)"
echo ""
echo "  Setup is running via cloud-init - watch Discord for progress."
echo "  Once complete, reboot to apply all kernel settings:"
echo "    hcloud server reboot $SERVER_NAME"
