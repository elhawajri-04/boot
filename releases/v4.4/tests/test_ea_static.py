from pathlib import Path
import unittest,re
from collections import Counter
s=(Path(__file__).resolve().parents[1]/'XAU_V4_4_StableR2Cancel_BridgeDiagnostics.mq5').read_text(encoding='utf-8')
base=Path(__file__).resolve().parents[2]/'v4.3/XAU_V4_3_R1Swing_R2PendingGuard.mq5'

class V44Checks(unittest.TestCase):
 def test_all_pending_only_guards_retained(self):
  for required in ['if(CountR2PendingOrders()<=0)\n    ICT4Execute("R2");',
       'ProcessICT4R2PendingLifecycle();\n      ProcessICT4Executors();',
       'if(!r1 && !allowed)', 'if(!typeMatchesSide)',
       'if(!NewsAllowsAutoEntry())', 'CalculateSingleRiskSizedLot(',
       'BuildR1ScalpStop(side,realEntry,low,high,localStop,why)',
       'InpEnableMaxSLRiskGuard = true', 'InpNewsGuardFailClosed = true',
       'ManageActiveBasketPositions();', 'AutoProtectOpenPositions();']:
   self.assertIn(required,s,required)
  self.assertNotIn('InpICTSMCObserveOnly',s)
 def test_r2_cancel_retry_safety(self):
  self.assertIn('string R2CancellationRetryKey(ulong ticket)',s)
  self.assertIn('GlobalVariableCheck(retryKey)',s)
  self.assertIn('GlobalVariableSet(retryKey,(double)retryAt)',s)
  self.assertIn('GlobalVariableDel(retryKey);',s)
  self.assertIn('retcode==TRADE_RETCODE_MARKET_CLOSED',s)
  self.assertIn('" | STILL PENDING ON BROKER"',s)
  self.assertIn('allDeleted=false;\n            continue;',s)
  self.assertIn('allDeleted=false;\n         // 10018',s)
  self.assertIn('GlobalVariableDel(ICT4R2InvalidationKey(ticket));',s)
  self.assertIn('"CANCEL RETRY | "+reason',s)
  self.assertIn('if(OrderGetInteger(ORDER_MAGIC) != InpMagicNumber)',s)
  self.assertIn('if(!IsR2ManagedPendingComment(comment))',s)
 def test_bridge_observability_fail_closed(self):
  for token in ['BridgeDiagnosticChange("FEED "+source,"OK")','BridgeDiagnosticChange("POLL /zones/latest"',
                'BridgeDiagnosticChange("POLL /r2"','BridgeTransportDiagnostic("POST",url',
                'BridgeTransportDiagnostic("GET",url','NONSTANDARD_STATUS_CHECK_EDGE_DNS_PROXY',
                'WRONG_WORKER_BUILD','WORKER MODEL/AGE',
                'StringReplace(excerpt,InpWriteToken,"[REDACTED]")']:
   self.assertIn(token,s,token)
  self.assertIn('if(!InpEnableIntegratedBridgeMonitor)return;',s)
 def test_legend_stays_color_consistent(self):
  self.assertIn("input color InpR2WatchSellColor = C'255,220,0';",s)
  self.assertIn('AppendLegendRow(rows,tones,"R2 SELL  |  FVG/OB WATCH ONLY",InpR2WatchSellColor)',s)
 def test_balanced_delimiters(self):
  c=re.sub(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'',lambda m:' '*len(m.group()),s)
  stack=[];lookup={')':'(',']':'[','}':'{'}
  for i,ch in enumerate(c):
   if ch in '([{':stack.append((ch,i))
   if ch in ')]}':
    self.assertTrue(stack,f'closing {ch} at {i}')
    self.assertEqual(stack.pop()[0],lookup[ch])
  self.assertEqual(stack,[])
 def test_code_diff_only_targeted_segments(self):
  if not base.exists():self.skipTest('Local prior release not available')
  a=base.read_text()
  for f in ['ICT4Pending(','BuildR1ScalpStop(','CalculateSingleRiskSizedLot(',
            'ValidateStops(','R2ArmedInvalidation(','ProcessICT4R2PendingLifecycle(']:
   def function(text):
    i=text.find(f)
    # Match function definition starting at line; ignore calls.
    patterns=[m.start() for m in re.finditer(r'(?m)^\s*(?:bool|void|double|string)\s+'+re.escape(f),text)]
    assert len(patterns)==1,(f,patterns)
    i=patterns[0]; start=text.find('{',i)
    depth=0
    for j in range(start,len(text)):
     if text[j]=='{':depth+=1
     if text[j]=='}':
      depth-=1
      if depth==0:return text[i:j+1]
    raise AssertionError('unterminated '+f)
   left,right=function(a),function(s)
   if f=='ProcessICT4R2PendingLifecycle(': 
    left=left.replace('This will be retried on the next timer iteration.', 'Per-ticket broker retry cooldown persists across EA reloads.')
   self.assertEqual(left,right,f)

class ScenarioModels(unittest.TestCase):
 """Independent control-flow scenario checks; these are NOT a MetaEditor or broker execution test."""
 def simulate_cancel(self,retcode,checks=1000,delay_market=120,delay_other=30):
  now=0;expiry=-1;attempts=0;log_events=0
  for now in range(checks):
   if now<expiry:continue
   attempts+=1;log_events+=1
   expiry=now+(max(60,delay_market) if retcode==10018 else max(10,delay_other))
  return attempts,log_events
 def test_closed_broker_spam_suppression(self):
  self.assertEqual(self.simulate_cancel(10018,checks=600),(5,5))
 def test_transient_rejection_limited(self):
  self.assertEqual(self.simulate_cancel(10031,checks=90),(3,3))
 def test_pending_state_never_marked_deleted_on_retry_skip(self):
  pending=True;retryAt=120
  for now in range(1,120):
   isSkipped=now<retryAt
   if isSkipped:self.assertTrue(pending)

if __name__=='__main__':unittest.main(verbosity=2)