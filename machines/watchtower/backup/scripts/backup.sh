#!/bin/sh
set -e

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

# Initialize repo if it doesn't exist
log "Checking restic repository..."
restic snapshots >/dev/null 2>&1 || {
  log "Initializing restic repository..."
  restic init
}

# Run once immediately on first start
log "Starting initial backup..."
/scripts/run-backup.sh

# Export env vars so cron jobs can access them
env > /etc/environment

# Install cron job
log "Scheduling backups with cron: ${BACKUP_CRON}"
CRON_LINE="${BACKUP_CRON} . /etc/environment; /scripts/run-backup.sh >> /var/log/backup.log 2>&1"
echo "$CRON_LINE" | crontab -

# Keep container running
log "Backup daemon running. Waiting for next scheduled run..."
crond -f -l 2
