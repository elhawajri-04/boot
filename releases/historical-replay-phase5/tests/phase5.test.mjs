import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {originalWorker,quoteIsValid,cancellationReason,candidateAdmission,examineRetest} from '../scripts/phase5_replay.mjs';
import {buildCommands} from '../scripts/export_causal_commands.mjs';
const home=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const ea=fs.readFileSync(path.join(home,'mt5','XAU_Phase5_Research_Tester.mq5'),'utf8');
const repoWorker=path.resolve(home,'../v4.1/XAU_V4_Worker_v4_1.js');
const worker=process.env.XAU_WORKER||(fs.existsSync(repoWorker)?repoWorker:path.resolve(home,'../../XAU_V4_Worker_v4_1.js'));


test('original Worker identity and only validated latest-pivot fix',()=>{
 const o=originalWorker(worker);
 assert.equal(o.worker_sha256,'6d6a7716288a5fb835608ec224f1ef7bd1b6273b7154c98e436289fbe65a8179');
 assert.equal(o.adapter_sha256,'78589c92d37969ca31c33fdf023cf7f60576c2e06f2d8232c9b933f43c4a6617');
});
test('MIXED HTF cannot cancel pending setup, regardless of prior state',()=>{
 const e={side:'BUY',expiry_time:2000,invalidation:100,oppositeCount:0};
 assert.equal(cancellationReason(e,'MIXED',{c:101},1000),'');
 assert.equal(cancellationReason(e,'MIXED',{c:101},1300),'');
 assert.equal(e.oppositeCount,0);
});
test('opposite HTF requires two fresh decisions, opposite counter resets on MATCHED or MIXED',()=>{
 const e={side:'BUY',expiry_time:2000,invalidation:100,oppositeCount:0};
 assert.equal(cancellationReason(e,'SELL',{c:101},1000),'');
 assert.equal(cancellationReason(e,'BUY',{c:101},1300),'');
 assert.equal(cancellationReason(e,'SELL',{c:101},1400),'');
 assert.equal(cancellationReason(e,'SELL',{c:101},1700),'OPPOSITE_HTF_CONFIRMED');
});
test('structural invalidation and hard expiry retain precedence, including MIXED',()=>{
 const e={side:'BUY',expiry_time:1500,invalidation:100,oppositeCount:0};
 assert.equal(cancellationReason(e,'MIXED',{c:99},1000),'STRUCTURAL_INVALIDATION_CLOSE');
 assert.equal(cancellationReason(e,'MIXED',null,1500),'EXPIRED');
});
test('parallel candidate admission retains distinct zones under a cap',()=>{
 const a={side:'BUY',retest_low:100,retest_high:105};
 const b={side:'BUY',retest_low:110,retest_high:115};
 const c={side:'BUY',retest_low:120,retest_high:125};
 const dup={side:'BUY',retest_low:101,retest_high:104};
 assert.equal(candidateAdmission([a],b,3),'');
 assert.equal(candidateAdmission([a,b],c,3),'');
 assert.equal(candidateAdmission([a,b,c],{side:'SELL',retest_low:140,retest_high:145},3),'CANDIDATE_CAPACITY');
 assert.equal(candidateAdmission([a],dup,3),'OVERLAPPING_ZONE');
});
test('retouch is never considered a fill on event creation or absent in-band quote',()=>{
 const e={armed:true,event_time:500,retest_low:100,retest_high:105,side:'BUY'};
 assert.equal(examineRetest(e,{bid:103,ask:104},500),'WAIT');
 assert.equal(examineRetest(e,{bid:99,ask:99.5},502),'GAP_ACROSS_ZONE_UNVERIFIED');
 assert.equal(examineRetest(e,{bid:102,ask:102.5},502),'OBSERVED_ZONE_TOUCH');
});
test('historical future quote and stale quote blocked',()=>{
 assert.equal(quoteIsValid({bid:100,ask:100.2,t:1000001},1000,30000),false);
 assert.equal(quoteIsValid({bid:100,ask:100.2,t:900000},1000,30000),false);
});
test('January/February research commands exactly regenerated from phase 5 events',()=>{
 for(const prefix of ['jan','feb']){
  const events=fs.readFileSync(path.join(home,'results',prefix+'_events.csv'),'utf8');
  const commands=fs.readFileSync(path.join(home,'results',prefix+'_commands.csv'),'utf8');
  assert.equal(buildCommands(events),commands);
  assert.ok(commands.includes(',ARM,'));
  assert.ok(!commands.includes('outcome_bid')&&!commands.includes('OBSERVED_ZONE_TOUCH'));
  const armIds=commands.split('\n').filter(x=>x.includes(',ARM,')).map(x=>x.split(',')[2]);
  assert.equal(armIds.length,new Set(armIds).size);
  assert.ok(armIds.every(id=>prefix==='jan'?id.includes('1767'):id.includes('1770')));
 }
});
test('strict week-selected unique command files, no manual rename/stale run',()=>{
 assert.match(ea,/#property tester_file "phase5_jan_commands.csv"/);
 assert.match(ea,/#property tester_file "phase5_feb_commands.csv"/);
 assert.match(ea,/InpResearchPeriod = P5_JAN_2026/);
 assert.match(ea,/command timestamp belongs to wrong week/);
 assert.match(ea,/selected period does not match Strategy Tester dates/);
});
test('EA remains tester-only, fail closed news, verified risk/stop gates',()=>{
 assert.match(ea,/if\(!MQLInfoInteger\(MQL_TESTER\)\)/);
 assert.match(ea,/InpResearchAllowUnverifiedNews = false/);
 assert.match(ea,/!newsReady&&!InpResearchAllowUnverifiedNews/);
 assert.match(ea,/NearestM5Swing\(/);
 assert.match(ea,/ATRClosed\(atr5\)/);
 assert.match(ea,/ExistingRiskMoney\(/);
 assert.match(ea,/OrderCalcProfit/);
 assert.match(ea,/OrderCalcMargin/);
 assert.match(ea,/MinimumStopsPoints\(/);
});
test('R2 strictly pending limits; cancellation requires broker acknowledgement',()=>{
 const code=ea.slice(ea.indexOf('void ProcessArm('),ea.indexOf('void RunCommands('));
 assert.match(code,/trade\.BuyLimit\(/);assert.match(code,/trade\.SellLimit\(/);
 assert.doesNotMatch(code,/trade\.Buy\(/);assert.doesNotMatch(code,/trade\.Sell\(/);
 assert.match(ea,/if\(ok && trade\.ResultRetcode\(\)==TRADE_RETCODE_DONE\)/);
 assert.match(ea,/InpCancelRetrySeconds = 120/);
});
test('EA holds multiple independent slots; cancellation matches event id not engine',()=>{
 assert.match(ea,/Active r1\[3\],r2\[3\]/);
 assert.match(ea,/r1\[i\]\.id==c\.id/);
 assert.match(ea,/r2\[i\]\.id==c\.id/);
 assert.doesNotMatch(ea,/CancelState\(r1,"SUPERSEDED"/);
 assert.doesNotMatch(ea,/CancelState\(r2,"SUPERSEDED"/);
});
test('R1 retest then causally confirmed CLOSED M1 rejection; no future-bar leakage',()=>{
 assert.match(ea,/a\.touched=true;a\.touchTime=now/);
 assert.match(ea,/CopyRates\(_Symbol,PERIOD_M1,1,1,m1\)/);
 assert.match(ea,/if\(closeTime<=a\.touchTime\)return/);
 assert.match(ea,/InpR1MaxConfirmSeconds/);
 assert.match(ea,/InpR1EntryMaxDistancePoints/);
 assert.match(ea,/InpR1ConfirmationMode = P5_M1_REJECTION/);
});
test('calendar ranges and chronological streams in both weeks',()=>{
 const fs2=requireFailSafe();
 for(const p of ['jan','feb']){
  const text=fs2.readFileSync(path.join(home,'results',p+'_commands.csv'),'utf8');
  const times=text.trim().split('\n').slice(1).map(x=>+x.split(',')[0]);
  assert.ok(times.every(Number.isInteger));
  assert.deepEqual([...times].sort((a,b)=>a-b),times);
 }
 function requireFailSafe(){return fs;}
});