#!/usr/bin/env node
// Converts Phase3 RESEARCH events into a timestamp-ordered replay command stream.
// The backtest consumer MUST apply one command only when TimeCurrent >= time_server.
// Do not treat ARM as a fill. No future outcome prices are exported.
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const COLUMNS=['time_server','action','event_id','engine','side','order_type','zone_low','zone_high','retest_low','retest_high','limit_price','distal_invalidation','expiry_server','reason'];
export function buildCommands(csvText){
 const lines=csvText.trim().split(/\r?\n/);const head=lines.shift()?.split(',');
 // Phase 3 event fields in this module's own format do not have comma-containing notes on existing data.
 if(!head||head[0]!=='event_id'||!head.includes('outcome_time'))throw Error('Incorrect event CSV header');
 const commands=[],seen=new Set();
 for(const line of lines){
  if(!line)continue;
  // The CSV writer quotes notes if commas appear; parse simple CSV correctly.
  const cells=[];let buf='',quoted=false;
  for(let i=0;i<line.length;i++){
   if(line[i]==='"' && quoted && line[i+1]==='"'){buf+='"';i++;}
   else if(line[i]==='"')quoted=!quoted;
   else if(line[i]===','&&!quoted){cells.push(buf);buf='';}else buf+=line[i];
  }
  cells.push(buf);if(cells.length!==head.length)throw Error('Malformed Phase3 event row');
  const e=Object.fromEntries(head.map((k,i)=>[k,cells[i]]));
  const created=Number(e.event_time),expires=Number(e.expiry_time),end=Number(e.outcome_time);
  if(!Number.isSafeInteger(created)||!Number.isSafeInteger(expires)||expires<=created||!e.event_id||seen.has(e.event_id))throw Error('Invalid or duplicate event');
  seen.add(e.event_id);
  // Event rejection at timestamp of ARM is deliberately NOT an executable command.
  if(['NO_VALUE_ZONE_OVERLAP','NO_FRESH_ORIGIN_QUOTE','NOT_OUTSIDE_RETEST_ZONE'].includes(e.outcome))continue;
  if(!['R1','R2'].includes(e.engine)||!['BUY','SELL'].includes(e.side))throw Error('Invalid direction');
  const numeric=['zone_low','zone_high','retest_low','retest_high','placement_entry','invalidation'];
  for(const k of numeric)if(!Number.isFinite(Number(e[k]))||e[k]==='')throw Error('Invalid numeric '+k);
  if(!(Number(e.retest_low)<Number(e.retest_high)))throw Error('Invalid overlap');
  const arm=[created,'ARM',e.event_id,e.engine,e.side,e.engine==='R2'?e.placement_type:'RETEST_MARKET',e.zone_low,e.zone_high,e.retest_low,e.retest_high,e.placement_entry,e.invalidation,expires,'CONFIRMED_SMC_EVENT'];
  if(!['BUY_LIMIT','SELL_LIMIT'].includes(e.placement_type))throw Error('Phase3 only supports LIMIT research for R2');
  commands.push(arm);
  if(['HTF_CHANGED_OR_MIXED','STRUCTURAL_INVALIDATION_CLOSE','SUPERSEDED_BY_NEW_EVENT','EXPIRED'].includes(e.outcome)){
   if(end<created)throw Error('Future cancellation precedes ARM');
   commands.push([end,'CANCEL',e.event_id,e.engine,e.side,'','','','','','','','',''+e.outcome]);
  }
 }
 // Causal stream. Events at identical timestamp get cancellation before a fresh ARM.
 commands.sort((a,b)=>a[0]-b[0]||({CANCEL:0,ARM:1}[a[1]]-{CANCEL:0,ARM:1}[b[1]])||a[2].localeCompare(b[2]));
 return [COLUMNS.join(','),...commands.map(row=>row.join(','))].join('\n')+'\n';
}
const main=process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url);
if(main){
 if(process.argv.length!==4){console.error('Usage: node export_causal_commands.mjs phase3_events.csv phase3_commands.csv');process.exit(2);}
 const text=buildCommands(fs.readFileSync(process.argv[2],'utf8'));
 fs.writeFileSync(process.argv[3],text,'utf8');
 console.log('Prepared '+(text.trim().split('\n').length-1)+' causal commands without future outcome prices');
}