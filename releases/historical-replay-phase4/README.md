# Phase 4 — XAUUSD.s 2026 causal execution **RESEARCH** / MT5 Strategy Tester

**Status:** Node.js replay and 9 local code/regression tests executed; `.mq5` *has not yet been compiled in Windows MetaEditor or executed in MetaTrader 5 Strategy Tester*. No fill/profitability or production-readiness claim. Version V4.4 deployed/demo EA and Worker V4.1 source were NOT modified or deployed.

## Requirements covered

1. **Newest confirmed BOS/CHOCH swing:** Research replay loads exact original Worker V4.1 adapter, validates original SHA256 `6d6a7716288a5fb835608ec224f1ef7bd1b6273b7154c98e436289fbe65a8179`, and modifies only two specific filters in `breakOfStructure` from `x.index<n-3` to `x.index<=n-3`. For two bars to the right, the pivot at `n-3` is already confirmed. A negative synthetic regression test catches older-pivot false BOS.
2. **Capture confirmation only after full candle close:** same original Worker M5 and M15 analyzer, run at exact closed-candle timestamps (`t+TF_SECONDS <= now`); event identity is frozen (`engine_side_lastclosedbar`), and research state persists rather than requiring the breakout close to lie in the retest value area.
3. **Causal time-limited retest:** R1 expires 1h, R2 6h, or earlier on HTF change/structural invalidation, according to Phase3 research rules. Quote sampling once/second only, using past ticks up to current clock; `ARM`/`CANCEL` generated with no future outcome prices. Initial candidate must start outside a compatible Premium/Discount and FVG/OB overlap. An observed touch is NOT a broker fill. R1 tester waits for later in-band Bid/Ask quote and closed M5 confirmation; R2 places a LIMIT-only pending order at ARM, subject to broker checks.
4. **Execution gates:** Tester EA validates current bid/ask freshness, server trading session and configurable session window, spread, close-only local M5 swing + M5 ATR stop for R1 (not far structural invalidation), M15 ATR beyond zone distal for R2, risk/lot step and 1%-of-equity order risk, 5%-aggregate stop risk, `OrderCalcProfit`, `OrderCalcMargin`, tick size, broker stop+freeze levels, price distance, and broker return codes. R2 pending cancellations wait for actual broker acknowledgement and throttle retries while market closed. Check historical commissions and swaps in the tester's broker deal history.
5. **Broker testing:** `.mq5` refuses `OnInit` outside the Strategy Tester. Tests use MT5 `Every tick based on real ticks`, symbol `XAUUSD.s`, chart M5, one week at a time; compare accepted orders, fills and broker journal against the original signal audit. Do **not** use output as evidence of profitable edge without verified news & historical session policies, realistic costs, more data and holdout.

## Files

- `scripts/phase4_replay.mjs` — strict research replay, original Worker V4.1 pinned + *only corrected pivot eligibility*; separate two-stage lifecycle.
- `scripts/export_causal_commands.mjs` — returns `ARM`/`CANCEL` streams, stripped of future outcome/touch data.
- `mt5/XAU_Phase4_Research_Tester.mq5` — tester-only EA (source for Windows MetaEditor compilation).
- `mt5/phase4_news_clear.csv` — blank **fail-closed** template. No historical news has been verified yet.
- `results/jan_commands.csv`, `results/feb_commands.csv` — chrono command streams created from corrected source.
- `results/jan_events.csv`, `results/feb_events.csv` and summaries — quote-only research; do NOT feed these event files to the tester.
- `tests/phase4.test.mjs` — 9 Node regression/static tests; **not MQL5 compilation or backtest execution**.

## Running the corrected signal replay (Node 22+)

From repository root, with your January and February exporter files placed in independent folders. The files must match prefix; use metadata timestamps, not filename, to choose the week.

```powershell
node releases/historical-replay-phase4/scripts/phase4_replay.mjs --worker releases/v4.1/XAU_V4_Worker_v4_1.js --dir C:\XAUExports\Jan2026 --prefix jan26 --out C:\XAUExports\Jan2026\jan_events.csv
node releases/historical-replay-phase4/scripts/export_causal_commands.mjs C:\XAUExports\Jan2026\jan_events.csv C:\XAUExports\Jan2026\jan_commands.csv
node --test releases/historical-replay-phase4/tests/phase4.test.mjs
```

## Running the tester in Windows (first compile, no real account trades)

1. In **MT5 File > Open Data Folder**, copy `mt5/XAU_Phase4_Research_Tester.mq5` to `MQL5/Experts/`. Open using **F4** and compile using **F7**. **Send MetaEditor compiler errors before going further if any**. No `.ex5` binary is supplied, and compiler success has not been verified here.
2. Place `results/jan_commands.csv` in `MQL5/Files/` and rename the copy exactly `phase4_commands.csv`. Also put `mt5/phase4_news_clear.csv` in `MQL5/Files/`. The latter is **blank** by design. Do not put price/research `events.csv` in place of `commands.csv`.
3. Open **Ctrl+R** Strategy Tester. Expert: `XAU_Phase4_Research_Tester`; symbol: `XAUUSD.s`; period: `M5`; modeling: **Every tick based on real ticks**; dates 2026-01-06 through 2026-01-13. Use a **demo-style tester deposit**. Live/demo chart operation is prohibited by MQL_TESTER guard.
4. By default, `InpResearchAllowUnverifiedNews=false`: tester **refuses to start**, as no trusted historical CLEAR intervals have been provided. This is an intentional news fail-closed guard. To **diagnose broker execution only**, the user may explicitly set `InpResearchAllowUnverifiedNews=true`; the EA logs `UNVERIFIED HISTORICAL NEWS OVERRIDE` and results must **NOT** be interpreted as trustworthy profitability or risk-adjusted trading claims. For production-quality results, collect sourced, independently checked *historical CLEAR windows* and populate `phase4_news_clear.csv` with `from_server,to_server,decision,source`, epoch server seconds, `CLEAR`, and non-template provenance; include at least 300 seconds buffer before blocked news. The code cannot independently verify that submitted sources are authentic.
5. In **Experts / Journal** watch `P4|R1|...` / `P4|R2|...` reasons such as `REJECT`, `PENDING_ACCEPTED`, `MARKET_ACCEPTED`, `CANCEL_OK`, `CANCEL_RETRY`. Save the tester HTML report and Journal, then repeat with February `results/feb_commands.csv` replacing `phase4_commands.csv`, date 2026-02-02 through 2026-02-09. Confirm symbol suffix and server clock match CSV export.
6. Compare all accepted/rejected command outcomes (including `TRADE_RETCODE`, pending placement vs actual fills, position SL/TP) and account commissions/spread with the audit. **Do not paste the Phase4 tester-only logic directly into live V4.4** without further review.

## Explicit limitations

- `MQL5` has no local MetaEditor compiler here; the source was reviewed + tested statically, not compiled or broker-tested. An uncompilable line might still exist and must be fixed from the Windows error list.
- Historical tick files came from broker exporter, but MT5's actual real-tick tester history/available tick stream must independently cover the periods. Broker sessions can vary historically; `SymbolInfoSessionTrade` is only as good as the tester's symbol settings. The EA stops outside a reported broker trading window (including weekends).
- `phase4_commands.csv` is a **research signal hypothesis** generated by an offline replay with perfect local candle/tick availability. Neither latency nor news availability has been matched to live Worker/EA. No transactions were submitted from this chat.
- The EA risk calculations are based on `OrderCalcProfit` and stop-loss prices; historical gaps can exceed planned loss. R1 one-market order upon retest and R2 pending-limit are the research strategies; not necessarily identical to present live EA.
- Any outcome price or `observed_touch` in `results/*_events.csv` is **ex post** audit only. Tester receives only causal `ARM`/`CANCEL` files, and processes commands no earlier than their timestamp.