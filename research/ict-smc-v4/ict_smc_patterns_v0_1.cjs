/* ICT/SMC objective closed-bar primitives, SHADOW RESEARCH ONLY.
 * No Worker integration, no broker orders. v0.1
 * All arrays are chronological (oldest -> newest) and passed by value.
 * These definitions are algorithmic choices, not universal ICT doctrine.
 */
"use strict";

function finite(x){return typeof x==="number" && Number.isFinite(x);}
function closedBars(raw, generatedAt, seconds){
 if(!Array.isArray(raw)||!finite(generatedAt)||seconds<=0)return [];
 return raw.filter(x=>x && [x.t,x.o,x.h,x.l,x.c].every(y=>finite(Number(y))) &&
                  Number(x.t)+seconds<=generatedAt)
 .map(x=>({t:Number(x.t),o:Number(x.o),h:Number(x.h),l:Number(x.l),c:Number(x.c)}))
 .filter(x=>x.l<=Math.min(x.o,x.c) && x.h>=Math.max(x.o,x.c) && x.h>=x.l)
 .sort((a,b)=>a.t-b.t).filter((x,i,a)=>i===0 || x.t>a[i-1].t);
}
function atr(bars,period=14){
 if(bars.length<period+1)return null;
 let v=0;
 for(let i=bars.length-period;i<bars.length;i++){
  const b=bars[i],p=bars[i-1];
  v+=Math.max(b.h-b.l,Math.abs(b.h-p.c),Math.abs(b.l-p.c));
 }
 return v/period;
}
function pivots(bars,left=2,right=2){
 const highs=[],lows=[];
 for(let i=left;i<bars.length-right;i++){
  const b=bars[i];
  let high=true,low=true;
  for(let j=i-left;j<=i+right;j++){
   if(j===i)continue;
   // Tie-breaker: earlier equal pivot wins to prevent duplicate levels.
   if(bars[j].h>b.h || (bars[j].h===b.h && j<i))high=false;
   if(bars[j].l<b.l || (bars[j].l===b.l && j<i))low=false;
  }
  if(high)highs.push({index:i,t:b.t,price:b.h});
  if(low)lows.push({index:i,t:b.t,price:b.l});
 }
 return {highs,lows};
}
function structuralBias(bars,swings){
 const hi=swings.highs.slice(-2),lo=swings.lows.slice(-2);
 if(hi.length<2||lo.length<2)return "UNKNOWN";
 if(hi[1].price>hi[0].price && lo[1].price>lo[0].price)return "BUY";
 if(hi[1].price<hi[0].price && lo[1].price<lo[0].price)return "SELL";
 return "MIXED";
}
function breakOfStructure(bars,swings,bias){
 const n=bars.length;if(n<7)return null;
 const last=bars[n-1],prev=bars[n-2],events=[];
 const high=swings.highs.filter(x=>x.index<n-3).at(-1);
 const low=swings.lows.filter(x=>x.index<n-3).at(-1);
 if(high && prev.c<=high.price && last.c>high.price)
  events.push({type:bias==="SELL"?"CHOCH":"BOS",direction:"BUY",level:high.price,t:last.t});
 if(low && prev.c>=low.price && last.c<low.price)
  events.push({type:bias==="BUY"?"CHOCH":"BOS",direction:"SELL",level:low.price,t:last.t});
 return events[0]||null;
}
function sweep(bars,swings,lookback=8){
 const base=atr(bars)||0,events=[];
 for(let i=Math.max(4,bars.length-lookback);i<bars.length;i++){
  const b=bars[i];
  const high=swings.highs.filter(x=>x.index<i-2).at(-1);
  const low=swings.lows.filter(x=>x.index<i-2).at(-1);
  if(high && b.h>high.price+base*0.05 && b.c<high.price && b.o<high.price)
   events.push({t:b.t,index:i,kind:"BUY_SIDE_SWEEP",direction:"SELL",level:high.price,extreme:b.h});
  if(low && b.l<low.price-base*0.05 && b.c>low.price && b.o>low.price)
   events.push({t:b.t,index:i,kind:"SELL_SIDE_SWEEP",direction:"BUY",level:low.price,extreme:b.l});
 }
 return events.at(-1)||null;
}
function displacement(bars,lookback=6){
 const a=atr(bars);
 if(!(a>0))return null;
 for(let i=bars.length-1;i>=Math.max(1,bars.length-lookback);i--){
  const b=bars[i],body=Math.abs(b.c-b.o),range=b.h-b.l;
  if(body>=0.65*a && range>0 && body/range>=0.65)
   return {index:i,t:b.t,direction:b.c>b.o?"BUY":"SELL",atr:a,body,range};
 }
 return null;
}
function fvg(bars,dir,lookback=25){
 const a=atr(bars);if(!(a>0))return null;
 for(let i=bars.length-1;i>=Math.max(2,bars.length-lookback);i--){
  const first=bars[i-2],third=bars[i];
  let low,high;
  if(dir==="BUY"){low=first.h;high=third.l;}
  else if(dir==="SELL"){low=third.h;high=first.l;}
  else return null;
  if(high-low<0.10*a)continue;
  // Fully mitigated if a later FINISHED candle traversed the distal edge.
  let filled=false;
  for(let j=i+1;j<bars.length;j++){
   if(dir==="BUY" && bars[j].l<=low)filled=true;
   if(dir==="SELL" && bars[j].h>=high)filled=true;
  }
  if(!filled)return {direction:dir,t:third.t,index:i,low,high,distal:dir==="BUY"?low:high};
 }
 return null;
}
function orderBlock(bars,impulse,maxLookback=4){
 if(!impulse)return null;
 const dir=impulse.direction;
 for(let i=impulse.index-1;i>=Math.max(0,impulse.index-maxLookback);i--){
  const b=bars[i];
  if(dir==="BUY" && b.c>=b.o)continue;
  if(dir==="SELL" && b.c<=b.o)continue;
  if(b.h-b.l>3*impulse.atr)continue;
  let invalid=false;
  for(let j=impulse.index+1;j<bars.length;j++){
   if(dir==="BUY" && bars[j].c<b.l)invalid=true;
   if(dir==="SELL" && bars[j].c>b.h)invalid=true;
  }
  if(!invalid)return {t:b.t,direction:dir,index:i,low:b.l,high:b.h,
                      distal:dir==="BUY"?b.l:b.h};
 }
 return null;
}
function dealingRange(swings){
 const hi=swings.highs.at(-1),lo=swings.lows.at(-1);
 if(!hi||!lo||hi.price<=lo.price)return null;
 return {low:lo.price,high:hi.price,equilibrium:(lo.price+hi.price)/2};
}
function analyzeTF(raw,generatedAt,seconds){
 const bars=closedBars(raw,generatedAt,seconds);
 if(bars.length<60)return {ready:false,reason:"NO_DATA",bars:bars.length};
 const swings=pivots(bars),bias=structuralBias(bars,swings);
 return {ready:true,bars,swings,bias,break:breakOfStructure(bars,swings,bias),
         sweep:sweep(bars,swings),displacement:displacement(bars),
         value:dealingRange(swings),atr:atr(bars)};
}
// STRICT no-trade-until-confluence, deliberately NOT wired to production.
function previewSetup(snapshot,timeframe,seconds,htfBias){
 const s=analyzeTF(snapshot[timeframe],Number(snapshot.generated_at),seconds);
 if(!s.ready)return {allowed:false,reason:"NO_DATA"};
 if(htfBias!=="BUY"&&htfBias!=="SELL")return {allowed:false,reason:"WAIT_HTF_BIAS"};
 if(!s.sweep || s.sweep.direction!==htfBias)return {allowed:false,reason:"WAIT_SWEEP"};
 if(!s.displacement || s.displacement.direction!==htfBias ||
    s.displacement.index<=s.sweep.index)return {allowed:false,reason:"WAIT_DISPLACEMENT"};
 if(!s.break || s.break.direction!==htfBias)return {allowed:false,reason:"WAIT_BOS_CHOCH"};
 const gap=fvg(s.bars,htfBias);
 const block=orderBlock(s.bars,s.displacement);
 if(!gap && !block)return {allowed:false,reason:"WAIT_FVG_OB"};
 const zone=gap||block,price=s.bars.at(-1).c;
 if(!s.value)return {allowed:false,reason:"WAIT_DEALING_RANGE"};
 const valueOK=htfBias==="BUY"?price<=s.value.equilibrium:price>=s.value.equilibrium;
 if(!valueOK)return {allowed:false,reason:"WATCH_VALUE",zone};
 return {allowed:true,reason:"ICT_SMC_CONFLUENCE",direction:htfBias,
         structure:s.break.type,zone,low:zone.low,high:zone.high,distal:zone.distal,
         sweep:s.sweep,displacement:s.displacement};
}
function previewSnapshot(snapshot){
 const t=Number(snapshot.generated_at);
 const h1=analyzeTF(snapshot.H1,t,3600);
 const m30=analyzeTF(snapshot.M30,t,1800);
 const bias=h1.ready&&m30.ready&&h1.bias===m30.bias?h1.bias:"MIXED";
 return {model:"ICT_SMC_V4_RESEARCH",
   htf_bias:bias,
   r1:previewSetup(snapshot,"M5",300,bias),
   r2:previewSetup(snapshot,"M15",900,bias),
   not_live:true};
}
if(typeof module!=="undefined"&&module.exports)
 module.exports={closedBars,atr,pivots,structuralBias,breakOfStructure,
                 sweep,displacement,fvg,orderBlock,dealingRange,analyzeTF,
                 previewSetup,previewSnapshot};
