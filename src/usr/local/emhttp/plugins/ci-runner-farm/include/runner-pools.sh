#!/bin/bash
# Pure runner-pool configuration helpers.
#
# Safe to source from tests: no filesystem, Docker, GitHub, or process side
# effects. The web-written cfg is parsed by runner-farm.sh's allowlisted loader;
# these helpers validate literal values and never eval/source operator input.

POOL_HARD_MAX=64
POOL_MAX_COUNT=8
POOL_CONFIG_MAX_BYTES=16384
POOL_LABEL_MAX_BYTES=63
# shellcheck disable=SC2034 # public results consumed by runtime/tests
POOL_CONFIG_ERROR=""
POOL_CONFIG_ERROR_FIELD=""
POOL_CONFIG_VERSION=""
POOL_RECORDS=""
POOL_SERIALIZED_V2=""
POOL_CONFIG_REVISION=""
POOL_SNAPSHOT_INPUT=""

pool_error() {
  POOL_CONFIG_ERROR="$1"
  POOL_CONFIG_ERROR_FIELD="${2:-}"
  return 1
}

pool_id_valid() {
  [[ "$1" =~ ^[a-z]([a-z0-9-]{0,22}[a-z0-9])?$ ]]
}

pool_owner_valid() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$ ]]
}

pool_uint_valid() {
  [[ "$1" =~ ^[1-9][0-9]?$ ]] && [ "$1" -le "$POOL_HARD_MAX" ]
}

pool_zero_uint_valid() {
  [[ "$1" =~ ^(0|[1-9][0-9]?)$ ]] && [ "$1" -le "$POOL_HARD_MAX" ]
}

pool_label_valid() {
  local label="$1"
  [ -n "$label" ] && [ "${#label}" -le "$POOL_LABEL_MAX_BYTES" ] &&
    [[ "$label" =~ ^[a-z0-9]([a-z0-9._-]*[a-z0-9])?$ ]]
}

pool_label_reserved() {
  case "$1" in
    self-hosted|linux|windows|macos|x64|x86|arm|arm64|default|invalid|ci-runner-farm|ci-pool-*) return 0 ;;
    *) return 1 ;;
  esac
}

parse_cpu_milli() {
  local value="${1,,}" whole fraction
  [ "$value" = "inherit" ] && { printf 'inherit\n'; return 0; }
  [[ "$value" =~ ^(0|[1-9][0-9]*)(\.[0-9]{1,3})?$ ]] || return 1
  whole="${value%%.*}"
  if [ "${value#*.}" = "$value" ]; then
    fraction=0
  else
    fraction="${value#*.}000"
    fraction="${fraction:0:3}"
  fi
  value=$((10#$whole * 1000 + 10#$fraction))
  [ "$value" -gt 0 ] && [ "$value" -le 256000 ] || return 1
  printf '%s\n' "$value"
}

parse_memory_bytes() {
  local value="${1,,}" number suffix multiplier
  [ "$value" = "inherit" ] && { printf 'inherit\n'; return 0; }
  [[ "$value" =~ ^([1-9][0-9]*)(b|k|kb|ki|kib|m|mb|mi|mib|g|gb|gi|gib|t|tb|ti|tib)?$ ]] || return 1
  number="${BASH_REMATCH[1]}"
  suffix="${BASH_REMATCH[2]}"
  case "$suffix" in
    ''|b) multiplier=1 ;;
    k|kb|ki|kib) multiplier=1024 ;;
    m|mb|mi|mib) multiplier=1048576 ;;
    g|gb|gi|gib) multiplier=1073741824 ;;
    t|tb|ti|tib) multiplier=1099511627776 ;;
    *) return 1 ;;
  esac
  [ "${#number}" -le 12 ] || return 1
  value=$((10#$number * multiplier))
  [ "$value" -ge 6291456 ] && [ "$value" -le 1099511627776 ] || return 1
  printf '%s\n' "$value"
}

pool_cpu_canonical() {
  local raw="${1,,}" milli
  [ "$raw" = "inherit" ] && { printf 'inherit\n'; return; }
  milli="$(parse_cpu_milli "$raw")" || return 1
  if [ $((milli % 1000)) -eq 0 ]; then
    printf '%s\n' "$((milli / 1000))"
  else
    printf '%s.%03d\n' "$((milli / 1000))" "$((milli % 1000))" | sed 's/0*$//'
  fi
}

pool_memory_canonical() {
  local raw="${1,,}" bytes
  [ "$raw" = "inherit" ] && { printf 'inherit\n'; return; }
  bytes="$(parse_memory_bytes "$raw")" || return 1
  printf '%s\n' "$bytes"
}

pool_additional_normalize() {
  local raw="${1,,}" label out="" seen="," oldifs
  [ -z "$raw" ] && { printf '\n'; return 0; }
  case "$raw" in
    ','*|*','|*',,'*) return 1 ;;
  esac
  oldifs="$IFS"; IFS=','
  # shellcheck disable=SC2206 # strict comma grammar validated here
  local labels=($raw)
  IFS="$oldifs"
  for label in "${labels[@]}"; do
    pool_label_valid "$label" || return 1
    pool_label_reserved "$label" && return 1
    case "$seen" in *",$label,"*) return 1 ;; esac
    seen="${seen}${label},"
    out="${out}${out:+,}${label}"
  done
  printf '%s\n' "$out"
}

pool_v1_record_normalize() {
  local rec="$1" id fixed min max idle extra
  [ "${rec//[^|]/}" = "||||" ] ||
    { pool_error "Pool '$rec' must have exactly id|fixed|min|max|idle." "record"; return 1; }
  IFS='|' read -r id fixed min max idle extra <<<"$rec"
  [ -z "${extra:-}" ] && [ -n "$idle" ] ||
    { pool_error "Pool '$rec' must have exactly id|fixed|min|max|idle." "record"; return 1; }
  pool_id_valid "$id" ||
    { pool_error "Pool id '$id' must be lowercase, 1-24 characters, and contain only letters, digits, and internal hyphens." "id"; return 1; }
  case "$id" in default|invalid) pool_error "Pool id '$id' is reserved." "id"; return 1 ;; esac
  for n in "$fixed" "$min" "$max" "$idle"; do
    pool_uint_valid "$n" ||
      { pool_error "Pool '$id' capacities must be canonical integers from 1 to $POOL_HARD_MAX." "capacity"; return 1; }
  done
  [ "$min" -le "$max" ] || { pool_error "Pool '$id' minimum exceeds its maximum." "min"; return 1; }
  [ "$idle" -le "$max" ] || { pool_error "Pool '$id' idle buffer exceeds its maximum." "idle"; return 1; }
  printf '%s|%s|%s|%s|%s\n' "$id" "$fixed" "$min" "$max" "$idle"
}

pool_v2_record_normalize() {
  local rec="$1" _version id routing additional fixed min max idle cpus memory extra
  local caps cpu_milli memory_bytes cpu_source memory_source
  [ "${rec//[^|]/}" = "|||||||||" ] ||
    { pool_error "V2 pool '$rec' must have exactly ten fields." "record"; return 1; }
  IFS='|' read -r _version id routing additional fixed min max idle cpus memory extra <<<"$rec"
  [ "$_version" = "v2" ] && [ -z "${extra:-}" ] && [ -n "$memory" ] ||
    { pool_error "V2 pool '$rec' must have exactly ten fields." "record"; return 1; }
  pool_id_valid "$id" ||
    { pool_error "Pool id '$id' must be lowercase, 1-24 characters, and contain only letters, digits, and internal hyphens." "id"; return 1; }
  case "$id" in default|invalid) pool_error "Pool id '$id' is reserved." "id"; return 1 ;; esac
  routing="${routing,,}"
  pool_label_valid "$routing" ||
    { pool_error "Pool '$id' routing label is invalid." "routing_label"; return 1; }
  pool_label_reserved "$routing" &&
    { pool_error "Pool '$id' routing label '$routing' is reserved." "routing_label"; return 1; }
  caps="$(pool_additional_normalize "$additional")" ||
    { pool_error "Pool '$id' has invalid, reserved, or duplicate additional labels." "additional_labels"; return 1; }
  case ",$caps," in *",$routing,"*) pool_error "Pool '$id' repeats its routing label as an additional label." "additional_labels"; return 1 ;; esac
  pool_uint_valid "$fixed" ||
    { pool_error "Pool '$id' fixed capacity must be 1 to $POOL_HARD_MAX." "fixed"; return 1; }
  pool_zero_uint_valid "$min" ||
    { pool_error "Pool '$id' minimum must be 0 to $POOL_HARD_MAX." "min"; return 1; }
  pool_zero_uint_valid "$idle" ||
    { pool_error "Pool '$id' idle target must be 0 to $POOL_HARD_MAX." "idle"; return 1; }
  if [ "$max" != "auto" ]; then
    pool_uint_valid "$max" ||
      { pool_error "Pool '$id' maximum must be 1 to $POOL_HARD_MAX or auto." "max"; return 1; }
    [ "$min" -le "$max" ] || { pool_error "Pool '$id' minimum exceeds its maximum." "min"; return 1; }
    [ "$idle" -le "$max" ] || { pool_error "Pool '$id' idle target exceeds its maximum." "idle"; return 1; }
  fi
  cpus="${cpus,,}"; memory="${memory,,}"
  cpu_milli="$(parse_cpu_milli "$cpus")" ||
    { pool_error "Pool '$id' CPU claim is invalid." "cpus"; return 1; }
  memory_bytes="$(parse_memory_bytes "$memory")" ||
    { pool_error "Pool '$id' memory claim is invalid." "memory"; return 1; }
  cpu_source="$cpus"; memory_source="$memory"
  cpus="$(pool_cpu_canonical "$cpus")" || return 1
  memory="$(pool_memory_canonical "$memory")" || return 1
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$id" "$routing" "$caps" "$fixed" "$min" "$max" "$idle" \
    "$cpu_milli" "$memory_bytes" "$cpu_source" "$memory_source" "$cpus" "$memory"
}

# Validate and normalize one complete immutable snapshot.
# Usage: pool_config_validate <single|pools> <serialized records> <repo|org> [owner]
pool_config_validate() {
  local mode="${1:-}" raw="${2:-}" scope="${3:-}" owner="${4-${GH_OWNER:-}}"
  local rec normalized id routing caps fixed min max idle cpu_milli memory_bytes
  local count=0 sum_fixed=0 sum_max=0 ids=" " routing_seen=" " all_caps=","
  local version="" oldifs
  POOL_CONFIG_ERROR=""; POOL_CONFIG_ERROR_FIELD=""; POOL_CONFIG_VERSION=""
  POOL_RECORDS=""; POOL_SERIALIZED_V2=""; POOL_CONFIG_REVISION=""

  case "$mode" in
    single)
      POOL_CONFIG_VERSION="legacy"
      POOL_CONFIG_REVISION="$(printf '%s' "single|${RUNNER_COUNT:-4}|${RUNNER_LABELS:-}|${RUNNER_CPUS:-}|${RUNNER_MEMORY:-}" | sha256sum | cut -d' ' -f1)"
      return 0
      ;;
    pools) ;;
    *) pool_error "Runner mode must be single or pools." "mode"; return 1 ;;
  esac
  [ "$scope" = "org" ] || { pool_error "Runner pools require Organization scope." "scope"; return 1; }
  pool_owner_valid "$owner" ||
    { pool_error "Organization owner must be 1-39 letters, digits, or internal hyphens." "owner"; return 1; }
  [ -n "$raw" ] || { pool_error "Runner pools mode requires at least one pool." "pools"; return 1; }
  [ "${#raw}" -le "$POOL_CONFIG_MAX_BYTES" ] || { pool_error "Runner pool configuration is too large." "pools"; return 1; }
  case "$raw" in
    *[$'\r\n\t ']*|*\'*|*\"*|*\\*|*/*) pool_error "Runner pools contain unsupported whitespace or characters." "pools"; return 1 ;;
    ';'*|*';'|*';;'*) pool_error "Runner pool entries cannot be empty." "pools"; return 1 ;;
  esac

  oldifs="$IFS"; IFS=';'
  # shellcheck disable=SC2206 # strict semicolon grammar validated below
  local records=($raw)
  IFS="$oldifs"
  [ "${#records[@]}" -le "$POOL_MAX_COUNT" ] ||
    { pool_error "At most $POOL_MAX_COUNT runner pools are supported." "pools"; return 1; }

  for rec in "${records[@]}"; do
    if [[ "$rec" == v2\|* ]]; then
      [ -z "$version" ] || [ "$version" = "v2" ] ||
        { pool_error "V1 and V2 pool records cannot be mixed." "pools"; return 1; }
      version="v2"
      normalized="$(pool_v2_record_normalize "$rec")" || return 1
      IFS='|' read -r id routing caps fixed min max idle cpu_milli memory_bytes _ _ canonical_cpu canonical_memory <<<"$normalized"
      case "$ids" in *" $id "*) pool_error "Pool id '$id' is duplicated." "id"; return 1 ;; esac
      case "$routing_seen" in *" $routing "*) pool_error "Routing label '$routing' is duplicated." "routing_label"; return 1 ;; esac
      case "$all_caps" in *",$routing,"*) pool_error "Routing label '$routing' is used as another pool's additional label." "routing_label"; return 1 ;; esac
      local cap capifs="$IFS"
      IFS=','
      # shellcheck disable=SC2206
      local cap_list=($caps)
      IFS="$capifs"
      for cap in "${cap_list[@]}"; do
        [ -z "$cap" ] && continue
        case "$routing_seen" in *" $cap "*) pool_error "Additional label '$cap' is another pool's routing label." "additional_labels"; return 1 ;; esac
        case "$all_caps" in *",$cap,"*) ;; *) all_caps="${all_caps}${cap}," ;; esac
      done
      ids="${ids}${id} "; routing_seen="${routing_seen}${routing} "
      POOL_RECORDS="${POOL_RECORDS}${POOL_RECORDS:+;}${normalized}"
      POOL_SERIALIZED_V2="${POOL_SERIALIZED_V2}${POOL_SERIALIZED_V2:+;}v2|${id}|${routing}|${caps}|${fixed}|${min}|${max}|${idle}|${canonical_cpu}|${canonical_memory}"
    else
      [ -z "$version" ] || [ "$version" = "v1" ] ||
        { pool_error "V1 and V2 pool records cannot be mixed." "pools"; return 1; }
      version="v1"
      normalized="$(pool_v1_record_normalize "$rec")" || return 1
      id="${normalized%%|*}"
      case "$ids" in *" $id "*) pool_error "Pool id '$id' is duplicated." "id"; return 1 ;; esac
      ids="${ids}${id} "
      IFS='|' read -r _ fixed min max idle <<<"$normalized"
      sum_fixed=$((sum_fixed + fixed)); sum_max=$((sum_max + max))
      POOL_RECORDS="${POOL_RECORDS}${POOL_RECORDS:+;}${normalized}"
    fi
    count=$((count + 1))
  done
  [ "$count" -gt 0 ] || { pool_error "Runner pools mode requires at least one pool." "pools"; return 1; }
  if [ "$version" = "v1" ]; then
    [ "$sum_fixed" -le "$POOL_HARD_MAX" ] ||
      { pool_error "Runner pool fixed capacity ($sum_fixed) exceeds the fleet hard maximum ($POOL_HARD_MAX)." "fixed"; return 1; }
    [ "$sum_max" -le "$POOL_HARD_MAX" ] ||
      { pool_error "Runner pool maximum capacity ($sum_max) exceeds the fleet hard maximum ($POOL_HARD_MAX)." "max"; return 1; }
  fi
  POOL_CONFIG_VERSION="$version"
  pool_policy_validate "${POOL_BACKEND:-classic}" || return 1
  POOL_CONFIG_REVISION="$(printf '%s' "${mode}|${version}|${POOL_RECORDS}|${AUTOSCALE:-false}" | sha256sum | cut -d' ' -f1)"
}

pool_policy_validate() {
  local backend="${1:-classic}" rec id min max
  case "$backend" in classic|scaleset) ;; *) pool_error "Pool backend must be classic or scaleset." "backend"; return 1 ;; esac
  [ "$POOL_CONFIG_VERSION" != "v2" ] && return 0
  while IFS= read -r rec; do
    id="${rec%%|*}"
    min="$(pool_record_field "$rec" 5)"
    max="$(pool_record_field "$rec" 6)"
    if [ "$backend" = "classic" ]; then
      [ "$min" -ge 1 ] || { pool_error "Classic pool '$id' minimum must be at least 1." "min"; return 1; }
      [ "$max" != "auto" ] || { pool_error "Classic pool '$id' cannot use max=auto." "max"; return 1; }
    fi
  done < <(printf '%s\n' "$POOL_RECORDS" | tr ';' '\n')
}

pool_mode_enabled() {
  [ "${RUNNER_MODE:-single}" = "pools" ]
}

pool_snapshot_load() {
  local input="${RUNNER_MODE:-single}|${RUNNER_POOLS:-}|${GH_SCOPE:-repo}|${GH_OWNER:-}|${POOL_BACKEND:-classic}|${RUNNER_CPUS:-}|${RUNNER_MEMORY:-}|${AUTOSCALE:-false}"
  [ "$input" = "$POOL_SNAPSHOT_INPUT" ] && [ -n "$POOL_CONFIG_REVISION" ] && return 0
  pool_config_validate "${RUNNER_MODE:-single}" "${RUNNER_POOLS:-}" "${GH_SCOPE:-repo}" "${GH_OWNER:-}" || return 1
  POOL_SNAPSHOT_INPUT="$input"
}

pool_records() {
  pool_snapshot_load || return 1
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

pool_record_field() {
  local rec="$1" index="$2" field n=1 oldifs="$IFS"
  IFS='|' read -ra fields <<<"$rec"
  IFS="$oldifs"
  field="${fields[$((index - 1))]-}"
  printf '%s\n' "$field"
}

pool_field() {
  local rec
  rec="$(pool_record "$1")" || return 1
  pool_record_field "$rec" "$2"
}

pool_is_v2() {
  [ "${POOL_CONFIG_VERSION:-}" = "v2" ]
}

pool_routing_label() {
  [ "$1" = "default" ] && ! pool_mode_enabled && { printf '%s\n' "${RUNNER_LABELS:-}"; return; }
  pool_snapshot_load || return 1
  if pool_is_v2; then pool_field "$1" 2; else printf 'ci-pool-%s\n' "$1"; fi
}

pool_label() { pool_routing_label "$@"; }

pool_additional_labels() {
  pool_snapshot_load || return 1
  pool_is_v2 && pool_field "$1" 3
}

pool_effective_labels() {
  local route caps
  route="$(pool_routing_label "$1")" || return 1
  caps="$(pool_additional_labels "$1")" || return 1
  printf '%s%s%s\n' "$route" "${caps:+,}" "$caps"
}

pool_fixed() {
  pool_snapshot_load || return 1
  if pool_is_v2; then pool_field "$1" 4; else pool_field "$1" 2; fi
}
pool_min() {
  pool_snapshot_load || return 1
  if pool_is_v2; then pool_field "$1" 5; else pool_field "$1" 3; fi
}
pool_max() {
  pool_snapshot_load || return 1
  if pool_is_v2; then pool_field "$1" 6; else pool_field "$1" 4; fi
}
pool_idle() {
  pool_snapshot_load || return 1
  if pool_is_v2; then pool_field "$1" 7; else pool_field "$1" 5; fi
}
pool_cpu_milli() {
  pool_snapshot_load || return 1
  if pool_is_v2; then
    local value
    value="$(pool_field "$1" 8)"
    [ "$value" != "inherit" ] || value="$(parse_cpu_milli "${RUNNER_CPUS:-1}")"
    printf '%s\n' "$value"
  else
    parse_cpu_milli "${RUNNER_CPUS:-1}"
  fi
}
pool_memory_bytes() {
  pool_snapshot_load || return 1
  if pool_is_v2; then
    local value
    value="$(pool_field "$1" 9)"
    [ "$value" != "inherit" ] || value="$(parse_memory_bytes "${RUNNER_MEMORY:-16g}")"
    printf '%s\n' "$value"
  else
    parse_memory_bytes "${RUNNER_MEMORY:-16g}"
  fi
}
pool_cpu_source() {
  pool_snapshot_load || return 1
  if pool_is_v2; then pool_field "$1" 10; else printf 'inherit\n'; fi
}
pool_memory_source() {
  pool_snapshot_load || return 1
  if pool_is_v2; then pool_field "$1" 11; else printf 'inherit\n'; fi
}

pool_config_serialize_v2() {
  pool_snapshot_load || return 1
  [ "$POOL_CONFIG_VERSION" = "v2" ] || return 1
  printf '%s\n' "$POOL_SERIALIZED_V2"
}

pool_config_revision() {
  pool_snapshot_load || return 1
  printf '%s\n' "$POOL_CONFIG_REVISION"
}

pool_runner_spec_hash() {
  local id="$1" rec
  rec="$(pool_record "$id")" || return 1
  printf '%s' "${RUNNER_MODE:-single}|${POOL_CONFIG_VERSION}|${POOL_BACKEND:-classic}|${AUTOSCALE:-false}|$rec|${RUNNER_CPUS:-}|${RUNNER_MEMORY:-}" |
    sha256sum | cut -d' ' -f1
}

pool_configured_target() {
  if [ "${AUTOSCALE:-false}" = "true" ]; then pool_min "$1"; else pool_fixed "$1"; fi
}

# Compatibility alias for existing tmpfs state names. New protocols must use
# config_revision/runner_spec_hash explicitly.
pool_state_generation() {
  pool_runner_spec_hash "$1" | cut -c1-12
}
