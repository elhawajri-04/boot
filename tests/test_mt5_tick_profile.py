"""Offline-only unit tests. Synthetic quotes do not prove trading performance."""
from __future__ import annotations

from collections import Counter
from decimal import Decimal as D
import gzip
import importlib.util
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
import csv

MODULE = Path(__file__).resolve().parents[1] / "research" / "mt5_tick_profile" / "profile.py"
spec = importlib.util.spec_from_file_location("mt5_quote_profile", MODULE)
prof = importlib.util.module_from_spec(spec)
assert spec and spec.loader
spec.loader.exec_module(prof)


def q(ms: int, mid: str, symbol="XAUUSD.s", spread="0.20"):
    m = D(mid)
    s = D(spread)
    return ms, m-s/2, m+s/2, symbol


def produce(quotes, *, window=60, min_updates=1):
    return list(prof.analyze(quotes, bin_size=D("0.10"), window_seconds=window,
                             min_updates=min_updates, required_symbol="XAUUSD.s"))


class TestMath(unittest.TestCase):
    def test_bin_round_half_up(self):
        self.assertEqual(prof.to_bin(D("4165.45"), D("0.1")), D("4165.5"))

    def test_bin_step_not_implicitly_gc_tick(self):
        self.assertEqual(prof.to_bin(D("4165.45"), D("0.50")), D("4165.5"))

    def test_value_area_single(self):
        self.assertEqual(prof.value_area(Counter({D("10"): 4}), D("0.7")), (D("10"), D("10"), D("10")))

    def test_poc_tie_prefers_lower_price(self):
        poc, *_ = prof.value_area(Counter({D("2"): 5, D("1"): 5}), D("0.7"))
        self.assertEqual(poc, D("1"))

    def test_value_area_expand_heavier_adjacent(self):
        hist = Counter({D("1"):3, D("2"):5, D("3"):4, D("4"):1})
        poc, val, vah = prof.value_area(hist, D("0.7"))
        self.assertEqual((poc, val, vah), (D("2"), D("1"), D("3")))

    def test_empty_profile_rejected(self):
        with self.assertRaises(prof.QuoteDataError): prof.value_area(Counter(), D("0.7"))

    def test_invalid_fraction_low(self):
        with self.assertRaises(prof.QuoteDataError): prof.value_area(Counter({D("1"):1}), D("0"))

    def test_invalid_fraction_high(self):
        with self.assertRaises(prof.QuoteDataError): prof.value_area(Counter({D("1"):1}), D("1.01"))

    def test_decimal_nan_rejected(self):
        with self.assertRaises(prof.QuoteDataError): prof.number("NaN", "bid")

    def test_decimal_infinity_rejected(self):
        with self.assertRaises(prof.QuoteDataError): prof.number("Infinity", "bid")


class TestTiming(unittest.TestCase):
    def test_utc_ms(self):
        self.assertEqual(prof.utc_ms(0), "1970-01-01T00:00:00.000Z")

    def test_empty_input(self):
        self.assertEqual(produce([]), [])

    def test_first_window_is_not_usable(self):
        r = produce([q(0,"10"),q(60000,"11")])
        self.assertFalse(r[0]["usable_for_research"])
        self.assertTrue(r[0]["left_truncated"])

    def test_final_window_not_complete(self):
        r = produce([q(60000,"10"),q(120000,"11")])
        self.assertFalse(r[-1]["window_complete"])
        self.assertIsNone(r[-1]["available_at_utc"])
        self.assertFalse(r[-1]["usable_for_research"])

    def test_middle_window_completed_only_on_next_quote(self):
        r = produce([q(100,"10"),q(60100,"11"),q(120100,"12")])
        self.assertEqual(len(r), 3)
        self.assertTrue(r[1]["usable_for_research"])
        self.assertEqual(r[1]["available_at_utc"], prof.utc_ms(120100))

    def test_no_premature_availability_for_gapped_windows(self):
        r = produce([q(100,"10"),q(60100,"11"),q(900100,"12")])
        self.assertEqual(r[1]["available_at_utc"], prof.utc_ms(900100))

    def test_repeated_timestamps_allowed(self):
        r = produce([q(100,"10"),q(100,"11"),q(60100,"12")])
        self.assertEqual(r[0]["quote_update_count"], 2)

    def test_backward_timestamp_rejected(self):
        with self.assertRaises(prof.QuoteDataError): produce([q(60100,"11"),q(100,"12")])

    def test_windows_bucketed_utc(self):
        r = produce([q(61000,"11"),q(120000,"12")])
        self.assertEqual(r[0]["window_start_utc"], prof.utc_ms(60000))
        self.assertEqual(r[0]["window_end_utc"], prof.utc_ms(120000))

    def test_low_count_does_not_qualify(self):
        r = produce([q(100,"10"),q(61000,"11"),q(120100,"12")],min_updates=2)
        self.assertFalse(r[1]["usable_for_research"])

    def test_mid_up_down_zero(self):
        r=produce([q(100,"10"),q(200,"11"),q(300,"10"),q(60100,"11")])
        self.assertEqual((r[0]["up_midquote_updates"], r[0]["down_midquote_updates"]),(1,1))

    def test_no_market_execution_possible(self):
        r=produce([q(100,"10"),q(60100,"11")])
        for item in r:
            self.assertFalse(item["execution_allowed"])
            self.assertIsNone(item["buyer_aggressor_delta"])
            self.assertIsNone(item["comex_volume"])

    def test_invalid_bin(self):
        with self.assertRaises(prof.QuoteDataError):
            list(prof.analyze([q(100,"10")],bin_size=D("0")))

    def test_invalid_window(self):
        with self.assertRaises(prof.QuoteDataError):
            list(prof.analyze([q(100,"10")],bin_size=D("0.1"),window_seconds=0))

    def test_mixed_symbols_rejected(self):
        with self.assertRaises(prof.QuoteDataError):
            produce([q(100,"10"),q(200,"11","GCZ6")])

    def test_counts_and_spread(self):
        r=produce([q(100,"10","XAUUSD.s","0.2"),q(200,"10.2","XAUUSD.s","0.4"),q(60100,"11")])
        self.assertEqual(r[0]["quote_update_count"],2)
        self.assertEqual(r[0]["mean_spread_usd"], 0.3)

    def test_hvn_lvn_are_proxies(self):
        r=produce([q(100,"10"),q(200,"10"),q(300,"10.1"),q(60100,"11")])
        self.assertIn("hvn_bins_proxy",r[0]);self.assertIn("lvn_bins_proxy",r[0])
        self.assertEqual(r[0]["mode"],"MT5_QUOTE_UPDATE_PROFILE_ONLY")


class TestCSV(unittest.TestCase):
    def setUp(self):
        self.tmp=TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.path=Path(self.tmp.name)/"quotes.csv"

    def write_rows(self,rows,*,path=None,fields=("time_msc","bid","ask","flags","symbol")):
        file=path or self.path
        opener=gzip.open if str(file).endswith(".gz") else open
        with opener(file,"wt",newline="",encoding="utf-8") as f:
            out=csv.DictWriter(f,fieldnames=fields)
            out.writeheader();out.writerows(rows)
        return file

    def row(self,ms=100,bid="10",ask="10.2",flags="6",symbol="XAUUSD.s"):
        return dict(time_msc=str(ms),bid=bid,ask=ask,flags=flags,symbol=symbol)

    def test_basic_csv_read(self):
        self.write_rows([self.row(),self.row(200,"10.1","10.3")])
        self.assertEqual(len(list(prof.quote_updates(self.path))),2)

    def test_gz_csv_read(self):
        path=self.path.with_suffix(".csv.gz")
        self.write_rows([self.row()],path=path)
        self.assertEqual(len(list(prof.quote_updates(path))),1)

    def test_duplicate_snapshot_skipped(self):
        self.write_rows([self.row(),self.row(200)])
        self.assertEqual(len(list(prof.quote_updates(self.path))),1)

    def test_bid_change_same_mid_accepted(self):
        self.write_rows([self.row(),self.row(200,"9.9","10.3")])
        self.assertEqual(len(list(prof.quote_updates(self.path))),2)

    def test_negative_spread_rejected(self):
        self.write_rows([self.row(ask="9")])
        with self.assertRaises(prof.QuoteDataError):list(prof.quote_updates(self.path))

    def test_zero_bid_rejected(self):
        self.write_rows([self.row(bid="0")])
        with self.assertRaises(prof.QuoteDataError):list(prof.quote_updates(self.path))

    def test_missing_field_rejected(self):
        self.write_rows([dict(time_msc="100",bid="10")],fields=("time_msc","bid"))
        with self.assertRaises(prof.QuoteDataError):list(prof.quote_updates(self.path))

    def test_corrupt_time_rejected(self):
        self.write_rows([self.row(ms="bad")])
        with self.assertRaises(prof.QuoteDataError):list(prof.quote_updates(self.path))

    def test_negative_flags_rejected(self):
        self.write_rows([self.row(flags="-1")])
        with self.assertRaises(prof.QuoteDataError):list(prof.quote_updates(self.path))

    def test_different_symbols_rejected(self):
        self.write_rows([self.row(),self.row(200,"10.1","10.3",symbol="OTHER")])
        with self.assertRaises(prof.QuoteDataError):list(prof.quote_updates(self.path))

    def test_required_symbol(self):
        self.write_rows([self.row()])
        with self.assertRaises(prof.QuoteDataError):list(prof.quote_updates(self.path,required_symbol="XAUUSD"))

    def test_sorted_timestamp(self):
        self.write_rows([self.row(200),self.row(100,"10.1","10.3")])
        with self.assertRaises(prof.QuoteDataError):list(prof.quote_updates(self.path))

    def test_main_writes_jsonl(self):
        self.write_rows([self.row(),self.row(61000,"10.1","10.3"),self.row(120100,"10.2","10.4")])
        output=self.path.with_name("features.jsonl")
        self.assertEqual(prof.main(["--csv",str(self.path),"--output",str(output),"--min-updates","1"]),0)
        self.assertEqual(len(output.read_text().splitlines()),1) # all quotes are in same 15min bucket

    def test_main_with_shorter_window(self):
        self.write_rows([self.row(),self.row(61000,"10.1","10.3"),self.row(120100,"10.2","10.4")])
        output=self.path.with_name("features.jsonl")
        prof.main(["--csv",str(self.path),"--output",str(output),"--window-seconds","60","--min-updates","1"])
        self.assertEqual(len(output.read_text().splitlines()),3)


if __name__=="__main__":unittest.main(verbosity=2)
