import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {runTickReplay,loadAdapter} from '../scripts/worker_replay_tick.mjs';
const dirHere=path.dirname(fileURLToPath(import.meta.url));
const worker=[path.resolve(dirHere,'../../v4.1/XAU_V4_Worker_v4_1.js'),path.resolve(dirHere,'../../XAU_V4_Worker_v4_1.js')].find(fs.existsSync) || path.resolve(dirHere,'../../v4.1/XAU_V4_Worker_v4_1.js');
const DUR={M1:60,M5:300,M15:900,M30:1800,H1:3600};
const EPOCH=Math.floor(Date.UTC(2026,0,1)/1000),START=EPOCH+90*3600,END=START+900;
function prepare(dir){
 for(const [tf,d] of Object.entries(DUR)){
  const lines=['t,o,h,l,c,tick_volume,spread_points,real_volume'];
  for(let t=EPOCH;t<=END;t+=d){
   const p=4000+Math.sin((t-EPOCH)/1500)*2+(t-EPOCH)/100000;
   lines.push([t,p.toFixed(2),(p+1).toFixed(2),(p-1).toFixed(2),(p+.1).toFixed(2),123,11,0].join(','));
  }
  fs.writeFileSync(path.join(dir,'demo_'+tf+'.csv'),lines.join('\n')+'\n');
 }
 const ticks=['time_msc,bid,ask,flags'];
 for(let t=START;t<END;t+=1)ticks.push([t*1000+1,4100+(t-START)*.0001,4100.11+(t-START)*.0001,230].join(','));
 fs.writeFileSync(path.join(dir,'demo_ticks.csv'),ticks.join('\n')+'\n');
 fs.writeFileSync(path.join(dir,'demo_meta.csv'),['key,value','format_version,1','symbol,XAUUSD.s','point,0.01',`start_server_unix,${START}`,`end_server_unix_exclusive,${END}`,'export_status,OK','ticks_exported,true'].join('\n')+'\n');
}
async function run(dir,extra={}){return runTickReplay({dir,worker,prefix:'demo',out:path.join(dir,'out.csv'),...extra});}
async function fixture(callback){const dir=fs.mkdtempSync(path.join(os.tmpdir(),'xau-phase2-'));try{prepare(dir);await callback(dir);}finally{fs.rmSync(dir,{recursive:true,force:true});}}
test('load ORIGINAL Worker source adapter, not an approximation',()=>{
 const result=loadAdapter(worker);
 assert.match(result.source_sha256,/^[a-f0-9]{64}$/);
 assert.match(result.adapter_sha256,/^[a-f0-9]{64}$/);
 assert.equal(typeof result.api.preview,'function');
});
test('1-second replay consumes quote timestamps and never grants execution',async()=>fixture(async dir=>{
 const s=await run(dir,{ 'max-events':'300'});
 assert.equal(s.counts.sampled_seconds,300);
 assert.equal(s.counts.quote_time_from_future,0);
 assert.equal(s.no_orders_sent,true);
 assert.equal(s.execution_eligible_always_false,true);
 const lines=fs.readFileSync(path.join(dir,'out.csv'),'utf8');
 assert.match(lines,/time_server,engine,htf_bias,model_confirmation/);
 for(const x of lines.trim().split('\n').slice(1))assert.equal(x.split(',').at(-1),'0');
}));
test('Appending future candles and quotes does not change early output',async()=>fixture(async dir=>{
 const a=await run(dir,{'max-events':'250'});
 const original=fs.readFileSync(path.join(dir,'out.csv'),'utf8');
 const future=END+3600;
 fs.appendFileSync(path.join(dir,'demo_H1.csv'),`${future},9900,9901,9899,9900,1,11,0\n`);
 fs.appendFileSync(path.join(dir,'demo_ticks.csv'),`${future*1000},9999,10000,230\n`);
 const b=await run(dir,{'max-events':'250'});
 assert.equal(fs.readFileSync(path.join(dir,'out.csv'),'utf8'),original);
 assert.equal(a.counts.sampled_seconds,b.counts.sampled_seconds);
}));
test('When tick quotes are stale, never synthesize bid/ask from OHLC',async()=>fixture(async dir=>{
 fs.writeFileSync(path.join(dir,'demo_ticks.csv'), 'time_msc,bid,ask,flags\n'+`${START*1000},4000,4000.11,230\n`);
 const s=await run(dir,{'max-events':'100','max-quote-age-ms':'5'});
 assert.ok(s.counts.quote_stale_or_missing>=90);
 assert.equal(s.counts.r1_raw_signal_seconds,0);
 assert.equal(s.counts.r2_raw_signal_seconds,0);
 assert.match(fs.readFileSync(path.join(dir,'out.csv'),'utf8'),/NO_FRESH_BID_ASK/);
}));
test('Missing or INCOMPLETE export cannot get a trading report',async()=>fixture(async dir=>{
 const metaFile=path.join(dir,'demo_meta.csv');
 fs.writeFileSync(metaFile,fs.readFileSync(metaFile,'utf8').replace('export_status,OK','export_status,INCOMPLETE'));
 await assert.rejects(run(dir),/COMPLETE/);
}));
test('Illegal cadence (which could skip candle-close boundaries) is rejected',async()=>fixture(async dir=>{
 await assert.rejects(run(dir,{'cadence-seconds':'7'}),/divisor of 300/);
}));