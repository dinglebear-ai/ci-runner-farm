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
STATUS_RECENT_ACTIVITY_JSON='[]'

status_state_file_valid() {
  local path="$1" max="$2" size mode
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  size="$(stat -c %s "$path" 2>/dev/null || echo invalid)"
  mode="$(stat -c %a "$path" 2>/dev/null || echo 0)"
  [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -le "$max" ] && [ "$mode" = 600 ]
}

status_scaleset_pool_tsv() {
  local pool="$1" snapshot="${SCALESET_SNAPSHOT:-${SCALESET_STATE_DIR:-$RUNDIR/scalesets}/snapshot.json}"
  local ownership="${SCALESET_OWNERSHIP:-${CFGDIR:-/boot/config/plugins/ci-runner-farm}/scale-set-ownership.json}"
  local plan="${SCALESET_STATE_DIR:-$RUNDIR/scalesets}/last-plan.tsv"
  case "$pool" in ''|*[!A-Za-z0-9._:-]*) return 1 ;; esac
  status_state_file_valid "$snapshot" 262144 || {
    printf '%s\n' '-1|0|0|0|unknown|0|0|0|0|0'
    return
  }
  status_state_file_valid "$ownership" 262144 || ownership=/nonexistent
  status_state_file_valid "$plan" 65536 || plan=/nonexistent
  php -r '
    $pool=$argv[1];$snapshot=$argv[2];$ownership=$argv[3];$plan=$argv[4];
    $fallback=[-1,0,0,0,"unknown",0,0,0,0,0];
    $s=json_decode(@file_get_contents($snapshot),true);
    if(!is_array($s)||($s["schema_version"]??0)!==1||
      strtotime((string)($s["valid_until"]??""))<=time()){echo implode("|",$fallback),"\n";exit;}
    $p=null;foreach(($s["pools"]??[]) as $candidate)
      if(($candidate["pool_id"]??"")===$pool){$p=$candidate;break;}
    if(!is_array($p)){echo implode("|",$fallback),"\n";exit;}
    $state="missing";$remote=(int)($p["scale_set_id"]??0);$tombstone=0;$orphan=0;
    if(is_file($ownership)&&!is_link($ownership)){
      $o=json_decode(@file_get_contents($ownership),true);$found=false;
      foreach(($o["records"]??[]) as $record)if(($record["pool_id"]??"")===$pool){
        $found=true;$state=(string)($record["state"]??"unknown");
        $remote=(int)($record["scale_set_id"]??$remote);
        $tombstone=$state==="delete_pending"?1:0;break;
      }
      $orphan=$found?0:1;
    }
    $desired=0;$admitted=0;$blocked=0;
    if(is_file($plan)&&!is_link($plan))foreach(file($plan,FILE_IGNORE_NEW_LINES|FILE_SKIP_EMPTY_LINES) as $line){
      $parts=explode("|",$line);if(($parts[0]??"")!==$pool)continue;
      $desired=max(0,(int)($parts[1]??0));$admitted=max(0,(int)($parts[2]??0));
      if(isset($parts[8])&&preg_match("/^(0|[1-9][0-9]*)$/",$parts[8]))$blocked=(int)$parts[8];
      elseif(isset($parts[3])&&preg_match("/^(0|[1-9][0-9]*)$/",$parts[3]))$blocked=(int)$parts[3];
      break;
    }
    $out=[max(0,(int)($p["assigned_jobs"]??0)),max(0,(int)($p["advertised_capacity"]??0)),
      ($p["session_healthy"]??false)===true?1:0,max(0,$remote),$state,$tombstone,$orphan,
      max(0,$desired),max(0,$admitted),max(0,$blocked)];
    echo implode("|",$out),"\n";
  ' "$pool" "$snapshot" "$ownership" "$plan"
}

status_reservations_json() {
  local dir="${RESERVATION_DIR:-$RUNDIR/reservations}" file first=1
  printf '['
  for file in "$dir"/*.state; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    if declare -F reservation_state_valid >/dev/null; then
      reservation_state_valid "$file" || continue
    fi
    local operation pool runner cpu memory deadline phase
    operation="$(reservation_field "$file" operation_id 2>/dev/null)"
    pool="$(reservation_field "$file" pool_id 2>/dev/null)"
    runner="$(reservation_field "$file" runner_name 2>/dev/null)"
    cpu="$(reservation_field "$file" cpu_milli 2>/dev/null)"
    memory="$(reservation_field "$file" memory_bytes 2>/dev/null)"
    deadline="$(reservation_field "$file" deadline 2>/dev/null)"
    phase="$(reservation_field "$file" phase 2>/dev/null)"
    case "$operation" in ''|*[!A-Za-z0-9._:-]*) continue ;; esac
    case "$pool" in ''|*[!a-z0-9-]*) continue ;; esac
    case "$runner" in ''|*[!A-Za-z0-9._:-]*) continue ;; esac
    case "$phase" in reserved|offered|assigned|acting|observed|failed|expired) ;; *) continue ;; esac
    case "$cpu:$memory:$deadline" in *[!0-9:]*) continue ;; esac
    [ -n "$cpu" ] && [ -n "$memory" ] && [ -n "$deadline" ] || continue
    [ "${#operation}" -le 128 ] && [ "${#pool}" -le 24 ] && [ "${#runner}" -le 128 ] || continue
    [ "${#cpu}" -le 6 ] && [ "${#memory}" -le 13 ] && [ "${#deadline}" -le 10 ] || continue
    [ "$cpu" -gt 0 ] && [ "$cpu" -le 256000 ] &&
      [ "$memory" -gt 0 ] && [ "$memory" -le 1099511627776 ] &&
      [ "$deadline" -gt 0 ] || continue
    [ "$first" = 1 ] || printf ','
    first=0
    printf '{"operation_id":"%s","pool_id":"%s","runner_name":"%s","cpu_milli":%s,"memory_bytes":%s,"deadline":%s,"phase":"%s"}' \
      "$operation" "$pool" "$runner" "$cpu" "$memory" "$deadline" "$phase"
  done
  printf ']'
}


status_recent_activity_json() {
  local path="${JIT_RECENT_ACTIVITY_FILE:-${RUNDIR:-/run/ci-runner-farm}/recent-jobs.jsonl}"
  local max="${STATUS_RECENT_ACTIVITY_MAX:-20}" size mode
  STATUS_RECENT_ACTIVITY_JSON='[]'
  [[ "$max" =~ ^[1-9][0-9]*$ ]] && [ "$max" -le 50 ] || return 1
  [ -f "$path" ] && [ ! -L "$path" ] || return 0
  size="$(stat -c %s "$path" 2>/dev/null || echo 262145)"
  mode="$(stat -c %a "$path" 2>/dev/null || echo 0)"
  [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -le 262144 ] && [ "$mode" = 600 ] || return 1
  STATUS_RECENT_ACTIVITY_JSON="$(php -r '
    $max=(int)$argv[2];$rows=[];
    $valid=function($v){return is_array($v)&&($v["schema_version"]??0)===1&&
      is_int($v["observed_at"]??null)&&$v["observed_at"]>0&&
      is_string($v["completed_at"]??null)&&strlen($v["completed_at"])<=64&&
      is_string($v["runner_name"]??null)&&preg_match("/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/",$v["runner_name"])&&
      is_string($v["pool_id"]??null)&&preg_match("/^[a-z0-9]+(?:-[a-z0-9]+)*$/",$v["pool_id"])&&
      is_int($v["work_handle"]??null)&&$v["work_handle"]>0&&
      is_string($v["job"]??null)&&strlen($v["job"])<=512&&
      in_array($v["conclusion"]??null,["success","failure","cancelled","unknown"],true);};
    foreach(file($argv[1],FILE_IGNORE_NEW_LINES|FILE_SKIP_EMPTY_LINES)?:[] as $line){
      $row=json_decode($line,true);if($valid($row))$rows[]=$row;
    }
    echo json_encode(array_reverse(array_slice($rows,-$max)),JSON_UNESCAPED_SLASHES);
  ' "$path" "$max")" || { STATUS_RECENT_ACTIVITY_JSON='[]'; return 1; }
}

status_model_refresh() {
  local cpu_reserve=0 memory_reserve=0
  STATUS_RESOURCES_JSON='{"cpu_milli":{"budget":0,"reserve":0,"reserved":0,"admissible":0},"memory_bytes":{"budget":0,"reserve":0,"reserved":0,"admissible":0}}'
  STATUS_OBSERVED_AT="$(date +%s)"
  STATUS_CONFIG_REVISION="$(config_revision)"
  if [ -f "$INVENTORY_FILE" ] && [ ! -L "$INVENTORY_FILE" ]; then
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
  status_recent_activity_json || STATUS_RECENT_ACTIVITY_JSON='[]'
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
  # Before the first migration there is no persisted transition ownership yet.
  # Publish the same production+quarantine-bound revision that runtime-config
  # will use, otherwise Fleet sends the legacy fallback revision and the
  # supervisor correctly rejects its first apply_sessions request.
  if [ -z "$ownership" ] && declare -F scaleset_ownership_revision >/dev/null; then
    ownership="$(scaleset_ownership_revision 2>/dev/null || true)"
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
  elif [ -f "$SCALESET_COMPAT" ] && [ ! -L "$SCALESET_COMPAT" ]; then compat_reason=invalid_compatibility_record
  fi
  if [ -x "$SCALESET_HELPER" ]; then
    helper_json="$("$SCALESET_HELPER" version 2>/dev/null)" || helper_json='{}'
    printf '%s' "$helper_json" | php -r 'exit(is_array(json_decode(stream_get_contents(STDIN),true))?0:1);' ||
      helper_json='{}'
  else
    compat_reason=helper_unavailable; valid=false
  fi
  if [ -f "$SCALESET_COMPAT" ] && [ ! -L "$SCALESET_COMPAT" ]; then
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
        "private_key_configured"=>is_file($argv[6])&&!is_link($argv[6])&&((fileperms($argv[6])&0777)===0600)];
      echo json_encode($out,JSON_UNESCAPED_SLASHES);
    ' "$SCALESET_COMPAT" "$valid" "$compat_reason" "$helper_json" "${AUTH_MODE:-pat}" \
      "${GITHUB_APP_KEY_FILE:-/nonexistent}")"
  else
    local escaped_reason private_key_configured=false key_path="${GITHUB_APP_KEY_FILE:-/nonexistent}"
    escaped_reason="$(printf '%s' "$compat_reason" | json_escape)"
    if [ -f "$key_path" ] && [ ! -L "$key_path" ] &&
       [ "$(stat -c %a "$key_path" 2>/dev/null || echo 0)" = 600 ]; then
      private_key_configured=true
    fi
    STATUS_COMPATIBILITY_JSON="{\"valid\":false,\"reason\":\"$escaped_reason\",\"auth_mode\":\"$(printf '%s' "${AUTH_MODE:-pat}"|json_escape)\",\"private_key_configured\":$private_key_configured}"
  fi
  latest="$(find "$SCALESET_STATE_DIR/operations" -maxdepth 1 -type f -name '*.json' -printf '%T@ %p\n' 2>/dev/null |
    sort -nr | head -1 | cut -d' ' -f2- || true)"
  if [ -n "$latest" ] && status_state_file_valid "$latest" 262144; then
    operation="$(cat "$latest" 2>/dev/null)"
    printf '%s' "$operation" | php -r 'exit(is_array(json_decode(stream_get_contents(STDIN),true))?0:1);' ||
      operation=null
  fi
  STATUS_OPERATION_JSON="$operation"
}
