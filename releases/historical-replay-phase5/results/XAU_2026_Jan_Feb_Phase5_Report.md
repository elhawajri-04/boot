# Phase 5 retest audit — 2026 Jan / Feb (research only)

**Generated from the same January and February broker exports used in Phase4.**

| Field | Jan 6–13 | Feb 2–9 | Total |
|---|---:|---:|---:|
| Historical seconds sampled | 604,800 | 604,800 | 1,209,600 |
| R1 structural confirmations | 2 | 3 | 5 |
| R2 structural confirmations | 1 | 0 | 1 |
| Phase 4 observed R1 in-band retests | 2 | 2 | 4 |
| Phase 5 observed R1 in-band retests | 2 | 3 | **5** |
| Phase 5 observed R2 in-band retests | 0 | 0 | 0 |
| Peak simultaneously active R1 candidates (observed) | 1 | 1 | 1 |
| Peak simultaneously active R2 candidates (observed) | 1 | 0 | 1 |
| Executed MT5 trades on new EA | untested | untested | untested |
| Verified profitability | no | no | no |

### Why February changed

The formerly discarded `R1_SELL_1770281400` zone appeared at broker time 1770281700 and was immediately canceled at 1770282000 under the old `HTF_CHANGED_OR_MIXED` policy. In Phase 5, `MIXED` is neutral and the zone survives, producing a first observed in-band bid price of 4923.40 at 1770282086. This is a **historical quote observation only**, neither a confirmed M1-rejection entry nor a broker fill.

### Execution-stage changes needing MT5 validation

- Sideways HTF does not automatically invalidate zones; two consecutive *opposite directional* fresh M5 HTF readings or closed-bar structural invalidation can still cancel before expiry.
- Multiple independent zones with a hard cap of 3 slots per engine; avoid duplicate >=70% overlap same side. Not yet exercised concurrently in supplied weeks.
- R1: closed M1 body with directional rejection after first actual tick touch, M5 local swing+ATR SL; spread, historical session, news, margin, aggregate risk all enforced. May produce **fewer** real trades than five observed retests.
- R2 remains limit-only, broker-ack cancellation.
- Both months' command files have separate fixed filenames and their dates are checked in OnInit; wrong period fails instead of silently reporting zero trades.

**Code tests:** 14 Node/static tests passed. This is not an MT5 compile or transaction result. Production EA V4.4 and deployed Worker unchanged.