# ICT / SMC v4, objective rule contract (SHADOW, NOT LIVE)
Date 2026-10-16. Branch research/ict-smc-v4-shadow.

IMPORTANT: The current production EA v3.5.38 and Worker v2.8 remain unchanged.
This file defines the intended NEW decision school for the NEXT version, not proof of a completed conversion or trading edge.

## Working definitions (specific algorithms, not universal ICT definitions)
All computations use FINISHED candles only. No future bars are allowed, and any swing pivot needs at least two bars on both sides before it can be used.

1. Confirmed swing high / low: high greater than two highs to left and >= two highs to right, and corresponding low inverse. In trading, index before two right-side candles is not confirmed. Equality/tie handling defined in tests.
2. BOS: last completed candle closes across a previously CONFIRMED structural pivot in direction of current structure. Break by wick alone is not BOS.
3. CHoCH: opposite close across last confirmed swing against prior structural direction. Identical conditions may produce different labels if trend context differs.
4. Liquidity sweep: price trades above an earlier confirmed swing high but CLOSES below it (buy-side sweep), or below a swing low and CLOSES above it (sell-side sweep). Sweep alone is not an entry signal.
5. Displacement: body >= 0.65 x 14-period ATR and body/range >= 0.65 (tunable only in a NEW frozen model cohort).
6. Bullish FVG: candle 3 low strictly above candle 1 high, gap >= 0.10 x ATR. Bearish: candle 3 high below candle 1 low. Preserve origin bar, distal/proximal boundaries, and full-fill/mitigation status; omit still forming bars.
7. Order block: last opposing candle before a structurally meaningful displacement; candle range defines zone, and a close through distal boundary invalidates it. Reject extremely wide candles.
8. Premium/discount: midpoint of CONFIRMED high and low of the dealing range, not the current forming bar.
9. HTF bias: confirmed H1 + M30 structure. If they disagree, trade WATCH ONLY. LTF confirmations cannot override HTF conflict.
10. R1 candidate: trade in HTF bias with recent sweep of opposite-side liquidity, displacement and M5 structure shift, followed by price returning to a valid FVG/OB in value. Existing EA M5 swing SL must still be suitable for a scalp. Never enter directly on an untouched indicator label.
11. R2 candidate: H1/M30 structural direction, M15 BOS/CHoCH after liquidity sweep/displacement, valid M15 FVG/OB retest, pending LIMIT order only. No limit when price already crosses invalidation or too close to market for broker stops.
12. Safety remains separate from strategy: dedicated R1 and R2 5% planned caps, 10% combined, one risk-sized order per engine setup, verified broker SL, news fail closed, UK session open to broker 23:59, frozen replay and forward Demo. Risk limits are NOT guarantees in gaps.

## Explicit non-trade outcomes
- Missing >=120 FINISHED H1 bars (or 60 M30/M15/M5) => NO_DATA.
- Pivot confirmation incomplete => WAIT_STRUCTURE.
- No recent valid liquidity sweep => WAIT_SWEEP.
- No structure break/shift and displacement => WAIT_DISPLACEMENT/WAIT_CHOCH.
- No valid unmitigated FVG or OB => WAIT_FVG_OB.
- HTF conflicted => WAIT_HTF_BIAS.
- Price not at discount for buy, premium for sell (if applicable) => WATCH_VALUE.
- Stale data, news unknown, broker session closed, risk or margin cap hit => BLOCK, irrespective of technical setup.

## What is still needed before any production upgrade
A. Implement/validate pure candle-pattern detectors with causality tests, repeatability and timestamps, no repaint.
B. Implement new R1 zone engine and regime/setup permission outputs without leaving classic EMA/RSI fallback that would execute.
C. Implement new R2 candidate and pending output protocol, preserve expiry/invalidation and R2 visual diagnostics.
D. Upgrade EA's R1 locked-zone M5 trigger and invalidation to enforce CHoCH/BOS and zone age; reconcile M5 swing SL.
E. Create deterministic replay and per-setup historical order outcome engine, USD historical news decision source, broker spec/cost parity.
F. Forward DEMO only. Require measured out-of-sample edge and hard stop safety tests before user manually chooses to deploy new EA and Worker.

## Test cohorts
Maintain untouched v3.5.38/v2.8 baseline. Compare 3 parallel arms on IDENTICAL broker data: BASELINE, ICT/SMC, and no-trade control. No optimized thresholds on validation/forward sets. Minimum historical train/validation splits and forward DEMO 8-12 weeks with adequate independent setups.

Useful reference documentation
- https://www.mql5.com/en/docs/series/copyrates
- https://www.mql5.com/en/docs/trading/ordercalcprofit
- https://www.mql5.com/en/docs/network/webrequest
