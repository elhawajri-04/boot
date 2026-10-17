# XAU R1/R2 Smart Execution D2, 2026-10-17

## Status
- Built from the most recent user-attached EA and Worker source, without replacing historical files.
- Node JavaScript syntax check: PASS.
- Offline unit, route and static regression checks: 39 PASS (6 BUY/SELL Market/Limit/Stop routing, rejection gates, news and feed age, EA safety markers).
- MQL5 MetaEditor compile: NOT TESTED, requires Windows MetaEditor.
- Broker execution, order lifetime, news guard, stop levels, quote drift, network connection: NOT TESTED on live MT5.
- Cloudflare Worker staging deployment: NOT DONE by this commit.

## Kept unchanged
- R1 M30 directional context, M5 entry confirmation and local closed-M5 swing + ATR stop.
- R2 H1/M30 structure agreement, M15 ICT/SMC confluence.
- R2 can choose BUY/SELL Market, BUY/SELL Limit and BUY/SELL Stop, based on the Worker setup. Never promote an unqualified setup to Market merely to increase trade count.
- Existing account risk caps, duplicate order prevention, broker-side stop/target validation and the pending lifecycle manager.
- `InpTelemetryOnlyStagingMode=true` as the safe installation default.

## D2 changes
- Worker R2 readiness is now checked consistently in /r2, /r2/setup and chart audit using a pure shared guard.
- The guard checks approved setup, Smart mode (not pending-only), exact order type and side, corresponding viability flag, minimum score/RR and directional entry/SL/TP.
- News and feed-age checks are also enforced for the exported execution_allowed and READY audit flag.
- EA R2 parser requires a nested Smart setup marked pending_only_mode=false, avoiding a false match from unrelated portions of the response.
- No backtest profitability, forward test success or MetaEditor compile is claimed.

## Demo verification sequence
1. Deploy the Worker JS in a separate Cloudflare staging environment with its own D1 binding. Do NOT overwrite live production or use a live account for first testing.
2. Check GET /health shows build XAU_V4_ICT_SMC_SMART_EXEC_20261017_D2, r2_pending_only_mode:false and r2_market_execution_enabled:true.
3. Compile XAU_EA_SmartExec_D2.mq5 in Windows MetaEditor. Resolve all compiler errors and review warnings.
4. On an empty MT5 Demo account configure the staging Worker URL, matching bridge token and WebRequest allowlist. Start with InpTelemetryOnlyStagingMode=true.
5. Verify fresh /latest, /r2 and /zones/latest, bidirectional polling, news gate and the R1/R2 pipeline. Confirm no broker orders in telemetry mode.
6. Only after review, on Demo, set InpTelemetryOnlyStagingMode=false. Test valid and invalid R2 Market/Limit/Stop, SL/TP, expiration, duplicate suppression, risk cap and broker retcodes. Existing/manual positions can be managed by the EA, so use an empty Demo account.
7. Record the Experts/Journal log, broker fills, and any unexpected order. Do NOT deploy to real money before successful demo forward testing.

GitHub branch: xau-smart-exec-d2-20261017. The main branch was not changed.
