#!/bin/bash
# Durable, low-frequency operation metadata for GraphQL-facing long-running work.

OPERATION_DIR="${OPERATION_DIR:-${CFGDIR:-/boot/config/plugins/ci-runner-farm}/operations}"
OPERATION_RECORD_MAX_BYTES=65536
OPERATION_MAX_FILES=64
OPERATION_MAX_AGE_SECONDS=2592000
OPERATION_LOCK_FD=""

operation_helper_path() {
  printf '%s/operation-record.php' "${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
}

operation_id_valid() {
  [[ "${1:-}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
}

operation_kind_valid() {
  case "${1:-}" in compatibility_test|provisioning_validation|image_build) return 0 ;; *) return 1 ;; esac
}

operation_output_source_valid() {
  case "${1:-}" in none|compatibility_log|provisioning_log|image_build_log) return 0 ;; *) return 1 ;; esac
}

operation_dir_ensure() {
  if [ -e "$OPERATION_DIR" ]; then
    [ -d "$OPERATION_DIR" ] && [ ! -L "$OPERATION_DIR" ] || return 1
  else
    mkdir -p -- "$OPERATION_DIR" || return 1
  fi
  chmod 0700 "$OPERATION_DIR" || return 1
}

operation_lock_acquire() {
  operation_dir_ensure || return 1
  [ ! -L "$OPERATION_DIR/.lock" ] || return 1
  exec {OPERATION_LOCK_FD}>"$OPERATION_DIR/.lock" || return 1
  chmod 0600 "$OPERATION_DIR/.lock" || { exec {OPERATION_LOCK_FD}>&-; OPERATION_LOCK_FD=""; return 1; }
  flock -w 5 "$OPERATION_LOCK_FD" || { exec {OPERATION_LOCK_FD}>&-; OPERATION_LOCK_FD=""; return 1; }
}

operation_lock_release() {
  [ -n "$OPERATION_LOCK_FD" ] || return 0
  flock -u "$OPERATION_LOCK_FD" 2>/dev/null || true
  exec {OPERATION_LOCK_FD}>&-
  OPERATION_LOCK_FD=""
}

operation_record_path() {
  operation_id_valid "${1:-}" || return 1
  printf '%s/%s.json' "$OPERATION_DIR" "$1"
}

operation_record_file_valid() {
  local path="$1" size mode
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  size="$(stat -c %s "$path" 2>/dev/null || echo invalid)"
  mode="$(stat -c %a "$path" 2>/dev/null || echo 0)"
  [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -ge 2 ] && [ "$size" -le "$OPERATION_RECORD_MAX_BYTES" ] && [ "$mode" = 600 ]
}

operation_current_boot_id() {
  local value="${CRF_OPERATION_BOOT_ID:-}"
  [ -n "$value" ] || value="$(cat "${CRF_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}" 2>/dev/null)"
  [[ "$value" =~ ^[A-Za-z0-9._:-]{8,128}$ ]] || return 1
  printf '%s' "$value"
}

operation_process_start_ticks() {
  local pid="$1" value line rest ticks
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pid" -ge 1 ] && [ "$pid" -le 4194304 ] || return 1
  value="${CRF_OPERATION_START_TICKS:-}"
  if [ -z "$value" ]; then
    line="$(cat "${CRF_PROC_ROOT:-/proc}/$pid/stat" 2>/dev/null)" || return 1
    rest="${line##*) }"
    # starttime is field 22 overall and field 20 after pid/comm are removed.
    ticks="$(printf '%s' "$rest" | awk '{print $20}')"
    value="$ticks"
  fi
  [[ "$value" =~ ^[1-9][0-9]{0,20}$ ]] || return 1
  printf '%s' "$value"
}

operation_create_commit() {
  local kind="$1" config_revision="$2" output_source="$3" id="$4" path tmp helper
  helper="$(operation_helper_path)"
  path="$(operation_record_path "$id")" || return 1
  [ ! -e "$path" ] && [ ! -L "$path" ] || return 1
  tmp="$(mktemp "$OPERATION_DIR/$id.json.tmp.XXXXXX")" || return 1
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  if ! /usr/bin/php "$helper" create "$tmp" "$id" "$kind" "$config_revision" "$output_source" ||
     ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp"
    return 1
  fi
}

operation_create() {
  local kind="$1" config_revision="$2" output_source="$3" id rc=0
  operation_kind_valid "$kind" && [[ "$config_revision" =~ ^[0-9a-f]{64}$ ]] &&
    operation_output_source_valid "$output_source" || return 1
  id="${CRF_OPERATION_ID:-$(cat /proc/sys/kernel/random/uuid 2>/dev/null)}"
  operation_id_valid "$id" || return 1
  operation_lock_acquire || return 1
  operation_create_commit "$kind" "$config_revision" "$output_source" "$id" || rc=1
  operation_lock_release
  [ "$rc" -eq 0 ] || return "$rc"
  OPERATION_ID="$id"
  printf '%s
' "$id"
}

operation_transition_commit() {
  local id="$1" state="$2" code="$3" message="$4" summary_file="${5:-}"
  local path tmp helper boot_id="" pid="" start_ticks=""
  helper="$(operation_helper_path)"
  path="$(operation_record_path "$id")" || return 1
  operation_record_file_valid "$path" || return 1
  case "$state" in
    running)
      boot_id="$(operation_current_boot_id)" || return 1
      pid="${CRF_OPERATION_PID:-$$}"
      start_ticks="$(operation_process_start_ticks "$pid")" || return 1
      ;;
    succeeded|failed|cancelled) ;;
    *) return 1 ;;
  esac
  if [ -n "$summary_file" ]; then
    [ -f "$summary_file" ] && [ ! -L "$summary_file" ] &&
      [ "$(stat -c %a "$summary_file" 2>/dev/null || echo 0)" = 600 ] || return 1
  fi
  tmp="$(mktemp "$OPERATION_DIR/$id.json.tmp.XXXXXX")" || return 1
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  if ! CRF_OPERATION_SUMMARY_FILE="$summary_file" /usr/bin/php "$helper" transition "$path" "$tmp" "$id" "$state" "$code" "$message" "$boot_id" "$pid" "$start_ticks" ||
     ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp"
    return 1
  fi
}

operation_transition() {
  local rc=0
  operation_lock_acquire || return 1
  operation_transition_commit "$@" || rc=1
  operation_lock_release
  return "$rc"
}

operation_mark_running() {
  operation_transition "$1" running running "${2:-Operation started.}"
}

operation_finish() {
  local id="$1" state="$2" code="$3" message="$4" summary_file="${5:-}"
  case "$state" in succeeded|failed|cancelled) ;; *) return 1 ;; esac
  operation_transition "$id" "$state" "$code" "$message" "$summary_file"
}

operation_read() {
  local id="$1" path helper
  helper="$(operation_helper_path)"
  path="$(operation_record_path "$id")" || return 1
  operation_record_file_valid "$path" || return 1
  /usr/bin/php "$helper" validate "$path" "$id"
}

operation_read_public() {
  local id="$1" path helper
  helper="$(operation_helper_path)"
  path="$(operation_record_path "$id")" || return 1
  operation_record_file_valid "$path" || return 1
  /usr/bin/php "$helper" public "$path" "$id"
}

operation_state_read() {
  local id="$1" path helper
  helper="$(operation_helper_path)"
  path="$(operation_record_path "$id")" || return 1
  operation_record_file_valid "$path" || return 1
  /usr/bin/php "$helper" state "$path" "$id"
}

operation_worker_live_path() {
  local path="$1" id="$2" helper data current_boot actual_ticks
  local -a fields=()
  helper="$(operation_helper_path)"
  operation_record_file_valid "$path" || return 1
  data="$(/usr/bin/php "$helper" worker "$path" "$id")" || return 1
  mapfile -t fields <<<"$data"
  [ "${#fields[@]}" -eq 4 ] && [ "${fields[0]}" = running ] || return 1
  current_boot="$(operation_current_boot_id)" || return 1
  [ "${fields[1]}" = "$current_boot" ] || return 1
  kill -0 "${fields[2]}" 2>/dev/null || return 1
  actual_ticks="$(operation_process_start_ticks "${fields[2]}")" || return 1
  [ "$actual_ticks" = "${fields[3]}" ]
}

operation_latest_public() {
  local file id mtime item
  local -a records=() sorted=()
  operation_dir_ensure || return 1
  for file in "$OPERATION_DIR"/*.json; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    id="$(basename "$file" .json)"
    operation_id_valid "$id" && operation_record_file_valid "$file" || continue
    /usr/bin/php "$(operation_helper_path)" validate "$file" "$id" >/dev/null 2>&1 || continue
    mtime="$(stat -c %Y "$file" 2>/dev/null || echo 0)"
    records+=("$mtime|$id")
  done
  [ "${#records[@]}" -gt 0 ] || { printf 'null
'; return 0; }
  mapfile -t sorted < <(printf '%s
' "${records[@]}" | sort -t'|' -k1,1nr)
  item="${sorted[0]}"
  operation_read_public "${item#*|}"
}

operation_prune_locked() {
  local file id state mtime now index item rc=0
  local -a terminal=() sorted=()
  now="$(date +%s)"
  for file in "$OPERATION_DIR"/*.json; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    id="$(basename "$file" .json)"
    operation_id_valid "$id" && operation_record_file_valid "$file" || continue
    state="$(/usr/bin/php "$(operation_helper_path)" state "$file" "$id" 2>/dev/null)" || continue
    case "$state" in succeeded|failed|cancelled) ;; *) continue ;; esac
    mtime="$(stat -c %Y "$file" 2>/dev/null || echo 0)"
    [[ "$mtime" =~ ^[0-9]+$ ]] || continue
    if [ $((now - mtime)) -gt "$OPERATION_MAX_AGE_SECONDS" ]; then
      rm -f -- "$file" || rc=1
    else
      terminal+=("$mtime|$file")
    fi
  done
  if [ "${#terminal[@]}" -gt "$OPERATION_MAX_FILES" ]; then
    mapfile -t sorted < <(printf '%s
' "${terminal[@]}" | sort -t'|' -k1,1nr)
    for ((index=OPERATION_MAX_FILES; index<${#sorted[@]}; index++)); do
      item="${sorted[$index]}"
      rm -f -- "${item#*|}" || rc=1
    done
  fi
  return "$rc"
}

operation_prune() {
  local rc=0
  operation_lock_acquire || return 1
  operation_prune_locked || rc=1
  operation_lock_release
  return "$rc"
}

operation_reconcile_interrupted() {
  local file id state rc=0
  operation_lock_acquire || return 1
  for file in "$OPERATION_DIR"/*.json; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    id="$(basename "$file" .json)"
    operation_id_valid "$id" && operation_record_file_valid "$file" || continue
    state="$(/usr/bin/php "$(operation_helper_path)" state "$file" "$id" 2>/dev/null)" || continue
    case "$state" in
      queued) ;;
      running) operation_worker_live_path "$file" "$id" && continue ;;
      *) continue ;;
    esac
    operation_transition_commit "$id" failed operation_interrupted       'Operation was interrupted before completion.' || rc=1
  done
  operation_prune_locked || rc=1
  operation_lock_release
  return "$rc"
}
