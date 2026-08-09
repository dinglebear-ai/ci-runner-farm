#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

. tests/lib/assert.sh

engine=src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

sed -n '/^cmd_validate()/,/^}/p' "$engine" >"$tmp/function.sh"
# shellcheck disable=SC1090,SC1091
. "$tmp/function.sh"

NAME_PREFIX=ci-runner
CACHE_ROOT="$tmp/cache"
GH_OWNER=acme
mkdir -p "$CACHE_ROOT/docker"

check_cache_root() { :; }
ensure_dirs() { :; }
registry_login() { :; }
pool_mode_enabled() { return 0; }
pool_records() { printf 'rust|ci-pool-rust|build|1|1|1|1|2000|4294967296\n'; }
effective_image() { printf 'test-image\n'; }
log() { :; }
err() { printf '%s\n' "$*" >>"$tmp/errors"; }
build_args() {
  printf '%s|%s|%s|%s\n' "$1" "$2" "${3:-}" "${4:-}" >"$tmp/build-args"
  [ "${3:-}" = rust ] && [ "${4:-}" = org:acme ] || return 1
  mkdir -p "$CACHE_ROOT/docker/$2" "$CACHE_ROOT/work/$2" "$CACHE_ROOT/dind-logs/$2"
  ARGS=(--name "$2" test-image)
}
docker() {
  case "${1:-}" in
    rm) return 0 ;;
    run)
      printf '%s\n' "$@" >"$tmp/docker-run"
      grep -Fxq test-image "$tmp/docker-run" || return 1
      ;;
    inspect) printf 'verified\n' ;;
    exec) printf 'no socket\n' ;;
    *) return 1 ;;
  esac
}

cmd_validate || crf_fail 'pool-mode runtime validation did not build a runnable probe'
crf_assert_eq '99|ci-runner-validate|rust|org:acme' "$(cat "$tmp/build-args")" \
  'runtime validation did not select the first configured pool and its organization scope'
crf_assert_contains "$(cat "$tmp/docker-run")" '--entrypoint' \
  'runtime validation did not replace the runner entrypoint'
for artifact in docker work dind-logs; do
  [ ! -e "$CACHE_ROOT/$artifact/ci-runner-validate" ] ||
    crf_fail "runtime validation left its $artifact artifact behind"
done

echo 'validate-runtime: OK'
