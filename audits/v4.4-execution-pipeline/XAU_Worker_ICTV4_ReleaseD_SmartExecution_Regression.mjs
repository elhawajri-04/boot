// Run from this directory: node XAU_Worker_ICTV4_ReleaseD_SmartExecution_Regression.mjs
// Pure simulation tests: no Worker HTTP/D1, no broker calls or profitability claims.
import assert from "node:assert/strict";
import {
 __testICTV4 as ICTV4,
 __testIctV4SidePlan as sidePlan,
 __testSmartR2Audit as audit
} from "./XAU_Worker_ICTV4_Research_ValueRetest.js";

const NOW=1800000000;
function bars(tf,slope,n=120) {
 return Array.from({length:n},(_,i)=>{
  const p=3000+slope*i+4*Math.sin(2*Math.PI*i/8);
  return {t:NOW-(n-i)*tf,o:p-.2,c:p+.2,h:p+1,l:p-1};
 });
}
function snapshot(dir="BUY") {
 const d=dir==="BUY"?.25:-.25;
 return {generated_at:NOW,H1:bars(3600,d),M30:bars(1800,d),
   M15:bars(900,d),M5:bars(300,d),bid:3000,ask:3000.1,point:.01};
}
function ready(dir="BUY"){
 const m=snapshot(dir),p=ICTV4.previewSnapshot(m);
 const a=ICTV4.analyzeTF(m.M15,NOW,900),eq=a.value.equilibrium;
 const zone=dir==="BUY"?
  {low:eq-4,high:eq-2,distal:eq-4,t:123}:
  {low:eq+2,high:eq+4,distal:eq+4,t:123};
 p.r2={allowed:true,zone,breakout:{t:111},reason:"ICT_SMC_CONFLUENCE"};
 return {m,p,eq};
}
let passed=0;
function test(name,fn){fn();passed++;console.log("PASS",name)}
test("BUY MARKET inside discount zone + closed bullish M15 bar",()=>{
 const {m,p,eq}=ready("BUY");m.bid=eq-3.1;m.ask=eq-3;
 const x=sidePlan(m,p,"M15",900);
 assert.equal(x.allowed,true);assert.equal(x.order_type,"BUY");
});
test("SELL MARKET inside premium zone + closed bearish M15 bar",()=>{
 const {m,p,eq}=ready("SELL");
 const b=m.M15.at(-1);b.o=b.c+.2;b.h=b.o+1;b.l=b.c-1;
 m.bid=eq+3;m.ask=eq+3.1;
 const x=sidePlan(m,p,"M15",900);
 assert.equal(x.allowed,true);assert.equal(x.order_type,"SELL");
});
test("Limit BUY and SELL when away from approved return zone",()=>{
 for(const dir of ["BUY","SELL"]){
  const {m,p,eq}=ready(dir);
  m.bid=dir==="BUY"?eq+4.9:eq-5.1;
  m.ask=dir==="BUY"?eq+5:eq-5;
  const x=sidePlan(m,p,"M15",900);
  assert.equal(x.allowed,true);assert.equal(x.order_type,dir+"_LIMIT");
 }
});
test("Stop BUY and SELL inside zone before confirmed candle",()=>{
 for(const dir of ["BUY","SELL"]){
  const {m,p,eq}=ready(dir);
  const b=m.M15.at(-1);
  if(dir==="BUY"){b.o=b.c+.2;b.h=b.o+1;b.l=b.c-1}
  m.bid=dir==="BUY"?eq-3.1:eq+3;
  m.ask=dir==="BUY"?eq-3:eq+3.1;
  const x=sidePlan(m,p,"M15",900);
  assert.equal(x.allowed,true);assert.equal(x.order_type,dir+"_STOP");
 }
});
test("Identical BOS + zone key survives Market to Limit change",()=>{
 const {m,p,eq}=ready();
 m.bid=eq-3.1;m.ask=eq-3;
 const market=sidePlan(m,p,"M15",900);
 m.bid=eq+4.9;m.ask=eq+5;
 const limit=sidePlan(m,p,"M15",900);
 assert.equal(market.setup_key,limit.setup_key);
 assert.equal(limit.order_type,"BUY_LIMIT");
});
test("Conflicting H1 and M30 still blocks R2 swing",()=>{
 const {m}=ready();m.M30=bars(1800,-.25);
 const model=ICTV4.previewSnapshot(m);
 assert.equal(model.r2_bias,"MIXED");
 assert.equal(model.r1_bias,"SELL");
 assert.equal(sidePlan(m,model,"M15",900).allowed,false);
});
test("R2 audit recognizes SMART Market and Pending READY",()=>{
 for(const type of ["BUY","BUY_LIMIT","BUY_STOP"]){
  const q=audit({market_state:"ICT_SMC_BUY",setup:{
    smart_execution_mode:true,allowed:true,
    strategy:"ICT_SMC_FVG_OB_BUY",side:"BUY",order_type:type,
    score:85,rr_tp1:1.6,entry:3000,sl:2990,tp1:3016,
    execution_reason:"ICT_SMC_CONFIRMED"
  }},{});
  assert.equal(q.status,"READY");assert.equal(q.allowed,true);
 }
});
test("R2 audit rejects wrong-direction and unapproved orders",()=>{
 for(const [type,allowed] of [["SELL",true],["NONE",false]]){
  const q=audit({market_state:"ICT_SMC_BUY",setup:{
    smart_execution_mode:true,allowed,
    strategy:"ICT_SMC_FVG_OB_BUY",side:"BUY",order_type:type,
    score:85,rr_tp1:1.6,entry:3000,sl:2990,tp1:3016,
    execution_reason:"NO_SMART_R2_SETUP"
  }},{});
  assert.equal(q.status,"WATCH");assert.equal(q.allowed,false);
 }
});
console.log("DONE",passed,"Smart R2 regression cases passed");
