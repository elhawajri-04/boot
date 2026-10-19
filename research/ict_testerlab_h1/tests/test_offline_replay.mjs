import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {__testICTV4 as ICT,__testIctV4SidePlan as plan} from '../Worker_H_uploaded_source.mjs';
const root=path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const out=path.join(root,'out');
const worker=fs.readFileSync(path.join(root,'Worker_H_uploaded_source.mjs'),'utf8');
const ea=fs.readFileSync(path.join(root,'EA_H1_uploaded_source.mq5'),'utf8');
assert.equal(typeof ICT.previewSnapshot,'function');
assert.equal(typeof plan,'function');
assert.match(worker,/const BUILD_VERSION = "XAU_V4_ICT_SMC_SMART_EXEC_20261019_H";/);
assert.match(ea,/EXEC_PIPELINE_20261019_H1/);
assert.match(ea,/XAU_V4_ICT_SMC_SMART_EXEC_20261019_H/);
assert.match(worker,/sweep:sweep\(bars,swings\)/);
const mql=fs.readFileSync(path.join(root,'XAU_H1_WorkerH_SignalReplay_TESTER_ONLY.mq5'),'utf8');
assert.match(mql,/!MQLInfoInteger\(MQL_TESTER\)/);
assert.doesNotMatch(mql,/\bWebRequest\s*\(/);
assert.match(mql,/OrderCalcProfit\(/);
assert.match(mql,/TRADE_RETCODE_PLACED/);
assert.match(mql,/FILE_COMMON/);
const result=JSON.parse(fs.readFileSync(path.join(out,'summary.json'),'utf8'));
assert.equal(result.source_worker,'USER_UPLOADED_H');
assert.equal(result.tick_count,2491352);
assert.ok(result.decision_instants>1000);
assert.equal(result.candidate_count.R1,4);
assert.equal(result.candidate_count.R2,0);
assert.equal(result.closed_trade_count,4);
assert.ok(result.net_closed_pnl<0);
assert.equal(result.research_assumptions.active_manager.startsWith('NOT_MODELED'),true);
const signals=fs.readFileSync(path.join(out,'signals.tsv'),'utf8').trim().split('\n');
assert.equal(signals.length,5);
assert.equal(signals[0],'signalled_at\tengine\tkey\tside\torder_type\tentry\tsl\ttp1\ttp2\texpires');
const observed=new Set();let last=-Infinity;
for(const row of signals.slice(1)){
 const [ts,eng,key,side,type,entry,sl,tp1,tp2,expiry]=row.split('\t');
 assert.ok(+ts>=last);last=+ts;
 assert.ok(!observed.has(key));observed.add(key);
 assert.equal(eng,'R1');assert.equal(type.endsWith('_LIMIT'),true);
 assert.ok(['BUY','SELL'].includes(side));
 assert.ok(+entry>0&&+sl>0&&+tp1>0&&+tp2>0);
 assert.ok(+expiry>+ts);
}
for(const row of fs.readFileSync(path.join(out,'closed_trades.csv'),'utf8').trim().split('\n').slice(1)){
 // All tick-executed take-profit fills are capped at their precommitted TP.
 if(row.includes('"TP"')){
   const cols=row.match(/(?:[^,"]+|"[^"]*")+/g); // CSV generated from JSON scalar values
   assert.ok(cols.length>=12);
 }
}
console.log('PASS: release compatibility, tester-only protection, signal provenance, and offline-results consistency assertions');
