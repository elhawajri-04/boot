# XAU current unified release — 2026-10-17 D: R2 Smart Execution

**Current EA:** [XAU_V4_4_ExecutionPipeline_Research.mq5](./XAU_V4_4_ExecutionPipeline_Research.mq5)  
**Current Worker:** [XAU_Worker_ICTV4_Research_ValueRetest.js](./XAU_Worker_ICTV4_Research_ValueRetest.js)

This release **supersedes C**. Older versions remain in GitHub history. It is the latest implementation, but **has not yet been MetaEditor-compiled, deployed to Cloudflare or forward-tested in MT5 by the assistant**. GitHub commits do not install the files.

## R2 Smart decision

- **Market BUY/SELL:** M15 sweep + displacement + confirmed BOS/CHOCH + valid zone/value gate are all present, the latest *closed M15 candle* confirms direction, and the live quote is in the approved retest zone.
- **Limit BUY_LIMIT/SELL_LIMIT:** confirmed setup exists, but price is above the buying zone or below the selling zone; await the retest.
- **Stop BUY_STOP/SELL_STOP:** price is already in the M15 return zone, but the last closed bar lacks directional confirmation; await break above its high / below its low, with a bounded ATR/point buffer. The EA still rejects broker-invalid pending prices.
- **No entry:** missing HTF agreement, ICT confluence, news approval, session, valid price/SL/TP, sufficient score/RR, freshness, eligible quote or account SL-risk room.
- R2 **still requires H1/M30 structural alignment**. R1 retains M30+M5 independent directional policy and M5-local swing stop.
- Workers `/r2` and `/r2/setup` now advertise `smart_execution_mode:true`, `pending_only_mode:false`; each R2 setup has `execution_mode`, `market_viable`, `pending_viable`, `execution_reason` and a stable BOS+zone `setup_key`. R2 READY audit now accepts approved Market or Pending instead of running an unrelated obsolete pending-only/R1 zone audit.

## MT5 execution safety

- `InpEnableR2PendingExecutor` **retains its old name** for saved MT5 inputs but is now the R2 Smart master switch. `InpR2EnableMarketExecution=true` additionally enables confirmed R2 market orders.
- Default `InpTelemetryOnlyStagingMode=true` **blocks all EA broker execution** until intentionally changed in MT5 Inputs.
- Source checks retain news/session gating, HTF/Worker protocol and feed age, SL/TP validation, spread-aware broker quote checks, market-entry drift limit, risk-sized lot and combined account caps, broker order retcodes, per-engine exposure locking, risk-limited pending order lifecycle and one accepted order per event.
- Broker comments on R2 Market start `XAU_R2P_` so existing R2 ownership, risk accounting and position management still recognize them.
- Stable `setup_key` is keyed on confirmed structure event + zone, **not** tick price or order type; the EA stores accepted keys in terminal global variables to avoid replay. Rejected broker requests have a bounded per-setup retry interval.
- A pending R2 order locks out R2 Market for the same or any other setup until it has been safely resolved. R1 may operate independently subject to total cap.

## Evidence and next steps

- The Worker source passed full-file JavaScript parser validation and **10 deterministic tests** for bid/ask decision routing and EA gate/source checks; the Smart R2 audit additionally passed 5 sample states (Market, Limit, Stop, mismatch, WAIT). These are **unit and structural checks**, not broker execution or profitability tests.
- In MetaEditor, compile the EA and confirm `0 errors`. Expected startup marker: `XAU RELEASE | EXEC_PIPELINE_20261017_D`.
- Deploy the matching Worker file to the existing Cloudflare Worker hostname and check `ICT4 PIPELINE` for `R2 model=OK` and a concrete `type=` or wait reason. Keep telemetry-only TRUE for this first verification.
- After verifying the currently deployed pair, explicitly switch telemetry-only FALSE on the user-owned Demo only to evaluate broker orders. Never infer success or trade rate from a closed-market test.


---

# XAU Live R1/R2 execution path audit — independent research, not deployed

## Root causes confirmed from V4.4 EA + ICTV4 Worker v4.1 source

1. **WATCH != APPROVED**. Worker `ictV4WatchZones` emits FVG/OB reference bands even when `r1_allowed:false` or R2 `setup.allowed:false`. Zone presence alone cannot authorize an entry.
2. **Trade-data polling depends on drawing inputs** in V4.4: `PollDecisionZones` only runs while `InpDrawDecisionZones=true` and `PollR2Visuals` only runs while `InpDrawR2Setup=true`. Disabled chart drawings can starve either executor of fresh Worker confirmation and leave `WORKER MODEL/AGE` blocked. Research EA decouples Worker polling from drawing inputs.
3. **Latest confirmed pivot off-by-one**. Worker `breakOfStructure` uses `index<n-3` instead of `index<=n-3` for confirmed pivot right=2. Corrected in research Worker.
4. **BOS candle value conflict**. Original `previewSetup` demands breakout candle close in premium/discount at the same time it recognizes BOS. Research Worker checks whether the candidate entry *zone* reaches the correct value half; entry prices are clipped to that half, and the approved FVG/OB zone is the same one used for the execution plan. It does not bypass sweep/displacement/BOS confirmations.
5. **Stale visual zone used for R1 scalp SL**. The original V4.4 `ICT4Execute` constructs M5 local swing SL using `g_buyZoneLow/g_sellZoneLow` from a persisted visible zone, which can differ from the currently approved Worker event. Research EA binds a fresh signal-specific zone `g_ictR1TradeZoneLow/High` from the same approved Worker response. It preserves nearest local M5 pivot and ATR buffer rules, rejects missing zone, does not use distant structural invalidation as scalp SL.

## What was changed

Research-only EA: [XAU_V4_4_ExecutionPipeline_Research.mq5](./XAU_V4_4_ExecutionPipeline_Research.mq5)

Research-only Worker: [XAU_Worker_ICTV4_Research_ValueRetest.js](./XAU_Worker_ICTV4_Research_ValueRetest.js)

- Telemetry-only staging defaults **true** in research EA, meaning **no broker orders, SL/TP management or deletions**. DO NOT replace the operational V4.4 chart EA with this unless tested on an independent isolated demo, especially if there are positions relying on EA-side management.
- Emits a bounded **`ICT4 PIPELINE`** audit line with R1/R2 model/allowed/reason/quote-age/order type/engine statuses every minute.
- R2 remains **Pending Only**; broker SL/TP, risk/news/session/quote freshness gates are not intentionally loosened.
- Code inspection and basic syntax checks are not MT5 Compile or real broker execution checks. No changes were deployed to Cloudflare Worker or original V4.4.

## Offline test — Jan & Feb 2026

An offline causal snapshot survey of closed M5/M15/M30/H1 candle records using M5 close as an approximate quote (NOT executable tick fills):

| Week | Original R1 approved snapshots | Research R1 | Original R2 pending source approval snapshots | Research R2 |
| --- | ---: | ---: | ---: | ---: |
| Jan 2026 | 0 | 2 | 0 | 3 M5 poll snapshots of one M15 signal |
| Feb 2026 | 0 | 3 | 0 | 0 |

**No performance result or expected trade frequency may be inferred from these numbers.** The Worker is still restrictive (H1/M30 agreement, sweep/displacement/BOS FVG/OB). Research EA is **telemetry-only** by default. R1/R2 broker order behavior under combined changes remains unproven.

## Validation before any trading deployment

1. Independently compile research EA in MetaEditor: **0 errors** required.
2. Validate research Worker by unit tests, controlled synthetic market payloads and phase2/3 historical replay against both scripts, ensuring no lookahead, valid pending prices and no stale market reuse. No Cloudflare deployment before these tests.
3. On a completely isolated demo terminal/account without active unmanaged positions, run telemetry-only and collect `ICT4 PIPELINE` / `AUTO_EXEC` / `POLL` lines. If live V4.4 was active during prior no-trade observation, collect its contemporaneous **MT5 Experts + Journal** as well; Strategy Tester phase5 log is irrelevant to V4.4 Worker readiness.
4. If a Worker signal is fully approved but EA still blocks, inspect feed age, session, local M5 swing / zone match, broker stop levels and risk lot failure. Do not force trades by disabling these protections.
5. Only after verifying safe behavior in the isolated demo may a separately approved release be considered.

**Status: Research prototype and root-cause diagnosis; NOT a verified live trading fix.**
