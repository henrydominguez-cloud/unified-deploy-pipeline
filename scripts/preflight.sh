#!/bin/sh
# Everything that must be green before `git push`, in one command.
# Stops at the first failure and says which step broke.
#
#   sh scripts/preflight.sh            # all steps, including the kind e2e
#   SKIP_E2E=1 sh scripts/preflight.sh # no cluster needed (~1 min)
#
# Set SANITIZE_TERMS_FILE to your private-terms list (kept outside the repo)
# so the sanitize step checks company/customer names too.
set -eu

n=0; total=7
[ "${SKIP_E2E:-0}" = "1" ] && total=6
START="$(date +%s)"

step() {   # step "title" command...
  n=$((n + 1)); title="$1"; shift
  printf '\n[%s/%s] %s\n' "$n" "$total" "$title"
  if "$@"; then
    printf '      -> ok\n'
  else
    printf '\nPREFLIGHT FAILED at step %s/%s: %s\n' "$n" "$total" "$title"
    exit 1
  fi
}

if [ "${SKIP_E2E:-0}" = "1" ]; then DOCTOR_MODE=quick; else DOCTOR_MODE=full; fi

step "tools installed"                    sh scripts/doctor.sh "$DOCTOR_MODE"
step "sample-app unit tests"              make -s test
step "pipeline logic (stubbed helm)"      make -s test-scripts
step "yamllint + shellcheck"              make -s lint
step "helm lint + render, both envs"      sh -c 'make -s render ENV=develop >/dev/null && make -s render ENV=production >/dev/null'
step "sanitize: files + git history"      make -s sanitize
if [ "${SKIP_E2E:-0}" != "1" ]; then
  step "e2e: 4 modes on kind"             make -s e2e
fi

rm -f setup.env rendered.yaml
ELAPSED=$(( $(date +%s) - START ))
printf '\nPREFLIGHT OK · %s/%s steps · %ss' "$n" "$total" "$ELAPSED"
[ "${SKIP_E2E:-0}" = "1" ] && printf ' · e2e SKIPPED'
if [ -z "${SANITIZE_TERMS_FILE:-}" ] || ! grep -qvE '^[[:space:]]*(#|$)' "$SANITIZE_TERMS_FILE" 2>/dev/null; then
  printf ' · private terms NOT checked (SANITIZE_TERMS_FILE unset or has no terms)'
fi
printf '\n'
