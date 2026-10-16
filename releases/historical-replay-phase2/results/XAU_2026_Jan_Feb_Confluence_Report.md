# XAUUSD.s ICT/SMC Replay, comparison of 2026 January and February weeks

## Research scope
- Jan 6–13, 2026 and Feb 2–9, 2026, each a full week (604,800 broker-server seconds).
- Original Worker V4.1 `ICTV4` adapter reused without changing the strategy; summary worker SHA256: `6d6a7716288a5fb835608ec224f1ef7bd1b6273b7154c98e436289fbe65a8179`.
- February metadata: `export_status=OK`, ticks exported, 2,491,352 tick rows excluding header, 5 bar timeframes with warmup.
- 1-second bid/ask replay with M5 closed-candle model refresh. Stage diagnostics at newly closed M5 times use live-like recent-history windows, H1=120, M30=120, M15=150, M5=200.
- **This is a signal audit only. No fills, news gate, lot sizing, R1 local swing stop, R2 pending lifecycle or profitability calculation. This does not verify whether the deployed Cloudflare Worker is the same revision.**

## Replay outcomes

| Metric | Jan 6–13 | Feb 2–9 |
| --- | ---: | ---: |
| Seconds sampled | 604,800 | 604,800 |
| Closed-M5 evaluations | 1,380 | 1,381 |
| HTF=MIXED | 978 | 955 |
| R1 model confirmations | 0 | 0 |
| R2 model confirmations | 0 | 0 |
| R1 raw order signals | 0 | 0 |
| R2 raw order signals | 0 | 0 |
| Seconds without fresh usable quote | 191,595 | 191,980 |

## Evidence at the final confluence stage

Re-analysis of the *original* `previewSnapshot` and `analyzeTF` functions at each newly closed M5 bar showed some near-confirmations where HTF bias, aligned liquidity sweep, subsequent displacement, BOS/CHOCH direction and FVG/OB were all present. These were blocked by the **value/equilibrium condition**:

| Period | Engine | Evaluations passing through zone stage | Also passing equilibrium/value stage |
| --- | --- | ---: | ---: |
| January | R1 | 2 | 0 |
| January | R2 | 3 | 0 |
| February | R1 | 3 | 0 |
| February | R2 | 0 | 0 |

Jan R2's three evaluations reflect repeated observations of a single M15 completed-bar state, **not three separate trades**.

### Example of the conflict

- January R2 BUY: BOS level 4444.79, close 4450.56, range equilibrium 4436.375. On that same completed bar, `price <= equilibrium` is false for a BUY.
- February R1 SELL: BOS level 4909.78, close 4908.11, equilibrium 4920.035. On that same completed bar, `price >= equilibrium` is false for a SELL.

The `previewSetup` source requires BOS/CHOCH on the *latest closed candle*, and simultaneously requires the latest close to be in the discounted half for BUY or premium half for SELL. After a confirmed break, the close is often already past equilibrium in the breakout direction. The two rules are not proven mathematically impossible in all markets, but they conflicted in **all eight stage-qualified sample evaluations across these two weeks**.

## Engineering action before profitability backtest

**Do not simply delete or weaken the value condition to force trades.** Instead evaluate a proper two-stage stateful research variant:
1. *Confirm event:* at the completed bar, require HTF, sweep, displacement, BOS/CHOCH, and zone; record signal, zone ID, structure level, invalidation and expiry.
2. *Await retest:* for bounded subsequent bars, wait for bid/ask to retrace into the allowed zone/value region, then independently apply R1/R2 order-type rules, entry/SL/TP and all safety gates. Cancel if invalidated or expired. All confirmed events must persist without seeing future candles.
3. Compare untouched original versus this **hypothesis** using larger 2026 samples and holdout data, before integrating a separate Strategy Tester EA.
4. Inspect actual deployed Worker version and live MQL5 settings; conclusions here are about supplied V4.1 source and replay files, not direct production execution.

## Source pin and tests
- Phase 2 replay regression tests: 6 pass.
- Original Worker SHA256: `6d6a7716288a5fb835608ec224f1ef7bd1b6273b7154c98e436289fbe65a8179`.
- Jan and Feb summary JSONs preserve exact counters.
- The February raw tick CSV and individual trades should **not** be inferred from the transition-only signal audit.