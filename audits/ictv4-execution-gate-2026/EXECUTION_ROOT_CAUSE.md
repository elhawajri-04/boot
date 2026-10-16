# XAUUSD.s execution blockage: pinned Worker V4.1 source audit

**Scope:** original Worker V4.1 `releases/v4.1/XAU_V4_Worker_v4_1.js` (SHA256 `6d6a7716288a5fb835608ec224f1ef7bd1b6273b7154c98e436289fbe65a8179`), research-only, no deployment changes. Jan 6–13 and Feb 2–9 2026 CSV candle export metadata `OK`; both use broker server timestamps. The counter below evaluates the original Worker `ICTV4.analyzeTF` against closed M5 and M15 candles. It does **not** count trade setups or fills and does not include HTF, sweep, news or broker session gates.

## Root cause A — BOS close and value-zone close incorrectly required at the same instant

In original Worker `previewSetup` (`XAU_V4_Worker_v4_1.js` around lines **8398–8413**), it requires a **latest closed candle BOS/CHOCH** and THEN requires that **very same candle close** to be on the discount side (`BUY`) or premium side (`SELL`) of the dealing-range midpoint:

```js
if (!s.break || s.break.direction !== htfBias) return {allowed:false,reason:"WAIT_BOS_CHOCH"};
const price = s.bars.at(-1).c;
const valueOK = htfBias==="BUY" ? price<=s.value.equilibrium : price>=s.value.equilibrium;
if(!valueOK) return {allowed:false,reason:"WATCH_VALUE",zone};
```

BOS confirmation moves **above the last confirmed swing high** for BUY, while the dealing midpoint is **below that high**. The SELL case is symmetric: BOS moves below the confirmed swing low while the midpoint is above it. Thus when the level used for BOS is the latest confirmed swing pivot, the simultaneous requirements are mathematically inconsistent: `(close > swingHigh) AND (close <= (swingHigh+swingLow)/2)` is false if `swingHigh>swingLow`, and similarly for SELL.

The Worker next calls `ictV4SidePlan` (around lines **8441–8474**), which sets `structurallyReady = Boolean(base.allowed)`: a failed `WATCH_VALUE` suppresses **all** `r1_allowed`/`r2_allowed` even if the zone and the real-time bid/ask would otherwise permit an executable pending limit order. Consequently the EA `ICT4Execute` (V4.4 around **4516–4633**) waits at `if(!allowed)`; it does not call `trade.Buy/Sell` or `ICT4Pending`.

### Reproducible original Worker measurement

| Week | Frame | Reported BOS | Same candle value check passed | BOS actually crossed latest confirmed swing |
|---|---:|---:|---:|---:|
| Jan 6–13 | M5 | 162 | 1 | 150 |
| Jan 6–13 | M15 | 49 | 0 | 47 |
| Feb 2–9 | M5 | 152 | 0 | 141 |
| Feb 2–9 | M15 | 55 | 0 | 52 |
| **Both weeks** | **M5 + M15** | **418** | **1** | **390** |

**ZERO** of the 390 genuine latest-pivot breakout candles also passed the value-zone condition. This confirms the blocking conjunction on these exports. The single exception passing the value test was **not a BOS of the latest confirmed pivot**: at MT5 server Unix **1767762600**, the BUY close was `4476.04` and the Worker compared it with an **older** swing `4475.71` even though the newest confirmed swing high was `4478.79` (close below that newer high).

## Root cause B — an off-by-one stale pivot level gives spurious BOS

`pivots` emits pivots with `i < bars.length-right` (default `right=2`), so the newest **confirmed** pivot can have index `n-3`. But `breakOfStructure` uses `swings.highs.filter(x=>x.index<n-3)` (and same for lows), explicitly **excluding** any pivot at index `n-3`. This can use an older pivot to label a BOS even though the current close has not broken the newest confirmed pivot. The rare value-pass example above exhibits precisely this behavior. Fix the pivot eligibility rule in a separate research branch and add regression tests; fixing this alone will make root cause A even more absolute, so the signal lifecycle must be redesigned together.

## Separate operational execution blockers

- The older `XAU Market Zones Engine v3.5.34` MT5 Experts log (Oct 16) contains **985** rejected R2 pending deletes with broker retcode `10018 market closed` and **286** `HTTP=1003` market-update failures. These are **confirmed for the old build only**, not evidence the current V4.4 still has this bug; V4.4 includes retry throttling. Broker-side failures require current V4.4 Experts and Journal after the structural-gate fix.
- Phase 3 replay generated four `OBSERVED_ZONE_TOUCH` candidates, **not** fills and **not** historical profits. Stage 4 must actually use broker-timed causal `ARM`/`CANCEL`, confirmed local M5 swing SL for R1, R2 pending-only, tick-level execution, symbol stops/volume/margin, news and session policy before measuring P&L.
- A separate V4.4 Strategy Tester invocation fails closed on session logic by default unless the user explicitly sets `InpTesterBrokerUTCOffsetMinutes` from placeholder `9999` to a historically valid broker offset. This is intentional safety, not proof of an auto-execution bug in the live terminal.

## Safe engineering resolution (NOT applied to live)

1. Compute structural confirmation on the last closed bar, using the **latest eligible confirmed pivot**, then save an immutable event key and zone.
2. At a later broker time, arm only if quote is fresh, and the zone **intersects** correct discount/premium half; require actual broker-valid LIMIT placement relation, with price/SL/TP normalization and risk/volume/margin checks.
3. R1: enter on a valid observed retest (market or pending according to the design) using **nearest closed M5 local swing plus ATR buffer**, not the far structural invalidation. R2: **pending only**, never change to market automatically.
4. Independently cancel on HTF change, closed-bar invalidation, expiry, session/news/risk events, and honor broker rejection/retry state (no phantom canceled orders).
5. Compare the original Worker with the research variant on additional months and test actual orders in an isolated MT5 Strategy Tester. Preserve live V4.4 and deployed Worker until demo/forward validation.

**Data and reproducibility**: `check_worker_gate.mjs` evaluates the exact pinned Worker adapter (via Node `vm`) with completed M5/M15 candles, and `test_gate_results.mjs` verifies stored jan/feb JSON snapshots. No network calls, no trade side effects.