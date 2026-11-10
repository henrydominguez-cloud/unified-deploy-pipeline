#!/bin/sh
# Wait for the rollout, then curl the service from inside the namespace.
set -eu
# shellcheck source=scripts/ci/lib.sh
. "$(dirname "$0")/lib.sh"
need RELEASE NAMESPACE
PORT="${SMOKE_PORT:-80}"
URL_PATH="${SMOKE_PATH:-/healthz}"
IMAGE="${CURL_IMAGE:-docker.io/curlimages/curl:8.11.1}"
RUN="${RUN_ID:-${CI_JOB_ID:-${GITHUB_RUN_ID:-local}}}"

kubectl -n "$NAMESPACE" rollout status "deploy/$RELEASE" --timeout=120s
kubectl -n "$NAMESPACE" run "smoke-$RUN" --rm -i --restart=Never --image="$IMAGE" -- \
  curl -fsS --max-time 10 "http://$RELEASE.$NAMESPACE.svc:$PORT$URL_PATH"
log "SMOKE OK · $RELEASE · ${CLUSTER_NAME:-local}"
