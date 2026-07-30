#!/bin/bash
# Pure serialization helpers for the schema-v2 Fleet snapshot. Callers build one
# Docker inventory first; these functions only consume that immutable file plus
# local reservation/config state and never invoke Docker or GitHub.

STATUS_OBSERVED_AT=0
STATUS_INVENTORY_REVISION=""
STATUS_CONFIG_REVISION=""
STATUS_RESOURCES_JSON='{"cpu_milli":{"budget":0,"reserve":0,"reserved":0,"admissible":0},"memory_bytes":{"budget":0,"reserve":0,"reserved":0,"admissible":0}}'
STATUS_RESERVATIONS_JSON='[]'

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
}
