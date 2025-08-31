#!/usr/bin/env bash
# ==============================================================================
# git-autocommit-push.sh
# ------------------------------------------------------------------------------
# Purpose:
#   Non-interactive "commit → pull --rebase --autostash → push" flow
#   using an SSH deploy key via GIT_SSH_COMMAND. Auto-creates branch and upstream
#   on first push. Optionally tags a release when --id is supplied.
#
# Usage:
#   git-autocommit-push.sh --repo /path --branch main --key /path/key \
#                          --name "CI Bot" --email "bot@example" \
#                          --message "Update" [--id REL-2025.08.30]
#
# Inputs:
#   --repo, --branch, --remote, --key, --name, --email, --message, --id
#   Environment: GIT_SSH_COMMAND (overrides), AUTO_SET_UPSTREAM=1, GIT_REMOTE=origin
#
# Behavior:
#   - Uses `git -C <path>` (official) to operate in the target repo.
#   - `git pull --rebase --autostash` is used to integrate remote changes safely.
#   - Converts HTTPS GitHub origin to SSH if needed, so the key is used.
#   - Tags are created locally and pushed if --id is set (annotated tag).
#
# Notes:
#   - Prefer a repo-local `core.sshCommand` for persistent config; GIT_SSH_COMMAND
#     takes precedence for one-off runs.
#   - For OpenSSH, consider `-o IdentitiesOnly=yes -F /dev/null` to avoid agent keys.
#   - Host key verification: keep strict checking. Pre-provision known_hosts.
#
# Exit codes:
#   0 success; 2 usage/config error; >0 underlying git/ssh error.
# ==============================================================================

set -Eeuo pipefail

# --- config -------------------------------------------------------------------
REPO_DIR="${REPO_DIR:-/srv/nixserver}"
DEPLOY_KEY_PATH="${DEPLOY_KEY_PATH:-/run/agenix/github-deploy}"
GIT_REMOTE="${GIT_REMOTE:-origin}"
GIT_BRANCH="${GIT_BRANCH:-main}"
GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-nixserver-gitops}"
GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-nixserver-gitops@local}"
KNOWN_HOSTS="${KNOWN_HOSTS:-}"
SSH_EXTRA_OPTS="${SSH_EXTRA_OPTS:-}"
AUTO_FIX_REMOTE="${AUTO_FIX_REMOTE:-1}"
AUTO_SET_UPSTREAM="${AUTO_SET_UPSTREAM:-1}"
CREATE_TAG_FROM_ID="${CREATE_TAG_FROM_ID:-1}"
GIT_REMOTE_URL="${GIT_REMOTE_URL:-}"

# --- args ---------------------------------------------------------------------
REL_ID=""
while (($#)); do
  case "$1" in
  --id)
    REL_ID="${2:-}"
    shift 2
    ;;
  -h | --help)
    sed -n '1,120p' "$0"
    exit 0
    ;;
  *)
    echo "[gitops] unknown arg: $1" >&2
    exit 64
    ;;
  esac
done

# --- helpers ------------------------------------------------------------------
die() {
  echo "[gitops] ERROR: $*" >&2
  exit 2
}
log() { echo "[gitops] $*"; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }

# Convert a GitHub https remote to ssh (https://github.com/owner/repo(.git)? → git@github.com:owner/repo.git)
to_ssh_url() {
  local url="$1"
  if [[ "$url" =~ ^https://github\.com/([^/]+)/([^/]+?)(\.git)?$ ]]; then
    printf 'git@github.com:%s/%s.git' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    return 0
  fi
  # fallback: https://host/path → ssh://git@host/path
  if [[ "$url" =~ ^https://([^/]+)/(.+)$ ]]; then
    printf 'ssh://git@%s/%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

# --- preflight ----------------------------------------------------------------
need git
[[ -d "$REPO_DIR/.git" ]] || die "not a git repo: $REPO_DIR"
[[ -f "$DEPLOY_KEY_PATH" ]] || die "missing deploy key: $DEPLOY_KEY_PATH"
chmod 0400 "$DEPLOY_KEY_PATH" || true

# Prefer pinned host keys if provided; otherwise accept-new to avoid prompts
if [[ -n "$KNOWN_HOSTS" && -f "$KNOWN_HOSTS" ]]; then
  export GIT_SSH_COMMAND="ssh -i '$DEPLOY_KEY_PATH' -o IdentitiesOnly=yes -o UserKnownHostsFile='$KNOWN_HOSTS' -o StrictHostKeyChecking=yes $SSH_EXTRA_OPTS"
else
  export GIT_SSH_COMMAND="ssh -i '$DEPLOY_KEY_PATH' -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new $SSH_EXTRA_OPTS"
fi

pushd "$REPO_DIR" >/dev/null
trap 'popd >/dev/null' EXIT

# Avoid “dubious ownership”
git config --local --add safe.directory "$REPO_DIR" >/dev/null 2>&1 || true
git config user.name "$GIT_AUTHOR_NAME"
git config user.email "$GIT_AUTHOR_EMAIL"
git config push.default simple

# Ensure remote exists (or add it if GIT_REMOTE_URL supplied)
if ! git remote get-url "$GIT_REMOTE" >/dev/null 2>&1; then
  [[ -n "$GIT_REMOTE_URL" ]] || die "remote '$GIT_REMOTE' missing (set GIT_REMOTE_URL to add it)"
  git remote add "$GIT_REMOTE" "$GIT_REMOTE_URL"
  log "added remote $GIT_REMOTE → $GIT_REMOTE_URL"
fi

remote_url="$(git remote get-url "$GIT_REMOTE" 2>/dev/null || true)"

# Auto-fix https→ssh so deploy key is used
if [[ "$AUTO_FIX_REMOTE" = "1" && "$remote_url" =~ ^https:// ]]; then
  if new_url="$(to_ssh_url "$remote_url")"; then
    git remote set-url "$GIT_REMOTE" "$new_url"
    log "switched $GIT_REMOTE from HTTPS to SSH: $new_url"
    remote_url="$new_url"
  else
    log "remote is HTTPS but could not translate automatically: $remote_url"
  fi
fi

# Ensure branch exists locally (track remote if present)
git fetch --prune "$GIT_REMOTE" || true
if ! git rev-parse --verify "$GIT_BRANCH" >/dev/null 2>&1; then
  if git ls-remote --exit-code --heads "$GIT_REMOTE" "$GIT_BRANCH" >/dev/null 2>&1; then
    git checkout -b "$GIT_BRANCH" --track "$GIT_REMOTE/$GIT_BRANCH"
  else
    git checkout -b "$GIT_BRANCH"
  fi
else
  git checkout "$GIT_BRANCH"
fi

# --- NEW ORDER: commit first, then rebase/pull --------------------------------
# Stage & commit local changes if any (prevents “unstaged changes” blocking rebase)
if [[ -n "$(git status --porcelain=v1)" ]]; then
  git add -A
  if [[ -n "$(git status --porcelain=v1)" ]]; then
    TS="$(date -Is)"
    msg="chore(gitops): auto-commit ${TS}"
    [[ -n "$REL_ID" ]] && msg="${msg} (release: ${REL_ID})"
    git commit -m "$msg"
  fi
fi

# Pull (rebase) only if an upstream exists; otherwise we'll push -u below.
if git rev-parse --abbrev-ref --symbolic-full-name "@{u}" >/dev/null 2>&1; then
  if ! git pull --rebase "$GIT_REMOTE" "$GIT_BRANCH"; then
    git rebase --abort >/dev/null 2>&1 || true
    die "pull --rebase failed (conflicts). Manual intervention required."
  fi
fi

# Create a tag for the release id (optional)
if [[ -n "$REL_ID" && "$CREATE_TAG_FROM_ID" = "1" ]]; then
  safe_id="${REL_ID//[^A-Za-z0-9._-]/_}"
  tag="release-${safe_id}"
  if ! git rev-parse --verify "refs/tags/${tag}" >/dev/null 2>&1; then
    git tag -a "$tag" -m "Release $REL_ID" || true
    created_tag=1
  fi
fi

# Determine if upstream is set; set on first push if desired
set_upstream_needed=0
git rev-parse --abbrev-ref --symbolic-full-name "@{u}" >/dev/null 2>&1 || set_upstream_needed=1

if [[ "$set_upstream_needed" = "1" && "$AUTO_SET_UPSTREAM" = "1" ]]; then
  git push -u "$GIT_REMOTE" "$GIT_BRANCH"
else
  git push "$GIT_REMOTE" "$GIT_BRANCH"
fi

# Push tag if created
if [[ "${created_tag:-0}" = "1" ]]; then
  git push "$GIT_REMOTE" "refs/tags/${tag}:refs/tags/${tag}" || true
fi

log "pushed at $(date -Is)"
