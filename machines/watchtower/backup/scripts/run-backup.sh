#!/bin/sh
# Called by cron and on first start — backs up /mnt/datos to qtower via restic REST server
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
  notify "❌ **watchtower backup failed** at $(date '+%Y-%m-%d %H:%M:%S'). Check logs: \`docker logs restic-backup --tail 30\`"
  exit 1
}
trap on_error ERR

notify "🔄 **watchtower backup started** at $(date '+%Y-%m-%d %H:%M:%S')"

# --- Restic backup (remote repo on qtower) ---
log "Starting restic backup to qtower..."

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

log "All done."
notify "✅ **watchtower backup complete** at $(date '+%Y-%m-%d %H:%M:%S')"
