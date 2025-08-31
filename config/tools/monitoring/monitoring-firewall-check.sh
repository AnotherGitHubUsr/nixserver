#!/usr/bin/env bash
# monitoring-firewall-check.sh — nft ruleset snapshot to log.
set -euo pipefail
mkdir -p /srv/nixserver/state/monitoring/logs
{
  echo "===== $(date '+%F %T') ====="
  nft list ruleset || true
} >>/srv/nixserver/state/monitoring/logs/firewall.check
