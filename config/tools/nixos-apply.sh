#!/usr/bin/env bash
set -euo pipefail

# Build NixOS from /srv/nixserver/config (flake), activate the EXACT built closure,
# mirror to /etc/nixos on success, export a release, then optionally commit/push.
#
# New:
#   --show-trace   → passes through to nixos-rebuild for detailed error traces.

FLAKE="/srv/nixserver/config"
HOST="$(hostname)"
MIRROR_TARGET="/etc/nixos"
DO_MIRROR=1
DO_EXPORT=1
DO_GIT=1
PASS_IMPURE=0
SHOW_TRACE=0 # added: off by default
EXTRA_ARGS=()

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
  --show-trace only affects the nixos-rebuild build step.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --flake)
    FLAKE="$2"
    shift 2
    ;;
  --host)
    HOST="$2"
    shift 2
    ;;
  --impure)
    PASS_IMPURE=1
    shift
    ;;
  --show-trace)
    SHOW_TRACE=1
    shift
    ;; # added
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
    EXTRA_ARGS+=("$2")
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

[[ $EUID -eq 0 ]] || {
  echo "Run as root"
  exit 1
}
[[ -r "$FLAKE/flake.nix" ]] || {
  echo "No flake.nix at $FLAKE" >&2
  exit 64
}

ts() { date +%Y-%m-%d_%H-%M-%S; }
TS="$(ts)"

echo "==> Building $FLAKE#$HOST"
BUILD_ARGS=(build --flake "$FLAKE#$HOST")
((PASS_IMPURE == 1)) && BUILD_ARGS+=(--impure)
((SHOW_TRACE == 1)) && BUILD_ARGS+=(--show-trace) # added
((${#EXTRA_ARGS[@]})) && BUILD_ARGS+=("${EXTRA_ARGS[@]}")

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
pushd "$WORKDIR" >/dev/null

if ! nixos-rebuild "${BUILD_ARGS[@]}"; then
  echo "Build failed." >&2
  exit 1
fi

RESULT_PATH="$(readlink -f ./result)"
[[ -x "$RESULT_PATH/bin/switch-to-configuration" ]] ||
  {
    echo "Missing switch-to-configuration" >&2
    exit 1
  }

echo "==> Activating built closure: $RESULT_PATH"
if ! "$RESULT_PATH/bin/switch-to-configuration" switch; then
  echo "Switch failed." >&2
  exit 2
fi
popd >/dev/null

if ((DO_MIRROR == 1)); then
  echo "==> Mirroring $FLAKE → $MIRROR_TARGET (backup, then rsync)"
  BACKUP_DIR="/srv/nixserver/backups/etc-nixos/$TS"
  install -d -m 0750 "$BACKUP_DIR"
  [[ -d "$MIRROR_TARGET" ]] && rsync -a --delete "$MIRROR_TARGET"/ "$BACKUP_DIR/"

  EXCLUDES=("--exclude=.git" "--exclude=.direnv" "--exclude=result" "--exclude=result*" "--exclude=state")
  if [[ -n "${RSYNC_EXCLUDES:-}" ]]; then
    # shellcheck disable=SC2206
    ADD=($RSYNC_EXCLUDES)
    EXCLUDES+=("${ADD[@]}")
  fi

  install -d -m 0755 "$MIRROR_TARGET"
  rsync -a --delete "${EXCLUDES[@]}" "$FLAKE"/ "$MIRROR_TARGET/" ||
    {
      echo "Mirror failed; backup in $BACKUP_DIR" >&2
      exit 3
    }
fi

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

if ((DO_GIT == 1)); then
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
fi

echo "==> Done."
