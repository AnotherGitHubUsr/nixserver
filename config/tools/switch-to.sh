#!/usr/bin/env bash
set -euo pipefail
# switch to an exported release by <TS> (confirm) or <TS_SHA> (no prompt)

BASE="/srv/nixserver"; REL="$BASE/releases"; LOCK="/run/lock/srv-nixos.lock"
usage(){ echo "usage: $0 <YYYY-MM-DD_HH-MMZ> | <YYYY-MM-DD_HH-MMZ_SHA>"; exit 2; }
[[ $# -eq 1 ]] || usage
arg="$1"; exec 9>"$LOCK"; flock 9
resolve(){ local a="$1"
  if [[ "$a" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}Z_[0-9a-f]+$ ]]; then echo "$a"; return 0; fi
  local m; m=$(ls -1 "$REL"/"${a}"_* 2>/dev/null || true); [[ -n "$m" ]] || { echo "no release for TS: $a" >&2; exit 2; }
  echo "$m" | sort | tail -n1 | xargs -I{} basename "{}"
}
TS_SHA="$(resolve "$arg")"; DEST="$REL/$TS_SHA"; [[ -d "$DEST" ]] || { echo "missing release: $TS_SHA" >&2; exit 2; }
SYS="$(cat "$DEST/.system-path")"; [[ -x "$SYS/bin/switch-to-configuration" ]] || { echo "invalid system path" >&2; exit 2; }
if [[ ! "$arg" =~ _[0-9a-f]+$ ]]; then
  echo "Switch to: $TS_SHA"; read -r -p "Proceed? [y/N/c] " ans; case "${ans,,}" in y|yes) : ;; *) echo "aborted."; exit 0;; esac
fi
OLD="$(readlink -f "$BASE/current" || true)"; [[ -n "$OLD" ]] && ln -sfn "$OLD" "$BASE/previous"; ln -sfn "$DEST" "$BASE/current"
exec "$SYS/bin/switch-to-configuration" switch
