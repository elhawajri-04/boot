# Current unified XAU release — 2026-10-17 B

**Current EA file:** [XAU_V4_4_ExecutionPipeline_Research.mq5](./XAU_V4_4_ExecutionPipeline_Research.mq5)  
**Current Worker file:** [XAU_Worker_ICTV4_Research_ValueRetest.js](./XAU_Worker_ICTV4_Research_ValueRetest.js)

This is the **latest project version**; historical versions remain in GitHub. It is not yet MT5-compiled or forward-tested as a pair. All code updates are committed to the current branch, not deployed to the user's MT5 or Cloudflare automatically.

- The EA prints `XAU RELEASE | EXEC_PIPELINE_20261017_B` on start.
- Telemetry-only mode defaults TRUE in source and should be TRUE in MT5 Inputs for verification. Expect `RESEARCH DIAGNOSTIC | TELEMETRY_ONLY=TRUE` and `ICT4 PIPELINE | ... telemetry_only=TRUE`. It will not send trades in this mode.
- The EA accepts the existing Worker URL, even when it previously hosted production and the user replaced its code; placeholder `example.invalid` remains blocked.
- Deploying Worker source on Cloudflare **requires a separate explicit deploy**; GitHub updates alone do not change a deployed Worker. The same Cloudflare hostname may be used when the operator intentionally replaced the old Worker code.
- The Worker preserves H1/M30 strict structural agreement. It now reports `WAIT_HTF_STRUCTURE_H1_<BIAS>_M30_<BIAS>_BARS_<COUNT>_<COUNT>` in both R1 and R2 pending reasons, revealing why no READY state was produced. Other gates remain unchanged, including R1 local confirmed M5 swing SL with ATR buffer and R2 Pending Only.
- When market is closed, `OFF | SESSION` is expected, and repeated `WAIT_HTF_STRUCTURE` should **not** be interpreted as a failed open-market trading test.
- Verify source in MetaEditor F7 = 0 errors; then confirm EA exact release marker in Experts. Verify the new Worker reason appears after Cloudflare deployment, then inspect R1 and R2 real-session readiness and broker orders (only when explicitly allowing demo execution).
- There is no claim of increased trade count, execution success or profitability from the diagnostic-only change.

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
