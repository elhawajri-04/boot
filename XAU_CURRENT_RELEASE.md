# XAU Current Release, EXEC_PIPELINE_20261017_E

## Current files
- [EA, XAU_EA_SmartExec_E.mq5](./XAU_EA_SmartExec_E.mq5)
- [Worker, XAU_Worker_SmartExec_E.js](./XAU_Worker_SmartExec_E.js)
- [Regression tests, test_xau_smart_exec_e.mjs](./test_xau_smart_exec_e.mjs)

This is the current working release. Earlier releases are retained for rollback and are not assumed to be active.

## What changed from D2
- Removed the demo/research-only `InpTelemetryOnlyStagingMode` Input entirely, avoiding an active EA that silently logs without sending orders.
- `OnTick` and `OnTimer` now always reach the normal R1/R2 execution paths.
- There is no account-mode check that blocks execution because an account is or is not DEMO.
- Updated release identifier to `EXEC_PIPELINE_20261017_E` and Worker build to `XAU_V4_ICT_SMC_SMART_EXEC_20261017_E`.
- R2 Smart Execution retains Market/Limit/Stop selection based on an approved setup. R1 remains independent.

## NOT changed
- Broker-side order validation, stop-loss/take-profit rules, risk calculations and combined XAU exposure guard.
- R1 M30 context with M5 confirmation and nearest valid closed-M5 swing + ATR stop.
- R2 structural, ICT/SMC, price-placement, score, R:R, news and feed freshness criteria.
- Existing pending-order lifecycle (e.g. cancellation of stale/invalid/unmatched orders), retry and duplicate suppression. No new demo-driven cancellation conditions were added.
- MT5 integrated trading inputs for normal strategy toggles and protection; only the telemetry-only gate was removed.

## Verification
- JavaScript syntax check passed (`node --check`).
- 44 Node regression checks passed (without broker orders).
- Uploaded source verified against GitHub blob SHA.
- MQL5 MetaEditor compilation and connected MT5 trading were not executable in this environment and remain unverified.

## Run
1. Deploy `XAU_Worker_SmartExec_E.js` to the existing intended Worker deployment.
2. Open `XAU_EA_SmartExec_E.mq5` in MetaEditor, compile with F7 and check compiler output.
3. Attach to the intended MT5 XAU chart and provide the correct Worker URL + write token, keeping established safety inputs in place.
4. Inspect Experts logs for `EXEC_PIPELINE_20261017_E`, Worker `/health` build and R1/R2 signal and execution state.

Do not confuse successful offline checks with confirmed broker execution.
