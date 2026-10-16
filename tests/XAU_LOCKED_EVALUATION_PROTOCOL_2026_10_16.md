# XAU R1/R2 locked evaluation protocol v1, 2026-10-16

Status: STARTED signal replay tooling. Full historical trade/PnL parity NOT YET COMPLETE.

## Frozen pair
EA: XAU_Market_Zones_v3_5_38_R1_R2_Single_Risk_Sized_Order.mq5
EA Git blob SHA: d38491472f992f6fc802eb6334ab866f7f532422
Worker: XAU_Worker_R2_v2_8_EA_Direct_R2_No_Shadow_Queue.js
Worker blob SHA: 54e393abaea35714ea364f3dd4360f77b80659e0
Do NOT mix with the similarly named plural Single_Risk_Sized_Orders.mq5, whose content differs.
Risk defaults: R1 5%, R2 5%, total XAU 10%, one risk-sized R1 market order per READY, one R2 pending order per valid setup. London 08 UK seasonal opening through broker 23:59. A nominal stop-risk ceiling does not guarantee no slippage.

## Testing stages, do not combine
A. Exact original Worker v2.8 decision functions on exported historical MT5 snapshots: IMPLEMENTED as separate exporter and offline replay script. Reproduces Regime R1, R1 calculated zones and R2 candidate selection, not live EA confirmation/SL and fills. No historical news feed yet. Snapshot cadence 60 sec by default vs live market snapshots every 10 sec. No profitability conclusions from this stage.
B. Exact EA state machine, R1 locked zone+M5 READY and scalp swing stop, R2 pending order creation/expiry, volume/risk/margin, broker execution: NOT YET IMPLEMENTED in a tester-only adapter. Historical PnL unverified.
C. Historical calendar block decisions: NOT AVAILABLE via native Strategy Tester calendar, exporter correctly marks UNKNOWN. Do not fabricate history.
D. Live forward test on separately isolated broker DEMO + Worker + D1: protocol prepared, cannot start without the user's MT5 running and reports.

## First historical snapshot run (smoke test)
1. In MetaEditor open tests/historical/XAU_Historical_Snapshot_Exporter_v1.mq5 and press F7. It refuses live-chart initialization and places no orders.
2. Open MT5 Strategy Tester using exporter and exactly the same broker XAUUSD symbol suffix as live, M5, mode Every tick based on real ticks.
3. Initial period 2026-09-01 through 2026-09-04, plus historical warm-up bars. InpCaptureEverySeconds=60, InpMaxRows=3000. Use 10-second snapshot cadence only for bounded parity checks, size becomes large.
4. Verify InpBrokerUtcOffsetMinutes for the broker's UTC offset DURING the historical period, not Palestine time. Split runs if broker DST offset changes. Save exact setting alongside the run.
5. After the test, find XAU_HISTORICAL_SNAPSHOTS_v1.jsonl inside MT5 terminal Common/Files and verify it is nonempty. Do not publicly publish raw account logs or secrets.
6. Download Worker v2.8 JS and tests/historical/XAU_Worker_Snapshot_Replay_v1.cjs into one folder, install Node 22+, and run:
   node XAU_Worker_Snapshot_Replay_v1.cjs XAU_Worker_R2_v2_8_EA_Direct_R2_No_Shadow_Queue.js XAU_HISTORICAL_SNAPSHOTS_v1.jsonl XAU_WORKER_SIGNALS.csv
7. Inspect decision CSV and errors. Valid R2 candidate at 10 nearby timestamps does NOT equal 10 trades.
8. Run on additional months only after the short test is verified and disk capacity checked.

## Exact parity gate before PnL
Compare a timestamp-aligned historical snapshot and EA execution state for: five timeframes and closed bars, EMA/RSI/ATR, R1 regime/zones, zone lock invalidation lifecycle, M5 READY and confirmed pivot SL, R2 selected strategy order entry/SL/TP/expiry, UK DST and broker session, historical USD news, single-order lots, total risk, broker volume/margin, order validity and expiration, gap/spread/slippage/commission/swap, netting/hedging, concurrent R1 and R2 exposure.
If any of these is missing or mismatched, resulting profit statistics must be labeled APPROXIMATION, never exact current-version backtest.

## Fixed evaluation cohorts
Historical development diagnostics, if ticks are available: 2024-01 through 2025-12.
Historical observed / not independent: 2026-01 through 2026-09 (prior 2026 tests already viewed).
Untouched out-of-sample holdout: DEMO forward observations from first functioning market session after setup, tentatively 2026-10-19 onward, minimum 8 to 12 trading weeks, ideally at least 100 independent closed setups EACH for R1 and R2. Sparse setups require a longer wait, not a premature pass.
Evaluate R1 only, R2 only, and both together; report by strategy, regime and calendar month. Never optimize against the holdout.

## Forward demo operations
Use a DEMO terminal, separately isolated Worker/D1 URL/token, not the production D1 or production account. Do not alter the live EA to test; start a separate test environment. Capture original version SHA, broker symbol, account type, leverage, commission, swap, lots, stop requirements, slippage.
Every week export: XAU_AUDIT_*.csv (MetaTrader Common Files), MT5 Account History detailed report, Experts + Journal logs, and daily (ideally intraday) equity snapshots. Do not include authentication keys. Keep historical logs separated by version.
Every complete trade basket requires initial risk, final NET PnL including commission/swap, engine ID, setup class, timestamps, fill and stop. Count partial closes as one logical basket for inference. Report missed/blocked signals separately from actual fills.
Track runtime and bridge errors, unknown/missing SL, duplicate signals, risk cap failures, rejected orders and overnight pending status.
Stop unattended testing on any protective order error until investigated. For real-money accounts, disable autonomous new entries during safety investigation.

## Pre-registered exploratory go/no-go targets
Minimum 8 to 12 weeks plus ~100 independent closes per engine. Net PF >1.20, positive expectancy per initial risk unit R, max equity drawdown <=15% AT TESTED RISK, consistent months, no breach of planned 5% per-engine/10% total risk limits and zero unhandled protective failures. These are evaluation gates, not proof of future performance. Even if PF passes, wide uncertainty or clustered wins require more data.
Closed-balance drawdown is NOT the same as peak intratrade equity drawdown; obtain equity curve. Avoid cherry-picking a period or parameters.

## Current blockers
No remote access to MetaTrader testing agent or broker tick data, so full historical trades and forward results have not been executed from this chat.
Stage A code is uploaded and static reviewed, but exporter requires F7 MetaEditor compilation and an MT5 smoke run.
Native Tester disables WebRequest; true Worker/EA integration parity and historical calendar controls require a replay adapter, which is not yet built.
Older local tester v1.4 contains different lot sizing and missing latest R1 M5 swing SL, do not use its profit result as v3.5.38.

Official docs: https://www.mql5.com/en/docs/network/webrequest
Official tester: https://www.metatrader5.com/en/terminal/help/algotrading/testing
Official timing: https://www.metatrader5.com/en/terminal/help/algotrading/test_preparation
