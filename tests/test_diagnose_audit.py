from __future__ import annotations
import importlib.util
import tempfile
from pathlib import Path
import unittest

FILE=Path(__file__).resolve().parents[1]/'research'/'execution_audit'/'diagnose_audit.py'
spec=importlib.util.spec_from_file_location('audit_diagnostic',FILE)
module=importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class AuditDiagnosticsTests(unittest.TestCase):
    def test_legacy_protocol(self):
        self.assertEqual(module.category({'engine':'R2','event':'STATE','reason':'REJECT','details':'WORKER_PENDING_ONLY_PROTOCOL_MISSING'}),'LEGACY_R2_PENDING_PROTOCOL')
    def test_legacy_worker(self):
        self.assertEqual(module.category({'engine':'R2','event':'STATE','reason':'PROTOCOL','details':'V2_5_PENDING_ONLY_WORKER_REQUIRED'}),'LEGACY_R2_PENDING_PROTOCOL')
    def test_session(self):
        self.assertEqual(module.category({'engine':'R1','event':'STATE','reason':'AUTO_EXEC','details':'OFF | SESSION'}),'SESSION_GUARD')
    def test_stale(self):
        self.assertEqual(module.category({'engine':'R2','event':'STATE','reason':'AUTO_EXEC','details':'BLOCK | WORKER MODEL/AGE'}),'WORKER_MODEL_OR_STALE_FEED')
    def test_news(self):
        self.assertEqual(module.category({'engine':'R1','event':'STATE','reason':'BLOCK','details':'BLOCK | NEWS'}),'NEWS_GUARD')
    def test_risk(self):
        self.assertEqual(module.category({'engine':'R1','event':'REJECT','reason':'EXECUTION_SKIP','details':'R1 RISK 10.39% > 5.00%'}),'RISK_GUARD_OR_RISK_LOG')
    def test_executed_not_verified(self):
        self.assertEqual(module.category({'engine':'R1','event':'EXECUTED','reason':'BUY','details':'X'}),'EXECUTION_LOGGED_NOT_BROKER_VERIFIED')
    def test_qualifications(self):
        self.assertEqual(module.category({'engine':'R2','event':'STATE','reason':'REJECT','details':'R2 SETUP NOT ALLOWED'}),'UNQUALIFIED_SIGNAL')
    def test_exposure(self):
        self.assertEqual(module.category({'engine':'R1','event':'STATE','reason':'WAIT','details':'WAIT | POSITION ACTIVE'}),'EXISTING_EXPOSURE')
    def test_aggregation(self):
        with tempfile.TemporaryDirectory() as t:
            f=Path(t)/'data.csv'
            f.write_text('server_time,engine,event,reason,details\n2026.10.16 09:00:00,R2,STATE,PROTOCOL,V2_5_PENDING_ONLY_WORKER_REQUIRED\n2026.10.17 09:00:00,R1,STATE,AUTO_EXEC,OFF | SESSION\n')
            x=module.summarize(f)
            self.assertEqual(x['rows'],2)
            self.assertEqual(x['by_day']['2026-10-16']['LEGACY_R2_PENDING_PROTOCOL'],1)
    def test_malformed_timestamp(self):
        with tempfile.TemporaryDirectory() as t:
            f=Path(t)/'data.csv';f.write_text('server_time,engine,event,reason,details\nnot-a-date,R1,STATE,X,Y\n')
            with self.assertRaises(ValueError):module.summarize(f)
    def test_empty_csv(self):
        with tempfile.TemporaryDirectory() as t:
            f=Path(t)/'data.csv';f.write_text('server_time,engine,event,reason,details\n')
            with self.assertRaises(ValueError):module.summarize(f)

if __name__=='__main__':unittest.main()
