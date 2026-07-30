#!/usr/bin/env bash
# Syntax-check the inline Fleet/Settings JavaScript after replacing server-side
# PHP interpolation expressions with inert JavaScript literals.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v node >/dev/null 2>&1 || { echo 'SKIP: node unavailable'; exit 0; }
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

for page in \
  src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page \
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
grep -Fq "min=\"'+(auto?Number(p.count)+1:1)" src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page
grep -Fq "mode!=='pools'" src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmSettings.page
grep -Fq "action:'apply-config'" src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmSettings.page
grep -Fq 'CRF_CONFIG_KEYS' src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmSettings.page
grep -Fq 'data-pool-field' src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmSettings.page
grep -Fq "crfSettingsForm.dataset.applying==='1'" src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmSettings.page
if grep -Fq '/update.php' src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmSettings.page; then
  echo 'Settings still delegates writes to /update.php' >&2; exit 1
fi
grep -Fq "document.addEventListener('crf-pools-change',check)" src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmSettings.page
grep -Fq "input.setAttribute('aria-describedby','crf-pools-errors crf-pool-'" src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmSettings.page
grep -Fq "input.setAttribute('aria-invalid','true')" src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmSettings.page
grep -Fq "'Remove '+subject" src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmSettings.page

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
