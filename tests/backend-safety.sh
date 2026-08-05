#!/usr/bin/env bash
# Focused behavioral contracts for image builds, retained logs, queue actions,
# and settings bounds added by the live Runner Farm screens.
# shellcheck disable=SC2034,SC2016 # globals feed dynamically extracted functions; PHP snippets are literal
set -euo pipefail

# cmd_build_async launches "$0 build-image <snapshot>". In probe mode, stand in
# for the real Docker build while still proving that the immutable snapshot is
# private and survives until the child starts.
if [ "${1:-}" = build-image ]; then
  snapshot="${2:-}"
  [ -f "$snapshot" ] && [ ! -L "$snapshot" ] || exit 21
  [ "$(stat -c %a "$snapshot")" = 600 ] || exit 22
  printf 'build probe consumed %s\n' "$(sha256sum "$snapshot" | awk '{print $1}')"
  exit 0
fi

cd "$(dirname "$0")/.."
. tests/lib/assert.sh

engine=src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
endpoint=src/usr/local/emhttp/plugins/ci-runner-farm/include/exec.php
tmp="$(mktemp -d)"
TEST_ROOT="$tmp"
trap 'rm -rf "$TEST_ROOT"' EXIT

snippet="$tmp/functions.sh"
for fn in json_string validate_settings_config count_pool_desired_drift pool_autoscale_tick pool_effective_target build_candidate_tag_valid build_candidate_state_load cmd_promote_image cmd_build_async cmd_build_status cmd_history_log cmd_build_image queued_snapshot_unavailable cmd_queued_json cmd_cancel_run; do
  sed -n "/^${fn}()/,/^}/p" "$engine" >> "$snippet"
done
# shellcheck disable=SC1090
. "$snippet"

# IMAGE_DRAIN_TIMEOUT=0 is the documented wait-forever value; reject the gap
# from 1-59 while preserving the bounded positive range.
validate_runtime_config(){ return 0; }
pool_error(){ VALIDATION_ERROR="$1"; }
POOL_BACKEND=classic AUTH_MODE=pat GITHUB_APP_ID='' GITHUB_APP_INSTALLATION_ID=''
GITHUB_APP_KEY_FILE="$tmp/no-key" IMAGE_SOURCE=builtin IMAGE='' NETWORK_ISOLATION=off
EPHEMERAL=false RUN_AS_ROOT=false SHARE_DOCKER_SOCK=false DIND=true
SHARED_IMAGE_CACHE=true AUTOSCALE=false IMAGE_AUTOUPDATE=false DASHBOARD_WIDGET_ENABLE=true
RUNNER_COUNT=4 AUTOSCALE_MIN=2 AUTOSCALE_MAX=16 AUTOSCALE_MIN_IDLE=2 AUTOSCALE_STEP=2
AUTOSCALE_INTERVAL=30 AUTOSCALE_IDLE_GRACE=5 IMAGE_AUTOUPDATE_INTERVAL=1800 RESOURCE_PIDS_LIMIT=4096
for timeout in 0 60 86400; do
  IMAGE_DRAIN_TIMEOUT="$timeout"
  validate_settings_config || crf_fail "valid drain timeout $timeout was rejected"
done
for timeout in 1 59 86401; do
  IMAGE_DRAIN_TIMEOUT="$timeout"
  if validate_settings_config; then crf_fail "invalid drain timeout $timeout was accepted"; fi
done

# Mixed pool policy: automatic pools use their configured floor and are not
# counted as reconciliation drift, while fixed pools retain durable overrides.
RUNDIR="$tmp/pool-runtime"
mkdir -p "$RUNDIR"
AUTOSCALE=true INVENTORY_ACTIVE=1
pool_mode_enabled(){ return 0; }
pool_configured_target(){ case "$1" in auto) echo 2 ;; fixed) echo 5 ;; esac; }
pool_state_generation(){ echo testgen; }
pool_autoscale_enabled(){ [ "$1" = auto ]; }
printf '9\n' > "$RUNDIR/scale-override.auto.testgen"
printf '7\n' > "$RUNDIR/scale-override.fixed.testgen"
crf_assert_eq 2 "$(pool_effective_target auto)" 'autoscaled pool honored a fixed runtime override'
crf_assert_eq 7 "$(pool_effective_target fixed)" 'fixed pool lost its durable runtime override'
pool_records(){ printf 'auto|record\nfixed|record\n'; }
current_count(){ case "$1" in auto) echo 9 ;; fixed) echo 8 ;; esac; }
crf_assert_eq 1 "$(count_pool_desired_drift)" 'autoscaled capacity was counted as durable reconciliation drift'

# The global daemon remains the master, but a fixed pool must be a no-op on a
# per-pool tick and discard any stale anti-flap counter from its former mode.
touch "$RUNDIR/autoscale.fixed.testgen.state"
current_count(){ touch "$tmp/fixed-pool-ticked"; echo 5; }
pool_autoscale_tick fixed
[ ! -e "$tmp/fixed-pool-ticked" ] || crf_fail 'fixed pool reached autoscale accounting'
[ ! -e "$RUNDIR/autoscale.fixed.testgen.state" ] || crf_fail 'fixed pool retained stale autoscale state'

# Empty argv from the dispatcher must mean the canonical Dockerfile, not an
# invalid snapshot. Capture the exact clean-context content passed to Docker.
CFGDIR="$TEST_ROOT/cfg" RUNDIR="$TEST_ROOT/run" BUILTIN_IMAGE=ci-runner-farm-runner:latest
BUILD_CANDIDATE_FILE="$CFGDIR/build-candidate.state"
PROMOTED_IMAGE_FILE="$CFGDIR/promoted-image.state"
mkdir -p "$CFGDIR" "$RUNDIR" "$TEST_ROOT/images"
printf 'FROM scratch\nLABEL source=canonical\n' > "$CFGDIR/Dockerfile"
docker_capture="$TEST_ROOT/dockerfile.seen"
log(){ :; }
err(){ printf '%s\n' "$*" > "$TEST_ROOT/error"; }
resource_positive_uint_valid(){ [[ "${1:-}" =~ ^[1-9][0-9]*$ ]] && [ "$1" -le "${2:-9000000000000000000}" ]; }
image_path(){ printf '%s/images/%s\n' "$TEST_ROOT" "$(printf '%s' "$1" | sha256sum | awk '{print $1}')"; }
docker(){
  case "${1:-}:${2:-}" in
    image:inspect)
      local path; path="$(image_path "$3")"
      [ -f "$path" ] || return 1
      [ "${4:-}" != --format ] || cat "$path"
      ;;
    build:-t)
      cp "$4/Dockerfile" "$docker_capture"
      printf 'sha256:%064d\n' 0 | tr 0 a > "$(image_path "$3")"
      ;;
    tag:) cp "$(image_path "$2")" "$(image_path "$3")" ;;
    *) return 31 ;;
  esac
}
cmd_build_image "" || crf_fail 'empty dispatcher argument rejected the canonical Dockerfile'
cmp -s "$CFGDIR/Dockerfile" "$docker_capture" || crf_fail 'build did not receive canonical Dockerfile content'
build_candidate_state_load || crf_fail 'direct build did not preserve verified candidate metadata'
[ "$BUILD_CANDIDATE_TAG" != "$BUILTIN_IMAGE" ] || crf_fail 'direct build targeted the production image tag'

# A stale save identity must fail before launch. A matching identity launches
# only the private snapshot, and both runtime build files remain mode 0600.
expected="$(sha256sum "$CFGDIR/Dockerfile" | awk '{print $1}')"
stale="$(printf stale | sha256sum | awk '{print $1}')"
reply="$(cmd_build_async "$stale")"
crf_assert_contains "$reply" '"code":"stale_dockerfile"' 'stale Dockerfile identity was not rejected'
[ ! -e "$RUNDIR/build.log" ] || crf_fail 'stale Dockerfile launch truncated or created a build log'
crf_assert_file_mode "$RUNDIR/build.lock" 600

reply="$(cmd_build_async "$expected")"
crf_assert_contains "$reply" '"ok":true' 'matching Dockerfile identity did not launch'
crf_assert_contains "$reply" "\"dockerfile_sha\":\"$expected\"" 'build response lost Dockerfile identity'
for _ in $(seq 1 100); do
  grep -q '__BUILD_RC__=' "$RUNDIR/build.log" 2>/dev/null && break
  sleep 0.02
done
grep -Fq "build probe consumed $expected" "$RUNDIR/build.log" || crf_fail 'build child did not consume the verified snapshot'
grep -Fq '__BUILD_RC__=0' "$RUNDIR/build.log" || crf_fail 'build completion sentinel is missing'
crf_assert_file_mode "$RUNDIR/build.lock" 600
crf_assert_file_mode "$RUNDIR/build.log" 600
status="$(cmd_build_status)"
crf_assert_contains "$status" '"running":false' 'completed build still reports running'
crf_assert_contains "$status" '"rc":0' 'completed build status lost its exit code'

# Retained history reads only the eight newest files, returns at most 150 lines,
# ignores a symlinked runner directory, and redacts both PAT and Bearer forms.
JIT_LOG_ROOT="$tmp/logs"
runner=ci-runner-jit-rust-0123456789abcdefabcd
mkdir -p "$JIT_LOG_ROOT/$runner"
jit_id_valid(){ [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ ]]; }
for i in $(seq -w 1 12); do
  file="$JIT_LOG_ROOT/$runner/Runner_$i.log"
  printf 'file-%s\n' "$i" > "$file"
  touch -d "@$((1000 + 10#$i))" "$file"
done
history="$(cmd_history_log "$runner")"
history_log="$(printf '%s' "$history" | php -r '$d=json_decode(stream_get_contents(STDIN),true); if(!is_array($d)||!($d["ok"]??false)) exit(1); echo $d["log"]??"";')"
case "$history_log" in *file-01*|*file-04*) crf_fail 'history included files older than the newest-eight cap' ;; esac
crf_assert_contains "$history_log" 'file-05' 'history omitted the oldest selected file'
crf_assert_contains "$history_log" 'file-12' 'history omitted the newest selected file'
# Oversized rotations are excluded before selection/reading even when newest.
truncate -s 17M "$JIT_LOG_ROOT/$runner/Runner_99.log"
printf 'oversized-secret-sentinel\n' >> "$JIT_LOG_ROOT/$runner/Runner_99.log"
touch -d '@3000' "$JIT_LOG_ROOT/$runner/Runner_99.log"
history="$(cmd_history_log "$runner")"
case "$history" in *oversized-secret-sentinel*) crf_fail 'history read an oversized rotation' ;; esac
{
  for i in $(seq 1 200); do printf 'line-%03d\n' "$i"; done
  printf 'Authorization: Bearer abcdefghijklmnopqrstuvwxyz\n'
  printf 'github_pat_abcdefghijklmnopqrstuvwxyz\n'
} > "$JIT_LOG_ROOT/$runner/Runner_12.log"
touch -d '@2000' "$JIT_LOG_ROOT/$runner/Runner_12.log"
history="$(cmd_history_log "$runner")"
history_log="$(printf '%s' "$history" | php -r '$d=json_decode(stream_get_contents(STDIN),true); if(!is_array($d)||!($d["ok"]??false)) exit(1); echo $d["log"]??"";')"
lines="$(printf '%s\n' "$history_log" | wc -l)"
crf_assert_eq 150 "$lines" 'history log is not capped to 150 lines'
case "$history_log" in *abcdefghijklmnopqrstuvwxyz*) crf_fail 'history returned an unredacted credential' ;; esac
crf_assert_contains "$history_log" '[REDACTED]' 'history credential redaction did not run'
mv "$JIT_LOG_ROOT/$runner" "$JIT_LOG_ROOT/real-runner"
ln -s real-runner "$JIT_LOG_ROOT/$runner"
history="$(cmd_history_log "$runner")"
crf_assert_contains "$history" '"log":""' 'history followed a symlinked runner directory'

# Cancellation requires a configured repo, a small/fresh snapshot membership,
# and a second live GitHub status check before the POST. Stale snapshots and
# runs that have already started fail before the destructive call.
RUNDIR="$tmp/queue" GH_REPOS='acme/repo other/repo'
mkdir -p "$RUNDIR"
queued_snapshot_unavailable "$(date +%s)" || crf_fail 'unavailable queue snapshot could not be written'
crf_assert_file_mode "$RUNDIR/queued.snapshot.json" 600
queue="$(cmd_queued_json)"
crf_assert_contains "$queue" '"queued":-1' 'unavailable queue snapshot lost its sentinel'
crf_assert_contains "$queue" '"detail_complete":false' 'unavailable queue snapshot claims complete detail'
token_calls=0 api_gets=0 api_posts=0 live_status=queued
github_api_token_load(){ token_calls=$((token_calls+1)); return 0; }
gh_api_request(){
  if [ "$1" = GET ]; then
    api_gets=$((api_gets+1)); GH_STATUS=200; GH_RESPONSE="{\"status\":\"$live_status\"}"; return 0
  fi
  api_posts=$((api_posts+1)); GH_STATUS=202; GH_RESPONSE=''; return 0
}
write_snapshot(){
  printf '{"timestamp":%s,"queued":1,"known_queued":1,"workflow_runs":1,"partial":false,"truncated":false,"detail_complete":true,"jobs":[{"repo":"acme/repo","run_id":42}]}\n' "$1" > "$RUNDIR/queued.snapshot.json"
  chmod 0600 "$RUNDIR/queued.snapshot.json"
}
write_snapshot "$(( $(date +%s) - 121 ))"
if cmd_cancel_run acme/repo 42 >/dev/null; then crf_fail 'stale queue snapshot authorized cancellation'; fi
crf_assert_eq 0 "$token_calls" 'stale queue snapshot reached GitHub authentication'
write_snapshot "$(date +%s)"
live_status=in_progress
if cmd_cancel_run acme/repo 42 >/dev/null; then crf_fail 'non-queued live run was cancelled'; fi
crf_assert_eq 1 "$api_gets" 'live queue status was not checked exactly once'
crf_assert_eq 0 "$api_posts" 'non-queued live run reached the cancel endpoint'
write_snapshot "$(date +%s)"
live_status=queued
cmd_cancel_run acme/repo 42 > "$tmp/cancel.reply"
reply="$(<"$tmp/cancel.reply")"
crf_assert_contains "$reply" '"ok":true' 'fresh farm queue member was not cancelled'
crf_assert_eq 1 "$api_posts" 'valid cancel did not call GitHub once'
[ ! -e "$RUNDIR/queued.snapshot.json" ] || crf_fail 'successful cancel left a stale queue snapshot'

# Endpoint and engine source contracts for the save/build identity handoff.
grep -Fq "'dockerfile_sha' => \$dockerfileSha" "$endpoint" || crf_fail 'save response lacks Dockerfile identity'
grep -Fq "post_scalar('dockerfile_sha', 64, true, true)" "$endpoint" || crf_fail 'build endpoint does not require Dockerfile identity'
grep -Fq "build-async ' . escapeshellarg(\$dockerfileSha)" "$endpoint" || crf_fail 'build endpoint does not pass the identity safely'
php -r '
  $src=file_get_contents($argv[1]);
  $start=strpos($src,"case ".chr(39)."set-token".chr(39).":");
  if ($start===false) exit(1);
  $end=strpos($src,"case ".chr(39)."clear-token".chr(39).":",$start);
  $block=substr($src,$start,$end-$start);
  $validate=strpos($block,"github_pat_validate(".chr(36)."tok)");
  $commit=strpos($block,"write_private_atomic(".chr(34).chr(36)."CFGDIR/token".chr(34).", ".chr(36)."tok)");
  if ($validate===false || $commit===false || $validate>=$commit) exit(2);
  if (strpos($block,"file_put_contents")!==false) exit(3);
' "$endpoint" || crf_fail 'PAT validation is not ordered before atomic credential replacement'
if sed -n '/^cmd_queued_refresh()/,/^}/p' "$engine" | grep -Fq 'queued.cache'; then
  crf_fail 'queue refresh still writes the retired split cache'
fi
grep -Fq 'if ($status!=="queued") continue;' "$engine" || crf_fail 'queue detail accepts jobs that are not actually queued'
grep -Fq 'POOL_AUTOSCALE="inherit"' "$engine" || crf_fail 'engine lacks the backward-compatible per-pool autoscale default'
grep -Fq 'AUTOSCALE POOL_AUTOSCALE AUTOSCALE_MIN' "$engine" || crf_fail 'engine config allowlist omits POOL_AUTOSCALE'
grep -Fq "'AUTOSCALE','POOL_AUTOSCALE','AUTOSCALE_MIN'" "$endpoint" || crf_fail 'apply endpoint allowlist omits POOL_AUTOSCALE'
grep -Fq "post_scalar('pool_autoscale', 255)" "$endpoint" || crf_fail 'pool validation endpoint does not bound per-pool autoscale intent'
grep -Fq '\"autoscale_enabled\":${pool_auto}' "$engine" || crf_fail 'pool status omits its effective autoscale policy'
grep -Fq '$AUTOSCALE|$POOL_AUTOSCALE|$AUTOSCALE_MIN' "$engine" || crf_fail 'capacity fingerprint omits per-pool autoscale policy'
grep -Fq '[ "$old_autoscale" != true ]' "$engine" || crf_fail 'Apply does not start a newly enabled daemon master for a live fleet'

echo 'backend-safety: OK'
