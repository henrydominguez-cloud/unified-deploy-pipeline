#!/bin/sh
# Tests for scripts/ci/*.sh without a cluster: helm and kubectl are replaced
# by stubs that record their arguments. Checks the exact commands each mode
# produces. Run from the repo root:  sh tests/ci-scripts.sh
set -eu

ROOT="$(pwd)"
CI="$ROOT/scripts/ci"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
CALLS="$TMP/calls.log"
pass=0; fail=0

# ── stubs ───────────────────────────────────────────────────────────
cat > "$TMP/bin/helm" <<'STUB'
#!/bin/sh
echo "helm $*" >> "$CALLS"
if [ "$1" = "version" ]; then echo "${FAKE_HELM_VERSION:-v3.16.4+gabc}"; fi
STUB
cat > "$TMP/bin/kubectl" <<'STUB'
#!/bin/sh
echo "kubectl $*" >> "$CALLS"
case "$*" in
  *jsonpath*) printf 'registry.example.com/sample-app:dev-7' ;;
  *current-context*) echo stub-cluster ;;
esac
STUB
# shellcheck disable=SC2016
for t in docker grype; do
  printf '#!/bin/sh\necho "%s $*" >> "$CALLS"\n' "$t" > "$TMP/bin/$t"
done
chmod +x "$TMP/bin/helm" "$TMP/bin/kubectl" "$TMP/bin/docker" "$TMP/bin/grype"
export PATH="$TMP/bin:$PATH" CALLS

# Clean environment: no CI built-ins leak into the tests.
unset GITLAB_CI GITHUB_ACTIONS CI_COMMIT_REF_NAME CI_PIPELINE_ID CI_PROJECT_NAME \
      CI_REGISTRY_IMAGE GITHUB_REPOSITORY GITHUB_REF_NAME GITHUB_RUN_ID 2>/dev/null || true
export APP_DIR=examples/sample-app APP_NAME=sample-app RUN_ID=42 SETUP_ENV_FILE="$TMP/setup.env"

ok()   { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
nok()  { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
has()  { if grep -qF -- "$2" "$3"; then ok "$1"; else nok "$1 (expected: $2)"; fi; }
hasnt(){ if grep -qF -- "$2" "$3"; then nok "$1 (unexpected: $2)"; else ok "$1"; fi; }

plan() {   # plan REF MODE [IMAGE_TAG]
  : > "$CALLS"
  REF_NAME="$1" DEPLOYMENT_MODE="$2" IMAGE_TAG="${3:-}" sh "$CI/setup.sh" >/dev/null
  set -a
  # shellcheck source=/dev/null
  . "$SETUP_ENV_FILE"
  set +a
  export DEPLOYMENT_MODE="$2" IMAGE_TAG="${3:-}"
}

# ── setup ───────────────────────────────────────────────────────────
plan feature/login full
has "setup: feature branch -> develop"     "DEPLOY_ENV=develop"      "$SETUP_ENV_FILE"
has "setup: detects python"                "PROJECT_TYPE=python"     "$SETUP_ENV_FILE"
has "setup: tag uses run id"               "NEW_TAG=dev-42"          "$SETUP_ENV_FILE"
has "setup: local image base"              "IMAGE_REPOSITORY=local/sample-app" "$SETUP_ENV_FILE"

plan main full
has "setup: main -> production"            "NAMESPACE=production"    "$SETUP_ENV_FILE"
has "setup: production values files"       "envs/production/app.yaml" "$SETUP_ENV_FILE"

GITHUB_REPOSITORY=You/Unified-Pipeline REF_NAME=develop sh "$CI/setup.sh" >/dev/null
has "setup: github -> lowercase ghcr"      "IMAGE_REPOSITORY=ghcr.io/you/unified-pipeline/sample-app" "$SETUP_ENV_FILE"

if DEPLOYMENT_MODE=deploy_image IMAGE_TAG="" sh "$CI/setup.sh" >/dev/null 2>&1; then
  nok "setup: deploy_image without IMAGE_TAG must fail"
else ok "setup: deploy_image without IMAGE_TAG fails"; fi

if DEPLOYMENT_MODE=yolo sh "$CI/setup.sh" >/dev/null 2>&1; then
  nok "setup: unknown mode must fail"
else ok "setup: unknown mode fails"; fi

# ── build + scan ────────────────────────────────────────────────────
plan feature/login full
BUILDER=docker PUSH=false sh "$CI/build.sh" >/dev/null
has   "build: builds the planned tag"      "docker build -f examples/sample-app/Dockerfile -t local/sample-app:dev-42" "$CALLS"
hasnt "build: PUSH=false does not push"    "docker push"             "$CALLS"

: > "$CALLS"
BUILDER=docker GITHUB_REPOSITORY=you/repo sh "$CI/build.sh" >/dev/null
has   "build: pushes by default"           "docker push local/sample-app:dev-42" "$CALLS"
has   "build: github source label"         "org.opencontainers.image.source=https://github.com/you/repo" "$CALLS"

: > "$CALLS"
SCAN_SOURCE=docker sh "$CI/scan.sh" >/dev/null
has   "scan: local image source"           "grype docker:local/sample-app:dev-42" "$CALLS"
rm -f grype.json

# ── deploy ──────────────────────────────────────────────────────────
plan feature/login full
sh "$CI/deploy.sh" >/dev/null
has   "full: upgrade --install"            "helm upgrade --install --create-namespace sample-app" "$CALLS"
has   "full: deploys the new tag"          "image.tag=dev-42"        "$CALLS"
has   "full: values chain order"           "-f examples/sample-app/envs/develop/infra.yaml -f examples/sample-app/envs/develop/app.yaml" "$CALLS"
hasnt "full: no --reuse-values"            "--reuse-values"          "$CALLS"
has   "full: helm 3 uses --atomic"         "--atomic --wait"         "$CALLS"

: > "$CALLS"
FAKE_HELM_VERSION="v4.0.1+gdef" sh "$CI/deploy.sh" >/dev/null
has   "full: helm 4 uses new flag"         "--rollback-on-failure --wait" "$CALLS"
hasnt "full: helm 4 avoids --atomic"       "--atomic"                "$CALLS"

plan feature/login config_only
sh "$CI/deploy.sh" >/dev/null
has   "config_only: reads running image"   "kubectl -n develop get deploy sample-app" "$CALLS"
has   "config_only: keeps running tag"     "image.tag=dev-7"         "$CALLS"
hasnt "config_only: no --install"          "--install"               "$CALLS"

plan main deploy_image prod-99
sh "$CI/deploy.sh" >/dev/null
has   "deploy_image: uses IMAGE_TAG"       "image.tag=prod-99"       "$CALLS"
has   "deploy_image: production ns"        "-n production"           "$CALLS"

# ── rollback ────────────────────────────────────────────────────────
plan main rollback
sh "$CI/rollback.sh" >/dev/null
has   "rollback: previous revision"        "helm rollback sample-app -n production" "$CALLS"

: > "$CALLS"
ROLLBACK_TO_REVISION=3 sh "$CI/rollback.sh" >/dev/null
has   "rollback: chosen revision"          "helm rollback sample-app 3 -n production" "$CALLS"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
