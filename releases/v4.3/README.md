# XAU MT5 V4.3 R1 Swing SL + R2 Pending Safety

## Scope
Visuals and Worker V4.1 are unchanged. This release changes EA execution and diagnostics only. Use with the v4.1 Worker shipped in releases/v4.1 on the same branch.

### R1
- Uses nearest confirmed local *closed-M5* pivot (strength/ATR parameters already in Inputs) and ATR stop buffer for every ICT/SMC R1 live order (market or pending).
- The remote structural zone invalidation level cannot become the R1 scalp SL.
- Builds the take profit from effective entry and local SL using `InpSimpleRR` (default 2.0).
- Blocks R1 when an eligible confirmed M5 pivot or valid stop is unavailable; status explains why.
- Dashboard READY level reflects local calculated SL/TP, not Worker structural levels.

### R2
- Pending Only enforced in EA and Worker, plus strict BUY/SELL side/type consistency.
- Timer invokes R2 pending-order lifecycle BEFORE new execution attempts; existing pending orders cannot be duplicated or moved on each Worker poll.
- Manages only pending orders tagged `XAU_R2P_`, matching EA Magic Number and chart symbol, never closes already opened positions in this lifecycle routine.
- Cancels pending R2 on blocked news, closed auto-entry session, confirmed opposite R2, known pending SL breach, confirmed M15 structural invalidation recorded when order was placed, unmeasurable risk or breached engine/combined risk cap.
- Optional feed-loss protection: `InpR2CancelPendingOnFeedLoss` (default true), `InpR2PendingFeedGraceSeconds` (default 120). Grace also applies after attaching EA when feed is initially unavailable.
- Broker delete failures remain visible with RETCODE and are retried from OnTimer.

### Preserved
- AutoTrading enabled by dedicated R1/R2 Inputs; ObserveOnly no longer exists.
- R1 / R2 caps default to 5% each with total risk cap default 10%.
- News checks, account and broker checks, SL/TP protection, trade manager, auto-performance, chart legend and R2 SELL yellow visuals remain.
- No database schema or Worker redeployment required for this V4.3 EA-only patch.

## Verified offline
- Git baseline was identified by matching the exact Git blob SHA of V4.2.
- Static code regression checks: 7 passed.
- Local Worker pending placement/health checks: 12 assertions passed.
- Worker JS syntax and HTTP mock probes: passed.
- **NOT verified**: MetaEditor MQL5 compilation, broker approval, any real execution, trade profitability, or live Worker deployment parity. All require MT5 demo evidence.

## Demo installation
1. Back up the existing EA/Inputs and take note of existing pending tickets.
2. Download `.mq5` from this GitHub branch, put it in `MQL5/Experts`, MetaEditor F7, verify zero errors.
3. Use the same Worker endpoint and matching WRITE_TOKEN. Add Worker URL to MT5 Tools > Options > Expert Advisors > Allow WebRequest for listed URL.
4. Attach the EA to the same broker symbol (e.g., `XAUUSD.s`), use Demo with Algorithmic Trading enabled, `InpTelemetryOnlyStagingMode=false`, `InpEnableAutoSignalExecutor=true`, `InpEnableR2PendingExecutor=true`, `InpDrawDecisionZones=true`, `InpDrawR2Setup=true`.
5. Check Experts and Journal for bridge health, R1 local pivot/no-pivot diagnostics, news/session/risk blocks and broker return codes. Simulate or wait for a legitimate candidate. Verify actual broker order price, SL/TP, lot, max risk, and risk events.
6. Validate R2 cancellation scenarios only in Demo with safe/non-live test environment: news block, stale worker, close beyond original invalidation on M15, broker rejection/retry. Ensure there are no duplicate R2 pending orders and no unexpected close of filled positions.

Please do not conclude the strategy is profitable without a sufficiently large, timestamped out-of-sample/backtest and forward-demo sample, including spreads, swaps, slippage and commission.

MQL5 references:
- https://www.mql5.com/en/docs/standardlibrary/tradeclasses/ctrade
- https://www.mql5.com/en/docs/trading/ordergetdouble