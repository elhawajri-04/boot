# XAU current code release, EXEC_PIPELINE_20261018_F

This document marks the **latest published source release**, not proof that this version has been compiled or installed on the running MT5 chart.

## Latest compatible pair
- **MT5 EA:** [XAU_EA_SmartExec_F.mq5](./XAU_EA_SmartExec_F.mq5)
- **Cloudflare Worker:** [XAU_Worker_SmartExec_E.js](./XAU_Worker_SmartExec_E.js) (UNCHANGED from release E)
- **Diagnostic report:** [EXECUTION_F_DIAGNOSTIC_REPORT.md](./research/execution_audit/EXECUTION_F_DIAGNOSTIC_REPORT.md)
- **Offline audit classifier:** [diagnose_audit.py](./research/execution_audit/diagnose_audit.py)
- **Tests:** [test_diagnose_audit.py](./tests/test_diagnose_audit.py) and [test_ea_f_static.py](./tests/test_ea_f_static.py)
- **Sanitized aggregate historical counts:** [audit_classification_oct2026.json](./research/execution_audit/audit_classification_oct2026.json)

## What changed in EA F
EA F is an **observability-only** update to E. It splits the formerly ambiguous `BLOCK | WORKER MODEL/AGE` status into model-unverified, feed-missing and feed-stale reasons, and adds separate R1/R2 poll health to Experts logs. Removes the leftover `telemetry_only=FALSE` label from the periodic diagnostic and replaces it with `mode=ACTIVE`.

The execution decisions, R1/R2 strategies, risk sizing, news/session guards, pending-order cancellation lifecycle, order sending, and manual-position protection **have not been changed**. There is **no account-type gate, demo-only lock or telemetry-only input**.

## Verification and usage
- 17 local regression tests passed (including static E-versus-F checks).
- **MetaEditor compilation of F not yet verified**, and live terminal connectivity has not been observed.
- If EA E is currently running on the chart, that running terminal is **still on E** until EA F is compiled and attached.
- In MetaEditor compile EA F via F7, then confirm the Experts log announces `EXEC_PIPELINE_20261018_F`.
- Keep the existing **Worker E** deployed. Its `build` is `XAU_V4_ICT_SMC_SMART_EXEC_20261017_E`.
- Check fresh R1/R2 `poll_health`, model, setup, execution and broker retcode during market-open periods. A Sunday `OFF | SESSION` does not establish an execution fault.

## Previous release / rollback
EA E remains available unchanged: [XAU_EA_SmartExec_E.mq5](./XAU_EA_SmartExec_E.mq5). Do not mistake the old October audit's `Pending Only` refusals for evidence that the E Worker still has that protocol issue.

Strategy research including COMEX and MT5 quote volume remains separate from these trading sources.
