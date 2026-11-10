#!/bin/sh
# Build $IMAGE_REPOSITORY:$NEW_TAG and (unless PUSH=false) push it.
# BUILDER=buildah (default, daemonless) | docker (GitHub runners, laptops).
# Registry login only when pushing and REGISTRY_PASSWORD is set.
set -eu
# shellcheck source=scripts/ci/lib.sh
. "$(dirname "$0")/lib.sh"
need APP_DIR IMAGE_REPOSITORY NEW_TAG
B="${BUILDER:-buildah}"
PUSH="${PUSH:-true}"
IMG="$IMAGE_REPOSITORY:$NEW_TAG"

set -- build -f "$APP_DIR/Dockerfile" -t "$IMG"
# On GitHub, this label links the ghcr.io package to the repository.
if [ -n "${GITHUB_REPOSITORY:-}" ]; then
  set -- "$@" --label "org.opencontainers.image.source=https://github.com/$GITHUB_REPOSITORY"
fi

if [ "$PUSH" = "true" ] && [ -n "${REGISTRY_PASSWORD:-}" ]; then
  need REGISTRY REGISTRY_USER
  printf '%s' "$REGISTRY_PASSWORD" | "$B" login -u "$REGISTRY_USER" --password-stdin "$REGISTRY"
fi
"$B" "$@" "$APP_DIR"
if [ "$PUSH" = "true" ]; then
  "$B" push "$IMG"
  log "BUILT and PUSHED $IMG"
else
  log "BUILT $IMG (not pushed)"
fi
