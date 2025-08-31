#!/usr/bin/env bash
# bcachefs-verify-reads.sh — warn-only scrub of all files on bcachefs mounts.
set -euo pipefail
logdir="${VERIFY_LOGDIR:-/srv/nixserver/state/monitoring/verify-reads}"
mkdir -p "$logdir"
declare -a targets=()
if (("$#")); then
  targets=("$@")
elif [[ -n "${BCACHEFS_TARGETS:-}" ]]; then
  read -r -a targets <<<"${BCACHEFS_TARGETS}"
else mapfile -t targets < <(findmnt -rn -t bcachefs -o TARGET | sort -u); fi
((${#targets[@]})) || {
  echo "bcachefs-verify-reads: no bcachefs mounts found."
  exit 0
}
for mnt in "${targets[@]}"; do
  [[ -d "$mnt" ]] || {
    echo "skip: $mnt not a directory"
    continue
  }
  esc="${mnt//[^A-Za-z0-9_.-]/_}"
  lock="/run/lock/verify-reads.${esc}.lock"
  exec 9>"$lock"
  flock -n 9 || {
    echo "verify already running for $mnt"
    continue
  }
  src="$(findmnt -nro SOURCE "$mnt")"
  [[ -n "$src" ]] || {
    echo "skip: cannot resolve source for $mnt"
    continue
  }
  start="$(date -Is)"
  if ! mount -o remount,ro,nochanges "$mnt" 2>/dev/null; then
    umount "$mnt" || true
    mount -t bcachefs -o ro,nochanges "$src" "$mnt"
  fi
  err=0
  while IFS= read -r -d $'\0' f; do dd if="$f" of=/dev/null bs=1M iflag=direct,nonblock status=none 2>/dev/null || {
    echo "READ-ERROR: $f" >&2
    err=1
  }; done < <(find "$mnt" -xdev -type f -print0)
  mount -o remount,rw "$mnt" 2>/dev/null || {
    umount "$mnt" || true
    mount "$mnt" || true
  }
  jlog="$logdir/verify-reads.${esc}.log"
  {
    echo "===== $(date -Is) verify window: $start .. now ($mnt) ====="
    journalctl -k --since "$start" | grep -Ei 'bcachefs|I/O error|checksum|corrupt|bad block' || true
  } >>"$jlog"
  [[ "$err" -eq 0 ]] && echo "verify-reads: completed for $mnt; see $jlog" || echo "verify-reads: completed with read errors for $mnt; see $jlog"
done
