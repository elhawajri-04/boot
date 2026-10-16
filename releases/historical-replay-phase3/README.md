# XAU ICT/SMC Historical Replay, Phase 3: two-stage retest **research variant**

**This is not the deployed Worker, not the live EA, not a calibrated strategy, not a broker simulator, and NOT a profitability backtest.** Nothing in this folder sends or simulates trades. The demo EA V4.4 and Worker V4.1 are unchanged.

## Why Phase 3 exists

The **original** V4.1 Worker ICT/SMC confirms Sweep → Displacement → BOS/CHOCH → FVG/OB, then asks the **same latest completed bar's close** to be in the discount half for BUY / premium half for SELL. Jan 6–13 and Feb 2–9 2026 each gave **zero** original Worker R1/R2 approved setups under the offline replay. Phase 3 tests the **new** hypothesis: confirm the structural event at the closed bar, freeze that zone and equity midpoint, then wait for price to return to the intersection of the zone and value half before expiry or invalidation.

### Reuse versus change

- Reused **byte-for-byte** from `releases/v4.1/XAU_V4_Worker_v4_1.js`: its `ICTV4` primitives `previewSnapshot`, `analyzeTF`, `sweep`, `displacement`, `breakOfStructure`, `fvg`, `orderBlock`, and the original side plan (the baseline). The replay stores exact original Worker and adapter SHA256 hashes.
- **Changed ONLY inside this isolated research hypothesis**: persist each event across time; test the premium/discount condition on a later zone retest instead of the breakout candle; define a 1h R1 / 6h R2 expiry from Worker plan defaults; cancel on HTF mismatch or closed-bar distal invalidation; require a fresh historical bid+ask quote; record retest observations, never trade fills.
- R2 research candidates are LIMIT only. A buyer must start ABOVE the entry band and a seller BELOW. Research R1 records a possible later market retest only; **no assumption that a real R1 order type or M5 swing stop would pass**.
- All timeframes M1/M5/M15/M30/H1 use **completed candles**, with the model re-evaluated on completed M5 intervals. R2 event creation is limited to newly closed M15 bars. Tick quotes are examined every broker-server second, with max age 30s by default. An event **cannot** count a touch at creation time. A quote that gaps across the whole zone is marked `GAP_ACROSS_ZONE_UNVERIFIED`, not a broker fill.
- Only successful, fresh quotes can arm an event. No artificial bar-close quote, future tick, or zero quote is used.

### Running locally (Node.js 22+)

Export a week using the MT5 exporter from Phase 1. Store the seven `prefix_{M1,M5,M15,M30,H1,ticks,meta}.csv` files in the same folder. The prefix and *actual* dates must be verified in metadata; our original February upload had filenames ending `(2)` and was renamed within a **separate local input folder** before processing. Do not infer a period from a filename.

From the cloned repository root:

```powershell
node releases/historical-replay-phase3/scripts/phase3_replay.mjs --worker releases/v4.1/XAU_V4_Worker_v4_1.js --dir C:\XAUExports\Jan2026 --prefix xau_20260106 --out C:\XAUExports\Jan2026\events.csv
node releases/historical-replay-phase3/scripts/export_causal_commands.mjs C:\XAUExports\Jan2026\events.csv C:\XAUExports\Jan2026\commands.csv
node --test releases/historical-replay-phase3/tests/phase3.test.mjs
```

The output has `events.csv`, `events.csv.summary.json`, and `commands.csv`. Research `events.csv` includes future *outcomes* recorded after the fact for auditing. **Never load that events file as pre-approved trading signals into a strategy tester.** `commands.csv` includes only timestamped `ARM` / `CANCEL` events and no outcome-price fields. Its consumer must process each event **only after the tester's current broker-server time reaches `time_server`**. The commands are inputs for *future* Stage 4 EA work, not a finished MT5 tester EA.

### Status and known limitations

- Result dataset: two one-week samples in 2026, **not** the full year.
- **No trading execution, SL/TP simulation, risk sizing, commission, spread-tested fills, swaps, news archive, session validation, or drawdown/Profit Factor.** Historical results here are *hypotheses about setup frequency*, not evidence of profitability.
- Original R1 broker stop is nearest confirmed M5 swing+ATR. That rule is not used here. Original R2 pending order cancellation and broker stop-level restrictions are not simulated.
- M5 rather than per-HTTP-request model refresh, historical quote sampling every second, and offline historical Worker functions can differ from deployed Worker latency and polling. Exact live Worker deployment revision has not been independently verified.
- Tester integration (a separate, restricted-to-Strategy-Tester EA consuming chronological commands) comes in Phase 4. News records/session decisions must be sourced or fail closed. Do not remove safeguards to create results.

See `results/XAU_2026_Jan_Feb_Phase3_Report.md` and CSV/JSON diagnostics for the findings.