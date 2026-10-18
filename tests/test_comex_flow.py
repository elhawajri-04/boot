"""Synthetic-data, offline-only tests. Not evidence of strategy profitability."""
from __future__ import annotations

from decimal import Decimal
import gzip
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve()
ENGINE = HERE.parents[1] / "research" / "comex_flow" / "engine.py"
spec = importlib.util.spec_from_file_location("comex_flow_engine", ENGINE)
engine = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = engine
spec.loader.exec_module(engine)

HEADER = "ts_event,symbol,action,price,size,side\n"
T0 = 1_782_000_000_000_000_000  # synthetic timestamp in nanoseconds


def row(i, price="3400.0", size=1, side="B", symbol="GCZ6", ts=None):
    return f"{T0 + i * 1_000_000_000 if ts is None else ts},{symbol},T,{price},{size},{side}\n"


class FlowTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "trades.csv"
        self.output = Path(self.tmp.name) / "features.jsonl"

    def write(self, lines, header=HEADER):
        self.path.write_text(header + "".join(lines), encoding="utf8")

    def generate(self, **overrides):
        kwargs = dict(mode="pretty", tick_size=Decimal("0.1"), contract=None,
                      window_seconds=300, value_area_fraction=Decimal("0.7"),
                      imbalance_ratio=Decimal("3"), min_imbalance_volume=2,
                      min_trades=1, min_known_ratio=Decimal("0.8"),
                      max_profile_ticks=10000, include_levels=True)
        kwargs.update(overrides)
        count = engine.generate(self.path, self.output, **kwargs)
        rows = [json.loads(x) for x in self.output.read_text(encoding="utf8").splitlines()]
        self.assertEqual(count, len(rows))
        return rows

    def test_side_buy_and_sell_aggressors(self):
        self.write([row(0, size=4, side="B"), row(1, size=2, side="A")])
        r = self.generate()[0]
        self.assertEqual((r["buy_aggressor_contracts"], r["sell_aggressor_contracts"]), (4, 2))
        self.assertEqual(r["delta_contracts"], 2)
        self.assertFalse(r["execution_allowed"])

    def test_unknown_side_unclassified_not_buy_or_sell(self):
        self.write([row(0, size=7, side="N"), row(1, size=1, side="B")])
        r = self.generate()[0]
        self.assertEqual((r["delta_contracts"], r["unclassified_contracts"]), (1, 7))
        self.assertEqual(r["quality"]["reason"], "PARTIAL_FINAL_WINDOW")
        self.assertLess(r["classified_volume_fraction"], 0.8)

    def test_tick_profile_poc_tie_picks_lower(self):
        self.write([row(0, "3400.0", 5), row(1, "3400.1", 5)])
        r = self.generate()[0]
        self.assertEqual(r["profile"]["poc"], 3400.0)
        self.assertEqual(r["profile"]["val"], 3400.0)
        self.assertEqual(r["profile"]["vah"], 3400.1)
        self.assertEqual(r["profile"]["value_area_fraction_actual"], 1.0)

    def test_profile_includes_unknown_in_poc_volume(self):
        self.write([row(0, "3400.0", 3, "N"), row(1, "3400.1", 2, "B")])
        self.assertEqual(self.generate()[0]["profile"]["poc"], 3400.0)

    def test_profile_gap_moves_across_empty_ticks(self):
        self.write([row(0, "3400.0", 6), row(1, "3400.2", 4)])
        r = self.generate()[0]
        self.assertEqual((r["profile"]["val"], r["profile"]["vah"]), (3400.0, 3400.2))

    def test_three_stacked_buy_diagonal_imbalances(self):
        lines = []
        for p in ["3400.0", "3400.1", "3400.2", "3400.3"]:
            lines.append(row(0, p, 2, "A"))
        for p in ["3400.1", "3400.2", "3400.3"]:
            lines.append(row(0, p, 8, "B"))
        self.write(lines)
        r = self.generate()[0]
        self.assertEqual(r["footprint"]["longest_stacked_buy"], 3)
        self.assertEqual(r["footprint"]["buy_imbalance_levels"], [3400.1, 3400.2, 3400.3])

    def test_diagonal_requires_both_nonzero_no_infinity(self):
        self.write([row(0, "3400.0", 99, "B")])
        r = self.generate()[0]
        self.assertEqual(r["footprint"]["buy_imbalance_levels"], [])

    def test_sell_diagonal_imbalance(self):
        self.write([row(0, "3400.0", 8, "A"), row(1, "3400.1", 2, "B")])
        r = self.generate()[0]
        self.assertEqual(r["footprint"]["sell_imbalance_levels"], [3400.0])

    def test_closed_buckets_independent_and_cvd_forward_only(self):
        self.write([row(0, size=8, side="B"), row(1, size=3, side="A"),
                    row(301, size=4, side="A")])
        r = self.generate()
        self.assertEqual(len(r), 2)
        self.assertEqual(r[0]["cvd_contracts"], 5)
        self.assertEqual(r[1]["cvd_contracts"], 1)
        self.assertEqual(r[0]["trades"], 2)
        self.assertNotEqual(r[0]["window_start_utc"], r[1]["window_start_utc"])

    def test_min_activity(self):
        self.write([row(0)])
        r = self.generate(min_trades=10)[0]
        self.assertFalse(r["quality"]["usable_for_research"])
        self.assertEqual(r["quality"]["reason"], "PARTIAL_FINAL_WINDOW")
        self.assertEqual(r["trades"], 1)

    def test_valid_with_quality_threshold(self):
        self.write([row(0, size=9, side="B"), row(1, size=1, side="N"), row(301)])
        r = self.generate(min_known_ratio=Decimal("0.9"), min_trades=2)[0]
        self.assertTrue(r["quality"]["usable_for_research"])

    def test_raw_1e9_prices(self):
        self.write([row(0, price="3400100000000")])
        self.assertEqual(self.generate(mode="raw-1e9")[0]["profile"]["poc"], 3400.1)

    def test_wrong_price_mode_fails(self):
        self.write([row(0, price="3400100000000")])
        with self.assertRaisesRegex(ValueError, "profile spans too many|price"):
            self.generate(mode="pretty")

    def test_wrong_tick_size_fails_no_partial_output(self):
        self.write([row(0, price="3400.15")])
        with self.assertRaisesRegex(ValueError, "not an exact multiple"):
            self.generate()
        self.assertFalse(self.output.exists())

    def test_no_mixed_contract_roll(self):
        self.write([row(0, symbol="GCZ6"), row(1, symbol="GCG7")])
        with self.assertRaisesRegex(ValueError, "multiple instruments"):
            self.generate()

    def test_select_contract_from_mixed_input(self):
        self.write([row(0, symbol="GCZ6"), row(1, symbol="GCG7")])
        r = self.generate(contract="GCG7")[0]
        self.assertEqual((r["instrument"], r["trades"]), ("GCG7", 1))

    def test_out_of_order_fails(self):
        self.write([row(1), row(0)])
        with self.assertRaisesRegex(ValueError, "out of ts_event order"):
            self.generate()

    def test_partial_file_is_not_overwritten_on_failure(self):
        self.output.write_text("older-valid-report\n")
        self.write([row(0), row(1, price="bad")])
        with self.assertRaises(ValueError):
            self.generate()
        self.assertEqual(self.output.read_text(), "older-valid-report\n")

    def test_naive_time_rejected(self):
        self.assertRaisesRegex(ValueError, "Naive", engine.ns_from_field, "2026-10-18T10:00:00")

    def test_utc_iso_time_accepted(self):
        a = engine.ns_from_field("2026-10-18T10:00:00Z")
        b = engine.ns_from_field("2026-10-18T13:00:00+03:00")
        self.assertEqual(a, b)

    def test_precise_nanosecond_iso(self):
        a = engine.ns_from_field("2026-10-18T10:00:00.123456789Z")
        b = engine.ns_from_field("2026-10-18T13:00:00.123456789+03:00")
        self.assertEqual(a, b)
        self.assertEqual(engine.iso_ns(a), "2026-10-18T10:00:00.123456789Z")

    def test_nanosecond_ordering_strict(self):
        ts = engine.ns_from_field("2026-10-18T10:00:00.123456789Z")
        self.write([row(0, ts=ts), row(1, ts=ts-1)])
        self.assertRaisesRegex(ValueError, "out of ts_event order", self.generate)

    def test_timestamp_seconds_rejected(self):
        self.assertRaisesRegex(ValueError, "nanoseconds", engine.ns_from_field, "1782000000")

    def test_size_zero_rejected(self):
        self.write([row(0, size=0)])
        self.assertRaisesRegex(ValueError, "positive integer", self.generate)

    def test_invalid_side_rejected(self):
        self.write([row(0, side="BUY")])
        self.assertRaisesRegex(ValueError, "unknown side", self.generate)

    def test_action_not_trade_rejected(self):
        self.write([row(0).replace(",T,", ",A,")])
        self.assertRaisesRegex(ValueError, "non-trade action", self.generate)

    def test_missing_contract_identity_rejected(self):
        self.write(["".join([f"{T0},T,3400.0,1,B\n"])],
                   header="ts_event,action,price,size,side\n")
        self.assertRaisesRegex(ValueError, "symbol.*instrument_id", self.generate)

    def test_multi_contract_without_symbol_but_instrument_id(self):
        self.write([f"{T0},123,T,3400.0,1,B\n"],
                   header="ts_event,instrument_id,action,price,size,side\n")
        self.assertEqual(self.generate()[0]["instrument"], "123")

    def test_empty_selection_rejected(self):
        self.write([row(0)])
        self.assertRaisesRegex(ValueError, "no trades matched", lambda: self.generate(contract="GCX5"))

    def test_include_levels_disabled(self):
        self.write([row(0)])
        self.assertNotIn("levels", self.generate(include_levels=False)[0]["footprint"])

    def test_gzip_csv(self):
        p = self.path.with_suffix(".csv.gz")
        with gzip.open(p, "wt", encoding="utf-8") as f:
            f.write(HEADER + row(0))
        self.path = p
        self.assertEqual(self.generate()[0]["trades"], 1)

    def test_bad_parameters_rejected(self):
        self.write([row(0)])
        self.assertRaises(ValueError, lambda: self.generate(window_seconds=0))
        self.assertRaises(ValueError, lambda: self.generate(min_known_ratio=Decimal("2")))
        self.assertRaises(ValueError, lambda: self.generate(tick_size=Decimal("0")))

    def test_final_bucket_is_unverified_and_never_published_as_complete(self):
        self.write([row(0, size=50, side="B")])
        r = self.generate()[0]
        self.assertFalse(r["window_complete"])
        self.assertIsNone(r["available_at_utc"])
        self.assertFalse(r["quality"]["usable_for_research"])

    def test_closed_bucket_availability_uses_next_trade_timestamp(self):
        self.write([row(0), row(901)])
        r = self.generate()[0]
        self.assertTrue(r["window_complete"])
        self.assertEqual(r["available_at_utc"], engine.iso_ns(T0 + 901_000_000_000))

    def test_quality_gate_after_full_bucket(self):
        self.write([row(0, side="N", size=10), row(301)])
        r = self.generate()[0]
        self.assertEqual(r["quality"]["reason"], "UNCLASSIFIED_VOLUME_HIGH")

    def test_insufficient_trades_after_complete_bucket(self):
        self.write([row(0), row(301)])
        r = self.generate(min_trades=10)[0]
        self.assertEqual(r["quality"]["reason"], "INSUFFICIENT_TRADES")

    def test_never_emits_trading_signal(self):
        self.write([row(0)])
        r = self.generate()[0]
        self.assertEqual(r["mode"], "HISTORICAL_OBSERVATION_ONLY")
        self.assertFalse(r["execution_allowed"])
        self.assertNotIn("order_type", r)
        self.assertNotIn("ready", r)

    def test_schema_fields_and_roll_guard(self):
        self.write([row(0)])
        r = self.generate()[0]
        self.assertEqual((r["dataset"], r["source_schema"]), ("GLBX.MDP3", "trades"))
        self.assertTrue(r["footprint"]["requires_mbo_for_order_book_absorption"])

    def test_cli_success(self):
        self.write([row(0)])
        r = subprocess.run([sys.executable, str(ENGINE), "--csv", str(self.path),
                            "--output", str(self.output), "--price-format", "pretty",
                            "--tick-size", "0.1", "--min-trades", "1"],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("Created 1 closed historical", r.stdout)

    def test_cli_failure_exit2(self):
        self.write([row(0, price="bad")])
        r = subprocess.run([sys.executable, str(ENGINE), "--csv", str(self.path),
                            "--output", str(self.output), "--price-format", "pretty",
                            "--tick-size", "0.1"], capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
