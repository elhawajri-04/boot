#!/usr/bin/env node
// Offline, READ-ONLY diagnostic against the original Worker ICTV4 primitives.
// Usage: node check_worker_gate.mjs --worker worker.js --dir export_folder --prefix xau_20250106
// Calculates BOS/value coexistence using ONLY fully closed M5/M15 bars and verified metadata.
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import crypto from 'node:crypto';

const args={};
for(let i=2;i<process.argv.length;i+=2){
 if(!process.argv[i]?.startsWith('--')||!process.argv[i+1])throw new Error('Use --worker PATH --dir PATH --prefix PREFIX');
 args[process.argv[i].slice(2)]=process.argv[i+1];
}
for(const f of ['worker','dir','prefix'])if(!args[f])throw new Error('Missing --'+f);
const src=fs.readFileSync(args.worker,'utf8'),marker='const ICTV4 = (()=>{';
const a=src.indexOf(marker),b=src.indexOf('// ======= End ICT/SMC v4 adapter =======',a);
if(a<0||b<=a)throw new Error('Original ICTV4 adapter not present');
const {ict}=vm.runInNewContext(src.slice(a,b)+'\n({ict:ICTV4})',{Math,Number,Boolean,Array,String,Set,Date},{timeout:4000});
const metaLines=fs.readFileSync(path.join(args.dir,args.prefix+'_meta.csv'),'utf8').trim().split(/\r?\n/);
if(metaLines[0]!=='key,value')throw new Error('Bad exporter meta');
const meta=Object.fromEntries(metaLines.slice(1).map(x=>x.split(',')));
if(meta.export_status!=='OK')throw new Error('Export not COMPLETE');
const start=Number(meta.start_server_unix),end=Number(meta.end_server_unix_exclusive);
if(!Number.isSafeInteger(start)||!Number.isSafeInteger(end)||end<=start)throw new Error('Bad timestamps');
const result={symbol:meta.symbol,start_server_unix:start,end_server_unix_exclusive:end,worker_sha256:crypto.createHash('sha256').update(src).digest('hex'),frames:{}};
for(const [tf,duration] of [['M5',300],['M15',900]]){
 const filename=path.join(args.dir,`${args.prefix}_${tf}.csv`);
 const rows=fs.readFileSync(filename,'utf8').trim().split(/\r?\n/);
 if(rows[0]!=='t,o,h,l,c,tick_volume,spread_points,real_volume')throw new Error('Wrong header '+tf);
 const bars=rows.slice(1).map(x=>{const [t,o,h,l,c]=x.split(',').map(Number);if(![t,o,h,l,c].every(Number.isFinite))throw new Error('bad candle');return{t,o,h,l,c}});
 const stats={bars_evaluated:0,bos_events:0,bos_with_dealing_value_pass:0,bos_breaking_latest_swing:0,latest_swing_bos_and_value_pass:0,stale_level_bos_with_value_pass:0,samples:[]};
 for(let n=60;n<=bars.length;n++){
  const bar=bars[n-1],clock=bar.t+duration;
  if(clock<start||clock>=end)continue;
  stats.bars_evaluated++;
  const model=ict.analyzeTF(bars.slice(Math.max(0,n-350),n),clock,duration);
  if(!model.ready||!model.break||!model.value)continue;
  const side=model.break.direction;
  const pass=side==='BUY'?bar.c<=model.value.equilibrium:bar.c>=model.value.equilibrium;
  const latest=side==='BUY'?model.swings.highs.at(-1):model.swings.lows.at(-1);
  if(!latest)continue;
  const breaksLatest=side==='BUY'?bar.c>latest.price:bar.c<latest.price;
  stats.bos_events++;
  if(pass)stats.bos_with_dealing_value_pass++;
  if(breaksLatest)stats.bos_breaking_latest_swing++;
  if(pass&&breaksLatest)stats.latest_swing_bos_and_value_pass++;
  if(pass&&!breaksLatest){
   stats.stale_level_bos_with_value_pass++;
   if(stats.samples.length<3)stats.samples.push({time_server:clock,direction:side,close:bar.c,broken_pivot:model.break.level,newest_confirmed_pivot:latest.price,equilibrium:model.value.equilibrium});
  }
 }
 result.frames[tf]=stats;
}
console.log(JSON.stringify(result,null,2));