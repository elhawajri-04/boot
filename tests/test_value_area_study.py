"""Read-only synthetic tests; not market profitability evidence."""
from __future__ import annotations
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

import numpy as np
import pandas as pd

MOD = Path(__file__).resolve().parents[1] / "research" / "mt5_tick_profile" / "value_area_study.py"
spec = importlib.util.spec_from_file_location("value_area_study", MOD)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class TestChronologicalValueArea(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.fp = self.root / "features.jsonl"
        self.bars = self.root / "m15.csv"
        self.ticks = self.root / "ticks.csv"
        base = pd.Timestamp("2026-02-02T01:00:00Z")
        self.rows = []
        self.candles = []
        self.quotes = []
        for n in range(6):
            start = base + pd.Timedelta(minutes=15 * n)
            t_ms = int(start.timestamp() * 1000)
            ref = 1000.0 + n
            self.candles.append({"t": int(start.timestamp()), "o": ref, "h": ref + 3,
                                 "l": ref - 3, "c": ref + 1,
                                 "tick_volume": 7, "real_volume": 0})
            self.quotes.append({"time_msc": t_ms+50, "bid": ref, "ask": ref + 0.1, "flags": 0})
            self.quotes.append({"time_msc": t_ms+100, "bid": ref+0.2, "ask": ref + 0.3, "flags": 0})
            end = start + pd.Timedelta(minutes=15)
            self.rows.append({"symbol": "XAUUSD.s", "mode": "MT5_QUOTE_UPDATE_PROFILE_ONLY",
                              "window_start_utc": start.isoformat(), "window_end_utc": end.isoformat(),
                              "available_at_utc": (end + pd.Timedelta(milliseconds=50)).isoformat(),
                              "window_complete": True, "left_truncated": n == 0,
                              "usable_for_research": n != 0,
                              "quote_update_count": 500, "poc_price": str(ref),
                              "val_price": str(ref - 1), "vah_price": str(ref + 0.5)})
        self.quotes.append({"time_msc": int((base+pd.Timedelta(minutes=90)).timestamp()*1000)+50,
                            "bid": 1006., "ask": 1006.1, "flags": 0})
        self.write()

    def write(self):
        self.fp.write_text("\n".join(json.dumps(x) for x in self.rows)+"\n")
        pd.DataFrame(self.candles).to_csv(self.bars,index=False)
        pd.DataFrame(self.quotes).to_csv(self.ticks,index=False)

    def test_no_future_and_publication_bid(self):
        data, diag = module.build_dataset(self.fp,self.bars,self.ticks)
        self.assertEqual(len(data), 4)  # first bucket is left truncated, last has no next M15 candle
        self.assertEqual(diag["raw_feature_windows"],6)
        self.assertEqual(float(data.iloc[0].publication_bid), 1002.0)
        self.assertEqual(float(data.iloc[0].next_return_bid), 1.0)
        self.assertEqual(float(data.iloc[0].arrival_ms),50)
        self.assertTrue((data.available_at >= data.end).all())
        self.assertTrue((data.available_at < data.end+pd.Timedelta(minutes=1)).all())

    def test_late_publication_rejected(self):
        self.rows[1]["available_at_utc"] = (pd.Timestamp(self.rows[1]["window_end_utc"]) + pd.Timedelta(seconds=100)).isoformat()
        self.write()
        data, diag = module.build_dataset(self.fp,self.bars,self.ticks)
        self.assertEqual(len(data),3)
        self.assertEqual(diag["delayed_over_60_seconds"],1)

    def test_no_next_m15_bar(self):
        self.candles.pop()
        self.write()
        with self.assertRaisesRegex(ValueError,"do not cover quote profiles"):
            module.build_dataset(self.fp,self.bars,self.ticks)

    def test_reject_mixed_symbol(self):
        self.rows[2]["symbol"] = "XAUUSD"
        self.write()
        with self.assertRaisesRegex(ValueError,"mixed"):
            module.build_dataset(self.fp,self.bars,self.ticks)

    def test_reject_fake_comex_or_real_volume(self):
        self.rows[1]["mode"] = "COMEX_REAL_VOLUME"
        self.write()
        with self.assertRaisesRegex(ValueError,"not a quote profile"):
            module.build_dataset(self.fp,self.bars,self.ticks)

    def test_reject_invalid_value_area(self):
        self.rows[1]["val_price"] = "2000"
        self.write()
        with self.assertRaisesRegex(ValueError,"invalid price value area"):
            module.build_dataset(self.fp,self.bars,self.ticks)

    def test_reject_unsorted_ticks(self):
        self.quotes[2]["time_msc"] = self.quotes[0]["time_msc"]-1
        self.write()
        with self.assertRaisesRegex(ValueError,"unsorted tick"):
            module.build_dataset(self.fp,self.bars,self.ticks)

    def test_no_publication_tick(self):
        self.rows[1]["available_at_utc"] = (pd.Timestamp(self.rows[1]["window_end_utc"]) + pd.Timedelta(milliseconds=51)).isoformat()
        self.write()
        data, diag = module.build_dataset(self.fp,self.bars,self.ticks)
        self.assertEqual(len(data),3)
        self.assertEqual(diag["unmatched_publication_ticks_on_otherwise_valid_windows"],1)

    def test_model_doesnt_learn_holdout_targets(self):
        rng=np.random.default_rng(43)
        n=60
        d=pd.DataFrame({"candle_range":rng.random(n)*20,"log_updates":rng.random(n)*2,
                        "profile_width_scaled":rng.random(n),"dist_poc_scaled":rng.random(n),
                        "above_value":rng.integers(0,2,n),"below_value":rng.integers(0,2,n),
                        "next_range":rng.random(n)*30})
        cols=["candle_range", "log_updates"]
        pred1=module._fit_predict(d.iloc[:45],d.iloc[45:],cols)
        d.loc[45:,'next_range'] = 10000  # future outcomes changed
        pred2=module._fit_predict(d.iloc[:45],d.iloc[45:],cols)
        np.testing.assert_allclose(pred1,pred2)

    def test_small_holdout_rejected(self):
        d=pd.DataFrame(index=pd.date_range('2026-02-02',periods=4,freq='15min',tz='UTC'))
        with self.assertRaisesRegex(ValueError,'too small'):
            module.evaluate(d,{})


if __name__ == '__main__':
    unittest.main()
