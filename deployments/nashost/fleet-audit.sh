#!/bin/bash
set -Eeuo pipefail
umask 077

PLUGIN=ci-runner-farm
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATION_SOURCE="${CRF_ENDPOINT_VALIDATION_SOURCE:-$SCRIPT_DIR/endpoint-validation.sh}"
[ -f "$VALIDATION_SOURCE" ] && [ ! -L "$VALIDATION_SOURCE" ] ||
  { echo "endpoint validation library is unavailable: $VALIDATION_SOURCE" >&2; exit 2; }
# shellcheck source=deployments/nashost/endpoint-validation.sh
. "$VALIDATION_SOURCE"
ENGINE="${CRF_ENGINE:-/usr/local/emhttp/plugins/$PLUGIN/include/runner-farm.sh}"
PLUGIN_CONFIG_DIR="${CRF_PLUGIN_CONFIG_DIR:-/boot/config/plugins/$PLUGIN}"
AUDIT_CONFIG="${CRF_AUDIT_CONFIG:-$PLUGIN_CONFIG_DIR/fleet-audit.env}"
LOG_ROOT="${CRF_AUDIT_LOG_ROOT:-/mnt/user/logs/ci-runner-farm-audit}"
WATCHDOG_SAMPLE_SECONDS="${CRF_WATCHDOG_SAMPLE_SECONDS:-30}"
GOTIFY_ENV="${CRF_GOTIFY_ENV:-/boot/config/plugins/user.scripts/gotify.env}"
GOTIFY_URL="${GOTIFY_URL:-}"
GOTIFY_TOKEN="${GOTIFY_TOKEN:-}"
CRF_NOTIFY_SUCCESS="${CRF_NOTIFY_SUCCESS:-true}"

# Nashost's production contract. Operators may override any value in
# /boot/config/plugins/ci-runner-farm/fleet-audit.env.
CRF_EXPECTED_COUNT="${CRF_EXPECTED_COUNT:-16}"
CRF_EXPECTED_IMAGE_ID="${CRF_EXPECTED_IMAGE_ID:-sha256:9815f0e3c6ff8145f497842518d27d1dfff295219b6207782734e951aa185061}"
CRF_EXPECTED_KACHE_VERSION="${CRF_EXPECTED_KACHE_VERSION:-0.13.0}"
CRF_EXPECTED_KACHE_SHA256="${CRF_EXPECTED_KACHE_SHA256:-5490686480adca08df1849d6dfba449e7e898e187135a452cfa6c6c40f9ff972}"
CRF_EXPECTED_KACHE_SOCKET="${CRF_EXPECTED_KACHE_SOCKET:-/_work/.kache/daemon.sock}"
CRF_EXPECTED_KACHE_LOCAL_MAX="${CRF_EXPECTED_KACHE_LOCAL_MAX:-80GiB}"
CRF_EXPECTED_KACHE_ENDPOINT="${CRF_EXPECTED_KACHE_ENDPOINT:-}"
CRF_EXPECTED_KACHE_BUCKET="${CRF_EXPECTED_KACHE_BUCKET:-kache}"
CRF_EXPECTED_KACHE_PREFIX="${CRF_EXPECTED_KACHE_PREFIX:-rust}"
CRF_EXPECTED_KACHE_REGION="${CRF_EXPECTED_KACHE_REGION:-us-east-1}"
CRF_EXPECTED_KACHE_PROFILE="${CRF_EXPECTED_KACHE_PROFILE:-kache}"
CRF_EXPECTED_AWS_MOUNT="${CRF_EXPECTED_AWS_MOUNT:-/mnt/cache/runner/kache-aws|false}"
CRF_EXPECTED_CPU_BUDGET_MILLI="${CRF_EXPECTED_CPU_BUDGET_MILLI:-76000}"
CRF_EXPECTED_CPU_RESERVE_MILLI="${CRF_EXPECTED_CPU_RESERVE_MILLI:-1000}"
CRF_EXPECTED_CPU_CONFIGURED_MILLI="${CRF_EXPECTED_CPU_CONFIGURED_MILLI:-74000}"
CRF_EXPECTED_CPU_HEADROOM_MILLI="${CRF_EXPECTED_CPU_HEADROOM_MILLI:-2000}"
CRF_EXPECTED_MEMORY_BUDGET_BYTES="${CRF_EXPECTED_MEMORY_BUDGET_BYTES:-124554051584}"
CRF_EXPECTED_MEMORY_RESERVE_BYTES="${CRF_EXPECTED_MEMORY_RESERVE_BYTES:-8589934592}"
CRF_EXPECTED_MEMORY_CONFIGURED_BYTES="${CRF_EXPECTED_MEMORY_CONFIGURED_BYTES:-122406567936}"
CRF_EXPECTED_MEMORY_HEADROOM_BYTES="${CRF_EXPECTED_MEMORY_HEADROOM_BYTES:-2147483648}"
CRF_RUNNER_NAME_PREFIX="${CRF_RUNNER_NAME_PREFIX:-nashost-}"
CRF_EXPECTED_PLUGIN_VERSION="${CRF_EXPECTED_PLUGIN_VERSION:-}"
CRF_EXPECTED_PLUGIN_PACKAGE_SHA256="${CRF_EXPECTED_PLUGIN_PACKAGE_SHA256:-}"

# Both persistent inputs are data read by a scheduled root process, never shell
# programs. Quotes delimit one literal value; they do not enable expansion.
load_runtime_literals() {
  local config="$1" kind="$2" line key raw value quote seen='|'
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    case "$line" in
      *=*) key="${line%%=*}"; raw="${line#*=}" ;;
      *) echo "$kind config contains an unknown or executable line" >&2; return 1 ;;
    esac
    case "$kind:$key" in
      audit:WATCHDOG_SAMPLE_SECONDS|audit:CRF_NOTIFY_SUCCESS|\
      audit:CRF_EXPECTED_COUNT|audit:CRF_EXPECTED_IMAGE_ID|\
      audit:CRF_EXPECTED_KACHE_VERSION|audit:CRF_EXPECTED_KACHE_SHA256|\
      audit:CRF_EXPECTED_KACHE_SOCKET|audit:CRF_EXPECTED_KACHE_LOCAL_MAX|\
      audit:CRF_EXPECTED_KACHE_ENDPOINT|audit:CRF_EXPECTED_KACHE_BUCKET|\
      audit:CRF_EXPECTED_KACHE_PREFIX|audit:CRF_EXPECTED_KACHE_REGION|\
      audit:CRF_EXPECTED_KACHE_PROFILE|audit:CRF_EXPECTED_AWS_MOUNT|\
      audit:CRF_EXPECTED_CPU_BUDGET_MILLI|audit:CRF_EXPECTED_CPU_RESERVE_MILLI|\
      audit:CRF_EXPECTED_CPU_CONFIGURED_MILLI|audit:CRF_EXPECTED_CPU_HEADROOM_MILLI|\
      audit:CRF_EXPECTED_MEMORY_BUDGET_BYTES|audit:CRF_EXPECTED_MEMORY_RESERVE_BYTES|\
      audit:CRF_EXPECTED_MEMORY_CONFIGURED_BYTES|audit:CRF_EXPECTED_MEMORY_HEADROOM_BYTES|\
      audit:CRF_RUNNER_NAME_PREFIX|audit:CRF_EXPECTED_PLUGIN_VERSION|\
      audit:CRF_EXPECTED_PLUGIN_PACKAGE_SHA256|\
      Gotify:GOTIFY_URL|Gotify:GOTIFY_TOKEN) ;;
      *) echo "$kind config contains unsupported key: $key" >&2; return 1 ;;
    esac
    case "$seen" in
      *"|$key|"*) echo "$kind config contains duplicate key: $key" >&2; return 1 ;;
    esac
    seen="${seen}${key}|"
    [ "${#raw}" -ge 2 ] || {
      echo "$kind config values must be quoted literals" >&2; return 1;
    }
    quote="${raw:0:1}"
    [ "$quote" = "'" ] || [ "$quote" = '"' ] || {
      echo "$kind config values must be quoted literals" >&2; return 1;
    }
    [ "${raw: -1}" = "$quote" ] || {
      echo "$kind config values must be quoted literals" >&2; return 1;
    }
    value="${raw:1:${#raw}-2}"
    case "$value" in
      *"$quote"*) echo "$kind config values must be simple literals" >&2; return 1 ;;
      *\$\(*|*\`*) echo "$kind config substitutions are forbidden" >&2; return 1 ;;
    esac
    printf -v "$key" '%s' "$value"
  done <"$config"
}

if [ -e "$AUDIT_CONFIG" ]; then
  [ -f "$AUDIT_CONFIG" ] && [ ! -L "$AUDIT_CONFIG" ] ||
    { echo "unsafe audit config: $AUDIT_CONFIG" >&2; exit 2; }
  [ "$(stat -c %a "$AUDIT_CONFIG")" = 600 ] ||
    { echo "audit config must be mode 600: $AUDIT_CONFIG" >&2; exit 2; }
  [ "$(stat -c %u "$AUDIT_CONFIG")" = "$EUID" ] ||
    { echo "audit config must be owned by the audit user: $AUDIT_CONFIG" >&2; exit 2; }
  load_runtime_literals "$AUDIT_CONFIG" audit || exit 2
fi
if [ -e "$GOTIFY_ENV" ]; then
  [ -f "$GOTIFY_ENV" ] && [ ! -L "$GOTIFY_ENV" ] ||
    { echo "unsafe Gotify config: $GOTIFY_ENV" >&2; exit 2; }
  [ "$(stat -c %a "$GOTIFY_ENV")" = 600 ] ||
    { echo "Gotify config must be mode 600: $GOTIFY_ENV" >&2; exit 2; }
  [ "$(stat -c %u "$GOTIFY_ENV")" = "$EUID" ] ||
    { echo "Gotify config must be owned by the audit user: $GOTIFY_ENV" >&2; exit 2; }
  load_runtime_literals "$GOTIFY_ENV" Gotify || exit 2
fi
case "$CRF_NOTIFY_SUCCESS" in true|false) ;; *) echo "CRF_NOTIFY_SUCCESS must be true or false" >&2; exit 2 ;; esac

require_uint() {
  [[ "${1:-}" =~ ^(0|[1-9][0-9]*)$ ]]
}
require_sha256() {
  [[ "${1:-}" =~ ^[0-9a-f]{64}$ ]]
}
require_image_id() {
  [[ "${1:-}" =~ ^sha256:[0-9a-f]{64}$ ]]
}
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  return 1
}
assert_eq() {
  local expected="$1" actual="$2" label="$3"
  [ "$actual" = "$expected" ] || fail "$label expected '$expected', got '$actual'"
}
require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command is unavailable: $1"
}
notify_gotify() (
  local title="$1" message="$2" priority="$3" config allowed_proto='=https'
  [ -n "$GOTIFY_TOKEN" ] || return 0
  if [ -n "${GOTIFY_CONFIG_ERROR:-}" ] ||
     [[ ! "$GOTIFY_TOKEN" =~ ^[A-Za-z0-9._-]+$ ]] ||
     [ -z "$GOTIFY_URL" ] || ! require_gotify_url "$GOTIFY_URL"; then
    printf 'Gotify notification configuration failed: %s\n' \
      "${GOTIFY_CONFIG_ERROR:-GOTIFY_URL or GOTIFY_TOKEN is invalid}" >&2
    return 2
  fi
  command -v curl >/dev/null 2>&1 || {
    echo 'Gotify notification delivery failed: curl is unavailable' >&2
    return 1
  }
  config="$(mktemp /tmp/ci-runner-farm-gotify.XXXXXX)" || {
    echo 'Gotify notification delivery failed: could not create protected curl config' >&2
    return 1
  }
  trap 'rm -f "$config"' EXIT
  chmod 0600 "$config"
  printf 'header = "X-Gotify-Key: %s"\n' "$GOTIFY_TOKEN" > "$config"
  case "$GOTIFY_URL" in http://*) allowed_proto='=http' ;; esac
  env -u http_proxy -u https_proxy -u all_proxy \
      -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
    curl --disable -fsS --max-time 15 --noproxy '*' \
    --proto "$allowed_proto" --config "$config" --request POST \
    --url "${GOTIFY_URL%/}/message" \
    --data-urlencode "title=$title" \
    --data-urlencode "message=$message" \
    --data-urlencode "priority=$priority" >/dev/null 2>&1 || {
      echo 'Gotify notification delivery failed: endpoint rejected or did not receive the message' >&2
      return 1
    }
)
notify_failure() {
  local log_file="$1"
  local notify=/usr/local/emhttp/webGui/scripts/notify
  if [ -x "$notify" ]; then
    "$notify" -e "CI Runner Farm Audit" -s "Fleet audit failed" \
      -d "See $log_file" -i alert >/dev/null 2>&1 || true
  fi
  notify_gotify "CI Runner Farm Audit failed" "Nashost fleet verification failed. See $log_file" 8
}
notify_success() {
  local log_file="$1"
  [ "$CRF_NOTIFY_SUCCESS" = true ] || return 0
  notify_gotify "CI Runner Farm Audit passed" \
    "16 runners verified with exact labels, Kache integrity, and 2 CPU / 2 GiB headroom. Log: $log_file" 1
}

GOTIFY_CONFIG_ERROR=""
if [ -n "$GOTIFY_TOKEN" ]; then
  if [[ ! "$GOTIFY_TOKEN" =~ ^[A-Za-z0-9._-]+$ ]]; then
    GOTIFY_CONFIG_ERROR='GOTIFY_TOKEN contains unsafe characters'
  elif [ -z "$GOTIFY_URL" ]; then
    GOTIFY_CONFIG_ERROR='GOTIFY_URL is required when GOTIFY_TOKEN is configured'
  elif ! require_gotify_url "$GOTIFY_URL"; then
    GOTIFY_CONFIG_ERROR='GOTIFY_URL must use HTTPS; HTTP is allowed only for exact localhost or 127.0.0.1 loopback targets'
  fi
fi

for value in \
  "$CRF_EXPECTED_COUNT" "$WATCHDOG_SAMPLE_SECONDS" \
  "$CRF_EXPECTED_CPU_BUDGET_MILLI" "$CRF_EXPECTED_CPU_RESERVE_MILLI" \
  "$CRF_EXPECTED_CPU_CONFIGURED_MILLI" "$CRF_EXPECTED_CPU_HEADROOM_MILLI" \
  "$CRF_EXPECTED_MEMORY_BUDGET_BYTES" "$CRF_EXPECTED_MEMORY_RESERVE_BYTES" \
  "$CRF_EXPECTED_MEMORY_CONFIGURED_BYTES" "$CRF_EXPECTED_MEMORY_HEADROOM_BYTES"; do
  require_uint "$value" || { echo "invalid numeric audit expectation: $value" >&2; exit 2; }
done
require_image_id "$CRF_EXPECTED_IMAGE_ID" ||
  { echo "invalid expected image id" >&2; exit 2; }
require_sha256 "$CRF_EXPECTED_KACHE_SHA256" ||
  { echo "invalid expected Kache hash" >&2; exit 2; }
if require_kache_endpoint "$CRF_EXPECTED_KACHE_ENDPOINT"; then
  :
else
  status=$?
  if [ "$status" -eq 2 ]; then
    echo "CRF_EXPECTED_KACHE_ENDPOINT must not use a documentation-only address" >&2
  elif [ "$status" -eq 3 ]; then
    echo "CRF_EXPECTED_KACHE_ENDPOINT contains unsafe characters" >&2
  elif [ "$status" -eq 4 ]; then
    echo "CRF_EXPECTED_KACHE_ENDPOINT must contain a valid authority" >&2
  elif [ -z "$CRF_EXPECTED_KACHE_ENDPOINT" ]; then
    echo "CRF_EXPECTED_KACHE_ENDPOINT is required in $AUDIT_CONFIG" >&2
  else
    echo "CRF_EXPECTED_KACHE_ENDPOINT must be an HTTP or HTTPS URL" >&2
  fi
  exit 2
fi
[ -n "$CRF_EXPECTED_PLUGIN_VERSION" ] ||
  { echo "CRF_EXPECTED_PLUGIN_VERSION is required in $AUDIT_CONFIG" >&2; exit 2; }
require_sha256 "$CRF_EXPECTED_PLUGIN_PACKAGE_SHA256" ||
  { echo "CRF_EXPECTED_PLUGIN_PACKAGE_SHA256 is required in $AUDIT_CONFIG" >&2; exit 2; }

mkdir -p "$LOG_ROOT"
chmod 0775 "$LOG_ROOT" 2>/dev/null || true
exec 9>"$LOG_ROOT/audit.lock"
flock -n 9 || { echo "another fleet audit is already running" >&2; exit 1; }

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
log_file="$LOG_ROOT/$stamp.log"
tmp_log="$LOG_ROOT/.$stamp.log.tmp.$$"
tmp_dir="$(mktemp -d /tmp/ci-runner-farm-audit.XXXXXX)"
trap 'rm -rf "$tmp_dir" "$tmp_log"' EXIT

audit_body() {
  local status_file="$tmp_dir/status.json"
  local github_file="$tmp_dir/github.json"
  local libdir="$tmp_dir/lib"
  local c image state routing aws_mount details
  local plugin_version package_name package_path package_hash
  local watchdog_pid_before watchdog_pid_after watchdog_count_before watchdog_count_after
  local watchdog_restarts_before watchdog_restarts_after watchdog_status mutation_status

  [ -z "$GOTIFY_CONFIG_ERROR" ] || fail "$GOTIFY_CONFIG_ERROR"

  for cmd in jq php python3 docker sha256sum stat pgrep ps flock; do
    require_command "$cmd"
  done
  [ -x "$ENGINE" ] || fail "runner farm engine is unavailable: $ENGINE"

  printf 'audit_started=%s\n' "$(date -u +%FT%TZ)"
  "$ENGINE" status-json > "$status_file"
  jq -e 'type == "object"' "$status_file" >/dev/null

  assert_eq "$CRF_EXPECTED_COUNT" "$(jq -r '.configured' "$status_file")" "configured runner count"
  assert_eq "$CRF_EXPECTED_COUNT" "$(jq -r '.count' "$status_file")" "current runner count"
  assert_eq 0 "$(jq -r '.stale' "$status_file")" "stale runner count"
  assert_eq 0 "$(jq -r '.retiring' "$status_file")" "retiring runner count"
  assert_eq 0 "$(jq -r '.blocked_capacity' "$status_file")" "blocked capacity"
  assert_eq 0 "$(jq -r '(.total_starting // 0)' "$status_file")" "starting runner count"
  assert_eq "" "$(jq -r '.config_error // ""' "$status_file")" "configuration error"

  assert_eq "$CRF_EXPECTED_CPU_BUDGET_MILLI" \
    "$(jq -r '.resources.cpu_milli.budget' "$status_file")" "CPU budget"
  assert_eq "$CRF_EXPECTED_CPU_RESERVE_MILLI" \
    "$(jq -r '.resources.cpu_milli.reserve' "$status_file")" "CPU reserve"
  assert_eq "$CRF_EXPECTED_CPU_CONFIGURED_MILLI" \
    "$(jq -r '.resources.cpu_milli.configured' "$status_file")" "configured CPU"
  assert_eq "$CRF_EXPECTED_CPU_HEADROOM_MILLI" \
    "$(jq -r '.resources.cpu_milli.configured_headroom' "$status_file")" "configured CPU headroom"
  assert_eq "$CRF_EXPECTED_CPU_CONFIGURED_MILLI" \
    "$(jq -r '.resources.cpu_milli.reserved' "$status_file")" "reserved CPU"
  assert_eq "$CRF_EXPECTED_CPU_HEADROOM_MILLI" \
    "$(jq -r '.resources.cpu_milli.admissible' "$status_file")" "admissible CPU"

  assert_eq "$CRF_EXPECTED_MEMORY_BUDGET_BYTES" \
    "$(jq -r '.resources.memory_bytes.budget' "$status_file")" "memory budget"
  assert_eq "$CRF_EXPECTED_MEMORY_RESERVE_BYTES" \
    "$(jq -r '.resources.memory_bytes.reserve' "$status_file")" "memory reserve"
  assert_eq "$CRF_EXPECTED_MEMORY_CONFIGURED_BYTES" \
    "$(jq -r '.resources.memory_bytes.configured' "$status_file")" "configured memory"
  assert_eq "$CRF_EXPECTED_MEMORY_HEADROOM_BYTES" \
    "$(jq -r '.resources.memory_bytes.configured_headroom' "$status_file")" "configured memory headroom"
  assert_eq "$CRF_EXPECTED_MEMORY_CONFIGURED_BYTES" \
    "$(jq -r '.resources.memory_bytes.reserved' "$status_file")" "reserved memory"
  assert_eq "$CRF_EXPECTED_MEMORY_HEADROOM_BYTES" \
    "$(jq -r '.resources.memory_bytes.admissible' "$status_file")" "admissible memory"

  mapfile -t names < <(
    docker ps --filter label=net.unraid.ci-runner-farm.managed=true --format '{{.Names}}' | sort
  )
  assert_eq "$CRF_EXPECTED_COUNT" "${#names[@]}" "managed container count"

  for c in "${names[@]}"; do
    image="$(docker inspect "$c" --format '{{.Image}}')"
    state="$(docker inspect "$c" --format '{{.State.Status}}')"
    routing="$(docker inspect "$c" --format '{{index .Config.Labels "net.unraid.ci-runner-farm.routing-label"}}')"
    aws_mount="$(docker inspect "$c" --format '{{range .Mounts}}{{if eq .Destination "/home/runner/.aws"}}{{.Source}}|{{.RW}}{{end}}{{end}}')"
    assert_eq "$CRF_EXPECTED_IMAGE_ID" "$image" "$c image"
    assert_eq running "$state" "$c state"
    [ -n "$routing" ] || fail "$c has no routing label"
    assert_eq "$CRF_EXPECTED_AWS_MOUNT" "$aws_mount" "$c AWS mount"

    details="$(docker exec -i "$c" sh -s -- \
      "$CRF_EXPECTED_KACHE_VERSION" "$CRF_EXPECTED_KACHE_SHA256" \
      "$CRF_EXPECTED_KACHE_SOCKET" "$CRF_EXPECTED_KACHE_LOCAL_MAX" \
      "$CRF_EXPECTED_KACHE_ENDPOINT" "$CRF_EXPECTED_KACHE_BUCKET" \
      "$CRF_EXPECTED_KACHE_PREFIX" "$CRF_EXPECTED_KACHE_REGION" \
      "$CRF_EXPECTED_KACHE_PROFILE" <<'INNER'
set -eu
version="$1"; binary_sha="$2"; socket="$3"; local_max="$4"; endpoint="$5"
bucket="$6"; prefix="$7"; region="$8"; profile="$9"
cfg=/home/runner/.config/kache/config.toml
test -f "$cfg"
test -S "$socket"
test "$(kache --version)" = "kache $version"
test "$(sha256sum /usr/local/bin/kache | awk '{print $1}')" = "$binary_sha"
supervisors=$(ps -eo user=,args= | awk '$1=="runner" && $0 ~ /[k]ache-supervise[.]sh/ {n++} END {print n+0}')
daemons=$(ps -eo user=,args= | awk '$1=="runner" && $0 ~ /[/]kache daemon run$/ {n++} END {print n+0}')
daemon_pid=$(ps -eo user=,pid=,args= | awk '$1=="runner" && $0 ~ /[/]kache daemon run$/ {print $2; exit}')
test "$supervisors" -eq 1
test "$daemons" -eq 1
daemon_exe=$(readlink -f "/proc/$daemon_pid/exe")
test "$(sha256sum "$daemon_exe" | awk '{print $1}')" = "$binary_sha"
grep -Fq "local_store = \"/_work/.kache\"" "$cfg"
grep -Fq "local_max_size = \"$local_max\"" "$cfg"
grep -Fq 'prefetch_enabled = false' "$cfg"
grep -Fq 'type = "s3"' "$cfg"
grep -Fq "bucket = \"$bucket\"" "$cfg"
grep -Fq "endpoint = \"$endpoint\"" "$cfg"
grep -Fq "region = \"$region\"" "$cfg"
grep -Fq "prefix = \"$prefix\"" "$cfg"
grep -Fq "profile = \"$profile\"" "$cfg"
tr -d '\r' < /home/runner/.aws/credentials | grep -Fxq "[$profile]"
printf 'kache=%s sha256=%s supervisors=%s daemons=%s socket=%s remote=s3://%s/%s l1=%s' \
  "$version" "$binary_sha" "$supervisors" "$daemons" "$socket" "$bucket" "$prefix" "$local_max"
INNER
)"
    printf '%s image=%s route=%s %s\n' "$c" "$image" "$routing" "$details"
  done

  mkdir -p "$libdir"
  cp "$(dirname "$ENGINE")"/*.sh "$libdir/"
  python3 - "$ENGINE" "$libdir/runner-farm.sh" <<'PY'
from pathlib import Path
import sys
src = Path(sys.argv[1]).read_text()
marker = 'case "${1:-status}" in'
Path(sys.argv[2]).write_text(src.rsplit(marker, 1)[0])
PY
  # shellcheck disable=SC1091
  source "$libdir/runner-farm.sh"
  github_api_token_load
  target="${GH_SCOPE}:${GH_OWNER}"
  base="$(github_scope_base "$target")"
  printf '{"runners":[' > "$github_file"
  local page=1 first=true page_file="$tmp_dir/github-page.json" item_count
  while :; do
    gh_api_request GET "$base/actions/runners?per_page=100&page=$page"
    assert_eq 200 "$GH_STATUS" "GitHub runner inventory HTTP status"
    printf '%s' "$GH_RESPONSE" > "$page_file"
    item_count="$(jq -r '(.runners // []) | length' "$page_file")"
    while IFS= read -r item; do
      if [ "$first" = true ]; then first=false; else printf ',' >> "$github_file"; fi
      printf '%s' "$item" >> "$github_file"
    done < <(jq -c '.runners[]?' "$page_file")
    [ "$item_count" -lt 100 ] && break
    page=$((page + 1))
    [ "$page" -le 20 ] || fail "GitHub runner pagination exceeded safety bound"
  done
  printf ']}' >> "$github_file"

  # The embedded PHP is intentionally single-quoted so Bash cannot expand it.
  # shellcheck disable=SC2016
  php -r '
$status=json_decode(file_get_contents($argv[1]),true);
$gh=json_decode(file_get_contents($argv[2]),true);
$expected=(int)$argv[3];
$prefix=$argv[4];
if(!is_array($status)||!is_array($gh)) exit(2);
$pools=[];
foreach(($status["pools"]??[]) as $p){
  $labels=array_values(array_filter(explode(",",(string)($p["effective_labels"]??"")),"strlen"));
  sort($labels,SORT_STRING);
  $pools[(string)$p["id"]]=$labels;
}
$current=[];
foreach(($status["runners"]??[]) as $runner){
  $current[$prefix.(string)$runner["name"]]=(string)$runner["pool"];
}
if(count($current)!==$expected){fwrite(STDERR,"status identity count mismatch\n");exit(1);}
$managed=[];
foreach(($gh["runners"]??[]) as $runner){
  $name=(string)($runner["name"]??"");
  if(str_starts_with($name,$prefix."ci-runner-")) $managed[$name][]=$runner;
}
if(count($managed)!==$expected){fwrite(STDERR,"GitHub managed identity count mismatch: ".count($managed)."\n");exit(1);}
foreach($current as $name=>$pool){
  if(count($managed[$name]??[])!==1){fwrite(STDERR,"identity count mismatch for $name\n");exit(1);}
  $runner=$managed[$name][0];
  if(($runner["status"]??"")!=="online"){fwrite(STDERR,"offline runner $name\n");exit(1);}
  $actual=array_map(fn($x)=>(string)($x["name"]??""),$runner["labels"]??[]);
  $expectedLabels=array_values(array_unique(array_merge(["self-hosted","Linux","X64"],$pools[$pool]??[])));
  sort($actual,SORT_STRING); sort($expectedLabels,SORT_STRING);
  if($actual!==$expectedLabels){
    fwrite(STDERR,"label mismatch for $name: actual=".implode(",",$actual)." expected=".implode(",",$expectedLabels)."\n");
    exit(1);
  }
  printf("%s id=%s online busy=%s labels=%s\n",$name,$runner["id"]??"",!empty($runner["busy"])?"true":"false",implode(",",$actual));
}
printf("github_online_exact=%d\n",count($current));
' "$status_file" "$github_file" "$CRF_EXPECTED_COUNT" "$CRF_RUNNER_NAME_PREFIX"

  plugin_version="$(sed -n 's/^<!ENTITY pluginVersion[[:space:]]*"\([^"]*\)">$/\1/p' "$PLUGIN_CONFIG_DIR.plg")"
  package_name="$(sed -n 's/^<!ENTITY packageName[[:space:]]*"\([^"]*\)">$/\1/p' "$PLUGIN_CONFIG_DIR.plg")"
  package_path="$PLUGIN_CONFIG_DIR/$package_name"
  [ -f "$package_path" ] || fail "installed plugin package is unavailable: $package_path"
  package_hash="$(sha256sum "$package_path" | awk '{print $1}')"
  assert_eq "$CRF_EXPECTED_PLUGIN_VERSION" "$plugin_version" "plugin version"
  assert_eq "$CRF_EXPECTED_PLUGIN_PACKAGE_SHA256" "$package_hash" "plugin package hash"

  reconcile_status="$("$ENGINE" reconcile-status)" ||
    fail "reconciliation ownership status is invalid"
  assert_eq true "$(jq -r '.ok' <<<"$reconcile_status")" "reconciliation ownership status"
  assert_eq false "$(jq -r '.active' <<<"$reconcile_status")" "reconciliation worker activity"
  mutation_status="$("$ENGINE" mutation-owner-status)"
  assert_eq false "$(jq -r '.active' <<<"$mutation_status")" "mutation owner activity"

  watchdog_pid_before="$(cat /var/local/emhttp/ci-runner-farm/kache-watchdog.pid)"
  watchdog_count_before="$(pgrep -af '[r]unner-farm.sh kache-watchdog-daemon' | wc -l)"
  watchdog_restarts_before="$(grep -c 'kache-watchdog: restarting unhealthy supervisor' /var/local/emhttp/ci-runner-farm/autoscale.log || true)"
  sleep "$WATCHDOG_SAMPLE_SECONDS"
  watchdog_pid_after="$(cat /var/local/emhttp/ci-runner-farm/kache-watchdog.pid)"
  watchdog_count_after="$(pgrep -af '[r]unner-farm.sh kache-watchdog-daemon' | wc -l)"
  watchdog_restarts_after="$(grep -c 'kache-watchdog: restarting unhealthy supervisor' /var/local/emhttp/ci-runner-farm/autoscale.log || true)"
  watchdog_status="$("$ENGINE" kache-watchdog-status)"
  assert_eq "$watchdog_pid_before" "$watchdog_pid_after" "watchdog PID stability"
  assert_eq 1 "$watchdog_count_before" "watchdog process count before sample"
  assert_eq 1 "$watchdog_count_after" "watchdog process count after sample"
  assert_eq "$watchdog_restarts_before" "$watchdog_restarts_after" "watchdog restart count"
  grep -Fq 'running (pid ' <<<"$watchdog_status" || fail "watchdog status is not running"

  printf 'plugin=%s package_sha256=%s watchdog_pid=%s reconcile=stopped mutation_owner=inactive\n' \
    "$plugin_version" "$package_hash" "$watchdog_pid_after"
  printf 'audit_result=PASS audit_completed=%s\n' "$(date -u +%FT%TZ)"
}

set +e
(
  set -Eeuo pipefail
  audit_body
) > "$tmp_log" 2>&1
rc=$?
set -e

mv "$tmp_log" "$log_file"
chmod 0644 "$log_file"
ln -sfn "$(basename "$log_file")" "$LOG_ROOT/latest.log"

if [ "$rc" -ne 0 ]; then
  set +e
  notification_error="$(notify_failure "$log_file" 2>&1)"
  notification_rc=$?
  set -e
  if [ -z "$GOTIFY_TOKEN" ]; then
    printf 'notification_result=SKIPPED gotify=disabled\n' >>"$log_file"
  elif [ "$notification_rc" -eq 0 ]; then
    printf 'notification_result=PASS gotify=delivered\n' >>"$log_file"
  else
    printf 'notification_result=FAIL gotify=%s\n' "$notification_error" >>"$log_file"
  fi
  cat "$log_file"
  exit "$rc"
fi
set +e
notification_error="$(notify_success "$log_file" 2>&1)"
notification_rc=$?
set -e
if [ "$CRF_NOTIFY_SUCCESS" = false ] || [ -z "$GOTIFY_TOKEN" ]; then
  printf 'notification_result=SKIPPED gotify=disabled\n' >>"$log_file"
elif [ "$notification_rc" -eq 0 ]; then
  printf 'notification_result=PASS gotify=delivered\n' >>"$log_file"
else
  printf 'notification_result=FAIL gotify=%s\n' "$notification_error" >>"$log_file"
fi
cat "$log_file"
[ "$notification_rc" -eq 0 ] || exit 3
