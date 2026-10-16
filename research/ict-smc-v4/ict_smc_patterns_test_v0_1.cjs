#!/usr/bin/env node
"use strict";
// No simulated executions, only deterministic no-repaint pattern tests.
const assert=require("node:assert/strict");
const t=require("./ict_smc_patterns_v0_1.cjs");
const b=(time,o,h,l,c)=>({t:time,o,h,l,c});
function run(){
 const bars=Array.from({length:65},(_,i)=>b(i*300,100,100.8,99.2,100.1));
 const filtered=t.closedBars([...bars,b(65*300,100,101,99,100)],65*300+120,300);
 assert.equal(filtered.length,65,"Candle still forming must be omitted");
 assert.equal(t.closedBars(bars,65*300,300).length,65);
 assert.equal(t.atr(bars)>0,true);
 const hp=bars.map(x=>({...x}));
 hp[32]=b(32*300,100,115,99,100);
 const sw=t.pivots(hp);
 assert.equal(sw.highs.at(-1).index,32,"Confirmed high");
 const prefix=hp.slice(0,34);
 assert.equal(t.pivots(prefix).highs.some(x=>x.index===32),false,"Future-bar pivot leak");
 assert.equal(t.pivots(hp).highs.some(x=>x.index===32),true,"Confirmed 2 bars later");
 let breach=hp.map(x=>({...x}));
 breach[64]=b(64*300,113,116,112.8,115.7);
 assert.equal(t.breakOfStructure(breach,t.pivots(breach),"BUY")?.direction,"BUY","CLOSE BOS");
 breach[64]=b(64*300,113,116,112.8,114.0);
 assert.equal(t.breakOfStructure(breach,t.pivots(breach),"BUY"),null,"wick alone is not BOS");
 let gap=bars.map(x=>({...x}));
 // The 3-candle gap becomes complete on last CLOSED bar.
 gap[62]=b(62*300,100,100.5,99.4,100.2);
 gap[63]=b(63*300,100.4,103.8,100.0,103.6);
 gap[64]=b(64*300,103.0,104.4,101.7,104.0);
 assert.ok(t.fvg(gap,"BUY")?.low>=100.5,"FVG bullish gap");
 gap.push(b(65*300,101,102,99,100));
 assert.equal(t.fvg(gap,"BUY")?.t===64*300,false,"Fully mitigated FVG rejected");
 let rev=bars.map(x=>({...x}));
 rev[62]=b(62*300,100.3,101,99.7,99.9); // opposite red candle
 rev[63]=b(63*300,99.9,104.5,99.8,104.3);
 rev[64]=b(64*300,104.3,105.1,103.9,104.9);
 const impulse=t.displacement(rev);
 assert.equal(impulse?.direction,"BUY");
 assert.equal(t.orderBlock(rev,impulse)?.index,62);
 assert.equal(t.previewSnapshot({generated_at:65*3600,H1:[],M30:[],M15:[],M5:[]}).r2.allowed,false,"Never execute with missing HTF data");
 console.log("ICT/SMC v0.1 deterministic tests PASSED, no trading actions.");
}
run();
