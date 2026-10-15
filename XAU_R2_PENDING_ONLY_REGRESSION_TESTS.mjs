// Run on Node 22+: node XAU_R2_PENDING_ONLY_REGRESSION_TESTS.mjs
// Pure offline tests. No Cloudflare deployment, API secrets or MT5 orders.
import assert from "node:assert/strict";
import worker, {
  __testR2Candidate as plan,
  __testPendingPlacement as placement
} from "./XAU_Worker_R2_v2_5_PENDING_ONLY_STAGING.js";

const live={ask:106.3,bid:106.1,spread_points:20,market_age_seconds:5};
const make=(overrides,quote=live)=>plan({
  score:85,allowed:true,expiry_hours:8,
  strategy:"PULLBACK_BUY",side:"BUY",order_type:"BUY_LIMIT",
  pending_context:true,entry:quote.ask,sl:80,tp1:138,tp2:150,
  zone_low:100,zone_high:110,notes:[],...overrides
},quote);
let count=0;
function test(name, fn){fn();count++;console.log("PASS "+name);}

test("BUY touches zone => deeper BUY_LIMIT not market",()=>{
  const x=make({});
  assert.equal(x.order_type,"BUY_LIMIT");assert.equal(x.entry,102);
  assert.equal(x.allowed,true);assert.equal(x.pending_viable,true);
});
test("SELL touches zone => upper SELL_LIMIT not market",()=>{
  const x=make({
    side:"SELL",strategy:"PULLBACK_SELL",order_type:"SELL_LIMIT",
    entry:103.7,sl:122,tp1:82,tp2:79
  },{ask:103.9,bid:103.7});
  assert.equal(x.order_type,"SELL_LIMIT");assert.equal(x.entry,108);
  assert.equal(x.allowed,true);assert.equal(x.pending_viable,true);
});
test("BUY too close to limit => wait",()=>{
  const x=make({}, {ask:101.5,bid:101.3});
  assert.equal(x.allowed,false);
  assert.equal(x.pending_only_reason,"WAIT_PRICE_MOVE_AWAY_FOR_PENDING");
});
test("SELL too close to limit => wait",()=>{
  const x=make({
    side:"SELL",order_type:"SELL_LIMIT",sl:122,tp1:82,tp2:79
  }, {ask:109.4,bid:109.2});
  assert.equal(x.allowed,false);
  assert.equal(x.pending_only_reason,"WAIT_PRICE_MOVE_AWAY_FOR_PENDING");
});
test("BUY or SELL market type cannot enter candidate output",()=>{
  for(const type of ["BUY","SELL"]){
    const x=make({order_type:type});
    assert.equal(x.allowed,false);assert.equal(x.order_type,"NONE");
    assert.equal(x.pending_only_reason,"MARKET_EXECUTION_FORBIDDEN");
    assert.equal(placement(type,104,live).allowed,false);
  }
});
test("invalid SL / insufficient R:R => reject",()=>{
  assert.equal(make({sl:105}).allowed,false);
  assert.equal(make({sl:70,tp1:108,tp2:115}).allowed,false);
});
test("STOP orders remain possible when structurally valid",()=>{
  assert.equal(make({pending_context:false,order_type:"BUY_STOP",entry:109,sl:96,tp1:134,tp2:145}).allowed,true);
  assert.equal(make({side:"SELL",pending_context:false,order_type:"SELL_STOP",entry:98,sl:111,tp1:70,tp2:60}).allowed,true);
});
const now=Math.floor(Date.now()/1000);
const candles=(seconds)=>Array.from({length:210},(_,i)=>{
  const o=4145+Math.sin(i/15)*8+i*.01;
  return{t:now-(211-i)*seconds,o,h:o+1.8,l:o-1.7,c:o+Math.sin(i/5)*.8,v:120};
});
const market=(allow)=>({
  symbol:"XAUUSD.s",generated_at:now,
  broker_server_day_of_week:4,broker_server_seconds_of_day:70000,
  bid:4152.12,ask:4152.30,spread_points:18,point:.01,digits:2,
  M1:candles(60),M5:candles(300),M15:candles(900),
  M30:candles(1800),H1:candles(3600),
  news_policy:{schema:1,source:"MT5_USD_CALENDAR",enabled:true,
    risk:allow?"NONE":"CRITICAL",decision:allow?"ALLOW":"BLOCK",
    entry_allowed:allow,calendar_healthy:true,
    status:allow?"NEWS CLEAR":"NEWS BLOCK CRITICAL CPI",checked_at_server:now}
});
let row={payload:JSON.stringify(market(true)),updated_at:Date.now()};
const env={WRITE_TOKEN:"OFFLINE_TEST",DB:{prepare(){
  return{async first(){return row;},bind(){return this;}};
}}};
async function read(path){
  const req=new Request("https://offline.test"+path,{
    headers:path.includes("zones")?{"X-Bridge-Key":env.WRITE_TOKEN}:{}
  });
  const reply=await worker.fetch(req,env);
  assert.equal(reply.status,200,path);
  return reply.json();
}
const health=await read("/health");
test("health advertises R2 pending-only",()=>{
  assert.equal(health.r2_pending_only_mode,true);
  assert.equal(health.r2_market_execution_enabled,false);
});
for(const endpoint of ["/r2","/r2/setup"]){
  const result=await read(endpoint);
  test(endpoint+" returns exclusively pending candidates",()=>{
    assert.equal(result.pending_only_mode,true);
    assert.ok(["NONE","BUY_LIMIT","SELL_LIMIT","BUY_STOP","SELL_STOP"]
      .includes(result.setup.order_type));
    for(const candidate of result.selector?.candidates??[]){
      assert.ok(["NONE","BUY_LIMIT","SELL_LIMIT","BUY_STOP","SELL_STOP"]
        .includes(candidate.order_type));
    }
    if(result.setup.allowed)assert.equal(result.setup.pending_viable,true);
  });
}
row={payload:JSON.stringify(market(false)),updated_at:Date.now()};
const newsBlocked=await read("/r2");
test("critical news always blocks execution",()=>{
  assert.equal(newsBlocked.news_gate.entry_allowed,false);
  assert.equal(newsBlocked.execution_allowed,false);
});
console.log("ALL "+count+" PENDING-ONLY REGRESSION CHECKS PASSED");
