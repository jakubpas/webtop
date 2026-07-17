#!/bin/bash
# Backs up ~/webtop_data (the webtop container's persistent config/profile
# volume) to ~/backups/ as a timestamped tarball.
#
# NOTE: there's no automated/scheduled backup system on darkplanet.pl (no
# crontab for `kuba`, `~/backups` is just an ad-hoc manual dumping ground used
# before deploys). This script matches that existing manual pattern rather
# than introducing new cron automation on a shared production host - run it
# by hand whenever you want a snapshot (e.g. before a container/host change).
#
# Usage:
#   ./scripts/backup-webtop-data.sh [ssh-host]
set -euo pipefail

SSH_HOST="${1:-kuba@darkplanet.pl}"

echo "Backing up ~/webtop_data on $SSH_HOST..."

ssh "$SSH_HOST" bash -s <<'REMOTE_SCRIPT'
set -euo pipefail
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$HOME/backups/webtop_data_${TIMESTAMP}.tar.gz"
tar -czf "$BACKUP_FILE" -C "$HOME" webtop_data
echo "Backup written to: $BACKUP_FILE"
ls -lh "$BACKUP_FILE"
REMOTE_SCRIPT
