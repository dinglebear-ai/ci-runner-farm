#!/bin/bash

if ! declare -F crf_runtime_run_prepared >/dev/null 2>&1; then
  CRF_RUNTIME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-runtime.sh
  . "$CRF_RUNTIME_DIR/runner-runtime.sh"
  unset CRF_RUNTIME_DIR
fi
# Execute one already-admitted scale-set work item. Demand, session ownership,
# and backend transitions are deliberately outside this file.

# REVIEW(crf-v3q.13.16, MUST-CHECK): ACK/acquire/JIT recovery must survive a
# host reboot. Keep PIDs, sockets, snapshots, and short leases in RUNDIR tmpfs,
# but persist bounded operation state on the configured cache dataset.
JIT_BOOTSTRAP_STATE_DIR="${JIT_BOOTSTRAP_STATE_DIR:-$CACHE_ROOT/state/jit}"
JIT_STATE_DIR_PINNED="${JIT_STATE_DIR+x}"
JIT_STATE_DIR_CONFIGURED="${JIT_STATE_DIR-}"
JIT_LOG_ROOT_PINNED="${JIT_LOG_ROOT+x}"
JIT_LOG_ROOT_CONFIGURED="${JIT_LOG_ROOT-}"
JIT_LEGACY_STATE_DIR="${JIT_LEGACY_STATE_DIR:-$RUNDIR/jit}"
JIT_LOG_MAX_BYTES="${JIT_LOG_MAX_BYTES:-268435456}"
JIT_LOG_MAX_DAYS="${JIT_LOG_MAX_DAYS:-7}"
JIT_HANDOFF_GRACE_SECONDS="${JIT_HANDOFF_GRACE_SECONDS:-300}"
JIT_RECENT_ACTIVITY_FILE="${JIT_RECENT_ACTIVITY_FILE:-$RUNDIR/recent-jobs.jsonl}"
JIT_RECENT_ACTIVITY_MAX="${JIT_RECENT_ACTIVITY_MAX:-50}"

jit_paths_refresh() {
  if [ "$JIT_STATE_DIR_PINNED" = x ]; then
    JIT_STATE_DIR="$JIT_STATE_DIR_CONFIGURED"
  else
    JIT_STATE_DIR="$CACHE_ROOT/state/jit"
  fi
  if [ "$JIT_LOG_ROOT_PINNED" = x ]; then
    JIT_LOG_ROOT="$JIT_LOG_ROOT_CONFIGURED"
  else
    JIT_LOG_ROOT="$CACHE_ROOT/logs/runners"
  fi
}

jit_paths_refresh

jit_id_valid() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ ]]; }

jit_state_write() {
  local runner_id="$1" phase="$2" reservation="$3" handle="$4" container="$5" pool="${6:-}" tmp path
  case "$phase" in
    admitted|jit_received|container_create_started|container_observed|secret_consumed|running|terminal|deleting|deleted|failed) ;;
    *) return 1 ;;
  esac
  [ -z "$pool" ] || pool_id_valid "$pool" || return 1
  mkdir -p "$JIT_STATE_DIR" && chmod 0700 "$JIT_STATE_DIR" || return 1
  path="$JIT_STATE_DIR/$runner_id.state"; tmp="$path.tmp.$$"
  (
    umask 077
    printf 'schema_version=1\nrunner_id=%s\nphase=%s\nreservation_id=%s\nwork_handle=%s\ncontainer_name=%s\npool_id=%s\nupdated_at=%s\n' \
      "$runner_id" "$phase" "$reservation" "$handle" "$container" "$pool" "$(date +%s)"
  ) >"$tmp" && chmod 0600 "$tmp" && mv "$tmp" "$path"
}

jit_state_field() {
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}

jit_container_exists() {
  docker inspect "$1" >/dev/null 2>&1
}

jit_container_running() {
  [ "$(docker inspect --format '{{.State.Running}}' "$1" 2>/dev/null)" = true ]
}

jit_pool_from_runner_id() {
  local runner_id="$1" rest pool suffix
  rest="${runner_id#"$NAME_PREFIX-jit-"}"
  [ "$rest" != "$runner_id" ] || return 1
  pool="${rest%-????????????????????}"
  suffix="${rest#"$pool-"}"
  pool_id_valid "$pool" && [[ "$suffix" =~ ^[0-9a-f]{20}$ ]] || return 1
  printf '%s\n' "$pool"
}

jit_container_identity_pool() {
  local container="$1" runner_id="$2" handle="$3" managed backend labeled_runner labeled_handle pool
  jit_container_exists "$container" || return 1
  managed="$(docker inspect --format "{{ index .Config.Labels \"${LABEL_NS}.managed\" }}" "$container" 2>/dev/null)"
  backend="$(docker inspect --format "{{ index .Config.Labels \"${LABEL_NS}.backend\" }}" "$container" 2>/dev/null)"
  labeled_runner="$(docker inspect --format "{{ index .Config.Labels \"${LABEL_NS}.runner-id\" }}" "$container" 2>/dev/null)"
  labeled_handle="$(docker inspect --format "{{ index .Config.Labels \"${LABEL_NS}.work-handle\" }}" "$container" 2>/dev/null)"
  pool="$(docker inspect --format "{{ index .Config.Labels \"${LABEL_NS}.pool\" }}" "$container" 2>/dev/null)"
  [ "$managed" = true ] && [ "$backend" = scaleset ] &&
    [ "$labeled_runner" = "$runner_id" ] && [ "$labeled_handle" = "$handle" ] &&
    pool_id_valid "$pool" || return 1
  printf '%s\n' "$pool"
}

jit_state_pool() {
  local state="$1" reservation="$2" runner_id="$3" handle="$4" container="$5" pool=""
  reservation_dir_ensure || return 1
  pool="$(jit_state_field "$state" pool_id)"
  if ! pool_id_valid "$pool"; then
    pool="$(jit_container_identity_pool "$container" "$runner_id" "$handle" 2>/dev/null)" || pool=""
  fi
  if ! pool_id_valid "$pool" && [ -f "$RESERVATION_DIR/$reservation.state" ]; then
    pool="$(reservation_field "$RESERVATION_DIR/$reservation.state" pool_id)"
  fi
  if ! pool_id_valid "$pool"; then
    pool="$(jit_pool_from_runner_id "$runner_id" 2>/dev/null)" || return 1
  fi
  if jit_container_exists "$container"; then
    [ "$(jit_container_identity_pool "$container" "$runner_id" "$handle")" = "$pool" ] || return 1
  fi
  printf '%s\n' "$pool"
}

jit_container_secret_consumed() {
  docker exec "$1" test -f /run/crf/consumed >/dev/null 2>&1
}

jit_state_stale() {
  local state="$1" updated now
  updated="$(jit_state_field "$state" updated_at)"
  now="$(date +%s)"
  [[ "$updated" =~ ^[0-9]+$ ]] && [[ "$JIT_HANDOFF_GRACE_SECONDS" =~ ^[1-9][0-9]*$ ]] || return 0
  [ "$now" -ge "$updated" ] && [ $((now - updated)) -ge "$JIT_HANDOFF_GRACE_SECONDS" ]
}

jit_import_state_dir() {
  local source_dir="$1" legacy runner_id phase current tmp
  [ "$source_dir" != "$JIT_STATE_DIR" ] || return 0
  [ -d "$source_dir" ] || return 0
  mkdir -p "$JIT_STATE_DIR" && chmod 0700 "$JIT_STATE_DIR" || return 1
  for legacy in "$source_dir"/*.state; do
    [ -f "$legacy" ] && [ ! -L "$legacy" ] || continue
    runner_id="${legacy##*/}"; runner_id="${runner_id%.state}"
    jit_id_valid "$runner_id" && [ "$(jit_state_field "$legacy" runner_id)" = "$runner_id" ] || continue
    phase="$(jit_state_field "$legacy" phase)"
    if [ "$phase" = deleted ] && ! jit_container_exists "$runner_id"; then
      rm -f -- "$legacy"
      continue
    fi
    current="$JIT_STATE_DIR/$runner_id.state"
    if [ ! -e "$current" ]; then
      tmp="$current.tmp.$$"
      if ! ( umask 077; cp -- "$legacy" "$tmp" ) ||
         ! chmod 0600 "$tmp" || ! mv "$tmp" "$current"; then
        rm -f -- "$tmp"
        return 1
      fi
    fi
    [ -f "$current" ] && rm -f -- "$legacy"
  done
}

jit_import_legacy_states() {
  jit_import_state_dir "$JIT_LEGACY_STATE_DIR" || return 1
  [ "$JIT_BOOTSTRAP_STATE_DIR" = "$JIT_LEGACY_STATE_DIR" ] ||
    jit_import_state_dir "$JIT_BOOTSTRAP_STATE_DIR"
}

jit_capture_diagnostics() {
  local container="$1" runner_id="$2" out tmp file total
  out="$JIT_LOG_ROOT/$runner_id"
  mkdir -p "$out" && chmod 0700 "$JIT_LOG_ROOT" "$out" 2>/dev/null || return 1
  tmp="$out/.capture.$$"; mkdir -p "$tmp" || return 1
  docker cp "$container:/actions-runner/_diag/." "$tmp/" >/dev/null 2>&1 || true
  find "$tmp" -type f \( -name 'Runner_*' -o -name 'Worker_*' \) -size -16M -print0 2>/dev/null |
    while IFS= read -r -d '' file; do
      sed -E \
        -e 's/(github_pat_|gh[pousr]_|ghs_)[A-Za-z0-9_]{8,}/[REDACTED]/g' \
        -e 's/(registrationToken|runnerRequestId|authorization)[\"=: ]+[A-Za-z0-9._+\\/=:-]{8,}/\1=[REDACTED]/Ig' \
        "$file" >"$out/$(basename "$file")"
      chmod 0600 "$out/$(basename "$file")"
    done
  rm -rf "$tmp"
  find "$JIT_LOG_ROOT" -mindepth 1 -type f -mtime "+$JIT_LOG_MAX_DAYS" -delete 2>/dev/null || true
  total="$(find "$JIT_LOG_ROOT" -type f -printf '%T@ %s %p\n' 2>/dev/null |
    sort -nr | awk -v cap="$JIT_LOG_MAX_BYTES" '{sum+=$2; if(sum>cap) print substr($0,index($0,$3))}')"
  [ -z "$total" ] || while IFS= read -r file; do rm -f -- "$file"; done <<<"$total"
}

jit_recent_activity_record() {
  local runner_id="$1" pool="$2" handle="$3" out job result conclusion completed_at
  local record lock tmp max="$JIT_RECENT_ACTIVITY_MAX"
  jit_id_valid "$runner_id" && pool_id_valid "$pool" && [[ "$handle" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ "$max" =~ ^[1-9][0-9]*$ ]] && [ "$max" -le 200 ] || return 1
  out="$JIT_LOG_ROOT/$runner_id"
  [ -d "$out" ] || return 0
  job="$(grep -h 'Running job:' "$out"/Runner_* 2>/dev/null | tail -n 1 | sed 's/^.*Running job: //')"
  [ -n "$job" ] || return 0
  result="$(grep -h 'Job result after all job steps finish:' "$out"/Worker_* 2>/dev/null | tail -n 1 | sed 's/^.*finish: //')"
  case "$result" in Succeeded) conclusion=success ;; Failed) conclusion=failure ;;
    Canceled|Cancelled) conclusion=cancelled ;; *) conclusion=unknown ;; esac
  completed_at="$(grep -h 'Job completed' "$out"/Worker_* 2>/dev/null | tail -n 1 | sed -n 's/^\[\([^ ]* [^ ]*Z\).*/\1/p')"
  record="$(php -r '
    $time=strtotime($argv[6]);if($time===false)$time=time();
    echo json_encode(["schema_version"=>1,"observed_at"=>time(),
      "completed_at"=>gmdate("c",$time),"runner_name"=>$argv[1],"pool_id"=>$argv[2],
      "work_handle"=>(int)$argv[3],"job"=>substr($argv[4],0,512),
      "conclusion"=>$argv[5]],JSON_UNESCAPED_SLASHES);
  ' "$runner_id" "$pool" "$handle" "$job" "$conclusion" "$completed_at")" || return 1
  mkdir -p "$(dirname "$JIT_RECENT_ACTIVITY_FILE")" || return 1
  lock="$JIT_RECENT_ACTIVITY_FILE.lock"; tmp="$JIT_RECENT_ACTIVITY_FILE.tmp.$$"
  (
    umask 077; exec 7>"$lock" || exit 1; chmod 0600 "$lock" || exit 1; flock -x 7 || exit 1
    if [ -f "$JIT_RECENT_ACTIVITY_FILE" ] && [ ! -L "$JIT_RECENT_ACTIVITY_FILE" ]; then
      grep -Fv "\"runner_name\":\"$runner_id\"" "$JIT_RECENT_ACTIVITY_FILE" 2>/dev/null |
        tail -n "$((max - 1))" >"$tmp" || true
    else
      : >"$tmp"
    fi
    printf '%s\n' "$record" >>"$tmp"
    chmod 0600 "$tmp" && mv -f "$tmp" "$JIT_RECENT_ACTIVITY_FILE"
  )
}

jit_retire_handle() {
  local pool="$1" handle="$2" payload response rc=0
  pool_id_valid "$pool" && jit_id_valid "$handle" || return 1
  payload="$(php -r 'echo json_encode(["pool_id"=>$argv[1],"work_handle"=>(int)$argv[2]],
    JSON_UNESCAPED_SLASHES);' "$pool" "$handle")" || return 1
  response="$(scaleset_request retire_jit "$payload")" || rc=$?
  local validation_rc
  if printf '%s' "$response" | php -r '
    $j=json_decode(stream_get_contents(STDIN),true);
    if(($j["ok"]??false)===true&&($j["result"]["retired"]??false)===true)exit(0);
    // A root-owned local deleting record proves this handle was issued. If the
    // controller no longer has its tombstone, retirement already committed and
    // only the response was lost. Treat that one terminal code as idempotent.
    if(($j["ok"]??true)===false&&($j["code"]??"")==="work_handle_not_issued")exit(0);
    exit(2);
  '; then
    return 0
  else
    validation_rc=$?
  fi
  [ "$rc" -ne 0 ] && return "$rc"
  return "$validation_rc"
}

jit_cleanup_observed() {
  local runner_id="$1" reservation="$2" handle="$3" container="$4" pool="${5:-}" state
  reservation_dir_ensure || return 1
  state="$JIT_STATE_DIR/$runner_id.state"
  if ! pool_id_valid "$pool"; then
    pool="$(jit_state_pool "$state" "$reservation" "$runner_id" "$handle" "$container")" || return 1
  elif jit_container_exists "$container"; then
    [ "$(jit_container_identity_pool "$container" "$runner_id" "$handle")" = "$pool" ] || return 1
  fi
  jit_state_write "$runner_id" deleting "$reservation" "$handle" "$container" "$pool" || return 1
  jit_capture_diagnostics "$container" "$runner_id" || true
  jit_recent_activity_record "$runner_id" "$pool" "$handle" || true
  crf_runtime_force_remove "$container" || true
  if jit_container_exists "$container"; then
    return 1
  fi
  # REVIEW(crf-v3q.13.10): The helper first compacts replay proof, then the
  # shell releases its resource reservation. Failure leaves deleting state for
  # a conservative retry and never permits an old work handle to be reissued.
  jit_retire_handle "$pool" "$handle" || return 1
  reservation_release "$reservation" || return 1
  jit_state_write "$runner_id" deleted "$reservation" "$handle" "$container" "$pool" || return 1
  rm -f "$state"
}

jit_execute() {
  local pool="$1" reservation="$2" handle="$3" spec_hash="$4"
  local config_revision="$5" runner_id container idx rc jit_image descriptor=""
  IFS= read -r descriptor || [ -n "$descriptor" ] || true
  backend_scaleset_admission_allowed ||
    { err "JIT admission is blocked by backend transition state"; return 1; }
  if ! pool_id_valid "$pool" ||
     ! jit_id_valid "$reservation" ||
     ! jit_id_valid "$handle"; then
    err "invalid JIT operation identity"
    return 1
  fi
  [ -n "$descriptor" ] && [ "${#descriptor}" -le 65536 ] &&
    [[ "$descriptor" =~ ^[A-Za-z0-9._+/=-]+$ ]] ||
    { err "invalid JIT descriptor"; return 1; }
  [ "$(reservation_field "$RESERVATION_DIR/$reservation.state" phase)" = assigned ] &&
    [ "$(reservation_field "$RESERVATION_DIR/$reservation.state" pool_id)" = "$pool" ] &&
    [ "$(reservation_field "$RESERVATION_DIR/$reservation.state" runner_spec_hash)" = "$spec_hash" ] &&
    [ "$(reservation_field "$RESERVATION_DIR/$reservation.state" config_revision)" = "$config_revision" ] ||
    { err "JIT reservation is not a committed scheduler admission"; return 1; }

  runner_id="$(printf '%s' "$pool|$handle|$reservation" | sha256sum | cut -c1-20)"
  container="${NAME_PREFIX}-jit-${pool}-${runner_id}"
  runner_id="$container"
  idx=$((16#$(printf '%s' "$runner_id" | sha256sum | cut -c1-6) % 1000000))
  jit_state_write "$runner_id" admitted "$reservation" "$handle" "$container" "$pool" || return 1
  jit_state_write "$runner_id" jit_received "$reservation" "$handle" "$container" "$pool" || return 1

  mkdir -p "$CACHE_ROOT/work/$runner_id" "$CACHE_ROOT/docker/$runner_id" "$JIT_LOG_ROOT/$runner_id" ||
    return 1
  chmod 0700 "$CACHE_ROOT/work/$runner_id" "$CACHE_ROOT/docker/$runner_id" "$JIT_LOG_ROOT/$runner_id" 2>/dev/null || true

  # Dynamically scoped input consumed by build_args.
  # shellcheck disable=SC2034
  local NO_REGISTER=1
  build_args "$idx" "$container" "$pool" "org:$GH_OWNER" || return 1
  [[ "${CRF_IMAGE_ARG_INDEX:-}" =~ ^[0-9]+$ ]] ||
    { err "runner image argument index is invalid"; return 1; }
  jit_image="${ARGS[$CRF_IMAGE_ARG_INDEX]}"
  # JIT invokes ./run.sh --jitconfig itself in the protected wrapper, so keep
  # all Docker options before the image and intentionally drop the classic
  # listener command that follows it.
  ARGS=("${ARGS[@]:0:$CRF_IMAGE_ARG_INDEX}")
  ARGS+=(
    --label "${LABEL_NS}.backend=scaleset"
    --label "${LABEL_NS}.runner-id=$runner_id"
    --label "${LABEL_NS}.work-handle=$handle"
    -e CRF_CREDENTIAL_KIND=jit
    -e EPHEMERAL=true
    "$jit_image"
  )
  jit_state_write "$runner_id" container_create_started "$reservation" "$handle" "$container" "$pool" || return 1
  crf_runtime_run_prepared
  rc=$?
  if jit_container_exists "$container"; then
    jit_state_write "$runner_id" container_observed "$reservation" "$handle" "$container" "$pool" || return 1
  else
    # An unobserved create remains conservatively charged for recovery.
    jit_state_write "$runner_id" failed "$reservation" "$handle" "$container" "$pool" || true
    return "${rc:-1}"
  fi
  if ! runner_secret_inject "$container" "$descriptor"; then
    err "JIT runner $runner_id did not consume its protected descriptor"
    jit_cleanup_observed "$runner_id" "$reservation" "$handle" "$container" "$pool"
    return 1
  fi
  descriptor=""
  unset descriptor
  jit_state_write "$runner_id" secret_consumed "$reservation" "$handle" "$container" "$pool" || return 1
  jit_state_write "$runner_id" running "$reservation" "$handle" "$container" "$pool" || return 1
  return 0
}

jit_reconcile_orphan_containers() {
  local container state status handle pool reservation
  while IFS= read -r container; do
    [ -n "$container" ] || continue
    jit_pool_from_runner_id "$container" >/dev/null 2>&1 || continue
    state="$JIT_STATE_DIR/$container.state"
    [ ! -e "$state" ] || continue
    status="$(docker inspect --format '{{.State.Status}}' "$container" 2>/dev/null)"
    case "$status" in exited|dead) ;; *) continue ;; esac
    handle="$(docker inspect --format "{{ index .Config.Labels \"${LABEL_NS}.work-handle\" }}" "$container" 2>/dev/null)"
    jit_id_valid "$handle" || continue
    pool="$(jit_container_identity_pool "$container" "$container" "$handle")" || continue
    reservation="orphan-${container#"$NAME_PREFIX-jit-"}"
    jit_state_write "$container" terminal "$reservation" "$handle" "$container" "$pool" || continue
    jit_cleanup_observed "$container" "$reservation" "$handle" "$container" "$pool" || true
  done < <(docker ps -a \
    --filter "label=${LABEL_NS}.managed=true" \
    --filter "label=${LABEL_NS}.backend=scaleset" \
    --format '{{.Names}}' 2>/dev/null)
}

jit_reconcile() {
  local state phase runner_id reservation handle container pool
  reservation_dir_ensure || return 1
  jit_import_legacy_states || return 1
  mkdir -p "$JIT_STATE_DIR" 2>/dev/null || return 1
  for state in "$JIT_STATE_DIR"/*.state; do
    [ -f "$state" ] && [ ! -L "$state" ] || continue
    runner_id="${state##*/}"; runner_id="${runner_id%.state}"
    phase="$(jit_state_field "$state" phase)"
    reservation="$(jit_state_field "$state" reservation_id)"
    handle="$(jit_state_field "$state" work_handle)"
    container="$(jit_state_field "$state" container_name)"
    jit_id_valid "$runner_id" && jit_id_valid "$reservation" && jit_id_valid "$handle" &&
      [ "$container" = "$runner_id" ] || continue
    pool="$(jit_state_pool "$state" "$reservation" "$runner_id" "$handle" "$container")" || continue
    case "$phase" in
      terminal|deleting)
        jit_cleanup_observed "$runner_id" "$reservation" "$handle" "$container" "$pool" || true
        ;;
      running|secret_consumed)
        if ! jit_container_running "$container"; then
          jit_state_write "$runner_id" terminal "$reservation" "$handle" "$container" "$pool" &&
            jit_cleanup_observed "$runner_id" "$reservation" "$handle" "$container" "$pool" || true
        fi
        ;;
      admitted|jit_received|container_create_started|container_observed|failed)
        if jit_container_exists "$container"; then
          if jit_container_secret_consumed "$container"; then
            jit_state_write "$runner_id" running "$reservation" "$handle" "$container" "$pool" || true
          elif jit_state_stale "$state"; then
            jit_state_write "$runner_id" terminal "$reservation" "$handle" "$container" "$pool" &&
              jit_cleanup_observed "$runner_id" "$reservation" "$handle" "$container" "$pool" || true
          fi
        elif jit_state_stale "$state"; then
          jit_retire_handle "$pool" "$handle" &&
            reservation_release "$reservation" &&
            jit_state_write "$runner_id" deleted "$reservation" "$handle" "$container" "$pool" || true
        fi
        ;;
      deleted)
        if jit_container_exists "$container" &&
           [ "$(jit_container_identity_pool "$container" "$runner_id" "$handle")" = "$pool" ]; then
          jit_capture_diagnostics "$container" "$runner_id" || true
          crf_runtime_force_remove "$container" || true
        fi
        ;;
    esac
  done
  jit_reconcile_orphan_containers
}
