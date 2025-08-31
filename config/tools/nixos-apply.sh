#!/usr/bin/env bash
# ==============================================================================
# nixos-apply.sh
# ------------------------------------------------------------------------------
# Purpose
#   Deterministically build a NixOS system from a flake, activate the EXACT
#   built closure, mirror the flake into /etc/nixos on success, export a
#   release snapshot, and optionally auto-commit/push the repo.
#
# Behavior
#   1) nixos-rebuild build --flake "<FLAKE>#<HOST>" [--impure] [--show-trace] …
#   2) Run the built result's ./bin/switch-to-configuration switch
#   3) Mirror flake → /etc/nixos via rsync (backup the old contents)
#   4) Export a release (if export-release.sh is present and executable)
#   5) Optionally run git-autocommit-push.sh
#
# Usage
#   nixos-apply.sh [--flake PATH] [--host NAME] [--impure] [--show-trace]
#                  [--no-mirror] [--no-export] [--no-git]
#                  [--extra "RAW ARGS TO nixos-rebuild"]
#
# Environment
#   EXPORT_RELEASE   Path to export-release.sh
#                   (default: /srv/nixserver/config/tools/export-release.sh)
#   AUTOCOMMIT_TOOL  Path to git-autocommit-push.sh
#                   (default: /srv/nixserver/config/tools/git-autocommit-push.sh)
#   RSYNC_EXCLUDES   Space-separated extra rsync --exclude patterns
#
# Notes
#   - We build first, then activate the built closure directly to avoid
#     evaluating again. The activation script is part of the result’s closure
#     and is invoked as: result/bin/switch-to-configuration switch
#   - --show-trace is passed only to the build step for richer error traces.
#   - --extra lets you pass additional flags to nixos-rebuild verbatim
#     (e.g. '--keep-going -j4 -L').
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
SHOW_TRACE=0  # 1=--show-trace, 0=off
EXTRA_ARGS=() # additional nixos-rebuild args (single string)

# Timestamp helper (used for backup dir naming)
ts() { date +%Y-%m-%d_%H-%M-%S; }

usage() {
  cat <<'USAGE'
Usage: nixos-apply.sh [--flake PATH] [--host NAME] [--impure] [--show-trace]
                      [--no-mirror] [--no-export] [--no-git]
                      [--extra "ARGS..."]
Env:
  EXPORT_RELEASE  (/srv/nixserver/config/tools/export-release.sh)
  AUTOCOMMIT_TOOL (/srv/nixserver/config/tools/git-autocommit-push.sh)
  RSYNC_EXCLUDES  (extra rsync --exclude patterns, space-separated)
Notes:
  --extra passes raw args to nixos-rebuild (besides the managed ones here).
  --show-trace affects only the nixos-rebuild build step.
USAGE
}

# ---------- Arg parsing --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
  --flake)
    FLAKE="${2:-}"
    shift 2
    ;;
  --host)
    HOST="${2:-}"
    shift 2
    ;;
  --impure)
    PASS_IMPURE=1
    shift
    ;;
  --show-trace)
    SHOW_TRACE=1
    shift
    ;;
  --no-mirror)
    DO_MIRROR=0
    shift
    ;;
  --no-export)
    DO_EXPORT=0
    shift
    ;;
  --no-git)
    DO_GIT=0
    shift
    ;;
  --extra)
    EXTRA_ARGS+=("${2:-}")
    shift 2
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "unknown arg: $1" >&2
    exit 64
    ;;
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
((PASS_IMPURE == 1)) && BUILD_ARGS+=(--impure)            # allow impure eval when asked
((SHOW_TRACE == 1)) && BUILD_ARGS+=(--show-trace)         # richer error traces
((${#EXTRA_ARGS[@]})) && BUILD_ARGS+=("${EXTRA_ARGS[@]}") # raw passthrough

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
pushd "$WORKDIR" >/dev/null

# nixos-rebuild will place ./result symlink in $PWD
if ! nixos-rebuild "${BUILD_ARGS[@]}"; then
  echo "Build failed." >&2
  exit 1
fi

RESULT_PATH="$(readlink -f ./result)"
if [[ ! -x "$RESULT_PATH/bin/switch-to-configuration" ]]; then
  echo "Missing switch-to-configuration in result" >&2
  exit 1
fi

# ---------- Activate the exact built closure ----------------------------------
echo "==> Activating built closure: $RESULT_PATH"
if ! "$RESULT_PATH/bin/switch-to-configuration" switch; then
  echo "Switch failed." >&2
  exit 2
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

  # Base excludes; allow caller to append via RSYNC_EXCLUDES
  EXCLUDES=(
    "--exclude=.git" "--exclude=.direnv"
    "--exclude=result" "--exclude=result*"
    "--exclude=state"
  )
  if [[ -n "${RSYNC_EXCLUDES:-}" ]]; then
    # shellcheck disable=SC2206  # word-split intended for user-provided patterns
    ADD=($RSYNC_EXCLUDES)
    EXCLUDES+=("${ADD[@]}")
  fi

  install -d -m 0755 "$MIRROR_TARGET"
  if ! rsync -a --delete "${EXCLUDES[@]}" "$FLAKE"/ "$MIRROR_TARGET/"; then
    echo "Mirror failed; backup in $BACKUP_DIR" >&2
    exit 3
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
      exit 4
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
      exit 5
    }
  else
    echo "==> Skipping git autocommit (no tool found)"
  fi
else
  echo "==> Skipping git autocommit (mirror disabled or git disabled)"
fi

echo "==> Done."
