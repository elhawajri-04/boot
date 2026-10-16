#!/usr/bin/env node
// Phase 1: SIGNAL REPLAY ONLY. Deliberately never models broker fills or profitability.
// Extracts the original ICT/SMC V4 decision adapter from the supplied Worker source.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import vm from 'node:vm';
import readline from 'node:readline';
import { once } from 'node:events';

const durations = {M1:60,M5:300,M15:900,M30:1800,H1:3600};
const headerBars='t,o,h,l,c,tick_volume,spread_points,real_volume';
const headerTicks='time_msc,bid,ask,flags';
const outputColumns=['time_server','engine','htf_bias','raw_allowed','pending_only','side','order_type','entry','sl_worker','tp1_worker','tp2_worker','zone_low','zone_high','invalidation','score','setup_key','reason','news_verified','execution_eligible'];

function argsOf(argv) {
  const out={};
  for(let i=0;i<argv.length;i+=2){
    if(!argv[i].startsWith('--') || i+1>=argv.length)throw Error('Arguments are --name value pairs');
    out[argv[i].slice(2)]=argv[i+1];
  }
  for(const k of ['worker','dir','prefix','out'])if(!out[k])throw Error('Missing --'+k);
  if(out['max-events']!==undefined && (!Number.isInteger(Number(out['max-events'])) || Number(out['max-events'])<1))
    throw Error('--max-events must be a positive integer');
  return out;
}
function loadOriginalWorker(workerPath){
  const content=fs.readFileSync(workerPath,'utf8');
  const begin=content.indexOf('const ICTV4 = (()=>{');
  const endMarker='// ======= End ICT/SMC v4 adapter =======';
  const end=content.indexOf(endMarker,begin);
  if(begin<0||end<begin)throw Error('Required original ICT/SMC V4 adapter missing, refuse replay');
  const exactAdapter=content.slice(begin,end);
  if(!exactAdapter.includes('function ictV4SidePlan(')||!exactAdapter.includes('function previewSnapshot('))
    throw Error('Original Worker adapter shape changed, abort');
  const api=vm.runInNewContext(exactAdapter+'\n({ preview: ICTV4.previewSnapshot, plan: ictV4SidePlan })',
                               {Math,Number,Boolean,Array,String,Set,Date}, {timeout:3000,filename:'original-worker-ICTV4.js'});
  return {api,sha256:crypto.createHash('sha256').update(content).digest('hex'),
          adapterSha256:crypto.createHash('sha256').update(exactAdapter).digest('hex')};
}

async function* csvRows(file,expectedHeader){
  const input=fs.createReadStream(file,{encoding:'utf8'});
  const lines=readline.createInterface({input,crlfDelay:Infinity});
  let first=true,prev=-Infinity,lineNo=0;
  for await(const line of lines){
    lineNo++;
    if(first){first=false;if(line.trim()!==expectedHeader)throw Error('Unexpected CSV header '+file+': '+line);continue;}
    if(!line.trim())continue;
    const a=line.split(',');
    if(a.length!==expectedHeader.split(',').length)throw Error(`${file}:${lineNo}: wrong column count`);
    const ns=a.map(Number);
    if(ns.some(x=>!Number.isFinite(x)))throw Error(`${file}:${lineNo}: nonnumeric field`);
    const t=ns[0];
    if(t<prev)throw Error(`${file}:${lineNo}: timestamps not ascending`);
    prev=t;
    if(expectedHeader===headerTicks){
      if(ns[1]<=0||ns[2]<ns[1])continue; // zero/invalid quote never considered for decisions
      yield {time_msc:t,bid:ns[1],ask:ns[2],flags:ns[3]};
    }else{
      const [_,o,h,l,c,tick_volume,spread_points,real_volume]=ns;
      if(h<Math.max(o,c)||l>Math.min(o,c)||h<l||t%60!==0)throw Error(`${file}:${lineNo}: invalid OHLC or time`);
      yield {t,o,h,l,c,tick_volume,spread_points,real_volume};
    }
  }
  if(first)throw Error('Empty CSV '+file);
}
async function iteratorWithHead(it){const iterator=it[Symbol.asyncIterator]();return {iterator,head:await iterator.next()};}
async function pullBefore(state, cutoff,buffer,max=350){
  while(!state.head.done && state.head.value.t+cutoff.seconds<=cutoff.time){
    const v=state.head.value;
    if(v.t>cutoff.time-cutoff.seconds)throw Error('FUTURE_BAR_DETECTED');
    buffer.push(v); if(buffer.length>max)buffer.shift();
    state.head=await state.iterator.next();
  }
}
async function quoteAt(state,timeMsc){
  while(!state.head.done && state.head.value.time_msc<=timeMsc){
    state.current=state.head.value;
    state.head=await state.iterator.next();
  }
  return state.current||null;
}
function csvSafe(v){return String(v??'').replaceAll('"','""').includes(',')?'"'+String(v??'').replaceAll('"','""')+'"':String(v??'');}
async function writeLine(stream,line){if(!stream.write(line+'\n'))await once(stream,'drain');}
function planRow(time,engine,bias,plan,reasonOverride){
  const isR2=engine==='R2',pending=['BUY_LIMIT','SELL_LIMIT','BUY_STOP','SELL_STOP'].includes(plan?.order_type);
  const approved=Boolean(plan?.allowed) && (!isR2 || pending);
  return [time,engine,bias,approved?1:0,isR2?1:0,plan?.side||'',approved?plan.order_type:'NONE',
   approved?plan.entry:'',approved?plan.sl:'',approved?plan.tp1:'',approved?plan.tp2:'',
   plan?.zone_low??'',plan?.zone_high??'',plan?.invalidation??'',plan?.score||0,
   `${engine}_${plan?.zone_id||'NONE'}_${plan?.latest_closed_bar||0}_${plan?.order_type||'NONE'}`,
   reasonOverride||(approved?plan.reason:(isR2&&plan?.allowed&&!pending?'R2_MARKET_REJECTED_PENDING_ONLY':plan?.reason||'WAIT')),
   0,0]; // fail closed: historical news + session and EA stop/lot validation not yet replayed
}

export async function runReplay(opts){
 const {worker,dir,prefix,out}=opts;
 const maxEvents=opts['max-events']?Number(opts['max-events']):Infinity;
 const metaFile=path.join(dir,prefix+'_meta.csv');
 const metaLines=fs.readFileSync(metaFile,'utf8').replaceAll('\r','').trim().split('\n');
 if(metaLines[0]!=='key,value')throw Error('Metadata format invalid');
 const meta=Object.fromEntries(metaLines.slice(1).map(l=>l.split(',')));
 if(meta.export_status!=='OK'||meta.ticks_exported!=='true')throw Error('Need COMPLETE tick+bar export, refuse simulated/fabricated quotes');
 if(meta.format_version!=='1')throw Error('Unsupported metadata version');
 const start=Number(meta.start_server_unix),end=Number(meta.end_server_unix_exclusive);
 if(!Number.isInteger(start)||!Number.isInteger(end)||start>=end)throw Error('Invalid period metadata');
 const {api,sha256,adapterSha256}=loadOriginalWorker(worker);
 const states={},buffers={};
 for(const tf of Object.keys(durations)){
   states[tf]=await iteratorWithHead(csvRows(path.join(dir,prefix+'_'+tf+'.csv'),headerBars));
   buffers[tf]=[];
 }
 const quoteState=await iteratorWithHead(csvRows(path.join(dir,prefix+'_ticks.csv'),headerTicks));
 const sample=states.M5;
 const counts={events:0,quotes_stale:0,bars_incomplete:0,r1_raw_signals:0,r2_raw_signals:0,r2_market_filtered:0,wait_reasons:{}};
 fs.mkdirSync(path.dirname(out),{recursive:true});
 const stream=fs.createWriteStream(out,{encoding:'utf8'});
 const t0=Date.now();
 try{
  await writeLine(stream,outputColumns.join(','));
  while(!sample.head.done && counts.events<maxEvents){
    const candle=sample.head.value;
    const clock=candle.t+300;
    // Advance ALL timeframes including M5 only after the bars are closed.
    for(const tf of Object.keys(durations)){
      await pullBefore(states[tf],{seconds:durations[tf],time:clock},buffers[tf]);
    }
    // sample.head already advanced by pullBefore(); do not advance it again.
    if(clock<start || clock>=end)continue;
    if(!buffers.M5.some(x=>x.t===candle.t))throw Error('M5 clock advanced out of sequence');
    counts.events++;
    const quote=await quoteAt(quoteState,clock*1000);
    if(!quote || quote.time_msc>clock*1000 || clock*1000-quote.time_msc>30000){
      counts.quotes_stale++;
      for(const engine of ['R1','R2'])await writeLine(stream,planRow(clock,engine,'UNKNOWN',null,'NO_FRESH_BID_ASK').map(csvSafe).join(','));
      continue;
    }
    if(Object.keys(durations).some(tf=>buffers[tf].length<60)){
      counts.bars_incomplete++;
      for(const engine of ['R1','R2'])await writeLine(stream,planRow(clock,engine,'UNKNOWN',null,'INSUFFICIENT_CLOSED_HISTORY').map(csvSafe).join(','));
      continue;
    }
    const snapshot={generated_at:clock,bid:quote.bid,ask:quote.ask,point:Number(meta.point),
      H1:buffers.H1.slice(),M30:buffers.M30.slice(),M15:buffers.M15.slice(),M5:buffers.M5.slice(),M1:buffers.M1.slice()};
    const state=api.preview(snapshot);
    const r1=api.plan(snapshot,state,'M5',300);
    const r2=api.plan(snapshot,state,'M15',900);
    if(r1.allowed)counts.r1_raw_signals++;
    if(r2.allowed && ['BUY','SELL'].includes(r2.order_type))counts.r2_market_filtered++;
    if(r2.allowed && ['BUY_LIMIT','SELL_LIMIT','BUY_STOP','SELL_STOP'].includes(r2.order_type))counts.r2_raw_signals++;
    for(const [engine,plan] of [['R1',r1],['R2',r2]]){
      const row=planRow(clock,engine,state.htf_bias,plan);
      const reason=row[16];counts.wait_reasons[reason]=(counts.wait_reasons[reason]||0)+1;
      await writeLine(stream,row.map(csvSafe).join(','));
    }
  }
  stream.end();await once(stream,'finish');
 }catch(e){stream.destroy();throw e;}
 const summary={phase:'signal_replay_only',no_orders_sent:true,no_profitability_calculated:true,
   execution_eligible_always_false:true,broker_clock_note:'CSV server datetime values must match tick timestamps',
   sample_cadence:'once per completed M5 bar (not identical to live 1s poll)',
   historic_news_unavailable:true,local_ea_r1_swing_sl_not_replayed:true,
   symbol:meta.symbol,start,end,worker_sha256:sha256,worker_adapter_sha256:adapterSha256,
   counts,elapsed_seconds:Math.round((Date.now()-t0)/1000)};
 fs.writeFileSync(out+'.summary.json',JSON.stringify(summary,null,2)+'\n');
 return summary;
}

if(process.argv[1] && path.resolve(process.argv[1])===path.resolve(new URL(import.meta.url).pathname)){
 try{const summary=await runReplay(argsOf(process.argv.slice(2)));console.log(JSON.stringify(summary,null,2));}
 catch(err){console.error('REPLAY FAILED:',err.message);process.exitCode=1;}
}