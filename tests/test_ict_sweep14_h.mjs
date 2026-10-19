/** Offline regression checks for Worker H. Run: node tests/test_ict_sweep14_h.mjs */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const es = fs.readFileSync(path.join(root, 'XAU_Worker_SmartExec_E.js'), 'utf8');
const hs = fs.readFileSync(path.join(root, 'XAU_Worker_SmartExec_H.js'), 'utf8');
const from='const BUILD_VERSION = "XAU_V4_ICT_SMC_SMART_EXEC_20261017_E";';
const to='const BUILD_VERSION = "XAU_V4_ICT_SMC_SWEEP14_20261019_H";';
const old='         sweep:sweep(bars,swings),displacement:displacement(bars),';
const altered='         // Keep a confirmed liquidity sweep eligible until a FRESH BOS follows.\n         // BOS recency (4 M5 / 3 M15), event order and all other confirmations stay unchanged.\n         sweep:sweep(bars,swings,(seconds===300||seconds===900)?14:8),\n         displacement:displacement(bars),';
assert.equal(hs.replace(to,from).replace(altered,old),es, 'Strategy guards/market routes must be unchanged');
assert.ok(hs.includes('timeframe==="M5"?4:3'), 'Fresh BOS recency must be preserved');
const load=async s=>import('data:text/javascript;base64,'+Buffer.from(s).toString('base64'));
const e=await load(es), h=await load(hs);
const seed=[];
for(let i=0;i<80;i++)seed.push({o:100,h:i===60?103:i===69?104:101,l:99,c:100});
let count=0;
for(const seconds of [300,900]){
  const raw=seed.map((v,i)=>({...v,t:100000+i*seconds}));
  const now=raw.at(-1).t+seconds+1;
  assert.equal(e.__testICTV4.analyzeTF(raw,now,seconds).sweep,null);
  assert.equal(h.__testICTV4.analyzeTF(raw,now,seconds).sweep.index,69);
  count+=2;
}
for(const seconds of [1800,3600]){
  const raw=seed.map((v,i)=>({...v,t:100000+i*seconds}));
  const now=raw.at(-1).t+seconds+1;
  assert.deepEqual(h.__testICTV4.analyzeTF(raw,now,seconds).sweep,e.__testICTV4.analyzeTF(raw,now,seconds).sweep);
  count++;
}
const snapshot={generated_at:100000+80*3600+1,bid:100,ask:100.11,point:.01};
for(const [tf,seconds] of Object.entries({H1:3600,M30:1800,M15:900,M5:300}))
  snapshot[tf]=seed.map((v,i)=>({...v,t:100000+i*seconds}));
const preview=h.__testICTV4.previewSnapshot(snapshot);
for(const [tf,seconds] of [['M5',300],['M15',900]]){
  assert.equal(h.__testIctV4SidePlan(snapshot,preview,tf,seconds).allowed,false);
  count++;
}
assert.equal(typeof h.__testR2SmartSetupReady,'function');
assert.equal(typeof h.__testIctV4SidePlan,'function');
assert.equal(typeof h.__testSmartR2Audit,'function');
console.log(`PASS: ${count} behavior assertions + exact source regression + mode exports`);
