#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1090 # variables and dynamic paths feed sourced modules
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib/assert.sh

engine=src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
jit=src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-jit.sh
scalesets=src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-scalesets.sh
ownership=tools/crf-scaleset/internal/ownership/ownership.go
event=src/usr/local/emhttp/plugins/ci-runner-farm/event/docker_started
builder=build-plg.sh

grep -Fq 'RUNDIR="/var/local/emhttp/${PLUGIN}"' "$engine" ||
  crf_fail "runtime directory is not rooted on Unraid rootfs/tmpfs"
grep -Fq 'nohup "$0" autoscale-daemon >>"${RUNDIR}/autoscale.log"' "$engine" ||
  crf_fail "autoscale log is not on runtime storage"
grep -Fq 'nohup "$0" imageupdate-daemon >>"${RUNDIR}/imageupdate.log"' "$engine" ||
  crf_fail "image-update log is not on runtime storage"
grep -Fq 'bt="$RUNDIR/boot.log"' "$engine" ||
  crf_fail "fleet boot log reader is not on runtime storage"
grep -Fq 'RUNDIR="/var/local/emhttp/ci-runner-farm"' "$event" ||
  crf_fail "Docker-start hook has no runtime directory"
grep -Fq '>>"$RUNDIR/boot.log"' "$event" ||
  crf_fail "Docker-start hook writes boot logs to flash"
grep -Fq 'RUNDIR="/var/local/emhttp/${NAME}"' "$builder" ||
  crf_fail "plugin install has no runtime directory"
grep -Fq '>>"\$RUNDIR/boot.log"' "$builder" ||
  crf_fail "plugin install writes boot logs to flash"
grep -Fq 'SCALESET_STATE_DIR="${SCALESET_STATE_DIR:-$RUNDIR/scalesets}"' "$scalesets" ||
  crf_fail "scale-set hot state is not on runtime storage"
grep -Fq 'SCALESET_DURABLE_STATE_DIR="$CACHE_ROOT/state/scalesets"' "$scalesets" ||
  crf_fail "scale-set durable state does not follow CACHE_ROOT"
grep -Fq 'JIT_STATE_DIR="$CACHE_ROOT/state/jit"' "$jit" ||
  crf_fail "JIT durable state does not follow CACHE_ROOT"
grep -Fq 'JIT_LOG_ROOT="$CACHE_ROOT/logs/runners"' "$jit" ||
  crf_fail "JIT diagnostics do not follow CACHE_ROOT"
grep -Fq 'JIT_RECENT_ACTIVITY_FILE="${JIT_RECENT_ACTIVITY_FILE:-$RUNDIR/recent-jobs.jsonl}"' "$jit" ||
  crf_fail "recent one-shot activity is not on runtime tmpfs"
grep -Fq "! -path './bin/.crf-scaleset.rollback-*'" "$scalesets" ||
  crf_fail "rollback helpers can poison the packaged identity digest"
grep -Fq 'slices.Equal(record.AppliedLabels, labels) && record.State == targetState' "$ownership" ||
  crf_fail "no-op ownership reconciliation can rewrite flash state"

for runtime_file in \
  autoscale.log autoscale.pid autoscale.state imageupdate.log imageupdate.pid \
  boot.log queued.snapshot.json queued.lock cache-usage.cache usage.cache stats.cache sec.cache warn.cache build.log build.lock \
  recent-jobs.jsonl recent-jobs.jsonl.lock; do
  if rg -F "/boot/config/plugins/ci-runner-farm/$runtime_file" src/usr/local/emhttp/plugins/ci-runner-farm >/dev/null ||
     rg -F "\$CFGDIR/$runtime_file" src/usr/local/emhttp/plugins/ci-runner-farm >/dev/null ||
     rg -F "\$CFGDIR/$runtime_file" "$builder" >/dev/null; then
    crf_fail "runtime file $runtime_file targets the Unraid boot flash"
  fi
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
(
  RUNDIR="$tmp/run"
  CFGDIR="$tmp/cfg"
  SCRIPT_DIR="$PWD/src/usr/local/emhttp/plugins/ci-runner-farm/include"
  CACHE_ROOT="$tmp/bootstrap"
  NAME_PREFIX=ci-runner
  LABEL_NS=net.unraid.ci-runner-farm
  unset JIT_STATE_DIR JIT_LOG_ROOT JIT_BOOTSTRAP_STATE_DIR JIT_LEGACY_STATE_DIR
  mkdir -p "$RUNDIR" "$CFGDIR" "$CACHE_ROOT"
  pool_id_valid(){ [[ "$1" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; }
  . "$jit"
  [ "$JIT_STATE_DIR" = "$tmp/bootstrap/state/jit" ] || crf_fail "JIT bootstrap path mismatch"
  CACHE_ROOT="$tmp/configured"
  jit_paths_refresh
  [ "$JIT_STATE_DIR" = "$tmp/configured/state/jit" ] || crf_fail "JIT state ignored configured CACHE_ROOT"
  [ "$JIT_LOG_ROOT" = "$tmp/configured/logs/runners" ] || crf_fail "JIT logs ignored configured CACHE_ROOT"
  [ "$JIT_RECENT_ACTIVITY_FILE" = "$RUNDIR/recent-jobs.jsonl" ] ||
    crf_fail "recent activity ignored runtime tmpfs"
)
(
  RUNDIR="$tmp/run2"
  CFGDIR="$tmp/cfg2"
  SCRIPT_DIR="$PWD/src/usr/local/emhttp/plugins/ci-runner-farm/include"
  CACHE_ROOT="$tmp/bootstrap2"
  unset SCALESET_DURABLE_STATE_DIR SCALESET_DURABLE_BOOTSTRAP_STATE_DIR
  mkdir -p "$RUNDIR" "$CFGDIR" "$CACHE_ROOT/state/scalesets/replay"
  printf 'proof\n' >"$CACHE_ROOT/state/scalesets/replay/messages.jsonl"
  err(){ printf '%s\n' "$*" >&2; }
  log(){ :; }
  . "$scalesets"
  CACHE_ROOT="$tmp/configured2"
  scaleset_paths_refresh
  scaleset_import_bootstrap_durable_state
  [ -f "$tmp/configured2/state/scalesets/replay/messages.jsonl" ] ||
    crf_fail "scale-set replay proof was not migrated to configured CACHE_ROOT"
  [ ! -d "$tmp/bootstrap2/state/scalesets" ] ||
    crf_fail "legacy durable state remained active after migration"
)

echo "flash-write-paths: OK"
