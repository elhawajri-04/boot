#!/usr/bin/env python3
"""Offline COMEX GC order-flow features from Databento GLBX.MDP3 trades CSV.

Research ONLY. No network requests, no Worker/MT5 calls and no order routing.
The outputs are historical feature windows, NOT trade signals.
"""
from __future__ import annotations

import argparse
import csv
from dataclasses import dataclass, field
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
import gzip
import json
import os
import re
from pathlib import Path
import tempfile
from typing import Iterator

DATASET = "GLBX.MDP3"
SCHEMA = "trades"
REQUIRED = frozenset(("ts_event", "price", "size", "side"))
NS_PER_SECOND = 1_000_000_000
UNDEF_PRICE = 9223372036854775807


@dataclass(frozen=True)
class Trade:
    ts_ns: int
    tick: int
    volume: int
    side: str
    contract: str


def ns_from_field(value: str) -> int:
    v = value.strip()
    if v.isdecimal():
        ns = int(v)
        if ns < 1_000_000_000_000_000_000:
            raise ValueError("ts_event must be UTC nanoseconds, not seconds/milliseconds")
        return ns
    # Databento pretty_ts may contain 9 fractional digits. datetime only
    # preserves microseconds, so parse the fractional *nanoseconds* ourselves.
    match = re.fullmatch(r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}:\d{2})", v)
    if not match:
        if "T" in v and not (v.endswith("Z") or re.search(r"[+-]\d{2}:\d{2}$", v)):
            raise ValueError("Naive timestamps are rejected; provide a UTC offset")
        raise ValueError("ts_event must be Unix nanoseconds or ISO8601 with timezone")
    base, fractional, tz = match.groups()
    if tz == "Z":
        tz = "+00:00"
    try:
        utc = datetime.fromisoformat(base + tz).astimezone(timezone.utc)
    except ValueError as exc:
        raise ValueError("invalid timestamp") from exc
    delta = utc - datetime(1970, 1, 1, tzinfo=timezone.utc)
    fractional_ns = int((fractional or "0").ljust(9, "0"))
    return (delta.days * 86400 + delta.seconds) * NS_PER_SECOND + fractional_ns


def iso_ns(ns: int) -> str:
    sec, nanos = divmod(ns, NS_PER_SECOND)
    dt = datetime.fromtimestamp(sec, timezone.utc)
    return dt.strftime("%Y-%m-%dT%H:%M:%S") + f".{nanos:09d}Z"


def parse_price_tick(value: str, mode: str, tick_size: Decimal) -> int:
    v = value.strip()
    if not v or v == str(UNDEF_PRICE):
        raise ValueError("missing/undefined price")
    try:
        price = Decimal(v)
    except InvalidOperation as exc:
        raise ValueError(f"bad price: {value}") from exc
    if mode == "raw-1e9":
        if price != price.to_integral_value():
            raise ValueError("raw-1e9 prices must be integer numbers")
        price /= Decimal(NS_PER_SECOND)
    if not price.is_finite() or price <= 0:
        raise ValueError("price must be positive and finite")
    # Catch the most dangerous scale error: 1e-9 raw price interpreted as
    # a human-readable GC dollar quote. This is INPUT validation only.
    if mode == "pretty" and price >= Decimal("1000000000"):
        raise ValueError("price looks raw-1e9; use --price-format raw-1e9")
    ticks = price / tick_size
    if ticks != ticks.to_integral_value():
        raise ValueError(f"price {price} is not an exact multiple of tick size {tick_size}")
    return int(ticks)


def open_csv(path: Path):
    if str(path).endswith(".gz"):
        return gzip.open(path, "rt", encoding="utf-8-sig", newline="")
    return path.open("r", encoding="utf-8-sig", newline="")


def iter_trades(path: Path, mode: str, tick_size: Decimal,
                selected_contract: str | None = None) -> Iterator[Trade]:
    if not path.is_file():
        raise ValueError(f"CSV file not found: {path}")
    found = 0
    contract_in_stream = None
    prior_ns = None
    with open_csv(path) as handle:
        reader = csv.DictReader(handle)
        if not reader.fieldnames or not REQUIRED.issubset(reader.fieldnames):
            raise ValueError(f"Required columns: {', '.join(sorted(REQUIRED))}")
        if "symbol" not in reader.fieldnames and "instrument_id" not in reader.fieldnames:
            raise ValueError("Need 'symbol' or 'instrument_id' to prevent contract mixing")
        for line_number, row in enumerate(reader, 2):
            try:
                # Reject mixing instruments, including inadvertent contract rolls.
                contract = (row.get("symbol") or row.get("instrument_id") or "").strip()
                if not contract:
                    raise ValueError("missing instrument identity")
                if selected_contract is not None and contract != selected_contract:
                    continue
                if contract_in_stream is None:
                    contract_in_stream = contract
                elif contract != contract_in_stream:
                    raise ValueError("multiple instruments detected; choose --contract")
                if "action" in reader.fieldnames:
                    action = (row.get("action") or "").strip().upper()
                    if action not in ("T", "TRADE"):
                        raise ValueError(f"non-trade action {action!r} in trades export")
                side = (row.get("side") or "").strip().upper()
                # Databento trade side B = buyer aggressor, A = seller aggressor.
                if side not in ("B", "A", "N"):
                    raise ValueError(f"unknown side {side!r}, expected B/A/N")
                volume_text = (row.get("size") or "").strip()
                if not volume_text.isdecimal() or int(volume_text) <= 0:
                    raise ValueError("size must be a positive integer")
                trade = Trade(ts_ns=ns_from_field(row["ts_event"]),
                              tick=parse_price_tick(row["price"], mode, tick_size),
                              volume=int(volume_text), side=side, contract=contract)
                if prior_ns is not None and trade.ts_ns < prior_ns:
                    raise ValueError("records are out of ts_event order")
                prior_ns = trade.ts_ns
                found += 1
                yield trade
            except (ValueError, ArithmeticError) as exc:
                raise ValueError(f"CSV line {line_number}: {exc}") from exc
    if found == 0:
        raise ValueError("no trades matched the selected contract")


@dataclass
class Level:
    buy: int = 0
    sell: int = 0
    unknown: int = 0

    @property
    def total(self) -> int:
        return self.buy + self.sell + self.unknown


@dataclass
class Window:
    start_ns: int
    contract: str
    tick_size: Decimal
    levels: dict[int, Level] = field(default_factory=dict)
    trades: int = 0
    buy: int = 0
    sell: int = 0
    unknown: int = 0
    last_ns: int = 0
    min_tick: int | None = None
    max_tick: int | None = None
    price_volume: int = 0

    def add(self, t: Trade) -> None:
        level = self.levels.setdefault(t.tick, Level())
        if t.side == "B":
            self.buy += t.volume
            level.buy += t.volume
        elif t.side == "A":
            self.sell += t.volume
            level.sell += t.volume
        else:
            self.unknown += t.volume
            level.unknown += t.volume
        self.trades += 1
        self.last_ns = t.ts_ns
        self.min_tick = t.tick if self.min_tick is None else min(self.min_tick, t.tick)
        self.max_tick = t.tick if self.max_tick is None else max(self.max_tick, t.tick)
        self.price_volume += t.tick * t.volume


def longest_run(levels: list[int]) -> int:
    previous = None
    current = maximum = 0
    for tick in levels:
        current = current + 1 if previous is not None and tick == previous + 1 else 1
        maximum = max(current, maximum)
        previous = tick
    return maximum


def analyze(window: Window, *, window_seconds: int, cumulative_delta: int,
            value_area_fraction: Decimal, imbalance_ratio: Decimal,
            min_imbalance_volume: int, min_trades: int, min_known_ratio: Decimal,
            max_profile_ticks: int, include_levels: bool,
            window_complete: bool, available_ns: int | None) -> dict:
    assert window.min_tick is not None and window.max_tick is not None
    if window.max_tick - window.min_tick + 1 > max_profile_ticks:
        raise ValueError("profile spans too many price ticks; confirm tick size and contract")
    total = window.buy + window.sell + window.unknown
    profile = window.levels
    poc = min(profile, key=lambda tick: (-profile[tick].total, tick))
    low = high = poc
    accumulated = profile[poc].total
    threshold = Decimal(total) * value_area_fraction
    while Decimal(accumulated) < threshold and (low > window.min_tick or high < window.max_tick):
        next_low = profile.get(low - 1, Level()).total if low > window.min_tick else -1
        next_high = profile.get(high + 1, Level()).total if high < window.max_tick else -1
        if next_low >= next_high and low > window.min_tick:
            low -= 1
            accumulated += profile.get(low, Level()).total
        else:
            high += 1
            accumulated += profile.get(high, Level()).total

    buy_imbalances = []
    sell_imbalances = []
    for tick, level in sorted(profile.items()):
        lower_sell = profile.get(tick - 1, Level()).sell
        upper_buy = profile.get(tick + 1, Level()).buy
        if (level.buy >= min_imbalance_volume and lower_sell >= min_imbalance_volume
                and Decimal(level.buy) >= imbalance_ratio * lower_sell):
            buy_imbalances.append(tick)
        if (level.sell >= min_imbalance_volume and upper_buy >= min_imbalance_volume
                and Decimal(level.sell) >= imbalance_ratio * upper_buy):
            sell_imbalances.append(tick)

    def price(tick: int) -> float:
        return float(Decimal(tick) * window.tick_size)

    known = window.buy + window.sell
    coverage = Decimal(known) / Decimal(total)
    valid = window_complete and window.trades >= min_trades and coverage >= min_known_ratio
    output = {
        "schema_version": 1, "dataset": DATASET, "source_schema": SCHEMA,
        "instrument": window.contract, "market": "COMEX_GC_FUTURES",
        "mode": "HISTORICAL_OBSERVATION_ONLY", "execution_allowed": False,
        "window_start_utc": iso_ns(window.start_ns),
        "window_end_utc": iso_ns(window.start_ns + window_seconds * NS_PER_SECOND),
        "last_trade_utc": iso_ns(window.last_ns),
        "window_seconds": window_seconds, "tick_size": float(window.tick_size),
        "window_complete": window_complete,
        "available_at_utc": iso_ns(available_ns) if available_ns is not None else None,
        "trades": window.trades, "total_contracts": total,
        "buy_aggressor_contracts": window.buy, "sell_aggressor_contracts": window.sell,
        "unclassified_contracts": window.unknown,
        "delta_contracts": window.buy - window.sell,
        "cvd_contracts": cumulative_delta,
        "classified_volume_fraction": float(coverage),
        "quality": {"usable_for_research": bool(valid),
                    "reason": "OK" if valid else (
                        "PARTIAL_FINAL_WINDOW" if not window_complete else (
                        "INSUFFICIENT_TRADES" if window.trades < min_trades else "UNCLASSIFIED_VOLUME_HIGH")),
                    "min_trades": min_trades, "min_classified_fraction": float(min_known_ratio)},
        "profile": {"poc": price(poc), "val": price(low), "vah": price(high),
                    "value_area_fraction_target": float(value_area_fraction),
                    "value_area_fraction_actual": float(Decimal(accumulated) / Decimal(total)),
                    "vwap": price(window.price_volume) / total,
                    "low": price(window.min_tick), "high": price(window.max_tick)},
        "footprint": {"type": "TRADE_VOLUME_DIAGONAL_APPROXIMATION",
                      "buy_imbalance_levels": [price(tick) for tick in buy_imbalances],
                      "sell_imbalance_levels": [price(tick) for tick in sell_imbalances],
                      "longest_stacked_buy": longest_run(buy_imbalances),
                      "longest_stacked_sell": longest_run(sell_imbalances),
                      "requires_mbo_for_order_book_absorption": True},
    }
    if include_levels:
        output["footprint"]["levels"] = [
            {"price": price(tick), "buy": lev.buy, "sell": lev.sell,
             "unknown": lev.unknown, "total": lev.total}
            for tick, lev in sorted(profile.items())
        ]
    return output


def generate(path: Path, output: Path, *, mode: str, tick_size: Decimal,
             contract: str | None, window_seconds: int, value_area_fraction: Decimal,
             imbalance_ratio: Decimal, min_imbalance_volume: int, min_trades: int,
             min_known_ratio: Decimal, max_profile_ticks: int, include_levels: bool) -> int:
    if tick_size <= 0 or not tick_size.is_finite():
        raise ValueError("tick-size must be positive and finite")
    if not (Decimal(0) < value_area_fraction <= Decimal(1)):
        raise ValueError("value-area-fraction must be in (0, 1]")
    if not (Decimal(0) <= min_known_ratio <= Decimal(1)):
        raise ValueError("min-known-ratio must be in [0, 1]")
    if not (window_seconds > 0 and imbalance_ratio > 1 and min_imbalance_volume > 0
            and min_trades > 0 and max_profile_ticks > 1):
        raise ValueError("invalid window/imbalance/trade/profile parameters")
    output.parent.mkdir(parents=True, exist_ok=True)
    count = 0
    cvd = 0
    current = None
    # Atomic output: a malformed/truncated file never creates a trusted partial output.
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=output.parent,
                                     prefix=".comex-", suffix=".tmp", delete=False) as temp:
        tmp_name = temp.name
        try:
            for trade in iter_trades(path, mode, tick_size, contract):
                bucket = trade.ts_ns // (window_seconds * NS_PER_SECOND)
                start_ns = bucket * window_seconds * NS_PER_SECOND
                if current is None or start_ns != current.start_ns:
                    if current is not None:
                        temp.write(json.dumps(analyze(current, window_seconds=window_seconds,
                                    cumulative_delta=cvd, value_area_fraction=value_area_fraction,
                                    imbalance_ratio=imbalance_ratio, min_imbalance_volume=min_imbalance_volume,
                                    min_trades=min_trades, min_known_ratio=min_known_ratio,
                                    max_profile_ticks=max_profile_ticks,
                                    include_levels=include_levels,
                                    window_complete=True, available_ns=trade.ts_ns), separators=(",", ":")) + "\n")
                        count += 1
                    current = Window(start_ns=start_ns, contract=trade.contract, tick_size=tick_size)
                current.add(trade)
                cvd += trade.volume if trade.side == "B" else (-trade.volume if trade.side == "A" else 0)
            if current is not None:
                temp.write(json.dumps(analyze(current, window_seconds=window_seconds,
                           cumulative_delta=cvd, value_area_fraction=value_area_fraction,
                           imbalance_ratio=imbalance_ratio, min_imbalance_volume=min_imbalance_volume,
                           min_trades=min_trades, min_known_ratio=min_known_ratio,
                           max_profile_ticks=max_profile_ticks, include_levels=include_levels,
                           window_complete=False, available_ns=None),
                           separators=(",", ":")) + "\n")
                count += 1
            temp.flush()
            os.fsync(temp.fileno())
            os.replace(tmp_name, output)
        finally:
            if os.path.exists(tmp_name):
                os.unlink(tmp_name)
    return count


def main() -> int:
    parser = argparse.ArgumentParser(description="Offline COMEX GC trades-to-Order-Flow research, no order execution")
    parser.add_argument("--csv", type=Path, required=True, help="Databento GLBX.MDP3 trades CSV or CSV.gz")
    parser.add_argument("--output", type=Path, required=True, help="Output JSONL historical feature windows")
    parser.add_argument("--price-format", choices=["pretty", "raw-1e9"], required=True,
                        help="Explicit scale. pretty if Databento pretty_px=true")
    parser.add_argument("--tick-size", type=Decimal, required=True, help="Contract tick size (e.g. 0.1 for GC)")
    parser.add_argument("--contract", default=None, help="Exact symbol or instrument_id (avoid roll mixing)")
    parser.add_argument("--window-seconds", type=int, default=300)
    parser.add_argument("--value-area-fraction", type=Decimal, default=Decimal("0.70"))
    parser.add_argument("--imbalance-ratio", type=Decimal, default=Decimal("3"))
    parser.add_argument("--min-imbalance-volume", type=int, default=2)
    parser.add_argument("--min-trades", type=int, default=20)
    parser.add_argument("--min-known-ratio", type=Decimal, default=Decimal("0.8"))
    parser.add_argument("--max-profile-ticks", type=int, default=10000)
    parser.add_argument("--include-levels", action="store_true", help="Include per-price footprint counts")
    args = parser.parse_args()
    try:
        n = generate(args.csv, args.output, mode=args.price_format, tick_size=args.tick_size,
                     contract=args.contract, window_seconds=args.window_seconds,
                     value_area_fraction=args.value_area_fraction,
                     imbalance_ratio=args.imbalance_ratio,
                     min_imbalance_volume=args.min_imbalance_volume,
                     min_trades=args.min_trades, min_known_ratio=args.min_known_ratio,
                     max_profile_ticks=args.max_profile_ticks,
                     include_levels=args.include_levels)
    except (ValueError, OSError) as exc:
        parser.exit(2, f"ERROR (no execution): {exc}\n")
    print(f"Created {n} closed historical window(s): {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
