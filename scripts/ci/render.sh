#!/bin/sh
# helm lint + render the chart with the values chain. Output: rendered.yaml.
# Chain (last wins): chart/values.yaml -> infra.yaml -> app.yaml -> --set image.*
set -eu
# shellcheck source=scripts/ci/lib.sh
. "$(dirname "$0")/lib.sh"
need RELEASE CHART_PATH NAMESPACE VALUES_INFRA VALUES_APP IMAGE_REPOSITORY NEW_TAG
OUT="${RENDER_OUT:-rendered.yaml}"

helm lint "$CHART_PATH" -f "$VALUES_INFRA" -f "$VALUES_APP"
helm template "$RELEASE" "$CHART_PATH" -n "$NAMESPACE" \
  -f "$VALUES_INFRA" -f "$VALUES_APP" \
  --set image.repository="$IMAGE_REPOSITORY" --set image.tag="$NEW_TAG" > "$OUT"
log "Rendered $(grep -c '^kind:' "$OUT") objects -> $OUT"
