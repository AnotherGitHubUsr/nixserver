#!/usr/bin/env bash
# monitoring-periodic-8h.sh — freshclam, crowdsec reload, SMART sample, sensors, journal, nft, sizes.
set -euo pipefail
LOGDIR="/srv/nixserver/state/monitoring/periodic-8h"
mkdir -p "$LOGDIR"
if [[ -e /dev/disk/by-label/detritus ]]; then hdparm -W 1 /dev/disk/by-label/detritus >/dev/null 2>&1 || true; fi
freshclam | tee -a "$LOGDIR/clamav-update.log" || true
systemctl reload crowdsec >/dev/null 2>&1 || true
echo "Crowdsec DB updated $(date)" >>"$LOGDIR/crowdsec-update.log"
if [[ -e /dev/disk/by-label/detritus ]]; then smartctl -a /dev/disk/by-label/detritus | tee -a "$LOGDIR/detritus-smart.log" || true; fi
echo "===== $(date '+%F %T') =====" >>"$LOGDIR/lmsensors.log"
sensors >>"$LOGDIR/lmsensors.log" 2>/dev/null || true
echo "===== $(date '+%F %T') =====" >>"$LOGDIR/journal-errors.log"
journalctl --since "-8h" | grep -i error >>"$LOGDIR/journal-errors.log" || true
echo "===== $(date '+%F %T') =====" >>"$LOGDIR/firewall.log"
nft list ruleset >>"$LOGDIR/firewall.log" 2>/dev/null || true
echo "===== $(date '+%F %T') =====" >>"$LOGDIR/logsizes.log"
ls -lh "$LOGDIR" >>"$LOGDIR/logsizes.log" || true
