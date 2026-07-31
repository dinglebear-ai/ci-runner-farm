#!/bin/bash
# Execute one already-admitted scale-set work item. Demand, session ownership,
# and backend transitions are deliberately outside this file.

# REVIEW(crf-v3q.13.16, MUST-CHECK): ACK/acquire/JIT recovery must survive a
# host reboot. Keep PIDs, sockets, snapshots, and short leases in RUNDIR tmpfs,
# but persist bounded operation state on the configured cache dataset.
JIT_STATE_DIR="${JIT_STATE_DIR:-$CACHE_ROOT/state/jit}"
JIT_LOG_ROOT="${JIT_LOG_ROOT:-$CACHE_ROOT/logs/runners}"
JIT_LOG_MAX_BYTES="${JIT_LOG_MAX_BYTES:-268435456}"
JIT_LOG_MAX_DAYS="${JIT_LOG_MAX_DAYS:-7}"

jit_id_valid() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ ]]; }

jit_state_write() {
  local runner_id="$1" phase="$2" reservation="$3" handle="$4" container="$5" tmp path
  case "$phase" in
    admitted|jit_received|container_create_started|container_observed|secret_consumed|running|terminal|deleting|deleted|failed) ;;
    *) return 1 ;;
  esac
  mkdir -p "$JIT_STATE_DIR" && chmod 0700 "$JIT_STATE_DIR" || return 1
  path="$JIT_STATE_DIR/$runner_id.state"; tmp="$path.tmp.$$"
  (
    umask 077
    printf 'schema_version=1\nrunner_id=%s\nphase=%s\nreservation_id=%s\nwork_handle=%s\ncontainer_name=%s\nupdated_at=%s\n' \
      "$runner_id" "$phase" "$reservation" "$handle" "$container" "$(date +%s)"
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

jit_retire_handle() {
  local reservation="$1" handle="$2" pool payload response
  pool="$(reservation_field "$RESERVATION_DIR/$reservation.state" pool_id)"
  pool_id_valid "$pool" && jit_id_valid "$handle" || return 1
  payload="$(php -r 'echo json_encode(["pool_id"=>$argv[1],"work_handle"=>(int)$argv[2]],
    JSON_UNESCAPED_SLASHES);' "$pool" "$handle")" || return 1
  response="$(scaleset_request retire_jit "$payload")" || return 1
  printf '%s' "$response" | php -r '
    $j=json_decode(stream_get_contents(STDIN),true);
    if(($j["ok"]??false)!==true||($j["result"]["retired"]??false)!==true)exit(2);
  '
}

jit_cleanup_observed() {
  local runner_id="$1" reservation="$2" handle="$3" container="$4"
  jit_state_write "$runner_id" deleting "$reservation" "$handle" "$container" || return 1
  jit_capture_diagnostics "$container" "$runner_id" || true
  docker rm -f "$container" >/dev/null 2>&1 || true
  if jit_container_exists "$container"; then
    return 1
  fi
  # REVIEW(crf-v3q.13.10): The helper first compacts replay proof, then the
  # shell releases its resource reservation. Failure leaves deleting state for
  # a conservative retry and never permits an old work handle to be reissued.
  jit_retire_handle "$reservation" "$handle" || return 1
  reservation_release "$reservation" || return 1
  jit_state_write "$runner_id" deleted "$reservation" "$handle" "$container"
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
  jit_state_write "$runner_id" admitted "$reservation" "$handle" "$container" || return 1
  jit_state_write "$runner_id" jit_received "$reservation" "$handle" "$container" || return 1

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
  jit_state_write "$runner_id" container_create_started "$reservation" "$handle" "$container" || return 1
  docker run "${ARGS[@]}" >/dev/null 2>&1
  rc=$?
  if jit_container_exists "$container"; then
    jit_state_write "$runner_id" container_observed "$reservation" "$handle" "$container" || return 1
  else
    # An unobserved create remains conservatively charged for recovery.
    jit_state_write "$runner_id" failed "$reservation" "$handle" "$container" || true
    return "${rc:-1}"
  fi
  if ! runner_secret_inject "$container" "$descriptor"; then
    err "JIT runner $runner_id did not consume its protected descriptor"
    jit_cleanup_observed "$runner_id" "$reservation" "$handle" "$container"
    return 1
  fi
  descriptor=""
  unset descriptor
  jit_state_write "$runner_id" secret_consumed "$reservation" "$handle" "$container" || return 1
  jit_state_write "$runner_id" running "$reservation" "$handle" "$container" || return 1
  return 0
}

jit_reconcile() {
  local state phase runner_id reservation handle container
  mkdir -p "$JIT_STATE_DIR" 2>/dev/null || return 1
  for state in "$JIT_STATE_DIR"/*.state; do
    [ -f "$state" ] || continue
    runner_id="${state##*/}"; runner_id="${runner_id%.state}"
    phase="$(jit_state_field "$state" phase)"
    reservation="$(jit_state_field "$state" reservation_id)"
    handle="$(jit_state_field "$state" work_handle)"
    container="$(jit_state_field "$state" container_name)"
    case "$phase" in
      terminal|deleting)
        jit_cleanup_observed "$runner_id" "$reservation" "$handle" "$container" || true
        ;;
      running|secret_consumed|container_observed)
        if ! jit_container_running "$container"; then
          jit_state_write "$runner_id" terminal "$reservation" "$handle" "$container" &&
            jit_cleanup_observed "$runner_id" "$reservation" "$handle" "$container" || true
        fi
        ;;
      admitted|jit_received|container_create_started|failed)
        # Ambiguous creation is never retried blindly. Only release after exact
        # absence is observed; an existing container remains charged/preserved.
        if ! jit_container_exists "$container"; then
          jit_retire_handle "$reservation" "$handle" &&
            reservation_release "$reservation" &&
            jit_state_write "$runner_id" deleted "$reservation" "$handle" "$container" || true
        fi
        ;;
    esac
  done
}
