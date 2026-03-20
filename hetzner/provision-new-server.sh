#!/bin/bash

# Provision a new Hetzner server with Docker + Tailscale
# Usage: hetzner-provision [server-name] [server-type] [location]

set -euo pipefail

# --- Config ---
SERVER_NAME="${1:-wariwari-prod}"
SERVER_TYPE="${2:-cx23}"
LOCATION="${3:-hel1}"
IMAGE="ubuntu-24.04"
SSH_KEY_NAME="hetzner-provisioning"
SSH_KEY_PATH="$HOME/.ssh/$SSH_KEY_NAME"
SETUP_BASE_URL="https://setup.davafons.cc/hetzner"
SETUP_URL="$SETUP_BASE_URL/setup.sh"
MONITORING_URL="$SETUP_BASE_URL/setup-monitoring.sh"

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

# --- SSH key (shared across all servers, only used for emergency access) ---
if [ ! -f "$SSH_KEY_PATH" ]; then
  info "Generating shared provisioning SSH key at $SSH_KEY_PATH"
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

echo ""
echo "Monitoring endpoints (self-hosted Prometheus/Loki)."
echo ""
read -rp "Prometheus remote write URL: " PROMETHEUS_REMOTE_WRITE_URL
[ -n "$PROMETHEUS_REMOTE_WRITE_URL" ] || error "Prometheus remote write URL is required"
read -rp "Loki push URL: " LOKI_URL
[ -n "$LOKI_URL" ] || error "Loki URL is required"

# --- Check for existing server ---
if hcloud server describe "$SERVER_NAME" >/dev/null 2>&1; then
  error "Server '$SERVER_NAME' already exists. Delete it first: hcloud server delete $SERVER_NAME"
fi

# --- Build cloud-init user-data ---
USERDATA=$(mktemp)
trap "rm -f $USERDATA" EXIT
cat > "$USERDATA" <<CLOUDINIT
#!/bin/bash
set -euo pipefail

DISCORD_WEBHOOK_URL='$DISCORD_WEBHOOK_URL'

# Notify Discord on any failure in the wrapper itself
notify_error() {
  curl -s -X POST "\$DISCORD_WEBHOOK_URL" \\
    -H "Content-Type: application/json" \\
    -d '{"embeds": [{"title": "'"\$(hostname)"' - provisioning", "description": "Cloud-init failed: '"'\$1'"'", "color": 16711680}]}' 2>/dev/null || true
}
trap 'notify_error "wrapper script failed at line \$LINENO"' ERR

# Write secrets to tmpfs (RAM only, never written to disk)
install -m 600 /dev/null /run/setup-secrets
cat > /run/setup-secrets <<'SECRETS'
TAILSCALE_AUTHKEY='$TAILSCALE_AUTHKEY'
DISCORD_WEBHOOK_URL='$DISCORD_WEBHOOK_URL'
PROMETHEUS_REMOTE_WRITE_URL='$PROMETHEUS_REMOTE_WRITE_URL'
LOKI_URL='$LOKI_URL'
SECRETS

# Download and run setup script (it downloads its own dependencies)
SETUP_SCRIPT=\$(mktemp)
curl -fsSL '$SETUP_URL' -o "\$SETUP_SCRIPT" || { notify_error "Failed to download setup script from $SETUP_URL"; exit 1; }
bash "\$SETUP_SCRIPT"
rm -f "\$SETUP_SCRIPT"

# Download and run monitoring setup
MONITORING_SCRIPT=\$(mktemp)
curl -fsSL '$MONITORING_URL' -o "\$MONITORING_SCRIPT" || { notify_error "Failed to download monitoring script"; exit 1; }
bash "\$MONITORING_SCRIPT"
rm -f "\$MONITORING_SCRIPT"
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

# --- Done ---
echo ""
success "Server '$SERVER_NAME' provisioned!"
echo ""
echo "  Public IP:    $IP"
echo "  SSH:          ssh root@$SERVER_NAME  (via Tailscale SSH, once setup finishes)"
echo ""
echo "  Setup is running via cloud-init - watch Discord for progress."
echo "  Once complete, reboot to apply all kernel settings:"
echo "    hcloud server reboot $SERVER_NAME"
echo ""
echo "  NOTE: OpenSSH is disabled. All SSH access is via Tailscale."
echo "  Emergency access: use Hetzner console (hcloud server ssh $SERVER_NAME or web console)"
