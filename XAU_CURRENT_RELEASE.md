# XAU latest published source, EXEC_PIPELINE_20261019_H

**Current intended pair:** [EA H](./XAU_EA_SmartExec_H.mq5) + [Worker H](./XAU_Worker_SmartExec_H.js).

This is the latest source release, not evidence it has been deployed to Cloudflare or compiled/attached in MT5.

## Purpose
The October 19 log showed repeated **strategy-level waiting** (`allowed=FALSE`, `type=NONE`), including M30 MIXED, H1/M30 misalignment and a lack of a recent qualifying ICT sequence. No fully qualified broker order rejection was observed in that short log. Intermittent HTTP 1001/1003 and M1 news-shock guard were also observed and remain separate technical/market gates.

Worker H changes only the **liquidity Sweep search window** from 8 to 14 completed M5/M15 bars. The BOS/CHOCH confirmation **remains strictly within the last 4 completed M5 bars (R1) or 3 completed M15 bars (R2)**. Sweep→Displacement→BOS event order, FVG/OB zone quality, structure, risk limits, SL/TP, duplicate handling, news/session policies and R2 Smart Market/Limit/Stop routing are unchanged. EA H only updates its Worker `/health` build expectation and release marker from EA G; it has **no changed execution logic**.

## Files
- EA: [XAU_EA_SmartExec_H.mq5](./XAU_EA_SmartExec_H.mq5)
- Worker: [XAU_Worker_SmartExec_H.js](./XAU_Worker_SmartExec_H.js)
- Test: [test_ict_sweep14_h.mjs](./tests/test_ict_sweep14_h.mjs)
- Research/replay report: [ICT_SWEEP14_H_REPORT.md](./research/ict_sweep14/ICT_SWEEP14_H_REPORT.md)

## Evidence
A limited, **signal-generation-only** historical replay of uploaded JustMarkets OHLC from Jan 13–Feb 6 2026, 5,059 M5-close evaluation instants, yielded:
- R1 unique authorized setup keys: E=19 vs H=34.
- R2 unique authorized setup keys: E=1 vs H=5.

These are not executed trades, backtest results, PnL, proof of accuracy, or out-of-sample evidence. Candidate parameters were selected using these same data; additional independent testing remains important. No change to Broker-facing EA logic was made.

Offline Worker H JavaScript syntax and synthetic behavior/diff tests passed. **MetaEditor compile for EA H and remote Cloudflare deployment remain unverified**. Existing EA G / Worker E and all prior versions remain available for rollback.

## Installation and version check
1. Update Cloudflare Worker to Worker H source.
2. Compile EA H in MetaEditor and attach over G.
3. `/health` must show `build: XAU_V4_ICT_SMC_SWEEP14_20261019_H`.
4. Experts must log `EXEC_PIPELINE_20261019_H`; investigate any `WRONG_WORKER_BUILD`, feed stale, news blocks and broker retcodes if a signal qualifies.
