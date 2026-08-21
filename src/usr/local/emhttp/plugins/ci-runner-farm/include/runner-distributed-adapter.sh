#!/bin/bash
# Local execution bridge for controller-approved distributed container placements.
# This layer does not schedule work, mint/retire GitHub JIT state, or receive GitHub credentials.

DISTRIBUTED_ADAPTER_MAX_STATE_FILES=4096

distributed_adapter_paths_refresh() {
  DISTRIBUTED_ADAPTER_STATE_DIR="${DISTRIBUTED_ADAPTER_STATE_DIR:-$RUNDIR/distributed-adapter}"
  DISTRIBUTED_ADAPTER_LOG_ROOT="${DISTRIBUTED_ADAPTER_LOG_ROOT:-$CACHE_ROOT/distributed-logs}"
}

distributed_adapter_dir_ensure() {
  distributed_adapter_paths_refresh
  [ ! -L "$DISTRIBUTED_ADAPTER_STATE_DIR" ] || return 1
  mkdir -p "$DISTRIBUTED_ADAPTER_STATE_DIR" || return 1
  [ -d "$DISTRIBUTED_ADAPTER_STATE_DIR" ] && chmod 0700 "$DISTRIBUTED_ADAPTER_STATE_DIR"
}

distributed_adapter_key() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
distributed_adapter_state_path() { printf '%s/%s.state\n' "$DISTRIBUTED_ADAPTER_STATE_DIR" "$(distributed_adapter_key "$1")"; }
distributed_adapter_reservation_id() { printf 'dist-%s\n' "$(distributed_adapter_key "$1" | cut -c1-32)"; }
distributed_adapter_container_name() { printf '%s-dist-%s-%s\n' "$NAME_PREFIX" "$2" "$(distributed_adapter_key "$1" | cut -c1-20)"; }

distributed_adapter_phase_valid() { case "${1:-}" in prepared|starting|observed|running|cancelling|terminal) return 0;; *) return 1;; esac; }
distributed_adapter_terminal_kind_valid() { case "${1:-}" in ''|finished|failed|cancelled) return 0;; *) return 1;; esac; }
distributed_adapter_container_id_valid() { [[ "${1:-}" =~ ^[0-9a-f]{64}$ ]]; }

distributed_adapter_state_write() {
  local placement="$1" command="$2" pool="$3" runner="$4" container="$5" container_id="$6" reservation="$7"
  local cpu="$8" memory="$9" spec="${10}" revision="${11}" phase="${12}" terminal_kind="${13:-}" detail="${14:-}"
  local path tmp
  distributed_adapter_dir_ensure || return 1
  jit_id_valid "$placement" && jit_id_valid "$command" && pool_id_valid "$pool" && reservation_name_valid "$runner" &&
    reservation_name_valid "$container" && reservation_id_valid "$reservation" &&
    resource_positive_uint_valid "$cpu" 256000 && resource_positive_uint_valid "$memory" 1099511627776 &&
    reservation_token_valid "$spec" && reservation_token_valid "$revision" && distributed_adapter_phase_valid "$phase" &&
    distributed_adapter_terminal_kind_valid "$terminal_kind" || return 1
  [ -z "$container_id" ] || distributed_adapter_container_id_valid "$container_id" || return 1
  [ -z "$detail" ] || jit_id_valid "$detail" || return 1
  if [ "$phase" = terminal ]; then
    [ -n "$terminal_kind" ] || return 1
    [ "$terminal_kind" != failed ] || [ -n "$detail" ] || return 1
  else
    [ -z "$terminal_kind" ] && [ -z "$detail" ] || return 1
  fi
  path="$(distributed_adapter_state_path "$placement")"; tmp="$path.tmp.$$"
  {
    umask 077
    printf 'schema_version=1\nplacement_id=%s\ncommand_id=%s\npool_id=%s\nrunner_name=%s\ncontainer_name=%s\ncontainer_id=%s\nreservation_id=%s\ncpu_milli=%s\nmemory_bytes=%s\nrunner_spec_hash=%s\nconfig_revision=%s\nphase=%s\nterminal_kind=%s\ndetail_code=%s\n' \
      "$placement" "$command" "$pool" "$runner" "$container" "$container_id" "$reservation" "$cpu" "$memory" "$spec" "$revision" "$phase" "$terminal_kind" "$detail" >"$tmp"
  } || { rm -f -- "$tmp"; return 1; }
  if ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp"
    return 1
  fi
}

distributed_adapter_state_field() {
  local path="$1" key="$2"
  case "$key" in schema_version|placement_id|command_id|pool_id|runner_name|container_name|container_id|reservation_id|cpu_milli|memory_bytes|runner_spec_hash|config_revision|phase|terminal_kind|detail_code) ;; *) return 1;; esac
  sed -n "s/^${key}=//p" "$path" | head -1
}

distributed_adapter_state_valid() {
  local path="$1" key placement command pool runner container container_id reservation cpu memory spec revision phase terminal detail size mode
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  size="$(stat -c %s "$path" 2>/dev/null || echo 8193)"; mode="$(stat -c %a "$path" 2>/dev/null || echo 0)"
  resource_uint_valid "$size" 8192 && [ "$mode" = 600 ] || return 1
  for key in schema_version placement_id command_id pool_id runner_name container_name container_id reservation_id cpu_milli memory_bytes runner_spec_hash config_revision phase terminal_kind detail_code; do
    [ "$(grep -c "^${key}=" "$path" 2>/dev/null)" = 1 ] || return 1
  done
  [ "$(distributed_adapter_state_field "$path" schema_version)" = 1 ] || return 1
  placement="$(distributed_adapter_state_field "$path" placement_id)"; command="$(distributed_adapter_state_field "$path" command_id)"
  pool="$(distributed_adapter_state_field "$path" pool_id)"; runner="$(distributed_adapter_state_field "$path" runner_name)"
  container="$(distributed_adapter_state_field "$path" container_name)"; container_id="$(distributed_adapter_state_field "$path" container_id)"
  reservation="$(distributed_adapter_state_field "$path" reservation_id)"; cpu="$(distributed_adapter_state_field "$path" cpu_milli)"
  memory="$(distributed_adapter_state_field "$path" memory_bytes)"; spec="$(distributed_adapter_state_field "$path" runner_spec_hash)"
  revision="$(distributed_adapter_state_field "$path" config_revision)"; phase="$(distributed_adapter_state_field "$path" phase)"
  terminal="$(distributed_adapter_state_field "$path" terminal_kind)"; detail="$(distributed_adapter_state_field "$path" detail_code)"
  jit_id_valid "$placement" && jit_id_valid "$command" && pool_id_valid "$pool" && reservation_name_valid "$runner" &&
    reservation_name_valid "$container" && reservation_id_valid "$reservation" && resource_positive_uint_valid "$cpu" 256000 &&
    resource_positive_uint_valid "$memory" 1099511627776 && reservation_token_valid "$spec" && reservation_token_valid "$revision" &&
    distributed_adapter_phase_valid "$phase" && distributed_adapter_terminal_kind_valid "$terminal" &&
    [ "$container" = "$(distributed_adapter_container_name "$placement" "$pool")" ] &&
    [ "$reservation" = "$(distributed_adapter_reservation_id "$placement")" ] &&
    { [ -z "$container_id" ] || distributed_adapter_container_id_valid "$container_id"; } &&
    { [ -z "$detail" ] || jit_id_valid "$detail"; } || return 1
  if [ "$phase" = terminal ]; then
    [ -n "$terminal" ] && { [ "$terminal" != failed ] || [ -n "$detail" ]; }
  else
    [ -z "$terminal" ] && [ -z "$detail" ]
  fi
}

distributed_adapter_reply_id() { printf '{"schema_version":1,"payload":{"result":"%s","id":"%s"}}\n' "$1" "$2"; }
distributed_adapter_reply_code() { printf '{"schema_version":1,"payload":{"result":"%s","detail_code":"%s"}}\n' "$1" "$2"; }
distributed_adapter_reply_simple() { printf '{"schema_version":1,"payload":{"result":"%s"}}\n' "$1"; }
distributed_adapter_reply_terminal() {
  case "$1" in
    finished) printf '{"schema_version":1,"payload":{"result":"terminal","outcome":"finished"}}\n' ;;
    cancelled) printf '{"schema_version":1,"payload":{"result":"terminal","outcome":"cancelled"}}\n' ;;
    failed) printf '{"schema_version":1,"payload":{"result":"terminal","outcome":{"failed":{"detail_code":"%s"}}}}\n' "$2" ;;
    *) distributed_adapter_reply_code rejected invalid_terminal_state ;;
  esac
}

distributed_adapter_reply_find_failure() {
  local find_rc="$1" missing_result="$2"
  if [ "$find_rc" != 1 ]; then
    distributed_adapter_reply_code deferred container_identity_ambiguous
  elif [ "$missing_result" = absent ]; then
    distributed_adapter_reply_simple absent
  else
    distributed_adapter_reply_code deferred "$missing_result"
  fi
}

distributed_adapter_state_load() {
  local placement="$1" path
  distributed_adapter_dir_ensure || return 2
  path="$(distributed_adapter_state_path "$placement")"
  [ -e "$path" ] || return 1
  distributed_adapter_state_valid "$path" || return 2
  [ "$(distributed_adapter_state_field "$path" placement_id)" = "$placement" ] || return 2
  DA_PLACEMENT="$placement"
  DA_COMMAND="$(distributed_adapter_state_field "$path" command_id)"
  DA_POOL="$(distributed_adapter_state_field "$path" pool_id)"
  DA_RUNNER="$(distributed_adapter_state_field "$path" runner_name)"
  DA_CONTAINER="$(distributed_adapter_state_field "$path" container_name)"
  DA_CONTAINER_ID="$(distributed_adapter_state_field "$path" container_id)"
  DA_RESERVATION="$(distributed_adapter_state_field "$path" reservation_id)"
  DA_CPU="$(distributed_adapter_state_field "$path" cpu_milli)"
  DA_MEMORY="$(distributed_adapter_state_field "$path" memory_bytes)"
  DA_SPEC="$(distributed_adapter_state_field "$path" runner_spec_hash)"
  DA_REVISION="$(distributed_adapter_state_field "$path" config_revision)"
  DA_PHASE="$(distributed_adapter_state_field "$path" phase)"
  DA_TERMINAL="$(distributed_adapter_state_field "$path" terminal_kind)"
  DA_DETAIL="$(distributed_adapter_state_field "$path" detail_code)"
}

distributed_adapter_state_store() {
  distributed_adapter_state_write "$DA_PLACEMENT" "$DA_COMMAND" "$DA_POOL" "$DA_RUNNER" "$DA_CONTAINER" "${1:-$DA_CONTAINER_ID}" \
    "$DA_RESERVATION" "$DA_CPU" "$DA_MEMORY" "$DA_SPEC" "$DA_REVISION" "$2" "${3:-}" "${4:-}"
}

distributed_adapter_policy_prepare() {
  local placement="$1" command="$2" pool="$3" runner="$4" requested_cpu="$5" requested_memory="$6" local_cpu local_memory
  pool_id_valid "$pool" && jit_id_valid "$placement" && jit_id_valid "$command" && reservation_name_valid "$runner" || return 1
  local_cpu="$(pool_cpu_milli "$pool" 2>/dev/null)" || return 1
  local_memory="$(pool_memory_bytes "$pool" 2>/dev/null)" || return 1
  [ "$requested_cpu" = "$local_cpu" ] && [ "$requested_memory" = "$local_memory" ] || return 2
  DA_PLACEMENT="$placement"; DA_COMMAND="$command"; DA_POOL="$pool"; DA_RUNNER="$runner"
  DA_CPU="$requested_cpu"; DA_MEMORY="$requested_memory"
  DA_SPEC="$(pool_runner_spec_hash "$pool" 2>/dev/null)" || return 1
  DA_REVISION="$(pool_config_revision 2>/dev/null)" || return 1
  reservation_token_valid "$DA_SPEC" && reservation_token_valid "$DA_REVISION" || return 1
  DA_CONTAINER="$(distributed_adapter_container_name "$placement" "$pool")"
  DA_RESERVATION="$(distributed_adapter_reservation_id "$placement")"
  reservation_name_valid "$DA_CONTAINER" && reservation_id_valid "$DA_RESERVATION" || return 1
  DA_CONTAINER_ID=""; DA_PHASE=prepared; DA_TERMINAL=""; DA_DETAIL=""
}

distributed_adapter_reservation_ensure() {
  local path phase deadline
  reservation_dir_ensure || return 1
  path="$RESERVATION_DIR/$DA_RESERVATION.state"
  if [ -e "$path" ]; then
    reservation_state_valid "$path" || return 1
    [ "$(reservation_field "$path" pool_id)" = "$DA_POOL" ] &&
      [ "$(reservation_field "$path" runner_name)" = "$DA_CONTAINER" ] &&
      [ "$(reservation_field "$path" cpu_milli)" = "$DA_CPU" ] &&
      [ "$(reservation_field "$path" memory_bytes)" = "$DA_MEMORY" ] &&
      [ "$(reservation_field "$path" runner_spec_hash)" = "$DA_SPEC" ] &&
      [ "$(reservation_field "$path" config_revision)" = "$DA_REVISION" ] || return 1
    phase="$(reservation_field "$path" phase)"
    case "$phase" in
      reserved) reservation_set_phase "$DA_RESERVATION" assigned ;;
      assigned) : ;;
      *) return 1 ;;
    esac
    return 0
  fi
  deadline=$(( $(date +%s) + 900 ))
  reservation_create "$DA_POOL" "$DA_CONTAINER" "$DA_CPU" "$DA_MEMORY" "$DA_SPEC" "$DA_REVISION" "$DA_RESERVATION" "$deadline" || return 1
  reservation_set_phase "$DA_RESERVATION" assigned
}

distributed_adapter_find_container() {
  local placement="$1" output short full name expected_name managed backend label_placement command pool runner cpu memory spec revision status exit_code
  local -a ids=()
  output="$(docker ps -a --filter "label=${LABEL_NS}.placement-id=$placement" --format '{{.ID}}' 2>/dev/null)" || return 3
  while IFS= read -r short; do [ -n "$short" ] && ids+=("$short"); done <<<"$output"
  [ "${#ids[@]}" -le 1 ] || return 2
  [ "${#ids[@]}" -eq 1 ] || return 1
  short="${ids[0]}"
  full="$(docker inspect --format '{{.Id}}' "$short" 2>/dev/null)" || return 3
  distributed_adapter_container_id_valid "$full" || return 3
  name="$(docker inspect --format '{{.Name}}' "$full" 2>/dev/null)" || return 3; name="${name#/}"
  managed="$(docker inspect --format "{{ index .Config.Labels \"${MANAGED_LABEL%=*}\" }}" "$full" 2>/dev/null)" || return 3
  backend="$(docker inspect --format "{{ index .Config.Labels \"${LABEL_NS}.backend\" }}" "$full" 2>/dev/null)" || return 3
  label_placement="$(docker inspect --format "{{ index .Config.Labels \"${LABEL_NS}.placement-id\" }}" "$full" 2>/dev/null)" || return 3
  command="$(docker inspect --format "{{ index .Config.Labels \"${LABEL_NS}.command-id\" }}" "$full" 2>/dev/null)" || return 3
  pool="$(docker inspect --format "{{ index .Config.Labels \"${LABEL_NS}.pool\" }}" "$full" 2>/dev/null)" || return 3
  runner="$(docker inspect --format "{{ index .Config.Labels \"${LABEL_NS}.requested-runner-name\" }}" "$full" 2>/dev/null)" || return 3
  cpu="$(docker inspect --format "{{ index .Config.Labels \"${LABEL_NS}.cpu-milli\" }}" "$full" 2>/dev/null)" || return 3
  memory="$(docker inspect --format "{{ index .Config.Labels \"${LABEL_NS}.memory-bytes\" }}" "$full" 2>/dev/null)" || return 3
  spec="$(docker inspect --format "{{ index .Config.Labels \"${LABEL_NS}.runner-spec-hash\" }}" "$full" 2>/dev/null)" || return 3
  revision="$(docker inspect --format "{{ index .Config.Labels \"${LABEL_NS}.config-revision\" }}" "$full" 2>/dev/null)" || return 3
  status="$(docker inspect --format '{{.State.Status}}' "$full" 2>/dev/null)" || return 3
  exit_code="$(docker inspect --format '{{.State.ExitCode}}' "$full" 2>/dev/null)" || return 3
  expected_name="$(distributed_adapter_container_name "$placement" "$pool")"
  [ "$managed" = true ] && [ "$backend" = distributed ] && [ "$label_placement" = "$placement" ] && [ "$name" = "$expected_name" ] &&
    jit_id_valid "$command" && pool_id_valid "$pool" && reservation_name_valid "$runner" && resource_positive_uint_valid "$cpu" 256000 &&
    resource_positive_uint_valid "$memory" 1099511627776 && reservation_token_valid "$spec" && reservation_token_valid "$revision" || return 2
  DISTRIBUTED_CONTAINER_ID="$full"; DISTRIBUTED_CONTAINER_NAME="$name"; DISTRIBUTED_CONTAINER_STATUS="$status"; DISTRIBUTED_CONTAINER_EXIT_CODE="$exit_code"
  DISTRIBUTED_CONTAINER_COMMAND="$command"; DISTRIBUTED_CONTAINER_POOL="$pool"; DISTRIBUTED_CONTAINER_RUNNER="$runner"
  DISTRIBUTED_CONTAINER_CPU="$cpu"; DISTRIBUTED_CONTAINER_MEMORY="$memory"; DISTRIBUTED_CONTAINER_SPEC="$spec"; DISTRIBUTED_CONTAINER_REVISION="$revision"
}

distributed_adapter_state_reconstruct_from_container() {
  local placement="$1" phase="${2:-running}"
  DA_PLACEMENT="$placement"; DA_COMMAND="$DISTRIBUTED_CONTAINER_COMMAND"; DA_POOL="$DISTRIBUTED_CONTAINER_POOL"; DA_RUNNER="$DISTRIBUTED_CONTAINER_RUNNER"
  DA_CONTAINER="$DISTRIBUTED_CONTAINER_NAME"; DA_CONTAINER_ID="$DISTRIBUTED_CONTAINER_ID"; DA_RESERVATION="$(distributed_adapter_reservation_id "$placement")"
  DA_CPU="$DISTRIBUTED_CONTAINER_CPU"; DA_MEMORY="$DISTRIBUTED_CONTAINER_MEMORY"; DA_SPEC="$DISTRIBUTED_CONTAINER_SPEC"; DA_REVISION="$DISTRIBUTED_CONTAINER_REVISION"
  DA_PHASE="$phase"; DA_TERMINAL=""; DA_DETAIL=""
  distributed_adapter_state_store "$DA_CONTAINER_ID" "$phase"
}

distributed_adapter_secret_consumed() { docker exec "$1" test -f /run/crf/consumed >/dev/null 2>&1; }

distributed_adapter_capture_diagnostics() {
  local placement="$1" container_id="$2" dir
  dir="$DISTRIBUTED_ADAPTER_LOG_ROOT/$(distributed_adapter_key "$placement")"
  [ ! -L "$DISTRIBUTED_ADAPTER_LOG_ROOT" ] || return 1
  mkdir -p "$dir" || return 1; chmod 0700 "$DISTRIBUTED_ADAPTER_LOG_ROOT" "$dir" 2>/dev/null || true
  docker logs "$container_id" >"$dir/container.log" 2>&1 || true
  docker inspect "$container_id" >"$dir/container-inspect.json" 2>/dev/null || true
  chmod 0600 "$dir/container.log" "$dir/container-inspect.json" 2>/dev/null || true
}

distributed_adapter_terminalize() {
  local kind="$1" detail="${2:-}" container_id="${DA_CONTAINER_ID:-}"
  distributed_adapter_state_store "$container_id" terminal "$kind" "$detail" || return 1
  DA_PHASE=terminal; DA_TERMINAL="$kind"; DA_DETAIL="$detail"
  if [ -n "$container_id" ] && distributed_adapter_container_id_valid "$container_id"; then
    distributed_adapter_capture_diagnostics "$DA_PLACEMENT" "$container_id" || true
    crf_runtime_force_remove "$container_id" || true
    crf_runtime_container_exists "$container_id" || reservation_release "$DA_RESERVATION" 2>/dev/null || true
  else
    reservation_release "$DA_RESERVATION" 2>/dev/null || true
  fi
}

distributed_adapter_reply_state_terminal() { distributed_adapter_reply_terminal "$DA_TERMINAL" "$DA_DETAIL"; }

distributed_adapter_existing_matches_state() {
  [ "$DISTRIBUTED_CONTAINER_NAME" = "$DA_CONTAINER" ] && [ "$DISTRIBUTED_CONTAINER_COMMAND" = "$DA_COMMAND" ] &&
    [ "$DISTRIBUTED_CONTAINER_POOL" = "$DA_POOL" ] && [ "$DISTRIBUTED_CONTAINER_RUNNER" = "$DA_RUNNER" ] &&
    [ "$DISTRIBUTED_CONTAINER_CPU" = "$DA_CPU" ] && [ "$DISTRIBUTED_CONTAINER_MEMORY" = "$DA_MEMORY" ] &&
    [ "$DISTRIBUTED_CONTAINER_SPEC" = "$DA_SPEC" ] && [ "$DISTRIBUTED_CONTAINER_REVISION" = "$DA_REVISION" ]
}

distributed_adapter_reply_observed() {
  local expected="${1:-}"
  if [ -n "$expected" ] && [ "$DISTRIBUTED_CONTAINER_ID" != "$expected" ]; then
    distributed_adapter_reply_id running "$DISTRIBUTED_CONTAINER_ID"
    return 0
  fi
  if [ -n "${DA_CONTAINER_ID:-}" ] && [ "$DISTRIBUTED_CONTAINER_ID" != "$DA_CONTAINER_ID" ]; then
    distributed_adapter_reply_code deferred runtime_identity_mismatch
    return 0
  fi
  case "$DISTRIBUTED_CONTAINER_STATUS" in
    running|paused)
      if distributed_adapter_secret_consumed "$DISTRIBUTED_CONTAINER_ID"; then
        DA_CONTAINER_ID="$DISTRIBUTED_CONTAINER_ID"
        if [ "${DA_PHASE:-}" != running ]; then
          distributed_adapter_state_store "$DA_CONTAINER_ID" running || { distributed_adapter_reply_code deferred state_write_failed; return 0; }
          DA_PHASE=running
        fi
        distributed_adapter_reply_id running "$DISTRIBUTED_CONTAINER_ID"
      else
        [ "${DA_PHASE:-}" = observed ] || { DA_CONTAINER_ID="$DISTRIBUTED_CONTAINER_ID"; distributed_adapter_state_store "$DA_CONTAINER_ID" observed || true; DA_PHASE=observed; }
        distributed_adapter_reply_code deferred container_secret_pending
      fi
      ;;
    exited|dead)
      DA_CONTAINER_ID="$DISTRIBUTED_CONTAINER_ID"
      if [ "$DISTRIBUTED_CONTAINER_STATUS" = exited ] && [ "${DISTRIBUTED_CONTAINER_EXIT_CODE:-1}" = 0 ]; then
        distributed_adapter_terminalize finished || { distributed_adapter_reply_code deferred state_write_failed; return 0; }
      elif [ "$DISTRIBUTED_CONTAINER_STATUS" = dead ]; then
        distributed_adapter_terminalize failed container_runtime_dead || { distributed_adapter_reply_code deferred state_write_failed; return 0; }
      else
        distributed_adapter_terminalize failed container_exit_nonzero || { distributed_adapter_reply_code deferred state_write_failed; return 0; }
      fi
      distributed_adapter_reply_state_terminal
      ;;
    *) distributed_adapter_reply_code deferred container_state_transitional ;;
  esac
}

distributed_adapter_handle_start_existing_container() {
  local descriptor="$1"
  DA_CONTAINER_ID="$DISTRIBUTED_CONTAINER_ID"
  distributed_adapter_state_store "$DA_CONTAINER_ID" observed || { distributed_adapter_reply_code deferred state_write_failed; return 0; }
  DA_PHASE=observed
  case "$DISTRIBUTED_CONTAINER_STATUS" in
    exited|dead) distributed_adapter_reply_observed; return 0 ;;
    running|paused) ;;
    *) distributed_adapter_reply_code deferred container_state_transitional; return 0 ;;
  esac
  if distributed_adapter_secret_consumed "$DA_CONTAINER_ID"; then
    distributed_adapter_state_store "$DA_CONTAINER_ID" running || { distributed_adapter_reply_code deferred state_write_failed; return 0; }
    DA_PHASE=running
    distributed_adapter_reply_id started "$DA_CONTAINER_ID"
    return 0
  fi
  if ! runner_secret_inject "$DA_CONTAINER" "$descriptor" "$DA_CONTAINER_ID"; then
    if distributed_adapter_secret_consumed "$DA_CONTAINER_ID"; then
      distributed_adapter_state_store "$DA_CONTAINER_ID" running || { distributed_adapter_reply_code deferred state_write_failed; return 0; }
      DA_PHASE=running
      distributed_adapter_reply_id started "$DA_CONTAINER_ID"
      return 0
    fi
    distributed_adapter_terminalize failed credential_handoff_failed || { distributed_adapter_reply_code deferred state_write_failed; return 0; }
    distributed_adapter_reply_code rejected credential_handoff_failed
    return 0
  fi
  distributed_adapter_state_store "$DA_CONTAINER_ID" running || { distributed_adapter_reply_code deferred state_write_failed; return 0; }
  DA_PHASE=running
  distributed_adapter_reply_id started "$DA_CONTAINER_ID"
}

distributed_adapter_launch_prepared() {
  local descriptor="$1" current_cpu current_memory current_spec current_revision idx image find_rc
  current_cpu="$(pool_cpu_milli "$DA_POOL" 2>/dev/null)" || { distributed_adapter_terminalize failed local_policy_invalid || true; distributed_adapter_reply_code rejected local_policy_invalid; return 0; }
  current_memory="$(pool_memory_bytes "$DA_POOL" 2>/dev/null)" || { distributed_adapter_terminalize failed local_policy_invalid || true; distributed_adapter_reply_code rejected local_policy_invalid; return 0; }
  current_spec="$(pool_runner_spec_hash "$DA_POOL" 2>/dev/null)" || { distributed_adapter_terminalize failed local_policy_invalid || true; distributed_adapter_reply_code rejected local_policy_invalid; return 0; }
  current_revision="$(pool_config_revision 2>/dev/null)" || { distributed_adapter_terminalize failed local_policy_invalid || true; distributed_adapter_reply_code rejected local_policy_invalid; return 0; }
  if [ "$current_cpu" != "$DA_CPU" ] || [ "$current_memory" != "$DA_MEMORY" ] || [ "$current_spec" != "$DA_SPEC" ] || [ "$current_revision" != "$DA_REVISION" ]; then
    distributed_adapter_terminalize failed local_policy_changed || true
    distributed_adapter_reply_code rejected local_policy_changed
    return 0
  fi
  distributed_adapter_reservation_ensure || { distributed_adapter_reply_code deferred reservation_state_ambiguous; return 0; }
  if docker inspect "$DA_CONTAINER" >/dev/null 2>&1; then
    if distributed_adapter_find_container "$DA_PLACEMENT" && [ "$DISTRIBUTED_CONTAINER_NAME" = "$DA_CONTAINER" ]; then
      distributed_adapter_handle_start_existing_container "$descriptor"
    else
      distributed_adapter_terminalize failed container_name_collision || true
      distributed_adapter_reply_code rejected container_name_collision
    fi
    return 0
  fi
  distributed_adapter_state_store "" starting || { distributed_adapter_reply_code deferred state_write_failed; return 0; }
  DA_PHASE=starting
  idx=$((16#$(distributed_adapter_key "$DA_PLACEMENT" | cut -c1-6) % 1000000))
  # Dynamically scoped input consumed by the shared build_args implementation.
  # shellcheck disable=SC2034
  local NO_REGISTER=1
  build_args "$idx" "$DA_CONTAINER" "$DA_POOL" "org:$GH_OWNER" || { distributed_adapter_terminalize failed local_materialization_failed || true; distributed_adapter_reply_code rejected local_materialization_failed; return 0; }
  [[ "${CRF_IMAGE_ARG_INDEX:-}" =~ ^[0-9]+$ ]] || { distributed_adapter_terminalize failed local_materialization_failed || true; distributed_adapter_reply_code rejected local_materialization_failed; return 0; }
  image="${ARGS[$CRF_IMAGE_ARG_INDEX]}"
  ARGS=("${ARGS[@]:0:$CRF_IMAGE_ARG_INDEX}")
  ARGS+=(
    --label "${LABEL_NS}.backend=distributed"
    --label "${LABEL_NS}.placement-id=$DA_PLACEMENT"
    --label "${LABEL_NS}.command-id=$DA_COMMAND"
    --label "${LABEL_NS}.requested-runner-name=$DA_RUNNER"
    --label "${LABEL_NS}.cpu-milli=$DA_CPU"
    --label "${LABEL_NS}.memory-bytes=$DA_MEMORY"
    -e CRF_CREDENTIAL_KIND=jit
    -e EPHEMERAL=true
    "$image"
  )
  crf_runtime_run_prepared || true
  if distributed_adapter_find_container "$DA_PLACEMENT"; then
    distributed_adapter_existing_matches_state || { distributed_adapter_reply_code deferred runtime_identity_mismatch; return 0; }
    distributed_adapter_handle_start_existing_container "$descriptor"
    return 0
  else
    find_rc=$?
  fi
  # Even a nonzero docker client result cannot prove the daemon did not create
  # the container. `starting` remains a conservative replay fence.
  distributed_adapter_reply_find_failure "$find_rc" container_start_uncertain
  return 0
}

distributed_adapter_start() {
  local placement="$1" command="$2" pool="$3" runner="$4" cpu="$5" memory="$6" descriptor="$7" state_rc find_rc count
  if distributed_adapter_state_load "$placement"; then
    [ "$DA_COMMAND" = "$command" ] && [ "$DA_POOL" = "$pool" ] && [ "$DA_RUNNER" = "$runner" ] && [ "$DA_CPU" = "$cpu" ] && [ "$DA_MEMORY" = "$memory" ] || { distributed_adapter_reply_code rejected placement_conflict; return 0; }
    case "$DA_PHASE" in
      terminal) distributed_adapter_reply_state_terminal ;;
      prepared) distributed_adapter_launch_prepared "$descriptor" ;;
      starting)
        if distributed_adapter_find_container "$placement"; then
          distributed_adapter_existing_matches_state || { distributed_adapter_reply_code deferred runtime_identity_mismatch; return 0; }
          distributed_adapter_handle_start_existing_container "$descriptor"
        else
          find_rc=$?
          distributed_adapter_reply_find_failure "$find_rc" container_start_uncertain
        fi
        ;;
      observed)
        if distributed_adapter_find_container "$placement"; then
          distributed_adapter_existing_matches_state || { distributed_adapter_reply_code deferred runtime_identity_mismatch; return 0; }
          distributed_adapter_handle_start_existing_container "$descriptor"
        else
          find_rc=$?
          if [ "$find_rc" = 1 ]; then distributed_adapter_terminalize failed container_lost || true; distributed_adapter_reply_state_terminal; else distributed_adapter_reply_code deferred container_identity_ambiguous; fi
        fi
        ;;
      running) distributed_adapter_inspect "$placement" "$DA_CONTAINER_ID" ;;
      cancelling) distributed_adapter_reply_code deferred container_cancel_pending ;;
    esac
    return 0
  else
    state_rc=$?
  fi
  [ "$state_rc" = 1 ] || { distributed_adapter_reply_code deferred state_corrupt; return 0; }
  if distributed_adapter_find_container "$placement"; then
    distributed_adapter_state_reconstruct_from_container "$placement" observed || { distributed_adapter_reply_code deferred state_write_failed; return 0; }
    [ "$DA_COMMAND" = "$command" ] && [ "$DA_POOL" = "$pool" ] && [ "$DA_RUNNER" = "$runner" ] && [ "$DA_CPU" = "$cpu" ] && [ "$DA_MEMORY" = "$memory" ] || { distributed_adapter_reply_code rejected placement_conflict; return 0; }
    distributed_adapter_handle_start_existing_container "$descriptor"
    return 0
  else
    find_rc=$?
  fi
  [ "$find_rc" = 1 ] || { distributed_adapter_reply_code deferred container_identity_ambiguous; return 0; }
  distributed_adapter_policy_prepare "$placement" "$command" "$pool" "$runner" "$cpu" "$memory"
  case $? in
    0) ;;
    2) distributed_adapter_reply_code rejected pool_resource_mismatch; return 0 ;;
    *) distributed_adapter_reply_code rejected local_policy_invalid; return 0 ;;
  esac
  distributed_adapter_dir_ensure || { distributed_adapter_reply_code deferred state_write_failed; return 0; }
  count=0; for state_file in "$DISTRIBUTED_ADAPTER_STATE_DIR"/*.state; do [ -f "$state_file" ] && count=$((count+1)); done
  [ "$count" -lt "$DISTRIBUTED_ADAPTER_MAX_STATE_FILES" ] || { distributed_adapter_reply_code deferred state_capacity_exhausted; return 0; }
  distributed_adapter_state_store "" prepared || { distributed_adapter_reply_code deferred state_write_failed; return 0; }
  DA_PHASE=prepared
  distributed_adapter_launch_prepared "$descriptor"
}

distributed_adapter_inspect() {
  local placement="$1" expected="${2:-}" state_rc find_rc
  if distributed_adapter_state_load "$placement"; then
    case "$DA_PHASE" in
      terminal) distributed_adapter_reply_state_terminal; return 0 ;;
      prepared)
        if distributed_adapter_find_container "$placement"; then
          distributed_adapter_existing_matches_state || { distributed_adapter_reply_code deferred runtime_identity_mismatch; return 0; }
          DA_CONTAINER_ID="$DISTRIBUTED_CONTAINER_ID"; distributed_adapter_state_store "$DA_CONTAINER_ID" observed || true; DA_PHASE=observed
          distributed_adapter_reply_observed "$expected"
        else
          find_rc=$?
          distributed_adapter_reply_find_failure "$find_rc" container_start_prepared
        fi
        return 0 ;;
      starting)
        if ! distributed_adapter_find_container "$placement"; then
          find_rc=$?
          distributed_adapter_reply_find_failure "$find_rc" container_start_uncertain
          return 0
        fi
        distributed_adapter_existing_matches_state || { distributed_adapter_reply_code deferred runtime_identity_mismatch; return 0; }
        DA_CONTAINER_ID="$DISTRIBUTED_CONTAINER_ID"; distributed_adapter_state_store "$DA_CONTAINER_ID" observed || true; DA_PHASE=observed
        distributed_adapter_reply_observed "$expected"; return 0 ;;
      cancelling)
        if ! distributed_adapter_find_container "$placement"; then
          find_rc=$?
          if [ "$find_rc" = 1 ]; then
            distributed_adapter_state_store "$DA_CONTAINER_ID" terminal cancelled "" || { distributed_adapter_reply_code deferred state_write_failed; return 0; }
            DA_PHASE=terminal; DA_TERMINAL=cancelled; DA_DETAIL=""
            reservation_release "$DA_RESERVATION" 2>/dev/null || true
            distributed_adapter_reply_simple cancelled
          else
            distributed_adapter_reply_code deferred container_identity_ambiguous
          fi
          return 0
        fi
        distributed_adapter_existing_matches_state || { distributed_adapter_reply_code deferred runtime_identity_mismatch; return 0; }
        distributed_adapter_reply_code deferred container_cancel_pending
        return 0 ;;
      observed|running)
        if ! distributed_adapter_find_container "$placement"; then
          find_rc=$?
          if [ "$find_rc" = 1 ]; then distributed_adapter_terminalize failed container_lost || true; distributed_adapter_reply_state_terminal; else distributed_adapter_reply_code deferred container_identity_ambiguous; fi
          return 0
        fi
        distributed_adapter_existing_matches_state || { distributed_adapter_reply_code deferred runtime_identity_mismatch; return 0; }
        distributed_adapter_reply_observed "$expected"; return 0 ;;
    esac
  else
    state_rc=$?
  fi
  [ "$state_rc" = 1 ] || { distributed_adapter_reply_code deferred state_corrupt; return 0; }
  if ! distributed_adapter_find_container "$placement"; then
    find_rc=$?
    distributed_adapter_reply_find_failure "$find_rc" absent
    return 0
  fi
  distributed_adapter_state_reconstruct_from_container "$placement" observed || { distributed_adapter_reply_code deferred state_write_failed; return 0; }
  distributed_adapter_reply_observed "$expected"
}

distributed_adapter_cancel() {
  local placement="$1" expected="${2:-}" state_rc find_rc actual_id
  if distributed_adapter_state_load "$placement"; then
    [ "$DA_PHASE" != terminal ] || { distributed_adapter_reply_state_terminal; return 0; }
    if [ -n "$expected" ] && [ -n "$DA_CONTAINER_ID" ] && [ "$expected" != "$DA_CONTAINER_ID" ]; then
      distributed_adapter_reply_code deferred runtime_identity_mismatch; return 0
    fi
    if ! distributed_adapter_find_container "$placement"; then
      find_rc=$?
      if [ "$find_rc" != 1 ]; then distributed_adapter_reply_code deferred container_identity_ambiguous; return 0; fi
      case "$DA_PHASE" in
        prepared) distributed_adapter_terminalize cancelled || true; distributed_adapter_reply_simple cancelled ;;
        starting) distributed_adapter_reply_code deferred container_start_uncertain ;;
        observed|running|cancelling) distributed_adapter_terminalize cancelled || true; distributed_adapter_reply_simple cancelled ;;
      esac
      return 0
    fi
    distributed_adapter_existing_matches_state || { distributed_adapter_reply_code deferred runtime_identity_mismatch; return 0; }
  else
    state_rc=$?
    [ "$state_rc" = 1 ] || { distributed_adapter_reply_code deferred state_corrupt; return 0; }
    if ! distributed_adapter_find_container "$placement"; then
      find_rc=$?
    distributed_adapter_reply_find_failure "$find_rc" absent
    return 0
    fi
    distributed_adapter_state_reconstruct_from_container "$placement" running || { distributed_adapter_reply_code deferred state_write_failed; return 0; }
  fi
  actual_id="$DISTRIBUTED_CONTAINER_ID"
  if [ -n "$expected" ] && [ "$actual_id" != "$expected" ]; then distributed_adapter_reply_code deferred runtime_identity_mismatch; return 0; fi
  DA_CONTAINER_ID="$actual_id"
  if [ "${DA_PHASE:-}" != cancelling ]; then
    distributed_adapter_state_store "$actual_id" cancelling || { distributed_adapter_reply_code deferred state_write_failed; return 0; }
    DA_PHASE=cancelling
  fi
  crf_runtime_stop_remove "$actual_id" 30 || { distributed_adapter_reply_code deferred container_cancel_uncertain; return 0; }
  crf_runtime_container_exists "$actual_id" && { distributed_adapter_reply_code deferred container_cancel_uncertain; return 0; }
  DA_CONTAINER_ID="$actual_id"
  distributed_adapter_state_store "$actual_id" terminal cancelled "" || { distributed_adapter_reply_code deferred state_write_failed; return 0; }
  DA_PHASE=terminal; DA_TERMINAL=cancelled; DA_DETAIL=""
  reservation_release "$DA_RESERVATION" 2>/dev/null || true
  distributed_adapter_reply_simple cancelled
}

cmd_distributed_adapter() {
  local raw action placement command pool runner cpu memory descriptor expected
  local -a fields=()
  raw="$(dd bs=131073 count=1 2>/dev/null)" || { distributed_adapter_reply_code rejected invalid_request; return 0; }
  [ -n "$raw" ] && [ "${#raw}" -le 131072 ] || { distributed_adapter_reply_code rejected invalid_request; return 0; }
  mapfile -d '' -t fields < <(printf '%s' "$raw" | php "$SCRIPT_DIR/runner-container-adapter-parser.php" 2>/dev/null)
  raw=""; unset raw
  [ "${#fields[@]}" -eq 9 ] || { distributed_adapter_reply_code rejected invalid_request; return 0; }
  action="${fields[0]}"; placement="${fields[1]}"; command="${fields[2]}"; pool="${fields[3]}"; runner="${fields[4]}"
  cpu="${fields[5]}"; memory="${fields[6]}"; descriptor="${fields[7]}"; expected="${fields[8]}"
  fields=()
  case "$action" in
    start) distributed_adapter_start "$placement" "$command" "$pool" "$runner" "$cpu" "$memory" "$descriptor" ;;
    inspect) distributed_adapter_inspect "$placement" "$expected" ;;
    cancel) distributed_adapter_cancel "$placement" "$expected" ;;
    *) distributed_adapter_reply_code rejected invalid_request ;;
  esac
  descriptor=""; unset descriptor
}

distributed_adapter_locked() {
  (
    umask 077
    distributed_adapter_dir_ensure || { distributed_adapter_reply_code deferred state_write_failed; exit 0; }
    exec 9>"$DISTRIBUTED_ADAPTER_STATE_DIR/adapter.lock" || { distributed_adapter_reply_code deferred state_write_failed; exit 0; }
    chmod 0600 "$DISTRIBUTED_ADAPTER_STATE_DIR/adapter.lock" 2>/dev/null || true
    flock -w 5 9 || { distributed_adapter_reply_code deferred adapter_busy; exit 0; }
    cmd_distributed_adapter
  )
}
