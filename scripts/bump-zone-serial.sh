#!/bin/bash
# Safely bumps the SOA serial of a BIND zone file on darkplanet.pl and reloads it.
#
# Manually editing the serial by hand is a classic BIND footgun: if the new
# value isn't strictly greater than the currently loaded one, `rndc reload`
# silently keeps serving the old zone data. This script reads the current
# serial remotely, computes a correct next value (today's date + a 2-digit
# counter, per the usual YYYYMMDDnn convention), and only then edits + reloads.
#
# Usage:
#   ./scripts/bump-zone-serial.sh [zone-name] [zone-file-path] [ssh-host]
#
# Defaults match this project's use case:
#   zone-name:      darkplanet.pl
#   zone-file-path: /etc/bind/zones/darkplanet.pl
#   ssh-host:       kuba@darkplanet.pl
set -euo pipefail

ZONE_NAME="${1:-darkplanet.pl}"
ZONE_FILE="${2:-/etc/bind/zones/darkplanet.pl}"
SSH_HOST="${3:-kuba@darkplanet.pl}"

echo "Bumping SOA serial for zone '$ZONE_NAME' ($ZONE_FILE) on $SSH_HOST..."

# shellcheck disable=SC2087
ssh "$SSH_HOST" bash -s -- "$ZONE_NAME" "$ZONE_FILE" <<'REMOTE_SCRIPT'
set -euo pipefail
ZONE_NAME="$1"
ZONE_FILE="$2"

CURRENT_SERIAL=$(grep -oE '[0-9]{10}[[:space:]]*;;[[:space:]]*serial' "$ZONE_FILE" | grep -oE '^[0-9]{10}')
if [[ -z "$CURRENT_SERIAL" ]]; then
  echo "ERROR: could not find a 10-digit SOA serial in $ZONE_FILE" >&2
  exit 1
fi

TODAY=$(date +%Y%m%d)
CURRENT_DATE_PART="${CURRENT_SERIAL:0:8}"
CURRENT_COUNTER="${CURRENT_SERIAL:8:2}"

if [[ "$CURRENT_DATE_PART" == "$TODAY" ]]; then
  # Already bumped today — increment the 2-digit counter.
  NEXT_COUNTER=$(printf "%02d" $((10#$CURRENT_COUNTER + 1)))
  NEW_SERIAL="${TODAY}${NEXT_COUNTER}"
else
  NEW_SERIAL="${TODAY}01"
fi

# Guard: RFC1912 requires the new serial to be strictly greater than the old
# one, regardless of the date-based scheme above (e.g. if the clock is behind,
# or the zone already has a serial from "the future"). Fall back to a simple
# numeric increment if needed.
if [[ "$NEW_SERIAL" -le "$CURRENT_SERIAL" ]]; then
  NEW_SERIAL=$((CURRENT_SERIAL + 1))
fi

echo "Current serial: $CURRENT_SERIAL -> New serial: $NEW_SERIAL"

sudo cp "$ZONE_FILE" "$ZONE_FILE.bak.$(date +%Y%m%d%H%M%S)"
sudo sed -i "s/${CURRENT_SERIAL} ;; serial/${NEW_SERIAL} ;; serial/" "$ZONE_FILE"

echo "Validating zone syntax..."
sudo named-checkzone "$ZONE_NAME" "$ZONE_FILE"

echo "Reloading zone..."
sudo rndc reload "$ZONE_NAME"

echo "Done. New serial: $NEW_SERIAL"
REMOTE_SCRIPT
