from pathlib import Path
import re, unittest, subprocess
s=(Path(__file__).resolve().parents[1] / 'XAU_V4_3_R1Swing_R2PendingGuard.mq5').read_text()
class SecurityRegressions(unittest.TestCase):
 def test_source_same_runtime_unless_explicit_patch(self):
  assert 'InpICTSMCObserveOnly' not in s
  assert 'ProcessAutoSignalExecutor();' not in s
  assert 'ProcessR2PendingExecutor();' not in s
 def test_r1_local_closed_m5(self):
  assert 'CopyRates(_Symbol,PERIOD_M5,1,lookback+strength+1,bars)' in s
  assert 'double candidate=buy?pivot-buffer:pivot+buffer;' in s
  assert 'BuildR1ScalpStop(side,realEntry,low,high,localStop,why)' in s
  assert 'sl=localStop;' in s
  assert 'riskDistance*InpSimpleRR' in s
  assert 'ValidateStops(side,realEntry,sl,tp,why)' in s
 def test_r2_pending_only_direction(self):
  assert 'R2 MUST BE PENDING' in s
  assert 'type=="BUY"||type=="BUY_LIMIT"||type=="BUY_STOP"' in s
  assert 'type=="SELL"||type=="SELL_LIMIT"||type=="SELL_STOP"' in s
  assert 'if(!allowed || !typeMatchesSide)' in s
  assert 'if(CountR2PendingOrders()<=0)\n    ICT4Execute("R2");' in s
 def test_pending_lifecycle(self):
  assert 'ProcessICT4R2PendingLifecycle();\n      ProcessICT4Executors();' in s
  assert 'if(CountR2PendingOrders()<=0)return;' in s
  for reason in ['NEWS_GUARD','ENTRY_SESSION_CLOSED','R2_WORKER_FEED_STALE',
                 'M15_CONFIRMED_STRUCTURAL_INVALIDATION','CONFIRMED_OPPOSITE_R2',
                 'R2_SL_RISK_CAP_EXCEEDED','TOTAL_XAU_SL_RISK_CAP_EXCEEDED']:
   assert reason in s
  assert 'DeleteR2PendingOrders(reason)' in s
  assert 'GlobalVariableSet(key,g_r2Invalidation)' in s
  assert 'GlobalVariableDel(ICT4R2InvalidationKey(ticket));' in s
  assert 'iClose(_Symbol,PERIOD_M15,1)' in s
 def test_protection_and_tracking_preserved(self):
  for text in ['AutoProtectOpenPositions();','EnforceMaxSLRiskGuardForNewPosition();',
               'ManageActiveBasketPositions();','SendProtectedMarketOrder(',
               'CalculateSingleRiskSizedLot(', 'InpEnableMaxSLRiskGuard = true',
               'InpNewsGuardFailClosed = true','InpTelemetryOnlyStagingMode = false']:
   assert text in s
 def test_visual_colors_preserved(self):
  assert "input color InpR2WatchSellColor = C'255,220,0';" in s
  assert 'AppendLegendRow(rows,tones,"R2 SELL  |  FVG/OB WATCH ONLY",InpR2WatchSellColor)' in s
 def test_braces(self):
  # Ignore strings and C++ style comments when checking delimiters.
  cleaned=re.sub(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'', lambda m:' ' * len(m.group()), s)
  stack=[]
  pairs={')':'(',']':'[','}':'{'}
  for idx,ch in enumerate(cleaned):
   if ch in '([{': stack.append((ch,idx))
   elif ch in ')]}':
    if not stack or stack[-1][0]!=pairs[ch]:self.fail(f'unbalanced {ch} at char {idx}')
    stack.pop()
  self.assertFalse(stack,stack[-5:])

if __name__=='__main__':unittest.main(verbosity=2)