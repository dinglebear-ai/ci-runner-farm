#!/bin/bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT_SOURCE="${CRF_AUDIT_SOURCE:-$SCRIPT_DIR/fleet-audit.sh}"
VALIDATION_SOURCE="${CRF_ENDPOINT_VALIDATION_SOURCE:-$SCRIPT_DIR/endpoint-validation.sh}"
BOOT_CONFIG_ROOT="${CRF_BOOT_CONFIG_ROOT:-/boot/config}"
PLUGIN=ci-runner-farm
PLUGIN_CONFIG_DIR="${CRF_PLUGIN_CONFIG_DIR:-$BOOT_CONFIG_ROOT/plugins/$PLUGIN}"
PLUGIN_PLG="${CRF_PLUGIN_PLG:-$PLUGIN_CONFIG_DIR.plg}"
AUDIT_INSTALL_PATH="${CRF_AUDIT_INSTALL_PATH:-$PLUGIN_CONFIG_DIR/fleet-audit.sh}"
VALIDATION_INSTALL_PATH="${CRF_ENDPOINT_VALIDATION_INSTALL_PATH:-$PLUGIN_CONFIG_DIR/endpoint-validation.sh}"
AUDIT_CONFIG="${CRF_AUDIT_CONFIG:-$PLUGIN_CONFIG_DIR/fleet-audit.env}"
AUDIT_LOG_ROOT="${CRF_AUDIT_LOG_ROOT:-/mnt/user/logs/ci-runner-farm-audit}"
USER_SCRIPTS_ROOT="${CRF_USER_SCRIPTS_ROOT:-$BOOT_CONFIG_ROOT/plugins/user.scripts}"
GOTIFY_ENV="${CRF_GOTIFY_ENV:-$USER_SCRIPTS_ROOT/gotify.env}"
USER_SCRIPT_DIR="${CRF_USER_SCRIPT_DIR:-$USER_SCRIPTS_ROOT/scripts/ci-runner-farm-audit}"
USER_SCRIPT_PATH="$USER_SCRIPT_DIR/script"
SCHEDULE_JSON="${CRF_SCHEDULE_JSON:-$USER_SCRIPTS_ROOT/schedule.json}"
CUSTOM_CRON="${CRF_CUSTOM_CRON:-$USER_SCRIPTS_ROOT/customSchedule.cron}"
SCHEDULE="${CRF_AUDIT_SCHEDULE:-30 6 * * *}"
SCHEDULE_ID="${CRF_AUDIT_SCHEDULE_ID:-scheduleci-runner-farm-audit}"
UPDATE_CRON="${CRF_UPDATE_CRON:-1}"
RUN_AUDIT="${CRF_INSTALL_RUN_AUDIT:-0}"

[ -f "$VALIDATION_SOURCE" ] && [ ! -L "$VALIDATION_SOURCE" ] ||
  { echo "endpoint validation library is unavailable: $VALIDATION_SOURCE" >&2; exit 1; }
# shellcheck source=deployments/nashost/endpoint-validation.sh
. "$VALIDATION_SOURCE"

# gotify.env is operator-controlled configuration read by this root installer,
# never a shell program. Accept only one literal assignment for each allowlisted
# key; quotes are delimiters, not evaluation syntax.
load_gotify_literals() {
  local config="$1" line key raw value quote
  local seen_url=0 seen_token=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    case "$line" in
      GOTIFY_URL=*|GOTIFY_TOKEN=*) ;;
      *) echo "Gotify config contains an unknown or executable line" >&2; return 1 ;;
    esac
    key="${line%%=*}"
    raw="${line#*=}"
    [ "${#raw}" -ge 2 ] || {
      echo "Gotify config values must be quoted literals" >&2; return 1;
    }
    quote="${raw:0:1}"
    [ "$quote" = "'" ] || [ "$quote" = '"' ] || {
      echo "Gotify config values must be quoted literals" >&2; return 1;
    }
    [ "${raw: -1}" = "$quote" ] || {
      echo "Gotify config values must be quoted literals" >&2; return 1;
    }
    value="${raw:1:${#raw}-2}"
    case "$value" in
      *"$quote"*) echo "Gotify config values must be simple literals" >&2; return 1 ;;
    esac
    case "$key" in
      GOTIFY_URL)
        [ "$seen_url" -eq 0 ] || { echo "duplicate GOTIFY_URL in Gotify config" >&2; return 1; }
        GOTIFY_URL="$value"; seen_url=1
        ;;
      GOTIFY_TOKEN)
        [ "$seen_token" -eq 0 ] || { echo "duplicate GOTIFY_TOKEN in Gotify config" >&2; return 1; }
        GOTIFY_TOKEN="$value"; seen_token=1
        ;;
    esac
  done <"$config"
}

[ -f "$AUDIT_SOURCE" ] && [ ! -L "$AUDIT_SOURCE" ] ||
  { echo "fleet audit source is unavailable: $AUDIT_SOURCE" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
[[ "$SCHEDULE" =~ ^[^[:cntrl:]]{1,64}$ ]] ||
  { echo "invalid audit schedule" >&2; exit 1; }
if [ -e "$SCHEDULE_JSON" ]; then
  [ -f "$SCHEDULE_JSON" ] && [ ! -L "$SCHEDULE_JSON" ] ||
    { echo "unsafe User Scripts schedule JSON: $SCHEDULE_JSON" >&2; exit 1; }
  jq -e 'type == "object"' "$SCHEDULE_JSON" >/dev/null ||
    { echo "invalid User Scripts schedule JSON" >&2; exit 1; }
fi

GOTIFY_URL="${GOTIFY_URL:-}"
GOTIFY_TOKEN="${GOTIFY_TOKEN:-}"
if [ -e "$GOTIFY_ENV" ]; then
  [ -f "$GOTIFY_ENV" ] && [ ! -L "$GOTIFY_ENV" ] ||
    { echo "unsafe Gotify config: $GOTIFY_ENV" >&2; exit 1; }
  [ "$(stat -c %a "$GOTIFY_ENV")" = 600 ] ||
    { echo "Gotify config must be mode 600: $GOTIFY_ENV" >&2; exit 1; }
  [ "$(stat -c %u "$GOTIFY_ENV")" = "$EUID" ] ||
    { echo "Gotify config must be owned by the installer user: $GOTIFY_ENV" >&2; exit 1; }
  load_gotify_literals "$GOTIFY_ENV" || exit 1
fi
if [ -n "$GOTIFY_TOKEN" ]; then
  [[ "$GOTIFY_TOKEN" =~ ^[A-Za-z0-9._-]+$ ]] ||
    { echo 'GOTIFY_TOKEN contains unsafe characters' >&2; exit 1; }
  [ -n "$GOTIFY_URL" ] ||
    { echo 'GOTIFY_URL is required when GOTIFY_TOKEN is configured' >&2; exit 1; }
  require_gotify_url "$GOTIFY_URL" ||
    { echo 'GOTIFY_URL must use HTTPS; HTTP is allowed only for exact localhost or 127.0.0.1 loopback targets' >&2; exit 1; }
fi

[ -f "$PLUGIN_PLG" ] || { echo "plugin registration is unavailable: $PLUGIN_PLG" >&2; exit 1; }
plugin_version="$(sed -n 's/^<!ENTITY pluginVersion[[:space:]]*"\([^"]*\)">$/\1/p' "$PLUGIN_PLG")"
package_name="$(sed -n 's/^<!ENTITY packageName[[:space:]]*"\([^"]*\)">$/\1/p' "$PLUGIN_PLG")"
package_path="$PLUGIN_CONFIG_DIR/$package_name"
[ -n "$plugin_version" ] && [ -n "$package_name" ] && [ -f "$package_path" ] ||
  { echo "could not resolve the installed plugin package" >&2; exit 1; }
package_hash="$(sha256sum "$package_path" | awk '{print $1}')"
[[ "$package_hash" =~ ^[0-9a-f]{64}$ ]] ||
  { echo "invalid plugin package hash" >&2; exit 1; }

# The public repository cannot carry Nashost's private Kache endpoint. Require
# it on first install and preserve the previously installed value on updates.
kache_endpoint="${CRF_EXPECTED_KACHE_ENDPOINT:-}"
if [ -z "$kache_endpoint" ] && [ -f "$AUDIT_CONFIG" ] && [ ! -L "$AUDIT_CONFIG" ]; then
  kache_endpoint="$(sed -n "s/^CRF_EXPECTED_KACHE_ENDPOINT='\([^']*\)'$/\1/p" "$AUDIT_CONFIG")"
fi
if require_kache_endpoint "$kache_endpoint"; then
  :
else
  status=$?
  case "$status" in
    2) echo "CRF_EXPECTED_KACHE_ENDPOINT must not use a documentation-only address" >&2 ;;
    3) echo "CRF_EXPECTED_KACHE_ENDPOINT contains unsafe characters" >&2 ;;
    4) echo "CRF_EXPECTED_KACHE_ENDPOINT must contain a valid authority" >&2 ;;
    *)
      if [ -z "$kache_endpoint" ]; then
        echo "CRF_EXPECTED_KACHE_ENDPOINT is required on first install" >&2
      else
        echo "CRF_EXPECTED_KACHE_ENDPOINT must be an HTTP or HTTPS URL" >&2
      fi
      ;;
  esac
  exit 1
fi

# All rejection paths above are read-only. Begin installation only after the
# complete source, package identity, schedule, and endpoint contract validates.
mkdir -p "$PLUGIN_CONFIG_DIR" "$USER_SCRIPT_DIR" "$(dirname "$SCHEDULE_JSON")" "$AUDIT_LOG_ROOT"
chmod 0775 "$AUDIT_LOG_ROOT" 2>/dev/null || true

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_dir="$PLUGIN_CONFIG_DIR/audit-schedule-backups/$stamp"
mkdir -p "$backup_dir"
[ ! -e "$SCHEDULE_JSON" ] || cp -a "$SCHEDULE_JSON" "$backup_dir/schedule.json"
[ ! -e "$CUSTOM_CRON" ] || cp -a "$CUSTOM_CRON" "$backup_dir/customSchedule.cron"

install -m 0755 "$VALIDATION_SOURCE" "$VALIDATION_INSTALL_PATH"
install -m 0755 "$AUDIT_SOURCE" "$AUDIT_INSTALL_PATH"

config_tmp="$AUDIT_CONFIG.tmp.$$"
cat > "$config_tmp" <<EOF
# Installed fleet audit identity. Regenerated by install-fleet-audit.sh.
CRF_EXPECTED_PLUGIN_VERSION='$plugin_version'
CRF_EXPECTED_PLUGIN_PACKAGE_SHA256='$package_hash'
CRF_EXPECTED_KACHE_ENDPOINT='$kache_endpoint'
EOF
chmod 0600 "$config_tmp"
mv "$config_tmp" "$AUDIT_CONFIG"

wrapper_tmp="$USER_SCRIPT_PATH.tmp.$$"
cat > "$wrapper_tmp" <<EOF
#!/bin/bash
exec /bin/bash '$AUDIT_INSTALL_PATH'
EOF
chmod 0755 "$wrapper_tmp"
mv "$wrapper_tmp" "$USER_SCRIPT_PATH"

if [ ! -e "$SCHEDULE_JSON" ]; then
  printf '{}\n' > "$SCHEDULE_JSON"
fi
schedule_tmp="$SCHEDULE_JSON.tmp.$$"
jq --arg script "$USER_SCRIPT_PATH" --arg schedule "$SCHEDULE" --arg id "$SCHEDULE_ID" '
  .[$script] = {
    script: $script,
    frequency: "custom",
    id: $id,
    custom: $schedule
  }
' "$SCHEDULE_JSON" > "$schedule_tmp"
chmod --reference="$SCHEDULE_JSON" "$schedule_tmp" 2>/dev/null || chmod 0600 "$schedule_tmp"
mv "$schedule_tmp" "$SCHEDULE_JSON"

cron_tmp="$CUSTOM_CRON.tmp.$$"
if [ -f "$CUSTOM_CRON" ]; then
  grep -vF "startCustom.php $USER_SCRIPT_PATH " "$CUSTOM_CRON" > "$cron_tmp" || true
else
  printf '# Generated cron schedule for user.scripts\n' > "$cron_tmp"
fi
printf '%s /usr/local/emhttp/plugins/user.scripts/startCustom.php %s > /dev/null 2>&1\n' \
  "$SCHEDULE" "$USER_SCRIPT_PATH" >> "$cron_tmp"
chmod 0600 "$cron_tmp"
mv "$cron_tmp" "$CUSTOM_CRON"

if [ "$UPDATE_CRON" = 1 ] && command -v update_cron >/dev/null 2>&1; then
  update_cron
fi

printf 'audit=%s\nconfig=%s\nwrapper=%s\nschedule=%s\nbackup=%s\nplugin=%s\npackage_sha256=%s\n' \
  "$AUDIT_INSTALL_PATH" "$AUDIT_CONFIG" "$USER_SCRIPT_PATH" "$SCHEDULE" "$backup_dir" \
  "$plugin_version" "$package_hash"

if [ "$RUN_AUDIT" = 1 ]; then
  bash "$AUDIT_INSTALL_PATH"
fi
