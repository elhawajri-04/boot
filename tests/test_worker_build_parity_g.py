"""Static release safety tests for published EA G vs EA F and Worker E."""
from pathlib import Path
import unittest
import hashlib

ROOT=Path(__file__).resolve().parents[1]
F=(ROOT/'XAU_EA_SmartExec_F.mq5').read_text(encoding='utf-8')
G=(ROOT/'XAU_EA_SmartExec_G.mq5').read_text(encoding='utf-8')
W=(ROOT/'XAU_Worker_SmartExec_E.js').read_text(encoding='utf-8')
EXPECTED='XAU_V4_ICT_SMC_SMART_EXEC_20261017_E'

class ReleaseGStaticSafety(unittest.TestCase):
    def test_worker_e_matches_expected(self):
        self.assertIn(f'const BUILD_VERSION = "{EXPECTED}";',W)
    def test_worker_e_exposes_build_in_health(self):
        self.assertIn('build: BUILD_VERSION,',W)
        self.assertIn('if (url.pathname === "/health")',W)
    def test_ea_g_checks_worker_e_parity(self):
        self.assertIn(f'string expectedBuild="{EXPECTED}";',G)
        self.assertIn('observedBuild=JsonGetString(response,"build")',G)
    def test_build_mismatch_reports_actual(self):
        self.assertIn('WRONG_WORKER_BUILD expected=',G)
        self.assertIn('" got="+',G)
    def test_no_legacy_build_constant(self):
        self.assertNotIn('XAU_V4_ICT_SMC_ADAPTIVE_MARKET_PENDING',G)
    def test_release_name(self):
        self.assertIn('EXEC_PIPELINE_20261019_G',G)
        self.assertNotIn('EXEC_PIPELINE_20261018_F',G)
    def test_unchanged_execution_and_broker_logic(self):
        a=G.replace('EXEC_PIPELINE_20261019_G','EXEC_PIPELINE_20261018_F').replace(
            'ADAPTIVE SMART EXEC G | WORKER BUILD PARITY FIX',
            'ADAPTIVE SMART EXEC F | DIAGNOSTICS ONLY')
        begin=a.index('      // Worker E is the published matching Smart Execution build for EA G.')
        end=a.index('      if(ok && StringFind(response,"\\\"strategy_model\\\"',begin)
        old=('      // Strict version and strategy parity: old v2.8 must fail.\n'
          '      if(ok && StringFind(response,"\\\"build\\\":\\\"XAU_V4_ICT_SMC_ADAPTIVE_MARKET_PENDING\\\"")<0)\n'
          '      {ok=false;failReason="WRONG_WORKER_BUILD";}\n')
        a=a[:begin]+old+a[end:]
        a=a.replace('      // Also verify the required service and policy capability fields.',
             '      // Check stable capability flags, NOT the build-name string.\n'
             '      // Worker v2.4 renamed BUILD_VERSION while retaining the same features.')
        self.assertEqual(a,F,'G unexpectedly altered trading logic outside health version check')
    def test_no_demo_only_gate_added(self):
        self.assertNotIn('InpTelemetryOnlyStagingMode',G)
    def test_r2_market_and_pending_preserved(self):
        for flag in ['InpR2EnableMarketExecution = true','"BUY_LIMIT"','"SELL_STOP"','"BUY"','"SELL"']:
            self.assertIn(flag,G)
    def test_risk_and_news_unchanged(self):
        for mark in ['InpEnableMaxSLRiskGuard','InpR2AutoMaxSLRiskPercent','NewsAllowsAutoEntry()','PrecheckNewRiskAgainstCap']:
            self.assertEqual(G.count(mark),F.count(mark))
    def test_worker_sha_expected(self):
        b=(ROOT/'XAU_Worker_SmartExec_E.js').read_bytes()
        blob=hashlib.sha1(b'blob '+str(len(b)).encode()+b'\0'+b).hexdigest()
        self.assertEqual(blob,'ac1718b0d08b85be670097456eea386dbfeeb03d')
    def test_f_sha_expected(self):
        b=(ROOT/'XAU_EA_SmartExec_F.mq5').read_bytes()
        blob=hashlib.sha1(b'blob '+str(len(b)).encode()+b'\0'+b).hexdigest()
        self.assertEqual(blob,'b27a7177253dfdab7e8a98e5147fba460759492e')

if __name__=='__main__':unittest.main(verbosity=2)
