#!/usr/bin/env node
"use strict";
// Historical Worker SIGNAL-DECISION replay only. NEVER sends orders.
// Reads exact original Worker JS offline, no Cloudflare or external network.
const fs=require("node:fs");
const vm=require("node:vm");
const readline=require("node:readline");
const path=require("node:path");

if(process.argv.length!==5){
 console.error("Usage: node XAU_Worker_Snapshot_Replay_v1.cjs <Worker_v2_8.js> <snapshots.jsonl> <signals.csv>");
 process.exit(2);
}
const [workerPath,inPath,outPath]=process.argv.slice(2);
if(path.resolve(inPath)===path.resolve(outPath))throw Error("Output must differ from input");
const workerRaw=fs.readFileSync(workerPath,"utf8");
if(!workerRaw.includes('R1_WATCH_R2_SWING_V2_8_EA_DIRECT_R2_ONLY'))throw Error("Refusing non-v2.8 Worker code");
if(!workerRaw.includes("async function calculateR2Swing") ||
   !workerRaw.includes("async function calculateRegimeR1"))throw Error("Missing expected Worker decision engines");
const source=workerRaw
 .replace(/\bexport\s+default\b/,"const __workerDefault =")
 .replace(/\bexport\s*\{[^}]*\}\s*;/gm,"")
 + "\n;globalThis.__replayAPI={calculateRegimeR1,calculateAutoDecisionZonesR1,calculateR2Swing};";
let simulatedMs=0;
class ReplayDate extends Date{
 constructor(...args){super(...(args.length?args:[simulatedMs]));}
 static now(){return simulatedMs;}
}
const context=vm.createContext({
 Date:ReplayDate,console,URL,URLSearchParams,
 TextEncoder,TextDecoder,crypto:undefined
});
vm.runInContext(source,context,{filename:path.basename(workerPath),timeout:10000});
const api=context.__replayAPI;
if(!api)throw Error("Worker functions unavailable");
const fields=[
 "generated_at","broker_time_iso","symbol","regime","r1_strategy",
 "r1_zone_type","r1_watch_only","r1_buy_low","r1_buy_high",
 "r1_sell_low","r1_sell_high","r2_market_state","r2_strategy",
 "r2_allowed_structural","r2_pending_viable","r2_order_type",
 "r2_side","r2_score","r2_entry","r2_sl","r2_tp1","r2_tp2",
 "r2_pending_reason","calendar_parity","execution_parity","error"
];
const csv=v=>{
 if(v===null||v===undefined)return "";
 const str=String(v);
 return /[,"\r\n]/.test(str)?'"'+str.replace(/"/g,'""')+'"':str;
};
const out=fs.createWriteStream(outPath,{encoding:"utf8"});
out.write(fields.join(",")+"\n");
let total=0,success=0,fail=0,r1Trading=0,r2Candidates=0,firstAt=0,lastAt=0;
const lines=readline.createInterface({input:fs.createReadStream(inPath,{encoding:"utf8"}),crlfDelay:Infinity});
(async()=>{
 for await(const line of lines){
  if(!line.trim())continue;
  total++;let row={calendar_parity:"NO_HISTORICAL_CALENDAR",execution_parity:"NOT_SIMULATED"};
  try{
   const snap=JSON.parse(line);
   const time=Number(snap.generated_at);
   if(!Number.isFinite(time)||time<=0)throw Error("Invalid generated_at");
   if(firstAt===0)firstAt=time;lastAt=time;
   simulatedMs=time*1000;row.generated_at=time;
   row.broker_time_iso=new Date(simulatedMs).toISOString();
   row.symbol=String(snap.symbol||"");
   if(!["H1","M30","M15","M5","M1"].every(tf=>Array.isArray(snap[tf])&&snap[tf].length>=60))
     throw Error("Insufficient timeframe history (need >=60 bars each)");
   if(!snap.news_policy || snap.news_policy.source!=="HISTORICAL_CALENDAR_NOT_REPLAYED")
     throw Error("Refusing snapshots with unverified/reconstructed historical news");
   const env={DB:{prepare:()=>({first:async()=>({
    payload:JSON.stringify(snap), updated_at:time*1000
   })})}};
   const r1=await api.calculateRegimeR1(env);
   const zones=api.calculateAutoDecisionZonesR1(r1);
   const r2=await api.calculateR2Swing(env);
   const setup=r2.setup||{};
   Object.assign(row,{
    regime:r1.regime,r1_strategy:r1.strategy,r1_zone_type:zones.zone_type,
    r1_watch_only:!!zones.watch_only,
    r1_buy_low:zones.buy_low,r1_buy_high:zones.buy_high,
    r1_sell_low:zones.sell_low,r1_sell_high:zones.sell_high,
    r2_market_state:r2.market_state,r2_strategy:setup.strategy,
    r2_allowed_structural:!!setup.allowed,
    r2_pending_viable:!!setup.pending_viable,
    r2_order_type:setup.order_type,r2_side:setup.side,r2_score:setup.score,
    r2_entry:setup.entry,r2_sl:setup.sl,r2_tp1:setup.tp1,
    r2_tp2:setup.tp2,r2_pending_reason:setup.pending_only_reason
   });
   if(!zones.watch_only)r1Trading++;
   if(setup.allowed)r2Candidates++;
   success++;
  }catch(e){fail++;row.error=e.message||String(e);}
  out.write(fields.map(f=>csv(row[f])).join(",")+"\n");
 }
 out.end();
 console.log(JSON.stringify({
  records:total,decision_evaluated:success,rejected:fail,
  r1_nonwatch_snapshots:r1Trading,r2_allowed_candidate_snapshots:r2Candidates,
  first_broker_epoch:firstAt,last_broker_epoch:lastAt,
  source:"Worker v2.8 ORIGINAL functions",
  warning:"NO TRADE FILLS, NO historical news, NO EA M5 READY parity, NO profitability claim"
 },null,2));
 if(fail)process.exitCode=1;
})().catch(e=>{out.end();console.error(e);process.exitCode=1;});
