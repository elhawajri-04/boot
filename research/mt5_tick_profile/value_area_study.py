#!/usr/bin/env python3
"""Independent, read-only MT5 quote-value-area historical study.

Requires historical quote profiles, broker M15 candles, and the same original MT5 ticks.
Uses only previously completed quote buckets as features; no EA, Worker, API or order calls.
The data here are BID/ASK quote updates, not COMEX executed trade volume.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
import pandas as pd

WINDOW = pd.Timedelta(minutes=15)
MAX_ARRIVAL_DELAY_MS = 60_000
TRAIN_END_UTC = pd.Timestamp("2026-02-05T00:00:00Z")


def _require(cond: bool, reason: str) -> None:
    if not cond:
        raise ValueError(reason)


def _model_mae(y: np.ndarray, pred: np.ndarray) -> float:
    return float(np.mean(np.abs(y - pred)))


def _pct(numer: int, denom: int) -> float | None:
    return round(100 * numer / denom, 2) if denom else None


def _fit_predict(train: pd.DataFrame, holdout: pd.DataFrame, cols: list[str]) -> np.ndarray:
    """Fixed-form train-only standardized least squares; no parameter search on holdout."""
    x_train = train[cols].to_numpy(dtype=float)
    x_hold = holdout[cols].to_numpy(dtype=float)
    mu = x_train.mean(axis=0)
    sigma = x_train.std(axis=0)
    sigma[sigma == 0] = 1
    xx = np.column_stack((np.ones(len(x_train)), (x_train - mu) / sigma))
    hh = np.column_stack((np.ones(len(x_hold)), (x_hold - mu) / sigma))
    fit = np.linalg.lstsq(xx, train["next_range"].to_numpy(dtype=float), rcond=None)[0]
    return np.maximum(hh @ fit, 0.0)


def build_dataset(features_file: Path, m15_file: Path, ticks_file: Path,
                  symbol: str = "XAUUSD.s") -> tuple[pd.DataFrame, dict]:
    records = [json.loads(line) for line in features_file.read_text(encoding="utf-8").splitlines() if line.strip()]
    _require(bool(records), "empty feature file")
    frame = pd.DataFrame(records)
    required = {"symbol", "window_start_utc", "window_end_utc", "available_at_utc",
                "window_complete", "left_truncated", "usable_for_research",
                "mode", "quote_update_count", "poc_price", "val_price", "vah_price"}
    _require(required.issubset(frame.columns), "incomplete feature schema")
    _require(frame.symbol.eq(symbol).all(), "unexpected or mixed feature symbols")
    _require(frame["mode"].eq("MT5_QUOTE_UPDATE_PROFILE_ONLY").all(), "not a quote profile")
    frame["start"] = pd.to_datetime(frame.window_start_utc, utc=True, format="ISO8601")
    frame["end"] = pd.to_datetime(frame.window_end_utc, utc=True, format="ISO8601")
    frame["available_at"] = pd.to_datetime(frame.available_at_utc, utc=True, format="ISO8601")
    _require(frame.start.is_unique and frame.start.is_monotonic_increasing, "unsorted or duplicated windows")
    _require((frame.end == frame.start + WINDOW).all(), "unexpected feature window")
    for col in ("poc_price", "val_price", "vah_price"):
        frame[col] = pd.to_numeric(frame[col], errors="raise")
    _require((frame.val_price <= frame.poc_price).all() and
             (frame.poc_price <= frame.vah_price).all(), "invalid price value area")
    _require((frame["quote_update_count"] > 0).all(), "invalid quote counts")
    bars = pd.read_csv(m15_file)
    _require({"t", "o", "h", "l", "c", "tick_volume", "real_volume"}.issubset(bars.columns),
             "incomplete M15 data")
    bars["start"] = pd.to_datetime(bars.t, unit="s", utc=True)
    _require(bars.start.is_monotonic_increasing and bars.start.is_unique, "bad M15 chronology")
    bars = bars.set_index("start", verify_integrity=True)
    candles = bars[["o", "h", "l", "c", "tick_volume", "real_volume"]].copy()
    d = frame.set_index("start", verify_integrity=True).join(candles, how="left", validate="one_to_one")
    _require(d.c.notna().all(), "historical M15 bars do not cover quote profiles")
    # The *next* M15 bar must start when the previous 15-minute profile ends.
    next_bars = candles.reindex(pd.DatetimeIndex(d.end))
    next_bars.index = d.index
    d["next_o"] = next_bars.o
    d["next_c"] = next_bars.c
    d["next_range"] = next_bars.h - next_bars.l
    # No look-ahead: the profile must be complete AND delivered <= 60 seconds
    # after the *next* M15 open. Otherwise the next M15 outcome isn't fairly available.
    delay_ms = (d.available_at - d.end).dt.total_seconds() * 1000
    d["arrival_ms"] = delay_ms
    chronological = (
        d.usable_for_research.eq(True) & d.window_complete.eq(True) &
        d.left_truncated.eq(False) & d.available_at.notna() &
        delay_ms.ge(0) & delay_ms.le(MAX_ARRIVAL_DELAY_MS) &
        d.next_o.notna() & d.next_c.notna() & d.next_range.notna()
    )
    # Use *the first available* observed bid at/after signal publication
    # to measure next-bar direction, not the previous bar's close (which could
    # precede publication by > 1 minute).
    ticks = pd.read_csv(ticks_file, usecols=["time_msc", "bid", "ask", "flags"],
                        dtype={"time_msc": "int64", "bid": "float64", "ask": "float64", "flags": "int32"})
    _require(len(ticks) > 0, "empty ticks")
    timestamps = ticks.time_msc.to_numpy()
    _require(bool(np.all(np.diff(timestamps) >= 0)), "unsorted tick timestamps")
    bids = ticks.bid.to_numpy()
    asks = ticks.ask.to_numpy()
    _require(np.isfinite(bids).all() and np.isfinite(asks).all() and
             bool(np.all((bids > 0) & (asks >= bids))), "invalid broker quotes")
    available_ms = (d.available_at.astype("int64") // 1_000_000).to_numpy()
    indices = np.searchsorted(timestamps, available_ms, side="left")
    bounded = np.minimum(indices, len(timestamps) - 1)
    hit = (indices < len(timestamps)) & (timestamps[bounded] == available_ms)
    d["publication_tick_match"] = hit
    d["publication_bid"] = bids[bounded]
    d["publication_ask"] = asks[bounded]
    d["publication_spread"] = d.publication_ask - d.publication_bid
    publication_candidate = chronological.copy()
    chronological &= d.publication_tick_match
    d = d.loc[chronological].copy()
    _require(len(d) > 0, "no time-aligned research observations")
    d["candle_range"] = d.h - d.l
    _require((d.candle_range > 0).all(), "invalid current candle range")
    d["next_return_bid"] = d.next_c - d.publication_bid
    d["position"] = np.where(d.c > d.vah_price, "above_value",
                             np.where(d.c < d.val_price, "below_value", "inside_value"))
    d["dist_poc_scaled"] = (d.c - d.poc_price) / d.candle_range
    d["profile_width_scaled"] = (d.vah_price - d.val_price) / d.candle_range
    d["log_updates"] = np.log1p(d.quote_update_count)
    d["above_value"] = (d.position == "above_value").astype(int)
    d["below_value"] = (d.position == "below_value").astype(int)
    d["poc_revert_side"] = np.sign(d.poc_price - d.c)
    d["next_direction"] = np.sign(d.next_return_bid)
    # Direction heuristics are diagnostics only. They are NOT orders or strategy signals.
    d["revert_match"] = (d.poc_revert_side == d.next_direction).where(d.poc_revert_side != 0, np.nan)
    d["breakout_side"] = np.where(d.position == "above_value", 1,
                                   np.where(d.position == "below_value", -1, 0))
    d["breakout_match"] = (d.breakout_side == d.next_direction).where(d.breakout_side != 0, np.nan)
    diagnostics = {
        "raw_feature_windows": len(frame),
        "m15_bar_matches": int(frame.start.isin(bars.index).sum()),
        "eligible_after_full_publication_and_contiguity": len(d),
        "excluded_total": int(len(frame) - len(d)),
        "delayed_over_60_seconds": int((delay_ms > MAX_ARRIVAL_DELAY_MS).sum()),
        "unmatched_publication_ticks_on_otherwise_valid_windows": int((~hit & publication_candidate.to_numpy()).sum()),
        "real_volume_nonzero_m15_rows": int((bars.real_volume > 0).sum()),
        "first_window": str(d.index.min()),
        "last_window": str(d.index.max()),
    }
    return d, diagnostics


def evaluate(d: pd.DataFrame, diagnostics: dict,
             train_end: pd.Timestamp = TRAIN_END_UTC) -> dict:
    train = d[d.index < train_end]
    hold = d[d.index >= train_end]
    _require(len(train) >= 30 and len(hold) >= 30, "train/holdout split too small")
    base_cols = ["candle_range", "log_updates"]
    enriched_cols = base_cols + ["profile_width_scaled", "dist_poc_scaled",
                                  "above_value", "below_value"]
    actual = hold.next_range.to_numpy(dtype=float)
    const_pred = np.full(len(hold), float(train.next_range.median()))
    base_pred = _fit_predict(train, hold, base_cols)
    rich_pred = _fit_predict(train, hold, enriched_cols)
    results = {
        "status": "EXPLORATORY_OBSERVATION_ONLY",
        "trained_before": str(train_end),
        "train_count": len(train), "holdout_count": len(hold),
        "holdout_dates": sorted(set(str(k.date()) for k in hold.index)),
        "holdout_up_rate_pct": _pct(int((hold.next_return_bid > 0).sum()), len(hold)),
        "holdout_pred_next_range_mae_usd": {
            "train_median_only": round(_model_mae(actual, const_pred), 4),
            "current_bar_range_plus_quote_activity": round(_model_mae(actual, base_pred), 4),
            "baseline_plus_poc_value_area": round(_model_mae(actual, rich_pred), 4),
        },
        "holdout_pred_next_range_rmse_usd": {
            "train_median_only": round(float(np.sqrt(np.mean((actual - const_pred) ** 2))), 4),
            "current_bar_range_plus_quote_activity": round(float(np.sqrt(np.mean((actual - base_pred) ** 2))), 4),
            "baseline_plus_poc_value_area": round(float(np.sqrt(np.mean((actual - rich_pred) ** 2))), 4),
        },
        "holdout_groups": {},
        "train_groups": {},
        "timing_and_input": diagnostics,
        "interpretation": "No trade setups, bid/ask fills, real_volume, COMEX trades, or execution outcomes inferred.",
    }
    for label, subset in (("train", train), ("holdout", hold)):
        groups = results[f"{label}_groups"]
        for key, g in subset.groupby("position"):
            active = g.loc[g.breakout_side != 0]
            groups[key] = {
                "count": len(g),
                "next_up_pct": _pct(int((g.next_return_bid > 0).sum()), len(g)),
                "next_range_mean_usd": round(float(g.next_range.mean()), 4),
                "mean_next_return_from_publication_bid_usd": round(float(g.next_return_bid.mean()), 4),
                "outside_value_continuation_pct": _pct(int(active.breakout_match.sum()), len(active)) if len(active) else None,
            }
        revert = subset.loc[subset.poc_revert_side != 0]
        groups["poc_reversion_all"] = {
            "count": len(revert),
            "next_move_toward_poc_pct": _pct(int(revert.revert_match.sum()), len(revert)),
        }
    return results


def main(argv: list[str] | None = None) -> int:
    a = argparse.ArgumentParser()
    a.add_argument("--features", required=True, type=Path)
    a.add_argument("--m15", required=True, type=Path)
    a.add_argument("--ticks", required=True, type=Path)
    a.add_argument("--output-dir", required=True, type=Path)
    ns = a.parse_args(argv)
    data, diagnostic = build_dataset(ns.features, ns.m15, ns.ticks)
    result = evaluate(data, diagnostic)
    ns.output_dir.mkdir(parents=True, exist_ok=True)
    (ns.output_dir / "value_area_holdout_results.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    view = ["end", "available_at", "arrival_ms", "quote_update_count", "poc_price", "val_price",
            "vah_price", "c", "publication_bid", "publication_ask", "position", "next_c",
            "next_return_bid", "candle_range", "next_range"]
    data[view].to_csv(ns.output_dir / "time_aligned_observations.csv", index_label="start_utc")
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
