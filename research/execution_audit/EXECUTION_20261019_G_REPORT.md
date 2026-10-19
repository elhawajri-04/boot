# XAU EA G, 19 October 2026 diagnostic

## Exact inputs
- User-provided terminal Experts log: `20261019.log`, UTF-16LE, 137 lines, approximately 13:11:51–13:30:10 (terminal time). This is a short extract, not a full trading day.
- Published EA F source: Git blob `b27a7177253dfdab7e8a98e5147fba460759492e`.
- Published Worker E source: Git blob `ac1718b0d08b85be670097456eea386dbfeeb03d`.
- Worker deployment **has not** been verified remotely, and MT5 MetaEditor compile for G **has not** been run.

## Findings verified from provided log
- At 13:11:51 F started with `EXEC_PIPELINE_20261018_F`, `execution_mode=ACTIVE`, `R2 SMART=ON`.
- 18 periodic `ICT4 PIPELINE` snapshots consistently show `allowed=FALSE` and `type=NONE` for both R1 and R2. No qualified trade order / broker execution attempt appears in this extract.
- Normal strategy wait: R1 `WAIT_R1_M30_CONTEXT_H1_BUY_M30_MIXED_BARS_119_119`; R2 `WAIT_R2_HTF_ALIGNMENT_H1_BUY_M30_MIXED_BARS_119_119`.
- Worker communication is **intermittent**, not permanently unavailable: `HTTP GET /r2` status 1003 (two separate occurrences), `HTTP POST /update` status 1001 (one occurrence), followed by `RECOVERED` around 13:15:58–13:15:59. Broader probes also failed during the outage. These non-standard statuses and `mt5_last_error=4006` are observations; the log does not establish whether the fault is broker-network, MT5 WebRequest, a proxy, DNS, Cloudflare, or another layer.
- There are 4 `/health` probe lines with status 200 and `WRONG_WORKER_BUILD`. **Definite local code bug:** EA F hard-coded `XAU_V4_ICT_SMC_ADAPTIVE_MARKET_PENDING`, while the intended Worker E source declares `XAU_V4_ICT_SMC_SMART_EXEC_20261017_E`. A 200 response will always fail this version check **when Worker E is actually serving that declared version**. This message alone cannot establish which Worker build was actually deployed.
- News shock guard activated at 13:20:41 with `NEWS BLOCK SHOCK: M1 CANDLE PRICE SHOCK` and subsequent `BLOCK | NEWS` for both engines.
- `AUDIT | R1/R2 | ... WORKER FEED STALE` occurred on intermittent intervals: 25 logged lines for R1 (30-second cap), 38 for R2 (20-second cap), not 63 independent outages. These caps are original strategy safety checks; not changed.
- `AUDIT | LEARN | RESULTS | ... mode=OBSERVE_ONLY` pertains to the learning/performance risk throttle (`InpEnableLearnedRiskThrottle`) and is **not** the retired telemetry-only trading gate. Log proves `execution_mode=ACTIVE` independently.

## G patch
- New EA source: `XAU_EA_SmartExec_G.mq5`, compatible with unchanged Worker E.
- `/health` probe now extracts `build` using `JsonGetString`, compares with Worker E's published build, and on mismatch logs `WRONG_WORKER_BUILD expected=... got=...`.
- All trading paths, R1/R2 conditions, risk calculations, pending orders, SL/TP, news, session handling, and feed freshness caps remain byte-for-byte unchanged relative to F except the health-probe diagnostic and release label.
- 12 static release/regression checks passed; **no MetaEditor compilation** and **no actual WebRequest or broker tests** were possible in this workspace.

## Next verification
1. Compile the full G EA source in MetaEditor, press F7, check errors/warnings, attach over F.
2. Leave Worker E deployed as intended. Verify its actual `/health` response `build` equals `XAU_V4_ICT_SMC_SMART_EXEC_20261017_E`; it should also show `r2_pending_only_mode:false`, `r2_market_execution_enabled:true`, and `strategy_model:ICT_SMC_V4_LIVE`.
3. Allow time for `/health` periodic probe, and inspect Experts for `EXEC_PIPELINE_20261019_G`, `PROBE /health | OK` or the more detailed version mismatch `expected=... got=...`.
4. Monitor intermittent HTTP statuses, freshness, high timeframe alignment, and broker retcodes if a fully eligible setup occurs. Do **not** change signal/HTF/news/feed safety gates just to increase trade count without evidence.

Source code and tests are published separately; historical volume research is not in the live decision pipeline.
