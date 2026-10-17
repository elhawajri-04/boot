import assert from 'node:assert/strict';
import fs from 'node:fs';
import worker, {__testR2SmartSetupReady as ready, __testIctV4SidePlan as choose,
  __testSmartR2Audit as audit} from './XAU_Worker_SmartExec_E.js';

let count=0;
const pass=(label,condition) => {assert.ok(condition,label); count++;};
const make=(type,side='BUY')=>({
  allowed:true, smart_execution_mode:true, pending_only_mode:false,
  side, order_type:type, score:85, setup_score:85, rr_tp1:1.6,
  pending_viable:type.includes('_'),market_viable:!type.includes('_'),
  entry:3000, sl:side==='BUY'?2990:3010, tp1:side==='BUY'?3015:2985,
  execution_reason:'ICT_SMC_CONFIRMED',strategy:'ICT_SMC_FVG_OB',
});
for(const [side,types] of [['BUY',['BUY','BUY_LIMIT','BUY_STOP']],['SELL',['SELL','SELL_LIMIT','SELL_STOP']]]){
  for(const type of types)pass(`${type} ready`,ready(make(type,side)));
}
const good=make('BUY');
for(const [key,value] of [['allowed',false],['smart_execution_mode',false],['pending_only_mode',true],['market_viable',false],['setup_score',50],['rr_tp1',0.4],['entry',0],['sl',3010],['tp1',2980],['side','SELL'],['order_type','BUY_STOP_LIMIT']]){
  pass(`reject ${key}=${value}`,!ready({...good,[key]:value}));
}
pass('market viable mismatch rejected',!ready({...make('SELL','SELL'),market_viable:false}));
pass('pending viable mismatch rejected',!ready({...make('SELL_STOP','SELL'),pending_viable:false}));
pass('market audit green only with gate',audit({setup:make('BUY'),market:{news_gate:{entry_allowed:true},market_age_seconds:2}},null).allowed===true);
pass('news unknown audit blocked',audit({setup:make('BUY'),market:{news_gate:{entry_allowed:false},market_age_seconds:2}},null).allowed===false);
pass('stale feed audit blocked',audit({setup:make('BUY'),market:{news_gate:{entry_allowed:true},market_age_seconds:50}},null).allowed===false);

const now=Math.floor(Date.now()/1000);
function bars(seconds,bullish=true){
 const latest=Math.floor((now-5)/seconds)*seconds-seconds;
 return Array.from({length:125},(_,i)=>{
  const c=3000+Math.sin(i*.38)*7+Math.sin(i*.13)*2;
  const o=(i===124)?c+(bullish?-0.4:0.4):c+Math.sin(i)*.2;
  return {t:latest-(124-i)*seconds,o,h:Math.max(c,o)+1,l:Math.min(c,o)-1,c};
 });
}
for(const side of ['BUY','SELL']){
  const isBuy=side==='BUY';
  const b=bars(900,isBuy);
  const zone={low:isBuy?2985:3010,high:isBuy?2990:3015,t:b[85].t,distal:isBuy?2985:3015};
  const model={r2_bias:side,r2:{allowed:true,zone,breakout:{t:b[94].t}},htf_detail:{h1_bias:side,m30_bias:side}};
  const snapshot={generated_at:now,point:.01,M15:b,bid:isBuy?2987.5:3012.5,ask:isBuy?2987.5:3012.5};
  const market=choose(snapshot,model,'M15',900);
  pass(`${side} market routed`,market.allowed===true&&market.order_type===side);
  const bStop=bars(900,!isBuy);
  const stop=choose({...snapshot,M15:bStop},model,'M15',900);
  pass(`${side} stop routed`,stop.allowed===true&&stop.order_type===side+'_STOP');
  const away=choose({...snapshot,bid:isBuy?3002:2998,ask:isBuy?3002:2998},model,'M15',900);
  pass(`${side} limit routed`,away.allowed===true&&away.order_type===side+'_LIMIT');
  const blocked=choose(snapshot,{...model,r2:{...model.r2,allowed:false}},'M15',900);
  pass(`${side} cannot skip confluence`,blocked.allowed===false);
}
const marketSnapshot={
  generated_at:now,point:.01,bid:3000,ask:3000.2,spread_points:20,
  H1:bars(3600),M30:bars(1800),M15:bars(900),M5:bars(300),M1:bars(60),
  news_policy:{schema:1,enabled:true,calendar_healthy:true,entry_allowed:false,
    decision:'UNKNOWN',risk:'UNKNOWN',status:'TEST',checked_at_server:now}
};
const env={DB:{prepare(){return {async first(){return {payload:JSON.stringify(marketSnapshot),updated_at:Date.now()};}};}}};
const base='https://example.workers.dev';
const health=await(await worker.fetch(new Request(base+'/health'),env)).json();
pass('/health says Smart not Pending Only',health.r2_pending_only_mode===false&&health.r2_market_execution_enabled===true);
const r2=await(await worker.fetch(new Request(base+'/r2'),env)).json();
pass('/r2 is valid schema',r2.ok===true&&r2.pending_only_mode===false&&r2.setup.smart_execution_mode===true);
pass('/r2 unknown news blocks all orders',r2.execution_allowed===false);
const setup=await(await worker.fetch(new Request(base+'/r2/setup'),env)).json();
pass('/r2/setup same model',setup.ok===true&&setup.pending_only_mode===false&&setup.execution_allowed===false);
const ea=fs.readFileSync(new URL('./XAU_EA_SmartExec_E.mq5',import.meta.url),'utf8');
pass('EA has no demo-only telemetry input',!ea.includes('InpTelemetryOnlyStagingMode'));
pass('EA has automatic execution in OnTimer',/void OnTimer\(\)[\s\S]*?ProcessICT4Executors\(\);/.test(ea));
pass('EA has automatic execution in OnTick',/void OnTick\(\)[\s\S]*?ProcessICT4Executors\(\);/.test(ea));
pass('EA preserves 10% SL risk guard',ea.includes('InpEnableMaxSLRiskGuard = true') && ea.includes('InpMaxSLRiskPercent = 10.0'));
pass('EA preserves R1 and R2 separate risk inputs',ea.includes('InpAutoExecutorMaxSLRiskPercent = 5.0')&&ea.includes('InpR2AutoMaxSLRiskPercent = 5.0'));
pass('EA preserves broker SL TP validations',ea.includes('ValidateStops(side, currentPrice, sl, tp, stopError)'));
pass('EA supports all pending types', ['"BUY_LIMIT"','"SELL_LIMIT"','"BUY_STOP"','"SELL_STOP"'].every(x=>ea.includes(x)));
pass('EA explicitly requires Smart protocol',ea.includes('g_r2SmartProtocolOK =')&&ea.includes('"\\"pending_only_mode\\":false"'));
pass('R1 ATR local swing intact',ea.includes('BuildR1ScalpStop(side,realEntry,low,high,localStop,why)'));
pass('EA MARKET only with viability',ea.includes('!InpR2EnableMarketExecution || !g_r2MarketViable'));
console.log(`${count} Smart Execution tests passed, no broker orders sent.`);
