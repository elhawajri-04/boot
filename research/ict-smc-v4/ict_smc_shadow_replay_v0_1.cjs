#!/usr/bin/env node
"use strict";
// SHADOW no-order evaluation on historical MT5 JSONL exported snapshots.
// Usage: node ict_smc_shadow_replay_v0_1.cjs snapshot.jsonl result.csv
const fs=require("node:fs");
const readline=require("node:readline");
const {previewSnapshot}=require("./ict_smc_patterns_v0_1.cjs");
if(process.argv.length!==4){
 console.error("Usage: node ict_smc_shadow_replay_v0_1.cjs snapshots.jsonl result.csv");
 process.exit(2);
}
const [source,output]=process.argv.slice(2);
if(require("node:path").resolve(source)===require("node:path").resolve(output)){
 throw new Error("Output must differ from input");
}
const columns=["generated_at","symbol","htf_bias","r1_allowed","r1_reason",
               "r1_side","r1_zone_low","r1_zone_high","r1_structure",
               "r2_allowed","r2_reason","r2_side","r2_zone_low",
               "r2_zone_high","r2_structure","error"];
const csv=x=>{
 const v=String(x===null||x===undefined?"":x);
 return /[,"\r\n]/.test(v)?'"'+v.replace(/"/g,'""')+'"':v;
};
const stream=fs.createWriteStream(output);
stream.write(columns.join(",")+"\n");
let total=0,errors=0,approve1=0,approve2=0;
const input=readline.createInterface({input:fs.createReadStream(source),crlfDelay:Infinity});
(async()=>{
 for await(const line of input){
  if(!line.trim())continue;
  total++;
  let record={};
  try{
   const snapshot=JSON.parse(line);
   const state=previewSnapshot(snapshot);
   record={
    generated_at:snapshot.generated_at,symbol:snapshot.symbol,
    htf_bias:state.htf_bias,
    r1_allowed:state.r1.allowed,r1_reason:state.r1.reason,
    r1_side:state.r1.direction,r1_zone_low:state.r1.zone?.low,
    r1_zone_high:state.r1.zone?.high,r1_structure:state.r1.structure,
    r2_allowed:state.r2.allowed,r2_reason:state.r2.reason,
    r2_side:state.r2.direction,r2_zone_low:state.r2.zone?.low,
    r2_zone_high:state.r2.zone?.high,r2_structure:state.r2.structure
   };
   if(state.r1.allowed)approve1++;
   if(state.r2.allowed)approve2++;
  }catch(e){errors++;record.error=String(e.message||e);}
  stream.write(columns.map(k=>csv(record[k])).join(",")+"\n");
 }
 stream.end();
 console.log(JSON.stringify({snapshots:total,errors,
   r1_eligible_snapshots:approve1,r2_eligible_snapshots:approve2,
   warning:"NOT A TRADE BACKTEST. Eligible snapshots are NOT independent orders; PnL NOT computed. Research branch only."},null,2));
 if(errors)process.exitCode=1;
})().catch(e=>{stream.end();console.error(e);process.exitCode=1;});
