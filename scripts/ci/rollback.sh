#!/bin/sh
# Roll back the Helm release. ROLLBACK_TO_REVISION empty = previous revision.
set -eu
# shellcheck source=scripts/ci/lib.sh
. "$(dirname "$0")/lib.sh"
need RELEASE NAMESPACE

helm history "$RELEASE" -n "$NAMESPACE" --max 10
if [ -n "${ROLLBACK_TO_REVISION:-}" ]; then
  helm rollback "$RELEASE" "$ROLLBACK_TO_REVISION" -n "$NAMESPACE" --wait --timeout 5m
else
  helm rollback "$RELEASE" -n "$NAMESPACE" --wait --timeout 5m
fi
kubectl -n "$NAMESPACE" rollout status "deploy/$RELEASE" --timeout=300s
helm history "$RELEASE" -n "$NAMESPACE" --max 3
log "ROLLBACK OK · $RELEASE · ${CLUSTER_NAME:-local}"
