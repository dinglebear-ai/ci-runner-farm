#!/bin/bash
# Pure runner-pool configuration helpers.
#
# Safe to source from tests: no filesystem, Docker, GitHub, or process side effects.
# The web-written cfg is parsed by runner-farm.sh's allowlisted loader; these helpers
# only validate the resulting literal strings and never eval/source operator input.

POOL_HARD_MAX=64
POOL_MAX_COUNT=8
POOL_CONFIG_MAX_BYTES=4096
# shellcheck disable=SC2034 # public validation result consumed by runner-farm.sh and tests
POOL_CONFIG_ERROR=""
POOL_RECORDS=""

pool_error() {
  POOL_CONFIG_ERROR="$1"
  return 1
}

pool_id_valid() {
  printf '%s' "$1" | grep -qE '^[a-z]([a-z0-9-]{0,22}[a-z0-9])?$'
}

pool_uint_valid() {
  case "$1" in
    [1-9]|[1-9][0-9]) [ "$1" -le "$POOL_HARD_MAX" ] ;;
    *) return 1 ;;
  esac
}

# Validate one complete immutable snapshot.
# Usage: pool_config_validate <single|pools> <serialized records> <repo|org>
pool_config_validate() {
  local mode="${1:-}" raw="${2:-}" scope="${3:-}" rec id fixed min max idle
  local count=0 sum_fixed=0 sum_max=0 seen=" "
  # shellcheck disable=SC2034 # public validation result consumed by callers
  POOL_CONFIG_ERROR=""
  POOL_RECORDS=""

  case "$mode" in
    single) return 0 ;;
    pools) ;;
    *) pool_error "Runner mode must be single or pools."; return 1 ;;
  esac
  [ "$scope" = "org" ] || { pool_error "Runner pools require Organization scope."; return 1; }
  [ -n "$raw" ] || { pool_error "Runner pools mode requires at least one pool."; return 1; }
  [ "${#raw}" -le "$POOL_CONFIG_MAX_BYTES" ] || { pool_error "Runner pool configuration is too large."; return 1; }
  case "$raw" in
    *[$'\r\n\t ']*|*\'*|*\"*|*\\*|*/*) pool_error "Runner pools contain unsupported whitespace or characters."; return 1 ;;
    ';'*|*';'|*';;'*) pool_error "Runner pool entries cannot be empty."; return 1 ;;
  esac

  local oldifs="$IFS"
  IFS=';'
  # shellcheck disable=SC2206 # strict semicolon-delimited grammar, validated below
  local records=($raw)
  IFS="$oldifs"
  [ "${#records[@]}" -le "$POOL_MAX_COUNT" ] || {
    pool_error "At most $POOL_MAX_COUNT runner pools are supported."; return 1;
  }

  for rec in "${records[@]}"; do
    [ -n "$rec" ] || { pool_error "Runner pool entries cannot be empty."; return 1; }
    oldifs="$IFS"; IFS='|' read -r id fixed min max idle extra <<EOF
$rec
EOF
    IFS="$oldifs"
    [ -z "${extra:-}" ] && [ -n "$idle" ] || {
      pool_error "Pool '$rec' must have exactly id|fixed|min|max|idle."; return 1;
    }
    pool_id_valid "$id" || {
      pool_error "Pool id '$id' must be lowercase, 1-24 characters, and may contain only letters, digits, and internal hyphens."; return 1;
    }
    case "$seen" in
      *" $id "*) pool_error "Pool id '$id' is duplicated."; return 1 ;;
    esac
    seen="${seen}${id} "
    for n in "$fixed" "$min" "$max" "$idle"; do
      pool_uint_valid "$n" || {
        pool_error "Pool '$id' capacities must be canonical integers from 1 to $POOL_HARD_MAX."; return 1;
      }
    done
    [ "$min" -le "$max" ] || { pool_error "Pool '$id' minimum exceeds its maximum."; return 1; }
    [ "$idle" -le "$max" ] || { pool_error "Pool '$id' idle buffer exceeds its maximum."; return 1; }
    sum_fixed=$((sum_fixed + fixed))
    sum_max=$((sum_max + max))
    count=$((count + 1))
    POOL_RECORDS="${POOL_RECORDS}${POOL_RECORDS:+;}${id}|${fixed}|${min}|${max}|${idle}"
  done

  [ "$count" -gt 0 ] || { pool_error "Runner pools mode requires at least one pool."; return 1; }
  [ "$sum_fixed" -le "$POOL_HARD_MAX" ] || {
    pool_error "Runner pool fixed capacity ($sum_fixed) exceeds the fleet hard maximum ($POOL_HARD_MAX)."; return 1;
  }
  [ "$sum_max" -le "$POOL_HARD_MAX" ] || {
    pool_error "Runner pool maximum capacity ($sum_max) exceeds the fleet hard maximum ($POOL_HARD_MAX)."; return 1;
  }
  return 0
}

pool_mode_enabled() {
  [ "${RUNNER_MODE:-single}" = "pools" ]
}

pool_records() {
  pool_config_validate "${RUNNER_MODE:-single}" "${RUNNER_POOLS:-}" "${GH_SCOPE:-repo}" || return 1
  if pool_mode_enabled; then
    printf '%s\n' "$POOL_RECORDS" | tr ';' '\n'
  else
    printf 'default|%s|%s|%s|%s\n' \
      "${RUNNER_COUNT:-4}" "${AUTOSCALE_MIN:-2}" "${AUTOSCALE_MAX:-16}" "${AUTOSCALE_MIN_IDLE:-2}"
  fi
}

pool_record() {
  local want="$1" rec
  while IFS= read -r rec; do
    [ "${rec%%|*}" = "$want" ] && { printf '%s\n' "$rec"; return 0; }
  done < <(pool_records)
  return 1
}

pool_field() {
  local rec
  rec="$(pool_record "$1")" || return 1
  printf '%s\n' "$rec" | cut -d'|' -f"$2"
}

pool_label() {
  [ "$1" = "default" ] && ! pool_mode_enabled && { printf '%s\n' "${RUNNER_LABELS:-}"; return; }
  printf 'ci-pool-%s\n' "$1"
}

pool_fixed() { pool_field "$1" 2; }
pool_min() { pool_field "$1" 3; }
pool_max() { pool_field "$1" 4; }
pool_idle() { pool_field "$1" 5; }

pool_configured_target() {
  if [ "${AUTOSCALE:-false}" = "true" ]; then pool_min "$1"; else pool_fixed "$1"; fi
}

pool_state_generation() {
  local rec
  rec="$(pool_record "$1")" || return 1
  printf '%s' "${RUNNER_MODE:-single}|${AUTOSCALE:-false}|$rec" | sha256sum | cut -c1-12
}
