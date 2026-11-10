#!/usr/bin/env bash
# Fail if what you are about to publish contains anything that looks like a
# secret or a private term. Run before every push to a public remote.
#
#   scripts/check-sanitized.sh [DIR]
#   SANITIZE_TERMS_FILE=~/private-terms.txt scripts/check-sanitized.sh
#
# What is scanned:
#   - inside a git repo: tracked + untracked-but-not-ignored files (what a
#     `git add -A` would publish) AND every commit already in history
#   - outside a git repo: every file under DIR
#
# SANITIZE_TERMS_FILE: one term per line (company, customer, host and
# cluster names...). Keep it OUTSIDE the repo: the list itself is private.
# Works with macOS bash 3.2 and BSD grep.
set -euo pipefail

ROOT="${1:-.}"
TERMS_FILE="${SANITIZE_TERMS_FILE:-}"
SELF="scripts/check-sanitized.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
found=0

if [[ -n "$TERMS_FILE" && ! -f "$TERMS_FILE" ]]; then
  echo "ERROR: SANITIZE_TERMS_FILE=$TERMS_FILE not found"; exit 2
fi
if [[ -n "$TERMS_FILE" ]]; then
  # absolute path before cd; drop blank lines and comments
  grep -vE '^[[:space:]]*(#|$)' "$TERMS_FILE" > "$TMP/terms" || true
fi

cd "$ROOT"

patterns=(
  'BEGIN [A-Z ]*PRIVATE KEY'                                   # PEM keys
  'AKIA[0-9A-Z]{16}'                                           # AWS access key id
  'glpat-[0-9A-Za-z_-]{20}'                                    # GitLab PAT
  'ghp_[0-9A-Za-z]{36}'                                        # GitHub PAT
  'ocid1\.[a-z]+\.'                                            # OCI resource ids
  '(^|[^0-9.])(10|192\.168)\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)' # private IPv4 (10/8, 192.168/16)
  '(^|[^0-9.])172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}'
  '(password|passwd|secret|token)["'\'']?[[:space:]]*[:=][[:space:]]*["'\''][^"'\''$ ]{8,}'
)

# ── File list (NUL-separated) ────────────────────────────────────────
IN_GIT=0
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  IN_GIT=1
  git ls-files -z --cached --others --exclude-standard > "$TMP/files"
  echo "scope: git files (tracked + untracked, ignored files skipped)"
else
  find . -type f -not -path './.git/*' -print0 > "$TMP/files"
  echo "scope: all files under $(pwd) (not a git repo)"
fi

# scan_files GREP_ARGS...  -> prints matches, returns 0 if any
scan_files() {
  local out
  out="$(xargs -0 grep -IHn "$@" < "$TMP/files" 2>/dev/null | grep -v "^\(\./\)\{0,1\}$SELF:" || true)"
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out"
}

# scan_history GREP_ARGS... -> same, over every commit's added lines
scan_history() {
  local out
  out="$(git log --all -p --no-color -- . ":(exclude)$SELF" 2>/dev/null \
        | grep '^+' | grep -v '^+++' | grep -n "$@" || true)"
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out" | head -20
}

HAS_HISTORY=0
if [[ "$IN_GIT" -eq 1 ]] && git rev-parse HEAD >/dev/null 2>&1; then
  HAS_HISTORY=1
  echo "scope: + git history ($(git rev-list --all --count) commits)"
fi

for p in "${patterns[@]}"; do
  if scan_files -E -e "$p"; then
    echo "^^^ files matched pattern: $p"; found=1
  fi
  if [[ "$HAS_HISTORY" -eq 1 ]] && scan_history -E -e "$p"; then
    echo "^^^ git HISTORY matched pattern: $p (deleting the file is not enough)"; found=1
  fi
done

if [[ -s "$TMP/terms" ]]; then
  # -F fixed strings, -i case-insensitive, -w whole words
  if scan_files -Fiw -f "$TMP/terms"; then
    echo "^^^ files matched a private term from $TERMS_FILE"; found=1
  fi
  if [[ "$HAS_HISTORY" -eq 1 ]] && scan_history -Fiw -f "$TMP/terms"; then
    echo "^^^ git HISTORY matched a private term (deleting the file is not enough)"; found=1
  fi
  echo "private terms checked: $(wc -l < "$TMP/terms" | tr -d ' ')"
else
  echo "WARN: SANITIZE_TERMS_FILE not set or empty — only generic patterns checked"
fi

if [[ "$found" -eq 0 ]]; then
  echo "SANITIZED OK"
else
  echo "FAIL: fix the matches above before pushing"
  exit 1
fi
