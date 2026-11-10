#!/bin/sh
# Deploy with helm according to DEPLOYMENT_MODE. Uses the current KUBECONFIG.
#   full          -> NEW_TAG (just built)
#   deploy_image  -> IMAGE_TAG (already in the registry)
#   config_only   -> the tag running now; only values change
# No --reuse-values: the repo's values are re-applied on every deploy.
set -eu
# shellcheck source=scripts/ci/lib.sh
. "$(dirname "$0")/lib.sh"
need DEPLOYMENT_MODE RELEASE CHART_PATH NAMESPACE VALUES_INFRA VALUES_APP IMAGE_REPOSITORY
CLUSTER="${CLUSTER_NAME:-$(kubectl config current-context 2>/dev/null || echo unknown)}"

case "$DEPLOYMENT_MODE" in
  full)
    need NEW_TAG
    TAG="$NEW_TAG"
    set -- upgrade --install --create-namespace ;;
  deploy_image)
    need IMAGE_TAG
    TAG="$IMAGE_TAG"
    set -- upgrade --install --create-namespace ;;
  config_only)
    IMG="$(kubectl -n "$NAMESPACE" get deploy "$RELEASE" \
          -o jsonpath='{.spec.template.spec.containers[0].image}')"
    TAG="${IMG##*:}"
    set -- upgrade ;;
  *) die "deploy.sh does not handle DEPLOYMENT_MODE=$DEPLOYMENT_MODE" ;;
esac
[ -n "$TAG" ] || die "could not resolve image tag"
# Helm 4 renamed --atomic to --rollback-on-failure (old name is deprecated).
case "$(helm version --short 2>/dev/null || true)" in
  v3*|"") SAFE="--atomic" ;;
  *)      SAFE="--rollback-on-failure" ;;
esac

log "Deploying $RELEASE -> $CLUSTER/$NAMESPACE with tag $TAG ($DEPLOYMENT_MODE)"

helm "$@" "$RELEASE" "$CHART_PATH" -n "$NAMESPACE" \
  -f "$VALUES_INFRA" -f "$VALUES_APP" \
  --set image.repository="$IMAGE_REPOSITORY" \
  --set image.tag="$TAG" \
  "$SAFE" --wait --timeout "${HELM_TIMEOUT:-5m}"

helm history "$RELEASE" -n "$NAMESPACE" --max 3
log "DEPLOY OK · $RELEASE · $CLUSTER · $NAMESPACE · $TAG · $DEPLOYMENT_MODE"
