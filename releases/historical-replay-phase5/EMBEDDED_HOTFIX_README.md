# Phase 5 Embedded Commands — February/January 2026 diagnostic hotfix

This is a **research-only, Strategy Tester-only** alternative to `XAU_Phase5_Research_Tester.mq5` addressing repeated `P5 FATAL: missing phase5_feb_commands.csv` file-transfer errors.

## What changed

- The **exact Phase 5 historical command rows** are embedded as MQL5 string literals in `mt5/XAU_Phase5_Embedded_Tester.mq5`.
- January 2026: **4 records** (3 ARM, 1 CANCEL); February 2026: **3 ARM**.
- CSV bytes pinned to original GitHub blobs in the EA source comments. No market signals, R1/R2 execution logic, SL/TP, position sizing, risk management or cancellation rules were changed.
- Removed `#property tester_file` declarations so Strategy Tester does **not depend on external CSV transfer**.
- Historical-news verification is still **fail closed** by default. `InpResearchAllowUnverifiedNews=true` skips the historical-news file for *diagnostic execution only*. This is **not a validated performance backtest**.
- Original EA and deployed Demo V4.4/Worker remain unchanged.

## Run February without any CSV files

1. Download the **raw source** [XAU_Phase5_Embedded_Tester.mq5](https://raw.githubusercontent.com/elhawajri-04/boot/research/phase5-embedded-commands-hotfix/releases/historical-replay-phase5/mt5/XAU_Phase5_Embedded_Tester.mq5) into the active MT5 data folder `MQL5/Experts`.
2. Open file in MetaEditor and press **F7**. Must show **0 errors** before running; MQL5 compilation has **not** been independently verified here.
3. Select `XAU_Phase5_Embedded_Tester.ex5` under Strategy Tester > Settings > Expert, **not** the older Phase4/Phase5 executable.
4. XAUUSD.s / M5 / **2026-02-02 to 2026-02-09** / Every tick based on real ticks.
5. Inputs: `InpResearchPeriod=P5_FEB_2026`, `InpR1ConfirmationMode=P5_M1_REJECTION`, `InpResearchAllowUnverifiedNews=true` **diagnostic only**.
6. Start; expected initialization:
   - `P5 EMBEDDED ORDERS READY | period=1 | orders=3 | no_csv_files_required=1`
   - `P5 START | tester_only=1 | commands=3 | ...`
7. Provide Tester Journal and Backtest/History. If compile errors appear, send MetaEditor errors before starting.

**No files are required in MQL5/Files** for this unverified-news diagnostic. To run with real historical news safety, that dataset needs separate verified integration before trusting profitability.

This change only removes file-loading friction and does **not** increase frequency of structural confirmations. February still has three historical candidate ARM events in the embedded snapshot.
