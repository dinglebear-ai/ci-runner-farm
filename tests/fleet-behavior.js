'use strict';
const fs = require('fs');
const page = fs.readFileSync('src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmFleet.page', 'utf8');
const engine = fs.readFileSync('src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh', 'utf8');

function must(condition, message) { if (!condition) throw new Error(message); }
must(page.includes('Tracked repository run queue'), 'queue tile is not accurately named');
must(page.includes('not pool demand'), 'queue tile lacks its demand limitation');
must(page.includes("d.schema_version!==2"), 'Fleet accepts unknown snapshot schemas');
must(page.includes('unsupported or malformed Fleet snapshot'), 'malformed snapshots do not preserve last-good UI');
must(page.includes("Scale up to':'Scale to"), 'scale controls do not distinguish autoscale');
must(page.includes('class="orange"'), 'primary scaling control is not visibly orange');
must(page.includes('openPools'), 'pool disclosure state is lost on refresh');
must(page.includes('document.activeElement!==scale'), 'scale input is overwritten while typing');
must(engine.includes('"schema_version":2'), 'engine does not emit typed Fleet schema');
must(engine.includes('github_phase_refresh'), 'busy/idle state is not batched');
const usage = engine.match(/cmd_usage_refresh\(\) \{([\s\S]*?)\n\}/);
must(usage, 'usage refresh function missing');
must(!/\bdocker\s+exec\b/.test(usage[1]), 'recurring usage refresh execs per runner');
must(!/\bdocker\s+logs\b/.test(usage[1]), 'recurring usage refresh reads per-runner logs');
console.log('fleet-behavior: OK');
