#!/usr/bin/env bash
set -euo pipefail

# export-release.sh
# Snapshot the active NixOS system into /srv/nixserver/releases/<YYYY-MM-DD_HH-MM>-<git-sha>,
# copy config+manifests (never /srv/nixserver/state), write metadata, and pin the system
# closure via a GC root (secrets are not pinned). Prints the release ID on stdout.

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

# Resolve the currently active system store path and generation
system_path="$(readlink -f /run/current-system)"
gen="$(readlink /nix/var/nix/profiles/system | sed 's/.*-//')"
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

# Metadata
iso_now="$(date -Is)"
kernel="$(uname -r)"

cat > "$rel_dir/release.json" <<EOF
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

# Pin the system closure via GC root located inside the release directory.
# --indirect ensures a companion gcroot appears under /nix/var/nix/gcroots/auto
# so moving the release directory later won't break the root.
ln -sfn "$system_path" "$rel_dir/system"
nix-store --add-root "$rel_dir/gcroot-system" --indirect "$system_path" >/dev/null

# Mark as latest
echo "$rel_id" > "$STATE_DIR/LAST"

echo "$rel_id"
