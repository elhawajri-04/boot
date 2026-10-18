"""Diff tests verify F only diagnoses, not strategy/risk/order routing."""
from __future__ import annotations
from pathlib import Path
from collections import Counter
import difflib
import unittest

ROOT=Path(__file__).resolve().parents[1]
E=ROOT/'XAU_EA_SmartExec_E.mq5'
if not E.is_file():
    E=Path('/mnt/data/e_release/XAU_EA_SmartExec_E.mq5')
F=ROOT/'XAU_EA_SmartExec_F.mq5'

class EAFStaticDiffTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not E.exists():
            raise unittest.SkipTest('E baseline not available: local diff test only')
        cls.e=E.read_text()
        cls.f=F.read_text()

    def test_execution_api_occurrences_unchanged(self):
        for name in ['SendProtectedMarketOrder(', 'ICT4Pending(', 'CalculateSingleRiskSizedLot(', 'DeleteR2PendingOrders(',
                     'ProcessICT4R2PendingLifecycle(', 'NewsAllowsAutoEntry(', 'AutoEntrySessionOpen(',
                     'BuildR1ScalpStop(', 'ValidateStops(', 'ProcessICT4Executors(', 'trade.Buy(', 'trade.Sell(']:
            with self.subTest(name=name):
                self.assertEqual(self.e.count(name),self.f.count(name))

    def test_r2_lifecycle_unchanged(self):
        needle='void ProcessICT4R2PendingLifecycle()'
        stop='void ICT4Execute(string engine)'
        self.assertEqual(self.e.split(needle,1)[1].split(stop,1)[0],self.f.split(needle,1)[1].split(stop,1)[0])

    def test_protected_sender_unchanged(self):
        for marker in ['bool SendProtectedMarketOrder(', 'bool ICT4Pending(']:
            self.assertIn(marker,self.e)
            self.assertIn(marker,self.f)
            def getbody(s):
                t=s.split(marker,1)[1]; i=t.index('{'); depth=0
                for j in range(i,len(t)):
                    if t[j]=='{':depth+=1
                    if t[j]=='}':
                        depth-=1
                        if depth==0:return t[i:j+1]
                raise AssertionError('Unmatched function block')
            self.assertEqual(getbody(self.e),getbody(self.f))

    def test_only_whitelisted_areas_modified(self):
        old=self.e.splitlines();new=self.f.splitlines()
        sm=difflib.SequenceMatcher(a=old,b=new,autojunk=False)
        allowed_old_sections=[(0,6),(480,502),(4520,4550),(4645,4680),(7445,7465),
            (11255,11350),(11545,11568),(12405,12535)]
        changes=[(i1,i2,j1,j2) for tag,i1,i2,j1,j2 in sm.get_opcodes() if tag!='equal']
        for i1,i2,j1,j2 in changes:
            with self.subTest(old_lines=(i1+1,i2),new_lines=(j1+1,j2)):
                self.assertTrue(any(lo<=i1 and i2<=hi for lo,hi in allowed_old_sections))
        self.assertGreater(len(changes),5)

    def test_f_diagnostic_new_labels(self):
        for s in ['WORKER MODEL UNVERIFIED','WORKER FEED MISSING','WORKER FEED STALE','poll_health=%s','EXEC_PIPELINE_20261018_F','mode=%s']:
            self.assertIn(s,self.f)

if __name__=='__main__':unittest.main()
