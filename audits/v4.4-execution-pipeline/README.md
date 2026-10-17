# XAU current unified release — 2026-10-17 D: R2 Smart Execution

**Current EA:** [XAU_V4_4_ExecutionPipeline_Research.mq5](./XAU_V4_4_ExecutionPipeline_Research.mq5)  
**Current Worker:** [XAU_Worker_ICTV4_Research_ValueRetest.js](./XAU_Worker_ICTV4_Research_ValueRetest.js)

This release **supersedes C**. Older versions remain in GitHub history. It is the latest implementation, but **has not yet been MetaEditor-compiled, deployed to Cloudflare or forward-tested in MT5 by the assistant**. GitHub commits do not install the files.

## R2 Smart decision

- **Market BUY/SELL:** M15 sweep + displacement + confirmed BOS/CHOCH + valid zone/value gate are all present, the latest *closed M15 candle* confirms direction, and the live quote is in the approved retest zone.
- **Limit BUY_LIMIT/SELL_LIMIT:** confirmed setup exists, but price is above the buying zone or below the selling zone; await the retest.
- **Stop BUY_STOP/SELL_STOP:** price is already in the M15 return zone, but the last closed bar lacks directional confirmation; await break above its high / below its low, with a bounded ATR/point buffer. The EA still rejects broker-invalid pending prices.
- **No entry:** missing HTF agreement, ICT confluence, news approval, session, valid price/SL/TP, sufficient score/RR, freshness, eligible quote or account SL-risk room.
- R2 **still requires H1/M30 structural alignment**. R1 retains M30+M5 independent directional policy and M5-local swing stop.
- Workers `/r2` and `/r2/setup` now advertise `smart_execution_mode:true`, `pending_only_mode:false`; each R2 setup has `execution_mode`, `market_viable`, `pending_viable`, `execution_reason` and a stable BOS+zone `setup_key`. R2 READY audit now accepts approved Market or Pending instead of running an unrelated obsolete pending-only/R1 zone audit.

## MT5 execution safety

- `InpEnableR2PendingExecutor` **retains its old name** for saved MT5 inputs but is now the R2 Smart master switch. `InpR2EnableMarketExecution=true` additionally enables confirmed R2 market orders.
- Default `InpTelemetryOnlyStagingMode=true` **blocks all EA broker execution** until intentionally changed in MT5 Inputs.
- Source checks retain news/session gating, HTF/Worker protocol and feed age, SL/TP validation, spread-aware broker quote checks, market-entry drift limit, risk-sized lot and combined account caps, broker order retcodes, per-engine exposure locking, risk-limited pending order lifecycle and one accepted order per event.
- Broker comments on R2 Market start `XAU_R2P_` so existing R2 ownership, risk accounting and position management still recognize them.
- Stable `setup_key` is keyed on confirmed structure event + zone, **not** tick price or order type; the EA stores accepted keys in terminal global variables to avoid replay. Rejected broker requests have a bounded per-setup retry interval.
- A pending R2 order locks out R2 Market for the same or any other setup until it has been safely resolved. R1 may operate independently subject to total cap.

## Evidence and next steps

- The Worker source passed full-file JavaScript parser validation, 10 unit/structural checks and 5 additional audit samples. A checked-in reproducible [Release D Smart R2 regression suite](./XAU_Worker_ICTV4_ReleaseD_SmartExecution_Regression.mjs) was run against the current Worker and **all 8 tests passed**, covering Market, Limit, Stop, HTF disagreement, stable setup identity and READY audits. These are not broker execution or profitability tests. Run from this directory: `node XAU_Worker_ICTV4_ReleaseD_SmartExecution_Regression.mjs`.
- In MetaEditor, compile the EA and confirm `0 errors`. Expected startup marker: `XAU RELEASE | EXEC_PIPELINE_20261017_D`.
- Deploy the matching Worker file to the existing Cloudflare Worker hostname and check `ICT4 PIPELINE` for `R2 model=OK` and a concrete `type=` or wait reason. Keep telemetry-only TRUE for this first verification.
- After verifying the currently deployed pair, explicitly switch telemetry-only FALSE on the user-owned Demo only to evaluate broker orders. Never infer success or trade rate from a closed-market test.


---

**Earlier releases:** Previous versions B and C, including their source code and audit notes, remain available through GitHub commit history. Release D is the single current version.
