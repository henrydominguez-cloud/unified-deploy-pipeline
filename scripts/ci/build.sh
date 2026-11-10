#!/bin/sh
# Build and push $IMAGE_REPOSITORY:$NEW_TAG.
# BUILDER=buildah (default, daemonless) | docker (GitHub runners, laptops).
# Registry login only if REGISTRY_PASSWORD is set.
set -eu
# shellcheck source=scripts/ci/lib.sh
. "$(dirname "$0")/lib.sh"
need APP_DIR IMAGE_REPOSITORY NEW_TAG
B="${BUILDER:-buildah}"
IMG="$IMAGE_REPOSITORY:$NEW_TAG"

if [ -n "${REGISTRY_PASSWORD:-}" ]; then
  need REGISTRY REGISTRY_USER
  printf '%s' "$REGISTRY_PASSWORD" | "$B" login -u "$REGISTRY_USER" --password-stdin "$REGISTRY"
fi
"$B" build -f "$APP_DIR/Dockerfile" -t "$IMG" "$APP_DIR"
if [ "${PUSH:-true}" = "true" ]; then "$B" push "$IMG"; fi
log "BUILT $IMG"
