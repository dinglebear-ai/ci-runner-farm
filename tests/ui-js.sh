#!/usr/bin/env bash
# Syntax-check the inline Fleet/Pools/Settings JavaScript after replacing server-side
# PHP interpolation expressions with inert JavaScript literals.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v node >/dev/null 2>&1 || { echo 'SKIP: node unavailable'; exit 0; }
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

for page in \
  src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page \
  src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmHistory.page \
  src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmLogs.page \
  src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmPools.page \
  src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmImage.page \
  src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmSettings.page; do
  out="$tmpdir/$(basename "$page").js"
  awk '
    /^<script>$/ { inside=1; next }
    /^<\/script>$/ { inside=0; next }
    inside { print }
  ' "$page" | perl -0pe 's/<\?=.*?\?>/null/gs' > "$out"
  node --check "$out"
done

core_js="$tmpdir/crf-core.js"
awk '
  /^<script>$/ { inside=1; next }
  /^<\/script>$/ { inside=0; next }
  inside { print }
' src/usr/local/emhttp/plugins/ci-runner-farm/include/crf-core.php |
  perl -0pe 's/<\?=.*?\?>/null/gs' > "$core_js"
node --check "$core_js"

grep -Fq "put('up','up '+p.up)" src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page
grep -Fq 'CRF_POOL_PENDING.has(pool)' src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page
grep -Fq 'input.min=String(scaleSet?0:(auto?Number(p.count)+1:1))' src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page
grep -Fq 'id="crf-pools-section"' src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page
grep -Fq "fleet.className='crf-pool-fleet'" src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page
grep -Fq 'body.dataset.poolBody=id' src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page
grep -Fq 'class="crf-pool-title"' src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page
grep -Fq "copy.className='crf-pool-selector'" src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page
grep -Fq 'crfCollectPoolRows(tb)' src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page
grep -Fq 'if(tb)crfCollectPoolRows(tb);CRF_BUSY_POOLS.has(pool)' src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page
grep -Fq 'CRF_QUEUE_CANCEL_PENDING.has(key)' src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page
grep -Fq 'if(q!==null){CRF_QUEUE_DEPTH.push(q)' src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page
grep -Fq 'if(q!==null&&q>=3&&!CRF_QUEUE_OPEN)crfToggleQueue(true,false)' src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page
grep -Fq 'crfCloseDrawer();crfCloseRunnerMenu(true);crfToggleHeroMenu(false);crfToggleQueue(false)' src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page
if grep -Eq 'const CRF_LOAD_(CPU|BUSY)=\[' src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page; then
  echo 'Fleet ships hard-coded load history instead of live samples' >&2; exit 1
fi
if grep -Fq "fleet.querySelector('.crf-pool-metrics').innerHTML" src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page; then
  echo 'Fleet still destroys pool metric focus during status polling' >&2; exit 1
fi
if grep -Fq "section.innerHTML=pools.map" src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page; then
  echo 'Fleet still destroys all pool sections during status polling' >&2; exit 1
fi
if grep -Eq 'crf-pool-card|crf-pool-row-head' src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page; then
  echo 'Fleet still renders pool summaries instead of one runner table per pool' >&2; exit 1
fi
grep -Fq "action:'apply-config'" src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmSettings.page
grep -Fq 'CRF_CONFIG_KEYS' src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmSettings.page
grep -Fq "crfSettingsForm.dataset.applying==='1'" src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmSettings.page
! grep -Fq 'name="RUNNER_MODE"' src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmSettings.page
if grep -Fq '/update.php' src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmSettings.page; then
  echo 'Settings still delegates writes to /update.php' >&2; exit 1
fi
grep -Fq '.crfs-card .inline_help{font-size:12px;color:var(--link-text-color,#29b6f6)!important' src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmSettings.page
grep -Fq '#crf-pools-editor{display:grid;gap:8px}' src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmSettings.page
grep -Fq '.crfs-pool-row{display:grid;grid-template-columns:repeat(3,minmax(120px,1fr));gap:8px;align-items:end;border:1px solid var(--border-color);border-radius:6px;padding:10px;min-width:0}' src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmSettings.page
grep -Fq 'button.crfs-pool-label{font-family:bitstream,monospace;font-size:11px;line-height:1.3;letter-spacing:0!important;text-transform:none!important;color:var(--link-text-color)!important;align-self:center;white-space:normal;overflow-wrap:anywhere;background:var(--shade-bg-color,transparent)!important;border:1px solid var(--border-color)!important;border-radius:4px;cursor:pointer;text-align:left;grid-column:1/-1;width:100%!important;min-width:0!important;max-width:100%' src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmSettings.page
grep -Fq '.crfs-pool-row input{width:100%!important;box-sizing:border-box}' src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmSettings.page

pools=src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmPools.page
grep -Fq 'Menu="RunnerFarm:2"' src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmHistory.page
grep -Fq 'Menu="RunnerFarm:3"' src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmLogs.page
grep -Fq 'Menu="RunnerFarm:4"' src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmSettings.page
grep -Fq 'Menu="RunnerFarm:5"' "$pools"
grep -Fq 'Menu="RunnerFarm:6"' src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmImage.page
grep -Fq 'name="RUNNER_MODE"' "$pools"
grep -Fq 'name="RESOURCE_CPU_BUDGET"' "$pools"
grep -Fq 'name="AUTOSCALE"' "$pools"
grep -Fq 'data-pool-field' "$pools"
grep -Fq "input.setAttribute('aria-invalid','true')" "$pools"
grep -Fq "action:'apply-config'" "$pools"
grep -Fq "action:'validate-pools'" "$pools"
grep -Fq 'pool_autoscale:settings.POOL_AUTOSCALE' "$pools"
grep -Fq "(ids.length||scaleSet)?'true':'false'" "$pools"
grep -Fq 'CRF_COMPAT_FAILURES>=8' "$pools"
grep -Fq 'if(!crfPoolsActive())' "$pools"
grep -Fq 'crfBuildPoolEditor(settings.RUNNER_POOLS,settings.POOL_AUTOSCALE)' "$pools"
grep -Fq 'button.crfp-pool-action{width:auto!important' "$pools"
grep -Fq '.crfp-pool-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(380px,1fr));gap:16px}' "$pools"
grep -Fq 'crf_render_shell('\''history'\'')' src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmHistory.page
grep -Fq 'crf_render_shell('\''logs'\'')' src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmLogs.page
image_page=src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmImage.page
grep -Fq "const CRFI_DRAFT_KEY='ci-runner-farm:settings-draft:v1'" "$image_page"
grep -Fq 'crfiStageSettings({IMAGE_AUTOUPDATE:String(value)})' "$image_page"
grep -Fq 'crfiRestoreSettingsDraft();' "$image_page"
grep -Fq 'crfiCandidate(null)' "$image_page"
if grep -Fq "action:'apply-config'" "$image_page"; then
  echo 'Runner Image bypasses the shared Settings review/apply transaction' >&2; exit 1
fi
grep -Fq "'history' => ['History', crf_frame_url('/Utilities/RunnerFarm/RunnerFarmHistory'), 'fa-history']" src/usr/local/emhttp/plugins/ci-runner-farm/include/crf-core.php
grep -Fq 'class="fa <?=$icon?> crf-primary-icon"' src/usr/local/emhttp/plugins/ci-runner-farm/include/crf-core.php
grep -Fq 'grid-template-columns:repeat(4,minmax(0,1fr))' src/usr/local/emhttp/plugins/ci-runner-farm/include/crf-core.php
grep -Fq 'height:calc(66px + env(safe-area-inset-bottom,0px))' src/usr/local/emhttp/plugins/ci-runner-farm/include/crf-core.php
grep -Fq "path==='/Utilities/RunnerFarm/RunnerFarm'" src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarm.page
grep -Fq "path==='/Settings/RunnerFarm'" src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarm.page
grep -Fq "path==='/Settings/RunnerFarm/RunnerFarm'" src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarm.page
grep -Fq '.crfl-line{min-width:0;width:100%' src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmLogs.page
grep -Fq 'grid-template-areas:"name phase menu" "job job menu"' src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page
grep -Fq 'if(!Number.isInteger(key)||key<1||key>CRF_PRIMARY_ROUTES.length)return' src/usr/local/emhttp/plugins/ci-runner-farm/include/crf-core.php
grep -Fq "const CRF_EMBEDDED = <?=crf_is_embedded() ? 'true' : 'false'?>;" src/usr/local/emhttp/plugins/ci-runner-farm/include/crf-core.php
grep -Fq "parent.postMessage({type:'crf:frame-state'" src/usr/local/emhttp/plugins/ci-runner-farm/include/crf-core.php
if grep -Fq 'const index=Number(event.key)-1' src/usr/local/emhttp/plugins/ci-runner-farm/include/crf-core.php; then
  echo 'non-numeric keys can still navigate to /undefined' >&2; exit 1
fi
grep -Fq '"$SRC/RunnerFarmHistory.page"' deploy.sh
grep -Fq '"$SRC/RunnerFarmLogs.page"' deploy.sh

# Execute the empty-state renderer from the page: invalid config must produce a
# disabled mutation button, while a valid empty fleet remains startable.
node - src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page <<'NODE'
const fs=require('fs'), vm=require('vm');
const src=fs.readFileSync(process.argv[2],'utf8');
const match=src.match(/function crfEmptyFleetHtml\(d\)\{[\s\S]*?\n\}/);
if(!match) throw new Error('empty-fleet renderer not found');
const ctx={crfEsc:s=>String(s),crfDark:()=>false};
vm.createContext(ctx); vm.runInContext(match[0],ctx);
const invalid=ctx.crfEmptyFleetHtml({configured:3,config_error:'bad pools'});
if(!invalid.includes('data-crf-mutation')||!invalid.includes(' disabled')) throw new Error('invalid empty fleet has active Start');
const valid=ctx.crfEmptyFleetHtml({configured:3,config_error:''});
if(!valid.includes('data-crf-mutation')||valid.includes(' disabled')) throw new Error('valid empty fleet Start is disabled');
NODE

node tests/fleet-behavior.js
node tests/pool-ui-behavior.js "$pools"

echo 'ui-js: OK'
