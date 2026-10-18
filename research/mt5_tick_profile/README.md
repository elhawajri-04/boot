# MT5 XAUUSD.s Quote-Update Profile v1 (free, offline)

This is a stand-alone, **read-only** JustMarkets MT5 quote tick exporter and Python analyzer for XAUUSD.s. It is **not COMEX order flow**, **not executed trade volume**, not an EA and does not send signals, orders, or cancellations.

## Preserve trading version E

The production trading files `XAU_EA_SmartExec_E.mq5` and `XAU_Worker_SmartExec_E.js` are unchanged. Continue using them as before. No added demo-only restrictions or volatility/news gates were introduced by this research module.

## Simplest use: export quotes from MT5 and share CSV

1. On the PC with MT5 open the **XAUUSD.s** chart; the market may be closed if historical quotes are available.
2. Download `research/mt5_tick_profile/MT5_Export_Quote_Ticks.mq5` into the terminal's **MQL5/Scripts** directory. In MT5 choose **File > Open Data Folder**, then `MQL5/Scripts`.
3. Open that `.mq5` file in MetaEditor and press **F7**. Confirm `0 errors` before running. This is source-only; it has **not** been compiled in a Windows MetaEditor during development.
4. In MT5 Navigator > Scripts, drag `MT5_Export_Quote_Ticks` onto the **XAUUSD.s** chart (right-click Navigator > Refresh if necessary).
5. Leave `InpLookbackCalendarDays=3` to include the most recent Friday when run on Sunday. Set `InpMaxExportRows` higher if you hit the safety cap. Press OK and wait for an Experts message beginning `MT5_QUOTE_EXPORT SUCCESS`. Running this script does **not** attach/replace/remove your existing trading EA.
6. Find `XAU_QuoteTicks_MT5.csv` in the **common** MQL5 Files directory. The full Windows path is printed in the **Experts** tab, e.g. `...\\MetaQuotes\\Terminal\\Common\\Files\\XAU_QuoteTicks_MT5.csv`. You may upload the CSV to ChatGPT for offline analysis. Do not send account passwords, API keys, or private account exports.

**If the script prints FAILED:** take a screenshot of the Experts tab. Do not use a partial CSV. The script deletes its partial output on a failed chunk or safety-limit breach.

`CopyTicksRange(COPY_TICKS_INFO)` returns historical *Bid and/or Ask quote changes*. This remains available for previous trading days after the market closes, subject to the broker's stored tick history. `FILE_COMMON` stores output in MetaTrader's shared Common Files sandbox. Official docs: [CopyTicksRange](https://www.mql5.com/en/docs/series/copyticksrange) and [FileOpen](https://www.mql5.com/en/docs/files/fileopen).

## Optional: analyze exported data locally

Python 3.10 or newer is recommended; uses **only the Python standard library**, no subscriptions or packages.

From repository root:

```bash
python research/mt5_tick_profile/profile.py \
  --csv "XAU_QuoteTicks_MT5.csv" \
  --output "XAU_QuoteProfile.jsonl" \
  --symbol "XAUUSD.s" \
  --bin-usd 0.10 \
  --window-seconds 900 \
  --min-updates 20
```

Results include quote-update count per midquote-price bin, POC, an approximately 70% value area (VAL and VAH), heuristic high/low-activity occupied price levels, mean quoted spread, and up/down **midquote movement counts**.

The first observed window is `left_truncated=true` and not eligible by default. The final observed window is `window_complete=false` and not eligible. Other windows become available only on the **first observed quote in a later window**, as indicated by `available_at_utc`. These rules prevent accidental use of incomplete/future quotes in later analysis.

**Important caveats:**

- The histogram is **quote-event activity**, not true volume-at-price. The same price quote repeated without any change is de-duplicated. The broker's quote frequency, quote filtering and spread affect all results.
- The value area and proxy HVN/LVN are **descriptive** and do not establish supply/demand or proven trade signals. First and last windows need special handling. The value area is expanded from the POC across observed levels; gaps in observed bins are not treated as trading volume.
- `up_midquote_updates` and `down_midquote_updates` must NOT be treated as buyer/seller aggressor Delta, cumulative Delta, time-and-sales, footprint, absorption, or COMEX depth. Those are unavailable from this feed.
- No correlation of XAUUSD.s with COMEX GC futures is claimed and no conversion between broker quotes and GC futures prices is used.
- No changes to R1/R2 filtering, order quantity, SL/TP, expiration, risk policy, the Worker protocol or MT5 auto execution were made.
- The exporter writes the filename configured in `InpOutputCSV`, overwriting any earlier file with that name. Archive outputs you need before re-running.
- Exports may be large and take time; broker history availability varies. The row cap prevents uncontrolled exports and aborts partial files.

## Tests

```bash
python -m unittest discover -s tests -p 'test_mt5_tick_profile.py' -v
```

All tests use synthetic ticks and local files, not real JustMarkets historical quotes, broker execution or trading performance. The MQL5 exporter must still be compiled in the user's MetaEditor before running.

## What comes next

After receiving the first real CSV, validate coverage and quote quality; compute profiles; then compare with *date-aligned* R1/R2 setup and execution logs before considering integration. Separately investigate `R1/R2 EXEC OFF | SESSION` and other trading workflow blockers, which an order-flow indicator cannot fix.
