import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {originalWorker,confirmEvent,armEvent,quoteIsValid,cancellationReason} from '../scripts/phase4_replay.mjs';
import {buildCommands} from '../scripts/export_causal_commands.mjs';
const home=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const repoWorker=path.resolve(home,'../v4.1/XAU_V4_Worker_v4_1.js');
const worker=fs.existsSync(repoWorker)?repoWorker:path.resolve(home,'../XAU_V4_Worker_v4_1.js');
const ea=fs.readFileSync(path.join(home,'mt5/XAU_Phase4_Research_Tester.mq5'),'utf8');
const gate=originalWorker(worker);
test('locked original Worker identity; only two exact n-3 pivot gates patched',()=>{
 assert.equal(gate.worker_sha256,'6d6a7716288a5fb835608ec224f1ef7bd1b6273b7154c98e436289fbe65a8179');
 assert.equal(gate.original_adapter_sha256,'b0b73e69470de5bf40313280a70293532c68276bdcdaf563f56646f15b103571');
 assert.equal(gate.adapter_sha256,'78589c92d37969ca31c33fdf023cf7f60576c2e06f2d8232c9b933f43c4a6617');
});
test('newest confirmed pivot n-3 is eligible, older pivot does not spoof BOS',()=>{
 const n=10, lows=[96,95,94,93,94,95,96,97,96,97];
 const bars=Array.from({length:n},(_,i)=>({t:i*300,o:97.0,h:97,l:lows[i],c:97.0}));
 // latest swing high at n-3 (index 7) is 105, an older swing at index 4 has high=101.
 for(let i=0;i<bars.length;i++)bars[i].h=i===7?105:i===4?101:99;
 // last closed bar 9 finishes at 103, below newest 105; earlier break of 101 is NOT sufficient.
 bars[8].c=100;bars[9].c=103;bars[9].h=104;
 // construct direct swing input to isolate breakOfStructure, extraction from patched ICTV4 adapter.
 const s=fs.readFileSync(worker,'utf8'),start=s.indexOf('const ICTV4 = (()=>{'),end=s.indexOf('// ======= End ICT/SMC v4 adapter =======',start);
 const raw=s.slice(start,end);
 const orig=raw.match(/function breakOfStructure\(bars,swings,bias\)\{[\s\S]*?\n\}/)?.[0];
 assert.ok(orig,'source function not found');
 const fixed=orig.replaceAll('x.index<n-3','x.index<=n-3');
 const swings={highs:[{index:4,price:101},{index:7,price:105}],lows:[]};
 const patched=vm.runInNewContext(fixed+'\n breakOfStructure(bars,swings,"BUY")',{bars,swings});
 const broken=vm.runInNewContext(orig+'\n breakOfStructure(bars,swings,"BUY")',{bars,swings});
 assert.equal(broken.direction,'BUY');assert.equal(patched,null);
 bars[9].h=106;bars[9].c=106;
 const corrected=vm.runInNewContext(fixed+'\n breakOfStructure(bars,swings,"BUY")',{bars,swings});
 assert.equal(corrected.direction,'BUY');assert.equal(corrected.level,105);
});
test('Phase 4 phase3-style event is frozen, has expiry and not a fill',()=>{
 const a={ready:true,bars:Array.from({length:60},(_,i)=>({t:i*300,o:101,h:102,l:100,c:101})),sweep:{direction:'BUY',index:50},displacement:{direction:'BUY',index:55},break:{direction:'BUY'},value:{equilibrium:101}};
 const fake={fvg:()=>({low:100,high:102,distal:100}),orderBlock:()=>null};
 const e=confirmEvent(fake,a,'BUY','R2',18000,0.01);assert.ok(e);
 assert.equal(e.expiry_time,39600);assert.equal(e.placement_type,'BUY_LIMIT');
 assert.equal(armEvent(e,{bid:103,ask:103.2,t:18000000},18000,0),true);
 assert.equal(e.outcome,'');assert.equal(cancellationReason(e,'MIXED',null,18100),'HTF_CHANGED_OR_MIXED');
});
test('quote freshness disallows future and stale ticks',()=>{
 assert.equal(quoteIsValid({bid:101,ask:101.2,t:20001000},20000,30000),false);
 assert.equal(quoteIsValid({bid:101,ask:101.2,t:19960000},20000,30000),false);
});
test('January and February commands contain both ARM and causal CANCEL without outcomes',()=>{
 for(const month of ['jan','feb']){
  const events=fs.readFileSync(path.join(home,'results',month+'_events.csv'),'utf8');
  const commands=buildCommands(events);
  assert.equal(commands,fs.readFileSync(path.join(home,'results',month+'_commands.csv'),'utf8'));
  assert.ok(!commands.includes('outcome_bid')&&!commands.includes('OBSERVED_ZONE_TOUCH'));
  assert.ok(commands.includes(',ARM,')&&commands.includes(',CANCEL,'));
 }
});
test('EA cannot operate on live or demo charts, reads exact tester_file',()=>{
 assert.match(ea,/if\(!MQLInfoInteger\(MQL_TESTER\)\)/);
 assert.match(ea,/#property tester_file "phase4_commands.csv"/);
 assert.match(ea,/#property tester_file "phase4_news_clear.csv"/);
});
test('EA enforces R2 pending-only, R1 local M5 swing ATR, new order risk and margin',()=>{
 const t=ea.slice(ea.indexOf('void ProcessArm('),ea.indexOf('void RunCommands('));
 assert.match(t,/trade\.BuyLimit\(/);assert.match(t,/trade\.SellLimit\(/);
 assert.doesNotMatch(t,/trade\.Buy\(/);assert.doesNotMatch(t,/trade\.Sell\(/);
 assert.match(ea,/NearestM5Swing\(/);assert.match(ea,/ATRClosed\(atr5\)/);
 assert.match(ea,/OrderCalcProfit/);assert.match(ea,/OrderCalcMargin/);assert.match(ea,/ExistingRiskMoney\(/);
});
test('fail-closed historical news until explicitly labelled unverified-research override',()=>{
 assert.match(ea,/InpResearchAllowUnverifiedNews = false/);
 assert.match(ea,/!newsReady&&!InpResearchAllowUnverifiedNews/);
 assert.match(ea,/NEWS: no historical news clearance/);
});
test('causal orders and no premature cancellation or phantom deletion',()=>{
 assert.match(ea,/cmds\[nextCommand\]\.at<=now/);
 assert.match(ea,/CANCEL_ALREADY_DUE/);
 assert.match(ea,/rc!=TRADE_RETCODE_PLACED&&rc!=TRADE_RETCODE_DONE/);
 assert.match(ea,/TRADE_RETCODE_DONE\)\{Trace\(a.engine,a.id,"CANCEL_OK"/);
 assert.match(ea,/InpCancelRetrySeconds = 120/);
});