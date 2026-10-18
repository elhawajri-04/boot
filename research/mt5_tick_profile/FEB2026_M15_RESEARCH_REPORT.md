# JustMarkets XAUUSD.s MT5 Quote Profile: February 2–6, 2026

**Status:** Observational historical research. This is not an R1/R2 signal replay, order-flow tape, or execution/profitability backtest. No changes to `XAU_EA_SmartExec_E.mq5` or `XAU_Worker_SmartExec_E.js`.

## Inputs and time validation

- Broker: JustMarkets, symbol `XAUUSD.s`.
- Source: user's exported `xau_20250106_ticks(2).csv`, `xau_20250106_meta(3).csv`, `xau_20250106_M15(3).csv`.
- Although these filenames suggest January, the actual timestamps cover **2026-02-02 through 2026-02-06 UTC**. Always trust timestamps over names.
- Tick CSV contained no `symbol` field. Its per-file symbol was recovered from the paired `meta.csv`, and enforced on each exported analysis record.
- Observations are **bid/ask quote changes**, not executed trade volume or COMEX aggressor side. All matched M15 real-volume values were zero.
- M15 bar times were joined by exact UTC timestamp. Final incomplete profile and first left-truncated profile are excluded. Comparisons to the next bar also exclude gaps longer than 15 minutes.

## Data volume

| Metric | Result |
|---|---:|
| Raw bid/ask tick records | 2,491,352 |
| 15-minute quote-profile windows | 460 |
| Exact M15 timestamp matches | 460 |
| Profile windows eligible by chronological rules | 458 |
| Eligible comparisons to *consecutive* next M15 candle | 454 |
| Earlier sample, Feb 2–4 | 272 |
| Later check, Feb 5–6 | 182 |
| M15 bars with non-zero `real_volume` | 0 |
| Exact quote update counts matching broker M15 tick volume | 150/460 |

The number of quote changes counted from the exported tick data may differ slightly from broker M15 `tick_volume` because of feed aggregation, duplicate quote snapshots, flags, and feed recording conventions. Do not force these counts to match.

## Exploratory comparisons (Pearson correlations)

| Quantity compared | Observed value |
|---|---:|
| Quote-update count vs **same** M15 candle range | **0.737** |
| Quote-update count vs **next** consecutive M15 candle range | **0.589** |
| Midquote up/down pressure vs next M15 close change | **0.056** |
| Midquote up/down pressure vs next M15 close change, Feb 5–6 only | **0.088** |

A simple sign-of-quote-pressure heuristic matched the next M15 candle direction **53.85%** over the later 182 candles. The fraction of upward next candles was **50.55%**. This difference is too small and fragile to establish an edge; the heuristic ignores transaction costs, spread, session bias, filtering, and trading rules. These are simple observations, not trade signals.

On Feb 2–4, the 75th percentile threshold of quote-update count was **6591.75** per 15-minute window. Applying this *unchanged* threshold to Feb 5–6:

- 17 higher-activity M15 windows: mean next range **$44.25**.
- 165 other windows: mean next range **$24.79**.

This is compatible with volatility persistence, not proof that high quote activity predicts direction or increases profitable trading frequency. The held-out period includes only two dates and is not enough for production changes.

## Conclusions

1. **Potentially useful:** an activity/volatility context feature and future Volume Profile price-area annotation. Test whether it adds information beyond ATR, session, and current R1/R2 filters.
2. **Not demonstrated:** quote direction pressure as an independent BUY/SELL confirmation. The association with next-candle direction is weak.
3. **Not demonstrated:** any reduction in EA/Worker order rejections or `EXEC OFF | SESSION` state. Those are technical/session gates not addressed by volume data.
4. **Not yet testable from these inputs:** whether actual R1/R2 setups were more frequent or profitable. The supplied `XAU_AUDIT_...csv` dates are from October, not the February tick interval. A timestamp-aligned strategy decision/execution audit or a faithful offline replay would be needed.

## Safety, method and scope

- The underlying `research/mt5_tick_profile/profile.py` produces quote-frequency profiles, including POC/VAH/VAL/HVN/LVN *proxies*. These are not COMEX market-volume levels.
- All predictive comparisons use one period's features and the subsequent *consecutive* M15 candle; partial and gapped windows are excluded. The profile is only considered known after its next observed quote (`available_at_utc`). **This is still not a trade-executable backtest** because no bid/ask fills, latency, strategy orders or commission are simulated.
- The production files remain unchanged. No new input flags, kill switches, order cancel rules or profitability claims were introduced.

## Suggested next step

Add read-only quote activity and profile metadata to an offline strategy replay with the same time range, then test the incremental value of profile features compared with ATR/session-only baselines. Only after enough held-out periods show an actual benefit should we consider changing R1/R2 entry conditions.
