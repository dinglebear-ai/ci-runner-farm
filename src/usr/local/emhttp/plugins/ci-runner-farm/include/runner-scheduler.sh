#!/bin/bash
# Pure, deterministic, resource-aware scale-set scheduler.
#
# Input rows:
# pool|assigned|warm|service|charged|pending|leases|max|cpu_milli|memory_bytes|healthy|fresh
# `max` is a positive integer or auto. The caller supplies the currently
# admissible CPU/memory budget; charged runners, pending starts, and leases must
# already be reflected in that budget. Output rows:
# pool|desired|admitted|blocked_reason|start_order|safe_removals|advertised|new_leases|blocked_count

SCHEDULER_CURSOR=0
SCHEDULER_STARTS=0
SCHEDULER_ERROR=""

scheduler_uint() {
  local value="${1:-}" max="${2:-9000000000000000000}"
  [[ "$value" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
  [ "${#value}" -lt "${#max}" ] && return 0
  [ "${#value}" -eq "${#max}" ] && [[ ! "$value" > "$max" ]]
}

scheduler_plan() {
  local input="$1" available_cpu="$2" available_memory="$3" cursor="${4:-0}" snapshot_fresh="${5:-1}"
  local soft_limit="${SCHEDULER_START_LIMIT:-2}" hard_limit=4
  local line pool assigned warm service charged pending leases max cpu memory healthy pool_fresh
  local i n round progress order=0 last_cursor
  local -a ids=() desired=() admitted=() blocked=() removals=() advertised=() start_order=()
  local -a new_leases=() cpus=() memories=() needs=() blocked_count=()

  SCHEDULER_ERROR=""; SCHEDULER_STARTS=0
  if ! scheduler_uint "$available_cpu" || ! scheduler_uint "$available_memory" ||
     ! scheduler_uint "$cursor" || ! scheduler_uint "$soft_limit"; then
    SCHEDULER_ERROR=invalid_scheduler_argument
    return 1
  fi
  [ "$soft_limit" -ge 1 ] || soft_limit=1
  [ "$soft_limit" -le "$hard_limit" ] || soft_limit="$hard_limit"
  case "$snapshot_fresh" in 0|1) ;; *) SCHEDULER_ERROR=invalid_freshness; return 1 ;; esac

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "${line//[^|]/}" = "|||||||||||" ] ||
      { SCHEDULER_ERROR=invalid_scheduler_row; return 1; }
    IFS='|' read -r pool assigned warm service charged pending leases max cpu memory healthy pool_fresh <<<"$line"
    pool_id_valid "$pool" || { SCHEDULER_ERROR=invalid_pool_id; return 1; }
    if ! scheduler_uint "$assigned" 1000000000 || ! scheduler_uint "$warm" "$POOL_HARD_MAX" ||
       ! scheduler_uint "$service" "$POOL_HARD_MAX" || ! scheduler_uint "$charged" "$POOL_HARD_MAX" ||
       ! scheduler_uint "$pending" "$POOL_HARD_MAX" || ! scheduler_uint "$leases" "$POOL_HARD_MAX"; then
      SCHEDULER_ERROR=invalid_scheduler_count
      return 1
    fi
    if ! scheduler_uint "$cpu" 256000 || [ "$cpu" -eq 0 ] ||
       ! scheduler_uint "$memory" 1099511627776 || [ "$memory" -eq 0 ]; then
      SCHEDULER_ERROR=invalid_resource_claim
      return 1
    fi
    case "$healthy:$pool_fresh" in 0:0|0:1|1:0|1:1) ;;
      *) SCHEDULER_ERROR=invalid_health_or_freshness; return 1 ;;
    esac
    if [ "$max" = auto ]; then
      max="$POOL_HARD_MAX"
    else
      if ! scheduler_uint "$max" "$POOL_HARD_MAX" || [ "$max" -eq 0 ]; then
        SCHEDULER_ERROR=invalid_pool_max
        return 1
      fi
    fi
    for i in "${ids[@]-}"; do
      [ "$i" != "$pool" ] || { SCHEDULER_ERROR=duplicate_pool; return 1; }
    done
    i="${#ids[@]}"
    ids[i]="$pool"; cpus[i]="$cpu"; memories[i]="$memory"
    if [ "$assigned" -ge "$max" ] || [ "$warm" -ge $((max - assigned)) ]; then
      desired[i]="$max"
    else
      desired[i]=$((assigned + warm))
    fi
    needs[i]=$((desired[i] - service - pending - leases))
    [ "${needs[i]}" -ge 0 ] || needs[i]=0
    removals[i]=$((service - desired[i]))
    [ "${removals[i]}" -ge 0 ] || removals[i]=0
    # REVIEW(crf-v3q.13.5, MUST-CHECK): The max-capacity header is total
    # assigned work plus free resource-backed offers, never a per-pool
    # standalone host estimate. Service, pending, and offered slots are each
    # resource-backed; assigned demand is not additional capacity until one of
    # those slots exists to serve it.
    admitted[i]=0; advertised[i]=$((service + pending + leases)); new_leases[i]="$leases"
    blocked[i]=""; blocked_count[i]=0; start_order[i]=""
    if [ "$snapshot_fresh" != 1 ] || [ "$pool_fresh" != 1 ]; then
      blocked[i]=stale_demand; blocked_count[i]="${needs[i]}"; needs[i]=0; removals[i]=0
    elif [ "$healthy" != 1 ]; then
      blocked[i]=session_unhealthy; blocked_count[i]="${needs[i]}"; needs[i]=0; removals[i]=0
    fi
    # `charged` is intentionally parsed even though the broker has already
    # subtracted it. This keeps the pure input contract explicit and testable.
    : "$charged"
  done < "$input"

  n="${#ids[@]}"
  if [ "$n" -le 0 ] || [ "$n" -gt "$POOL_MAX_COUNT" ]; then
    SCHEDULER_ERROR=invalid_pool_count
    return 1
  fi
  cursor=$((cursor % n)); last_cursor="$cursor"

  # Equal round-robin: at most one admission per feasible pool in each round.
  # P <= 8 and K <= 4, so the bounded scan is O(P + K) in deployed limits.
  while [ "$SCHEDULER_STARTS" -lt "$soft_limit" ]; do
    progress=0
    for ((round=0; round<n && SCHEDULER_STARTS<soft_limit; round++)); do
      i=$(((cursor + round) % n))
      [ "${needs[i]}" -gt 0 ] || continue
      if [ "${cpus[i]}" -le "$available_cpu" ] && [ "${memories[i]}" -le "$available_memory" ]; then
        admitted[i]=$((admitted[i] + 1))
        advertised[i]=$((advertised[i] + 1))
        new_leases[i]=$((new_leases[i] + 1))
        needs[i]=$((needs[i] - 1))
        available_cpu=$((available_cpu - cpus[i]))
        available_memory=$((available_memory - memories[i]))
        SCHEDULER_STARTS=$((SCHEDULER_STARTS + 1))
        order=$((order + 1))
        start_order[i]="${start_order[i]}${start_order[i]:+,}${order}"
        blocked[i]=""
        last_cursor=$(((i + 1) % n))
        progress=1
      fi
    done
    cursor="$last_cursor"
    [ "$progress" = 1 ] || break
  done
  SCHEDULER_CURSOR="$last_cursor"

  for ((i=0; i<n; i++)); do
    if [ "${needs[i]}" -gt 0 ] && [ -z "${blocked[i]}" ]; then
      if [ "${cpus[i]}" -gt "$available_cpu" ]; then blocked[i]=cpu_exhausted
      elif [ "${memories[i]}" -gt "$available_memory" ]; then blocked[i]=memory_exhausted
      elif [ "$SCHEDULER_STARTS" -ge "$soft_limit" ]; then blocked[i]=start_limit
      else blocked[i]=infeasible
      fi
    fi
    [ "${blocked_count[i]}" -gt 0 ] || blocked_count[i]="${needs[i]}"
    # The ordered start field contains the pool-local order only for admitted
    # rows. The caller expands admitted counts using the emitted fair pool order.
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "${ids[i]}" "${desired[i]}" "${admitted[i]}" "${blocked[i]:-none}" \
      "${start_order[i]:-none}" \
      "${removals[i]}" "${advertised[i]}" "${new_leases[i]}" "${blocked_count[i]}"
  done
}

scheduler_wait_for_sequence() {
  local snapshot="$1" previous="$2" deadline=$(( $(date +%s) + 5 )) current
  while [ "$(date +%s)" -lt "$deadline" ]; do
    current="$(sed -n 's/^sequence=//p' "$snapshot" 2>/dev/null | head -1)"
    [ -n "$current" ] && [ "$current" != "$previous" ] && return 0
    sleep 0.2
  done
  return 1
}

scheduler_prewarm_set() {
  local pool="$1" target="$2" expected_revision="$3" max path tmp
  pool_snapshot_load && pool_record "$pool" >/dev/null 2>&1 || return 1
  scheduler_uint "$target" && [ "$target" -le "$POOL_HARD_MAX" ] || return 1
  # Fleet submits the authoritative full config revision exposed by status,
  # which is also what the scale-set tick binds temporary intent to. Comparing
  # against the pool-only hash makes every live UI request stale by definition.
  declare -F config_revision >/dev/null && [ "$(config_revision)" = "$expected_revision" ] || return 3
  # Automatic pools are bounded by their autoscale ceiling. A fixed pool's
  # prewarm record is a temporary runtime target, equivalent to its classic
  # scale override, and is bounded by the fleet fuse instead.
  if pool_autoscale_enabled "$pool"; then
    max="$(pool_max "$pool")"; [ "$max" = auto ] || [ "$target" -le "$max" ] || return 1
  fi
  mkdir -p "$RUNDIR" || return 1
  path="$RUNDIR/prewarm.$pool"; tmp="$path.tmp.$$"
  ( umask 077; printf 'target=%s\nconfig_revision=%s\nexpires=%s\n' \
    "$target" "$expected_revision" "$(( $(date +%s) + 3600 ))" >"$tmp" ) &&
    chmod 0600 "$tmp" && mv "$tmp" "$path"
}
