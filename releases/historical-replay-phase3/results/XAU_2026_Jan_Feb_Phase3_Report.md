# XAUUSD.s 2026 historical Phase 3, two-stage retest research

**Scope:** 2026-01-06 to 2026-01-13 and 2026-02-02 to 2026-02-09. Historical broker symbol XAUUSD.s, 1-second quote sampling using exported real ticks. All candle-only structural confirmations are computed from fully closed bars and pinned Worker V4.1 primitives. **This is not a backtest of profitability, nor does it create a real or simulated broker trade.**

## Head-to-head signal frequency

| Metric | Jan 6–13 | Feb 2–9 | Combined |
|:--|--:|--:|--:|
| Historical seconds sampled | 604,800 | 604,800 | 1,209,600 |
| Original ICTV4 R1 approved signals (Phase 2 baseline) | 0 | 0 | 0 |
| Original ICTV4 R2 approved signals (Phase 2 baseline) | 0 | 0 | 0 |
| **New two-stage variant** structural confirmations R1 | 2 | 3 | **5** |
| **New two-stage variant** structural confirmations R2 | 1 | 0 | **1** |
| R1 quote observations touching retest band | 2 | 2 | **4** |
| R2 quote observations touching retest band | 0 | 0 | **0** |
| Invalidated by HTF change before retest | 1 (R2) | 1 (R1) | 2 |
| Actual broker orders | 0 | 0 | 0 |
| Backtested P&L | Not computed | Not computed | Not computed |

## Details

- **Jan:** One R2 BUY event was recorded at 1767672000 and invalidated at 1767673800 when the larger-timeframe bias changed or became mixed. Two later R1 SELL events at 1767798600 and 1767806100 had a fresh ASK/BID observation in the frozen premium/discount overlap zone after the event, before the one-hour deadline.
- **Feb:** One R1 SELL event at 1770281700 was canceled by HTF change after 5 minutes; two later R1 SELL events at 1770308100 and 1770312600 had post-confirmation in-zone quote observations before one-hour expiry.
- All 6 events used the original Worker zone extraction, but the **lifecycle, retest condition, overlap interval and order assumptions are NEW research rules**. The old Worker would not have approved them at event creation.
- The four retest observations are **not necessarily four fillable or profitable trades**. Bid/Ask presence is confirmed, but broker stops-level, chart sessions, historical news policy, R1 local M5 swing+ATR stops, order sizing, cancellation acknowledgements, TP, SL, spreads over execution, slippage, and margin constraints have **not** been modeled.

## Reproducibility / integrity

- Source Worker V4.1 SHA256: `6d6a7716288a5fb835608ec224f1ef7bd1b6273b7154c98e436289fbe65a8179`.
- Extracted adapter SHA256: `b0b73e69470de5bf40313280a70293532c68276bdcdaf563f56646f15b103571`.
- MT5 exporter `meta.export_status=OK` for both exports. The February upload retained filename prefix `xau_20250106` but metadata is unequivocally February 2026.
- Results files include event IDs, creation time, signal-bar time, zone/value intersections, cancellation/observation times, and quoted prices. Commands CSVs remove outcome prices and must be consumed causally in a future tester EA.
- Fourteen local unit/regression tests pass; they do **not** replace MetaEditor compilation or actual broker-tester validation.

## Next engineering gate

Build a **separate tester-only EA** to consume chronological `ARM` and `CANCEL` commands **at their simulated server time**, execute R1 retests against native MT5 tick quotes using confirmed M5 swing+ATR SL, place R2 LIMIT pending orders only with real broker stop/margin/risk checks, and cancel on expiry/invalidation. Verify all symbols/time-zone offsets. Supply verified historical news/session guard policies (otherwise fail closed); use real-tick tester with commission/slippage/spread. Only then compute Profit Factor, net P&L, and max drawdown. Evaluate longer 2026 development and independent out-of-sample data before concluding edge.