# XAU V4.4, pending cancellation and bridge diagnostics (Demo candidate)

## Inputs and sources

This release starts from **V4.3**. The Worker remains **V4.1** from `releases/v4.1/XAU_V4_Worker_v4_1.js`. No Worker deployment or database changes are included. This is a **new branch**, not an update to the live main branch.

## Changes

1. **R2 cancellation failure throttling.** Broker error 10018 (`TRADE_RETCODE_MARKET_CLOSED`) schedules a **per-order 120-second** retry (minimum 60 seconds). Other broker failures default to **30 seconds** (minimum 10 seconds). A terminal Global Variable keyed to the account, magic, and ticket persists the next retry time through EA reloads. Failure/skipped retry returns `false`; the order remains **pending at the broker**, retains its SL/TP, and R2 cannot arm another order while it remains outstanding. Successful broker deletion clears the retry key and saved structural invalidation marker. Initial failure and each scheduled retry are logged, not every tick.
2. **Bridge diagnostics.** Record method/endpoint (not tokens), response code, MT5 last error, safe truncated response body, and per-endpoint recovery. Distinguish transport failure (-1), auth (401/403), timeout (408/504), rate limit (429), and nonstandard 1001/1003. Nonstandard results **do not establish a precise root cause**, they require network/edge/Worker investigation. Repeated endpoint failures are rate-limited in logs to 300 seconds by default. No transport retrial or fail-open logic was introduced.
3. **Unambiguous statuses.** `R2 WAIT | NO VALID R2 PENDING SETUP` when the Worker provides no permitted R2 plan, versus `BLOCK | R2 NON-PENDING TYPE` only when a disallowed type appears in an otherwise allowed plan. R1 displays no confirmation separately from side/type mismatch.
4. **Preserved** R1 M5 swing plus ATR stop, R2 pending-only, broker magic/symbol filters, risk budgets, news fail-closed, chart colors and legend, and auto protection. Observe Only remains removed.

## Verification done

* 9 Python tests checking preserved and changed static code logic plus modeled retry scenarios.
* 10 Worker order-placement cases and 2 health protocol checks on Node 22, passed.
* The V4.3 to V4.4 source was diffed. Broker execution, risk calculation, R1 stop, and the R2 lifecycle monitoring rules remain unchanged except for cancellation diagnostics, retry handling, and status clarification.

**Not yet verified:** MQL5 compilation in MetaEditor, WebRequest to the *deployed* Worker, or actual MT5 Demo execution/cancellation. These are mandatory acceptance gates. Past logs mixed multiple versions; the old R2 rejection storm must be re-tested with a clean V4.4 log, not assumed fixed in a live market.

## Safe Demo checklist

1. Keep V4.3 backed up. Confirm correct deployed Worker URL, `XAUUSD.s`, one EA attached, and account type `DEMO`.
2. Compile the complete `.mq5` in MetaEditor (F7), ensure **0 errors**. Restart or reattach V4.4. Observe its version banner.
3. Verify `InpTelemetryOnlyStagingMode=false`, `InpEnableAutoSignalExecutor=true`, `InpEnableR2PendingExecutor=true`, `InpEnableMaxSLRiskGuard=true`, `InpEnableUSDNewsGuard=true` and MT5 AutoTrading permission. **Do not disable news or risk guards to manufacture entries.**
4. Test the bridge endpoints from the MT5 Experts log and the deployed Worker. Check `HTTP GET/POST` diagnostics, `FEED` freshness, and Worker model parity.
5. For a broker-held R2 pending order that becomes invalid while the market is closed, verify: one `R2 CANCEL RETRY SCHEDULED` event per configured retry period, no market fill/duplicate pending, and one `R2 PENDING CANCELLED` after the broker resumes accepting deletes. Do **not** assume the order was cancelled while market closed.
6. Confirm one broker-accepted R1 execution with correct nearest confirmed M5 swing SL, ATR buffer, sized lot, TP; and one R2 BUY/SELL LIMIT/STOP pending with valid SL/TP, expiry, and successful cancellation or fill. Check server ticket/retcode and History.

## Before historic profitability testing

MT5 Strategy Tester cannot run `WebRequest()` in an Expert Advisor (see [MQL5 WebRequest docs](https://www.mql5.com/en/docs/network/webrequest)). Therefore, this cloud-dependent live EA **cannot be claimed historically backtested simply by pressing Start**. A separate reproducible *offline Worker decision replay* or approved test harness will be needed, with historical M1/M5/M15/M30/H1 gold data, broker spread/commission/slippage, original signal timestamps, news/session/calendar offsets, lot/risk safeguards and no lookahead. Use in-sample, out-of-sample, then forward Demo validation, reporting profit factor, net R, max drawdown, exposure, entry/cancellation counts and win rate separately for R1 and R2.