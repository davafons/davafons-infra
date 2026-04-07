#!/bin/bash

# Sync SigNoz alert rules and notification channels from JSON files.
# Fetches secrets from AWS SSM Parameter Store automatically.
#
# Usage:
#   ./sync-alerts.sh

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()    { echo -e "${YELLOW}=> $1${NC}"; }
success() { echo -e "${GREEN}=> $1${NC}"; }
error()   { echo -e "${RED}=> ERROR: $1${NC}" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ALERTS_DIR="$SCRIPT_DIR/alerts"

SSM_PATH="/davafons-infra/monitoring/signoz"
SIGNOZ_URL="${SIGNOZ_URL:-http://monitoring:8080}"

# --- Fetch secrets from SSM ---
info "Fetching secrets from SSM..."

ssm_params=$(aws ssm get-parameters-by-path \
  --path "$SSM_PATH/" \
  --with-decryption \
  --query "Parameters[*].{Name:Name,Value:Value}" \
  --output json) || error "Failed to fetch SSM parameters. Run 'aws login' first."

ssm_get() {
  echo "$ssm_params" | jq -r ".[] | select(.Name == \"$SSM_PATH/$1\") | .Value"
}

SIGNOZ_API_KEY=$(ssm_get "SIGNOZ_API_KEY")

[[ -n "$SIGNOZ_API_KEY" ]] || error "SIGNOZ_API_KEY not found in SSM ($SSM_PATH/SIGNOZ_API_KEY)"

success "Secrets loaded from SSM"

# --- API helper ---
api() {
  local method="$1" endpoint="$2"
  shift 2
  local response http_code
  response=$(curl -s -w "\n%{http_code}" -X "$method" \
    "${SIGNOZ_URL}${endpoint}" \
    -H "Content-Type: application/json" \
    -H "SIGNOZ-API-KEY: ${SIGNOZ_API_KEY}" \
    "$@")
  http_code=$(echo "$response" | tail -1)
  response=$(echo "$response" | sed '$d')
  if [[ "$http_code" -ge 400 ]]; then
    echo -e "${RED}  API error ($method $endpoint): $response${NC}" >&2
    return 1
  fi
  echo "$response"
}

# --- Sync notification channels ---
sync_channels() {
  info "Syncing notification channels..."

  local existing
  existing=$(api GET "/api/v1/channels" 2>/dev/null || echo '{"data":[]}')

  for channel_file in "$ALERTS_DIR"/channel-*.json; do
    [[ -f "$channel_file" ]] || continue

    local name
    name=$(jq -r '.name' "$channel_file")

    local payload
    payload=$(cat "$channel_file")

    # Check if channel already exists
    local existing_id
    existing_id=$(echo "$existing" | jq -r ".data[] | select(.name == \"$name\") | .id" 2>/dev/null || true)

    if [[ -n "$existing_id" ]]; then
      if api PUT "/api/v1/channels/$existing_id" -d "$payload" > /dev/null; then
        success "  Updated channel: $name"
      else
        info "  Channel already exists: $name (update failed, may need admin API key)"
      fi
    else
      api POST "/api/v1/channels" -d "$payload" > /dev/null
      success "  Created channel: $name"
    fi
  done
}

# --- Sync alert rules ---
sync_rules() {
  info "Syncing alert rules..."

  local existing
  existing=$(api GET "/api/v1/rules" 2>/dev/null || echo '{"data":{"rules":[]}}')

  for rule_file in "$ALERTS_DIR"/*.json; do
    [[ -f "$rule_file" ]] || continue

    # Skip channel files
    [[ "$(basename "$rule_file")" == channel-* ]] && continue

    local alert_name
    alert_name=$(jq -r '.alert' "$rule_file")

    local payload
    payload=$(cat "$rule_file")

    # Check if rule already exists (match by alert name)
    local existing_id
    existing_id=$(echo "$existing" | jq -r ".data.rules[] | select(.alert == \"$alert_name\") | .id" 2>/dev/null || true)

    if [[ -n "$existing_id" ]]; then
      api PUT "/api/v1/rules/$existing_id" -d "$payload" > /dev/null
      success "  Updated rule: $alert_name"
    else
      api POST "/api/v1/rules" -d "$payload" > /dev/null
      success "  Created rule: $alert_name"
    fi
  done
}

# --- Main ---
sync_channels
sync_rules

success "All alerts synced!"
