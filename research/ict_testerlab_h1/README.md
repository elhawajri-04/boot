# Offline ICT/SMC TesterLab replacement — research only

This is a **separate test lab** made from the exact H1 EA and Worker H source the user uploaded. The missing `XAU_EA_H1_TESTERLAB_FULL.mq5` source is **not required**. No production EA or deployed Cloudflare Worker is changed.

## Why the previous test produced zero trades

The `20261019(1).log` and `63.html` for Oct 16, 2026 are a test of `XAU_EA_H1_TESTERLAB_FULL.ex5`, not proof of a non-trading strategy. In that test:

- `InpTesterLabMode=0`;
- offline URL was `https://testerlab.invalid`;
- simulated `GET /zones/latest`, `GET /r2`, and health returned HTTP 503;
- the first run stopped on calendar coverage; the later run finished `valid=true` after 491,124 ticks, but **0 trades** and no qualified Worker replies.

The current lab separately runs the user's **actual Worker H pure ICT/SMC functions** against already exported historical JustMarkets OHLC, then simulates bid/ask fills on exported JustMarkets quote ticks. It additionally exports an MT5 **Strategy Tester-only** trade-entry replay EA and `signals.tsv` for verification by the broker's historical fill engine.

## Actual results from the uploaded historical dataset

- **Dataset**: JustMarkets `XAUUSD.s`, **Feb 2–6, 2026** (this is *not* the Oct 16 backtest period).
- **2,491,352** historical bid/ask snapshots; 1,379 first-tick-of-M5-bar evaluation moments.
- ICT Worker H confirmed **4 unique R1 plans** (3 `SELL_LIMIT`, 1 `BUY_LIMIT`) and **0 R2 plans**. The 4 orders filled on the available quote ticks; 1 won and 3 lost.
- Simplified simulator's **closed P&L = −$48.81** on an illustrative $1,000 initial balance, 5% maximum single-strategy risk, assumed 100 oz/lot, minimum 0.01 lot, 10% combined cap. Maximum **closed-balance** drawdown ≈8.1%.
- No commission, swap, broker fill restrictions, news calendar, exact H1 near-M5-pivot SL replacement, actual H1 active position manager, or session gate; no fees except actual spread. Profitable TP fills capped at TP, adverse SL gap slippage retained. **Not an actual H1 backtest, not live results, not independent proof of strategy profitability.** Four fills are vastly insufficient to assess an edge.
- Distinct repeating `ICT_SMC_CONFIRMED` statuses from successive M5 evaluations were deduplicated by the Worker event setup key.

See `out/summary.json`, `out/candidates.csv`, and `out/closed_trades.csv` for the complete accounting. Live strategies **must not** be modified based on this short, exploratory sample.

## Reproduce the offline research

Requires Node.js v20+ and the actual previously exported files in one folder:

```
xau_20250106_ticks(2).csv
xau_20250106_M1(3).csv
xau_20250106_M5(3).csv
xau_20250106_M15(3).csv
xau_20250106_M30(3).csv
xau_20250106_H1(3).csv
```

Despite `20250106` in filenames, tick source timestamps correspond to Feb 2026. The script checks numeric tick monotonicity and uses only **closed candles** as of the first quote after each M5 boundary, matching the H1 EA candle-count inputs (minus its current incomplete bar).

```
node replay_worker_ticks.mjs --data "C:\\path\\to\\exports" --out out
node tests/test_offline_replay.mjs
```

`Worker_H_uploaded_source.mjs` must remain **byte-for-byte the user's uploaded Worker H**, rather than substituting the older GitHub Worker H release. The H1 source snapshot is included only to establish the correct code baseline.

## Broker execution sandbox (optional, native MT5 Strategy Tester)

The extra EA `XAU_H1_WorkerH_SignalReplay_TESTER_ONLY.mq5` is a **signal-entry replay sandbox**. It is **NOT** the production H1 EA and it cannot run outside `MQL_TESTER`. It deliberately uses broker `OrderCalcProfit`, actual contract size, broker order types and retcodes. It does **not** reproduce the full production EA trade manager or the economic calendar. Passing this test is necessary but not sufficient for an H1 performance claim.

1. Copy `XAU_H1_WorkerH_SignalReplay_TESTER_ONLY.mq5` to MT5 `MQL5/Experts/CodexTesterLab/`, then compile with `F7` in MetaEditor. **It has not been compiled in MetaEditor by this research environment.**
2. Copy the generated `signals.tsv` into `%APPDATA%\MetaQuotes\Terminal\Common\Files\XAU_H1_LAB\signals.tsv` (create directory). The EA defaults to this `FILE_COMMON` relative location.
3. In MT5 Strategy Tester select **this replay sandbox**, `XAUUSD.s`, **Feb 2–6, 2026**, **Every tick based on real ticks**. Use the broker offset matching the exported times; if source time offsets differ from tester time, use `InpSignalTimeOffsetSeconds` and document the correction.
4. Inspect the Experts/Journal tab for accepted/rejected pending orders, and the Deals/Report for broker fill P&L. Compare candidates to `out/candidates.csv`. Broker stop/expiration rules can reject orders; this is valuable diagnostic data.
5. Do **not** attach the sandbox to the live chart; it will deliberately refuse to initialize outside MT5 Tester. Keep production H1 + Worker H unchanged.

## Next step to get a meaningful test of the October 16 market

Export **historical MT5 M1/M5/M15/M30/H1 candles plus actual bid/ask ticks for Oct 16** from the same broker, with original broker-server times and symbol specifications, then run the same Worker analysis. After that, add a faithful H1 trade manager and USD-news calendar to the test harness and validate it against MT5 broker fills. A full profitability conclusion requires more than one short period and out-of-sample testing.
