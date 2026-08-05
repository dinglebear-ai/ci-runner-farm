'use strict';
const fs=require('fs');
const vm=require('vm');
const page=process.argv[2];
const src=fs.readFileSync(page,'utf8');
function fail(message){throw new Error(message);}
function declaration(name){
  const marker='function '+name+'(';
  const start=src.indexOf(marker);if(start<0)fail(name+' is missing');
  const brace=src.indexOf('{',start);let depth=0,quote='',escaped=false;
  for(let i=brace;i<src.length;i++){
    const ch=src[i];
    if(quote){if(escaped)escaped=false;else if(ch==='\\')escaped=true;else if(ch===quote)quote='';continue;}
    if(ch==='\"'||ch==="'"||ch==='`'){quote=ch;continue;}
    if(ch==='{')depth++;else if(ch==='}'&&--depth===0)return src.slice(start,i+1);
  }
  fail(name+' is unterminated');
}
const constants=['CRF_POOL_ID','CRF_POOL_LABEL','CRF_POOL_ROUTING_RESERVED'].map(name=>{
  const match=src.match(new RegExp('const '+name+'=.*?;'));
  if(!match)fail(name+' is missing');return match[0];
}).join('\n');
const functions=['crfPoolRoutingReserved','crfPoolAdditionalReserved','crfPoolCpuMilli','crfPoolMemoryBytes'].map(declaration).join('\n');
const ctx={};vm.createContext(ctx);vm.runInContext(constants+'\n'+functions,ctx);
const eq=(actual,expected,message)=>{if(actual!==expected)fail(message+': '+String(actual)+' !== '+String(expected));};
eq(ctx.crfPoolCpuMilli('0.001'),1,'minimum CPU');
eq(ctx.crfPoolCpuMilli('256'),256000,'maximum CPU');
if(!Number.isNaN(ctx.crfPoolCpuMilli('0')))fail('zero CPU accepted');
if(!Number.isNaN(ctx.crfPoolCpuMilli('256.001')))fail('oversized CPU accepted');
if(!Number.isNaN(ctx.crfPoolCpuMilli('999999999999999999')))fail('overflowing CPU accepted');
eq(ctx.crfPoolCpuMilli('inherit'),null,'CPU inherit');
eq(ctx.crfPoolMemoryBytes('6 MiB'),6291456n,'minimum memory');
eq(ctx.crfPoolMemoryBytes('1 TiB'),1099511627776n,'maximum memory');
eq(ctx.crfPoolMemoryBytes('inherit'),null,'memory inherit');
eq(ctx.crfPoolMemoryBytes('5m'),null,'undersized memory');
eq(ctx.crfPoolMemoryBytes('2t'),null,'oversized memory');
eq(ctx.crfPoolMemoryBytes('1.5g'),null,'fractional memory');
if(!ctx.crfPoolAdditionalReserved('ci-pool-rust'))fail('derived routing label accepted as additional label');
if(ctx.crfPoolRoutingReserved('ci-pool-rust'))fail('derived routing label rejected for routing');
for(const required of [
  "'ci-pool-'+original[0]",
  "autoscale:settings.AUTOSCALE",
  "backend:settings.POOL_BACKEND",
  "runner_cpus:settings.RUNNER_CPUS",
  "runner_memory:settings.RUNNER_MEMORY",
  "crfPoolAdditionalReserved(label)",
  "routeCounts.get(route)",
  "backend==='classic'&&max==='auto'"
])if(!src.includes(required))fail('pool editor contract missing: '+required);
if(src.includes('Combined fixed capacity exceeds')||src.includes('Combined numeric maximums exceed'))fail('V2 UI still applies legacy aggregate capacity caps');
console.log('pool-ui-behavior: OK');
