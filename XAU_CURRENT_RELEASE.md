# XAU latest published source, EXEC_PIPELINE_20261019_G

**Current intended code pair:** [EA G](./XAU_EA_SmartExec_G.mq5) + [unchanged Worker E](./XAU_Worker_SmartExec_E.js).

Published source is not proof the EA has been compiled or attached to the MT5 chart, nor that Worker E is deployed at the URL.

## Why G exists
The user's October 19 MT5 log revealed repeated `WRONG_WORKER_BUILD` responses from `/health`, while normal strategy waiting and intermittent HTTP errors also occurred. EA F's `/health` probe was incorrectly hardcoded to `XAU_V4_ICT_SMC_ADAPTIVE_MARKET_PENDING` even though intended Worker E declares `XAU_V4_ICT_SMC_SMART_EXEC_20261017_E`. This is a deterministic diagnostic mismatch and does **not** prove the live deployment is Worker E.

G changes **only** the health-probe build comparison and release label. It now reads the actual `build` field and checks against the Worker E build, logging `expected=... got=...` on a mismatch. No trading strategy, R1/R2 execution, Market/Limit/Stop routing, risk limits, SL/TP management, news guards, polling intervals, pending-order cancellation rules or Demo restrictions were added or changed.

## Verification
- 12 standalone Python static regression tests passed with published EA F and Worker E SHA checks.
- MetaEditor MQL5 compile for G and live Worker deployment check remain **unverified**.
- [Log diagnostic report](./research/execution_audit/EXECUTION_20261019_G_REPORT.md)
- [Static test source](./tests/test_worker_build_parity_g.py)
- Historical volume research has not been connected to trade execution.

## Installation
1. Replace the previously compiled EA F source with [EA G](./XAU_EA_SmartExec_G.mq5) in MetaEditor and compile with F7.
2. Continue using Worker E, with actual `/health` JSON `build = XAU_V4_ICT_SMC_SMART_EXEC_20261017_E`, `strategy_model = ICT_SMC_V4_LIVE`, `r2_pending_only_mode = false`, and `r2_market_execution_enabled = true`. If the deployed build differs, deploy the matching Worker E; do not force acceptance of an unknown build.
3. After G is attached, confirm `EXEC_PIPELINE_20261019_G` appears in Experts and that periodic `PROBE /health` is OK or reports the exact mismatch.
4. For trade scarcity, independently monitor `allowed`, `type`, reasons, news shock, and intermittent HTTP failures. No broker order attempts were observed in the supplied 13:11–13:30 log, so the log does not evidence an execution refusal of a qualified signal.

Earlier EA versions E and F remain in the repository for rollback.
