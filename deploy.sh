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
COMPOSE_DIR="$SCRIPT_DIR/docker-compose"
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

# --- Config parsing ---
get_server_host() {
  local server="$1"
  grep "^SERVER $server " "$CONF_FILE" | awk '{print $3}'
}

get_server_base_dir() {
  local server="$1"
  grep "^SERVER $server " "$CONF_FILE" | awk '{print $4}'
}

get_server_stacks() {
  local server="$1"
  grep "^STACK $server " "$CONF_FILE" | awk '{print $3}'
}

get_all_servers() {
  grep "^SERVER " "$CONF_FILE" | awk '{print $2}'
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

context_name() {
  echo "deploy-$1"
}

# --- Core functions ---
sync_stack() {
  local server="$1" stack="$2"
  local host base_dir
  host=$(get_server_host "$server")
  base_dir=$(get_server_base_dir "$server")

  local local_dir="$COMPOSE_DIR/$stack/"
  local remote_dir="$base_dir/$stack/"

  [[ -d "$local_dir" ]] || error "Local stack directory not found: $local_dir"

  info "Syncing $stack -> $host:$remote_dir"
  ssh "$host" "mkdir -p $remote_dir"
  rsync -avz --delete \
    --exclude '.env' \
    --exclude '.env.local' \
    "$local_dir" "$host:$remote_dir"
}

docker_compose() {
  local server="$1" stack="$2"
  shift 2
  local base_dir
  base_dir=$(get_server_base_dir "$server")
  local ctx
  ctx=$(context_name "$server")

  docker --context "$ctx" compose -f "$base_dir/$stack/docker-compose.yaml" "$@"
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
  local host ctx
  host=$(get_server_host "$server")
  ctx=$(context_name "$server")

  info "Setting up docker context '$ctx' for $host"

  if docker context inspect "$ctx" &>/dev/null; then
    warn "Context '$ctx' already exists, updating..."
    docker context rm -f "$ctx" >/dev/null
  fi

  docker context create "$ctx" --docker "host=ssh://$host"
  success "Docker context '$ctx' created"

  info "Testing connection..."
  if docker --context "$ctx" info >/dev/null 2>&1; then
    success "Connected to Docker on $host"
  else
    error "Failed to connect. Check SSH access: ssh $host"
  fi
}

cmd_deploy() {
  local server="$1"
  local stack="${2:-}"
  local stacks
  stacks=$(resolve_stacks "$server" "$stack")

  # Ensure context exists
  local ctx
  ctx=$(context_name "$server")
  docker context inspect "$ctx" &>/dev/null || cmd_setup "$server"

  for s in $stacks; do
    echo ""
    info "${BOLD}Deploying $s to $server${NC}"
    sync_stack "$server" "$s"
    docker_compose "$server" "$s" up -d --remove-orphans
    success "$s deployed"
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
  deploy [stack]     Sync and deploy stack(s) — omit stack to deploy all
  restart [stack]    Restart stack(s)
  stop [stack]       Stop stack(s)
  pull [stack]       Pull latest images
  logs <stack>       Tail logs (extra args passed to docker compose logs)
  ps [stack]         Show running containers
  exec <stack> ...   Execute command in a stack container
  shell              SSH into the server
  info               Show server configuration

Examples:
  ./deploy.sh observability setup
  ./deploy.sh observability deploy observability
  ./deploy.sh wariwari-prod deploy db
  ./deploy.sh wariwari-prod deploy              # deploy all stacks
  ./deploy.sh wariwari-prod ps
  ./deploy.sh observability logs observability --since 5m
  ./deploy.sh observability exec observability grafana sh
  ./deploy.sh wariwari-prod shell
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
  deploy)  cmd_deploy "$SERVER" "${3:-}" ;;
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
