#!/usr/bin/env bash
# ==============================================================================
# nixos-apply.sh
# ------------------------------------------------------------------------------
# Purpose
#   Deterministically build a NixOS system from a flake, set the system profile
#   to the EXACT built closure, ensure /boot is mounted so boot entries update,
#   activate the closure, mirror the flake into /etc/nixos on success, export a
#   release snapshot, and optionally auto-commit/push the repo.
#
# Behavior
#   1) nixos-rebuild build --flake "<FLAKE>#<HOST>" [--impure] [--show-trace] …
#   2) Set system profile → nix-env -p /nix/var/nix/profiles/system --set <result>
#   3) Ensure /boot is mounted (if present), then run:
#      <result>/bin/switch-to-configuration switch
#   4) Mirror flake → /etc/nixos (backup, then rsync)
#   5) Export a release (if export-release.sh exists)
#   6) Optionally run git-autocommit-push.sh
#
# Usage
#   nixos-apply.sh [--flake PATH] [--host NAME] [--impure] [--show-trace]
#                  [--no-mirror] [--no-export] [--no-git]
#                  [--extra "RAW ARGS TO nixos-rebuild"]
#                  [--allow-unmounted-boot]
#
# Environment
#   EXPORT_RELEASE   Path to export-release.sh
#                   (default: /srv/nixserver/config/tools/export-release.sh)
#   AUTOCOMMIT_TOOL  Path to git-autocommit-push.sh
#                   (default: /srv/nixserver/config/tools/git-autocommit-push.sh)
#   RSYNC_EXCLUDES   Space-separated extra rsync --exclude patterns
#
# Notes
#   - Setting the system profile BEFORE activation makes the switch persistent.
#   - Mounting /boot ensures loader entries are written for next reboot.
#   - --allow-unmounted-boot lets you proceed in a “test” style if /boot
#     is intentionally absent (no new loader entries will be written).
# ==============================================================================
set -euo pipefail

# ---------- Defaults -----------------------------------------------------------
FLAKE="/srv/nixserver/config" # flake root (contains flake.nix)
HOST="$(hostname)"            # attribute under nixosConfigurations
MIRROR_TARGET="/etc/nixos"    # mirror target on successful activation
DO_MIRROR=1                   # 1=mirror /etc/nixos, 0=skip
DO_EXPORT=1                   # 1=export release, 0=skip
DO_GIT=1                      # 1=autocommit/push, 0=skip
PASS_IMPURE=0
SHOW_TRACE=0                  # 1=--show-trace, 0=off
EXTRA_ARGS=()                 # additional nixos-rebuild args (single string)
ALLOW_UNMOUNTED_BOOT=0        # 1=do not fail if /boot is unmounted

# Timestamp for backups
ts() { date +%Y-%m-%d_%H-%M-%S; }

usage() {
  cat <<'USAGE'
Usage: nixos-apply.sh [--flake PATH] [--host NAME] [--impure] [--show-trace]
                      [--no-mirror] [--no-export] [--no-git]
                      [--extra "ARGS..."]
                      [--allow-unmounted-boot]
Env:
  EXPORT_RELEASE  (/srv/nixserver/config/tools/export-release.sh)
  AUTOCOMMIT_TOOL (/srv/nixserver/config/tools/git-autocommit-push.sh)
  RSYNC_EXCLUDES  (extra rsync --exclude patterns, space-separated)
Notes:
  - The script sets the system profile to the built result before activation.
  - It mounts /boot (if present) to write loader entries. Use
    --allow-unmounted-boot to skip that requirement.
USAGE
}

# ---------- Arg parsing --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --flake) FLAKE="${2:-}"; shift 2 ;;
    --host) HOST="${2:-}"; shift 2 ;;
    --impure) PASS_IMPURE=1; shift ;;
    --show-trace) SHOW_TRACE=1; shift ;;
    --no-mirror) DO_MIRROR=0; shift ;;
    --no-export) DO_EXPORT=0; shift ;;
    --no-git) DO_GIT=0; shift ;;
    --extra) EXTRA_ARGS+=("${2:-}"); shift 2 ;;
    --allow-unmounted-boot) ALLOW_UNMOUNTED_BOOT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done

# ---------- Preconditions ------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi
if [[ ! -r "$FLAKE/flake.nix" ]]; then
  echo "No flake.nix at $FLAKE" >&2
  exit 64
fi

TS="$(ts)"

# ---------- Build (single evaluation) -----------------------------------------
echo "==> Building $FLAKE#$HOST"
BUILD_ARGS=(build --flake "$FLAKE#$HOST")
((PASS_IMPURE == 1)) && BUILD_ARGS+=(--impure)
((SHOW_TRACE == 1)) && BUILD_ARGS+=(--show-trace)
((${#EXTRA_ARGS[@]})) && BUILD_ARGS+=("${EXTRA_ARGS[@]}")

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
pushd "$WORKDIR" >/dev/null

# nixos-rebuild places ./result symlink in PWD
if ! nixos-rebuild "${BUILD_ARGS[@]}"; then
  echo "Build failed." >&2
  exit 1
fi

RESULT_PATH="$(readlink -f ./result)"
if [[ ! -x "$RESULT_PATH/bin/switch-to-configuration" ]]; then
  echo "Missing switch-to-configuration in result" >&2
  exit 1
fi

# ---------- Set system profile BEFORE activation ------------------------------
# This makes the generation persistent and aligns with nixos-rebuild semantics.
echo "==> Registering system profile → $RESULT_PATH"
nix-env -p /nix/var/nix/profiles/system --set "$RESULT_PATH"

# ---------- Ensure /boot is mounted (to write loader entries) -----------------
# If /boot exists and is configured, mount it unless already mounted.
if [[ -d /boot ]]; then
  if ! findmnt -n /boot >/dev/null 2>&1; then
    if (( ALLOW_UNMOUNTED_BOOT == 1 )); then
      echo "==> /boot is not mounted; proceeding due to --allow-unmounted-boot"
    else
      echo "==> Mounting /boot to update bootloader entries"
      if ! mount /boot; then
        echo "ERROR: /boot could not be mounted. Use --allow-unmounted-boot to bypass." >&2
        exit 2
      fi
    fi
  fi
fi

# ---------- Activate the exact built closure ----------------------------------
echo "==> Activating built closure: $RESULT_PATH"
if ! "$RESULT_PATH/bin/switch-to-configuration" switch; then
  echo "Switch failed." >&2
  exit 3
fi
popd >/dev/null

# ---------- Mirror flake → /etc/nixos -----------------------------------------
if ((DO_MIRROR == 1)); then
  echo "==> Mirroring $FLAKE → $MIRROR_TARGET (backup then rsync)"
  BACKUP_DIR="/srv/nixserver/backups/etc-nixos/$TS"
  install -d -m 0750 "$BACKUP_DIR"
  if [[ -d "$MIRROR_TARGET" ]]; then
    rsync -a --delete "$MIRROR_TARGET"/ "$BACKUP_DIR/"
  fi
  EXCLUDES=(
    "--exclude=.git" "--exclude=.direnv"
    "--exclude=result" "--exclude=result*"
    "--exclude=state"
  )
  if [[ -n "${RSYNC_EXCLUDES:-}" ]]; then
    # shellcheck disable=SC2206
    ADD=($RSYNC_EXCLUDES)
    EXCLUDES+=("${ADD[@]}")
  fi
  install -d -m 0755 "$MIRROR_TARGET"
  if ! rsync -a --delete "${EXCLUDES[@]}" "$FLAKE"/ "$MIRROR_TARGET/"; then
    echo "Mirror failed; backup in $BACKUP_DIR" >&2
    exit 4
  fi
fi

# ---------- Export a release snapshot -----------------------------------------
REL_ID=""
if ((DO_EXPORT == 1)); then
  EXPORT="${EXPORT_RELEASE:-/srv/nixserver/config/tools/export-release.sh}"
  if [[ -x "$EXPORT" ]]; then
    echo "==> Exporting release via $EXPORT"
    if ! REL_ID="$("$EXPORT")"; then
      echo "Export failed." >&2
      exit 5
    fi
    echo "Release: $REL_ID"
  else
    echo "==> Skipping export (no export-release.sh found)"
  fi
fi

# ---------- Optional repo autocommit/push -------------------------------------
if ((DO_GIT == 1 && DO_MIRROR == 1)); then
  AUTOCOMMIT="${AUTOCOMMIT_TOOL:-/srv/nixserver/config/tools/git-autocommit-push.sh}"
  if [[ -x "$AUTOCOMMIT" ]]; then
    echo "==> Git autocommit/push"
    REPO_DIR="${REPO_DIR:-/srv/nixserver}" \
      "$AUTOCOMMIT" ${REL_ID:+--id "$REL_ID"} || {
      echo "Git commit/push failed." >&2
      exit 6
    }
  else
    echo "==> Skipping git autocommit (no tool found)"
  fi
else
  echo "==> Skipping git autocommit (mirror disabled or git disabled)"
fi

echo "==> Done."
