#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib/assert.sh

root="$(mktemp -d /tmp/crf-graphql-mutations.XXXXXX)"
trap 'rm -rf "$root"' EXIT
RUNDIR="$root/run"
SCRIPT_DIR="$(pwd)/src/usr/local/emhttp/plugins/ci-runner-farm/include"
mkdir -p "$RUNDIR"
# shellcheck disable=SC1090
. "$SCRIPT_DIR/runner-api.sh"

calls="$root/calls"
config="$(printf config | sha256sum | cut -d' ' -f1)"
inventory="$(printf inventory | sha256sum | cut -d' ' -f1)"
ownership="$(printf ownership | sha256sum | cut -d' ' -f1)"
compatibility="$(printf compatibility | sha256sum | cut -d' ' -f1)"
transition="$(printf transition | sha256sum | cut -d' ' -f1)"
request_id=70000000-0000-4000-8000-000000000001

with_fleet_lock(){ shift; "$@"; }
runner_api_fleet_guard(){ return 0; }
runner_api_config_guard(){ return 0; }
runner_api_observed_refresh(){
  RUNNER_API_OBSERVED_CONFIG_REVISION="$config"
  RUNNER_API_OBSERVED_INVENTORY_REVISION="$inventory"
  RUNNER_API_OBSERVED_TRANSITION_REVISION="$transition"
  RUNNER_API_OBSERVED_OWNERSHIP_REVISION="$ownership"
  RUNNER_API_OBSERVED_COMPATIBILITY_RECORD_ID="$compatibility"
  RUNNER_API_OBSERVED_CREDENTIAL_REVISION=null
}
record(){ printf '%s\n' "$*" >>"$calls"; printf '{"action":"%s"}\n' "$1"; }
cmd_scale(){ record scale "$@"; }
scheduler_prewarm_guarded(){ record prewarm "$@"; }
cmd_recycle(){ record recycle "$@"; }
cmd_maintenance(){ record maintenance "$@"; }
cmd_image_build_operation_start(){ record image-build-start "$@"; }
cmd_provisioning_operation_start(){ record provisioning-validation-start "$@"; }
cmd_compatibility_operation_start(){ record compatibility-test-start "$@"; }
migration_start(){ record backend-migration-start "$@"; }
migration_rollback(){ record backend-rollback "$@"; }
cmd_cancel_run(){ record queue-cancel "$@"; }
cmd_cache_clear_pkg(){ record cache-clear "$@"; }

request(){
  php -r '
    $op=$argv[1];$id=$argv[2];$c=$argv[3];$i=$argv[4];$o=$argv[5];$x=$argv[6];$t=$argv[7];
    $expected=(object)[];$input=(object)[];
    if(in_array($op,["scale","recycle"],true))$expected=(object)["config_revision"=>$c,"inventory_revision"=>$i];
    elseif(in_array($op,["prewarm","maintenance","provisioning-validation-start","compatibility-test-start","cache-clear"],true))$expected=(object)["config_revision"=>$c];
    elseif(in_array($op,["backend-migration-start","backend-rollback"],true))$expected=(object)["config_revision"=>$c,"ownership_revision"=>$o,"compatibility_record_id"=>$x,"transition_revision"=>$t];
    switch($op){
      case "scale":$input=(object)["pool_id"=>"rust","target"=>3];break;
      case "prewarm":$input=(object)["pool_id"=>"rust","target"=>2];break;
      case "recycle":$input=(object)["runner_name"=>"ci-runner-rust-1"];break;
      case "maintenance":$input=(object)["mode"=>"BEGIN"];break;
      case "image-build-start":$input=(object)["dockerfile_sha256"=>$c];break;
      case "queue-cancel":$input=(object)["repository"=>"owner/repo","run_id"=>"123"];break;
    }
    echo json_encode(["schema_version"=>1,"request_id"=>$id,"operation"=>$op,"expected"=>$expected,"input"=>$input],JSON_UNESCAPED_SLASHES);
  ' "$1" "$request_id" "$config" "$inventory" "$ownership" "$compatibility" "$transition"
}

operations=(scale prewarm recycle maintenance image-build-start provisioning-validation-start compatibility-test-start backend-migration-start backend-rollback queue-cancel cache-clear)
for operation in "${operations[@]}"; do
  output="$(request "$operation" | runner_api_dispatch "$operation")" || crf_fail "$operation dispatch failed"
  printf '%s' "$output" | php -r '$j=json_decode(stream_get_contents(STDIN),true);exit(is_array($j)&&($j["ok"]??false)===true&&($j["result"]["action"]??"")===$argv[1]?0:1);' "$operation" ||
    crf_fail "$operation did not return its strict success envelope"
done

for operation in "${operations[@]}"; do
  grep -q "^$operation\( \|$\)" "$calls" || crf_fail "$operation did not reach its fixed handler"
done

cmd_image_build_operation_start(){
  printf '%s\n' '{"ok":false,"code":"operation_running","message":"an image build is already active","operation_id":"70000000-0000-4000-8000-000000000002"}'
  return 4
}
set +e
failure="$(request image-build-start | runner_api_dispatch image-build-start)"
failure_rc=$?
set -e
crf_assert_eq 4 "$failure_rc" 'operation-running exit code'
printf '%s' "$failure" | php -r '$j=json_decode(stream_get_contents(STDIN),true);exit(is_array($j)&&($j["ok"]??true)===false&&($j["code"]??"")==="operation_running"?0:1);' ||
  crf_fail 'operation start failure code was not preserved'

echo 'graphql-mutation-dispatch: OK'
