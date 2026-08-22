#!/usr/bin/env bash
# Final offline/package gate. A live compatibility record is optional for normal
# CI, but CRF_REQUIRE_LIVE_GATE=1 makes the exact packaged-identity proof
# mandatory before an operator can claim scale-set activation.
set -euo pipefail
cd "$(dirname "$0")/.."

. tests/lib/assert.sh

pools=src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-pools.sh
scheduler=src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-scheduler.sh
scalesets=src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-scalesets.sh
protocol=tools/crf-scaleset/internal/protocol/protocol.go
supervisor=tools/crf-scaleset/internal/supervisor/supervisor.go

# Numeric and identity budgets locked by the standalone plan.
grep -Fq 'POOL_MAX_COUNT=8' "$pools" || crf_fail "eight-pool limit drifted"
grep -Fq 'POOL_HARD_MAX=64' "$pools" || crf_fail "emergency fuse drifted"
grep -Fq 'POOL_CONFIG_MAX_BYTES=16384' "$pools" || crf_fail "pool config byte limit drifted"
grep -Fq 'MaxFrameBytes = 1 << 20' "$protocol" || crf_fail "IPC 1 MiB hard limit drifted"
grep -Fq 'len(s.Pools) > 8' "$protocol" || crf_fail "snapshot pool bound missing"
grep -Fq 'len(cfg.Pools) > 8' "$supervisor" || crf_fail "session goroutine bound missing"
grep -Fq 'cfg.Heartbeat > 10*time.Second' "$supervisor" || crf_fail "heartbeat limit drifted"
grep -Fq 'ValidUntil: now.Add(2 * s.cfg.Heartbeat)' "$supervisor" ||
  crf_fail "control snapshot two-heartbeat staleness missing"
grep -Fq 'cfg.DemandTTL = 90 * time.Second' "$supervisor" ||
  crf_fail "bounded GitHub long-poll demand TTL drifted"
grep -Fq 'result.ValidUntil = now.Add(s.cfg.DemandTTL)' "$supervisor" ||
  crf_fail "pool demand expires before the bounded long-poll window"
grep -Fq 'make(chan protocol.PoolSnapshot, len(s.cfg.Pools))' "$supervisor" ||
  crf_fail "per-pool long-poll result bound missing"
grep -Fq 'MaxJournalBytes int64 = 8 << 20' \
  tools/crf-scaleset/internal/journal/journal.go ||
  crf_fail "eight MiB replay-journal cap drifted"
grep -Eq '^[[:space:]]*maxIssuedHandles[[:space:]]*=[[:space:]]*131072([[:space:]]|$)' \
  tools/crf-scaleset/internal/controller/controller.go ||
  crf_fail "issued-handle state cap drifted"
grep -Fq 'SCALESET_HELPER_LOG_MAX_BYTES="${SCALESET_HELPER_LOG_MAX_BYTES:-8388608}"' \
  "$scalesets" || crf_fail "eight MiB helper-log cap drifted"
grep -Fq 'SCALESET_OPERATION_MAX_FILES="${SCALESET_OPERATION_MAX_FILES:-32}"' \
  "$scalesets" || crf_fail "operation-record cap drifted"
grep -Fq 'SCALESET_DEMAND_TTL_MAX_SECONDS="${SCALESET_DEMAND_TTL_MAX_SECONDS:-120}"' \
  "$scalesets" || crf_fail "bounded shell demand TTL drifted"
grep -Fq "find . -type f ! -path './bin/.crf-scaleset.rollback-*' -print0" \
  "$scalesets" || crf_fail "plugin identity includes rollback helpers"
grep -Fq 'LC_ALL=C sort -z | xargs -0 sha256sum' "$scalesets" ||
  crf_fail "plugin identity is locale-sensitive"
grep -Fq 'soft_limit="${SCHEDULER_START_LIMIT:-2}" hard_limit=4' "$scheduler" ||
  crf_fail "two/four cold-start bounds drifted"
grep -Fq '"$(( $(date +%s) + 90 ))"' "$scalesets" ||
  crf_fail "capacity lease no longer spans a GitHub long-poll cycle"
grep -Fq 'JIT_LOG_MAX_BYTES="${JIT_LOG_MAX_BYTES:-268435456}"' \
  src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-jit.sh ||
  crf_fail "256 MiB diagnostic cap drifted"
grep -Fq 'JIT_LOG_MAX_DAYS="${JIT_LOG_MAX_DAYS:-7}"' \
  src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-jit.sh ||
  crf_fail "seven-day diagnostic cap drifted"
grep -Fq '30*24*time.Hour' tools/crf-scaleset/cmd/crf-scaleset/main.go ||
  crf_fail "30-day compatibility age drifted"
grep -Fq '035cda46ea086d5faaa13f4b17953112c1c7f295' \
  tools/crf-scaleset/cmd/crf-scaleset/main.go || crf_fail "scale-set module revision drifted"
grep -Fq 'github.com/actions/scaleset v0.4.0' tools/crf-scaleset/go.mod ||
  crf_fail "scale-set module version drifted"
grep -Fq 'github.com/dinglebear-ai/scaleset v0.4.1-0.20260822023756-035cda46ea08' \
  tools/crf-scaleset/go.mod || crf_fail "scale-set fork backport drifted"
grep -Fq 'go 1.25.3' tools/crf-scaleset/go.mod || crf_fail "Go version drifted"

# Activation uses real remote ownership/session operations. No test-only
# migration bypass may remain anywhere in the production package.
grep -Fq 'scaleset_request apply_sessions' "$scalesets" ||
  crf_fail "production session application is missing"
grep -Fq 'scaleset_request reconcile_owned' "$scalesets" ||
  crf_fail "production remote eligibility reconciliation is missing"
grep -Fq 'scaleset_request delete_owned' "$scalesets" ||
  crf_fail "production exact-owned deletion is missing"
grep -Fq 'probe.RunLive' tools/crf-scaleset/cmd/crf-scaleset/main.go ||
  crf_fail "live compatibility probe is not wired"
grep -Fq 'record.State = "create_ambiguous"' tools/crf-scaleset/internal/ownership/ownership.go ||
  crf_fail "ambiguous response-loss ownership tombstone is missing"
grep -Fq 'never adopt by name' tools/crf-scaleset/internal/ownership/ownership.go ||
  crf_fail "foreign name/spec adoption guard is missing"
grep -Fq 'scaleSetLabelContract = "canonical-name-label-v1"'   tools/crf-scaleset/internal/ownership/ownership.go ||
  crf_fail "canonical scale-set name-label migration contract is missing"
grep -Fq 'scaleSetNameContract  = "routing-label-name-v1"'   tools/crf-scaleset/internal/ownership/ownership.go ||
  crf_fail "stable routing-name migration contract is missing"
grep -Fq 'return routingLabel' tools/crf-scaleset/internal/ownership/ownership.go ||
  crf_fail "scale-set names are not stable workflow routing names"
grep -Fq 'scaleset.Label{Type: "System", Name: name}'   tools/crf-scaleset/internal/github/api.go ||
  crf_fail "scale-set canonical name label is missing"
grep -Fq 'func LabelsForComparison' tools/crf-scaleset/internal/github/api.go ||
  crf_fail "canonical routing-name label comparison is missing"
grep -Fq 'ScaleSetID: int(scaleSetID)'   tools/crf-scaleset/cmd/crf-scaleset/main.go ||
  crf_fail "listener clients are not bound to their scale-set IDs"
grep -Fq 'NewAdapterWithScaleSetClientFactory'   tools/crf-scaleset/cmd/crf-scaleset/main.go ||
  crf_fail "one shared mutable client still serves every scale set"
grep -Fq 'flock -w "$lock_timeout" 6'   src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-scalesets.sh ||
  crf_fail "scale-set request sequence is not serialized through socket delivery"
grep -Fq 'timeout --signal=TERM --kill-after=5s' \
  src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-scalesets.sh ||
  crf_fail "scale-set request socket I/O is unbounded"
! grep -Fq 'timeout --foreground' \
  src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-scalesets.sh ||
  crf_fail "scale-set request timeout leaves helper descendants running"
grep -Fq 'flock -n 5'   src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh ||
  crf_fail "autoscale ticks are not serialized"
grep -Fq 'image="${ARGS[$CRF_IMAGE_ARG_INDEX]}"' \
  src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh ||
  crf_fail "runner recycle does not inspect the recorded image argument"
! grep -Fq 'image="${ARGS[${#ARGS[@]}-1]}"' \
  src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh ||
  crf_fail "runner recycle still treats the listener command as the image"
grep -Fq 'runner_secret_inject "$name" "$CRF_REGISTRATION_SECRET"' \
  src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh ||
  crf_fail "runner recycle does not perform protected credential handoff"
! grep -R -Eq 'CRF_MIGRATION_TEST_GATES|live_probe_not_configured|not yet compatibility-proven' src tools ||
  crf_fail "test-only or placeholder scale-set gate remains in production"

# The complete typed snapshot remains comfortably beneath the expected 256 KiB
# budget in the deterministic maximum fixture.
bash tests/performance-contracts.sh >/dev/null
bash tests/autoscale-locks.sh >/dev/null
bash tests/mutation-ownership.sh >/dev/null
bash tests/reconcile-status.sh >/dev/null
bash tests/endpoint-validation.sh >/dev/null
bash tests/nashost-kache-profile.sh >/dev/null
bash tests/nashost-candidate-docs.sh >/dev/null
bash tests/image-promotion.sh >/dev/null
bash tests/resource-admission.sh >/dev/null
bash tests/nashost-fleet-audit.sh >/dev/null
bash tests/flash-write-paths.sh >/dev/null
bash tests/job-visibility.sh >/dev/null
bash tests/jit-recovery.sh >/dev/null
bash tests/recent-activity.sh >/dev/null
bash tests/readiness-json.sh >/dev/null
bash tests/recycle-runtime.sh >/dev/null
bash tests/release-publication-guard.sh >/dev/null
bash tests/stalled-credential-handoff.sh >/dev/null
bash tests/reconcile-stop-lifecycle.sh >/dev/null
bash tests/reconcile-retry.sh >/dev/null
bash tests/runner-runtime.sh >/dev/null
bash tests/distributed-container-adapter.sh >/dev/null
bash tests/distributed-status.sh >/dev/null
bash tests/validate-runtime.sh >/dev/null
bash tests/scale-set-control.sh >/dev/null
bash tests/scale-set-supervisor.sh >/dev/null
bash tests/package-reproducible.sh >/dev/null

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp -a build-plg.sh src tools VERSION CHANGELOG.md "$tmp/"
go125="$(crf_go125)"
(
  cd "$tmp"
  CRF_GO="$go125" ./build-plg.sh --tgz-only >/dev/null
)
mkdir -p "$tmp/package"
tar -xzf "$tmp/ci-runner-farm.tgz" -C "$tmp/package"
helper="$tmp/package/bin/crf-scaleset"
[ -x "$helper" ] || crf_fail "packaged helper is not executable"
for executable in \
  include/runner-farm.sh \
  include/runner-runtime.sh \
  include/runner-container-adapter.sh \
  include/runner-distributed-adapter.sh \
  include/runner-entrypoint.sh \
  event/docker_started \
  event/stopping_docker \
  nchan/ci_runner_farm; do
  [ -x "$tmp/package/$executable" ] ||
    crf_fail "packaged $executable is not executable"
done
helper_type="$(file "$helper")"
grep -Fq 'statically linked' <<<"$helper_type" || crf_fail "packaged helper is not static"
"$helper" version >"$tmp/version.json"
php -r '
  $j=json_decode(file_get_contents($argv[1]),true);
  exit(is_array($j)&&($j["go_version"]??"")==="go1.25.3"&&
    ($j["module_revision"]??"")==="035cda46ea086d5faaa13f4b17953112c1c7f295"?0:1);
' "$tmp/version.json" || crf_fail "packaged helper identity mismatch"

record="${CRF_LIVE_COMPAT_RECORD:-}"
if [ -n "$record" ]; then
  [ -f "$record" ] || crf_fail "CRF_LIVE_COMPAT_RECORD does not exist"
  "$helper" check-compatibility --path "$record" >/dev/null ||
    crf_fail "live compatibility record does not bind the packaged helper"
elif [ "${CRF_REQUIRE_LIVE_GATE:-0}" = 1 ]; then
  crf_fail "live packaged-identity gate required but CRF_LIVE_COMPAT_RECORD is unset"
fi

echo "final-release-gate: OK ($([ -n "$record" ] && echo live packaged identity proven || echo offline package checks only))"
