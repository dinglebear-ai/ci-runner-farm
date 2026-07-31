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
  src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmPools.page \
  src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmSettings.page; do
  out="$tmpdir/$(basename "$page").js"
  awk '
    /^<script>$/ { inside=1; next }
    /^<\/script>$/ { inside=0; next }
    inside { print }
  ' "$page" | perl -0pe 's/<\?=.*?\?>/null/gs' > "$out"
  node --check "$out"
done

grep -Fq "up '+crfEsc(p.up)" src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page
grep -Fq 'CRF_POOL_PENDING.has(pool)' src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page
grep -Fq 'input.min=String(scaleSet?0:(auto?Number(p.count)+1:1))' src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page
grep -Fq 'id="crf-pools-section"' src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page
grep -Fq "fleet.className='crf-pool-fleet'" src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page
grep -Fq 'body.dataset.poolBody=id' src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page
grep -Fq 'class="crf-pool-title"' src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page
grep -Fq "copy.className='crf-pool-selector'" src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page
grep -Fq 'crfCollectPoolRows(tb)' src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page
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

pools=src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmPools.page
grep -Fq 'Menu="RunnerFarm:2"' "$pools"
grep -Fq 'Menu="RunnerFarm:3"' src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmImage.page
grep -Fq 'Menu="RunnerFarm:4"' src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmSettings.page
grep -Fq 'name="RUNNER_MODE"' "$pools"
grep -Fq 'name="RESOURCE_CPU_BUDGET"' "$pools"
grep -Fq 'name="AUTOSCALE"' "$pools"
grep -Fq 'data-pool-field' "$pools"
grep -Fq "input.setAttribute('aria-invalid','true')" "$pools"
grep -Fq "action:'apply-config'" "$pools"
grep -Fq "action:'validate-pools'" "$pools"
grep -Fq 'CRF_COMPAT_FAILURES>=8' "$pools"
grep -Fq 'if(!crfPoolsActive())' "$pools"
grep -Fq 'crfBuildPoolEditor(settings.RUNNER_POOLS)' "$pools"
grep -Fq 'button.crfp-pool-action{width:auto!important' "$pools"
grep -Fq '.crfp-card .inline_help{font-size:12px;color:var(--link-text-color,#29b6f6)!important' "$pools"

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

echo 'ui-js: OK'
