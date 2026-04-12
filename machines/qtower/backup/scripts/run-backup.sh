#!/bin/sh
# Called by cron and on first start — dumps databases, runs restic backup, syncs to S3
set -e

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

notify() {
  local message="$1"
  if [ -n "$DISCORD_WEBHOOK" ]; then
    curl -sf -H "Content-Type: application/json" \
      -d "{\"content\": \"$message\"}" \
      "$DISCORD_WEBHOOK" >/dev/null 2>&1 || true
  fi
}

# Trap errors and notify on failure
on_error() {
  log "Backup FAILED"
  notify "❌ **qtower backup failed** at $(date '+%Y-%m-%d %H:%M:%S'). Check logs: \`docker logs restic-backup --tail 30\`"
  exit 1
}
trap on_error ERR

notify "🔄 **qtower backup started** at $(date '+%Y-%m-%d %H:%M:%S')"

# --- Database dumps ---
log "Starting database dumps..."
mkdir -p /data/db-dumps

if docker inspect immich_postgres >/dev/null 2>&1; then
  log "Dumping immich..."
  pg_user=$(docker exec immich_postgres sh -c 'echo $POSTGRES_USER')
  docker exec immich_postgres pg_dumpall -U "$pg_user" > /data/db-dumps/immich.sql
  log "Dump complete: $(du -h /data/db-dumps/immich.sql | cut -f1)"
else
  log "WARNING: immich_postgres not running, skipping dump"
fi

# --- Restic backup (local repo) ---
log "Starting restic backup to local repo..."

restic backup /data \
  --verbose \
  --exclude='*.tmp' \
  --exclude='*.log' \
  --exclude='__pycache__' \
  --exclude='node_modules' \
  --exclude='*.pyc' \
  --exclude='.cache'

log "Applying retention policy..."

restic forget \
  --keep-daily 7 \
  --keep-weekly 4 \
  --keep-monthly 6 \
  --prune

# --- Sync restic repo to S3 ---
log "Syncing restic repo to S3 (s3://${S3_BUCKET})..."

aws s3 sync /repo "s3://${S3_BUCKET}" --delete --storage-class DEEP_ARCHIVE

log "All done."
notify "✅ **qtower backup complete** at $(date '+%Y-%m-%d %H:%M:%S')"
