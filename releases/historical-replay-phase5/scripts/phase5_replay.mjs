#!/usr/bin/env node
// Phase 5 research: same pinned Worker adapter, corrected pivot; parallel zones + tolerant HTF life cycle.
// Causal two-stage retest lifecycle; no broker fills claimed.
// No broker fills / no profitability; all triggers are quote observations only.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import vm from 'node:vm';
import readline from 'node:readline';
import {once} from 'node:events';
import {fileURLToPath} from 'node:url';

const TF={M1:60,M5:300,M15:900,M30:1800,H1:3600};
const BAR_HEADER='t,o,h,l,c,tick_volume,spread_points,real_volume';
const TICK_HEADER='time_msc,bid,ask,flags';
const EVENT_COLUMNS=['event_id','engine','event_time','signal_bar','side','zone_type','zone_low','zone_high','value_eq','retest_low','retest_high','invalidation','expiry_time','placement_type','placement_entry','initial_quote_age_ms','outcome','outcome_time','outcome_bid','outcome_ask','quote_age_ms','observed_touch','note'];
const decimal=x=>Number.isFinite(x)?Number(x.toFixed(4)):'';
const asCsv=x=>{const t=String(x??'');return /[",\r\n]/.test(t)?'"'+t.replaceAll('"','""')+'"':t;};
const bump=(o,k)=>{o[k]=(o[k]||0)+1;};

export function originalWorker(workerPath){
 const full=fs.readFileSync(workerPath,'utf8');
 const begin=full.indexOf('const ICTV4 = (()=>{'),end=full.indexOf('// ======= End ICT/SMC v4 adapter =======',begin);
 if(begin<0||end<begin)throw Error('ICTV4 adapter marker missing; cannot substitute another strategy');
 const sourceAdapter=full.slice(begin,end);
 // Precise correction: n-3 is a fully CONFIRMED pivot (right=2).
 // Keep all other Worker primitives unchanged, and refuse ambiguous upstream edits.
 const broken='swings.highs.filter(x=>x.index<n-3).at(-1);';
 const brokenLow='swings.lows.filter(x=>x.index<n-3).at(-1);';
 if(sourceAdapter.split(broken).length!==2 || sourceAdapter.split(brokenLow).length!==2)
  throw Error('Expected original breakOfStructure swing gates not found: fail closed');
 const exact=sourceAdapter.replace(broken,'swings.highs.filter(x=>x.index<=n-3).at(-1);')
                          .replace(brokenLow,'swings.lows.filter(x=>x.index<=n-3).at(-1);');
 if(!exact.includes('function analyzeTF(')||!exact.includes('function previewSetup(')||!exact.includes('function ictV4SidePlan('))throw Error('Worker ICTV4 structure changed');
 const api=vm.runInNewContext(exact+'\n({ict:ICTV4,originalPlan:ictV4SidePlan})', {Math,Number,Boolean,Array,String,Set,Date}, {timeout:4000});
 return {api,worker_sha256:crypto.createHash('sha256').update(full).digest('hex'),adapter_sha256:crypto.createHash('sha256').update(exact).digest('hex'),original_adapter_sha256:crypto.createHash('sha256').update(sourceAdapter).digest('hex'),swing_fix:'n-3 included (confirmed right=2)'};
}
export function confirmEvent(ict,analysis,side,engine,clock,point=.01){
 if(!['BUY','SELL'].includes(side))return null;
 if(!analysis?.ready||analysis.bars.length<60)return null;
 const sw=analysis.sweep,disp=analysis.displacement,bos=analysis.break;
 if(sw?.direction!==side||disp?.direction!==side||disp.index<=sw.index||bos?.direction!==side)return null;
 const gap=ict.fvg(analysis.bars,side),block=ict.orderBlock(analysis.bars,disp);
 const zone=gap||block;
 if(!zone||!analysis.value||!(zone.low<zone.high)||!(point>0))return null;
 const eq=analysis.value.equilibrium;
 if(!Number.isFinite(eq))return null;
 const low=side==='BUY'?zone.low:Math.max(zone.low,eq);
 const high=side==='BUY'?Math.min(zone.high,eq):zone.high;
 const valid=high-low>=point; // require at least one point of overlap for a quoted executable touch
 const last=analysis.bars.at(-1);
 const expiry=clock+(engine==='R1'?3600:21600);
 const placement=side==='BUY'?'BUY_LIMIT':'SELL_LIMIT';
 const result={
  event_id:`${engine}_${side}_${last.t}`,engine,event_time:clock,signal_bar:last.t,side,
  zone_type:gap?'FVG':'OB',zone_low:zone.low,zone_high:zone.high,value_eq:eq,
  retest_low:low,retest_high:high,invalidation:zone.distal,expiry_time:expiry,
  placement_type:placement,placement_entry:side==='BUY'?high:low,
  initial_quote_age_ms:'',outcome:'',outcome_time:'',outcome_bid:'',outcome_ask:'',quote_age_ms:'',observed_touch:0,note:'',
  // internal flags not exported
  valid_overlap:valid,armed:false,origin_quote:null
 };
 return result;
}
// Non-destructive candidate admission (prevents identical overlapping entries).
export function candidateAdmission(active,event,maxCandidates=3){
 const duplicate=active.some(x=>x.side===event.side &&
  Math.min(x.retest_high,event.retest_high)-Math.max(x.retest_low,event.retest_low)>0 &&
  (Math.min(x.retest_high,event.retest_high)-Math.max(x.retest_low,event.retest_low)) /
  Math.min(x.retest_high-x.retest_low,event.retest_high-event.retest_low)>=0.70);
 if(duplicate)return 'OVERLAPPING_ZONE';
 if(active.length>=maxCandidates)return 'CANDIDATE_CAPACITY';
 return '';
}
export function quoteIsValid(quote,clock,maxAgeMs){
 if(!quote || !(quote.bid>0 && quote.ask>=quote.bid))return false;
 const age=clock*1000-quote.t;
 return age>=0&&age<=maxAgeMs;
}
export function armEvent(e,quote,clock,ageMs,point=.01){
 // MUST NOT use a future tick. Positioning means pending candidate, NOT an actual broker order.
 if(!e.valid_overlap){e.outcome='NO_VALUE_ZONE_OVERLAP';e.outcome_time=clock;e.note='No overlap between original zone and premium/discount half';return false;}
 if(!quote){e.outcome='NO_FRESH_ORIGIN_QUOTE';e.outcome_time=clock;return false;}
 e.initial_quote_age_ms=ageMs;
 // Market has to be outside the tradable zone on the breakout side when setup is identified.
 // A resting LIMIT at upper edge for BUY must be < ASK; reverse for SELL.
 const outside=e.side==='BUY'?quote.ask>e.retest_high+point:quote.bid<e.retest_low-point;
 if(!outside){e.outcome='NOT_OUTSIDE_RETEST_ZONE';e.outcome_time=clock;return false;}
 e.armed=true;e.origin_quote={bid:quote.bid,ask:quote.ask,t:quote.t};return true;
}
export function examineRetest(e,quote,clock){
 if(!e.armed||clock<=e.event_time)return 'WAIT'; // NEVER enter on creation bar/quote
 const price=e.side==='BUY'?quote.ask:quote.bid;
 const touches=price>=e.retest_low && price<=e.retest_high;
 if(touches)return 'OBSERVED_ZONE_TOUCH';
 // A gap across entire zone could fill broker LIMIT, but this engine refuses to assume a fill.
 const crosses=e.side==='BUY'?price<e.retest_low:price>e.retest_high;
 if(crosses)return 'GAP_ACROSS_ZONE_UNVERIFIED';
 return 'WAIT';
}
export function cancellationReason(e,htfBias,completedTFBar,clock,oppositeBarsRequired=2){
 if(clock>=e.expiry_time)return 'EXPIRED';
 // A MIXED higher-timeframe reading is neutral, not structural invalidation.
 // Opposite confirmed HTF is actionable only when it persists on fresh M5 decisions.
 if(htfBias==='BUY'||htfBias==='SELL'){
  e.oppositeCount=htfBias===e.side?0:(e.oppositeCount||0)+1;
 }else e.oppositeCount=0;
 if(e.oppositeCount>=oppositeBarsRequired)return 'OPPOSITE_HTF_CONFIRMED';
 if(completedTFBar){
  if(e.side==='BUY'&&completedTFBar.c<e.invalidation)return 'STRUCTURAL_INVALIDATION_CLOSE';
  if(e.side==='SELL'&&completedTFBar.c>e.invalidation)return 'STRUCTURAL_INVALIDATION_CLOSE';
 }
 return '';
}
function finish(e,why,clock,quote,ageMs,note=''){
 if(e.outcome)return;
 e.outcome=why;e.outcome_time=clock;e.outcome_bid=quote?.bid??'';e.outcome_ask=quote?.ask??'';
 e.quote_age_ms=ageMs??'';e.observed_touch=why==='OBSERVED_ZONE_TOUCH'?1:0;e.note=note;
}
export function readMeta(file){
 const rows=fs.readFileSync(file,'utf8').replaceAll('\r','').trim().split('\n');
 if(rows.shift()!=='key,value')throw Error('Bad metadata');
 const m=Object.fromEntries(rows.map(x=>x.split(',')));
 if(m.export_status!=='OK'||m.ticks_exported!=='true'||m.format_version!=='1')throw Error('Need valid COMPLETE tick export');
 const start=Number(m.start_server_unix),end=Number(m.end_server_unix_exclusive),point=Number(m.point);
 if(!Number.isSafeInteger(start)||!Number.isSafeInteger(end)||!(start<end)||!(point>0)||start%300!==0||end%300!==0)throw Error('Bad time/point in meta');
 return {m,start,end,point};
}
async function* csvRows(file,header){
 const stream=fs.createReadStream(file,{encoding:'utf8'}),rl=readline.createInterface({input:stream,crlfDelay:Infinity});
 let first=true,prev=-Infinity,n=0;
 try{
  for await(const s of rl){
   if(first){first=false;if(s.trim()!==header)throw Error('Bad CSV header '+file);continue;}
   if(!s.trim())continue;
   const a=s.split(',').map(Number);
   if(a.length!==header.split(',').length||a.some(x=>!Number.isFinite(x)))throw Error('Bad row in '+file);
   if(a[0]<prev)throw Error('Unsorted CSV '+file);
   prev=a[0];n++;
   if(header===TICK_HEADER)yield {t:a[0],bid:a[1],ask:a[2]};
   else{const [t,o,h,l,c]=a;if(t%60!==0||h<Math.max(o,c)||l>Math.min(o,c)||h<l)throw Error('Bad OHLC '+file);yield {t,o,h,l,c};}
  }
 }finally{rl.close();stream.destroy();}
 if(first||n===0)throw Error('Empty '+file);
}
async function withHead(gen){const iterator=gen[Symbol.asyncIterator]();return {iterator,head:await iterator.next()};}
async function advanceBar(s,clock,duration,cache){
 let changed=false;
 while(!s.head.done&&s.head.value.t+duration<=clock){
  cache.push(s.head.value);if(cache.length>350)cache.shift();
  s.head=await s.iterator.next();changed=true;
 }
 return changed;
}
async function advanceTicks(s,ms){
 while(!s.head.done&&s.head.value.t<=ms){
  const q=s.head.value;if(q.bid>0&&q.ask>=q.bid)s.last=q;
  s.head=await s.iterator.next();
 }
 return s.last||null;
}
function optsParse(argv){
 const opts={};for(let i=0;i<argv.length;i+=2){if(!argv[i]?.startsWith('--')||!argv[i+1])throw Error('Expected --option value pairs');opts[argv[i].slice(2)]=argv[i+1];}
 for(const name of ['worker','dir','prefix','out'])if(!opts[name])throw Error('Missing --'+name);
 return opts;
}
export async function runReplay(opts){
 const {worker,dir,prefix,out}=opts;
 const cadence=Number(opts['cadence-seconds']??1),maxAgeMs=Number(opts['max-quote-age-ms']??30000);
 if(!Number.isInteger(cadence)||cadence<1||300%cadence!==0)throw Error('Invalid cadence');
 if(!Number.isInteger(maxAgeMs)||maxAgeMs<0||maxAgeMs>300000)throw Error('Invalid quote age');
 const {m,start,end,point}=readMeta(path.join(dir,prefix+'_meta.csv'));
 const {api,worker_sha256,adapter_sha256,original_adapter_sha256,swing_fix}=originalWorker(worker);
 const bars={},states={};for(const tf of Object.keys(TF)){
  bars[tf]=[];states[tf]=await withHead(csvRows(path.join(dir,prefix+'_'+tf+'.csv'),BAR_HEADER));
 }
 const tick=await withHead(csvRows(path.join(dir,prefix+'_ticks.csv'),TICK_HEADER));
 fs.mkdirSync(path.dirname(out),{recursive:true});
 const outStream=fs.createWriteStream(out,{encoding:'utf8'});
 const summary={phase:'phase5_parallel_zone_retest_research',symbol:m.symbol,start,end,worker_sha256,adapter_sha256,original_adapter_sha256,swing_fix,
  sampled_seconds:0,source_events:{R1:0,R2:0},fully_tradable_value_overlap:{R1:0,R2:0},
  setup_rejected:{},results:{R1:{},R2:{}},observed_retest:{R1:0,R2:0},peak_concurrent:{R1:0,R2:0},broker_orders:0,
  fills_simulated:0,profitability_calculated:false,news_verified:false,session_policy_verified:false,
  local_r1_sl_calculated:false,broker_stops_checked:false,entry_guaranteed:false,
  restrictions:'Research-only. Original ICTV4 adapter patched ONLY for newest confirmed swing; multi-zone/HTF policy is research logic, not live Worker. No fills or monetary results.'};
 const active={R1:[],R2:[]},seen={R1:new Set(),R2:new Set()};
 const maxCandidates=Number(opts['max-candidates-per-engine']??3);
 if(!Number.isInteger(maxCandidates)||maxCandidates<1||maxCandidates>10)throw Error('Invalid max candidates');
 let htf='MIXED',lastM5=null, lastM15=null;
 const completed=[];
 const writeRow=async e=>{completed.push({...e});const row=EVENT_COLUMNS.map(k=>e[k]);if(!outStream.write(row.map(asCsv).join(',')+'\n'))await once(outStream,'drain');bump(summary.results[e.engine],e.outcome);};
 const resolve=async (engine,e,reason,clock,q,ageMs,note='')=>{
  if(!active[engine].includes(e))return;
  finish(e,reason,clock,q,ageMs,note);await writeRow(e);
  active[engine]=active[engine].filter(x=>x!==e);
 };
 try{
  if(!outStream.write(EVENT_COLUMNS.join(',')+'\n'))await once(outStream,'drain');
  for(let clock=start;clock<end;clock+=cadence){
   let freshM5=false,freshM15=false;
   for(const [tf,dur] of Object.entries(TF)){
    const changed=await advanceBar(states[tf],clock,dur,bars[tf]);
    if(tf==='M5'&&changed)freshM5=true;
    if(tf==='M15'&&changed)freshM15=true;
   }
   const quote=await advanceTicks(tick,clock*1000),hasQuote=quoteIsValid(quote,clock,maxAgeMs);
   const age=hasQuote?clock*1000-quote.t:null;
   summary.sampled_seconds++;
   if(freshM5 && Object.keys(TF).every(tf=>bars[tf].length>=60)){
    const snapshot={generated_at:clock,point,bid:hasQuote?quote.bid:0,ask:hasQuote?quote.ask:0,...bars};
    const model=api.ict.previewSnapshot(snapshot);htf=model.htf_bias;
    // Cancel existing states *before* considering new confirmations.
    for(const engine of ['R1','R2']){
     const completedBar=engine==='R1'?bars.M5.at(-1):(freshM15?bars.M15.at(-1):null);
     for(const e of [...active[engine]]){
      const why=cancellationReason(e,htf,completedBar,clock);
      if(why)await resolve(engine,e,why,clock,hasQuote?quote:null,age);
     }
    }
    for(const engine of ['R1','R2']){
     const tf=engine==='R1'?'M5':'M15';
     if(engine==='R2'&&!freshM15)continue; // a single M15 close must not create repeated events
     const analyzed=api.ict.analyzeTF(bars[tf],clock,TF[tf]);
     const event=confirmEvent(api.ict,analyzed,htf,engine,clock,point);
     if(!event||seen[engine].has(event.event_id))continue;
     seen[engine].add(event.event_id);summary.source_events[engine]++;
     if(event.valid_overlap)summary.fully_tradable_value_overlap[engine]++;
     // Limit simultaneous candidates per engine; no forced replacement or look-ahead.
     const denied=candidateAdmission(active[engine],event,maxCandidates);
     if(denied){
      finish(event,denied,clock,hasQuote?quote:null,age);
      bump(summary.setup_rejected,event.outcome);await writeRow(event);continue;
     }
     // Arming needs a recent historical quote at the confirmation time, else fail closed.
     if(!hasQuote || !armEvent(event,quote,clock,age,point)){
      if(!event.outcome)finish(event,'NO_FRESH_ORIGIN_QUOTE',clock,null,null);
      bump(summary.setup_rejected,event.outcome);
      await writeRow(event);
     }else{
      event.oppositeCount=0;
      active[engine].push(event);
      summary.peak_concurrent[engine]=Math.max(summary.peak_concurrent[engine],active[engine].length);
     }
    }
   }
   for(const engine of ['R1','R2']){
   for(const e of [...active[engine]]){
    if(clock>=e.expiry_time){await resolve(engine,e,'EXPIRED',clock,hasQuote?quote:null,age);continue;}
    if(!hasQuote)continue;
    const action=examineRetest(e,quote,clock);
    if(action!=='WAIT'){
     if(action==='OBSERVED_ZONE_TOUCH')summary.observed_retest[engine]++;
     await resolve(engine,e,action,clock,quote,age,'No broker order or fill assumed');
    }
   }
  }
  }
  for(const engine of ['R1','R2'])for(const e of [...active[engine]])await resolve(engine,e,'END_OF_EXPORT_CENSORED',end,null,null);
  outStream.end();await once(outStream,'finish');
 }catch(e){outStream.destroy();throw e;}
 summary.total_recorded=completed.length;
 fs.writeFileSync(out+'.summary.json',JSON.stringify(summary,null,2)+'\n');
 return summary;
}
const isMain=process.argv[1] && path.resolve(process.argv[1])===fileURLToPath(import.meta.url);
if(isMain){try{const result=await runReplay(optsParse(process.argv.slice(2)));console.log(JSON.stringify(result,null,2));}catch(e){console.error('PHASE5 FAILED:',e.stack||e.message);process.exitCode=1;}}