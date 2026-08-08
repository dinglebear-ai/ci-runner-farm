#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
. tests/lib/assert.sh

AUDIT=deployments/nashost/fleet-audit.sh
INSTALLER=deployments/nashost/install-fleet-audit.sh
bash -n "$AUDIT"
bash -n "$INSTALLER"

# These are literal source-contract strings, not expressions for this test shell.
# shellcheck disable=SC2016
for needle in \
  'CRF_EXPECTED_COUNT="${CRF_EXPECTED_COUNT:-16}"' \
  'CRF_EXPECTED_CPU_CONFIGURED_MILLI="${CRF_EXPECTED_CPU_CONFIGURED_MILLI:-74000}"' \
  'CRF_EXPECTED_CPU_HEADROOM_MILLI="${CRF_EXPECTED_CPU_HEADROOM_MILLI:-2000}"' \
  'CRF_EXPECTED_MEMORY_CONFIGURED_BYTES="${CRF_EXPECTED_MEMORY_CONFIGURED_BYTES:-122406567936}"' \
  'CRF_EXPECTED_MEMORY_HEADROOM_BYTES="${CRF_EXPECTED_MEMORY_HEADROOM_BYTES:-2147483648}"' \
  'github_online_exact=' \
  'mutation-owner-status' \
  'kache-watchdog-daemon' \
  'GOTIFY_ENV=' \
  'X-Gotify-Key:' \
  'notify_success'; do
  grep -Fq "$needle" "$AUDIT" || crf_fail "audit contract missing: $needle"
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
boot="$tmp/boot"
plugin_dir="$boot/plugins/ci-runner-farm"
user_root="$boot/plugins/user.scripts"
mkdir -p "$plugin_dir" "$user_root/scripts/existing" "$tmp/logs"
package=ci-runner-farm-test.tgz
printf 'package payload\n' > "$plugin_dir/$package"
cat > "$plugin_dir.plg" <<EOF
<!ENTITY pluginVersion "9.9.9">
<!ENTITY packageName "$package">
EOF
cat > "$user_root/schedule.json" <<'EOF'
{
  "/existing/script": {
    "script": "/existing/script",
    "frequency": "custom",
    "id": "scheduleexisting",
    "custom": "0 1 * * *"
  }
}
EOF
cat > "$user_root/customSchedule.cron" <<'EOF'
# Generated cron schedule for user.scripts
0 1 * * * /usr/local/emhttp/plugins/user.scripts/startCustom.php /existing/script > /dev/null 2>&1
EOF

env \
  CRF_BOOT_CONFIG_ROOT="$boot" \
  CRF_AUDIT_SOURCE="$PWD/$AUDIT" \
  CRF_AUDIT_LOG_ROOT="$tmp/logs" \
  CRF_UPDATE_CRON=0 \
  CRF_INSTALL_RUN_AUDIT=0 \
  bash "$INSTALLER" > "$tmp/install.out"

installed="$plugin_dir/fleet-audit.sh"
config="$plugin_dir/fleet-audit.env"
wrapper="$user_root/scripts/ci-runner-farm-audit/script"
crf_assert_file_mode "$installed" 755
crf_assert_file_mode "$config" 600
crf_assert_file_mode "$wrapper" 755
grep -Fq "CRF_EXPECTED_PLUGIN_VERSION='9.9.9'" "$config"
grep -Fq "$(sha256sum "$plugin_dir/$package" | awk '{print $1}')" "$config"
grep -Fq "exec '$installed'" "$wrapper"
jq -e --arg script "$wrapper" '
  .["/existing/script"].custom == "0 1 * * *" and
  .[$script].frequency == "custom" and
  .[$script].custom == "30 6 * * *"
' "$user_root/schedule.json" >/dev/null
grep -Fq '/existing/script' "$user_root/customSchedule.cron"
crf_assert_eq 1 "$(grep -Fc "startCustom.php $wrapper " "$user_root/customSchedule.cron")" "audit cron entry count"

# Reinstalling is idempotent and must preserve unrelated schedules.
sleep 1
env \
  CRF_BOOT_CONFIG_ROOT="$boot" \
  CRF_AUDIT_SOURCE="$PWD/$AUDIT" \
  CRF_AUDIT_LOG_ROOT="$tmp/logs" \
  CRF_UPDATE_CRON=0 \
  CRF_INSTALL_RUN_AUDIT=0 \
  bash "$INSTALLER" >/dev/null
crf_assert_eq 1 "$(grep -Fc "startCustom.php $wrapper " "$user_root/customSchedule.cron")" "idempotent audit cron entry"
jq -e '.["/existing/script"].id == "scheduleexisting"' "$user_root/schedule.json" >/dev/null
[ "$(find "$plugin_dir/audit-schedule-backups" -mindepth 1 -maxdepth 1 -type d | wc -l)" -ge 2 ] ||
  crf_fail "installer did not preserve schedule backups"

echo 'nashost-fleet-audit: OK'
