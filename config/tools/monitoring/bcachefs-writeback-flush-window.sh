#!/usr/bin/env bash
# bcachefs-writeback-flush-window.sh — manual flush window helper.
set -euo pipefail
FLUSH_BYTES="${1:-${BCACHEFS_MOVE_BYTES_FLUSH:-268435456}}"
WINDOW_SEC="${2:-${BCACHEFS_FLUSH_WINDOW_SECONDS:-7200}}"
writeback_set() {
  local bytes="${1:-0}"
  local found=0
  for opt in /sys/fs/bcachefs/*/options/move_bytes_in_flight; do
    [[ -f "$opt" ]] || continue
    echo "$bytes" >"$opt"
    found=1
    echo "set $(basename "$(dirname "$(dirname "$opt")")") move_bytes_in_flight=$bytes"
  done
  ((found == 1)) || echo "No bcachefs options found under /sys/fs/bcachefs"
}
writeback_set "$FLUSH_BYTES"
echo "Flush window open (${WINDOW_SEC}s, bytes_in_flight=$FLUSH_BYTES)"
sleep "$WINDOW_SEC"
writeback_set 0
echo "flush window closed."
