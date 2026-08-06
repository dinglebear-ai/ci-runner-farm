#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib/assert.sh
module=src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-operations.sh
helper=src/usr/local/emhttp/plugins/ci-runner-farm/include/operation-record.php
root="$(mktemp -d /tmp/crf-operations.XXXXXX)"
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/include" "$root/config"
cp "$module" "$root/include/runner-operations.sh"
cp "$helper" "$root/include/operation-record.php"
SCRIPT_DIR="$root/include" CFGDIR="$root/config" OPERATION_DIR="$root/config/operations"
# shellcheck disable=SC1090
. "$root/include/runner-operations.sh"
sha="$(printf config | sha256sum | cut -d' ' -f1)"

id1='00000001-0000-0000-0000-000000000001'
CRF_OPERATION_ID="$id1"
created="$(operation_create compatibility_test "$sha" compatibility_log)"
crf_assert_eq "$id1" "$created" 'created operation ID'
crf_assert_eq "$sha" "$(operation_config_revision_read "$id1")" 'operation config revision'
crf_assert_file_mode "$OPERATION_DIR" 700
crf_assert_file_mode "$OPERATION_DIR/$id1.json" 600
if operation_create compatibility_test "$sha" compatibility_log >/dev/null 2>&1; then crf_fail 'duplicate operation ID was accepted'; fi
operation_read_public "$id1" | php -r '$j=json_decode(stream_get_contents(STDIN),true);exit(is_array($j)&&($j["state"]??"")==="queued"&&($j["output"]??null)===[]?0:1);'

unset CRF_OPERATION_ID
operation_mark_running "$id1" 'Compatibility test started.'
operation_worker_live_path "$OPERATION_DIR/$id1.json" "$id1" || crf_fail 'current worker identity was not live'
summary="$root/summary.log"
{
  for i in $(seq 1 25); do printf 'line-%02d
' "$i"; done
  printf 'Authorization: Bearer abcdefghijklmnopqrstuvwxyz
'
  printf 'github_pat_abcdefghijklmnopqrstuvwxyz
'
} >"$summary"
chmod 0600 "$summary"
operation_finish "$id1" succeeded compatible 'Compatibility test passed.' "$summary"
public="$(operation_read_public "$id1")"
printf '%s' "$public" | php -r '
$j=json_decode(stream_get_contents(STDIN),true);
$out=$j["output"]??[];$text=implode("
",$out);
exit(is_array($j)&&($j["state"]??"")==="succeeded"&&count($out)<=20&&strlen($text)<=4096&&
 strpos($text,"abcdefghijklmnopqrstuvwxyz")===false&&strpos($text,"[REDACTED]")!==false?0:1);
' || crf_fail 'terminal summary contract failed'
if operation_finish "$id1" failed failed 'late failure' >/dev/null 2>&1; then crf_fail 'terminal operation transitioned again'; fi

if operation_read_public not-a-uuid >/dev/null 2>&1; then crf_fail 'invalid operation ID was accepted'; fi
ln -s "$OPERATION_DIR/$id1.json" "$OPERATION_DIR/00000002-0000-0000-0000-000000000002.json"
if operation_read_public 00000002-0000-0000-0000-000000000002 >/dev/null 2>&1; then crf_fail 'symlinked operation record was accepted'; fi
rm "$OPERATION_DIR/00000002-0000-0000-0000-000000000002.json"

idq='00000003-0000-0000-0000-000000000003'
CRF_OPERATION_ID="$idq" operation_create image_build "$sha" image_build_log >/dev/null
set +e
existing="$(CRF_OPERATION_ID='00000003-0000-0000-0000-000000000099' operation_create_unique image_build "$sha" image_build_log)"
unique_rc=$?
set -e
crf_assert_eq 2 "$unique_rc" 'duplicate active kind exit code'
crf_assert_eq "$idq" "$existing" 'duplicate active kind operation ID'
idm='00000004-0000-0000-0000-000000000004'
CRF_OPERATION_ID="$idm" operation_create provisioning_validation "$sha" provisioning_log >/dev/null
CRF_OPERATION_PID=4194304 CRF_OPERATION_START_TICKS=1 operation_mark_running "$idm" 'Validation started.'
idb='00000005-0000-0000-0000-000000000005'
CRF_OPERATION_ID="$idb" operation_create image_build "$sha" image_build_log >/dev/null
actual_ticks="$(operation_process_start_ticks $$)"
CRF_OPERATION_BOOT_ID='fake-boot-identity' CRF_OPERATION_PID=$$ CRF_OPERATION_START_TICKS="$actual_ticks" operation_mark_running "$idb" 'Build started.'
unset CRF_OPERATION_BOOT_ID CRF_OPERATION_PID CRF_OPERATION_START_TICKS
idl='00000006-0000-0000-0000-000000000006'
CRF_OPERATION_ID="$idl" operation_create compatibility_test "$sha" compatibility_log >/dev/null
operation_mark_running "$idl" 'Live worker.'
operation_reconcile_interrupted
for id in "$idq" "$idm" "$idb"; do
  crf_assert_eq failed "$(operation_state_read "$id")" "interrupted state for $id"
  operation_read_public "$id" | php -r '$j=json_decode(stream_get_contents(STDIN),true);exit(($j["code"]??"")==="operation_interrupted"?0:1);' || crf_fail "interrupted code for $id"
done
crf_assert_eq running "$(operation_state_read "$idl")" 'live worker was interrupted'
crf_assert_eq succeeded "$(operation_state_read "$id1")" 'terminal record changed during reconciliation'

retention_dir="$root/config/retention-operations"
OPERATION_DIR="$retention_dir"
OPERATION_MAX_FILES=3 OPERATION_MAX_AGE_SECONDS=999999999
now="$(date +%s)"
for n in 7 8 9 10 11; do
  id="$(printf '%08x-0000-0000-0000-%012x' "$n" "$n")"
  CRF_OPERATION_ID="$id" operation_create image_build "$sha" image_build_log >/dev/null
  operation_finish "$id" failed failed 'failed' >/dev/null
  touch -d "@$((now - 12 + n))" "$OPERATION_DIR/$id.json"
done
operation_prune
for n in 7 8; do
  id="$(printf '%08x-0000-0000-0000-%012x' "$n" "$n")"
  [ ! -e "$OPERATION_DIR/$id.json" ] || crf_fail "old count-bound terminal $id was retained"
done
for n in 9 10 11; do
  id="$(printf '%08x-0000-0000-0000-%012x' "$n" "$n")"
  [ -e "$OPERATION_DIR/$id.json" ] || crf_fail "new count-bound terminal $id was pruned"
done
terminal_count=0
for file in "$OPERATION_DIR"/*.json; do
  id="$(basename "$file" .json)"
  state="$(operation_state_read "$id" 2>/dev/null || true)"
  case "$state" in succeeded|failed|cancelled) terminal_count=$((terminal_count+1)) ;; esac
done
crf_assert_eq 3 "$terminal_count" 'terminal count retention bound'

OPERATION_MAX_AGE_SECONDS=10
old='0000000c-0000-0000-0000-00000000000c'
CRF_OPERATION_ID="$old" operation_create image_build "$sha" image_build_log >/dev/null
operation_finish "$old" failed failed 'old' >/dev/null
touch -d '@1' "$OPERATION_DIR/$old.json"
old_running='0000000d-0000-0000-0000-00000000000d'
CRF_OPERATION_ID="$old_running" operation_create image_build "$sha" image_build_log >/dev/null
CRF_OPERATION_PID=4194304 CRF_OPERATION_START_TICKS=1 operation_mark_running "$old_running" 'old running'
unset CRF_OPERATION_PID CRF_OPERATION_START_TICKS
touch -d '@1' "$OPERATION_DIR/$old_running.json"
printf 'leave me
' >"$OPERATION_DIR/unrelated.txt"
operation_prune
[ ! -e "$OPERATION_DIR/$old.json" ] || crf_fail 'old terminal operation was retained'
[ -e "$OPERATION_DIR/$old_running.json" ] || crf_fail 'old non-terminal operation was pruned'
[ -e "$OPERATION_DIR/unrelated.txt" ] || crf_fail 'unrelated file was pruned'

mv "$SCRIPT_DIR/operation-record.php" "$SCRIPT_DIR/operation-record.php.real"
printf '%s
' '<?php fwrite(STDERR,"forced write failure\n"); exit(5);' >"$SCRIPT_DIR/operation-record.php"
CRF_OPERATION_ID='0000000e-0000-0000-0000-00000000000e'
if operation_create image_build "$sha" image_build_log >/dev/null 2>&1; then crf_fail 'atomic create ignored a helper failure'; fi
[ ! -e "$OPERATION_DIR/0000000e-0000-0000-0000-00000000000e.json" ] || crf_fail 'failed atomic create left a final record'
shopt -s nullglob
partials=("$OPERATION_DIR"/0000000e-0000-0000-0000-00000000000e.json.tmp.*)
[ "${#partials[@]}" -eq 0 ] || crf_fail 'failed atomic create left a temporary record'
mv "$SCRIPT_DIR/operation-record.php.real" "$SCRIPT_DIR/operation-record.php"

boot_line="$(grep -n '^cmd_boot_autostart()' src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh | cut -d: -f1)"
reconcile_line="$(grep -n 'operation_reconcile_interrupted ||' src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh | cut -d: -f1)"
auth_line="$(awk -v start="$boot_line" 'NR>start && index($0,"auth_credentials_configured ||") { print NR; exit }' src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh)"
[ "$reconcile_line" -gt "$boot_line" ] && [ "$reconcile_line" -lt "$auth_line" ] || crf_fail 'boot reconciliation does not precede credential early return'

printf 'operations: OK
'
