# XAU Phase 5 — Embedded Risk 5% Diagnostic Tester

This build is for **MT5 Strategy Tester ONLY**. It does not update the running demo/live V4.4 EA or the deployed Worker.

Source: [XAU_Phase5_Embedded_Risk5_Diagnostics.mq5](https://raw.githubusercontent.com/elhawajri-04/boot/research/phase5-embedded-risk5-diagnostics/releases/historical-replay-phase5/mt5/XAU_Phase5_Embedded_Risk5_Diagnostics.mq5)

## Change scope

- `InpRiskPercentPerTrade = 5.0` — planned risk at the stop-loss capped to 5% of **current equity**, subject to available aggregate risk room and broker volume limits.
- `InpMaxAggregateRiskPct = 5.0` — total estimated SL exposure across positions and pending orders on the symbol, including the new order, limited to 5% of equity. The code does **not** automatically increase account-wide exposure to 10%, 15% etc when multiple signals exist.
- New `P5 RISK_POLICY` on initialization and `P5 RISK_AUDIT` at R1/R2 order sizing: event, side, entry, SL, distance, equity, percentage limits, estimated existing exposure, permitted additional risk, minimum broker lot, minimum-lot estimated loss, selected lot and selected-lot estimated loss, decision/rejection reason.
- Keeps same embedded January (4) and February (3) historical command records, M5 swing+ATR R1 SL, M1 retest confirmation, R2 pending LIMIT only, 5% aggregate cap, stop-distance/spread/session/news checks, and Strategy Tester-only guard.
- No external CSV needed for the **unverified historical news override diagnostic**; production-quality backtesting requires externally verified historical news intervals and updated integration.

## Run February 2026

1. Download MQ5 to active `MT5 Data Folder/MQL5/Experts`, open it directly in MetaEditor, press F7; check **0 errors**. We did **not** compile/test MQL5 remotely.
2. In MT5 Strategy Tester select `XAU_Phase5_Embedded_Risk5_Diagnostics.ex5`, `XAUUSD.s` / `M5` / 2026-02-02 through 2026-02-09 / **Every tick based on real ticks**.
3. Inputs: `InpResearchPeriod=P5_FEB_2026`, `InpRiskPercentPerTrade=5.0`, `InpMaxAggregateRiskPct=5.0`, `InpR1ConfirmationMode=P5_M1_REJECTION`. For feasibility analysis **only** set `InpResearchAllowUnverifiedNews=true`.
4. Run and export **Journal** + **Backtest** / trade history. Search for `P5 RISK_AUDIT`, `MARKET_ACCEPTED`, `REJECT`, and `P5 SUMMARY`. Compare February candidates to the earlier 1% default before drawing conclusions.

### Limits

5% per trade is aggressive. The 5% stop-budget is a modeled loss based on `OrderCalcProfit` and does not include possible gaps, slippage, fees or unexpected executions, so **actual realized loss can exceed 5%**. The new build may trade more of the existing three February signals, but **it cannot create additional ICT/SMC confirmations**. One profitable February trade is inadequate evidence of a profitable strategy; do not use this build on a real/demo chart. The news filter is explicitly bypassed during the diagnostic and results cannot be treated as independently validated profitability.
