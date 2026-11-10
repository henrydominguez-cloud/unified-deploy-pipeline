#!/bin/sh
# Run language tests if PROJECT_TYPE matches $1 (python|java). Exits 0 if not,
# so a CI can create one job per language without knowing the type upfront.
set -eu
# shellcheck source=scripts/ci/lib.sh
. "$(dirname "$0")/lib.sh"
need PROJECT_TYPE APP_DIR
WANT="${1:-$PROJECT_TYPE}"
[ "$PROJECT_TYPE" = "$WANT" ] || { log "skip: PROJECT_TYPE=$PROJECT_TYPE, this step tests $WANT"; exit 0; }

ROOT="$(pwd)"
cd "$APP_DIR"
case "$PROJECT_TYPE" in
  python)
    for f in requirements.txt requirements-dev.txt; do
      if [ -f "$f" ]; then pip install --quiet -r "$f"; fi
    done
    python -m pytest -q --junitxml="$ROOT/report.xml" ;;
  java)
    mvn -B -q verify ;;
  *)
    log "no tests for PROJECT_TYPE=$PROJECT_TYPE" ;;
esac
