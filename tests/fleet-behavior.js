'use strict';
const fs = require('fs');
const vm = require('vm');
const page = fs.readFileSync('src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page', 'utf8');
const engine = fs.readFileSync('src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh', 'utf8');

function must(condition, message) { if (!condition) throw new Error(message); }
function functionSource(name) {
  const match = page.match(new RegExp('function ' + name + '\\([^)]*\\)\\{[\\s\\S]*?\\n\\}'));
  must(match, name + ' function missing');
  return match[0];
}

must(page.includes('Tracked repository run queue'), 'queue tile is not accurately named');
must(page.includes('not pool demand'), 'queue tile lacks its demand limitation');
must(page.includes('id="crf-s-assigned"'), 'Fleet has no assigned-job counter');
must(page.includes('scale-set demand'), 'assigned-job counter is not identified as scale-set demand');
must(page.includes('crfRenderActivity'), 'recent one-shot activity is not rendered');
must(page.includes('Recent one-shot activity'), 'recent activity panel is missing');
must(page.includes("crfDemandValue(p,'assigned_jobs')"), 'pool headers do not preserve unavailable assigned demand');
must(page.includes("crfDemandValue(p,'advertised_capacity')"), 'pool headers do not preserve unavailable capacity');
must(page.includes("r.completed?'completed':'exited'"), 'completed one-shot runners still render as unexplained exits');
must(page.includes("d.schema_version!==2"), 'Fleet accepts unknown snapshot schemas');
must(page.includes('unsupported or malformed Fleet snapshot'), 'malformed snapshots do not preserve last-good UI');
must(page.includes("Scale up to':'Scale to"), 'scale controls do not distinguish autoscale');
must(page.includes('class="orange"'), 'primary scaling control is not visibly orange');
must(page.includes("if(!fleet){") && page.includes("const body=fleet.querySelector('.crf-pool-bays-body')"),
  'pool refresh does not reuse stable pool sections and runner bodies');
must(page.includes('document.activeElement!==scale'), 'scale input is overwritten while typing');
must(page.includes('grid-template-columns:58px minmax(54px,.7fr) minmax(0,1.5fr)'),
  'recent activity has no narrow-view layout');
must(engine.includes('"schema_version":2'), 'engine does not emit typed Fleet schema');
must(engine.includes('"operation":null,"maintenance":%s'), 'inventory fallback omits maintenance state');
must(engine.includes('recent_activity') && engine.includes('STATUS_RECENT_ACTIVITY_JSON'), 'engine omits recent one-shot activity');
must(engine.includes('pcompleted'), 'engine does not distinguish completed one-shot runners from errors');
must(engine.includes('${completed}') && engine.includes('completed'), 'runner schema omits completed lifecycle state');
must(engine.includes('github_phase_refresh'), 'busy/idle state is not batched');

const usage = engine.match(/cmd_usage_refresh\(\) \{([\s\S]*?)\n\}/);
must(usage, 'usage refresh function missing');
must(!/\bdocker\s+exec\b/.test(usage[1]), 'recurring usage refresh execs per runner');
const logReads = usage[1].match(/\bdocker\s+logs\b/g) || [];
must(logReads.length === 1, 'usage refresh must perform one bounded log read path');
must(usage[1].includes('if [ "$phase" = busy ]') && usage[1].includes('docker logs --timestamps --tail 80'),
  'active-job discovery is not limited to a bounded busy-runner log tail');

const ctx = {};
vm.createContext(ctx);
vm.runInContext([
  functionSource('crfDemandValue'),
  functionSource('crfAssignedDemand'),
  functionSource('crfActivityWhen')
].join('\n'), ctx);
const fresh = {pools:[
  {demand_fresh:true, assigned_jobs:2, advertised_capacity:3},
  {demand_fresh:true, assigned_jobs:1, advertised_capacity:2}
]};
must(ctx.crfAssignedDemand(fresh) === 3, 'fresh assigned demand is not summed');
must(ctx.crfAssignedDemand({pools:[fresh.pools[0],{demand_fresh:false,assigned_jobs:-1}]}) === null,
  'unavailable pool demand is coerced into a partial total');
must(ctx.crfDemandValue({demand_fresh:false,assigned_jobs:-1}, 'assigned_jobs') === '—',
  'unavailable pool demand does not render as unknown');
const twoDaysAgo = new Date(Date.now() - (2 * 24 * 60 + 5) * 60000).toISOString();
must(ctx.crfActivityWhen(twoDaysAgo) === '2d ago', 'older recent activity has ambiguous clock-only time');

console.log('fleet-behavior: OK');
