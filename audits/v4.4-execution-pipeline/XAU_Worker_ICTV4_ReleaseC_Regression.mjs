// Run from this directory: node XAU_Worker_ICTV4_ReleaseC_Regression.mjs
import assert from "node:assert/strict";
import { __testICTV4 as ICTV4, __testIctV4SidePlan as sidePlan } from "./XAU_Worker_ICTV4_Research_ValueRetest.js";
const generated_at=1800000000;
function candles(sec,slope=0,wave=4,n=120) {
 const a=[];
 for(let i=0;i<n;i++) {
  const mid=3000+slope*i+wave*Math.sin(2*Math.PI*i/8);
  a.push({t:generated_at-(n-i)*sec,o:mid-.2,c:mid+.2,h:mid+1,l:mid-1});
 }
 return a;
}
function snapshot(h1,m30,h1count=120) {
 return {generated_at,H1:candles(3600,h1,4,h1count),
  M30:candles(1800,m30),M15:candles(900,.25),
  M5:candles(300,-.25),bid:3000,ask:3000.1,point:.01};
}
const cases=[];
function test(name,fn){fn();cases.push(name);console.log("PASS:",name)}
test("Conflicting H1 BUY/M30 SELL does not automatically veto R1",()=>{
 const s=snapshot(.25,-.25),p=ICTV4.previewSnapshot(s);
 assert.equal(p.htf_detail.h1_bias,"BUY");
 assert.equal(p.htf_detail.m30_bias,"SELL");
 assert.equal(p.r1_bias,"SELL");
 assert.equal(p.r2_bias,"MIXED");
 assert.equal(p.htf_detail.r1_counter_h1,true);
 assert.notEqual(p.r1.reason,"WAIT_HTF_BIAS");
 assert.equal(p.r2.reason,"WAIT_HTF_BIAS");
 const r2=sidePlan(s,p,"M15",900);
 assert.equal(r2.allowed,false);
 assert.match(r2.reason,/WAIT_R2_HTF_ALIGNMENT/);
});
test("Aligned H1 and M30 give same bias to both engines",()=>{
 const p=ICTV4.previewSnapshot(snapshot(.25,.25));
 assert.equal(p.r1_bias,"BUY");assert.equal(p.r2_bias,"BUY");
});
test("Missing H1 history cannot allow either engine",()=>{
 const p=ICTV4.previewSnapshot(snapshot(.25,-.25,35));
 assert.equal(p.r1_bias,"MIXED");assert.equal(p.r2_bias,"MIXED");
});
test("Recent BOS survives 4 closed candles, expires at 3",()=>{
 const b=Array.from({length:16},(_,i)=>({t:i*300,o:10,c:10,h:11,l:9}));
 b[11].c=11;b[12].o=11;b[12].c=13;b[12].h=14;
 b[13].o=13;b[13].c=13;b[14].o=13;b[14].c=13;b[15].o=13;b[15].c=13;
 const swings={highs:[{index:6,price:12}],lows:[]};
 assert.equal(ICTV4.breakOfStructure(b,swings,"BUY",4)?.index,12);
 assert.equal(ICTV4.breakOfStructure(b,swings,"BUY",3),null);
});
test("Displacement requires sweep index < impulse index <= BOS",()=>{
 const b=Array.from({length:25},(_,i)=>({t:i*300,o:10,c:10.1,h:10.2,l:9.9}));
 b[22]={t:22*300,o:10,c:13,h:13.1,l:9.9};
 assert.equal(ICTV4.displacementInSequence(b,22,22,"BUY"),null);
 assert.equal(ICTV4.displacementInSequence(b,20,22,"SELL"),null);
 assert.equal(ICTV4.displacementInSequence(b,20,22,"BUY")?.index,22);
});
test("Counter-H1 R1 pending price uses validated zone and lower score",()=>{
 const s=snapshot(.25,-.25),p=ICTV4.previewSnapshot(s);
 const a=ICTV4.analyzeTF(s.M5,generated_at,300),eq=a.value.equilibrium;
 const zone={low:eq+2,high:eq+3,distal:eq+3,t:123};
 p.r1={allowed:true,zone,reason:"ICT_SMC_CONFLUENCE"};
 s.bid=eq-5;s.ask=eq-4.9;
 const order=sidePlan(s,p,"M5",300);
 assert.equal(order.allowed,true);
 assert.equal(order.order_type,"SELL_LIMIT");
 assert.equal(order.counter_h1,true);
 assert.equal(order.score,75);
 assert.equal(order.entry,Math.round(zone.low*100)/100);
 assert.equal(order.reason,"ICT_SMC_CONFIRMED_COUNTER_H1");
});
test("Worker publishes R2 only as pending, never as market",()=>{
 const s=snapshot(.25,.25),p=ICTV4.previewSnapshot(s);
 const a=ICTV4.analyzeTF(s.M15,generated_at,900),eq=a.value.equilibrium;
 const zone={low:eq-3,high:eq-2,distal:eq-3,t:456};
 p.r2={allowed:true,zone,reason:"ICT_SMC_CONFLUENCE"};
 s.bid=eq+4.9;s.ask=eq+5;
 const order=sidePlan(s,p,"M15",900);
 assert.equal(order.allowed,true);
 assert.equal(order.order_type,"BUY_LIMIT");
});
console.log("PASS:",cases.length,"Worker release-C unit cases");