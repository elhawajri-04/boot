import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {runReplay} from '../scripts/worker_replay.mjs';

const HERE=path.dirname(fileURLToPath(import.meta.url));
const WORKER=[path.resolve(HERE,'../../v4.1/XAU_V4_Worker_v4_1.js'),
              path.resolve(HERE,'../../XAU_V4_Worker_v4_1.js')].find(fs.existsSync)
              || path.resolve(HERE,'../../v4.1/XAU_V4_Worker_v4_1.js');
const DURATIONS={M1:60,M5:300,M15:900,M30:1800,H1:3600};
const EPOCH=Math.floor(Date.UTC(2025,0,1,0,0,0)/1000);
const START=EPOCH+90*3600;
const END=START+4*3600;
function prep(dir, prefix='test'){
 for(const [tf,sec] of Object.entries(DURATIONS)){
  const rows=['t,o,h,l,c,tick_volume,spread_points,real_volume'];
  for(let t=EPOCH;t<END;t+=sec){
   const v=4160+(t-EPOCH)/3600*.05+Math.sin((t-EPOCH)/14400)*.8;
   rows.push([t,v.toFixed(2),(v+.2).toFixed(2),(v-.2).toFixed(2),(v+.03).toFixed(2),15,20,0].join(','));
  }
  fs.writeFileSync(path.join(dir,`${prefix}_${tf}.csv`),rows.join('\n')+'\n');
 }
 const ticks=['time_msc,bid,ask,flags'];
 for(let t=START-1;t<END;t+=300){
  const b=4170+(t-START)*.0001;
  ticks.push([t*1000,b.toFixed(2),(b+.18).toFixed(2),3].join(','));
 }
 fs.writeFileSync(path.join(dir,`${prefix}_ticks.csv`),ticks.join('\n')+'\n');
 fs.writeFileSync(path.join(dir,`${prefix}_meta.csv`),[
  'key,value','format_version,1','symbol,XAUUSD.s','point,0.01',
  `start_server_unix,${START}`,`end_server_unix_exclusive,${END}`,
  'ticks_exported,true','export_status,OK'].join('\n')+'\n');
}
function sandbox(){return fs.mkdtempSync(path.join(os.tmpdir(),'xau-replay-'));}
function opts(dir,worker=WORKER){return {dir,prefix:'test',worker,out:path.join(dir,'signals.csv'),'max-events':'3'};}

test('Worker adapter is reused, emits R1/R2 research rows and never executable signals',async()=>{
 const dir=sandbox();try{
  assert.ok(fs.existsSync(WORKER),'Worker source fixture missing');
  prep(dir);
  const summary=await runReplay(opts(dir));
  assert.equal(summary.counts.events,3);
  assert.equal(summary.counts.quotes_stale,0);
  assert.equal(summary.execution_eligible_always_false,true);
  const lines=fs.readFileSync(path.join(dir,'signals.csv'),'utf8').trim().split('\n');
  assert.equal(lines.length,7);
  for(const line of lines.slice(1)){
   const fields=line.split(',');
   assert.ok(['R1','R2'].includes(fields[1]));
   assert.equal(fields.at(-1),'0');
   if(fields[1]==='R2' && fields[3]==='1') assert.ok(fields[6].includes('LIMIT')||fields[6].includes('STOP'));
  }
  assert.ok(summary.worker_sha256.length===64);
 }finally{fs.rmSync(dir,{recursive:true,force:true});}
});

test('Future candles cannot alter earlier replay results',async()=>{
 const dir=sandbox();try{
  prep(dir);
  const a=await runReplay(opts(dir));
  const before=fs.readFileSync(path.join(dir,'signals.csv'),'utf8');
  const f=path.join(dir,'test_H1.csv');
  const futureTime=END+3600;
  fs.appendFileSync(f,`${futureTime},9000,9001,8999,9000,1,10,0\n`);
  const b=await runReplay({...opts(dir),out:path.join(dir,'later.csv')});
  const after=fs.readFileSync(path.join(dir,'later.csv'),'utf8');
  assert.equal(before,after);
  assert.equal(a.counts.events,b.counts.events);
 }finally{fs.rmSync(dir,{recursive:true,force:true});}
});

test('Missing fresh quotes must never be filled with OHLC close',async()=>{
 const dir=sandbox();try{
  prep(dir);
  fs.writeFileSync(path.join(dir,'test_ticks.csv'),'time_msc,bid,ask,flags\n');
  const s=await runReplay(opts(dir));
  assert.equal(s.counts.quotes_stale,3);
  assert.equal(s.counts.r1_raw_signals,0);
  assert.equal(s.counts.r2_raw_signals,0);
  assert.ok(fs.readFileSync(path.join(dir,'signals.csv'),'utf8').includes('NO_FRESH_BID_ASK'));
 }finally{fs.rmSync(dir,{recursive:true,force:true});}
});

test('Incomplete exports are rejected, not backtested as profitable',async()=>{
 const dir=sandbox();try{
  prep(dir);
  const p=path.join(dir,'test_meta.csv');
  fs.writeFileSync(p,fs.readFileSync(p,'utf8').replace('export_status,OK','export_status,INCOMPLETE'));
  await assert.rejects(runReplay(opts(dir)),/COMPLETE/);
 }finally{fs.rmSync(dir,{recursive:true,force:true});}
});