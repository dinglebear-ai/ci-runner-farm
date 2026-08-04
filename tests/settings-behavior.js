'use strict';
const fs = require('fs');
const page = fs.readFileSync('src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmSettings.page', 'utf8');
const pools = fs.readFileSync('src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmPools.page', 'utf8');

function must(condition, message) {
  if (!condition) throw new Error(message);
}

must(pools.includes("Object.freeze(['id','routing_label','additional_labels','fixed','min','max','idle','cpus','memory'])"),
  'pool serializer has no fixed field allowlist');
must(pools.includes("row.remove();crfValidatePools(false)"), 'removed draft rows can remain in runtime serialization');
must(pools.includes("input.dataset.poolField=field"), 'pool inputs are positional');
must(pools.includes("if(field==='id'&&saved) input.readOnly=true"), 'saved IDs remain editable');
must(pools.includes('Duplicate as new pool'), 'immutable-ID duplicate workflow is absent');
must(pools.includes('aria-label="Copy selector"'), 'selector action is not accessibly named');
must(page.includes("crfSettingsForm.dataset.applying==='1'"), 'Apply is not single-flight');
must(page.includes("setAttribute('aria-busy','true')"), 'Apply does not expose busy state');
must(page.includes('const epoch=++applyEpoch'), 'Apply has no response epoch');
must(page.includes('expected_config_revision:CRF_CONFIG_REVISION'), 'Apply has no optimistic concurrency');
must(!page.includes('crfSettingsForm.submit()'), 'native form submission bypass remains');
must(!page.includes('/update.php'), 'native update endpoint remains');

console.log('settings-behavior: OK');
