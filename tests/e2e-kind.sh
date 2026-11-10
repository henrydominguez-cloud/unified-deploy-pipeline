#!/bin/sh
# End-to-end test of the four modes on a local kind cluster, using the same
# scripts/ci/*.sh the pipeline runs. Asserts real cluster state after each
# step. Needs: docker (or Colima), kind, kubectl, helm, curl.
#
#   sh tests/e2e-kind.sh          # run, leave the release for inspection
#   CLEANUP=1 sh tests/e2e-kind.sh  # uninstall the release at the end
#
# Safety: it never uses your current kubectl context. It writes the kind
# cluster's kubeconfig to a temp file and points KUBECONFIG at it.
set -eu

CLUSTER="${KIND_CLUSTER:-unified-pipeline}"
ROOT="$(pwd)"
CI="$ROOT/scripts/ci"
TMP="$(mktemp -d)"
PF_PID=""
cleanup_tmp() {
  if [ -n "$PF_PID" ]; then kill "$PF_PID" 2>/dev/null || true; fi
  rm -rf "$TMP"
}
trap cleanup_tmp EXIT
pass=0; fail=0

ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
nok()  { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else nok "$1: expected '$3', got '$2'"; fi; }
step() { printf '\n▶ %s\n' "$1"; }
# NOTE: never write `VAR=x run ...`. In POSIX mode (macOS /bin/sh = bash 3.2)
# an assignment before a *function* call stays set after it returns and leaks
# into the next step. Pass variables with `run env VAR=x cmd` instead.
# run CMD... : show only the last line, but the full log and exit 1 on failure
run()  { "$@" > "$TMP/run.log" 2>&1 || { cat "$TMP/run.log"; echo "ERROR: step failed"; exit 1; }; tail -1 "$TMP/run.log"; }

# ── 0. Prerequisites ──────────────────────────────────────────────────
step "0/6 prerequisites"
for t in docker kind kubectl helm curl; do
  command -v "$t" >/dev/null || { echo "ERROR: $t not found"; exit 1; }
done
docker info >/dev/null 2>&1 || { echo "ERROR: docker daemon not reachable (colima start?)"; exit 1; }
echo "  helm $(helm version --short)"
if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  kind create cluster --name "$CLUSTER"
fi
kind get kubeconfig --name "$CLUSTER" > "$TMP/kubeconfig"
export KUBECONFIG="$TMP/kubeconfig"
echo "  cluster: $(kubectl config current-context)"

# ── Common env (same variables the pipeline sets) ─────────────────────
export APP_DIR=examples/sample-app APP_NAME=sample-app REF_NAME=develop \
       RUN_ID=e2e SETUP_ENV_FILE="$TMP/setup.env" CLUSTER_NAME="kind-$CLUSTER"
DEPLOYMENT_MODE=full sh "$CI/setup.sh" >/dev/null
set -a
# shellcheck source=/dev/null
. "$SETUP_ENV_FILE"
set +a
export IMAGE_REPOSITORY=sample-app       # local image name, loaded into kind

# ── Helpers that read real cluster state ──────────────────────────────
running_tag() {
  img="$(kubectl -n "$NAMESPACE" get deploy "$RELEASE" \
        -o jsonpath='{.spec.template.spec.containers[0].image}')"
  echo "${img##*:}"
}
# generation changes only when the pod template changes = pods restart
generation() { kubectl -n "$NAMESPACE" get deploy "$RELEASE" -o jsonpath='{.metadata.generation}'; }
revision()   { helm history "$RELEASE" -n "$NAMESPACE" --max 1 -o json | sed -n 's/.*"revision":\([0-9]*\).*/\1/p'; }
# Ground truth for "which values did helm apply": the ConfigMap itself.
cm_greeting() {
  kubectl -n "$NAMESPACE" get configmap "$RELEASE-config" -o jsonpath='{.data.GREETING}'
}
# Name of a pod that is NOT terminating. After a rollout the old pod can stay
# in Terminating for a while; `port-forward svc/...` may pick that old pod, so
# the test always targets a live one explicitly.
live_pod() {
  kubectl -n "$NAMESPACE" get pods -l "app.kubernetes.io/name=$RELEASE" \
    -o go-template='{{range .items}}{{if not .metadata.deletionTimestamp}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' \
    | head -1
}
# greeting EXPECTED : what the running app answers; polls up to ~20 s and
# prints the last value seen
greeting() {
  want="$1"; got=""; i=0
  while [ $i -lt 10 ]; do
    pod="$(live_pod)"
    if [ -n "$pod" ]; then
      kubectl -n "$NAMESPACE" port-forward "pod/$pod" 18080:8080 >/dev/null 2>&1 &
      PF_PID=$!
      sleep 1
      got="$(curl -fsS --max-time 3 localhost:18080/ 2>/dev/null \
            | sed -n 's/.*"greeting": "\([^"]*\)".*/\1/p')" || true
      kill "$PF_PID" 2>/dev/null || true; wait "$PF_PID" 2>/dev/null || true; PF_PID=""
    fi
    [ "$got" = "$want" ] && break
    i=$((i + 1)); sleep 1
  done
  printf '%s' "$got"
}
load_image() {   # load_image TAG
  kind load docker-image "sample-app:$1" --name "$CLUSTER" >/dev/null
}

# Start from a clean release so revision numbers are predictable.
helm uninstall "$RELEASE" -n "$NAMESPACE" --wait >/dev/null 2>&1 || true

# ── 1. full ───────────────────────────────────────────────────────────
step "1/6 full: build image local-1, deploy, smoke"
run env NEW_TAG=local-1 BUILDER=docker PUSH=false sh "$CI/build.sh"
load_image local-1
run env DEPLOYMENT_MODE=full NEW_TAG=local-1 sh "$CI/deploy.sh"
run sh "$CI/smoke.sh"
eq "image tag"      "$(running_tag)" "local-1"
eq "greeting"       "$(greeting "hello from develop")" "hello from develop"
eq "helm revision"  "$(revision)"    "1"
GEN1="$(generation)"

# ── 2. config_only, nothing changed ───────────────────────────────────
step "2/6 config_only with identical values: no rebuild, no restart"
run env DEPLOYMENT_MODE=config_only sh "$CI/deploy.sh"
eq "image tag kept"     "$(running_tag)" "local-1"
eq "pods not restarted" "$(generation)"  "$GEN1"
eq "helm revision"      "$(revision)"    "2"

# ── 3. config_only, app.yaml changed ──────────────────────────────────
# Uses a temp copy: the repo file is never modified.
step "3/6 config_only with a changed greeting: same image, pods roll"
sed 's/hello from develop/hello from config_only/' "$VALUES_APP" > "$TMP/app.yaml"
run env DEPLOYMENT_MODE=config_only VALUES_APP="$TMP/app.yaml" sh "$CI/deploy.sh"
eq "image tag kept"  "$(running_tag)" "local-1"
GEN3="$(generation)"
if [ "$GEN3" != "$GEN1" ]; then ok "pods restarted (generation $GEN1 -> $GEN3)"; else nok "pods did not restart"; fi
eq "configmap updated" "$(cm_greeting)" "hello from config_only"
eq "app serves new greeting" "$(greeting "hello from config_only")" "hello from config_only"
eq "helm revision"   "$(revision)"    "3"

# ── 4. deploy_image ───────────────────────────────────────────────────
# Simulates an image that already exists in the registry: retag, no build.
step "4/6 deploy_image local-2 (existing image, no build)"
docker tag sample-app:local-1 sample-app:local-2
load_image local-2
run env DEPLOYMENT_MODE=deploy_image IMAGE_TAG=local-2 sh "$CI/deploy.sh"
eq "image tag"      "$(running_tag)" "local-2"
eq "configmap = repo values again (no --reuse-values)" "$(cm_greeting)" "hello from develop"
eq "app serves repo greeting" "$(greeting "hello from develop")" "hello from develop"
eq "helm revision"  "$(revision)"    "4"

# ── 5. rollback to previous ───────────────────────────────────────────
step "5/6 rollback (previous revision = 3)"
run sh "$CI/rollback.sh"
eq "image tag back" "$(running_tag)" "local-1"
eq "greeting back"  "$(greeting "hello from config_only")" "hello from config_only"

# ── 6. rollback to a chosen revision ──────────────────────────────────
step "6/6 rollback to revision 1"
run env ROLLBACK_TO_REVISION=1 sh "$CI/rollback.sh"
eq "image tag"      "$(running_tag)" "local-1"
eq "greeting rev 1" "$(greeting "hello from develop")" "hello from develop"

printf '\nhelm history:\n'
helm history "$RELEASE" -n "$NAMESPACE"

if [ "${CLEANUP:-0}" = "1" ]; then
  helm uninstall "$RELEASE" -n "$NAMESPACE" --wait >/dev/null
  echo "release uninstalled (cluster kept; 'make kind-down' deletes it)"
fi

printf '\nE2E: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
