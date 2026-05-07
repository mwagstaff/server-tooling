#!/usr/bin/env bash
set -euo pipefail

# MongoDB backup script — run via cron on the server
# Cron entry (daily at 3am):
#   0 3 * * * /home/mwagstaff/dev/kidventures/infrastructure/mongo/backup.sh

CONTAINER="mongo-kidventures"
BACKUP_DIR="/backups/kidventures"
KEEP_DAYS=30

mkdir -p "${BACKUP_DIR}"

FILENAME="${BACKUP_DIR}/$(date +%Y%m%d-%H%M%S).gz"
sudo docker exec "${CONTAINER}" mongodump --archive --gzip --db kidventures | gzip > "${FILENAME}"
echo "Backup written: ${FILENAME} ($(du -sh "${FILENAME}" | cut -f1))"

# Prune old backups
find "${BACKUP_DIR}" -name "*.gz" -mtime "+${KEEP_DAYS}" -delete
echo "Pruned backups older than ${KEEP_DAYS} days"
