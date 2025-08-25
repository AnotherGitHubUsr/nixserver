#!/usr/bin/env bash
set -euo pipefail
# commit/push only when repo has changes; uses GitHub deploy key (agenix)
REPO_DIR="${REPO_DIR:-/srv/nixserver/config}"
DEPLOY_KEY_PATH="${DEPLOY_KEY_PATH:-/run/agenix/github-deploy}"
GIT_REMOTE="${GIT_REMOTE:-origin}"
GIT_BRANCH="${GIT_BRANCH:-main}"
GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-nixserver-gitops}"
GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-nixserver-gitops@local}"
KNOWN_HOSTS="${KNOWN_HOSTS:-}"
SSH_EXTRA_OPTS="${SSH_EXTRA_OPTS:-}"

command -v git >/dev/null || {
  echo "missing git" >&2
  exit 2
}
[[ -d "$REPO_DIR/.git" ]] || {
  echo "not a git repo: $REPO_DIR" >&2
  exit 2
}
[[ -f "$DEPLOY_KEY_PATH" ]] || {
  echo "missing deploy key: $DEPLOY_KEY_PATH" >&2
  exit 2
}
chmod 0400 "$DEPLOY_KEY_PATH" || true
if [[ -n "$KNOWN_HOSTS" && -f "$KNOWN_HOSTS" ]]; then
  export GIT_SSH_COMMAND="ssh -i '$DEPLOY_KEY_PATH' -o IdentitiesOnly=yes -o UserKnownHostsFile='$KNOWN_HOSTS' -o StrictHostKeyChecking=yes $SSH_EXTRA_OPTS"
else
  export GIT_SSH_COMMAND="ssh -i '$DEPLOY_KEY_PATH' -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new $SSH_EXTRA_OPTS"
fi

pushd "$REPO_DIR" >/dev/null
git config user.name "$GIT_AUTHOR_NAME"
git config user.email "$GIT_AUTHOR_EMAIL"

git fetch "$GIT_REMOTE" || true
git checkout "$GIT_BRANCH" 2>/dev/null || git checkout -b "$GIT_BRANCH"
git pull --rebase "$GIT_REMOTE" "$GIT_BRANCH" || true

# Only commit when actual changes exist
if [[ -z "$(git status --porcelain=v1)" ]]; then
  echo "[gitops] clean; nothing to commit."
  popd >/dev/null
  exit 0
fi

git add -A
[[ -n "$(git status --porcelain=v1)" ]] || {
  echo "[gitops] no staged changes"
  popd >/dev/null
  exit 0
}
TS="$(date -Is)"
git commit -m "chore(gitops): auto-commit ${TS}"
git push "$GIT_REMOTE" "$GIT_BRANCH"
echo "[gitops] pushed at ${TS}"
popd >/dev/null
