# XAU Execution Diagnostics F | Current EA + Worker E

## Release and verification

- Current EA source: `XAU_EA_SmartExec_F.mq5`, a narrowly scoped **observability-only** update of the verified GitHub EA E baseline.
- Current Worker: **unchanged** `XAU_Worker_SmartExec_E.js`.
- EA F runtime line: `EXEC_PIPELINE_20261018_F`.
- 17 local Python tests passed, covering audit classification and static regression against EA E. The order methods, lifecycle, risk sizing, news/session guards, trading signals, and execution inputs remain unchanged.
- **MetaEditor compilation has not been run** for F here. Offline Python tests do not prove MQL5 compilation or successful broker orders.
- No demo-only input, forced cancellation, altered risk limit, or new setup eligibility condition was introduced.

## Historical audit only

An MT5 audit export supplied in this conversation spans **2026-10-15 18:45:38 to 2026-10-18 14:53:31** (times recorded by the broker server). Its 1,889 CSV rows are repeated telemetry/audit entries. **They are not independent trading opportunities**, and the export includes earlier EA/Worker builds.

| Day | Rows with legacy R2 Pending Only protocol mismatch | Rows with a closed-session status | Rows with Worker model/age or stale-feed status |
|---|---:|---:|---:|
| Oct 15 | 3 | 21 | 6 |
| Oct 16 | **903** | 35 | 69 |
| Oct 17 | 0 | 145 | 68 |
| Oct 18 | 0 | 28 | 10 |

Other categories are in `audit_classification_oct2026.json`. The audit contains **three** R1 `EXECUTED` events on October 16; those have `ticket=0` in this CSV, so the event alone does not establish a confirmed broker fill. A row with a risk percentage above an input cap can belong to previous code/diagnostic paths. Investigate with the exact matching Experts/Journal and trading history, rather than treating it as proof that EA E violates the cap.

**What the audit actually proves:** repeated old R2 protocol refusals were present on Oct 15–16, but this does not establish the current E Worker is mismatched. On Oct 17–18, session closure and combined `BLOCK | WORKER MODEL/AGE` flags dominate the sampled statuses; Oct 18 is Sunday. An account's broker feed can reasonably be stale on closed-market days. The generic label could not distinguish HTTP, protocol, missing, and stale age conditions.

## F changes, no strategy change

1. The EA logs poll health separately for R1 `/zones/latest` and R2 `/r2`, including HTTP status, model mismatch, invalid market age, missing setup, and fresh feed.
2. The single `BLOCK | WORKER MODEL/AGE` status is now split into `BLOCK | WORKER MODEL UNVERIFIED`, `BLOCK | WORKER FEED MISSING` and `BLOCK | WORKER FEED STALE`. These are **the same three fail-closed checks in EA E**, with a more detailed reason.
3. The periodic `ICT4 PIPELINE` output includes `poll_health` fields and `mode=ACTIVE` instead of the leftover `telemetry_only=FALSE` text.
4. No Worker changes or server-side deployment needed to pair Worker E with EA F.

## What remains unknown

- Whether EA F compiles in MetaEditor and reaches the Worker from the user's terminal.
- Whether R1/R2 reach qualified READY setups in a market-open period in the current release.
- Whether the current EA's submitted order is broker-accepted or broker-rejected, and why. Requires matched Experts/Journal and broker retcode.
- Whether the absence of R2 fills is caused by strategy signal selectivity rather than the integration. Historical audit alone cannot establish that.

## Next validation

1. Compile EA F (F7) and load the EA on the same XAUUSD.s chart. The file name may be arbitrary, but the terminal Experts output should show `EXEC_PIPELINE_20261018_F`.
2. Keep the **existing Worker E** deployed. The release is the normal active trading build; no diagnostic-only execution blocker was added.
3. During a **market-open session**, retrieve the current Trade Audit CSV and the same-time Experts/Journal log. The `poll_health` fields distinguish HTTP/model/market-age from missing READY setups; risk and broker retcodes can be traced separately.
4. No conclusion of improved win rate, trade count, or actual order execution is made from this source-only diagnostic release.

For reproducibility:

```bash
python research/execution_audit/diagnose_audit.py --audit your_audit.csv --output audit_summary.json
python -m unittest discover -s tests -p 'test_diagnose_audit.py' -v
python -m unittest discover -s tests -p 'test_ea_f_static.py' -v
```
