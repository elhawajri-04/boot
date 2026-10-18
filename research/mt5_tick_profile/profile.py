#!/usr/bin/env python3
"""Deterministic quote-TICK histogram for MT5/JustMarkets XAUUSD.s.

Counts distinct Bid/Ask quote-change events at rounded midquote prices.
This is NEVER COMEX executed volume, actual buyer/seller order flow, or delta.
Standalone research; cannot call or alter EA/Worker or issue orders.
"""
from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
import csv
import gzip
import json
from pathlib import Path
from typing import Iterable, Iterator


class QuoteDataError(ValueError):
    """Invalid or ambiguous historical quote records."""


def number(value: str, label: str) -> Decimal:
    try:
        result = Decimal(value)
    except (InvalidOperation, ValueError, TypeError) as exc:
        raise QuoteDataError(f"invalid {label}: {value!r}") from exc
    if not result.is_finite():
        raise QuoteDataError(f"non-finite {label}")
    return result


def utc_ms(ms: int) -> str:
    return datetime.fromtimestamp(ms / 1000, timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def quote_updates(path: Path, *, required_symbol: str | None = None) -> Iterator[tuple[int, Decimal, Decimal, str]]:
    """Yield valid quote changes, preserving order, safely skipping duplicate quote snapshots."""
    opener = gzip.open if str(path).endswith(".gz") else open
    with opener(path, "rt", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        required = {"time_msc", "bid", "ask", "symbol", "flags"}
        if not reader.fieldnames or not required.issubset(reader.fieldnames):
            raise QuoteDataError("CSV must contain time_msc,bid,ask,flags,symbol")
        last_ms = -1
        last_quote = None
        first_symbol = None
        for line_num, row in enumerate(reader, 2):
            try:
                timestamp = int(row["time_msc"])
                flags = int(row["flags"])
            except (TypeError, ValueError, KeyError) as exc:
                raise QuoteDataError(f"line {line_num}: malformed timestamp or flags") from exc
            if timestamp <= 0 or timestamp < last_ms:
                raise QuoteDataError(f"line {line_num}: unsorted/invalid timestamp")
            last_ms = timestamp
            symbol = (row.get("symbol") or "").strip()
            if not symbol:
                raise QuoteDataError(f"line {line_num}: missing symbol")
            if first_symbol is None:
                first_symbol = symbol
            if symbol != first_symbol or (required_symbol is not None and symbol != required_symbol):
                raise QuoteDataError(f"line {line_num}: mixed/unexpected symbols")
            if flags < 0:
                raise QuoteDataError(f"line {line_num}: invalid flags")
            bid = number(row.get("bid"), "bid")
            ask = number(row.get("ask"), "ask")
            if bid <= 0 or ask < bid:
                raise QuoteDataError(f"line {line_num}: invalid bid/ask")
            current = (bid, ask)
            if current == last_quote:
                continue
            last_quote = current
            yield timestamp, bid, ask, symbol


def to_bin(mid: Decimal, bin_size: Decimal) -> Decimal:
    steps = (mid / bin_size).quantize(Decimal("1"), rounding=ROUND_HALF_UP)
    return steps * bin_size


def value_area(histogram: Counter[Decimal], percentage: Decimal) -> tuple[Decimal, Decimal, Decimal]:
    """Contiguous price Value Area expanding from POC; ties prefer lower price."""
    if not histogram:
        raise QuoteDataError("empty histogram")
    if not Decimal("0.01") <= percentage <= Decimal("1"):
        raise QuoteDataError("value area fraction must be in [0.01, 1]")
    occupied = sorted(histogram)
    poc = min(occupied, key=lambda price: (-histogram[price], price))
    index = occupied.index(poc)
    low = high = index
    accumulated = histogram[poc]
    total = sum(histogram.values())
    while Decimal(accumulated) / total < percentage:
        left = occupied[low - 1] if low else None
        right = occupied[high + 1] if high + 1 < len(occupied) else None
        if left is None and right is None:
            break
        if right is None or (left is not None and histogram[left] >= histogram[right]):
            low -= 1
            accumulated += histogram[occupied[low]]
        else:
            high += 1
            accumulated += histogram[occupied[high]]
    return poc, occupied[low], occupied[high]


def calculate_window(window: dict, *, bin_size: Decimal, value_area_frac: Decimal,
                     min_updates: int, complete: bool, available_at: int | None,
                     left_truncated: bool) -> dict:
    hist: Counter[Decimal] = window["hist"]
    poc, val, vah = value_area(hist, value_area_frac)
    values = sorted(hist.values())
    # Descriptive top/bottom counts; NOT exchange-reconstructed HVN/LVN.
    rank = max(1, (len(values) + 4) // 5)
    lo_threshold = values[rank - 1]
    hi_threshold = values[-rank]
    return {
        "symbol": window["symbol"],
        "mode": "MT5_QUOTE_UPDATE_PROFILE_ONLY",
        "data_origin": "BROKER_BID_ASK_QUOTE_TICKS_NOT_EXECUTED_VOLUME",
        "window_start_utc": utc_ms(window["start"]),
        "window_end_utc": utc_ms(window["end"]),
        "available_at_utc": utc_ms(available_at) if available_at is not None else None,
        "window_complete": complete,
        "left_truncated": left_truncated,
        "usable_for_research": complete and not left_truncated and window["updates"] >= min_updates,
        "quote_update_count": window["updates"],
        "up_midquote_updates": window["up"],
        "down_midquote_updates": window["down"],
        "unchanged_midquote_updates": window["flat"],
        "mean_spread_usd": round(float(window["spread_sum"] / window["updates"]), 5),
        "poc_price": str(poc),
        "val_price": str(val),
        "vah_price": str(vah),
        "hvn_bins_proxy": [str(p) for p in sorted(hist) if hist[p] >= hi_threshold],
        "lvn_bins_proxy": [str(p) for p in sorted(hist) if hist[p] <= lo_threshold],
        "quote_counts_by_price": {str(p): hist[p] for p in sorted(hist)},
        "buyer_aggressor_delta": None,
        "comex_volume": None,
        "execution_allowed": False,
    }


def analyze(ticks: Iterable[tuple[int, Decimal, Decimal, str]], *, bin_size: Decimal,
            window_seconds: int = 900, value_area_frac: Decimal = Decimal("0.7"),
            min_updates: int = 20, required_symbol: str | None = None) -> Iterator[dict]:
    if bin_size <= 0 or not bin_size.is_finite():
        raise QuoteDataError("invalid bin size")
    if window_seconds < 1 or window_seconds > 86400 or min_updates < 1:
        raise QuoteDataError("invalid window or min updates")
    width = window_seconds * 1000
    current = None
    last_mid = None
    first = True
    previous_time = -1
    for time_ms, bid, ask, symbol in ticks:
        if time_ms < previous_time:
            raise QuoteDataError("timestamp moved backward")
        if required_symbol is not None and symbol != required_symbol:
            raise QuoteDataError("symbol mismatch")
        previous_time = time_ms
        group_start = (time_ms // width) * width
        if current is None or current["start"] != group_start:
            if current is not None:
                # No future leakage: this bucket becomes available on NEXT observed quote.
                yield calculate_window(current, bin_size=bin_size,
                    value_area_frac=value_area_frac, min_updates=min_updates,
                    complete=True, available_at=time_ms, left_truncated=first)
                first = False
            current = {"start": group_start, "end": group_start+width,
                       "symbol": symbol, "hist": Counter(), "updates": 0,
                       "up": 0, "down": 0, "flat": 0, "spread_sum": Decimal(0)}
            last_mid = None
        if current["symbol"] != symbol:
            raise QuoteDataError("mixed symbols in stream")
        mid = (bid + ask) / 2
        current["hist"][to_bin(mid, bin_size)] += 1
        current["updates"] += 1
        current["spread_sum"] += ask - bid
        if last_mid is not None:
            if mid > last_mid:
                current["up"] += 1
            elif mid < last_mid:
                current["down"] += 1
            else:
                current["flat"] += 1
        last_mid = mid
    if current is not None:
        yield calculate_window(current, bin_size=bin_size,
            value_area_frac=value_area_frac, min_updates=min_updates,
            complete=False, available_at=None, left_truncated=first)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Analyze MT5 quote ticks without trading")
    p.add_argument("--csv", required=True, type=Path)
    p.add_argument("--output", required=True, type=Path)
    p.add_argument("--symbol", default="XAUUSD.s")
    p.add_argument("--bin-usd", type=Decimal, default=Decimal("0.10"))
    p.add_argument("--window-seconds", type=int, default=900)
    p.add_argument("--min-updates", type=int, default=20)
    a = p.parse_args(argv)
    if not a.csv.is_file():
        p.error(f"missing CSV: {a.csv}")
    # Keep output in local research folder; not directly consumable by EA.
    features = list(analyze(quote_updates(a.csv, required_symbol=a.symbol),
                            bin_size=a.bin_usd, window_seconds=a.window_seconds,
                            min_updates=a.min_updates, required_symbol=a.symbol))
    if not features:
        p.error("no usable bid/ask quote updates")
    a.output.parent.mkdir(parents=True, exist_ok=True)
    with a.output.open("w", encoding="utf-8") as out:
        for feature in features:
            out.write(json.dumps(feature, ensure_ascii=False, separators=(",", ":")) + "\n")
    usable = sum(bool(r["usable_for_research"]) for r in features)
    print(f"Analyzed {len(features)} windows, {usable} complete/eligible; saved {a.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
