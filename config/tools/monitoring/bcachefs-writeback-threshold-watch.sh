#!/usr/bin/env bash
# bcachefs-writeback-threshold-watch.sh — open flush window when dirty bytes exceed limit.
set -euo pipefail
LIMIT_BYTES="${BCACHEFS_DIRTY_LIMIT:-161061273600}"
FLUSH_BYTES="${BCACHEFS_MOVE_BYTES_FLUSH:-268435456}"
WINDOW_SEC="${BCACHEFS_FLUSH_WINDOW_SECONDS:-7200}"
dirty_bytes() {
  local total=0 v
  for f in /sys/fs/bcachefs/*/internal/dirty_data; do
    [[ -f "$f" ]] || continue
    v="$(awk '{print $1}' "$f" 2>/dev/null || echo 0)"
    total=$((total + v))
  done
  if ((total == 0)); then for f in /sys/fs/bcachefs/*/writeback_dirty; do
    [[ -f "$f" ]] || continue
    v="$(awk '{print $1}' "$f" 2>/dev/null || echo 0)"
    total=$((total + v))
  done; fi
  if ((total == 0)); then
    local sum=0
    while read -r mnt; do
      out="$(bcachefs fs usage --bytes "$mnt" 2>/dev/null || true)"
      b="$(echo "$out" | grep -Eo 'cached data[^0-9]*([0-9]+)' | awk '{print $NF}' | head -n1)"
      [[ -n "$b" ]] || b=0
      sum=$((sum + b))
    done < <(findmnt -rn -t bcachefs -o TARGET | sort -u)
    echo "$sum"
  else echo "$total"; fi
}
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
d="$(dirty_bytes)"
if ((d < LIMIT_BYTES)); then
  writeback_set 0
  echo "below threshold: $d < $LIMIT_BYTES"
  exit 0
fi
echo "threshold exceeded: $d >= $LIMIT_BYTES"
writeback_set "$FLUSH_BYTES"
echo "Flush window open for ${WINDOW_SEC}s..."
sleep "$WINDOW_SEC"
writeback_set 0
echo "flush window closed."
