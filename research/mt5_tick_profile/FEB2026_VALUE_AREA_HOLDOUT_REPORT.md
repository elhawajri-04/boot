# MT5 Quote Profile: POC / VAH / VAL incremental test, Feb 2026

**Status:** Completed reproducible, *observational* comparison of broker quote-update profiles. Not a COMEX footprint, R1/R2 historical signal replay, MT5 broker execution test, or profitable trading strategy backtest.

## Inputs

- User-exported `XAUUSD.s` ticks, 2,491,352 MT5 Bid/Ask quote snapshots, UTC Feb 2–6, 2026.
- Matching MT5 M15 candles for the same dates, plus separately created *15-minute quote-update profile* JSONL. The raw user-supplied tick data is intentionally **not committed** to the public GitHub repository.
- Quote profiles were computed using a **$0.10 price-bin** and expanding the 70% quoted-price activity value area around the proxy POC, with no look-ahead into subsequent windows.
- Every M15's `real_volume` is zero. The features reflect **quote-update frequency at prices**, not actual trade count, traded contracts, buyer/seller-initiated Delta, order-book depth, or COMEX volume.

## Timing discipline

- Only profile windows marked complete, non-left-truncated, eligible and with a chronologically adjacent next M15 candle are considered.
- `available_at_utc` must land between the previous candle's end and **60 seconds** later. `available_at_utc` must match an actual exported tick timestamp. The 60-second threshold is a *research data-quality filter*, **not an EA/Worker trade-execution gate**.
- To avoid the previous candle-close vs next-period-publication ambiguity, the next directional observation is measured from **Bid at the actual publication tick** to the close-Bid of the next M15 candle. This is still a *price-change observation*, not an executable fill.
- Total quote windows: **460**. Excluded: **7** total, among which are the truncated initial window and delayed/overnight gaps. **453** observations remain, **271** in Feb 2–4 (train) and **182** in Feb 5–6 (held out). Only two held-out trading days are available, so confidence is limited.

## Prespecified comparisons, without tuning on holdout

1. Simple training-sample median estimate of next M15 high-minus-low range.
2. Linear model trained on current M15 high-minus-low range plus log(quote update count).
3. Same linear model **plus** profile width relative to current range, close-to-POC distance relative to range, and flags for close above VAH / below VAL. All model scaling and coefficients are fitted on Feb 2–4 only. Evaluated unchanged on Feb 5–6.
4. Descriptive directional observations: Is the *next* M15 price movement from the actual publication Bid consistent with the last completed candle's location outside the Value Area, or toward POC? These are **not** real entry rules and don't include spread, execution, SL/TP, commission or session filtering.

### Holdout results: prediction of next M15 *range* (US dollars per ounce)

| Fixed model | MAE, lower is better | RMSE, lower is better |
|---|---:|---:|
| Training median only | 10.9262 | 14.1234 |
| **Current range + quote activity** | **9.0423** | **12.0833** |
| Current range + activity + **POC/VAH/VAL** | 10.0898 | 12.9413 |

The value-area features **worsened** holdout MAE by approximately **11.6%** relative to the simpler range+activity model. They did not demonstrate incremental benefit for *range prediction* in this sample. This says nothing definitive about their usefulness in actual R1/R2 setups.

### Holdout: directional diagnostics (not a strategy)

| Completed-candle location relative to quote value area | N | Following M15 direction up | Following M15 direction consistent with break outside VA |
|---|---:|---:|---:|
| Above VAH | 40 | 57.50% | 57.50% |
| Below VAL | 42 | 47.62% | 52.38% |
| Within VAL/VAH | 100 | 49.00% | Not applicable |

- All 182 valid held-out windows had a measurable close/POC side. Next price change **toward** the POC side occurred **49.45%** of the time.
- Training results for *below VAL* continuation were just **32.08%** across 53 windows, whereas held-out continuation was **52.38%** across 42 windows. This instability cautions against retrofitting entry rules to the holdout sample.
- A naive direction-match percentage **is not** win rate, net expectancy, statistical significance, or evidence of higher completed order count.

## Engineering outcome

- New, standalone offline evaluator: [`research/mt5_tick_profile/value_area_study.py`](./value_area_study.py)
- Synthetic, reproducibility and no-lookahead tests: [`tests/test_value_area_study.py`](../../tests/test_value_area_study.py). **10 passing tests**.
- Machine-readable **aggregated** results: [`research/mt5_tick_profile/FEB2026_VALUE_AREA_HOLDOUT_RESULTS.json`](./FEB2026_VALUE_AREA_HOLDOUT_RESULTS.json).
- No changes to **`XAU_EA_SmartExec_E.mq5`**, **`XAU_Worker_SmartExec_E.js`**, current trading eligibility, R1/R2 order types, account risk, order cancelation or session guards.

### Local run (requires exported private data)

```bash
python research/mt5_tick_profile/value_area_study.py \
  --features /path/to/tick_profile_m15_features.jsonl \
  --m15 /path/to/xau_M15.csv \
  --ticks /path/to/xau_ticks.csv \
  --output-dir /path/to/private_output
python -m unittest discover -s tests -p 'test_value_area_study.py' -v
```

## Next decision

**Do not make POC/VAH/VAL mandatory filters for R1/R2 based on this result.** Next, reproduce or export timestamp-aligned *actual R1/R2 setup reasons and broker order outcomes* to test whether **quote activity** adds incremental information beyond ATR/session/context, and distinguish *lack of qualified setups* from *EA/Worker/broker execution issues*. A multi-week out-of-sample test is needed before promoting any feature to an automated decision input.
