# XAU Phase 5 — parallel candidate + HTF-neutral retest RESEARCH

**Status:** Node replay completed on broker-exported Jan 6–13 and Feb 2–9 2026 data. 14 Node/static tests passed. The new MQ5 EA **has NOT been compiled in Windows MetaEditor or run in MT5 Strategy Tester**. It is forbidden outside Strategy Tester by `MQL_TESTER`. **No profit claims.** Existing V4.4 and deployed Worker unchanged.

## What is changed relative to Phase 4

1. **`HTF=MIXED` is neutral, not an instant CANCEL.** A zone expires normally after R1 1h / R2 6h, is canceled on a closed-bar structural invalidation, or on two successive *fresh M5 decisions* with opposite BUY/SELL HTF bias. The separate EA receives exact timestamped CANCEL commands; it does not guess live HTF from the Worker.
2. **Independent simultaneous research zones**: up to three active candidates per engine, subject to an overlap filter rejecting >=70% overlap on the smaller same-side retest zone; no forced `SUPERSEDED` cancellation. The EA's actual account-wide exposure still counts all open positions/pending orders via `ExistingRiskMoney` and enforces 1% per-order and 5% aggregate default.
3. **R1 confirms *after* touching the zone, not on the same M5 candle.** The EA marks the earliest in-band bid/ask touch, waits for a **closed M1 candle completed strictly after that touch**, and requires a directional body closing in the directionally appropriate half of the bar. The execution price must remain within the configured 150-point proximity of the zone (default), and M1 confirmation times out after 180 seconds; it may then wait for another retest. Local M5 swing+ATR stop remains untouched. `InpR1ConfirmationMode=P5_LEGACY_M5_DIRECTION` permits A/B comparison.
4. **R2 stays BUY_LIMIT/SELL_LIMIT only.** Pendings receive broker SL/TP, margin, spread, stop/freeze checks; a failed deletion stays active until broker ack, with market-closed retries throttled.
5. **Cross-week mix-up impossible in the same tester run:** the EA includes `phase5_jan_commands.csv` and `phase5_feb_commands.csv` as separate declared tester files, picks one with `InpResearchPeriod`, and rejects a mismatch between the tester's start date and the selected week or an order timestamp outside the week. No renaming files is required.

## Real historical observations (no broker fills)

| Week of 2026 | Phase 4 structural confirmations | Phase 4 retest touches | Phase 5 structural confirmations | Phase 5 retest touches |
|---|---:|---:|---:|---:|
| Jan 6–13 | 3 (R1 2; R2 1) | 2 (R1) | 3 (R1 2; R2 1) | 2 (R1) |
| Feb 2–9 | 3 (R1 3) | 2 (R1) | 3 (R1 3) | 3 (R1) |
| Total | **6** | **4** | **6** | **5** |

Each replay was 604,800 **seconds**, reading the original Worker V4.1 ICT/SMC adapter with only its previously audited latest-confirmed swing pivot fix. `MIXED` does not invalidate February's first zone, so it reaches the observed retest. January's R2 candidate lives to 6h expiry but still sees no observed touch. Both weeks had **peak 1 simultaneous active candidate per engine**, so the *multizone* improvement has only been unit-tested, not demonstrated on these particular weeks. Nor has the new M1 R1 confirmation been broker-tested. **Trading frequency remains too low to claim success.**

## Install and compile (Windows, MT5 Strategy Tester only)

1. Download `mt5/XAU_Phase5_Research_Tester.mq5` and place under **MT5 File > Open Data Folder > MQL5/Experts**. Open in MetaEditor and press **F7**. We need `0 errors`; Linux Node tests do not prove MQL5 syntax correctness.
2. Put **three** files in **that terminal's** `MQL5/Files`: `mt5/phase5_jan_commands.csv`, `mt5/phase5_feb_commands.csv`, `mt5/phase5_news_clear.csv`. Don't rename any of them or use the prior Phase4 names.
3. Open Ctrl+R Strategy Tester, Expert `XAU_Phase5_Research_Tester`, symbol `XAUUSD.s`, timeframe **M5**, modelling **Every tick based on real ticks**, and Jan 6–13 2026. `Inputs > InpResearchPeriod = P5_JAN_2026`.
4. Leave `InpResearchAllowUnverifiedNews = false` (fail closed) for normal safety. For **execution-path diagnostics only**, user may explicitly set it `true`; this logs unverified historical news, and any monetary results do NOT establish strategy edge. Start and save **Journal**, Backtest/History, and HTML report. Repeat Feb 2–9 with `P5_FEB_2026`, no file replacement or recompilation needed.
5. Compare `P5|R1|...|TOUCHED|...`, `P5|...|MARKET_ACCEPTED`, R2 `PENDING_ACCEPTED`, broker retcodes, fills, SL price and slippage. Unverified news/sessions and the small sample forbid production deployment.

### Offline replication (Node v22+)

Use the folder containing all seven `xau_<prefix>_*.csv` exporter files, with correct actual dates in metadata.

```sh
node scripts/phase5_replay.mjs --worker ../XAU_V4_Worker_v4_1.js --dir /path/to/export --prefix xau_20250106 --out results/jan_events.csv
node scripts/export_causal_commands.mjs results/jan_events.csv results/jan_commands.csv
node --test tests/phase5.test.mjs
```

`--max-candidates-per-engine 3` is configurable in the Node replay; the EA takes `InpMaxActiveCandidatesPerEngine=3`. The audit files are **ex post** observations only; the command CSVs contain no outcome/touch prices. Never feed `*_events.csv` to an EA. No `WebRequest` or live Worker calls in this tester EA.

## Outstanding blockers and next iteration

- Verify MetaEditor compilation and actual broker execution on Jan & Feb. No Windows compiler runs have been made by the assistant.
- Even the updated rules produced **only six structural setups across two weeks**. The upstream Sweep → Displacement → BOS + FVG/OB eligibility is the next **diagnostic** bottleneck, and loosening it should be compared on out-of-sample months, not optimized solely to Jan–Feb.
- Test concurrent independent zones on real historical weeks where multiple setups overlap; current observed peak = 1.
- Obtain independently verifiable historical economic-news blackout windows and genuine broker historical session parameters before evaluating real expectancy/Profit Factor. Test variable spread, commission, random delay, and SL slippage. No changes to live V4.4 nor deployed Worker until all guards reviewed and the user approves.