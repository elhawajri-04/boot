import assert from 'node:assert/strict';
import worker,{__testPendingPlacement} from '../../v4.1/XAU_V4_Worker_v4_1.js';
const q={ask:4201.2,bid:4201.0};
const cases=[
  ['BUY_LIMIT',4200,true],['SELL_LIMIT',4202,true],
  ['BUY_STOP',4202,true],['SELL_STOP',4200,true],
  ['BUY_LIMIT',4202,false],['SELL_LIMIT',4200,false],
  ['BUY_STOP',4200,false],['SELL_STOP',4202,false],
  ['BUY',4201,false],['SELL',4201,false],
];
for(const [t,p,yes] of cases){const ret=__testPendingPlacement(t,p,q);assert.equal(ret.allowed,yes,`${t} @${p}: ${JSON.stringify(ret)}`);}
const health=await worker.fetch(new Request('https://worker.invalid/health'),{});
const body=await health.json();
assert.equal(health.status,200);assert.equal(body.r2_pending_only_mode,true);
assert.equal(body.r2_market_execution_enabled,false);
console.log(`PASS ${cases.length} R2 order-direction/price tests + 2 health protocol checks`);