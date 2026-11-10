#!/bin/sh
# Decide everything once: project type, environment, namespace, image and
# values files. Writes KEY=VALUE lines to $SETUP_ENV_FILE (default setup.env)
# that every later step reads.
#
# Inputs (env): DEPLOYMENT_MODE, IMAGE_TAG, APP_DIR, APP_NAME, CHART_DIR,
#   ENVS_DIR, NAMESPACE_DEVELOP, NAMESPACE_PRODUCTION, IMAGE_REPO, REF_NAME.
# Falls back to GitLab (CI_*) or GitHub (GITHUB_*) built-ins, then to git.
set -eu
# shellcheck source=scripts/ci/lib.sh
. "$(dirname "$0")/lib.sh"

: "${DEPLOYMENT_MODE:=full}"
: "${IMAGE_TAG:=}"
: "${APP_DIR:=.}"
: "${CHART_DIR:=chart}"
: "${ENVS_DIR:=envs}"
: "${NAMESPACE_DEVELOP:=develop}"
: "${NAMESPACE_PRODUCTION:=production}"
: "${SETUP_ENV_FILE:=setup.env}"

case "$DEPLOYMENT_MODE" in
  full|config_only|deploy_image|rollback) ;;
  *) die "DEPLOYMENT_MODE='$DEPLOYMENT_MODE' (use full|config_only|deploy_image|rollback)" ;;
esac
if [ "$DEPLOYMENT_MODE" = "deploy_image" ] && [ -z "$IMAGE_TAG" ]; then
  die "deploy_image needs IMAGE_TAG (an existing tag in the registry)"
fi

GH_REPO="${GITHUB_REPOSITORY:-}"
REF="${REF_NAME:-${CI_COMMIT_REF_NAME:-${GITHUB_REF_NAME:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo local)}}}"
RUN="${RUN_ID:-${CI_PIPELINE_ID:-${GITHUB_RUN_ID:-local}}}"
PROJECT="${CI_PROJECT_NAME:-${GH_REPO##*/}}"
APP="${APP_NAME:-${PROJECT:-$(basename "$(pwd)")}}"

if [ -n "${CI_REGISTRY_IMAGE:-}" ]; then
  BASE="$CI_REGISTRY_IMAGE"
elif [ -n "$GH_REPO" ]; then
  BASE="ghcr.io/$(printf '%s' "$GH_REPO" | tr '[:upper:]' '[:lower:]')"
else
  BASE="local"
fi
REPO="${IMAGE_REPO:-$BASE/$APP}"

if   [ -f "$APP_DIR/pom.xml" ]; then TYPE=java
elif [ -f "$APP_DIR/pyproject.toml" ] || ls "$APP_DIR"/requirements*.txt >/dev/null 2>&1; then TYPE=python
else TYPE=generic; fi

case "$REF" in
  main|master|release/*) ENV=production; NS="$NAMESPACE_PRODUCTION"; PFX=prod ;;
  *)                     ENV=develop;    NS="$NAMESPACE_DEVELOP";    PFX=dev ;;
esac

CHART="$APP_DIR/$CHART_DIR"
[ -f "$CHART/Chart.yaml" ] || die "no Chart.yaml in $CHART"
for f in infra app; do
  [ -f "$APP_DIR/$ENVS_DIR/$ENV/$f.yaml" ] || die "missing $APP_DIR/$ENVS_DIR/$ENV/$f.yaml"
done

cat > "$SETUP_ENV_FILE" <<PLAN
PROJECT_TYPE=$TYPE
DEPLOY_ENV=$ENV
NAMESPACE=$NS
RELEASE=$APP
CHART_PATH=$CHART
VALUES_INFRA=$APP_DIR/$ENVS_DIR/$ENV/infra.yaml
VALUES_APP=$APP_DIR/$ENVS_DIR/$ENV/app.yaml
IMAGE_REPOSITORY=$REPO
NEW_TAG=$PFX-$RUN
PLAN

log "── Plan ($DEPLOYMENT_MODE, ref $REF) ──"
cat "$SETUP_ENV_FILE"
