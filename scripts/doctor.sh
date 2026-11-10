#!/bin/sh
# Check that this machine has what the local targets need, before you spend
# time on a failing run. Prints one line per tool and an install hint.
#
#   sh scripts/doctor.sh          # everything
#   sh scripts/doctor.sh quick    # only what `make test test-scripts lint` needs
set -u

MODE="${1:-full}"
missing=0

if command -v brew >/dev/null 2>&1; then PKG="brew install"; else PKG="install"; fi

check() {   # check NAME HINT [VERSION_CMD...]
  name="$1"; hint="$2"; shift 2
  if command -v "$name" >/dev/null 2>&1; then
    ver=""
    if [ $# -gt 0 ]; then ver="$("$@" 2>/dev/null | head -1)"; fi
    printf '  ok       %-11s %s\n' "$name" "$ver"
  else
    printf '  MISSING  %-11s -> %s\n' "$name" "$hint"
    missing=$((missing + 1))
  fi
}

echo "Quick checks (make test test-scripts lint render sanitize):"
check python3    "$PKG python"      python3 --version
if python3 -m pytest --version >/dev/null 2>&1; then
  printf '  ok       %-11s %s\n' pytest "$(python3 -m pytest --version 2>&1 | head -1)"
else
  printf '  MISSING  %-11s -> %s\n' pytest "python3 -m venv ~/.venvs/unified-pipeline && . ~/.venvs/unified-pipeline/bin/activate && pip install pytest yamllint"
  missing=$((missing + 1))
fi
check yamllint   "$PKG yamllint"    yamllint --version
check shellcheck "$PKG shellcheck"  shellcheck --version
check helm       "$PKG helm"        helm version --short
check git        "$PKG git"         git --version
# shellcheck disable=SC2016
check bash       "$PKG bash"        bash -c 'echo "bash $BASH_VERSION"'

if [ "$MODE" != "quick" ]; then
  echo "End-to-end checks (make e2e):"
  check docker   "$PKG docker colima  (then: colima start)" docker --version
  check kind     "$PKG kind"        kind version
  check kubectl  "$PKG kubectl"     kubectl version --client
  check curl     "$PKG curl"        curl --version
  if command -v docker >/dev/null 2>&1; then
    if docker info >/dev/null 2>&1; then
      printf '  ok       %-11s daemon reachable\n' "docker"
    else
      printf '  MISSING  %-11s -> daemon not reachable (colima start, or open Docker Desktop)\n' "docker"
      missing=$((missing + 1))
    fi
  fi
fi

if [ "$missing" -eq 0 ]; then
  echo "DOCTOR OK"
else
  echo "DOCTOR: $missing problem(s) — fix them and run again"
  exit 1
fi
