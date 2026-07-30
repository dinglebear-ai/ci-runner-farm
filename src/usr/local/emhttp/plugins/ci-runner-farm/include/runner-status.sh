#!/bin/bash
# Pure serialization helpers for the schema-v2 Fleet snapshot. Callers build one
# Docker inventory first; these functions only consume that immutable file plus
# local reservation/config state and never invoke Docker or GitHub.

STATUS_OBSERVED_AT=0
STATUS_INVENTORY_REVISION=""
STATUS_CONFIG_REVISION=""
STATUS_RESOURCES_JSON='{"cpu_milli":{"budget":0,"reserve":0,"reserved":0,"admissible":0},"memory_bytes":{"budget":0,"reserve":0,"reserved":0,"admissible":0}}'
STATUS_RESERVATIONS_JSON='[]'
STATUS_BACKEND_JSON='{"requested":"classic","effective":"classic","transition_phase":"classic_active","transition_id":"","transition_revision":"","ownership_revision":""}'
STATUS_COMPATIBILITY_JSON='{"valid":false,"reason":"not_checked"}'
STATUS_OPERATION_JSON='null'

status_reservations_json() {
  local dir="${RESERVATION_DIR:-$RUNDIR/reservations}" file first=1
  printf '['
  for file in "$dir"/*.state; do
    [ -f "$file" ] || continue
    local operation pool runner cpu memory deadline phase
    operation="$(reservation_field "$file" operation_id)"
    pool="$(reservation_field "$file" pool_id)"
    runner="$(reservation_field "$file" runner_name)"
    cpu="$(reservation_field "$file" cpu_milli)"
    memory="$(reservation_field "$file" memory_bytes)"
    deadline="$(reservation_field "$file" deadline)"
    phase="$(reservation_field "$file" phase)"
    case "$operation$pool$runner$phase" in *[!A-Za-z0-9._:-]*) continue ;; esac
    case "$cpu:$memory:$deadline" in *[!0-9:]*) continue ;; esac
    [ "$first" = 1 ] || printf ','
    first=0
    printf '{"operation_id":"%s","pool_id":"%s","runner_name":"%s","cpu_milli":%s,"memory_bytes":%s,"deadline":%s,"phase":"%s"}' \
      "$operation" "$pool" "$runner" "$cpu" "$memory" "$deadline" "$phase"
  done
  printf ']'
}

status_model_refresh() {
  local cpu_reserve=0 memory_reserve=0
  STATUS_OBSERVED_AT="$(date +%s)"
  STATUS_CONFIG_REVISION="$(config_revision)"
  if [ -f "$INVENTORY_FILE" ]; then
    STATUS_INVENTORY_REVISION="$(sha256sum "$INVENTORY_FILE" | cut -d' ' -f1)"
  else
    STATUS_INVENTORY_REVISION="$(printf '' | sha256sum | cut -d' ' -f1)"
  fi
  if resource_snapshot_refresh "$INVENTORY_FILE" >/dev/null 2>&1; then
    cpu_reserve="$(parse_cpu_milli "${RESOURCE_CPU_RESERVE:-1}" 2>/dev/null || echo 0)"
    memory_reserve="$(parse_memory_bytes "${RESOURCE_MEMORY_RESERVE:-1g}" 2>/dev/null || echo 0)"
    STATUS_RESOURCES_JSON="{\"cpu_milli\":{\"budget\":$RESOURCE_CPU_BUDGET_MILLI,\"reserve\":$cpu_reserve,\"reserved\":$RESOURCE_CPU_RESERVED_MILLI,\"admissible\":$RESOURCE_CPU_ADMISSIBLE_MILLI},\"memory_bytes\":{\"budget\":$RESOURCE_MEMORY_BUDGET_BYTES,\"reserve\":$memory_reserve,\"reserved\":$RESOURCE_MEMORY_RESERVED_BYTES,\"admissible\":$RESOURCE_MEMORY_ADMISSIBLE_BYTES}}"
  fi
  STATUS_RESERVATIONS_JSON="$(status_reservations_json)"
  status_backend_refresh
}

status_backend_refresh() {
  local effective=invalid phase=invalid transition_id="" transition_revision="" ownership=""
  local compat_reason=missing valid=false helper_json='{}' operation=null latest
  : "${SCALESET_STATE_DIR:=${RUNDIR:-/run/ci-runner-farm}/scalesets}"
  : "${SCALESET_COMPAT:=${CFGDIR:-/boot/config/plugins/ci-runner-farm}/scaleset-compatibility.json}"
  : "${SCALESET_HELPER:=${SCRIPT_DIR:-/usr/local/emhttp/plugins/ci-runner-farm/include}/../bin/crf-scaleset}"
  if declare -F migration_load >/dev/null && migration_load; then
    effective="$MIGRATION_EFFECTIVE_BACKEND"; phase="$MIGRATION_PHASE"
    transition_id="$MIGRATION_TRANSITION_ID"; transition_revision="$MIGRATION_REVISION"
    ownership="$MIGRATION_OWNERSHIP_REVISION"
  fi
  if [ -z "$ownership" ]; then
    ownership="$(printf '%s\0%s\0%s\0%s\0%s' "${GH_OWNER:-}" "${AUTH_MODE:-pat}" \
      "${GITHUB_APP_INSTALLATION_ID:-pat}" "${RUNNER_GROUP:-}" \
      "$(cat /etc/machine-id 2>/dev/null)" | sha256sum | cut -d' ' -f1)"
  fi
  STATUS_BACKEND_JSON="{\"requested\":\"$(printf '%s' "${POOL_BACKEND:-classic}"|json_escape)\",\"effective\":\"$(printf '%s' "$effective"|json_escape)\",\"transition_phase\":\"$(printf '%s' "$phase"|json_escape)\",\"transition_id\":\"$(printf '%s' "$transition_id"|json_escape)\",\"transition_revision\":\"$(printf '%s' "$transition_revision"|json_escape)\",\"ownership_revision\":\"$(printf '%s' "$ownership"|json_escape)\"}"
  if declare -F scaleset_record_reason >/dev/null; then
    compat_reason="$(scaleset_record_reason)"
    [ "$compat_reason" = valid ] && valid=true
  elif declare -F scaleset_record_valid >/dev/null && scaleset_record_valid; then
    valid=true; compat_reason=valid
  elif [ -f "$SCALESET_COMPAT" ]; then compat_reason=invalid_compatibility_record
  fi
  if [ -x "$SCALESET_HELPER" ]; then
    helper_json="$("$SCALESET_HELPER" version 2>/dev/null)" || helper_json='{}'
    printf '%s' "$helper_json" | php -r 'exit(is_array(json_decode(stream_get_contents(STDIN),true))?0:1);' ||
      helper_json='{}'
  else
    compat_reason=helper_unavailable; valid=false
  fi
  if [ -f "$SCALESET_COMPAT" ]; then
    STATUS_COMPATIBILITY_JSON="$(php -r '
      $j=json_decode(file_get_contents($argv[1]),true);if(!is_array($j))$j=[];
      $h=json_decode($argv[4],true);if(!is_array($h))$h=[];
      $out=["valid"=>$argv[2]==="true","reason"=>$argv[3],
        "record_id"=>$j["compatibility_record_id"]??"",
        "tested_at"=>$j["tested_at"]??null,
        "age_seconds"=>max(0,time()-(int)@filemtime($argv[1])),
        "helper_digest"=>$j["helper_digest"]??"",
        "plugin_digest"=>$j["plugin_digest"]??"",
        "image_digest"=>$j["image_digest"]??"",
        "entrypoint_digest"=>$j["entrypoint_digest"]??"",
        "module_revision"=>$j["module_revision"]??($h["module_revision"]??""),
        "go_version"=>$j["go_version"]??($h["go_version"]??""),
        "runner_group_id"=>$j["runner_group_id"]??null,
        "runner_group_policy"=>$j["runner_group_policy"]??"",
        "owner"=>$j["owner"]??"",
        "auth_mode"=>$argv[5],
        "private_key_configured"=>is_file($argv[6])&&((fileperms($argv[6])&0777)===0600)];
      echo json_encode($out,JSON_UNESCAPED_SLASHES);
    ' "$SCALESET_COMPAT" "$valid" "$compat_reason" "$helper_json" "${AUTH_MODE:-pat}" \
      "${GITHUB_APP_KEY_FILE:-/nonexistent}")"
  else
    STATUS_COMPATIBILITY_JSON="{\"valid\":false,\"reason\":\"$compat_reason\",\"auth_mode\":\"$(printf '%s' "${AUTH_MODE:-pat}"|json_escape)\",\"private_key_configured\":$([ -f "${GITHUB_APP_KEY_FILE:-/nonexistent}" ] && echo true || echo false)}"
  fi
  latest="$(find "$SCALESET_STATE_DIR/operations" -maxdepth 1 -type f -name '*.json' -printf '%T@ %p\n' 2>/dev/null |
    sort -nr | head -1 | cut -d' ' -f2- || true)"
  if [ -n "$latest" ]; then
    operation="$(cat "$latest" 2>/dev/null)"
    printf '%s' "$operation" | php -r 'exit(is_array(json_decode(stream_get_contents(STDIN),true))?0:1);' ||
      operation=null
  fi
  STATUS_OPERATION_JSON="$operation"
}
