# XAU ICT Sweep Window H, October 19 2026

## Current intended pair

- EA: `XAU_EA_SmartExec_H.mq5` (EA G + Worker H build check + release marker only)
- Worker: `XAU_Worker_SmartExec_H.js` (Worker E + sweep lookback change)
- Earlier EA G / Worker E remains available for rollback.

## Problem visible in October 19 log

In `20261019.log`, after the connection is fresh, R1 and R2 repeatedly show `allowed=FALSE`, `type=NONE`, `WAIT_R1_M30_CONTEXT_H1_BUY_M30_MIXED_BARS_119_119` or `WAIT_R2_HTF_ALIGNMENT_H1_BUY_M30_MIXED_BARS_119_119`.
These are **pre-execution strategy waits**, not rejected qualified broker orders. The log also has intermittent HTTP 1001/1003 and a valid news-shock block; these are separate and **not fixed** by H.

The `119_119` suffix is simply a count of closed H1 and M30 candles in the latest snapshot. It is not a proof of a fault, count of failed attempts, or minutes of data age. `M30 MIXED` is a structural-bias output, not a Worker/network error.

## Objective bottleneck reproduced

Ran unmodified Worker E `ICTV4.previewSnapshot` and `ictV4SidePlan` on uploaded JustMarkets M5/M15/M30/H1 OHLC series (Jan 5–Feb 6, 2026), comparing every completed M5 candle beginning Jan 13 14:00 UTC through Feb 7 00:00 UTC. Each snapshot used only candles fully closed as of the simulated time, a synthetic +$0.11 ask spread for indicative trade-type decisions, and at most 120 historical bars per timeframe. The replay has 5,059 evaluation instants.

| Metric before broker/news/session execution checks | Original E | H sweep14 |
|---|---:|---:|
| Unique R1 setup keys with allowed=true | 19 | 34 |
| Unique R2 setup keys with allowed=true | 1 | 5 |
| R1 allowed snapshots (duplicates possible) | 31 | 59 |
| R2 allowed snapshots (duplicates possible) | 6 | 21 |

This replay is an **analysis of signal generation**, **not a profitable-trades backtest**. It cannot claim that all these orders would be filled, that broker risk checks would approve them, or that they would be winners. The counts are parameter-sensitive, computed on past data that informed the choice, and not an out-of-sample estimate. No special claims for October market conditions follow from these January/February figures.

## Narrow design change

The Worker previously considered a liquidity Sweep only in the last eight completed candles, before also requiring a subsequent displacement, BOS/CHOCH and fresh FVG/OB zone. The event window was inconsistent with retaining earlier sweeps while BOS was fresh. H retains the **last 14 closed candles** for Sweep detection in M5 / M15 *only*, while keeping the **BOS/CHOCH last 4 closed M5 or 3 closed M15 candles** unchanged. Event order (`sweep < displacement <= BOS`), zone validation, value-side alignment and invalidation remain required. The larger sweep window does not authorize a trade by itself.

H also changes the Worker build identifier to `XAU_V4_ICT_SMC_SWEEP14_20261019_H`; EA H matches this health identifier without changing its order/risk logic. Worker R2 Smart Market/Limit/Stop remains intact. All news, session, feed freshness, SL/TP, duplicate suppression, risk sizing, and pending lifecycle rules stay unchanged. No demo/telemetry-only mode or additional restrictions were added.

## Validation and limits

- Worker H JS syntax check passed in Node 22.
- Synthetic unit tests passed: exact Worker E↔H source diff, sweep retention M5/M15, unchanged H1/M30 sweep behavior, no bypass of later ICT confluence and exported API unchanged.
- Offline candle replay completed using the original, unchanged Worker E strategy as comparator.
- **MetaEditor compile for EA H remains unverified.** No live Cloudflare deployment or MT5 broker fills were verified by these tests.
- Worker E deployment already in place is not automatically updated by committing the source. EA H and Worker H must be deployed as a pair or health will report a mismatched build.

## Follow-up after installing

1. Deploy Worker H code to the same intended Worker endpoint.
2. Compile EA H in MetaEditor (`F7`) and load its resulting EX5 on the XAUUSD.s chart.
3. Check `/health` `build` is `XAU_V4_ICT_SMC_SWEEP14_20261019_H`.
4. Check MT5 `Experts` starts with `EXEC_PIPELINE_20261019_H` and the `/health` probe no longer logs `WRONG_WORKER_BUILD`.
5. Gather representative market-open logs, with both positive and negative signals, broker retcodes, spread, news and freshness to validate what fraction of new **setups actually trade** and whether results improve or worsen.
