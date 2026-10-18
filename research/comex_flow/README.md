# COMEX GC Historical Order Flow, v1

**Status:** research engine completed and locally unit-tested. The production trading sources **`XAU_EA_SmartExec_E.mq5`** and **`XAU_Worker_SmartExec_E.js`** are **unchanged**. No live feed, cloud deployment, real Databento dataset, historical trading performance, or MT5 execution is implied.

## الهدف

Build reproducible historical volume features **from actual GC futures trades** before deciding whether such features improve R1 and R2 on XAUUSD. This code never sends orders and never injects `READY` into the EA. Historical trade count and market structure must be evaluated separately from broker execution failures.

## Input and data sourcing

- Venue / dataset: Databento `GLBX.MDP3`, product **COMEX standard Gold Futures (`GC`)**, schema `trades`.
- The CSV must include `ts_event,price,size,side` plus `symbol` or `instrument_id`, optionally `action`. `.csv` and `.csv.gz` are supported.
- `side=B` means **buyer aggressor**, `side=A` means **seller aggressor**, and `side=N` means **unknown**. `N` volume counts in profile, not Delta or CVD. These are **executed trades**, not standing-book depth.
- Use the **specific listed contract** for your chosen historical dates, for example a relevant `GC` expiry, verified in Databento's instrument definitions. **Never silently stitch different expiries**, their prices and volume structures can differ.
- Standard `GC` minimum price increment is **$0.10 per troy ounce** according to CME; this script requires the tick increment explicitly. It is not an XAUUSD broker-point specification.
- Specify `--price-format pretty` if the CSV was exported with `pretty_px=True` (prices already in dollars). Specify `raw-1e9` only if exporting Databento's raw integer prices. The engine intentionally rejects ambiguous ticks, missing identities, unsorted timestamps and invalid price scales.
- The script does **not** require an API key; it operates only on a user-provided authorized export. Do not commit keys, private transaction data or licensed raw feeds to a public repository.

### Example: obtain an authorized trades CSV through Databento

Install `databento` into your own Python environment and use a Databento API key in a local environment variable. Do **not** paste it into chat or GitHub.

```python
import databento as db

client = db.Historical()  # reads DATABENTO_API_KEY from your local environment
# Replace symbols/date range with an ACTUAL contract listed during your requested range.
store = client.timeseries.get_range(
    dataset="GLBX.MDP3",
    schema="trades",
    symbols=["GCZ6"],
    start="2026-10-12T12:00:00Z",
    end="2026-10-12T13:00:00Z",
)
store.to_csv("gc_trades.csv", pretty_px=True, pretty_ts=True, map_symbols=True)
```

This is an **illustrative API request, not an executed query**. Historical data access and fees depend on the account. Review the contract symbol and its active/liquid dates before downloading. Reference: https://databento.com/docs/api-reference-historical

## Offline analysis

From the repository root:

```bash
python research/comex_flow/engine.py \
  --csv gc_trades.csv \
  --output gc_features.jsonl \
  --price-format pretty \
  --tick-size 0.1 \
  --contract GCZ6 \
  --window-seconds 300 \
  --min-trades 20 \
  --min-known-ratio 0.8 \
  --include-levels
```

The output is newline-delimited JSON with **one record per observed time bucket**, and includes:

- aggressor buy/sell/unclassified quantities (contracts), volume Delta and **input-anchored** CVD;
- POC, VAH, VAL, volume-weighted average price and per-price histogram for each fixed time bucket;
- diagonal *executed-volume* Footprint imbalance levels, stacked counts, and optional per-tick counts;
- input/data coverage diagnostics and an explicit timestamp at which the prior time bucket became available;
- `mode=HISTORICAL_OBSERVATION_ONLY`, `execution_allowed=false`, and a **quality flag**, never an order.

The last time bucket lacks the next bucket's timestamp, so `window_complete=false`, `available_at_utc=null` and `usable_for_research=false`. The very first bucket may also be left-truncated depending on the CSV start time, so omit it when making a strict forward-only comparison unless the export fully covers it. **Join features using `available_at_utc`, never using later trade data or blindly using window boundaries.**

**Important limits:**

1. This is a **fixed-window** volume profile, **not** an exchange trading-session composite profile. CVD resets when the input file begins, not at CME's session boundary. Use consistent file boundaries across tests.
2. Trade prints can estimate aggressor Delta and trade-volume imbalance, but **cannot validate hidden orders, liquidity replenishment, true absorption, cancellation imbalance, or full depth**. For that research, add `mbo`/`mbp-10` data in a separate future stage.
3. No independent support/resistance or trade placement rules have been added. The `feature` output must not be interpreted as a buy/sell signal.
4. **COMEX GC futures prices differ from a particular broker's XAUUSD spot/CFD quotes**. Never paste GC POC/VAH/VAL onto the broker chart without time alignment, contract selection and a basis/price mapping policy.
5. If a later comparison claims fewer trades or better performance, replay **the same existing EA/Worker E setup decisions and broker execution logs** against the historical features. Measure signal count, conversion to broker orders, rejection codes, net expectancy after spread/fees and max drawdown using held-out time periods. The current project does **not** have the required full synchronized history and makes no profit or trade-frequency claim.

## Testing

```bash
python -m unittest discover -s tests -p 'test_comex_flow.py' -v
```

All tests use **synthetic fabricated trade records** to verify math, chronological gating, file safety and rejection of malformed input. The tests do **not** backtest a strategy and should not be described as win-rate evidence.

## Research change control

These files are standalone in `research/comex_flow/` and `tests/`. They are not imported by Worker E or compiled into EA E. **Do not alter current trading criteria** before evaluating the model against real, licensed, date-matched historical data.

## Authoritative references

- Databento trade schema and aggressor side: https://databento.com/docs/schemas-and-data-formats/trades
- Databento fixed-price normalization: https://databento.com/docs/standards-and-conventions/common-fields-enums-types
- Databento GLBX.MDP3 coverage: https://databento.com/docs/venues-and-datasets
- Databento historical CSV and `DBNStore.to_csv`: https://databento.com/docs/api-reference-historical
- CME GC contract specifications and $0.10 tick: https://www.cmegroup.com/market-regulation/files/gold-futures-and-options-fact-card.pdf
