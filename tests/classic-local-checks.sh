#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp="$(mktemp -d)"
trap 'rm -rf -- "$task_tmp"' EXIT
export CRF_CFGDIR="$task_tmp/config" CRF_RUNDIR="$task_tmp/runtime" CRF_SOURCE_ONLY=1
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
source src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
reload_locked_snapshot() { : > "$task_tmp/snapshot-reloaded"; }
mkdir -p "$task_tmp/plugin/bin" "$task_tmp/plugin/include"
SCRIPT_DIR="$task_tmp/plugin/include"
export CLASSIC_FIXTURE_ROOT="$task_tmp"
cat > "$task_tmp/plugin/bin/ci-runner-capacity" <<'FIXTURE'
#!/bin/bash
set -euo pipefail
[ "$#" -eq 1 ] && [ "$1" = local-checks ]
[ "$BASHPID" = "$CLASSIC_FIXTURE_PID" ]
[ -e "/proc/$BASHPID/fd/8" ]
[ -e "$CLASSIC_FIXTURE_ROOT/snapshot-reloaded" ]
IFS= read -r body
[ "$body" = 'fixture typed envelope' ]
: > "$CLASSIC_FIXTURE_ROOT/delegated"
FIXTURE
chmod 700 "$task_tmp/plugin/bin/ci-runner-capacity"
printf '%s\n' 'fixture typed envelope' > "$task_tmp/input"
(
 export CLASSIC_FIXTURE_PID="$BASHPID"
 cmd_classic_local_checks < "$task_tmp/input"
)
[ -f "$task_tmp/delegated" ]
rm "$task_tmp/delegated"
if cmd_classic_local_checks /caller/path </dev/null; then
  echo 'classic local-checks accepted caller arguments' >&2; exit 1
fi
[ ! -e "$task_tmp/delegated" ]
printf '%s\n' 'classic local-checks owner wrapper passed'
