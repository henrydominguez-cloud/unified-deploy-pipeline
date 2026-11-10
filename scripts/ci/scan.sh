#!/bin/sh
# Scan $IMAGE_REPOSITORY:$NEW_TAG with grype (must be on PATH).
# Advisory by default; SECURITY_SCAN_STRICT=true fails on critical CVEs.
# Registry auth: set GRYPE_REGISTRY_AUTH_* in the caller.
set -eu
# shellcheck source=scripts/ci/lib.sh
. "$(dirname "$0")/lib.sh"
need IMAGE_REPOSITORY NEW_TAG
command -v grype >/dev/null || die "grype not found on PATH"
SRC="registry:$IMAGE_REPOSITORY:$NEW_TAG"

if [ "${SECURITY_SCAN_STRICT:-false}" = "true" ]; then
  grype "$SRC" -o json --file grype.json --fail-on critical
else
  grype "$SRC" -o json --file grype.json
fi
grype "$SRC" -o table
