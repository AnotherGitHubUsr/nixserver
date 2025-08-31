#!/usr/bin/env bash
# monitoring-monday-smart.sh — weekly SMART short tests and quick ClamAV sweep.
set -euo pipefail
LOGDIR="/srv/nixserver/state/monitoring/monday-10-30"
mkdir -p "$LOGDIR"
ALL_BLOCKS="$(lsblk -dn -o NAME | grep -E '^(sd|nvme|vd|xvd|hd)')" || true
for d in $ALL_BLOCKS; do
  DEV="/dev/$d"
  [[ -b "$DEV" ]] || continue
  hdparm -W 1 "$DEV" >/dev/null 2>&1 || true
  sleep 1
  smartctl -n standby -t short "$DEV" || true
  echo "SMART short test triggered for $DEV at $(date)" >>"$LOGDIR/smart-monday.log"
  smartctl -a "$DEV" >>"$LOGDIR/smart-$d.log" || true
done
find / \( -path /proc -o -path /sys -o -path /dev -o -path /run -o -path /nix/store \) -prune -o \
  -type f \( -iname '*.exe' -o -iname '*.dll' -o -iname '*.scr' -o -iname '*.bat' -o -iname '*.doc' -o -iname '*.docx' -o -iname '*.xls' -o -iname '*.xlsx' -o -iname '*.js' -o -iname '*.ps1' \) \
  -exec clamscan --infected --no-summary {} + 2>/dev/null | tee -a "$LOGDIR/clamav-monday-infected.log"
