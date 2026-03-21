#!/bin/bash

# Remote Docker Compose deployment tool
# Inspired by Kamal — rsync + docker context over SSH
#
# Usage:
#   ./deploy.sh <server> <command> [stack] [args...]
#
# Commands:
#   setup              Set up docker context for a server
#   deploy [stack]     Sync and start stack(s) (default: all stacks for server)
#   restart [stack]    Restart stack(s)
#   stop [stack]       Stop stack(s)
#   logs [stack]       Tail logs (pass extra args like --since 5m)
#   ps [stack]         Show running containers
#   exec <stack> ...   Run a command in a stack's container
#   pull [stack]       Pull latest images
#   shell              Open SSH session to server
#   info               Show server and stack configuration

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACHINES_DIR="$SCRIPT_DIR/machines"
CONF_FILE="$SCRIPT_DIR/deploy.conf"

# --- Colors ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}=> $1${NC}"; }
success() { echo -e "${GREEN}=> $1${NC}"; }
warn()    { echo -e "${YELLOW}=> $1${NC}"; }
error()   { echo -e "${RED}=> ERROR: $1${NC}" >&2; exit 1; }

# --- Dependencies ---
command -v yq >/dev/null 2>&1 || error "yq is required but not installed. Install it: sudo pacman -S yq"

# --- Config parsing ---
# Reads a key from an INI-style [section]
ini_get() {
  local section="$1" key="$2"
  sed -n "/^\[$section\]/,/^\[/p" "$CONF_FILE" | grep "^$key " | sed "s/^$key *= *//"
}

get_server_host() {
  ini_get "$1" "host"
}

get_server_base_dir() {
  ini_get "$1" "dir"
}

get_server_stacks() {
  ini_get "$1" "stacks" | tr ' ' '\n'
}

get_all_servers() {
  grep '^\[' "$CONF_FILE" | tr -d '[]'
}

validate_server() {
  local server="$1"
  local host
  host=$(get_server_host "$server")
  [[ -n "$host" ]] || error "Unknown server '$server'. Available: $(get_all_servers | tr '\n' ' ')"
}

validate_stack() {
  local server="$1"
  local stack="$2"
  local stacks
  stacks=$(get_server_stacks "$server")
  echo "$stacks" | grep -qx "$stack" || error "Stack '$stack' not configured for server '$server'. Available: $(echo "$stacks" | tr '\n' ' ')"
}


# --- Environment & Secrets ---
SSM_PREFIX="/davafons-infra"

# Builds the .env file from three sources:
#   1. Runtime vars from the server (/etc/environment, e.g. TAILSCALE_IP)
#   2. Clear env vars from .env.yaml (committed, non-secret config)
#   3. Secrets from .env.yaml fetched from AWS SSM Parameter Store
#
# .env.yaml format (same structure as Kamal's deploy.yml):
#   env:
#     clear:
#       KEY: value
#     secret:
#       - SECRET_NAME
sync_env() {
  local server="$1" stack="$2"
  local host base_dir
  host=$(get_server_host "$server")
  base_dir=$(get_server_base_dir "$server")

  local env_yaml="$MACHINES_DIR/$server/$stack/.env.yaml"
  local env_content=""

  # 1. Runtime vars from the server
  info "Fetching runtime vars from $host"
  env_content+=$(ssh "$host" "cat /etc/environment" 2>/dev/null || true)$'\n'

  [[ -f "$env_yaml" ]] || { _write_env "$host" "$base_dir/$stack" "$env_content"; return 0; }

  # 2. Clear env vars from .env.yaml
  local clear_vars
  clear_vars=$(yq -r '.env.clear // {} | to_entries[] | .key + "=" + (.value | tostring)' "$env_yaml" 2>/dev/null) || true
  [[ -n "$clear_vars" ]] && env_content+="$clear_vars"$'\n'

  # 3. Fetch secrets from AWS SSM
  local secret_names
  secret_names=$(yq -r '.env.secret // [] | .[]' "$env_yaml") || error "Failed to parse secrets from $env_yaml"

  if [[ -n "$secret_names" ]]; then
    local ssm_path="$SSM_PREFIX/$server/$stack"
    info "Fetching secrets for $stack from $ssm_path"

    # Bulk fetch (like: kamal secrets fetch --adapter aws_ssm_parameter_store --from <path>)
    local params
    params=$(aws ssm get-parameters-by-path \
      --path "$ssm_path/" \
      --with-decryption \
      --query "Parameters[*].[Name,Value]" \
      --output text) || error "Failed to fetch secrets from AWS SSM (path: $ssm_path)"

    # Extract each secret (like: kamal secrets extract <path/NAME> $SECRETS)
    for name in $secret_names; do
      local value
      value=$(echo "$params" | grep "$ssm_path/$name" | cut -f2 || true)
      [[ -n "$value" ]] || error "Secret '$name' not found in SSM at $ssm_path/$name"
      env_content+="$name=$value"$'\n'
    done
  fi

  # Validate no empty values
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local key="${line%%=*}"
    local val="${line#*=}"
    [[ -n "$val" ]] || error "Env var '$key' is empty — check SSM or .env.yaml"
  done <<< "$env_content"

  _write_env "$host" "$base_dir/$stack" "$env_content"
}

_write_env() {
  local host="$1" remote_dir="$2" content="$3"
  [[ -n "$content" ]] || return 0
  info "Writing .env to $host:$remote_dir/.env"
  ssh "$host" "mkdir -p $remote_dir"
  echo "$content" | ssh "$host" "cat > $remote_dir/.env && chmod 600 $remote_dir/.env"
}

_clean_env() {
  local server="$1" stack="$2"
  local host base_dir
  host=$(get_server_host "$server")
  base_dir=$(get_server_base_dir "$server")
  ssh "$host" "rm -f $base_dir/$stack/.env"
}

# --- Core functions ---
sync_stack() {
  local server="$1" stack="$2"
  local host base_dir
  host=$(get_server_host "$server")
  base_dir=$(get_server_base_dir "$server")

  local local_dir="$MACHINES_DIR/$server/$stack/"
  local remote_dir="$base_dir/$stack/"

  [[ -d "$local_dir" ]] || error "Local stack directory not found: $local_dir"

  info "Syncing $stack -> $host:$remote_dir"
  ssh "$host" "mkdir -p $remote_dir"
  rsync -avz --delete \
    --exclude '.env' \
    --exclude '.env.yaml' \
    "$local_dir" "$host:$remote_dir"
}

docker_compose() {
  local server="$1" stack="$2"
  shift 2
  local host base_dir
  host=$(get_server_host "$server")
  base_dir=$(get_server_base_dir "$server")

  ssh "$host" "cd $base_dir/$stack && docker compose $*"
}

resolve_stacks() {
  local server="$1"
  local stack="${2:-}"

  if [[ -n "$stack" ]]; then
    validate_stack "$server" "$stack"
    echo "$stack"
  else
    get_server_stacks "$server"
  fi
}

# --- Commands ---
cmd_setup() {
  local server="$1"
  local host
  host=$(get_server_host "$server")

  info "Testing SSH connection to $host..."
  if ssh "$host" "docker info" >/dev/null 2>&1; then
    success "Connected to Docker on $host"
  else
    error "Failed to connect. Check SSH access: ssh $host"
  fi
}

cmd_deploy() {
  local server="$1"
  local stack="${2:-}"
  local service="${3:-}"
  local stacks
  stacks=$(resolve_stacks "$server" "$stack")

  for s in $stacks; do
    echo ""
    info "${BOLD}Deploying $s${service:+ ($service)} to $server${NC}"
    sync_env "$server" "$s"
    sync_stack "$server" "$s"
    docker_compose "$server" "$s" up -d --remove-orphans $service
    _clean_env "$server" "$s"
    success "$s${service:+ ($service)} deployed"
  done
}

cmd_pull() {
  local server="$1"
  local stack="${2:-}"
  local stacks
  stacks=$(resolve_stacks "$server" "$stack")

  for s in $stacks; do
    info "Pulling images for $s"
    docker_compose "$server" "$s" pull
  done
}

cmd_restart() {
  local server="$1"
  local stack="${2:-}"
  local stacks
  stacks=$(resolve_stacks "$server" "$stack")

  for s in $stacks; do
    info "Restarting $s"
    docker_compose "$server" "$s" restart
    success "$s restarted"
  done
}

cmd_stop() {
  local server="$1"
  local stack="${2:-}"
  local stacks
  stacks=$(resolve_stacks "$server" "$stack")

  for s in $stacks; do
    info "Stopping $s"
    docker_compose "$server" "$s" down
    success "$s stopped"
  done
}

cmd_logs() {
  local server="$1"
  local stack="$2"
  shift 2

  validate_stack "$server" "$stack"
  docker_compose "$server" "$stack" logs -f "$@"
}

cmd_ps() {
  local server="$1"
  local stack="${2:-}"
  local stacks
  stacks=$(resolve_stacks "$server" "$stack")

  for s in $stacks; do
    echo -e "\n${BOLD}[$s]${NC}"
    docker_compose "$server" "$s" ps
  done
}

cmd_env() {
  local server="$1"
  local stack="${2:-}"
  local stacks
  stacks=$(resolve_stacks "$server" "$stack")

  for s in $stacks; do
    local ssm_path="$SSM_PREFIX/$server/$s"
    echo -e "\n${BOLD}[$s]${NC} (SSM: $ssm_path)"
    aws ssm get-parameters-by-path \
      --path "$ssm_path/" \
      --with-decryption \
      --query "Parameters[*].[Name,Value]" \
      --output text || error "Failed to fetch secrets from AWS SSM. Try: aws login"
  done
}

cmd_reboot() {
  local server="$1"
  local stack="${2:-}"
  local service="${3:-}"
  local stacks
  stacks=$(resolve_stacks "$server" "$stack")

  for s in $stacks; do
    echo ""
    info "${BOLD}Rebooting $s${service:+ ($service)} on $server${NC}"
    sync_env "$server" "$s"
    sync_stack "$server" "$s"
    if [[ -n "$service" ]]; then
      docker_compose "$server" "$s" rm -fsv "$service"
      local host
      host=$(get_server_host "$server")
      ssh "$host" "docker volume ls -q --filter name=${s}_${service} | xargs -r docker volume rm"
    else
      docker_compose "$server" "$s" down -v
    fi
    docker_compose "$server" "$s" up -d --remove-orphans $service
    _clean_env "$server" "$s"
    success "$s${service:+ ($service)} rebooted"
  done
}

cmd_exec() {
  local server="$1"
  local stack="$2"
  shift 2

  validate_stack "$server" "$stack"
  docker_compose "$server" "$stack" exec "$@"
}

cmd_shell() {
  local server="$1"
  local host
  host=$(get_server_host "$server")
  ssh "$host"
}

cmd_info() {
  local server="${1:-}"

  if [[ -n "$server" ]]; then
    validate_server "$server"
    local host base_dir stacks
    host=$(get_server_host "$server")
    base_dir=$(get_server_base_dir "$server")
    stacks=$(get_server_stacks "$server")

    echo -e "${BOLD}$server${NC}"
    echo "  Host:      $host"
    echo "  Base dir:  $base_dir"
    echo "  Stacks:    $(echo "$stacks" | tr '\n' ' ')"
  else
    for srv in $(get_all_servers); do
      cmd_info "$srv"
      echo ""
    done
  fi
}

# --- Usage ---
usage() {
  cat <<'EOF'
deploy.sh — Remote Docker Compose deployment

Usage:
  ./deploy.sh <server> <command> [stack] [args...]

Commands:
  setup              Set up docker context for a server
  deploy [stack] [service]  Sync and deploy stack(s) — optionally target a single service
  env [stack]              Fetch and display env/secrets without deploying
  reboot [stack] [service] Destroy containers & volumes, then redeploy from scratch
  restart [stack]    Restart stack(s)
  stop [stack]       Stop stack(s)
  pull [stack]       Pull latest images
  logs <stack>       Tail logs (extra args passed to docker compose logs)
  ps [stack]         Show running containers
  exec <stack> ...   Execute command in a stack container
  shell              SSH into the server
  info               Show server configuration

Examples:
  ./deploy.sh monitoring setup
  ./deploy.sh monitoring deploy monitoring
  ./deploy.sh qtower deploy db
  ./deploy.sh qtower deploy              # deploy all stacks
  ./deploy.sh qtower ps
  ./deploy.sh monitoring logs monitoring --since 5m
  ./deploy.sh monitoring exec monitoring grafana sh
  ./deploy.sh qtower shell
  ./deploy.sh info                              # show all servers
EOF
}

# --- Main ---
[[ -f "$CONF_FILE" ]] || error "Config file not found: $CONF_FILE"

# Handle bare 'info' command
if [[ "${1:-}" == "info" ]]; then
  cmd_info "${2:-}"
  exit 0
fi

SERVER="${1:-}"
COMMAND="${2:-}"

[[ -n "$SERVER" ]] || { usage; exit 1; }
[[ -n "$COMMAND" ]] || { usage; exit 1; }

validate_server "$SERVER"

case "$COMMAND" in
  setup)   cmd_setup "$SERVER" ;;
  deploy)  cmd_deploy "$SERVER" "${3:-}" "${4:-}" ;;
  env)     cmd_env "$SERVER" "${3:-}" ;;
  reboot)  cmd_reboot "$SERVER" "${3:-}" "${4:-}" ;;
  pull)    cmd_pull "$SERVER" "${3:-}" ;;
  restart) cmd_restart "$SERVER" "${3:-}" ;;
  stop)    cmd_stop "$SERVER" "${3:-}" ;;
  logs)    [[ -n "${3:-}" ]] || error "logs requires a stack name"; cmd_logs "$SERVER" "${@:3}" ;;
  ps)      cmd_ps "$SERVER" "${3:-}" ;;
  exec)    [[ -n "${3:-}" ]] || error "exec requires a stack name"; cmd_exec "$SERVER" "${@:3}" ;;
  shell)   cmd_shell "$SERVER" ;;
  info)    cmd_info "$SERVER" ;;
  *)       error "Unknown command: $COMMAND" ;;
esac
