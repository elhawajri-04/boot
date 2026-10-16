#!/usr/bin/env node
// XAU Historical Replay Phase 2: causal quote-clock scan of the ORIGINAL Worker ICT/SMC adapter.
// Research only. Does not simulate MT5 broker fills, historical news, local swing SL, or profitability.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import vm from 'node:vm';
import readline from 'node:readline';
import {once} from 'node:events';
import {fileURLToPath} from 'node:url';

const seconds = {M1:60,M5:300,M15:900,M30:1800,H1:3600};
const barHead='t,o,h,l,c,tick_volume,spread_points,real_volume';
const tickHead='time_msc,bid,ask,flags';
const cols=['time_server','engine','htf_bias','model_confirmation','raw_allowed','pending_only','side','order_type','entry','sl_worker','tp1_worker','tp2_worker','zone_low','zone_high','invalidation','score','last_closed_bar','zone_id','reason','quote_age_ms','news_verified','execution_eligible'];
const pending=new Set(['BUY_LIMIT','SELL_LIMIT','BUY_STOP','SELL_STOP']);

export function loadAdapter(worker){
 const full=fs.readFileSync(worker,'utf8');
 const start=full.indexOf('const ICTV4 = (()=>{'), end=full.indexOf('// ======= End ICT/SMC v4 adapter =======',start);
 if(start<0 || end<start)throw Error('Original ICT/SMC adapter is missing: refuse approximated strategy');
 const exact=full.slice(start,end);
 if(!exact.includes('function ictV4SidePlan(')||!exact.includes('function previewSnapshot('))throw Error('Worker adapter layout changed');
 const api=vm.runInNewContext(exact+'\n({preview:ICTV4.previewSnapshot, plan:ictV4SidePlan})',
    {Math,Number,Boolean,Array,String,Set,Date},{filename:'original-ICTV4.js',timeout:4000});
 return {api,source_sha256:crypto.createHash('sha256').update(full).digest('hex'),adapter_sha256:crypto.createHash('sha256').update(exact).digest('hex')};
}

function parseMetadata(file){
 const text=fs.readFileSync(file,'utf8').replaceAll('\r','').trim();
 const entries=text.split('\n').map(x=>x.split(','));
 if(entries.shift()?.join(',')!=='key,value')throw Error('Bad metadata header');
 const meta=Object.fromEntries(entries);
 if(meta.export_status!=='OK'||meta.ticks_exported!=='true')throw Error('Only COMPLETE broker tick exports allowed');
 if(meta.format_version!=='1')throw Error('Unsupported CSV format');
 const start=Number(meta.start_server_unix),end=Number(meta.end_server_unix_exclusive),point=Number(meta.point);
 if(!Number.isSafeInteger(start)||!Number.isSafeInteger(end)||end<=start|| !(point>0))throw Error('Bad metadata start/end/point');
 for(const t of [start,end])if(t%300!==0)throw Error('Replay period must align to M5 candle boundaries');
 return {meta,start,end,point};
}

async function* csv(file,expected){
 const stream=fs.createReadStream(file,{encoding:'utf8'});
 const iter=readline.createInterface({input:stream,crlfDelay:Infinity});
 let header=true,last=-Infinity,lineNo=0,records=0;
 try{
  for await(const line of iter){
   lineNo++;
   if(header){header=false;if(line.trim()!==expected)throw Error(`Wrong CSV header ${file}:${lineNo}`);continue;}
   if(!line.trim())continue;
   const arr=line.split(',').map(Number);
   if(arr.length!==expected.split(',').length||arr.some(x=>!Number.isFinite(x)))throw Error(`Malformed CSV ${file}:${lineNo}`);
   if(arr[0]<last)throw Error(`Out-of-order ${file}:${lineNo}`);
   last=arr[0];records++;
   if(expected===tickHead){
    if(!Number.isSafeInteger(arr[0]))throw Error(`Bad tick timestamp ${file}:${lineNo}`);
    // Zero bid/ask is allowed in raw tick feed: report lack of actionable quote until a fully valid pair is observed.
    yield {t:arr[0],bid:arr[1],ask:arr[2]};
   }else{
    const [t,o,h,l,c]=arr;
    if(!Number.isSafeInteger(t)||t%60!==0||h<Math.max(o,c)||l>Math.min(o,c)||h<l)throw Error(`Bad OHLC ${file}:${lineNo}`);
    yield {t,o,h,l,c};
   }
  }
 }finally{iter.close();stream.destroy();}
 if(header||records===0)throw Error('Missing market records '+file);
}
async function withHead(gen){const iterator=gen[Symbol.asyncIterator]();return {iterator,head:await iterator.next()};}
async function advanceBars(state,limit,duration,cache){
 let changed=false;
 while(!state.head.done&&state.head.value.t+duration<=limit){
  cache.push(state.head.value);if(cache.length>350)cache.shift();
  state.head=await state.iterator.next();changed=true;
 }
 return changed;
}
async function advanceQuote(state,timeMs){
 while(!state.head.done&&state.head.value.t<=timeMs){
  const x=state.head.value;
  if(x.bid>0&&x.ask>=x.bid)state.current=x;
  // Deliberately do not backfill an absent quote with future ticks or bar close.
  state.head=await state.iterator.next();
 }
 return state.current??null;
}
function argParse(args){
 const r={};for(let i=0;i<args.length;i+=2){if(!args[i]?.startsWith('--')||!args[i+1])throw Error('Use --name value arguments');r[args[i].slice(2)]=args[i+1];}
 for(const key of ['worker','dir','prefix','out'])if(!r[key])throw Error('Missing --'+key);
 return r;
}
function rejectIfInvalidOptions(options){
 const cadence=Number(options['cadence-seconds']??1);
 const maxAge=Number(options['max-quote-age-ms']??30000);
 const maxEvents=Number(options['max-events']??Number.MAX_SAFE_INTEGER);
 if(!Number.isInteger(cadence)||cadence<1||300%cadence!==0)throw Error('--cadence-seconds must be a positive divisor of 300');
 if(!Number.isInteger(maxAge)||maxAge<0||maxAge>300000)throw Error('Invalid quote age');
 if(!Number.isSafeInteger(maxEvents)||maxEvents<1)throw Error('Invalid max events');
 return {cadence,maxAge,maxEvents};
}
function csvEscape(value){
 const s=String(value??'');return /[",\n\r]/.test(s)?'"'+s.replaceAll('"','""')+'"':s;
}
function signalRow(t,engine,bias,modelReason,plan,ageMs,reasonOverride){
 const isR2=engine==='R2';
 const approved=Boolean(plan?.allowed)&&(!isR2||pending.has(plan.order_type));
 const reason=reasonOverride || (isR2&&plan?.allowed&&!pending.has(plan.order_type)?'R2_MARKET_FILTERED':plan?.reason||modelReason||'WAIT');
 return [t,engine,bias,modelReason||'',approved?1:0,isR2?1:0,
   plan?.side??'',approved?plan.order_type:'NONE',approved?plan.entry:'',approved?plan.sl:'',
   approved?plan.tp1:'',approved?plan.tp2:'',plan?.zone_low??'',plan?.zone_high??'',
   plan?.invalidation??'',plan?.score??0,plan?.latest_closed_bar??'',plan?.zone_id??'',reason,ageMs??'',0,0];
}
function uniqSignature(row){
 // Do not deduplicate newly *confirmed* signal setups across new completed candles.
 // Avoid writing 600k identical WAIT rows while retaining all signal and rejection transitions.
 const [t,engine,bias,modelReason,allowed,pOnly,side,type,entry,sl,tp1,tp2,zl,zh,invalid,score,bar,zone,reason]=row;
 if(allowed)return [engine,bias,allowed,side,type,bar,zone,entry,sl,tp1].join('|');
 return [engine,bias,modelReason,reason,side,type,zl,zh].join('|');
}
function increment(obj,key){obj[key]=(obj[key]||0)+1;}
export async function runTickReplay(opts){
 const {worker,dir,prefix,out}=opts;const {cadence,maxAge,maxEvents}=rejectIfInvalidOptions(opts);
 const {meta,start,end,point}=parseMetadata(path.join(dir,prefix+'_meta.csv'));
 const {api,source_sha256,adapter_sha256}=loadAdapter(worker);
 const states={},bars={};
 for(const [tf] of Object.entries(seconds)){
  states[tf]=await withHead(csv(path.join(dir,prefix+'_'+tf+'.csv'),barHead));bars[tf]=[];
 }
 const tickState=await withHead(csv(path.join(dir,prefix+'_ticks.csv'),tickHead));
 const sums={sampled_seconds:0,quote_stale_or_missing:0,incomplete_bars:0,m5_model_refreshes:0,
  m5_model_confirmed_r1:0,m5_model_confirmed_r2:0, r1_raw_signal_seconds:0,r2_raw_signal_seconds:0,
  r1_unique_signal_setups:0,r2_unique_signal_setups:0,r2_market_only_filtered_seconds:0,
  htf_bias_by_m5:{},r1_confirmation_wait_m5:{},r2_confirmation_wait_m5:{},
  decision_reasons_seconds:{},written_rows:0,quote_time_from_future:0};
 const started=Date.now();fs.mkdirSync(path.dirname(out),{recursive:true});
 const output=fs.createWriteStream(out,{encoding:'utf8'});
 let oldM5=null,base=null,lastRows={},lastSetup={R1:new Set(),R2:new Set()};
 let rowN=0;const write=async(row)=>{if(!output.write(row.map(csvEscape).join(',')+'\n'))await once(output,'drain');sums.written_rows++;};
 try{
  if(!output.write(cols.join(',')+'\n'))await once(output,'drain');
  for(let clock=start;clock<end && sums.sampled_seconds<maxEvents;clock+=cadence){
   // Date and bar cutoffs are evaluated strictly at this historical broker timestamp.
   for(const [tf,duration]of Object.entries(seconds)){
    if(states[tf].head.done||states[tf].head.value.t+duration<=clock)await advanceBars(states[tf],clock,duration,bars[tf]);
   }
   const currentM5=bars.M5.at(-1)?.t;
   if(currentM5!==oldM5){
    oldM5=currentM5;base=null;
    sums.m5_model_refreshes++;
    if(Object.keys(seconds).every(tf=>bars[tf].length>=60)){
     const snap={generated_at:clock,point, bid:0,ask:0,
      M1:bars.M1,M5:bars.M5,M15:bars.M15,M30:bars.M30,H1:bars.H1};
     const model=api.preview(snap);
     base={snap,model,planned:{}};
     for(const engine of ['R1','R2']){
      const key=engine.toLowerCase(),tf=engine==='R1'?'M5':'M15',duration=seconds[tf];
      if(model[key]?.allowed)sums['m5_model_confirmed_'+key]++;
      increment(sums[key+'_confirmation_wait_m5'],model[key]?.reason??'UNKNOWN');
      // If confluence did not confirm, a different BID/ASK cannot make base.allowed true.
      // Cache the blocked diagnostic after the FIRST VALID QUOTE, not with placeholder bid/ask=0.
     }
     increment(sums.htf_bias_by_m5,model.htf_bias);
    }
   }
   const quote=await advanceQuote(tickState,clock*1000);
   const age=quote?clock*1000-quote.t:null;
   const valid=quote && age>=0&&age<=maxAge;
   sums.sampled_seconds++;
   if(!valid)sums.quote_stale_or_missing++;
   if(!base)sums.incomplete_bars++;
   for(const engine of ['R1','R2']){
    const key=engine.toLowerCase(),tf=engine==='R1'?'M5':'M15',duration=seconds[tf];
    const bias=base?.model.htf_bias||'UNKNOWN',modelReason=base?.model[key]?.reason||'NO_HISTORY';
    let plan=null,override='';
    if(!valid)override='NO_FRESH_BID_ASK';
    else if(!base)override='INSUFFICIENT_CLOSED_HISTORY';
    else if(base.planned[engine])plan=base.planned[engine];
    else{
     // Only the quote changes intra-M5. Analyze the original source on each candidate quote.
     // Worker calculation of pivots/FVG/structure is unchanged, never approximated.
     base.snap.generated_at=clock;base.snap.bid=quote.bid;base.snap.ask=quote.ask;
     plan=api.plan(base.snap,base.model,tf,duration);
     if(!base.model[key]?.allowed)base.planned[engine]=plan;
    }
    const row=signalRow(clock,engine,bias,modelReason,plan,valid?age:null,override);
    const allowed=Number(row[4])===1;
    if(allowed){
     sums[key+'_raw_signal_seconds']++;
     const setupKey=[row[6],row[7],row[16],row[17]].join('|');
     if(!lastSetup[engine].has(setupKey)){
      lastSetup[engine].add(setupKey);sums[key+'_unique_signal_setups']++;
     }
    }
    if(engine==='R2'&&plan?.allowed&&!pending.has(plan.order_type))sums.r2_market_only_filtered_seconds++;
    increment(sums.decision_reasons_seconds,`${engine}|${row[18]}`);
    const keyRow=uniqSignature(row);
    if(lastRows[engine]!==keyRow){await write(row);lastRows[engine]=keyRow;}
   }
  }
  output.end();await once(output,'finish');
 }catch(e){output.destroy();throw e;}
 const summary={phase:'tick_clock_signal_audit_only',symbol:meta.symbol,start,end,
  analysis_cadence_seconds:cadence,quote_max_age_ms:maxAge,
  original_worker_sha256:source_sha256,original_adapter_sha256:adapter_sha256,
  src_data_completed:true,no_orders_sent:true,no_profitability_calculated:true,
  execution_eligible_always_false:true,news_not_replayed:true,
  session_guard_not_replayed:true,r1_local_swing_sl_not_replayed:true,r2_pending_lifecycle_not_replayed:true,
  comment:'Model checks are refreshed on each M5 close; bid/ask is scanned at configured historical seconds. NOT exact live timers/poll latency.',
  counts:sums,elapsed_seconds:Number(((Date.now()-started)/1000).toFixed(2))};
 fs.writeFileSync(out+'.summary.json',JSON.stringify(summary,null,2)+'\n');return summary;
}
const isMain=process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url);
if(isMain){try{const result=await runTickReplay(argParse(process.argv.slice(2)));console.log(JSON.stringify(result,null,2));}catch(e){console.error('PHASE2 REPLAY FAILED:',e.stack||e.message);process.exitCode=1;}}