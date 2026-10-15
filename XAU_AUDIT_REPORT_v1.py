#!/usr/bin/env python3
"""Read v3.5.18 MT5 audit CSVs. Standard library only.

Usage:
    python XAU_AUDIT_REPORT_v1.py XAU_AUDIT_<account>_<symbol>_<magic>.csv
    python XAU_AUDIT_REPORT_v1.py "C:\\...\\Terminal\\Common\\Files\\XAU_AUDIT_....csv"

Counts describe logged events, NOT independent trades or causal trade outcomes.
Do not treat a lower cancellation count as proof of higher profitability.
"""
from __future__ import annotations

import csv
import sys
from collections import Counter
from pathlib import Path


def format_counts(title: str, counts: Counter, limit: int = 12) -> None:
    print(f"\n{title}")
    if not counts:
        print("  None recorded")
        return
    for name, count in counts.most_common(limit):
        print(f"  {count:>6}  {name}")


def audit_report(path: Path) -> None:
    if not path.is_file():
        raise FileNotFoundError(f"CSV not found: {path}")

    with path.open("r", encoding="utf-8-sig", newline="", errors="replace") as stream:
        reader = csv.DictReader(stream)
        expected = {"server_time", "engine", "event", "reason", "details"}
        if not reader.fieldnames or not expected.issubset(reader.fieldnames):
            raise ValueError("CSV header does not match v3.5.18 audit format")
        rows = list(reader)

    print(f"Audit: {path}")
    print(f"Events logged: {len(rows)}")
    if rows:
        print(f"First logged: {rows[0]['server_time']}")
        print(f"Last logged:  {rows[-1]['server_time']}")
    print("All counts below are diagnostic events, not strategy win rates.")

    r1 = [r for r in rows if r["engine"] == "R1"]
    r2 = [r for r in rows if r["engine"] == "R2"]
    learning = [r for r in rows if r["engine"] == "LEARN"]

    r1_waits = Counter(
        (r.get("details") or r.get("reason") or "UNKNOWN").strip()
        for r in r1 if r["event"] == "STATE" and r["reason"] in {"WAIT", "OFF"}
    )
    r1_rejections = Counter(
        (r.get("details") or r.get("reason") or "UNKNOWN").strip()
        for r in r1
        if r["reason"] in {"BLOCK", "REJECT", "EXECUTION_SKIP"}
    )
    r2_cancels = Counter(
        (r.get("details") or r.get("reason") or "UNKNOWN").strip()
        for r in r2 if r["event"] == "CANCEL"
    )
    r2_rejections = Counter(
        (r.get("details") or r.get("reason") or "UNKNOWN").strip()
        for r in r2 if r["reason"] == "REJECT"
    )
    r2_broker_states = Counter(
        r.get("reason") or "UNKNOWN"
        for r in r2 if r["event"] == "BROKER_HISTORY"
    )

    format_counts("R1: most common WAIT / OFF states", r1_waits)
    format_counts("R1: blocked / rejected execution events", r1_rejections)
    format_counts("R2: reasons for successfully cancelled broker orders", r2_cancels)
    format_counts("R2: rejected new setup / placement reasons", r2_rejections)
    format_counts("R2: broker-side order outcomes", r2_broker_states)

    r2_armed = sum(r["event"] == "ARMED" for r in r2)
    r2_held = sum(r["reason"] == "HOLD" for r in r2)
    print(f"\nR2 ARMED events: {r2_armed}")
    print(f"R2 HOLD state entries: {r2_held} (de-duplicated snapshots)")

    if learning:
        last = learning[-1]
        print("\nLearning, last actual broker-basket snapshot:")
        print("  " + (last.get("details") or "no details"))
    else:
        print("\nLearning: no verified closed-basket snapshot yet.")

    print("\nImportant: compare identical periods and account conditions.")
    print("Use Strategy Tester and forward-demo testing for profitability.")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python XAU_AUDIT_REPORT_v1.py /path/to/XAU_AUDIT_*.csv")
        raise SystemExit(2)
    audit_report(Path(sys.argv[1]))
