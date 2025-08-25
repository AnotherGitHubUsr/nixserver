#!/usr/bin/env bash
# ==============================================================================
# disk-config-tool.sh  (v4.0.0)
# ==============================================================================
# PURPOSE
#   - Maintain a TOML “disk plan” that describes your mounts, and convert it to
#     /srv/nixserver/manifests/filesystems.json consumed by disk.nix.
#   - If no plan exists, create it from the LIVE system with an inventory header.
#   - If a plan exists, UPDATE it in-place:
#       * Rewrite the header comment block with current inventory
#       * Preserve existing [[filesystems]] entries
#       * Add any currently mounted filesystems that are missing (no duplicates)
#
# PATH POLICY
#   - Prefer /dev/disk/by-label/* for everything except /boot
#   - For /boot prefer /dev/disk/by-uuid/*; fall back to by-label if needed
#
# MODES
#   - (no flags) or --generate: create or update /srv/nixserver/state/disk-plan.current.toml
#   - --plan  [FILE] : parse TOML and print the JSON that would be written, with WARNs
#   - --apply [FILE] : write /srv/nixserver/manifests/filesystems.json from the TOML (with WARNs)
#
# TOML SHAPE
#   [root]
#   device  = "/dev/disk/by-uuid/XXXX..." | "/dev/disk/by-label/XXX"
#   fsType  = "ext4" | "xfs" | "bcachefs" | "btrfs" | "vfat" | ...
#   options = [ "noatime" ]   # optional list
#
#   [[filesystems]]
#   mountPoint = "/boot"
#   device     = "/dev/disk/by-uuid/AAAA-BBBB"
#   fsType     = "vfat"
#   options    = [ "relatime" ]
#
#   # Examples (commented):
#   # ZFS (pools are declared in Nix; here we only declare mountpoints using device="auto")
#   # [[filesystems]]
#   # mountPoint = "/pool"
#   # device     = "auto"
#   # fsType     = "zfs"
#   # options    = [ "rw" ]
#   #
#   # Bcachefs (multi-device fs is created with bcachefs-tools; here only the mount)
#   # [[filesystems]]
#   # mountPoint = "/bcfs"
#   # device     = "/dev/disk/by-label/carrot"   # the assembled bcachefs device/by-label
#   # fsType     = "bcachefs"
#   # options    = [
#   #   "discard=async",
#   #   "foreground_target=/dev/disk/by-label/carrot",
#   #   "writeback", "errors=remount-ro", "recovery_readonly", "readahead=16384"
#   # ]
#
# REQUIREMENTS
#   python3 (tomllib on 3.11+, tomli fallback ok), jq, util-linux (lsblk/findmnt/blkid)
# ==============================================================================

set -Eeuo pipefail
trap 'echo "[ERR] disk-config-tool: ${BASH_SOURCE[0]} failed at line ${LINENO}" >&2' ERR

# --- usage --------------------------------------------------------------------
usage() {
  cat <<'USAGE'
Usage:
  ./disk-config-tool.sh                 # create or update /srv/nixserver/state/disk-plan.current.toml
  ./disk-config-tool.sh --generate      # same as above
  ./disk-config-tool.sh --plan  [./plan.toml]
  ./disk-config-tool.sh --apply [./plan.toml]
USAGE
}

# --- prereqs ------------------------------------------------------------------
need() { command -v "$1" >/dev/null || {
  echo "[ERR] Missing $1. Try: nix shell nixpkgs#$1" >&2
  exit 2
}; }
need python3
need jq
need lsblk
need findmnt
need blkid

# --- paths --------------------------------------------------------------------
manifest_dir="/srv/nixserver/manifests"
state_dir="/srv/nixserver/state"
json_out="$manifest_dir/filesystems.json"
toml_out="$state_dir/disk-plan.current.toml"
mkdir -p "$manifest_dir" "$state_dir"

# --- args ---------------------------------------------------------------------
MODE="generate"
PLAN=""
while (($#)); do
  case "$1" in
  --apply)
    MODE="apply"
    if [[ $# -ge 2 && "${2:0:1}" != "-" ]]; then
      PLAN="$2"
      shift 2
    else
      PLAN="$toml_out"
      shift 1
    fi
    ;;
  --plan)
    MODE="plan"
    if [[ $# -ge 2 && "${2:0:1}" != "-" ]]; then
      PLAN="$2"
      shift 2
    else
      PLAN="$toml_out"
      shift 1
    fi
    ;;
  --generate)
    MODE="generate"
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "[ERR] unknown arg: $1" >&2
    usage
    exit 2
    ;;
  esac
done

# --- helpers ------------------------------------------------------------------
# choose best device path for a mountpoint, honoring by-uuid for /boot, by-label otherwise
best_path_for_mp() {
  local mp="$1"
  local src dev uuid label
  src="$(findmnt -nro SOURCE --target "$mp" 2>/dev/null || true)"
  [[ -n "$src" ]] || {
    printf '%s' ""
    return 0
  }
  dev="$(readlink -f "$src" || printf '%s' "$src")"
  uuid="$(blkid -s UUID -o value "$dev" 2>/dev/null || true)"
  label="$(blkid -s LABEL -o value "$dev" 2>/dev/null || true)"
  if [[ "$mp" == "/boot" ]]; then
    if [[ -n "$uuid" ]]; then
      printf '/dev/disk/by-uuid/%s' "$uuid"
    elif [[ -n "$label" ]]; then
      printf '/dev/disk/by-label/%s' "$label"
    else printf '%s' "$src"; fi
  else
    if [[ -n "$label" ]]; then
      printf '/dev/disk/by-label/%s' "$label"
    elif [[ -n "$uuid" ]]; then
      printf '/dev/disk/by-uuid/%s' "$uuid"
    else printf '%s' "$src"; fi
  fi
}

mk_live_entry_json() {
  # Emit one JSON object for a live mountpoint or empty if not found.
  local mp="$1" dev fs opts opts_json
  dev="$(best_path_for_mp "$mp")"
  fs="$(findmnt -nro FSTYPE --target "$mp" 2>/dev/null || true)"
  [[ -n "$dev" && -n "$fs" ]] || {
    echo ""
    return 0
  }

  # stable options only
  opts="$(findmnt -nro OPTIONS --target "$mp" 2>/dev/null || true)"
  opts="$(printf '%s\n' "$opts" | sed 's/,/\n/g' | grep -E '^(noatime|relatime|compress(=.*)?|subvol(=.*)?|x-systemd\.automount|nofail|ro|rw|umask=[0-9]+)$' || true)"

  if [[ -n "$opts" ]]; then
    opts_json="$(printf '%s\n' "$opts" | jq -Rsc 'split("\n")|map(select(length>0))')"
  else
    opts_json="[]"
  fi

  jq -n --arg mp "$mp" --arg dev "$dev" --arg fs "$fs" --argjson opts "$opts_json" \
    '{mountPoint:$mp, device:$dev, fsType:$fs} + (if ($opts|length)>0 then {options:$opts} else {} end)'
}

# Convert a JSON array like ["a","b"] to TOML-literals: "a", "b"
toml_quote_array() { jq -r 'map(@sh)|join(", ")' 2>/dev/null | sed "s/'/\"/g"; }

# Python TOML→JSON (no --argfile usage)
toml_to_json() {
  local plan="$1"
  python3 - "$plan" <<'PY'
import sys, json
try:
    import tomllib  # py3.11+
except ModuleNotFoundError:
    import tomli as tomllib  # fallback if installed
with open(sys.argv[1], 'rb') as f:
    data = tomllib.load(f)
print(json.dumps(data))
PY
}

# Validate single FS entry; echo WARNs, return 0 if valid, 1 if invalid.
validate_fs_entry() {
  local obj="$1" mp dev fs
  mp="$(jq -r '."mountPoint" // empty' <<<"$obj")"
  dev="$(jq -r '."device"     // empty' <<<"$obj")"
  fs="$(jq -r '."fsType"     // empty' <<<"$obj")"
  if [[ -z "$mp" || -z "$dev" || -z "$fs" ]]; then
    echo "WARN: invalid filesystems entry (needs mountPoint, device, fsType): $(jq -c . <<<"$obj")" >&2
    return 1
  fi
  return 0
}

# Build JSON array for filesystems from a TOML plan (with WARNs)
plan_to_fs_json() {
  local plan="$1" json
  json="$(toml_to_json "$plan")" || {
    echo "[ERR] TOML parse failed: $plan" >&2
    exit 2
  }

  # Allow either {root={}, filesystems=[...]} or the legacy {secrets=...} shape to fail loudly.
  # We do NOT use --argfile; pass $json over stdin to jq.
  printf '%s' "$json" | jq -c '
    def normopts($o):
      if $o == null then []
      elif ($o|type) == "string" then (if $o == "" then [] else [$o] end)
      elif ($o|type) == "array" then [ $o[] | select(type=="string" and length>0) ]
      else [] end;

    if (has("root") | not) or ((.root|type)!="object") then
      error("TOML must have [root] table")
    else . end
    | . as $in
    | ($in.root // {}) as $r
    | if ([$r.device,$r.fsType] | any(.==null or .=="")) then
        error("[root] requires non-empty device and fsType")
      else . end
    | (.filesystems // []) as $fs
    | (
        [ { mountPoint:"/", device:$r.device, fsType:$r.fsType }
          + (if (normopts($r.options)|length)>0 then { options: normopts($r.options) } else {} end)
        ]
        +
        ( $fs
          | map({
              mountPoint, device, fsType
            } + ( if (normopts(.options)|length)>0 then {options: normopts(.options)} else {} end ))
        )
      )'
}

# Merge live entries into existing TOML-derived set (no duplicates by mountPoint)
merge_live_into_fs_json() {
  local fs_json="$1" live_json="$2"
  jq -c --argjson live "$live_json" '
    # build set of existing MPs
    . as $cur
    | ($cur | map(.mountPoint)) as $have
    | $cur + ( $live
               | map(select( (.mountPoint|IN($have[])) | not )) )' <<<"$fs_json"
}

# Collect current live mounts we care about (/, /boot, and all other real mounts)
collect_live_fs_json() {
  local arr="[]"
  local mp
  # always consider / and /boot first
  for mp in / /boot; do
    local obj
    obj="$(mk_live_entry_json "$mp" || true)"
    [[ -n "$obj" ]] && arr="$(jq -c --argjson o "$obj" '. + [ $o ]' <<<"$arr")"
  done
  # all other mounts (ignore proc, sysfs, tmpfs, cgroup, devpts, overlay, squashfs, ramfs, zramfs)
  while read -r mp; do
    [[ "$mp" == "/" || "$mp" == "/boot" ]] && continue
    local obj
    obj="$(mk_live_entry_json "$mp" || true)"
    [[ -n "$obj" ]] && arr="$(jq -c --argjson o "$obj" '. + [ $o ]' <<<"$arr")"
  done < <(findmnt -rn -o TARGET | grep -vE '^/(proc|sys|dev|run|nix/store|boot/efi|var/lib/docker|var/lib/containers|snap|mnt|media)(/|$)' || true)
  printf '%s' "$arr"
}

# Render TOML with new header and provided fs array (root + entries)
render_toml() {
  local fs_json="$1"
  local inv
  inv="$(lsblk -p -o NAME,SIZE,TYPE,FSTYPE,LABEL,UUID,PARTUUID,MOUNTPOINT,MODEL,SERIAL)"
  inv="# $(head -n1 <<<"$inv")
$(tail -n +2 <<<"$inv" | sed 's/^/# /')"

  local root dev fs opts_joined
  root="$(jq -c 'map(select(.mountPoint=="/"))[0]' <<<"$fs_json")"
  dev="$(jq -r '."device"' <<<"$root")"
  fs="$(jq -r '."fsType"' <<<"$root")"
  opts_joined="$(jq -r '."options" // []' <<<"$root" | toml_quote_array)"

  cat <<EOF
# disk-plan.current.toml — generated/updated from live mounts
# HOW TO USE
#  1) Review [root] and [[filesystems]]; keep /dev/disk/by-uuid for /boot, by-label otherwise.
#  2) Edit options as needed; leave [] to omit.
#  3) Apply: ./disk-config-tool.sh --apply ./disk-plan.current.toml
#
$inv

[root]
device  = "$dev"
fsType  = "$fs"
$(if [[ -n "$opts_joined" ]]; then echo "options = [ $opts_joined ]"; fi)

# --- Examples ---------------------------------------------------------------
# ZFS (raidz/stripe/special devices are created in pool definition; here only mount)
# [[filesystems]]
# mountPoint = "/pool"
# device     = "auto"
# fsType     = "zfs"
# options    = [ "rw" ]
#
# bcachefs (multi-device filesystem already created; example mount options)
# [[filesystems]]
# mountPoint = "/bcfs"
# device     = "/dev/disk/by-label/carrot"
# fsType     = "bcachefs"
# options    = [
#   "discard=async",
#   "foreground_target=/dev/disk/by-label/carrot",
#   "writeback", "errors=remount-ro", "recovery_readonly", "readahead=16384"
# ]
EOF

  # rest of entries
  jq -c '.[] | select(.mountPoint != "/")' <<<"$fs_json" | while read -r line; do
    local mp d f o
    mp="$(jq -r '."mountPoint"' <<<"$line")"
    d="$(jq -r '."device"' <<<"$line")"
    f="$(jq -r '."fsType"' <<<"$line")"
    o="$(jq -r '."options" // []' <<<"$line" | toml_quote_array)"
    echo
    echo '[[filesystems]]'
    echo "mountPoint = \"$mp\""
    echo "device     = \"$d\""
    echo "fsType     = \"$f\""
    [[ -n "$o" ]] && echo "options    = [ $o ]"
  done
}

# --- generators / updaters ----------------------------------------------------
generate_or_update_plan() {
  local fs_json plan_json live_json merged_json tmp
  if [[ -r "$toml_out" ]]; then
    plan_json="$(plan_to_fs_json "$toml_out")" || exit 2
    # Validate each, warn on invalid (but plan_to_fs_json already hard-errors root)
    while read -r item; do validate_fs_entry "$item" || true; done < <(jq -c '.[]' <<<"$plan_json")
  else
    # minimal from live / + /boot (if present)
    plan_json="[]"
    local root
    root="$(mk_live_entry_json / || true)"
    [[ -n "$root" ]] && plan_json="$(jq -c --argjson o "$root" '. + [ $o ]' <<<"$plan_json")"
    local boot
    boot="$(mk_live_entry_json /boot || true)"
    [[ -n "$boot" ]] && plan_json="$(jq -c --argjson o "$boot" '. + [ $o ]' <<<"$plan_json")"
  fi

  live_json="$(collect_live_fs_json)"
  merged_json="$(merge_live_into_fs_json "$plan_json" "$live_json")"

  tmp="$(mktemp)"
  render_toml "$merged_json" >"$tmp"
  install -D -m 0644 "$tmp" "$toml_out"
  rm -f "$tmp"

  # also write a preview JSON for convenience
  printf '%s' "$merged_json" >"$json_out"
  echo "Plan updated → $toml_out"
  echo "Preview JSON → $json_out"
}

do_plan() {
  local plan="$1" fs_json
  [[ -r "$plan" ]] || {
    echo "[ERR] plan not readable: $plan (try --generate first)" >&2
    exit 2
  }
  fs_json="$(plan_to_fs_json "$plan")"
  while read -r item; do validate_fs_entry "$item" || true; done < <(jq -c '.[]' <<<"$fs_json")
  jq . <<<"$fs_json"
}

do_apply() {
  local plan="$1" fs_json
  [[ -r "$plan" ]] || {
    echo "[ERR] plan not readable: $plan (try --generate first)" >&2
    exit 2
  }
  fs_json="$(plan_to_fs_json "$plan")"
  while read -r item; do validate_fs_entry "$item" || true; done < <(jq -c '.[]' <<<"$fs_json")
  install -D -m 0644 <(printf '%s\n' "$fs_json") "$json_out"
  echo "Wrote $json_out"
}

# --- main ---------------------------------------------------------------------
case "$MODE" in
generate) generate_or_update_plan ;;
plan) do_plan "${PLAN:-$toml_out}" ;;
apply) do_apply "${PLAN:-$toml_out}" ;;
esac
