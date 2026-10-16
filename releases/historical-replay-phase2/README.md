# XAU 2026 Historical Replay: Phase 2, 1-second Quote-Clock Audit

This is an **offline research-only signal audit**, not an MT5 EA, executable signal engine, historical profit test, or real broker execution simulator. No Cloudflare D1, Worker deploy, Demo, or Live bot was modified.

## Purpose and what is unchanged

- Reuse the original `ICTV4` closed-candle adapter **directly from** `releases/v4.1/XAU_V4_Worker_v4_1.js` by extracting the source block and evaluating it in a local Node.js VM. No reconstruction of the original signal rules.
- Refresh the closed-candle confluence on each M5 close (M15/H1 etc. remain available only after close). Check quote-dependent plan at each *historical broker second* when the confluence is already confirmed. Cache fixed no-confluence rejections for speed.
- Consume ONLY received tick records with timestamp at or before the event time. Refuse positive signals with missing or stale Bid/Ask, malformed or incomplete exports; enforce R2 pending-only.
- Save transition-oriented diagnostic rows (CSV, no giant one-row-per-second file), with stage-level confirmation counts and quote statistics in `.summary.json`.

### Limitations, critically important

- **`execution_eligible=0` in every row**, always. No broker fills, no live EA R1 M5 swing SL, no news calendar, no session guards, no pending lifecycle, no profit accounting, no risk sizing.
- The replay is based on the **ICTV4 adapter**, not full Cloudflare Worker legacy calculations or deployed network latency. The 1-second sampled broker quote is a research approximation, not the exact production polling sequence.
- Zero confirmed model setups in a *single week* do not prove the algorithm cannot produce valid signals in other periods, nor prove the trading system is unprofitable. Stage conditions may be excessively strict and merit separate investigation, but don't loosen them without independent validation.
- A tick CSV can be missing broker-market hours including weekends. Count of `quote_stale_or_missing` includes closed market periods; this is not a Worker connectivity error.

## How to run (Windows PowerShell, Node.js 22+)

Keep the existing exports together in e.g. `C:\XAUExports`; despite its prefix `xau_20250106`, the supplied `_meta.csv` start/end timestamps are **2026-01-06 through 2026-01-13**.

From repository root on branch `release/historical-replay-phase2`:

```powershell
node releases/historical-replay-phase2/scripts/worker_replay_tick.mjs --worker releases/v4.1/XAU_V4_Worker_v4_1.js --dir C:\XAUExports --prefix xau_20250106 --out C:\XAUExports\tick_replay_20260106.csv --cadence-seconds 1
```

Optional `--cadence-seconds 5` or `300` (any positive divisor of 300) and `--max-quote-age-ms 30000`. First one matches near-second research cadence, and 300 is a baseline close-only comparison. `--max-events N` is for quick diagnostics, not an exhaustive week.

Results: `tick_replay_20260106.csv` (changes and signal transitions) and `tick_replay_20260106.csv.summary.json` (every sampled second counted, detailed M5 model-stage diagnostics). **Only 1-second results should be used for quote-opportunity comparison.** Rows are NOT broker deals.

Run tests:

```powershell
node --test releases/historical-replay-phase2/tests/replay_tick.test.mjs
```

## Actual independent 2026-01-06 to 2026-01-13 research sample

- 604,800 second-clock sample points, 1,380 closed-M5 confirmation evaluations
- Original Worker adapter confirmed **0 R1** and **0 R2** complete ICT/SMC setups on this one week
- 0 quote-dependent raw R1 or R2 entries, as expected when closed-bar confluence never confirms
- Model H1/M30 combined HTF bias at M5 closes: `MIXED 978`, `BUY 282`, `SELL 120`
- Per R1 model confirmation: `WAIT_HTF_BIAS 978`, `WAIT_SWEEP 315`, `WAIT_DISPLACEMENT 66`, `WAIT_BOS_CHOCH 19`, `WATCH_VALUE 2`
- Per R2 model confirmation: `WAIT_HTF_BIAS 978`, `WAIT_SWEEP 360`, `WAIT_DISPLACEMENT 39`, `WATCH_VALUE 3`
- 191,595 second samples had no fresh quote within 30 seconds; includes nontrading hours
- **No profitability statistics.** The original Worker code SHA-256 is pinned in each output summary.

## Next steps towards trustworthy profitability testing

1. Repeat 1-second audit on 2026 months, in independent chunks, using accurate `InpStartServer`, `InpEndServer` and distinct exporter prefixes (e.g. `xau_20260201`). Require `export_status=OK` and tick coverage evidence; no invented data.
2. Confirm whether any month contains legitimate confirmed confluence. If none, audit conditions formally before altering strategy, and do not misinterpret “no trades” as zero drawdown/profitable.
3. Create separate MT5 Strategy Tester EA consuming *immutable, version-pinned historical decisions*. Recalculate R1 SL at nearest confirmed M5 swing + ATR, and preserve R2 Pending Only and broker risk/expiration/cancel rules.
4. Feed a verified historical news/session policy and MT5 real ticks; absent policy = **fail closed**, not a fake success. Run actual fills with spread/commission/slippage and out-of-sample splits. Do not claim profits from signal rows.

This code and report are for 2026 study only. The V4.4 Demo/Live EA and Cloudflare Worker are unchanged.