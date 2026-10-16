# Phase 4 implementation status (16 October 2026)

## Corrected structural + two-stage replay on two separate 2026 weeks

| Metric | Jan 6–13 | Feb 2–9 | Sum |
|---|---:|---:|---:|
| Confirmed M5 R1 events | 2 | 3 | 5 |
| Confirmed M15 R2 events | 1 | 0 | 1 |
| Historical R1 in-band BID/ASK touch observations | 2 | 2 | 4 |
| Historical R2 touches | 0 | 0 | 0 |
| Time-scoped ARM command records | 3 | 3 | 6 |
| Causal CANCEL records | 1 | 1 | 2 |
| Observed MT5 broker fills | **not tested** | **not tested** | **not tested** |
| Validated Profit Factor / drawdown | **not available** | **not available** | **not available** |

- Worker source SHA256 pinned: `6d6a7716288a5fb835608ec224f1ef7bd1b6273b7154c98e436289fbe65a8179`.
- Original source adapter SHA256: `b0b73e69470de5bf40313280a70293532c68276bdcdaf563f56646f15b103571`.
- Research adapter SHA256 after ONLY latest-pivot break fix: `78589c92d37969ca31c33fdf023cf7f60576c2e06f2d8232c9b933f43c4a6617`.
- Six structural confirmations remain after correcting the BOS pivot filter; the replay has not manufactured additional opportunities in these weeks.
- Both results were generated from closed H1/M30/M15/M5/M1 bars and past bid/ask ticks, 604,800 broker-server seconds per week.
- Nine tests passed with `node --test tests/phase4.test.mjs` (includes regression against stale pivot, quote freshness, R2 limit-only static guard, chronological instructions); **none is an MT5 compilation or tester trade run**.
- The provided EA enforces news fail closed by default due to **missing independent historical news verification**. Testing with the explicit unverified-news toggle only checks execution feasibility, not validated profitability.
- EA has an explicit `MQL_TESTER` guard: cannot be attached to a live/demo chart. Current live/demo V4.4 and deployed Worker left unchanged.

**Next mandatory checkpoint:** compile `mt5/XAU_Phase4_Research_Tester.mq5` in Windows MetaEditor (0 errors), then submit real-tick Strategy Tester Experts/Journal and HTML report with verified news session coverage. Analyze order placement/SL/rejections and correct compiler/broker validation issues before changing the production Worker.