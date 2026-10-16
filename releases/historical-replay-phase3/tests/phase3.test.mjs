import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {confirmEvent,quoteIsValid,armEvent,examineRetest,cancellationReason,originalWorker,readMeta} from '../scripts/phase3_replay.mjs';
const phaseDir=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const gitWorker=path.resolve(phaseDir,'../v4.1/XAU_V4_Worker_v4_1.js');
const worker=fs.existsSync(gitWorker)?gitWorker:path.resolve(phaseDir,'../XAU_V4_Worker_v4_1.js');
const analysis=(side='BUY',zone={low:99,high:101,distal:99},eq=100.5)=>({
 ready:true,bars:Array.from({length:60},(_,i)=>({t:300*i,o:99.8,h:102,l:98,c:100})),
 sweep:{direction:side,index:50,t:15000},displacement:{direction:side,index:55,t:16500},
 break:{direction:side,t:17700},value:{equilibrium:eq},zone
});
const original={fvg:(_b,_s)=>original.zone,orderBlock:()=>null,zone:{low:99,high:101,distal:99}};
const clock=18300;
test('loads exact pinned ICTV4 adapter without recoding',()=>{
 const r=originalWorker(worker);assert.equal(r.worker_sha256,'6d6a7716288a5fb835608ec224f1ef7bd1b6273b7154c98e436289fbe65a8179');
 assert.equal(typeof r.api.ict.previewSnapshot,'function');
});
test('an event needs sweep, later displacement, BOS and correct HTF side',()=>{
 const base=analysis();assert.ok(confirmEvent(original,base,'BUY','R1',clock));
 assert.equal(confirmEvent(original,base,'MIXED','R1',clock),null);
 const a=analysis();a.displacement.index=49;assert.equal(confirmEvent(original,a,'BUY','R1',clock),null);
 const b=analysis();b.break.direction='SELL';assert.equal(confirmEvent(original,b,'BUY','R1',clock),null);
});
test('the discount/premium intersection, not breakout close, is retained',()=>{
 let e=confirmEvent(original,analysis('BUY'), 'BUY','R1',clock);
 assert.equal(e.retest_low,99);assert.equal(e.retest_high,100.5);
 e=confirmEvent(original,analysis('SELL',undefined,99.7),'SELL','R2',clock);
 assert.equal(e.retest_low,99.7);assert.equal(e.retest_high,101);
 assert.equal(e.placement_type,'SELL_LIMIT');
});
test('zone completely outside value half is untradable, not a fabricated fill',()=>{
 let e=confirmEvent(original,analysis('BUY',undefined,95),'BUY','R1',clock);
 assert.equal(e.valid_overlap,false);
 assert.equal(armEvent(e,{t:clock*1000,bid:104,ask:104.1},clock,0),false);
 assert.equal(e.outcome,'NO_VALUE_ZONE_OVERLAP');
});
test('missing/stale/future quotes are rejected before arming',()=>{
 assert.equal(quoteIsValid(null,clock,30000),false);
 assert.equal(quoteIsValid({t:(clock+1)*1000,bid:102,ask:102.2},clock,30000),false);
 assert.equal(quoteIsValid({t:(clock-31)*1000,bid:102,ask:102.2},clock,30000),false);
 assert.equal(quoteIsValid({t:clock*1000-100,bid:102,ask:102.2},clock,30000),true);
});
test('BUY_LIMIT candidate must begin above the zone, SELL_LIMIT below',()=>{
 const a=confirmEvent(original,analysis(),'BUY','R2',clock);
 assert.equal(armEvent(a,{bid:100.2,ask:100.3,t:clock*1000},clock,0),false);
 const b=confirmEvent(original,analysis(),'BUY','R2',clock);
 assert.equal(armEvent(b,{bid:102,ask:102.2,t:clock*1000},clock,0),true);
 const c=confirmEvent(original,analysis('SELL'),'SELL','R2',clock);
 assert.equal(armEvent(c,{bid:98,ask:98.2,t:clock*1000},clock,0),true);
});
test('same-clock cannot claim retest, subsequent valid tick can',()=>{
 const e=confirmEvent(original,analysis(),'BUY','R2',clock);
 assert.equal(armEvent(e,{bid:102,ask:102.2,t:clock*1000},clock,0),true);
 assert.equal(examineRetest(e,{bid:100,ask:100.1},clock),'WAIT');
 assert.equal(examineRetest(e,{bid:100,ask:100.1},clock+1),'OBSERVED_ZONE_TOUCH');
});
test('a gap beneath zone is not counted as a guaranteed fill',()=>{
 const e=confirmEvent(original,analysis(),'BUY','R2',clock);
 armEvent(e,{bid:102,ask:102.2,t:clock*1000},clock,0);
 assert.equal(examineRetest(e,{bid:96,ask:96.1},clock+1),'GAP_ACROSS_ZONE_UNVERIFIED');
});
test('expiry, HTF flip and completed-bar structure invalidate pending state',()=>{
 const e=confirmEvent(original,analysis(),'BUY','R2',clock);
 assert.equal(cancellationReason(e,'BUY',{c:100},clock+1000),'');
 assert.equal(cancellationReason(e,'MIXED',null,clock+2000),'HTF_CHANGED_OR_MIXED');
 assert.equal(cancellationReason(e,'BUY',{c:98},clock+2000),'STRUCTURAL_INVALIDATION_CLOSE');
 assert.equal(cancellationReason(e,'BUY',null,e.expiry_time),'EXPIRED');
});
test('R1 expires after 1h, R2 after 6h, with different event ids',()=>{
 const a=confirmEvent(original,analysis(),'BUY','R1',clock);
 const b=confirmEvent(original,analysis(),'BUY','R2',clock);
 assert.equal(a.expiry_time-clock,3600);assert.equal(b.expiry_time-clock,21600);
 assert.notEqual(a.event_id,b.event_id);
});
test('metadata must be complete with real ticks',()=>{
 const dir=fs.mkdtempSync(path.join(import.meta.dirname,'meta-test-'));
 const fixtureMeta=path.join(dir,'meta.csv');
 try {
  fs.writeFileSync(fixtureMeta,'key,value\nformat_version,1\nsymbol,XAUUSD.s\npoint,0.01\nstart_server_unix,1767657600\nend_server_unix_exclusive,1768262400\nticks_exported,true\nexport_status,OK\n');
  const {m}=readMeta(fixtureMeta);assert.equal(m.symbol,'XAUUSD.s');
  fs.writeFileSync(fixtureMeta,fs.readFileSync(fixtureMeta,'utf8').replace('export_status,OK','export_status,INCOMPLETE'));
  assert.throws(()=>readMeta(fixtureMeta),/COMPLETE/);
 } finally {fs.rmSync(dir,{recursive:true,force:true});}
});

test('causal command conversion does not leak future outcome quote/time on ARM',async()=>{
 const {buildCommands}=await import('../scripts/export_causal_commands.mjs');
 const events=fs.readFileSync(path.resolve(phaseDir,'results/jan_2026_events.csv'),'utf8');
 const cmds=buildCommands(events).trim().split('\n');
 assert.equal(cmds.length,5);
 const r=cmds.map(x=>x.split(','));
 assert.equal(r[1][1],'ARM');assert.equal(r[2][1],'CANCEL');
 assert.equal(r[1][13],'CONFIRMED_SMC_EVENT');
 assert.equal(r[2][13],'HTF_CHANGED_OR_MIXED');
 assert.equal(Number(r[2][0])>Number(r[1][0]),true);
 assert.ok(!cmds.some(x=>x.includes('OBSERVED_ZONE_TOUCH')));
 assert.ok(!cmds.some(x=>x.includes('outcome_bid')));
});
test('command generator rejects duplicate event ids',async()=>{
 const {buildCommands}=await import('../scripts/export_causal_commands.mjs');
 const lines=fs.readFileSync(path.resolve(phaseDir,'results/jan_2026_events.csv'),'utf8').trim().split('\n');
 assert.throws(()=>buildCommands(lines[0]+'\n'+lines[1]+'\n'+lines[1]+'\n'),/duplicate event/);
});
test('no trading APIs or network calls in Phase3 research replay',()=>{
 const code=fs.readFileSync(path.resolve(phaseDir,'scripts/phase3_replay.mjs'),'utf8');
 for(const forbidden of ['CTrade','OrderSend(','WebRequest(','fetch(','TradeRequest(','TRADE_ACTION_DEAL'])assert.equal(code.includes(forbidden),false,forbidden);
});