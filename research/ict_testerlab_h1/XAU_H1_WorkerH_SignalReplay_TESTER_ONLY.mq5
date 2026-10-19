// XAU H1 / Worker H signal replay sandbox, NOT the production EA H1.
// Strictly MT5 STRATEGY TESTER ONLY. No HTTP, no Cloudflare, no impact on live EA.
// Replays time-safe Worker H signals precomputed offline by replay_worker_ticks.mjs.
// Broker execution is REAL Strategy Tester processing, but H1 full position manager,
// news calendar and Worker snapshot freshness are NOT reproduced by this sandbox.
#property strict
#property version "1.00"
#property description "Offline generated Worker H signal-to-broker replay; testing only."
#include <Trade/Trade.mqh>
CTrade g_trade;
input string InpSignalsCommonPath="XAU_H1_LAB\\signals.tsv";
input double InpRiskPerStrategyPercent=5.0;
input double InpCombinedRiskLimitPercent=10.0;
input double InpMaxLot=1.0;
input int InpMaxSignalDelaySeconds=60;
input int InpSignalTimeOffsetSeconds=0;
input long InpReplayMagicNumber=2601019;
input int InpDeviationPoints=50;

struct RSignal {
 datetime at;
 datetime expires;
 string engine,key,side,orderType;
 double entry,sl,tp1,tp2;
};
RSignal g_signals[];
int g_cursor=0;
ulong g_pendingTicket=0;
datetime g_pendingExpires=0;
int g_submitted=0,g_rejected=0,g_missed=0;

bool LoadSignals() {
 int f=FileOpen(InpSignalsCommonPath,FILE_READ|FILE_CSV|FILE_ANSI|FILE_COMMON,'\t',CP_UTF8);
 if(f==INVALID_HANDLE){Print("REPLAY ERROR: cannot read ",InpSignalsCommonPath," error=",GetLastError());return false;}
 for(int i=0;i<10&&!FileIsEnding(f);i++)FileReadString(f); // header
 while(!FileIsEnding(f)){
  string fields[10];bool complete=true;
  for(int i=0;i<10;i++){
   if(FileIsEnding(f)){complete=false;break;}
   fields[i]=FileReadString(f);
  }
  if(!complete)break;
  if(fields[0]==""||fields[0]=="signalled_at")continue;
  RSignal r;
  r.at=(datetime)(StringToInteger(fields[0])+InpSignalTimeOffsetSeconds);
  r.engine=fields[1];r.key=fields[2];r.side=fields[3];r.orderType=fields[4];
  r.entry=StringToDouble(fields[5]);r.sl=StringToDouble(fields[6]);
  r.tp1=StringToDouble(fields[7]);r.tp2=StringToDouble(fields[8]);
  r.expires=(datetime)(StringToInteger(fields[9])+InpSignalTimeOffsetSeconds);
  if(r.at<=0||r.expires<r.at||r.sl<=0||r.entry<=0||r.tp1<=0||r.tp2<=0||
     (r.side!="BUY"&&r.side!="SELL")||(r.engine!="R1"&&r.engine!="R2")){
    Print("REPLAY INVALID SIGNAL ROW; refusing to start");FileClose(f);return false;
  }
  int n=ArraySize(g_signals);ArrayResize(g_signals,n+1);g_signals[n]=r;
  if(n>0 && g_signals[n].at<g_signals[n-1].at){
    Print("REPLAY ERROR: unsorted signal timestamps");FileClose(f);return false;
  }
 }
 FileClose(f);
 Print("REPLAY loaded ",ArraySize(g_signals)," unique Worker H signals, times are broker-server timestamps");
 return true;
}
int OnInit(){
 if(!MQLInfoInteger(MQL_TESTER)){
  Print("TESTER-ONLY SAFETY: expert refuses to run outside Strategy Tester");return INIT_FAILED;
 }
 if(InpRiskPerStrategyPercent<=0||InpRiskPerStrategyPercent>5||
   InpCombinedRiskLimitPercent<=0||InpCombinedRiskLimitPercent>10||
   InpMaxLot<=0||InpMaxSignalDelaySeconds<0){
  Print("REPLAY safety inputs invalid");return INIT_PARAMETERS_INCORRECT;
 }
 if(StringFind(_Symbol,"XAUUSD")!=0){Print("Expected XAUUSD symbol");return INIT_FAILED;}
 g_trade.SetExpertMagicNumber(InpReplayMagicNumber);
 g_trade.SetDeviationInPoints(InpDeviationPoints);
 g_trade.SetTypeFillingBySymbol(_Symbol);
 if(!LoadSignals())return INIT_FAILED;
 return INIT_SUCCEEDED;
}

bool BrokerRiskMoney(ENUM_ORDER_TYPE side,double entry,double sl,double volume,double &loss){
 double pnl=0.0;loss=0.0;
 if(!OrderCalcProfit(side,_Symbol,volume,entry,sl,pnl))return false;
 loss=MathMax(0.0,-pnl);
 return true;
}
bool ExistingRisk(double &risk){
 risk=0.0;
 for(int i=PositionsTotal()-1;i>=0;i--){
  ulong ticket=PositionGetTicket(i);if(ticket==0||!PositionSelectByTicket(ticket))continue;
  if(PositionGetString(POSITION_SYMBOL)!=_Symbol)continue;
  double stop=PositionGetDouble(POSITION_SL),p=PositionGetDouble(POSITION_PRICE_OPEN);
  if(stop<=0||p<=0)return false;
  long type=PositionGetInteger(POSITION_TYPE);
  double loss=0.0;
  if(!BrokerRiskMoney(type==POSITION_TYPE_BUY?ORDER_TYPE_BUY:ORDER_TYPE_SELL,p,stop,
                      PositionGetDouble(POSITION_VOLUME),loss))return false;
  risk+=loss;
 }
 for(int i=OrdersTotal()-1;i>=0;i--){
  ulong ticket=OrderGetTicket(i);if(ticket==0||!OrderSelect(ticket))continue;
  if(OrderGetString(ORDER_SYMBOL)!=_Symbol)continue;
  double stop=OrderGetDouble(ORDER_SL),p=OrderGetDouble(ORDER_PRICE_OPEN);
  if(stop<=0||p<=0)return false;
  ENUM_ORDER_TYPE type=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
  ENUM_ORDER_TYPE direction=(type==ORDER_TYPE_BUY_LIMIT||type==ORDER_TYPE_BUY_STOP||type==ORDER_TYPE_BUY_STOP_LIMIT)?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
  double loss=0.0;
  if(!BrokerRiskMoney(direction,p,stop,OrderGetDouble(ORDER_VOLUME_CURRENT),loss))return false;
  risk+=loss;
 }
 return true;
}

bool AnyPendingForStrategy(string engine){
 for(int i=OrdersTotal()-1;i>=0;i--){
  ulong id=OrderGetTicket(i);if(id==0||!OrderSelect(id))continue;
  if(OrderGetString(ORDER_SYMBOL)==_Symbol &&
     StringFind(OrderGetString(ORDER_COMMENT),"LAB_"+engine)==0)return true;
 }
 return false;
}

void Attempt(RSignal &r,const MqlTick &tick){
 if(r.engine=="R2" && AnyPendingForStrategy("R2")){g_missed++;return;}
 // Broker limit/stop order sides must be consistent with the current live quote.
 bool isBuy=r.side=="BUY";
 double intended=(r.orderType=="BUY"||r.orderType=="SELL")?(isBuy?tick.ask:tick.bid):r.entry;
 if((isBuy&&r.sl>=intended)||(!isBuy&&r.sl<=intended)){g_rejected++;return;}
 // No new position may break configured account-risk ceiling.
 double existing=0.0;if(!ExistingRisk(existing)){g_rejected++;return;}
 const double balance=AccountInfoDouble(ACCOUNT_BALANCE);
 double available=MathMin(balance*InpRiskPerStrategyPercent/100.0,
                           balance*InpCombinedRiskLimitPercent/100.0-existing);
 if(available<=0){g_rejected++;return;}
 double oneLotLoss=0.0;
 if(!BrokerRiskMoney(isBuy?ORDER_TYPE_BUY:ORDER_TYPE_SELL,intended,r.sl,1.0,oneLotLoss)||oneLotLoss<=0){g_rejected++;return;}
 double minVol=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
 double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
 double maxVol=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
 if(step<=0||minVol<=0){g_rejected++;return;}
 double lot=MathFloor(available/oneLotLoss/step)*step;
 lot=NormalizeDouble(MathMin(lot,MathMin(maxVol,InpMaxLot)),8);
 if(lot+1e-8<minVol){g_rejected++;return;}
 double tp=r.engine=="R2"?r.tp2:r.tp1;
 if((isBuy&&tp<=intended)||(!isBuy&&tp>=intended)){g_rejected++;return;}
 string comment="LAB_"+r.engine;
 bool request=false;
 if(r.orderType=="BUY")request=g_trade.Buy(lot,_Symbol,0,r.sl,tp,comment);
 else if(r.orderType=="SELL")request=g_trade.Sell(lot,_Symbol,0,r.sl,tp,comment);
 else if(r.orderType=="BUY_LIMIT"&&r.entry<tick.ask)
  request=g_trade.BuyLimit(lot,r.entry,_Symbol,r.sl,tp,ORDER_TIME_GTC,0,comment);
 else if(r.orderType=="SELL_LIMIT"&&r.entry>tick.bid)
  request=g_trade.SellLimit(lot,r.entry,_Symbol,r.sl,tp,ORDER_TIME_GTC,0,comment);
 else if(r.orderType=="BUY_STOP"&&r.entry>tick.ask)
  request=g_trade.BuyStop(lot,r.entry,_Symbol,r.sl,tp,ORDER_TIME_GTC,0,comment);
 else if(r.orderType=="SELL_STOP"&&r.entry<tick.bid)
  request=g_trade.SellStop(lot,r.entry,_Symbol,r.sl,tp,ORDER_TIME_GTC,0,comment);
 uint code=g_trade.ResultRetcode();
 if(!request||!(code==TRADE_RETCODE_DONE||code==TRADE_RETCODE_PLACED||code==TRADE_RETCODE_DONE_PARTIAL)){
  Print("REPLAY broker reject ",r.engine," ",r.orderType," retcode=",code," ",g_trade.ResultRetcodeDescription());g_rejected++;return;
 }
 g_submitted++;
 if(r.orderType!="BUY"&&r.orderType!="SELL"){
  g_pendingTicket=g_trade.ResultOrder();g_pendingExpires=r.expires;
 }
 Print("REPLAY order ",r.engine," ",r.orderType," volume=",lot," entry=",intended," SL=",r.sl," TP=",tp," code=",code);
}

void OnTick(){
 MqlTick tick;if(!SymbolInfoTick(_Symbol,tick))return;
 datetime t=tick.time;
 if(g_pendingTicket>0){
  if(!OrderSelect(g_pendingTicket)){g_pendingTicket=0;g_pendingExpires=0;}
  else if(t>=g_pendingExpires){
   if(g_trade.OrderDelete(g_pendingTicket)&&g_trade.ResultRetcode()==TRADE_RETCODE_DONE){
    Print("REPLAY expired pending order ",g_pendingTicket);
    g_pendingTicket=0;g_pendingExpires=0;
   }
  }
 }
 while(g_cursor<ArraySize(g_signals)&&g_signals[g_cursor].at<=t){
  RSignal r=g_signals[g_cursor++];
  if(t-r.at>InpMaxSignalDelaySeconds||t>r.expires){g_missed++;continue;}
  Attempt(r,tick);
 }
}
void OnDeinit(const int reason){
 Print("REPLAY SUMMARY | accepted_orders=",g_submitted," rejected=",g_rejected,
  " missed_or_overlap=",g_missed," | compare Strategy Tester Results/Deals");
}
