#!/bin/bash

# Monitoring Setup Script
# Installs Grafana Alloy with built-in node exporter metrics
# Ships metrics and Docker logs to self-hosted Prometheus/Loki
#
# Run standalone:
#   PROMETHEUS_REMOTE_WRITE_URL=http://prometheus:9090/api/v1/write \
#   LOKI_URL=http://loki:3100/loki/api/v1/push \
#   bash setup-monitoring.sh
#
# Or via cloud-init (secrets loaded from /run/setup-secrets)

set -euo pipefail

# --- Colors ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()    { echo -e "${YELLOW}=> $1${NC}"; }
success() { echo -e "${GREEN}=> $1${NC}"; }
error()   { echo -e "${RED}=> ERROR: $1${NC}" >&2; exit 1; }

# --- Pre-flight ---
[[ $EUID -eq 0 ]] || error "Must run as root"

# Load secrets from tmpfs if available
SECRETS_FILE="/run/setup-secrets"
if [[ -f "$SECRETS_FILE" ]]; then
  source "$SECRETS_FILE"
fi

[[ -n "${PROMETHEUS_REMOTE_WRITE_URL:-}" ]] || error "PROMETHEUS_REMOTE_WRITE_URL is required"
[[ -n "${LOKI_URL:-}" ]] || error "LOKI_URL is required"

# --- Install Alloy ---
info "Installing Grafana Alloy..."

apt-get install -y gpg
mkdir -p /etc/apt/keyrings/
curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor -o /etc/apt/keyrings/grafana.gpg
chmod 644 /etc/apt/keyrings/grafana.gpg
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
  > /etc/apt/sources.list.d/grafana.list
apt-get update
apt-get install -y alloy

# --- Configure Alloy ---
info "Configuring Alloy..."

cat > /etc/alloy/config.alloy <<'ALLOY_CONFIG'
// --- Node metrics (built-in node exporter) ---
prometheus.exporter.unix "node" {}

prometheus.scrape "node" {
  targets    = prometheus.exporter.unix.node.targets
  forward_to = [prometheus.remote_write.default.receiver]

  scrape_interval = "60s"
}

// --- Docker container metrics ---
prometheus.scrape "docker" {
  targets = [{
    __address__ = "127.0.0.1:9323",
  }]
  forward_to = [prometheus.remote_write.default.receiver]

  scrape_interval = "60s"
}

// --- Ship metrics to Prometheus ---
prometheus.remote_write "default" {
  endpoint {
    url = sys.env("PROMETHEUS_REMOTE_WRITE_URL")
  }

  external_labels = {
    instance = constants.hostname,
  }
}

// --- Docker container logs ---
local.file_match "docker_logs" {
  path_targets = [{
    __path__ = "/var/lib/docker/containers/*/*-json.log",
  }]
}

loki.source.file "docker_logs" {
  targets    = local.file_match.docker_logs.targets
  forward_to = [loki.process.docker_logs.receiver]
}

loki.process "docker_logs" {
  stage.json {
    expressions = {
      log    = "log",
      stream = "stream",
      time   = "time",
    }
  }

  stage.output {
    source = "log"
  }

  stage.labels {
    values = {
      stream = "stream",
    }
  }

  stage.timestamp {
    source = "time"
    format = "RFC3339Nano"
  }

  forward_to = [loki.write.default.receiver]
}

// --- System logs (auth, syslog) ---
local.file_match "system_logs" {
  path_targets = [{
    __path__ = "/var/log/auth.log",
    job       = "auth",
  }, {
    __path__ = "/var/log/syslog",
    job       = "syslog",
  }]
}

loki.source.file "system_logs" {
  targets    = local.file_match.system_logs.targets
  forward_to = [loki.write.default.receiver]
}

// --- Audit logs ---
local.file_match "audit_logs" {
  path_targets = [{
    __path__ = "/var/log/audit/audit.log",
    job       = "audit",
  }]
}

loki.source.file "audit_logs" {
  targets    = local.file_match.audit_logs.targets
  forward_to = [loki.write.default.receiver]
}

// --- Ship logs to Loki ---
loki.write "default" {
  endpoint {
    url = sys.env("LOKI_URL")
  }

  external_labels = {
    instance = constants.hostname,
  }
}
ALLOY_CONFIG

# --- Configure Alloy environment ---
info "Setting up Alloy environment..."

mkdir -p /etc/alloy
cat > /etc/alloy/environment <<EOF
PROMETHEUS_REMOTE_WRITE_URL=${PROMETHEUS_REMOTE_WRITE_URL}
LOKI_URL=${LOKI_URL}
EOF
chmod 600 /etc/alloy/environment

# Make systemd load the environment file
mkdir -p /etc/systemd/system/alloy.service.d
cat > /etc/systemd/system/alloy.service.d/override.conf <<EOF
[Service]
EnvironmentFile=/etc/alloy/environment
EOF

# Alloy needs access to Docker logs
usermod -aG docker alloy 2>/dev/null || true

# --- Start Alloy ---
info "Starting Alloy..."
systemctl daemon-reload
systemctl enable alloy
systemctl restart alloy

# --- Verify ---
info "Verifying Alloy..."
sleep 3
if systemctl is-active --quiet alloy; then
  success "Alloy is running"
else
  error "Alloy failed to start. Check: journalctl -u alloy"
fi

success "Monitoring setup complete! Metrics and logs shipping to Prometheus/Loki."
