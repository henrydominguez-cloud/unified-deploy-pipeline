# shellcheck shell=sh
# Shared helpers for scripts/ci/*.sh. POSIX sh: runs on alpine, debian,
# fedora images and on a laptop. CI-neutral: detects GitLab or GitHub only
# for log grouping, never for behaviour.

log() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# need VAR...  -> fail fast if any variable is empty or unset
need() {
  for _v in "$@"; do
    eval "_val=\${$_v:-}"
    [ -n "$_val" ] || die "missing variable $_v"
  done
}

group_start() {
  if [ -n "${GITLAB_CI:-}" ]; then
    printf '\033[0Ksection_start:%s:%s[collapsed=true]\r\033[0K%s\n' "$(date +%s)" "$1" "$2"
  elif [ -n "${GITHUB_ACTIONS:-}" ]; then
    printf '::group::%s\n' "$2"
  else
    printf '── %s\n' "$2"
  fi
}

group_end() {
  if [ -n "${GITLAB_CI:-}" ]; then
    printf '\033[0Ksection_end:%s:%s\r\033[0K\n' "$(date +%s)" "$1"
  elif [ -n "${GITHUB_ACTIONS:-}" ]; then
    printf '::endgroup::\n'
  fi
}
