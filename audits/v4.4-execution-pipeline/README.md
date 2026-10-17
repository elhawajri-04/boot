# Current unified XAU release — 2026-10-17 C

**Current EA:** [XAU_V4_4_ExecutionPipeline_Research.mq5](./XAU_V4_4_ExecutionPipeline_Research.mq5)  
**Current Worker:** [XAU_Worker_ICTV4_Research_ValueRetest.js](./XAU_Worker_ICTV4_Research_ValueRetest.js)  
**Repeatable tests:** [XAU_Worker_ICTV4_ReleaseC_Regression.mjs](./XAU_Worker_ICTV4_ReleaseC_Regression.mjs)

This is the latest project version, superseding release B. Prior commits remain available for rollback. The EA and Worker have been updated in GitHub **but are not automatically installed in MT5 or deployed to Cloudflare**.

## Release C — key changes

- **R1 scalping:** derive directional context from **M30**, confirm on **M5** using sweep, bullish/bearish displacement, structure break, suitable unmitigated FVG/OB and discount/premium retest zone. H1 direction disagreement no longer blocks R1 automatically, but the setup is flagged as `counter_h1` and scored **75** vs **85** for aligned R1.
- **R2 swing:** continue to require H1 and M30 structural agreement and **pending-only** orders; H1/M30 disagreement still correctly blocks R2.
- **Event chronology and bounded retest window:** the break event must fall in last **4 closed M5 bars** for R1 or **3 closed M15 bars** for R2, with `sweep.index < displacement.index <= break.index`, and a relevant zone. These are algorithmic windows for testing; not a proven optimized parameterization.
- **MT5 release marker:** `XAU RELEASE | EXEC_PIPELINE_20261017_C` is printed by the EA on startup; `ICT4 PIPELINE` should confirm R1 and R2 model OK once market data is updated.
- **Run** `node XAU_Worker_ICTV4_ReleaseC_Regression.mjs` from this directory to verify 7 deterministic Worker tests. The same 7 cases were executed against the updated source via the code environment; the entire Worker source passed JavaScript parser validation. MT5 MetaEditor compilation and end-to-end demo forward testing remain user-side, not yet confirmed for this release.
- **Default `InpTelemetryOnlyStagingMode=true`:** keeps broker execution disabled until readiness diagnostics and pending validity are observed. Reusing the existing Cloudflare Worker hostname is allowed if the user deployed the new Worker code there. `example.invalid` is still blocked.
- **Risk and orders:** R1 M5 local-swing stop protection, max risk guards, session checks, duplicate setup protection and R2 Pending Only retained in source. No trading-performance guarantee.

## Next validation

1. Compile the EA in MetaEditor (F7, require zero errors) and confirm `EXEC_PIPELINE_20261017_C` on startup.
2. Deploy the updated Worker source to the *existing* Cloudflare Worker; updating GitHub alone is not deployment.
3. With telemetry-only **TRUE**, inspect R1 and R2 `reason=` statuses. A valid disagreement may now produce R1 `WAIT_SWEEP` or `WAIT_BOS_CHOCH` while R2 produces `WAIT_R2_HTF_ALIGNMENT_H1_BUY_M30_SELL...`; this means directional policy is separated but no R1 confluence yet.
4. Test live market snapshots when XAUUSD.s is open. Simulated previews and closed-weekend snapshots do not demonstrate actual readiness or broker order acceptance.
5. Only after confirming the EA/Worker pair and broker-safe order handling, explicitly enable execution for demo forward validation.


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
