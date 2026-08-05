#!/bin/bash
# Resource admission and crash-safe pending-start reservations.
# Requires runner-pools.sh to be sourced first.
# shellcheck disable=SC2034 # public result variables are consumed by runner-farm.sh

RESOURCE_REASON=""
RESOURCE_CPU_BUDGET_MILLI=0
RESOURCE_MEMORY_BUDGET_BYTES=0
RESOURCE_CPU_RESERVED_MILLI=0
RESOURCE_MEMORY_RESERVED_BYTES=0
RESOURCE_CPU_ADMISSIBLE_MILLI=0
RESOURCE_MEMORY_ADMISSIBLE_BYTES=0
RESOURCE_RESERVATION_CPU_MILLI=0
RESOURCE_RESERVATION_MEMORY_BYTES=0
RESOURCE_INVENTORY_CPU_MILLI=0
RESOURCE_INVENTORY_MEMORY_BYTES=0
CRF_RESERVATION_ID=""

resource_error() {
  RESOURCE_REASON="$1"
  return 1
}

# Validate decimal integers without first coercing hostile input through Bash
# arithmetic. Equal-length digit strings compare lexically, which avoids signed
# overflow at every state-file and host-discovery boundary.
resource_uint_valid() {
  local value="${1:-}" max="${2:-9000000000000000000}"
  [[ "$value" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
  [ "${#value}" -lt "${#max}" ] && return 0
  [ "${#value}" -eq "${#max}" ] && [[ ! "$value" > "$max" ]]
}

resource_positive_uint_valid() {
  resource_uint_valid "${1:-}" "${2:-9000000000000000000}" && [ "$1" != 0 ]
}

reservation_id_valid() {
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ ]]
}

reservation_name_valid() {
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ ]]
}

reservation_token_valid() {
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ ]]
}

reservation_phase_valid() {
  case "${1:-}" in reserved|offered|assigned|acting|observed|failed|expired) return 0 ;; *) return 1 ;; esac
}

reservation_state_file_valid() {
  local path="$1" size mode
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  size="$(stat -c %s "$path" 2>/dev/null || echo 8193)"
  mode="$(stat -c %a "$path" 2>/dev/null || echo 0)"
  resource_uint_valid "$size" 8192 && [ "$mode" = 600 ]
}

resource_add_capped() {
  local current="$1" addition="$2" cap="$3"
  resource_uint_valid "$current" "$cap" && resource_uint_valid "$addition" "$cap" || return 1
  if [ "$current" -ge "$cap" ] || [ "$addition" -ge $((cap - current)) ]; then
    printf '%s\n' "$cap"
  else
    printf '%s\n' "$((current + addition))"
  fi
}

resource_host_cpu_milli() {
  local cpus
  cpus="${CRF_HOST_CPUS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null)}"
  resource_positive_uint_valid "$cpus" 1048576 || return 1
  printf '%s\n' "$((cpus * 1000))"
}

resource_host_memory_bytes() {
  local kib
  if [ -n "${CRF_HOST_MEMORY_BYTES:-}" ]; then
    resource_positive_uint_valid "$CRF_HOST_MEMORY_BYTES" 9000000000000000000 || return 1
    printf '%s\n' "$CRF_HOST_MEMORY_BYTES"
    return
  fi
  kib="$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null)"
  resource_positive_uint_valid "$kib" 8789062500000000 || return 1
  printf '%s\n' "$((kib * 1024))"
}

resource_overcommit_basis() {
  local raw="${1:-1.0}" whole fraction
  [[ "$raw" =~ ^(0|[1-9][0-9]*)(\.[0-9]{1,3})?$ ]] || return 1
  whole="${raw%%.*}"
  [ "${#whole}" -le 1 ] || return 1
  if [ "${raw#*.}" = "$raw" ]; then fraction=0
  else fraction="${raw#*.}000"; fraction="${fraction:0:3}"; fi
  raw=$((10#$whole * 1000 + 10#$fraction))
  [ "$raw" -ge 1000 ] && [ "$raw" -le 4000 ] || return 1
  printf '%s\n' "$raw"
}

resource_budget_resolve() {
  local host_cpu host_mem cpu_budget mem_budget cpu_reserve mem_reserve overcommit
  RESOURCE_REASON=""
  host_cpu="$(resource_host_cpu_milli)" || { resource_error invalid_host_cpu; return 1; }
  host_mem="$(resource_host_memory_bytes)" || { resource_error invalid_host_memory; return 1; }
  if [ "${RESOURCE_CPU_BUDGET:-auto}" = auto ]; then cpu_budget="$host_cpu"
  else cpu_budget="$(parse_cpu_milli "$RESOURCE_CPU_BUDGET")" || { resource_error invalid_cpu_budget; return 1; }; fi
  if [ "${RESOURCE_MEMORY_BUDGET:-auto}" = auto ]; then mem_budget="$host_mem"
  else mem_budget="$(parse_memory_bytes "$RESOURCE_MEMORY_BUDGET")" || { resource_error invalid_memory_budget; return 1; }; fi
  cpu_reserve="$(parse_cpu_milli "${RESOURCE_CPU_RESERVE:-1}")" ||
    { resource_error invalid_cpu_reserve; return 1; }
  mem_reserve="$(parse_memory_bytes "${RESOURCE_MEMORY_RESERVE:-1g}")" ||
    { resource_error invalid_memory_reserve; return 1; }
  overcommit="$(resource_overcommit_basis "${RESOURCE_CPU_OVERCOMMIT:-1.0}")" ||
    { resource_error invalid_cpu_overcommit; return 1; }
  [ "$cpu_reserve" -lt "$cpu_budget" ] || { resource_error cpu_reserve_exhausts_budget; return 1; }
  [ "$mem_reserve" -lt "$mem_budget" ] || { resource_error memory_reserve_exhausts_budget; return 1; }
  RESOURCE_CPU_BUDGET_MILLI=$(((cpu_budget - cpu_reserve) * overcommit / 1000))
  RESOURCE_MEMORY_BUDGET_BYTES=$((mem_budget - mem_reserve))
}

resource_claim_sum() {
  local count="$1" cpu="$2" memory="$3"
  if ! resource_uint_valid "$count" "$POOL_HARD_MAX" ||
     ! resource_positive_uint_valid "$cpu" 256000 ||
     ! resource_positive_uint_valid "$memory" 1099511627776; then
    return 1
  fi
  printf '%s|%s\n' "$((count * cpu))" "$((count * memory))"
}

resource_standalone_capacity() {
  local cpu="$1" memory="$2" cpu_fit memory_fit
  if ! resource_positive_uint_valid "$cpu" 256000 ||
     ! resource_positive_uint_valid "$memory" 1099511627776; then
    printf '0\n'
    return
  fi
  cpu_fit=$((RESOURCE_CPU_BUDGET_MILLI / cpu))
  memory_fit=$((RESOURCE_MEMORY_BUDGET_BYTES / memory))
  [ "$cpu_fit" -lt "$memory_fit" ] && printf '%s\n' "$cpu_fit" || printf '%s\n' "$memory_fit"
}

reservation_dir_ensure() {
  : "${RUNDIR:=/run/ci-runner-farm}"
  RESERVATION_DIR="${RESERVATION_DIR:-$RUNDIR/reservations}"
  [ ! -L "$RESERVATION_DIR" ] || return 1
  mkdir -p "$RESERVATION_DIR" || return 1
  [ -d "$RESERVATION_DIR" ] && chmod 0700 "$RESERVATION_DIR"
}

reservation_create() {
  local pool="$1" runner="$2" cpu="$3" memory="$4" spec_hash="$5" config_revision="$6"
  local operation_id="${7:-}" deadline="${8:-}" boot_id owner_pid tmp path
  reservation_dir_ensure || return 1
  [ -n "$operation_id" ] || operation_id="$(cat /proc/sys/kernel/random/uuid 2>/dev/null)"
  [ -n "$operation_id" ] || operation_id="$$-$(date +%s)-$RANDOM"
  deadline="${deadline:-$(( $(date +%s) + 300 ))}"
  boot_id="${CRF_BOOT_ID:-$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)}"
  owner_pid="${CRF_OWNER_PID:-$$}"
  reservation_id_valid "$operation_id" && pool_id_valid "$pool" &&
    reservation_name_valid "$runner" && reservation_token_valid "$boot_id" &&
    reservation_token_valid "$spec_hash" && reservation_token_valid "$config_revision" &&
    resource_positive_uint_valid "$owner_pid" 4194304 &&
    resource_positive_uint_valid "$deadline" 9999999999 &&
    resource_positive_uint_valid "$cpu" 256000 &&
    resource_positive_uint_valid "$memory" 1099511627776 || return 1
  path="$RESERVATION_DIR/$operation_id.state"; tmp="$path.tmp.$$"
  [ ! -e "$path" ] && [ ! -L "$path" ] || return 1
  {
    umask 077
    printf 'schema_version=1\noperation_id=%s\nboot_id=%s\nowner_pid=%s\ndeadline=%s\nconfig_revision=%s\npool_id=%s\nrunner_name=%s\ncpu_milli=%s\nmemory_bytes=%s\nrunner_spec_hash=%s\nphase=reserved\n' \
      "$operation_id" "$boot_id" "$owner_pid" "$deadline" "$config_revision" \
      "$pool" "$runner" "$cpu" "$memory" "$spec_hash" >"$tmp"
  } || { rm -f -- "$tmp"; return 1; }
  if ! chmod 0600 "$tmp" || ! mv -- "$tmp" "$path"; then
    rm -f "$tmp"
    return 1
  fi
  CRF_RESERVATION_ID="$operation_id"
}

reservation_field() {
  local path="$1" key="$2"
  reservation_state_file_valid "$path" || return 1
  case "$key" in
    schema_version|operation_id|boot_id|owner_pid|deadline|config_revision|pool_id|runner_name|cpu_milli|memory_bytes|runner_spec_hash|phase|poll_id|lease_epoch) ;;
    *) return 1 ;;
  esac
  sed -n "s/^${key}=//p" "$path" | head -1
}

reservation_state_valid() {
  local path="$1" operation pool runner cpu memory deadline phase key
  reservation_state_file_valid "$path" || return 1
  for key in schema_version operation_id boot_id owner_pid deadline config_revision pool_id runner_name cpu_milli memory_bytes runner_spec_hash phase; do
    [ "$(grep -c "^${key}=" "$path" 2>/dev/null)" = 1 ] || return 1
  done
  [ "$(reservation_field "$path" schema_version)" = 1 ] || return 1
  operation="$(reservation_field "$path" operation_id)"
  pool="$(reservation_field "$path" pool_id)"
  runner="$(reservation_field "$path" runner_name)"
  cpu="$(reservation_field "$path" cpu_milli)"
  memory="$(reservation_field "$path" memory_bytes)"
  deadline="$(reservation_field "$path" deadline)"
  phase="$(reservation_field "$path" phase)"
  reservation_id_valid "$operation" &&
    [ "$(basename "$path" .state)" = "$operation" ] &&
    pool_id_valid "$pool" && reservation_name_valid "$runner" &&
    reservation_token_valid "$(reservation_field "$path" boot_id)" &&
    reservation_token_valid "$(reservation_field "$path" config_revision)" &&
    reservation_token_valid "$(reservation_field "$path" runner_spec_hash)" &&
    resource_positive_uint_valid "$(reservation_field "$path" owner_pid)" 4194304 &&
    resource_positive_uint_valid "$deadline" 9999999999 &&
    resource_positive_uint_valid "$cpu" 256000 &&
    resource_positive_uint_valid "$memory" 1099511627776 &&
    reservation_phase_valid "$phase"
}

reservation_set_phase() {
  local id="$1" phase="$2" path tmp
  reservation_dir_ensure || return 1
  reservation_id_valid "$id" && reservation_phase_valid "$phase" || return 1
  path="$RESERVATION_DIR/$id.state"; reservation_state_file_valid "$path" || return 1
  [ "$(grep -c '^phase=' "$path" 2>/dev/null)" = 1 ] || return 1
  tmp="$path.tmp.$$"
  if ! sed "s/^phase=.*/phase=$phase/" "$path" >"$tmp" ||
     ! chmod 0600 "$tmp" || ! mv -- "$tmp" "$path"; then
    rm -f -- "$tmp"
    return 1
  fi
}

offer_lease_create() {
  local pool="$1" poll_id="$2" epoch="$3" cpu="$4" memory="$5" spec_hash="$6" config_revision="$7"
  local deadline="${8:-$(( $(date +%s) + 30 ))}" runner="offer-${pool}-${poll_id}-${epoch}" path tmp
  reservation_token_valid "$poll_id" && reservation_token_valid "$epoch" || return 1
  reservation_create "$pool" "$runner" "$cpu" "$memory" "$spec_hash" "$config_revision" \
    "lease-${pool}-${poll_id}-${epoch}" "$deadline" || return 1
  path="$RESERVATION_DIR/$CRF_RESERVATION_ID.state"; tmp="$path.tmp.$$"
  if ! {
      sed 's/^phase=.*/phase=offered/' "$path"
      printf 'poll_id=%s\nlease_epoch=%s\n' "$poll_id" "$epoch"
    } >"$tmp" || ! chmod 0600 "$tmp" || ! mv -- "$tmp" "$path"; then
    rm -f -- "$tmp"
    reservation_release "$CRF_RESERVATION_ID" || true
    return 1
  fi
}

offer_lease_assign() {
  local id="$1" runner="$2" path tmp
  reservation_dir_ensure || return 1
  reservation_id_valid "$id" && reservation_name_valid "$runner" || return 1
  path="$RESERVATION_DIR/$id.state"; reservation_state_file_valid "$path" || return 1
  [ "$(reservation_field "$path" phase)" = offered ] || return 1
  [ "$(grep -c '^runner_name=' "$path" 2>/dev/null)" = 1 ] &&
    [ "$(grep -c '^phase=' "$path" 2>/dev/null)" = 1 ] || return 1
  tmp="$path.tmp.$$"
  if ! sed -e "s/^runner_name=.*/runner_name=$runner/" -e 's/^phase=.*/phase=assigned/' \
      "$path" >"$tmp" || ! chmod 0600 "$tmp" || ! mv -- "$tmp" "$path"; then
    rm -f -- "$tmp"
    return 1
  fi
}

reservation_release() {
  reservation_dir_ensure || return 1
  reservation_id_valid "${1:-}" || return 1
  rm -f -- "$RESERVATION_DIR/$1.state"
}

reservation_runner_exists() {
  local runner="$1" file
  reservation_name_valid "$runner" || return 1
  reservation_dir_ensure || return 1
  for file in "$RESERVATION_DIR"/*.state; do
    [ -f "$file" ] || continue
    reservation_state_file_valid "$file" || continue
    [ "$(reservation_field "$file" runner_name)" = "$runner" ] && return 0
  done
  return 1
}

reservation_totals() {
  local file cpu memory
  RESOURCE_RESERVATION_CPU_MILLI=0
  RESOURCE_RESERVATION_MEMORY_BYTES=0
  reservation_dir_ensure || return 1
  for file in "$RESERVATION_DIR"/*.state; do
    [ -f "$file" ] || continue
    if ! reservation_state_valid "$file"; then
      RESOURCE_RESERVATION_CPU_MILLI="$RESOURCE_CPU_BUDGET_MILLI"
      RESOURCE_RESERVATION_MEMORY_BYTES="$RESOURCE_MEMORY_BUDGET_BYTES"
      continue
    fi
    cpu="$(reservation_field "$file" cpu_milli)"
    memory="$(reservation_field "$file" memory_bytes)"
    RESOURCE_RESERVATION_CPU_MILLI="$(resource_add_capped       "$RESOURCE_RESERVATION_CPU_MILLI" "$cpu" "$RESOURCE_CPU_BUDGET_MILLI")" || return 1
    RESOURCE_RESERVATION_MEMORY_BYTES="$(resource_add_capped       "$RESOURCE_RESERVATION_MEMORY_BYTES" "$memory" "$RESOURCE_MEMORY_BUDGET_BYTES")" || return 1
  done
}

reservation_reconcile() {
  local inventory="$1" now="${2:-$(date +%s)}" file runner deadline operation
  resource_uint_valid "$now" 9999999999 || return 1
  reservation_dir_ensure || return 1
  for file in "$RESERVATION_DIR"/*.state; do
    [ -f "$file" ] || continue
    reservation_state_valid "$file" || continue
    runner="$(reservation_field "$file" runner_name)"
    deadline="$(reservation_field "$file" deadline)"
    operation="$(basename "$file" .state)"
    if [ -n "$runner" ] && awk -F'|' -v n="$runner" '$1 == n { found=1 } END { exit !found }' "$inventory" 2>/dev/null; then
      reservation_release "$operation"
    elif [ "$now" -ge "$deadline" ]; then
      reservation_release "$operation"
    fi
  done
}

resource_inventory_totals() {
  local inventory="$1" row nano memory pool identity cpu
  RESOURCE_INVENTORY_CPU_MILLI=0
  RESOURCE_INVENTORY_MEMORY_BYTES=0
  [ -e "$inventory" ] || return 0
  [ ! -L "$inventory" ] || return 1
  [ -f "$inventory" ] || return 0
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    IFS='|' read -r _ _ _ nano memory _ pool _ _ _ identity _ <<<"$row"
    if resource_positive_uint_valid "$nano" 256000000000; then
      cpu=$((nano / 1000000))
    elif [ "$identity" = valid ] && pool_record "$pool" >/dev/null 2>&1; then
      cpu="$(pool_cpu_milli "$pool" 2>/dev/null || echo 0)"
    else
      cpu="$RESOURCE_CPU_BUDGET_MILLI"
    fi
    if ! resource_positive_uint_valid "$memory" 1099511627776; then
      if [ "$identity" = valid ] && pool_record "$pool" >/dev/null 2>&1; then
        memory="$(pool_memory_bytes "$pool" 2>/dev/null || echo 0)"
      else
        memory="$RESOURCE_MEMORY_BUDGET_BYTES"
      fi
    fi
    resource_positive_uint_valid "$cpu" 256000 || cpu="$RESOURCE_CPU_BUDGET_MILLI"
    resource_positive_uint_valid "$memory" 1099511627776 || memory="$RESOURCE_MEMORY_BUDGET_BYTES"
    RESOURCE_INVENTORY_CPU_MILLI="$(resource_add_capped       "$RESOURCE_INVENTORY_CPU_MILLI" "$cpu" "$RESOURCE_CPU_BUDGET_MILLI")" || return 1
    RESOURCE_INVENTORY_MEMORY_BYTES="$(resource_add_capped       "$RESOURCE_INVENTORY_MEMORY_BYTES" "$memory" "$RESOURCE_MEMORY_BUDGET_BYTES")" || return 1
  done < "$inventory"
}

resource_snapshot_refresh() {
  local inventory="$1"
  resource_budget_resolve || return 1
  resource_inventory_totals "$inventory" || return 1
  reservation_totals || return 1
  RESOURCE_CPU_RESERVED_MILLI="$(resource_add_capped     "$RESOURCE_INVENTORY_CPU_MILLI" "$RESOURCE_RESERVATION_CPU_MILLI" "$RESOURCE_CPU_BUDGET_MILLI")" || return 1
  RESOURCE_MEMORY_RESERVED_BYTES="$(resource_add_capped     "$RESOURCE_INVENTORY_MEMORY_BYTES" "$RESOURCE_RESERVATION_MEMORY_BYTES" "$RESOURCE_MEMORY_BUDGET_BYTES")" || return 1
  RESOURCE_CPU_ADMISSIBLE_MILLI=$((RESOURCE_CPU_BUDGET_MILLI - RESOURCE_CPU_RESERVED_MILLI))
  RESOURCE_MEMORY_ADMISSIBLE_BYTES=$((RESOURCE_MEMORY_BUDGET_BYTES - RESOURCE_MEMORY_RESERVED_BYTES))
}

resource_admit_one() {
  local cpu="$1" memory="$2"
  RESOURCE_REASON=""
  if ! resource_positive_uint_valid "$cpu" 256000 ||
     ! resource_positive_uint_valid "$memory" 1099511627776; then
    resource_error invalid_claim
    return 1
  fi
  [ "$cpu" -le "$RESOURCE_CPU_BUDGET_MILLI" ] || { resource_error cpu_claim_exceeds_budget; return 1; }
  [ "$memory" -le "$RESOURCE_MEMORY_BUDGET_BYTES" ] || { resource_error memory_claim_exceeds_budget; return 1; }
  [ "$cpu" -le "$RESOURCE_CPU_ADMISSIBLE_MILLI" ] || { resource_error cpu_exhausted; return 1; }
  [ "$memory" -le "$RESOURCE_MEMORY_ADMISSIBLE_BYTES" ] || { resource_error memory_exhausted; return 1; }
}

resource_reason_text() {
  case "$1" in
    invalid_claim) echo "Pool CPU or memory claim is invalid." ;;
    cpu_claim_exceeds_budget) echo "One runner needs more CPU than the host scheduling budget." ;;
    memory_claim_exceeds_budget) echo "One runner needs more memory than the host scheduling budget." ;;
    cpu_exhausted) echo "CPU scheduling budget is fully reserved." ;;
    memory_exhausted) echo "Memory scheduling budget is fully reserved." ;;
    host_docker_socket_forbidden) echo "V2 pools cannot share the host Docker socket." ;;
    *) echo "Resource admission is blocked." ;;
  esac
}

resource_v2_preflight() {
  local rec pool
  pool_snapshot_load || return 1
  [ "$POOL_CONFIG_VERSION" = v2 ] || return 0
  [ "${SHARE_DOCKER_SOCK:-false}" != true ] ||
    { resource_error host_docker_socket_forbidden; return 1; }
  [ -r /sys/fs/cgroup/cgroup.controllers ] || [ "${CRF_SKIP_CGROUP_PREFLIGHT:-0}" = 1 ] ||
    { resource_error cgroup_v2_unavailable; return 1; }
  while IFS= read -r rec; do
    pool="${rec%%|*}"
    [ "$(pool_cpu_milli "$pool" 2>/dev/null || echo 0)" -gt 0 ] ||
      { resource_error invalid_claim; return 1; }
    [ "$(pool_memory_bytes "$pool" 2>/dev/null || echo 0)" -gt 0 ] ||
      { resource_error invalid_claim; return 1; }
  done < <(pool_records)
}
