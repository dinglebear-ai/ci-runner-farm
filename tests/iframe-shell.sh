#!/usr/bin/env bash
# shellcheck disable=SC2016
# PHP snippets are intentionally single-quoted.
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib/assert.sh

frame=src/usr/local/emhttp/plugins/ci-runner-farm/include/crf-frame.php
core=src/usr/local/emhttp/plugins/ci-runner-farm/include/crf-core.php
php -l "$frame" >/dev/null

pages=(
  RunnerFarmFleet
  RunnerFarmHistory
  RunnerFarmLogs
  RunnerFarmSettings
  RunnerFarmPools
  RunnerFarmImage
)
for page in "${pages[@]}"; do
  file="src/usr/local/emhttp/plugins/ci-runner-farm/${page}.page"
  grep -Fq "require_once '/usr/local/emhttp/plugins/ci-runner-farm/include/crf-frame.php';" "$file" ||
    crf_fail "$page does not load the frame host"
  grep -Fq "crf_begin_embedded_page('${page}'" "$file" ||
    crf_fail "$page does not gate native and embedded rendering"
  gate_line="$(grep -nF "crf_begin_embedded_page('${page}'" "$file" | head -1 | cut -d: -f1)"
  core_line="$(grep -nF "include/crf-core.php" "$file" | head -1 | cut -d: -f1)"
  [ "$gate_line" -lt "$core_line" ] || crf_fail "$page loads the app before the frame gate"
done

host_html="$(php -r '
  $_GET=[];
  require $argv[1];
  ob_start();
  $embedded=crf_begin_embedded_page("RunnerFarmFleet", "Runner Farm: Runners");
  $html=ob_get_clean();
  if ($embedded) exit(2);
  echo $html;
' "$frame")"
crf_assert_contains "$host_html" 'class="crf-frame-host"' 'native route does not render a frame host'
crf_assert_contains "$host_html" '<iframe' 'native route does not render an iframe'
crf_assert_contains "$host_html" 'src="/Utilities/RunnerFarm/RunnerFarmFleet?crf_embed=1"' 'iframe source is not embedded mode'
crf_assert_contains "$host_html" "data.type!=='crf:frame-state'" 'frame host does not receive size/navigation state'
crf_assert_contains "$host_html" 'history.replaceState' 'frame navigation does not synchronize the outer URL'
case "$host_html" in *'history.pushState'*) crf_fail 'frame navigation creates duplicate browser-history entries' ;; esac
case "$host_html" in
  *'#header'*|*'#menu'*|*'#footer'*) crf_fail 'outer frame host hides global Unraid chrome' ;;
esac

php -r '
  $_GET=["crf_embed"=>"1"];
  require $argv[1];
  ob_start();
  $embedded=crf_begin_embedded_page("RunnerFarmFleet", "Runner Farm: Runners");
  $html=ob_get_clean();
  if (!$embedded || $html !== "") exit(2);
  if (crf_frame_url("/Utilities/RunnerFarm/RunnerFarmLogs") !== "/Utilities/RunnerFarm/RunnerFarmLogs?crf_embed=1") exit(3);
  if (crf_frame_url("/Utilities/RunnerFarm/RunnerFarmLogs?view=errors") !== "/Utilities/RunnerFarm/RunnerFarmLogs?view=errors&crf_embed=1") exit(4);
' "$frame"

php -r '
  $_GET=[];
  require $argv[1];
  if (crf_frame_url("/Utilities/RunnerFarm/RunnerFarmLogs") !== "/Utilities/RunnerFarm/RunnerFarmLogs") exit(2);
' "$frame"

grep -Fq "body:has(.crf-app-header) #header" "$core" || crf_fail 'embedded document no longer hides its duplicate Unraid header'
grep -Fq "crf_frame_url('/Utilities/RunnerFarm/RunnerFarmHistory')" "$core" || crf_fail 'product navigation escapes embedded mode'
grep -Fq "parent.postMessage({type:'crf:frame-state'" "$core" || crf_fail 'embedded document does not report frame state'

command -v node >/dev/null 2>&1 || { echo 'iframe-shell: OK (node unavailable; host JS check skipped)'; exit 0; }
tmpdir="$(mktemp -d)"
tmp="$tmpdir/frame-host.js"
trap 'rm -rf "$tmpdir"' EXIT
printf '%s
' "$host_html" | awk '
  /^    <script>$/ { inside=1; next }
  /^    <\/script>$/ { inside=0; next }
  inside { sub(/^    /, ""); print }
' > "$tmp"
node --check "$tmp"

echo 'iframe-shell: OK'
