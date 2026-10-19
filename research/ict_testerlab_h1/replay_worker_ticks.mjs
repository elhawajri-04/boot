/**
 * Independent OFFLINE XAU TesterLab replacement (research ONLY).
 * Uses the ORIGINAL, user-uploaded Worker H __testICTV4 and __testIctV4SidePlan
 * with saved MT5 broker OHLC and saved bid/ask ticks. No network calls or live orders.
 * Distinct from MT5 Strategy Tester: fee, news, position-manager, session, and
 * broker margin exactness must be validated with a separate MT5 replay later.
 * Node >=20; invocation: node replay_worker_ticks.mjs --data DIR --out DIR
 */
import fs from 'node:fs';
import path from 'node:path';
import { createInterface } from 'node:readline';
import { __testICTV4 as ICT, __testIctV4SidePlan as sidePlan } from './Worker_H_uploaded_source.mjs';

function argsFrom(argv){const out={};for(let i=0;i<argv.length;i++){if(!argv[i].startsWith('--'))throw Error('Unexpected '+argv[i]);out[argv[i].slice(2)]=argv[++i];}return out;}
const opts=argsFrom(process.argv.slice(2));
const DATA=opts.data||'/mnt/data';
const OUT=opts.out||'.';
const RISK=Number(opts['risk-pct']??'5');
const INITIAL=Number(opts['initial-balance']??'1000');
const CONTRACT=Number(opts['contract-size']??'100'); // not in supplied meta: ASSUMPTION
const MINLOT=Number(opts['min-lot']??'0.01');
const MAXLOT=Number(opts['max-lot']??'1');
const STEP=Number(opts['lot-step']??'0.01');
if(!(INITIAL>0&&RISK>0&&RISK<=5&&CONTRACT>0&&MINLOT>0&&MAXLOT>=MINLOT&&STEP>0))throw Error('Invalid risk/contract settings');
fs.mkdirSync(OUT,{recursive:true});
const files={M1:'xau_20250106_M1(3).csv',M5:'xau_20250106_M5(3).csv',M15:'xau_20250106_M15(3).csv',M30:'xau_20250106_M30(3).csv',H1:'xau_20250106_H1(3).csv'};
const secs={M1:60,M5:300,M15:900,M30:1800,H1:3600};
// Match H1 EA CopyRates counts including one unclosed candle, which Worker discards.
const completedCounts={M1:199,M5:199,M15:149,M30:119,H1:119};
function loadCsv(fp){const lines=fs.readFileSync(fp,'utf8').trim().split(/\r?\n/);const hdr=lines.shift().split(',');if(!['t','o','h','l','c'].every(x=>hdr.includes(x)))throw Error('Invalid OHLC header: '+fp);return lines.map(line=>{const row=line.split(',');const d={};for(const k of ['t','o','h','l','c'])d[k]=Number(row[hdr.indexOf(k)]);if(!Object.values(d).every(Number.isFinite))throw Error('Bad OHLC');return d;});}
const bars=Object.fromEntries(Object.entries(files).map(([tf,n])=>[tf,loadCsv(path.join(DATA,n))]));
const ticksPath=path.join(DATA,'xau_20250106_ticks(2).csv');
const candleIndexes=Object.fromEntries(Object.keys(files).map(k=>[k,0]));
const nReason={R1:{},R2:{}};
const nOrders={R1:{},R2:{}};
const seenKeys={R1:new Set(),R2:new Set()};
const candidates=[];
const activity=[];
const positions=[];
const closed=[];
const rejected={risk:0,overlap:0,nonviable:0};
let pending=[];
let account=INITIAL,peak=INITIAL,ddMax=0,evalCount=0,tickCount=0,windowFirst=null,windowLast=null;
let lastBar=-1,firstTradeTs=null,lastTradeTs=null;

function snapshot(t,bid,ask){
 const s={generated_at:t,bid,ask,point:0.01};
 for(const tf of Object.keys(secs)){
  const arr=bars[tf],second=secs[tf];
  while(candleIndexes[tf]<arr.length&&arr[candleIndexes[tf]].t+second<=t)candleIndexes[tf]++;
  s[tf]=arr.slice(Math.max(0,candleIndexes[tf]-completedCounts[tf]),candleIndexes[tf]);
 }
 return s;
}
function maxRiskPositionMoney(){return (account*Math.max(0,RISK))/100;}
function openRiskMoney(){return positions.reduce((v,p)=>v+Math.max(0,Math.abs(p.fill-p.sl))*CONTRACT*p.lot,0);}
function roundLot(v){const steps=Math.floor((v+1e-8)/STEP);return Math.min(MAXLOT,Math.floor((steps*STEP+1e-8)*100)/100);}
function positionsFor(e){return positions.filter(p=>p.engine===e).length;}
function canOpen(event,fill){
 const distance=Math.abs(fill-event.sl);
 if(!(distance>0) || (event.side==='BUY'&&event.sl>=fill) || (event.side==='SELL'&&event.sl<=fill))return null;
 // Matches *risk ceilings* of H1, not its exact broker OrderCalcProfit/lot algorithm.
 const target=Math.min(maxRiskPositionMoney(),Math.max(0,account*0.1-openRiskMoney()));
 const lot=roundLot(target/(distance*CONTRACT));
 return lot+1e-9>=MINLOT?lot:null;
}
function closePos(pos,ts,bid,ask,why){
 const currentExit=pos.side==='BUY'?bid:ask;
 // Do not assume a favorable price improvement beyond a TP limit.
 const exit=why==='TP'?pos.tp:currentExit;
 const profit=(exit-pos.fill)*(pos.side==='BUY'?1:-1)*CONTRACT*pos.lot;
 account+=profit;peak=Math.max(peak,account);ddMax=Math.max(ddMax,(peak-account)/peak*100);
 const out={engine:pos.engine,key:pos.key,side:pos.side,order_type:pos.order_type,
  signalled_at:pos.signalled_at,filled_at:pos.filled_at,closed_at:ts,entry:pos.fill,
  sl:pos.sl,tp:pos.tp,exit,lot:pos.lot,close_reason:why,pnl:Number(profit.toFixed(2)),
  r_multiple:Number((profit/(Math.abs(pos.fill-pos.sl)*CONTRACT*pos.lot)).toFixed(4))};
 closed.push(out);activity.push({ts,event:'CLOSE',...out});
 positions.splice(positions.indexOf(pos),1);
}
function tickExit(ts,bid,ask){
 for(const pos of [...positions]){
  if(pos.side==='BUY'){
   if(bid<=pos.sl)closePos(pos,ts,bid,ask,'SL');
   else if(bid>=pos.tp)closePos(pos,ts,bid,ask,'TP');
  }else{
   if(ask>=pos.sl)closePos(pos,ts,bid,ask,'SL');
   else if(ask<=pos.tp)closePos(pos,ts,bid,ask,'TP');
  }
 }
}
function fillEvent(ev,ts,bid,ask){
 const fill=ev.side==='BUY'?ask:bid;
 const lot=canOpen(ev,fill);
 if(lot===null){rejected.risk++;activity.push({ts,event:'SKIP_RISK',engine:ev.engine,key:ev.key});return;}
 const pos={...ev,fill,filled_at:ts,lot,tp:ev.engine==='R2'?ev.tp2:ev.tp1};
 positions.push(pos);firstTradeTs??=ts;lastTradeTs=ts;
 activity.push({ts,event:'FILL',engine:ev.engine,key:ev.key,order_type:ev.order_type,side:ev.side,fill,sl:ev.sl,tp:pos.tp,lot});
}
function tickProcess(ts,bid,ask){
 tickExit(ts,bid,ask);
 let retained=[];
 for(const ev of pending){
  if(ts>ev.expires){activity.push({ts,event:'EXPIRE',engine:ev.engine,key:ev.key});continue;}
  const triggered=ev.order_type==='BUY_LIMIT'?ask<=ev.entry:
   ev.order_type==='SELL_LIMIT'?bid>=ev.entry:
   ev.order_type==='BUY_STOP'?ask>=ev.entry:
   ev.order_type==='SELL_STOP'?bid<=ev.entry:false;
  if(!triggered){retained.push(ev);continue;}
  if(positionsFor(ev.engine)>0){rejected.overlap++;activity.push({ts,event:'SKIP_OVERLAP',engine:ev.engine,key:ev.key});continue;}
  fillEvent(ev,ts,bid,ask);
 }
 pending=retained;
 tickExit(ts,bid,ask);
}
function signalAt(t,bid,ask){
 const snap=snapshot(t,bid,ask);
 if(snap.H1.length<119||snap.M30.length<119||snap.M5.length<60||snap.M15.length<60)return;
 const preview=ICT.previewSnapshot(snap);
 evalCount++;
 for(const [engine,tf,seconds] of [['R1','M5',300],['R2','M15',900]]){
  const p=sidePlan(snap,preview,tf,seconds);
  nReason[engine][p.reason]=(nReason[engine][p.reason]||0)+1;
  if(!p.allowed)continue;
  if(seenKeys[engine].has(p.setup_key))continue;
  seenKeys[engine].add(p.setup_key);
  nOrders[engine][p.order_type]=(nOrders[engine][p.order_type]||0)+1;
  const ev={engine,key:p.setup_key,signalled_at:t,side:p.side,order_type:p.order_type,
   entry:p.entry,sl:p.sl,tp1:p.tp1,tp2:p.tp2,score:p.score,
   expires:t+p.expiry_hours*3600};
  candidates.push(ev);
  if(![ev.entry,ev.sl,ev.tp1,ev.tp2].every(x=>Number.isFinite(x)&&x>0)){
   rejected.nonviable++;continue;
  }
  if(['BUY','SELL'].includes(ev.order_type)){
   if(positionsFor(engine)>0){rejected.overlap++;continue;}
   fillEvent(ev,t,bid,ask);
  }else if(['BUY_LIMIT','SELL_LIMIT','BUY_STOP','SELL_STOP'].includes(ev.order_type)){
   if(pending.some(x=>x.engine===engine)){rejected.overlap++;continue;}
   pending.push(ev);activity.push({ts:t,event:'PENDING',engine,key:ev.key,order_type:ev.order_type,entry:ev.entry});
  }else rejected.nonviable++;
 }
}

const rl=createInterface({input:fs.createReadStream(ticksPath,{encoding:'utf8'}),crlfDelay:Infinity});
let prevMs=-1;
for await(const line of rl){
 if(line.startsWith('time_msc')||!line.trim())continue;
 const row=line.split(',');const ms=Number(row[0]),bid=Number(row[1]),ask=Number(row[2]);
 if(!(Number.isSafeInteger(ms)&&Number.isFinite(bid)&&Number.isFinite(ask)&&ask>=bid&&ms>=prevMs))throw Error('Bad/unsorted tick');
 prevMs=ms;tickCount++;const t=Math.floor(ms/1000);
 windowFirst??=t;windowLast=t;
 tickProcess(t,bid,ask);
 const bar=Math.floor(t/300)*300;
 if(lastBar===-1){lastBar=bar;continue;}
 if(bar!==lastBar){
  lastBar=bar;
  // Only CLOSED candles feed ICT. First tick of bar is both the decision moment and earliest fill.
  signalAt(t,bid,ask);
 }
}
// Mark-to-market of any open positions; no fabricated TP/SL after last observed quote.
const result={scope:'OFFLINE_RESEARCH_NOT_MT5_TESTER',source_worker:'USER_UPLOADED_H',
 disclaimer:'MT5 EA H1 broker routing/active manager/news/calendar/session/margin NOT fully modeled; 100 oz contract ASSUMED; ignore as claim of profitability.',
 data_time_window_unix:[windowFirst,windowLast],tick_count:tickCount,decision_instants:evalCount,
 original_balance:INITIAL,ending_balance:account,net_closed_pnl:Number((account-INITIAL).toFixed(2)),
 maximum_closed_equity_drawdown_pct:Number(ddMax.toFixed(2)),
 candidate_count:{R1:seenKeys.R1.size,R2:seenKeys.R2.size},
 candidate_order_types:nOrders,
 signal_reasons:Object.fromEntries(Object.entries(nReason).map(([k,v])=>[k,Object.entries(v).sort((a,b)=>b[1]-a[1]).slice(0,15)])),
 open_positions:positions.length,pending_orders:pending.length,closed_trade_count:closed.length,
 closed_trades_by_engine:Object.fromEntries(['R1','R2'].map(k=>[k,closed.filter(p=>p.engine===k).length])),
 closed_trade_wins:closed.filter(x=>x.pnl>0).length,closed_trade_losses:closed.filter(x=>x.pnl<0).length,
 total_positive_pnl:Number(closed.filter(x=>x.pnl>0).reduce((s,x)=>s+x.pnl,0).toFixed(2)),
 total_negative_pnl:Number(closed.filter(x=>x.pnl<0).reduce((s,x)=>s+x.pnl,0).toFixed(2)),
 rejected,research_assumptions:{contract_size_oz:CONTRACT,account_risk_pct_per_engine:RISK,combined_risk_cap_pct:10,min_lot:MINLOT,lot_step:STEP,
  max_lot:MAXLOT,commission_swap_slippage:'NOT_MODELED',spread:'ACTUAL BID/ASK QUOTES',
  entry_timing:'FIRST TICK AFTER CLOSED M5 BAR',historical_news_gate:'NOT_MODELED',
  r1_exit:'WORKER TP1',r2_exit:'WORKER TP2',active_manager:'NOT_MODELED',
  r1_scalp_SL_override:'NOT_MODELED; uses Worker M5 SL rather than H1 local-pivot tightening'}};
fs.writeFileSync(path.join(OUT,'summary.json'),JSON.stringify(result,null,2)+'\n');
function csvFor(data){if(!data.length)return '';const keys=[...new Set(data.flatMap(Object.keys))];return [keys.join(','),...data.map(x=>keys.map(k=>JSON.stringify(x[k]??'')).join(','))].join('\n')+'\n';}
fs.writeFileSync(path.join(OUT,'candidates.csv'),csvFor(candidates));
fs.writeFileSync(path.join(OUT,'closed_trades.csv'),csvFor(closed));
const tsvColumns=['signalled_at','engine','key','side','order_type','entry','sl','tp1','tp2','expires'];
fs.writeFileSync(path.join(OUT,'signals.tsv'),
 tsvColumns.join('\t')+'\n'+candidates.map(c=>tsvColumns.map(k=>String(c[k])).join('\t')).join('\n')+(candidates.length?'\n':''));
fs.writeFileSync(path.join(OUT,'events.csv'),csvFor(activity));
console.log(JSON.stringify({tick_count:result.tick_count,decision_instants:result.decision_instants,
 candidate_count:result.candidate_count,closed_trades:result.closed_trade_count,ending_balance:result.ending_balance,
 closed_pnl:result.net_closed_pnl,rejected,open:positions.length,pending:pending.length},null,2));
