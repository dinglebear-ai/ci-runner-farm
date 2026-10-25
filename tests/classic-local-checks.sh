#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp="$(mktemp -d)"
trap 'rm -rf -- "$task_tmp"' EXIT
export CRF_CFGDIR="$task_tmp/config" CRF_RUNDIR="$task_tmp/runtime" CRF_SOURCE_ONLY=1
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
source src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
reload_locked_snapshot() { :; }
shared_capacity_native_call() {
  [ "$#" -eq 1 ] && [ "$1" = local-checks ]
  [ -e "/proc/$BASHPID/fd/8" ]
  local body
  IFS= read -r body
  [ "$body" = 'fixture typed envelope' ]
  : > "$task_tmp/delegated"
}
printf '%s\n' 'fixture typed envelope' | cmd_classic_local_checks
[ -f "$task_tmp/delegated" ]
rm "$task_tmp/delegated"
if cmd_classic_local_checks /caller/path </dev/null; then
  echo 'classic local-checks accepted caller arguments' >&2; exit 1
fi
[ ! -e "$task_tmp/delegated" ]
printf '%s\n' 'classic local-checks owner wrapper passed'
