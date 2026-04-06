#!/bin/bash

# Monitoring Setup Script
# Installs OpenTelemetry Collector Contrib (otelcol-contrib)
# Ships metrics, logs, and traces to self-hosted SigNoz
#
# Run standalone:
#   SIGNOZ_ENDPOINT=http://signoz:4317 \
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

# Fall back to existing otelcol environment (from previous install)
OTELCOL_ENV="/etc/otelcol-contrib/environment"
if [[ -f "$OTELCOL_ENV" ]]; then
  source "$OTELCOL_ENV"
fi

# Legacy: fall back to Alloy environment for migration
ALLOY_ENV="/etc/alloy/environment"
if [[ -f "$ALLOY_ENV" ]]; then
  source "$ALLOY_ENV"
fi

[[ -n "${SIGNOZ_ENDPOINT:-}" ]] || error "SIGNOZ_ENDPOINT is required (e.g. http://signoz:4317)"

HAS_POSTGRES=false
if [[ -n "${POSTGRES_DSN:-}" ]]; then
  HAS_POSTGRES=true
  info "PostgreSQL DSN found — will enable postgresql receiver"
fi

HAS_ELASTICSEARCH=false
if [[ -n "${ELASTICSEARCH_URL:-}" ]]; then
  HAS_ELASTICSEARCH=true
  info "Elasticsearch URL found — will enable elasticsearch receiver"
fi

# --- Uninstall Grafana Alloy (if present) ---
if systemctl is-active --quiet alloy 2>/dev/null; then
  info "Stopping and removing Grafana Alloy..."
  systemctl stop alloy
  systemctl disable alloy
  apt-get remove -y alloy 2>/dev/null || true
  rm -rf /etc/alloy
  rm -rf /etc/systemd/system/alloy.service.d
  success "Alloy removed"
fi

# Remove legacy elasticsearch-exporter container (otelcol-contrib handles this natively)
if docker ps -a --format '{{.Names}}' | grep -q '^elasticsearch-exporter$'; then
  info "Removing legacy elasticsearch-exporter container..."
  docker rm -f elasticsearch-exporter 2>/dev/null || true
  success "elasticsearch-exporter removed"
fi

# --- Install otelcol-contrib ---
info "Installing OpenTelemetry Collector Contrib..."

OTELCOL_VERSION="0.120.0"
ARCH=$(dpkg --print-architecture)

curl -fsSL "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTELCOL_VERSION}/otelcol-contrib_${OTELCOL_VERSION}_linux_${ARCH}.deb" \
  -o /tmp/otelcol-contrib.deb
dpkg -i /tmp/otelcol-contrib.deb
rm -f /tmp/otelcol-contrib.deb

# --- Configure otelcol-contrib ---
info "Configuring otelcol-contrib..."

mkdir -p /etc/otelcol-contrib

cat > /etc/otelcol-contrib/config.yaml <<'OTELCOL_CONFIG'
receivers:
  # --- Host metrics (replaces node_exporter) ---
  hostmetrics:
    collection_interval: 60s
    root_path: /
    scrapers:
      cpu: {}
      disk: {}
      load: {}
      filesystem: {}
      memory: {}
      network: {}
      paging: {}
      process:
        mute_process_name_error: true
        mute_process_exe_error: true
        mute_process_io_error: true
        mute_process_user_error: true
        mute_process_cgroup_error: true
      processes: {}

  # --- Docker container metrics ---
  docker_stats:
    endpoint: unix:///var/run/docker.sock
    collection_interval: 60s
    api_version: "1.43"
    metrics:
      container.cpu.utilization:
        enabled: true
      container.memory.percent:
        enabled: true
      container.memory.usage.total:
        enabled: true
      container.memory.usage.limit:
        enabled: true
      container.network.io.usage.rx_bytes:
        enabled: true
      container.network.io.usage.tx_bytes:
        enabled: true
      container.blockio.io_service_bytes_recursive:
        enabled: true

  # --- Docker container logs ---
  filelog/docker:
    include: [/var/lib/docker/containers/*/*-json.log]
    start_at: end
    include_file_name: false
    include_file_path: true
    # Exclude noisy low-value containers by container ID directory
    # (Filtering by name happens after parsing via the filter processor below)
    operators:
      - id: container-parser
        type: container
        format: docker
        add_metadata_from_filepath: false
      # Tag log source
      - type: add
        field: attributes.log.source
        value: docker
      # Extract container name from Docker log tag (set via daemon.json tag option)
      - type: move
        if: attributes.attrs.tag != nil
        from: attributes.attrs.tag
        to: attributes["container.name"]
      # Detect environment from container name (-prod or -dev suffix)
      - type: add
        if: attributes["container.name"] != nil and attributes["container.name"] matches "-prod"
        field: attributes["deployment.environment"]
        value: production
      - type: add
        if: attributes["container.name"] != nil and attributes["container.name"] matches "-dev"
        field: attributes["deployment.environment"]
        value: development
      - type: add
        if: attributes["deployment.environment"] == nil
        field: attributes["deployment.environment"]
        value: infrastructure
      # Parse structured JSON logs (e.g. from Pino, Winston, etc.)
      - id: json-parser
        type: json_parser
        if: body matches "^\\{"
        parse_from: body
        parse_to: attributes
      # Map common log fields to OTel semantic conventions
      - id: severity-parser
        type: severity_parser
        if: attributes.level != nil
        parse_from: attributes.level
        mapping:
          trace: [trace, "10"]
          debug: [debug, "20"]
          info: [info, "30"]
          warn: [warn, "40"]
          error: [error, "50"]
          fatal: [fatal, "60"]

  # --- System logs (journald) ---
  journald:
    directory: /var/log/journal
    start_at: end
    operators:
      - type: add
        field: attributes.log.source
        value: journald

  # --- OTLP receiver (for instrumented apps) ---
  # Uses non-standard ports to avoid conflicts with SigNoz's otel-collector on the monitoring server
  otlp:
    protocols:
      grpc:
        endpoint: 127.0.0.1:4327
      http:
        endpoint: 127.0.0.1:4328

OTELCOL_CONFIG

# --- Optional: PostgreSQL receiver ---
if $HAS_POSTGRES; then
cat >> /etc/otelcol-contrib/config.yaml <<'OTELCOL_POSTGRES'
  # --- PostgreSQL metrics ---
  postgresql:
    endpoint: ${env:POSTGRES_HOST}
    transport: tcp
    username: ${env:POSTGRES_USER}
    password: ${env:POSTGRES_PASSWORD}
    databases:
      - ${env:POSTGRES_DB}
    collection_interval: 60s
    tls:
      insecure: true

OTELCOL_POSTGRES
fi

# --- Optional: Elasticsearch receiver ---
if $HAS_ELASTICSEARCH; then
cat >> /etc/otelcol-contrib/config.yaml <<'OTELCOL_ELASTICSEARCH'
  # --- Elasticsearch metrics ---
  elasticsearch:
    endpoint: ${env:ELASTICSEARCH_URL}
    collection_interval: 60s
    nodes: ["_local"]
    skip_cluster_metrics: false

OTELCOL_ELASTICSEARCH
fi

# --- Processors, exporters, service ---
cat >> /etc/otelcol-contrib/config.yaml <<'OTELCOL_SERVICE'
processors:
  memory_limiter:
    check_interval: 5s
    limit_mib: 512
    spike_limit_mib: 128
  batch:
    send_batch_size: 1000
    send_batch_max_size: 2048
    timeout: 10s
  resourcedetection:
    detectors: [env, system, docker]
    timeout: 2s
    system:
      hostname_sources: [os]
  # Drop logs from noisy low-value containers
  filter/drop_noisy:
    error_mode: ignore
    logs:
      log_record:
        - 'attributes["container.name"] != nil and IsMatch(attributes["container.name"], "^(signoz-|.*redis.*|.*cloudflare.*|adminer|pgadmin|autokuma)")'

exporters:
  otlp:
    endpoint: ${env:SIGNOZ_ENDPOINT}
    tls:
      insecure: true
    compression: gzip
    sending_queue:
      enabled: true
      num_consumers: 10
      queue_size: 5000
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 30s
      max_elapsed_time: 300s

service:
  telemetry:
    logs:
      encoding: json
  pipelines:
    metrics:
      receivers: [otlp, hostmetrics, docker_stats]
      processors: [memory_limiter, resourcedetection, batch]
      exporters: [otlp]
    traces:
      receivers: [otlp]
      processors: [memory_limiter, resourcedetection, batch]
      exporters: [otlp]
    logs:
      receivers: [otlp, filelog/docker, journald]
      processors: [memory_limiter, resourcedetection, filter/drop_noisy, batch]
      exporters: [otlp]
OTELCOL_SERVICE

# Add optional receivers to metrics pipeline
if $HAS_POSTGRES; then
  sed -i 's/receivers: \[otlp, hostmetrics, docker_stats\]/receivers: [otlp, hostmetrics, docker_stats, postgresql]/' /etc/otelcol-contrib/config.yaml
fi

if $HAS_ELASTICSEARCH; then
  sed -i 's/receivers: \[otlp, hostmetrics, docker_stats\]/receivers: [otlp, hostmetrics, docker_stats, elasticsearch]/' /etc/otelcol-contrib/config.yaml
  # Handle case where postgresql was already added
  sed -i 's/receivers: \[otlp, hostmetrics, docker_stats, postgresql\]/receivers: [otlp, hostmetrics, docker_stats, postgresql, elasticsearch]/' /etc/otelcol-contrib/config.yaml
fi

# --- Configure environment ---
info "Setting up otelcol-contrib environment..."

cat > /etc/otelcol-contrib/environment <<EOF
SIGNOZ_ENDPOINT=${SIGNOZ_ENDPOINT}
EOF

if $HAS_POSTGRES; then
  # Parse: postgresql://user:pass@host:port/dbname?params
  POSTGRES_USER=$(echo "$POSTGRES_DSN" | sed -n 's|postgresql://\([^:]*\):.*|\1|p')
  POSTGRES_PASSWORD=$(echo "$POSTGRES_DSN" | sed -n 's|postgresql://[^:]*:\([^@]*\)@.*|\1|p')
  POSTGRES_HOST=$(echo "$POSTGRES_DSN" | sed -n 's|postgresql://[^@]*@\(.*\)/[^/]*$|\1|p')
  POSTGRES_DB=$(echo "$POSTGRES_DSN" | sed -n 's|postgresql://[^/]*/\([^?]*\).*|\1|p')
  cat >> /etc/otelcol-contrib/environment <<EOF
POSTGRES_DSN=${POSTGRES_DSN}
POSTGRES_USER=${POSTGRES_USER}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_HOST=${POSTGRES_HOST}
POSTGRES_DB=${POSTGRES_DB}
EOF
fi

if $HAS_ELASTICSEARCH; then
  cat >> /etc/otelcol-contrib/environment <<EOF
ELASTICSEARCH_URL=${ELASTICSEARCH_URL}
EOF
fi

chmod 600 /etc/otelcol-contrib/environment

# Make systemd load the environment file
mkdir -p /etc/systemd/system/otelcol-contrib.service.d
cat > /etc/systemd/system/otelcol-contrib.service.d/override.conf <<EOF
[Service]
EnvironmentFile=/etc/otelcol-contrib/environment
EOF

# otelcol-contrib needs Docker socket + journal access
usermod -aG docker otelcol-contrib 2>/dev/null || true
usermod -aG systemd-journal otelcol-contrib 2>/dev/null || true

# --- Start otelcol-contrib ---
info "Starting otelcol-contrib..."
systemctl daemon-reload
systemctl enable otelcol-contrib
systemctl restart otelcol-contrib

# --- Verify ---
info "Verifying otelcol-contrib..."
sleep 3
if systemctl is-active --quiet otelcol-contrib; then
  success "otelcol-contrib is running"
else
  error "otelcol-contrib failed to start. Check: journalctl -u otelcol-contrib"
fi

# --- Install postgresqltuner (if PostgreSQL is present) ---
if $HAS_POSTGRES; then
  info "Installing postgresqltuner..."
  apt-get install -y perl libdbi-perl libdbd-pg-perl
  curl -fsSL https://raw.githubusercontent.com/jfcoz/postgresqltuner/master/postgresqltuner.pl \
    -o /usr/local/bin/postgresqltuner.pl
  chmod +x /usr/local/bin/postgresqltuner.pl

  # Wrapper that reads POSTGRES_DSN from otelcol environment
  cat > /usr/local/bin/postgresqltuner <<'WRAPPER'
#!/bin/bash
set -euo pipefail
source /etc/otelcol-contrib/environment
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

success "Monitoring setup complete! All telemetry shipping to SigNoz."
