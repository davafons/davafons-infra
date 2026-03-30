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

# Fall back to existing Alloy environment (from previous install)
ALLOY_ENV="/etc/alloy/environment"
if [[ -f "$ALLOY_ENV" ]]; then
  source "$ALLOY_ENV"
fi

[[ -n "${PROMETHEUS_REMOTE_WRITE_URL:-}" ]] || error "PROMETHEUS_REMOTE_WRITE_URL is required"
[[ -n "${LOKI_URL:-}" ]] || error "LOKI_URL is required"

HAS_POSTGRES=false
if [[ -n "${POSTGRES_DSN:-}" ]]; then
  HAS_POSTGRES=true
  info "PostgreSQL DSN found — will enable postgres exporter"
fi

HAS_ELASTICSEARCH=false
if [[ -n "${ELASTICSEARCH_URL:-}" ]]; then
  HAS_ELASTICSEARCH=true
  info "Elasticsearch URL found — will enable elasticsearch exporter"
fi

# --- Install Alloy ---
info "Installing Grafana Alloy..."

apt-get install -y gpg
mkdir -p /etc/apt/keyrings/
curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/grafana.gpg
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

// --- PostgreSQL metrics (enabled when POSTGRES_DSN is set) ---
ALLOY_CONFIG

if $HAS_POSTGRES; then
cat >> /etc/alloy/config.alloy <<'ALLOY_POSTGRES'
prometheus.exporter.postgres "default" {
  data_source_names = [sys.env("POSTGRES_DSN")]

  enabled_collectors = ["stat_statements"]
}

discovery.relabel "postgres" {
  targets = prometheus.exporter.postgres.default.targets

  rule {
    target_label = "instance"
    replacement  = constants.hostname
  }
}

prometheus.scrape "postgres" {
  targets    = discovery.relabel.postgres.output
  forward_to = [prometheus.remote_write.default.receiver]

  scrape_interval = "60s"
}
ALLOY_POSTGRES
fi

if $HAS_ELASTICSEARCH; then
cat >> /etc/alloy/config.alloy <<'ALLOY_ELASTICSEARCH'
// --- Elasticsearch metrics (via elasticsearch_exporter sidecar) ---
prometheus.scrape "elasticsearch" {
  targets = [{
    __address__ = "127.0.0.1:9114",
  }]
  forward_to = [prometheus.remote_write.default.receiver]

  scrape_interval = "60s"
}
ALLOY_ELASTICSEARCH
fi

cat >> /etc/alloy/config.alloy <<'ALLOY_CONFIG'
// --- Ship metrics to Prometheus ---
prometheus.remote_write "default" {
  endpoint {
    url = sys.env("PROMETHEUS_REMOTE_WRITE_URL")
  }

  external_labels = {
    instance = constants.hostname,
  }
}

// --- Docker container logs (via Docker API) ---
discovery.docker "containers" {
  host = "unix:///var/run/docker.sock"
}

discovery.relabel "docker_containers" {
  targets = discovery.docker.containers.targets

  rule {
    source_labels = ["__meta_docker_container_name"]
    target_label  = "container"
  }
}

loki.source.docker "docker_logs" {
  host       = "unix:///var/run/docker.sock"
  targets    = discovery.relabel.docker_containers.output
  forward_to = [loki.process.docker_logs.receiver]
}

loki.process "docker_logs" {
  stage.docker {}

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

if $HAS_POSTGRES; then
  cat >> /etc/alloy/environment <<EOF
POSTGRES_DSN=${POSTGRES_DSN}
EOF
fi

if $HAS_ELASTICSEARCH; then
  cat >> /etc/alloy/environment <<EOF
ELASTICSEARCH_URL=${ELASTICSEARCH_URL}
EOF
fi
chmod 600 /etc/alloy/environment

# Make systemd load the environment file
mkdir -p /etc/systemd/system/alloy.service.d
cat > /etc/systemd/system/alloy.service.d/override.conf <<EOF
[Service]
EnvironmentFile=/etc/alloy/environment
EOF

# Alloy needs Docker socket access for container log collection
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

# --- Start elasticsearch_exporter (if Elasticsearch is present) ---
if $HAS_ELASTICSEARCH; then
  info "Starting elasticsearch_exporter..."

  docker rm -f elasticsearch-exporter 2>/dev/null || true
  docker run -d \
    --name elasticsearch-exporter \
    --restart unless-stopped \
    --network host \
    --memory 64m \
    quay.io/prometheuscommunity/elasticsearch-exporter:v1.8.0 \
      --es.uri="${ELASTICSEARCH_URL}" \
      --es.all \
      --es.indices \
      --es.shards \
      --web.listen-address=127.0.0.1:9114

  success "elasticsearch_exporter running on :9114"
fi

# --- Install postgresqltuner (if PostgreSQL is present) ---
if $HAS_POSTGRES; then
  info "Installing postgresqltuner..."
  apt-get install -y perl libdbi-perl libdbd-pg-perl
  curl -fsSL https://raw.githubusercontent.com/jfcoz/postgresqltuner/master/postgresqltuner.pl \
    -o /usr/local/bin/postgresqltuner.pl
  chmod +x /usr/local/bin/postgresqltuner.pl

  # Wrapper that reads POSTGRES_DSN from Alloy environment
  cat > /usr/local/bin/postgresqltuner <<'WRAPPER'
#!/bin/bash
set -euo pipefail
source /etc/alloy/environment
# Parse: postgresql://user:pass@host:port/dbname?params
PGUSER=$(echo "$POSTGRES_DSN" | sed -n 's|postgresql://\([^:]*\):.*|\1|p')
PGPASS=$(echo "$POSTGRES_DSN" | sed -n 's|postgresql://[^:]*:\([^@]*\)@.*|\1|p')
PGHOST=$(echo "$POSTGRES_DSN" | sed -n 's|postgresql://[^@]*@\([^:]*\):.*|\1|p')
PGPORT=$(echo "$POSTGRES_DSN" | sed -n 's|postgresql://[^@]*@[^:]*:\([^/]*\)/.*|\1|p')
PGDB=$(echo "$POSTGRES_DSN" | sed -n 's|postgresql://[^/]*/\([^?]*\).*|\1|p')
exec postgresqltuner.pl --host="$PGHOST" --port="$PGPORT" --user="$PGUSER" --password="$PGPASS" --database="$PGDB" "$@"
WRAPPER
  chmod +x /usr/local/bin/postgresqltuner

  success "postgresqltuner installed — run: postgresqltuner"
fi

success "Monitoring setup complete! Metrics and logs shipping to Prometheus/Loki."
