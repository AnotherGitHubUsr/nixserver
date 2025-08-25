#!/usr/bin/env bash
# Lint shell scripts with syntax/style/static checks.
# Usage:
#   tools/lint-scripts.sh [OPTIONS] [PATH...]
# Options:
#   -q, --quiet   Only print files with issues (fail/warn), suppress OK noise
#   -h, --help    Show help
#
# If no PATH is given, defaults to /srv/nixserver/config/tools/*
# Notes:
#   • All checks are verbose by default EXCEPT shfmt. If formatting is needed,
#     a single summary is printed at the end listing files (via `shfmt -l`)
#     and how to fix (`shfmt -d` or `shfmt -w`).

set -Eeuo pipefail

QUIET=0
DEFAULT_GLOB="/srv/nixserver/config/tools/*"

print_help() { sed -n '1,25p' "$0"; }

log() { ((QUIET)) || printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
ok() { ((QUIET)) || printf '  [OK]   %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*" >&2; }

while (($#)); do
  case "$1" in
  -q | --quiet)
    QUIET=1
    shift
    ;;
  -h | --help)
    print_help
    exit 0
    ;;
  --)
    shift
    break
    ;;
  -*)
    warn "Unknown option: $1"
    print_help
    exit 2
    ;;
  *) break ;;
  esac
done

# Required tools (sed used by print_help)
REQ=(bash shellcheck shfmt grep sed)
HAVE() { command -v "$1" >/dev/null 2>&1; }

missing=()
for t in "${REQ[@]}"; do HAVE "$t" || missing+=("$t"); done
if ((${#missing[@]})); then
  warn "Missing tools: ${missing[*]}"
  warn "Install with nix:  nix profile install $(printf 'nixpkgs#%s ' "${missing[@]}")"
  exit 127
fi

((QUIET)) || {
  log "Using: $(bash --version | head -1)"
  log "Using: $(shellcheck --version | head -1)"
  log "Using: shfmt $(shfmt -version)"
}

# Collect targets
shopt -s nullglob
declare -a RAW_TARGETS=()
if (($#)); then
  for p in "$@"; do RAW_TARGETS+=("$p"); done
else
  for p in $DEFAULT_GLOB; do RAW_TARGETS+=("$p"); done
fi
shopt -u nullglob

# Expand directories → files
declare -a CANDIDATES=()
while IFS= read -r -d '' path; do CANDIDATES+=("$path"); done < <(
  for p in "${RAW_TARGETS[@]}"; do
    if [[ -d "$p" ]]; then
      find "$p" -type f -print0
    elif [[ -f "$p" ]]; then
      printf '%s\0' "$p"
    fi
  done
)

# Identify shell scripts:
#  - shebang mentioning bash|sh
#  - or extension .sh/.bash
#  - or executable and text with a shell shebang
is_shell() {
  local f=$1
  local first
  first="$(head -n1 "$f" 2>/dev/null || true)"
  if [[ "$first" =~ ^#!.*(bash|sh) ]]; then return 0; fi
  if [[ $f == *.sh || $f == *.bash ]]; then return 0; fi
  if [[ -x "$f" && "$first" =~ ^#!.*(bash|sh) ]]; then return 0; fi
  return 1
}

# Detect language for ShellCheck
detect_shell_lang() {
  local f="$1" first
  first="$(head -n1 "$f" 2>/dev/null || true)"
  case "$first" in
  '#!'*bash*) echo bash ;;
  '#!'*dash*) echo dash ;;
  '#!'*ksh*) echo ksh ;;
  '#!'*ash*) echo ash ;;
  '#!'*sh*) echo sh ;;
  *)
    case "$f" in
    *.bash) echo bash ;;
    *.sh) echo sh ;;
    *) echo bash ;; # safe fallback
    esac
    ;;
  esac
}

# Sanitize SHELLCHECK_OPTS (strip any -s/--shell to avoid conflicts)
parse_sc_opts() {
  local -a out=() toks=()
  local skip=0
  # shellcheck disable=SC2206
  toks=(${SHELLCHECK_OPTS:-})
  for t in "${toks[@]}"; do
    if ((skip)); then
      skip=0
      continue
    fi
    case "$t" in
    -s | --shell) skip=1 ;; # drop this and its value
    *) [[ -n "$t" ]] && out+=("$t") ;;
    esac
  done
  printf '%s\n' "${out[@]}"
}

# De-dup and filter
declare -A SEEN=()
declare -a FILES=()
for f in "${CANDIDATES[@]}"; do
  [[ -f "$f" ]] || continue
  is_shell "$f" || continue
  [[ -n "${SEEN[$f]:-}" ]] && continue
  SEEN["$f"]=1
  FILES+=("$f")
done

if ((${#FILES[@]} == 0)); then
  warn "No shell scripts found to lint."
  exit 0
fi

any_fail=0
any_warn=0
declare -a SHFMT_NEEDS=()

for f in "${FILES[@]}"; do
  # Per-file header:
  if ((QUIET)); then :; else printf '==> %s\n' "$f"; fi

  shebang="$(head -n1 "$f" || true)"
  shell="sh"
  [[ "$shebang" == *bash* ]] && shell="bash"

  # Track if something went wrong for this file (to print header in quiet)
  had_issue=0

  # Shebang/executable checks
  if [[ "$shebang" =~ ^#! ]] && [[ ! -x "$f" ]]; then
    ((QUIET && had_issue == 0)) && printf '==> %s\n' "$f"
    fail "Shebang present but file is not executable. Fix: chmod +x '$f'"
    any_fail=1
    had_issue=1
  fi
  if [[ ! "$shebang" =~ ^#! ]] && [[ -x "$f" ]]; then
    ((QUIET && had_issue == 0)) && printf '==> %s\n' "$f"
    warn "Executable without shebang (env may choose wrong shell). Add: '#!/usr/bin/env bash' or '#!/bin/sh'"
    any_warn=1
    had_issue=1
  fi

  # CRLF
  if LC_ALL=C grep -q $'\r' "$f"; then
    ((QUIET && had_issue == 0)) && printf '==> %s\n' "$f"
    fail "Contains CRLF line endings. Fix: dos2unix '$f' (or: sed -i 's/\r$//' '$f')"
    any_fail=1
    had_issue=1
  else
    ok "no CRLF line endings"
  fi

  # Syntax check
  if [[ "$shell" == bash ]]; then
    if ! bash -n "$f"; then
      ((QUIET && had_issue == 0)) && printf '==> %s\n' "$f"
      fail "bash syntax check failed (bash -n). Check unmatched quotes/ifs/heredocs."
      any_fail=1
      had_issue=1
    else
      ok "bash -n"
    fi
  else
    if command -v dash >/dev/null 2>&1; then
      if ! dash -n "$f"; then
        ((QUIET && had_issue == 0)) && printf '==> %s\n' "$f"
        fail "POSIX sh syntax check failed (dash -n)."
        any_fail=1
        had_issue=1
      else
        ok "dash -n"
      fi
    else
      if ! sh -n "$f"; then
        ((QUIET && had_issue == 0)) && printf '==> %s\n' "$f"
        fail "sh syntax check failed (sh -n)."
        any_fail=1
        had_issue=1
      else
        ok "sh -n"
      fi
    fi
  fi

  # --- ShellCheck -------------------------------------------------------------
  sc_lang="$(detect_shell_lang "$f")"
  case "$sc_lang" in bash | sh | dash | ksh | ash) : ;; *) sc_lang=bash ;; esac
  SC_OPTS=()
  while IFS= read -r _opt; do
    [[ -n "$_opt" ]] && SC_OPTS+=("$_opt")
  done < <(parse_sc_opts)

  if ! shellcheck -x -s "$sc_lang" ${SC_OPTS:+${SC_OPTS[@]}} "$f"; then
    ((QUIET)) && printf '==> %s\n' "$f"
    if ((QUIET)); then
      fail "shellcheck reported issues. Run: shellcheck -x -s $sc_lang '$f'"
    else
      fail "shellcheck reported issues (see messages above)."
    fi
    any_fail=1
    had_issue=1
  else
    ok "shellcheck"
  fi

  # --- shfmt (style) — quiet per-file; summarize later -----------------------
  if ! shfmt -d "$f" >/dev/null; then
    SHFMT_NEEDS+=("$f")
    any_warn=1
    had_issue=1
  else
    ok "shfmt"
  fi

  # Trailing whitespace
  if grep -nP '[ \t]+$' "$f" >/dev/null; then
    ((QUIET && had_issue == 0)) && printf '==> %s\n' "$f"
    warn "Trailing whitespace found (lines shown with: grep -nP '[ \\t]+$' '$f')."
    any_warn=1
    had_issue=1
  else
    ok "no trailing whitespace"
  fi

  # Recommend safety flags if missing (non-fatal)
  if ! grep -Eq 'set -E?e' "$f"; then
    ((QUIET && had_issue == 0)) && printf '==> %s\n' "$f"
    warn "Consider 'set -e' (or 'set -Eeuo pipefail') for safer failure handling."
    any_warn=1
    had_issue=1
  fi
done

# --- shfmt summary block -------------------------------------------------------
if ((${#SHFMT_NEEDS[@]})); then
  echo
  warn "shfmt found formatting issues in ${#SHFMT_NEEDS[@]} file(s):"
  # Show exactly what shfmt intends to rewrite:
  shfmt -l "${SHFMT_NEEDS[@]}" || true
  # Helpful next steps (properly quoted command suggestions)
  {
    printf 'To review diffs: shfmt -d'
    printf ' %q' "${SHFMT_NEEDS[@]}"
    printf '\n'
    printf 'To write fixes:  shfmt -w'
    printf ' %q' "${SHFMT_NEEDS[@]}"
    printf '\n'
  } >&2
fi

if ((any_fail)); then
  warn "Lint failures detected."
  exit 1
fi
if ((any_warn)); then
  warn "Completed with warnings."
else
  log "All checks passed."
fi
exit 0
