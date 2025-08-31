#!/usr/bin/env bash
# monitoring-onhours-check.sh — threshold actions based on on-hours since setup.
set -euo pipefail
ROOTDEV="/dev/disk/by-label/weatherwax"
BASEFILE="/srv/nixserver/state/monitoring/onhours-base.txt"
STATEFILE="/srv/nixserver/state/monitoring/onhours-state.txt"
LOGDIR="/srv/nixserver/state/monitoring/onhours-logs"
mkdir -p "$LOGDIR"
if [[ -s /srv/nixserver/state/monitoring/counters.json ]]; then
  CUR_MIN="$(jq -r '.on_minutes // 0' /srv/nixserver/state/monitoring/counters.json)"
  CUR=$((CUR_MIN / 60))
else CUR="$(smartctl -A "$ROOTDEV" | awk '/Power_On_Hours/ {print $10}')" || CUR=0; fi
[[ "$CUR" =~ ^[0-9]+$ ]] || CUR=0
if [[ ! -f "$BASEFILE" ]]; then echo "$CUR" >"$BASEFILE"; fi
BASE="$(cat "$BASEFILE")"
[[ "$BASE" =~ ^[0-9]+$ ]] || BASE=0
DELTA=$((CUR - BASE))
((DELTA < 0)) && DELTA=0
{
  echo "On-hours since setup: $DELTA"
  date
} >"$STATEFILE"
if ((DELTA > 0 && DELTA % 950 == 0)); then if command -v systemd-run >/dev/null 2>&1; then systemd-run --unit="bcachefs-verify-reads-scheduled" --on-calendar="03:00" --timer-property=Persistent=true "/srv/nixserver/config/tools/monitoring/bcachefs-verify-reads.sh"; fi; fi
if ((DELTA > 0 && DELTA % 2000 == 0)); then for d in /dev/sd? /dev/nvme?n?; do
  [[ -b "$d" ]] || continue
  smartctl -t long "$d" || true
done; fi
