#!/usr/bin/env bash
# ==============================================================================
# export-release.sh
# ------------------------------------------------------------------------------
# Purpose
#   Snapshot the active NixOS system into /srv/nixserver/releases/<ID>
#   and pin its store closure via a GC root. Copy the configuration repo and
#   manifests (never /srv/nixserver/state) and write metadata with boot status.
#
# Release ID
#   <YYYY-MM-DD_HH-MM>-<git-sha12>  (git short SHA from CONFIG_DIR)
#
# Usage
#   export-release.sh
#     - Creates: /srv/nixserver/releases/<ID>/{config,manifests,release.json,system,gcroot-system}
#     - Updates: /srv/nixserver/state/release/LAST  with the ID
#
# Notes
#   - GC root is created with: nix-store --add-root <rel>/gcroot-system --indirect -r <system>
#     This realizes and registers the system path, and creates an auto root symlink.
#   - release.json is written atomically to avoid partial files.
#   - /srv/nixserver/state is never copied into the release.
# ==============================================================================
set -euo pipefail

CONFIG_DIR="/srv/nixserver/config"
MANIFESTS_DIR="/srv/nixserver/manifests"
RELEASES_DIR="/srv/nixserver/releases"
STATE_DIR="/srv/nixserver/state/release"

mkdir -p "$RELEASES_DIR" "$STATE_DIR"

host="$(hostname)"
ts="$(date +%Y-%m-%d_%H-%M)"
gitrev="$(git -C "$CONFIG_DIR" rev-parse --short=12 HEAD 2>/dev/null || echo nogit)"
rel_id="${ts}-${gitrev}"
rel_dir="${RELEASES_DIR}/${rel_id}"

# Resolve the currently active system store path and generation number
system_path="$(readlink -f /run/current-system)"
# Extract NixOS profile generation from /nix/var/nix/profiles/system-<N>-link
# Fallback to "unknown" if pattern does not match
gen="$(readlink /nix/var/nix/profiles/system 2>/dev/null | sed -n 's/.*-\([0-9]\+\)-link/\1/p')"
[[ -n "$gen" ]] || gen="unknown"

# Detect if a reboot is required (booted system differs from current profile)
booted="$(readlink -f /run/booted-system 2>/dev/null || true)"
reboot_required=0
if [[ -n "${booted:-}" && "$booted" != "$system_path" ]]; then
  reboot_required=1
fi

# Create release tree
mkdir -p "$rel_dir"/{config,manifests}
# Copy repo config (exclude .git) and manifests; never copy /srv/nixserver/state
rsync -a --delete --exclude '.git' "$CONFIG_DIR"/ "$rel_dir/config/"
rsync -a --delete "$MANIFESTS_DIR"/ "$rel_dir/manifests/"

# Metadata (atomic write)
iso_now="$(date -Is)"
kernel="$(uname -r)"
tmp_json="${rel_dir}/.release.json.new"
cat >"$tmp_json" <<EOF
{
  "id": "${rel_id}",
  "host": "${host}",
  "timestamp": "${iso_now}",
  "systemPath": "${system_path}",
  "generation": "${gen}",
  "gitRev": "${gitrev}",
  "kernel": "${kernel}",
  "rebootRequired": ${reboot_required}
}
EOF
mv -f "$tmp_json" "$rel_dir/release.json"

# Pin the system closure via GC root located inside the release directory.
# --indirect ensures a companion gcroot appears under /nix/var/nix/gcroots/auto
# so moving the release directory later won't break the root.
ln -sfn "$system_path" "$rel_dir/system"
nix-store --add-root "$rel_dir/gcroot-system" --indirect -r "$system_path" >/dev/null

# Mark as latest
echo "$rel_id" >"$STATE_DIR/LAST"

# Print the release id on stdout for callers
echo "$rel_id"
