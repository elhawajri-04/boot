# XAU Historical Replay, Phase 1 (Signal Audit)

This is an isolated research tool. It **does not** modify or deploy the live Cloudflare Worker, the Demo/Live EA, or your D1 database. It does **not** place orders or claim historical profits.

## What exists today

- `mt5/XAU_Historical_Exporter.mq5`: MQL5 script exporting M1, M5, M15, M30, H1 candles and original bid/ask ticks in bounded time chunks. Source files are written to **Terminal/Common/Files**. One week is the default test period. A separate 30-day bar warmup is included for confirmed higher-timeframe structure.
- `scripts/worker_replay.mjs`: Node.js 22+ offline runner. It reads the actual Worker source file `releases/v4.1/XAU_V4_Worker_v4_1.js` and extracts the exact `ICTV4` adapter rather than recoding the strategy. Prints Worker file SHA256 and adapter SHA256 to identify what was tested. It advances one **completed M5 candle** at a time, feeds only fully closed M1/M5/M15/M30/H1 candles, and uses only previously arrived bid/ask ticks.
- `tests/replay.test.mjs`: automated replay sanity/regression tests, including future-bar exclusion, unavailable ticks, and incomplete exports.

**Important:** This is a research-only signal replay, not yet a strategy-testing EA, not a broker fill simulator, not an exact reproduction of the live EA's 1-second polling, news and session guards, R1 local swing stop, R2 pending lifecycle, dynamic lot sizing, or trade management. Thus the file's `execution_eligible` column is always `0`. Never interpret `raw_allowed=1` as a fill or as profit.

## Export from MT5

1. In MT5, select the actual gold symbol, e.g. `XAUUSD.s`, confirm sufficient historical candles and real ticks are available from your broker.
2. Open **MetaEditor** (`F4`), create or copy `XAU_Historical_Exporter.mq5` into `MQL5/Scripts`, press `F7` and verify **0 errors**. We cannot compile MQL5 in this environment.
3. Return to MT5, drag the script from Navigator > Scripts onto the **gold chart**. You may need to enable scripts. No AutoTrading permission or Worker URL is needed because this script never trades or contacts the network.
4. For the first sanity check, use `InpStartServer=2025.01.06 00:00`, `InpEndServer=2025.01.13 00:00`, `InpWarmupDays=30`, `InpPrefix=xau_20250106`, `InpExportTicks=true`.
5. Wait for `XAU HISTORICAL EXPORT COMPLETE` in the Experts tab. A `INCOMPLETE` status is **not** usable. Open MT5 menu **File > Open Data Folder**, navigate up to `Terminal`, then `Common/Files` (or use `TerminalInfoString(TERMINAL_COMMONDATA_PATH)` to locate it). Keep six CSV outputs together: `_M1`, `_M5`, `_M15`, `_M30`, `_H1`, `_ticks`, plus `_meta`.

CSV time fields are numeric MT5 timestamps. The replay uses exactly the broker-exported time fields, not your PC clock. **Verify** the tick timestamps and bar times agree; otherwise don't backtest.

## Replay offline (Node.js 22+ installed on PC)

Clone the repository and check out branch `release/historical-replay-phase1`. Assuming your exported files are at `C:\\XAUExports`:

```powershell
node releases/historical-replay-phase1/scripts/worker_replay.mjs --worker releases/v4.1/XAU_V4_Worker_v4_1.js --dir C:\XAUExports --prefix xau_20250106 --out C:\XAUExports\signal_audit.csv
```

Outputs: `signal_audit.csv` and `signal_audit.csv.summary.json`. They distinguish `R1` and `R2` signals, show raw Worker confirmation, zone prices and planned levels, reasons for waiting, and mark trade execution as ineligible until the historical news guard and EA tester integration exist.

To run automated regression tests from repository root:

```powershell
node --test releases/historical-replay-phase1/tests/replay.test.mjs
```

## Next phase, no look-ahead

1. Check exports and timestamps against one broker week before importing a full year.
2. Add a **read-only** Strategy Tester version of the V4.4 EA that consumes immutable historical decisions from a packaged local file, including recorded news/session policies or conservative fail-closed rules. The current EA uses `WebRequest`, which is unavailable in Strategy Tester.
3. Calculate final R1 SL from the same confirmed M5 swing+ATR rule used in the EA (do not use Worker structural invalidation as a scalp stop). Preserve R2 Pending Only, expiration, risk caps and life-cycle cancellations.
4. Run Strategy Tester in **Every tick based on real ticks**, include spread, commission, slippage, swaps and broker minimum stop-distance; produce R1/R2 separate real tester outcomes.
5. Split development and final out-of-sample periods; don't use the final period to tune parameters.

### Why there is no profitability number yet

- MT5's Strategy Tester does not execute `WebRequest`; calling production Worker during historical simulation is not a faithful replacement.
- `Date.now` and D1 `latest_market` in some legacy Worker utilities refer to wall time; calling them during historical replay risks false freshness decisions. Phase 1 invokes only the exact source's **pure ICT/SMC V4 adapter**. Legacy regime, cloud DB, news and live routing are NOT executed or imitated.
- The one-M5-bar cadence is a lower-frequency research sample, whereas live R1 and R2 poll the Worker faster. This must be reconciled before reporting fill rates or money returns.

Official API docs: https://www.mql5.com/en/docs/series/copyrates , https://www.mql5.com/en/docs/series/copyticksrange , https://www.mql5.com/en/docs/network/webrequest , https://www.mql5.com/en/docs/files/fileopen