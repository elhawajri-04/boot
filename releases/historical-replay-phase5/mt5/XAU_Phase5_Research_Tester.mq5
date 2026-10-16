//+------------------------------------------------------------------+
//| XAU Phase 5 Research Tester - NOT FOR LIVE/DEMO CHARTS            |
//| Historical ARM/CANCEL input, never directly calls Cloud Worker   |
//| Run ONLY inside MT5 Strategy Tester, on XAUUSD.s Every tick real |
//+------------------------------------------------------------------+
#property strict
#property version "5.00"
#property description "Research-only tester, NEVER attaches to a live chart. News policy fail-closed by default."
#property tester_file "phase5_jan_commands.csv"
#property tester_file "phase5_feb_commands.csv"
#property tester_file "phase5_news_clear.csv"
#include <Trade/Trade.mqh>
CTrade trade;

enum ENUM_P5_PERIOD { P5_JAN_2026=0, P5_FEB_2026=1 };
enum ENUM_P5_R1_CONFIRM { P5_M1_REJECTION=0, P5_LEGACY_M5_DIRECTION=1 };
input ENUM_P5_PERIOD InpResearchPeriod = P5_JAN_2026; // Explicit input; NO renaming commands between weeks
input string InpExpectedSymbol = "XAUUSD.s";
input bool InpResearchAllowUnverifiedNews = false; // FALSE blocks all orders without historical news-clear intervals
input double InpRiskPercentPerTrade = 1.0;         // <=10%; 1.0 default
input double InpMaxAggregateRiskPct = 5.0;         // include open positions and pending orders
input double InpLotCap = 0.10;
input int InpMaximumSpreadPoints = 200;
input int InpCommandMaximumDelaySeconds = 30;
input int InpWindowStartHourServer = 0;
input int InpWindowEndHourServer = 24;
input int InpMinSecondsAfterArm = 1;
input int InpCancelRetrySeconds = 120;
input int InpNewsLeadBufferSeconds = 300;
input double InpR1M5AtrBuffer = 0.12;
input double InpR2M15AtrBuffer = 0.12;
input ENUM_P5_R1_CONFIRM InpR1ConfirmationMode = P5_M1_REJECTION;
input int InpR1MaxConfirmSeconds = 180;
input int InpR1EntryMaxDistancePoints = 150; // distance from nearest retest edge on M1 confirmation
input int InpMaxActiveCandidatesPerEngine = 3; // fixed hard cap = 3
input double InpRewardRisk = 1.60;
input ulong InpMagic = 260104;

struct Command {
 datetime at;
 string action,id,engine,side,type,reason;
 double zoneLo,zoneHi,retestLo,retestHi,limitPrice,invalid;
 datetime expiry;
};
struct Active {
 bool on,filled,cancelRequested;
 string id,engine,side;
 datetime armed,expiry,lastCancelTry,touchTime;
 bool touched;
 double low,high,entry,invalid;
 ulong ticket;
};
struct NewsInterval {datetime from,to;string decision,source;};
Command cmds[];
Active r1[3],r2[3];
NewsInterval news[];
int nextCommand=0, atr5=INVALID_HANDLE, atr15=INVALID_HANDLE;
bool newsReady=false, testerReady=false;
int accepted=0,rejected=0,retired=0;

void Trace(string engine,string eventId,string action,string reason) {
 PrintFormat("P5|%s|%s|%s|%s|server=%s",engine,eventId,action,reason,TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS));
}
void ResetActive(Active &a) {
 a.on=false; a.filled=false;a.cancelRequested=false;a.ticket=0;a.lastCancelTry=0;
 a.touched=false;a.touchTime=0;
 a.id="";a.engine="";a.side="";a.armed=0;a.expiry=0;
 a.low=0;a.high=0;a.entry=0;a.invalid=0;
}
string Clean(string s){StringTrimLeft(s);StringTrimRight(s);return s;}
bool ParseCommands(){
 string file=InpResearchPeriod==P5_JAN_2026?"phase5_jan_commands.csv":"phase5_feb_commands.csv";
 int h=FileOpen(file,FILE_READ|FILE_TXT|FILE_ANSI);
 if(h==INVALID_HANDLE){Print("P5 FATAL: missing ",file,". Copy into MQL5/Files.");return false;}
 string header=Clean(FileReadString(h));
 if(header!="time_server,action,event_id,engine,side,order_type,zone_low,zone_high,retest_low,retest_high,limit_price,distal_invalidation,expiry_server,reason"){
  Print("P5 FATAL: command header mismatch");FileClose(h);return false;
 }
 datetime prev=0; string prevAction="";
 while(!FileIsEnding(h)){
  string line=Clean(FileReadString(h));if(line=="")continue;
  string p[];if(StringSplit(line,',',p)!=14){Print("P5 FATAL malformed command row: ",line);FileClose(h);return false;}
  Command c;
  c.at=(datetime)StringToInteger(p[0]);c.action=p[1];c.id=p[2];c.engine=p[3];c.side=p[4];c.type=p[5];c.reason=p[13];
  c.zoneLo=StringToDouble(p[6]);c.zoneHi=StringToDouble(p[7]);c.retestLo=StringToDouble(p[8]);c.retestHi=StringToDouble(p[9]);
  c.limitPrice=StringToDouble(p[10]);c.invalid=StringToDouble(p[11]);c.expiry=(datetime)StringToInteger(p[12]);
  if(c.at<=0||c.id==""||(c.engine!="R1"&&c.engine!="R2")||(c.side!="BUY"&&c.side!="SELL")||
     (c.action!="ARM"&&c.action!="CANCEL")||c.at<prev ||(c.at==prev&&prevAction=="ARM"&&c.action=="CANCEL")){
   Print("P5 FATAL: unordered/invalid command ",line);FileClose(h);return false;
  }
  if(c.action=="ARM"){
   if(c.expiry<=c.at||c.retestLo>=c.retestHi||c.retestLo<=0||c.zoneLo>c.retestLo||
      c.zoneHi<c.retestHi||c.limitPrice<=0||c.invalid<=0||
      (c.engine=="R2" && !((c.side=="BUY"&&c.type=="BUY_LIMIT")||(c.side=="SELL"&&c.type=="SELL_LIMIT")))||
      (c.engine=="R1"&&c.type!="RETEST_MARKET")){
     Print("P5 FATAL bad ARM: ",line);FileClose(h);return false;
   }
  }
  int n=ArraySize(cmds);ArrayResize(cmds,n+1);cmds[n]=c;
  prev=c.at;prevAction=c.action;
 }
 FileClose(h);
 if(ArraySize(cmds)<1){Print("P5 FATAL: no commands");return false;}
 for(int i=0;i<ArraySize(cmds);i++){
  if(cmds[i].action!="ARM")continue;
  for(int j=i+1;j<ArraySize(cmds);j++)if(cmds[j].action=="ARM"&&cmds[j].id==cmds[i].id){
   Print("P5 FATAL: duplicate ARM id ",cmds[i].id);return false;
  }
 }
 return true;
}
bool LoadNews(){
 int h=FileOpen("phase5_news_clear.csv",FILE_READ|FILE_TXT|FILE_ANSI);
 if(h==INVALID_HANDLE){Print("P5 NEWS: no historical news clearance file; blocked unless explicit research override");return false;}
 if(Clean(FileReadString(h))!="from_server,to_server,decision,source"){
  FileClose(h);Print("P5 NEWS: invalid interval header");return false;
 }
 while(!FileIsEnding(h)){
  string line=Clean(FileReadString(h));if(line=="")continue;
  string p[];if(StringSplit(line,',',p)!=4){FileClose(h);return false;}
  NewsInterval z;z.from=(datetime)StringToInteger(p[0]);z.to=(datetime)StringToInteger(p[1]);z.decision=Clean(p[2]);z.source=Clean(p[3]);
  if(z.from<=0||z.to<=z.from||z.decision!="CLEAR"||z.source=="" || StringFind(z.source,"TEMPLATE")>=0){FileClose(h);return false;}
  int n=ArraySize(news);if(n>0 && news[n-1].to>z.from){FileClose(h);return false;}
  ArrayResize(news,n+1);news[n]=z;
 }
 FileClose(h);
 return ArraySize(news)>0;
}
bool NewsAllowed(datetime now){
 if(InpResearchAllowUnverifiedNews)return true; // explicit UNVERIFIED diagnostic, not validated performance
 if(!newsReady)return false;
 for(int i=0;i<ArraySize(news);i++)
  if(news[i].from<=now && now+InpNewsLeadBufferSeconds<news[i].to)return true;
 return false;
}
datetime NewsClearDeadline(datetime now){
 if(InpResearchAllowUnverifiedNews)return now+86400;
 for(int i=0;i<ArraySize(news);i++)
  if(news[i].from<=now && now<news[i].to)return news[i].to-InpNewsLeadBufferSeconds;
 return now;
}
bool BrokerSessionNow(datetime now){
 MqlDateTime dt;TimeToStruct(now,dt);if(dt.day_of_week==0||dt.day_of_week==6)return false;
 int sec=dt.hour*3600+dt.min*60+dt.sec;
 bool allowed=(InpWindowStartHourServer==InpWindowEndHourServer)?false:
   ((InpWindowStartHourServer<InpWindowEndHourServer)?
     (dt.hour>=InpWindowStartHourServer&&dt.hour<InpWindowEndHourServer):
     (dt.hour>=InpWindowStartHourServer||dt.hour<InpWindowEndHourServer));
 if(!allowed)return false;
 datetime s,e;
 for(uint i=0;i<20;i++){
  if(!SymbolInfoSessionTrade(_Symbol,(ENUM_DAY_OF_WEEK)dt.day_of_week,i,s,e))break;
  long a=((long)s)%86400, b=((long)e)%86400;
  if(a<0)a+=86400;if(b<0)b+=86400;
  if(a==b)return true; // 24-hour market session
  if((a<b && sec>=a && sec<b)||(a>b && (sec>=a||sec<b)))return true;
 }
 return false; // fail closed when broker's trade sessions are not available
}
long MinimumStopsPoints(){
 long stop=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
 long freeze=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL);
 return (long)MathMax(stop,freeze)+2;
}
double TickSize(){double s=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);return s>0?s:_Point;}
double AlignPrice(double x,int rounding){double t=TickSize();return NormalizeDouble(rounding<0?MathFloor(x/t)*t:rounding>0?MathCeil(x/t)*t:MathRound(x/t)*t,_Digits);}
bool TradableNow(datetime now,MqlTick &q){
 if(!newsReady&&!InpResearchAllowUnverifiedNews)return false;
 if(!NewsAllowed(now)||!BrokerSessionNow(now))return false;
 if(!SymbolInfoTick(_Symbol,q)||q.ask<=0||q.bid<=0||q.ask<q.bid)return false;
 if(now-(datetime)q.time>10||q.time>now)return false;
 if((q.ask-q.bid)/_Point > InpMaximumSpreadPoints)return false;
 if(!MQLInfoInteger(MQL_TRADE_ALLOWED)||!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))return false;
 long mode=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_MODE);
 return mode==SYMBOL_TRADE_MODE_FULL;
}
// Newest swing confirmed strictly from M5 CLOSED bars; never use current forming bar.
bool NearestM5Swing(string side,double &pivot){
 MqlRates r[];ArraySetAsSeries(r,true);
 int n=CopyRates(_Symbol,PERIOD_M5,1,100,r);if(n<20)return false;
 for(int i=2;i<n-2;i++){
  bool good=true;
  for(int j=i-2;j<=i+2;j++){
   if(j==i)continue;
   if(side=="BUY" && (r[j].low<r[i].low || (r[j].low==r[i].low && j>i)))good=false;
   if(side=="SELL" && (r[j].high>r[i].high || (r[j].high==r[i].high && j>i)))good=false;
  }
  if(good){pivot=(side=="BUY"?r[i].low:r[i].high);return true;}
 }
 return false;
}
double ATRClosed(int handle){double a[];ArraySetAsSeries(a,true);if(CopyBuffer(handle,0,1,1,a)!=1)return 0;return a[0];}
bool R1ClosedBarConfirms(string side){
 MqlRates r[];ArraySetAsSeries(r,true);
 if(CopyRates(_Symbol,PERIOD_M5,1,1,r)!=1)return false;
 return side=="BUY"?r[0].close>r[0].open:r[0].close<r[0].open;
}
// Absolute worst-case stop exposure based on current server-calculated SL loss (excluding unknown gap slippage).
double ExistingRiskMoney(){
 double total=0,pnl=0;
 for(int i=PositionsTotal()-1;i>=0;i--){
  ulong tk=PositionGetTicket(i);if(tk==0||PositionGetString(POSITION_SYMBOL)!=_Symbol)continue;
  double sl=PositionGetDouble(POSITION_SL),open=PositionGetDouble(POSITION_PRICE_OPEN),vol=PositionGetDouble(POSITION_VOLUME);
  if(sl<=0)return DBL_MAX; // unknown protection: no new exposure
  ENUM_ORDER_TYPE dir=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
  if(!OrderCalcProfit(dir,_Symbol,vol,open,sl,pnl))return DBL_MAX;
  total+=MathMax(0,-pnl);
 }
 for(int i=OrdersTotal()-1;i>=0;i--){
  ulong tk=OrderGetTicket(i);if(tk==0||OrderGetString(ORDER_SYMBOL)!=_Symbol)continue;
  double sl=OrderGetDouble(ORDER_SL),open=OrderGetDouble(ORDER_PRICE_OPEN),vol=OrderGetDouble(ORDER_VOLUME_CURRENT);
  if(sl<=0)return DBL_MAX;
  ENUM_ORDER_TYPE t=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
  ENUM_ORDER_TYPE dir=(t==ORDER_TYPE_BUY || t==ORDER_TYPE_BUY_LIMIT||t==ORDER_TYPE_BUY_STOP||t==ORDER_TYPE_BUY_STOP_LIMIT)?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
  if(!OrderCalcProfit(dir,_Symbol,vol,open,sl,pnl))return DBL_MAX;
  total+=MathMax(0,-pnl);
 }
 return total;
}
bool RiskLot(string side,double entry,double sl,double &lot,string &why){
 double equity=AccountInfoDouble(ACCOUNT_EQUITY),pnl=0;
 if(equity<=0){why="NO_EQUITY";return false;}
 ENUM_ORDER_TYPE t=side=="BUY"?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
 if(!OrderCalcProfit(t,_Symbol,1.0,entry,sl,pnl)||pnl>=0){why="BAD_STOP_DIRECTION_OR_PROFIT_MODEL";return false;}
 double riskPerLot=-pnl,room=equity*InpMaxAggregateRiskPct/100.0-ExistingRiskMoney();
 double maxNew=MathMin(equity*InpRiskPercentPerTrade/100.0,room);
 if(maxNew<=0){why="MAX_ACCOUNT_RISK";return false;}
 double raw=maxNew/riskPerLot,step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
 double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),maxLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
 if(step<=0||minLot<=0){why="BAD_SYMBOL_VOLUME";return false;}
 lot=MathFloor((MathMin(raw,MathMin(InpLotCap,maxLot))+1e-10)/step)*step;
 lot=NormalizeDouble(lot,8);
 if(lot<minLot || lot<=0 || lot*riskPerLot>maxNew+0.001){why="LOT_BELOW_MIN_OR_RISK";return false;}
 double margin=0;
 if(!OrderCalcMargin(t,_Symbol,lot,entry,margin)||margin>AccountInfoDouble(ACCOUNT_MARGIN_FREE)){
  why="INSUFFICIENT_MARGIN";return false;
 }
 return true;
}
bool StopsOK(string side,double entry,double sl,double tp,bool pending,const MqlTick &q,string &why){
 double dist=MinimumStopsPoints()*_Point;
 if(side=="BUY"){
  if(!(sl<entry&&tp>entry)){why="DIRECTION_STOP";return false;}
  if(pending && entry>q.ask-dist){why="BUY_LIMIT_NOT_BELOW_ASK";return false;}
  if(entry-sl<dist || tp-entry<dist){why="BROKER_STOP_LEVEL";return false;}
  if(!pending && q.bid-sl<dist){why="BUY_MARKET_SL_TOO_CLOSE_BID";return false;}
 }else{
  if(!(sl>entry&&tp<entry)){why="DIRECTION_STOP";return false;}
  if(pending && entry<q.bid+dist){why="SELL_LIMIT_NOT_ABOVE_BID";return false;}
  if(sl-entry<dist || entry-tp<dist){why="BROKER_STOP_LEVEL";return false;}
  if(!pending && sl-q.ask<dist){why="SELL_MARKET_SL_TOO_CLOSE_ASK";return false;}
 }
 return true;
}
// When an R2 pending order is no longer valid, acknowledge broker cancellation before forgetting it.
bool CancelPending(Active &a,string cause,datetime now){
 if(a.ticket==0){a.on=false;retired++;Trace(a.engine,a.id,"CANCEL",cause+"|no_open_pending");return true;}
 if(!OrderSelect(a.ticket)){
  a.ticket=0;a.on=false;retired++;Trace(a.engine,a.id,"CANCEL_OR_FILLED",cause+"|broker_order_missing");return true;
 }
 if(a.lastCancelTry>0 && now-a.lastCancelTry<InpCancelRetrySeconds)return false;
 if(!BrokerSessionNow(now)){Trace(a.engine,a.id,"CANCEL_DEFER",cause+"|market_closed");a.lastCancelTry=now;return false;}
 a.lastCancelTry=now;
 bool ok=trade.OrderDelete(a.ticket);
 if(ok && trade.ResultRetcode()==TRADE_RETCODE_DONE){Trace(a.engine,a.id,"CANCEL_OK",cause);a.ticket=0;a.on=false;retired++;return true;}
 Trace(a.engine,a.id,"CANCEL_RETRY",cause+"|"+IntegerToString(trade.ResultRetcode()));return false;
}
void CancelState(Active &a,string cause,datetime now){
 if(!a.on)return;
 a.cancelRequested=true;
 if(a.ticket!=0)CancelPending(a,cause,now);
 else {Trace(a.engine,a.id,"STATE_CANCEL",cause);a.on=false;retired++;}
}
int FindFreeSlot(string engine){
 for(int i=0;i<InpMaxActiveCandidatesPerEngine;i++){
  if(engine=="R1"?!r1[i].on:!r2[i].on)return i;
 }
 return -1;
}
void ProcessArm(Command &c,datetime now){
 Active a;ResetActive(a);
 a.on=true;a.id=c.id;a.engine=c.engine;a.side=c.side;a.armed=c.at;a.expiry=c.expiry;
 a.low=c.retestLo;a.high=c.retestHi;a.entry=c.limitPrice;a.invalid=c.invalid;
 if(now>=c.expiry || now-c.at>InpCommandMaximumDelaySeconds){Trace(c.engine,c.id,"REJECT","LATE_ARM");rejected++;return;}
 int slot=FindFreeSlot(c.engine);
 if(slot<0){Trace(c.engine,c.id,"REJECT","MAX_SIMULTANEOUS_CANDIDATES");rejected++;return;}
 MqlTick q;
 if(!TradableNow(now,q)){Trace(c.engine,c.id,"REJECT","SESSION_NEWS_QUOTE_OR_SPREAD");rejected++;return;}
 if(c.engine=="R1"){
  r1[slot]=a;
  Trace("R1",a.id,"ARM","WAIT_FUTURE_RETEST|slot="+IntegerToString(slot));return;
 }
 // R2 remains strictly pending LIMIT; never market BUY/SELL.
 double atr=ATRClosed(atr15);
 if(atr<=0){Trace("R2",c.id,"REJECT","NO_CLOSED_M15_ATR");rejected++;return;}
 double buffer=MathMax(_Point*5,atr*InpR2M15AtrBuffer);
 double entry=AlignPrice(c.limitPrice,0);
 double sl=AlignPrice(c.side=="BUY"?c.invalid-buffer:c.invalid+buffer,c.side=="BUY"?-1:1);
 double tp=AlignPrice(c.side=="BUY"?entry+InpRewardRisk*(entry-sl):entry-InpRewardRisk*(sl-entry),c.side=="BUY"?1:-1);
 string why="";double lot=0;
 if(!StopsOK(c.side,entry,sl,tp,true,q,why)||!RiskLot(c.side,entry,sl,lot,why)){
  Trace("R2",c.id,"REJECT",why);rejected++;return;
 }
 datetime expire=(datetime)MathMin((long)c.expiry,(long)NewsClearDeadline(now));
 if(expire<=now+60){Trace("R2",c.id,"REJECT","NO_VALID_PENDING_NEWS_DEADLINE");rejected++;return;}
 string note="P5_R2_"+StringSubstr(c.id,StringLen(c.id)-MathMin(StringLen(c.id),16));
 bool ok=c.side=="BUY"?trade.BuyLimit(lot,entry,_Symbol,sl,tp,ORDER_TIME_SPECIFIED,expire,note):
                            trade.SellLimit(lot,entry,_Symbol,sl,tp,ORDER_TIME_SPECIFIED,expire,note);
 uint rc=trade.ResultRetcode();
 if(!ok||(rc!=TRADE_RETCODE_PLACED&&rc!=TRADE_RETCODE_DONE)||trade.ResultOrder()==0){
  Trace("R2",c.id,"BROKER_REJECT",IntegerToString(rc)+"|"+trade.ResultRetcodeDescription());rejected++;return;
 }
 a.ticket=trade.ResultOrder();r2[slot]=a;accepted++;
 Trace("R2",a.id,"PENDING_ACCEPTED","ticket="+(string)a.ticket+"|lot="+DoubleToString(lot,2));
}
void RunCommands(datetime now){
 while(nextCommand<ArraySize(cmds)&&cmds[nextCommand].at<=now){
  Command c=cmds[nextCommand++];
  if(c.action=="ARM"){
   // If ARM and its cancellation are both already in the elapsed tick gap, NEVER send the stale order.
   bool alreadyCanceled=false;
   for(int j=nextCommand;j<ArraySize(cmds)&&cmds[j].at<=now;j++){
    if(cmds[j].action=="CANCEL"&&cmds[j].id==c.id){alreadyCanceled=true;break;}
   }
   if(alreadyCanceled){Trace(c.engine,c.id,"SKIP","CANCEL_ALREADY_DUE");continue;}
   ProcessArm(c,now);
  }else{
   bool found=false;
   for(int i=0;i<InpMaxActiveCandidatesPerEngine;i++){
    if(c.engine=="R1"){
     if(r1[i].on&&r1[i].id==c.id){CancelState(r1[i],c.reason,now);found=true;break;}
    }else{
     if(r2[i].on&&r2[i].id==c.id){CancelState(r2[i],c.reason,now);found=true;break;}
    }
   }
   if(!found)Trace(c.engine,c.id,"CANCEL_IGNORED","UNKNOWN_OR_ALREADY_INACTIVE");
  }
 }
}
void ManageR1(Active &a,datetime now,const MqlTick &q){
 if(!a.on)return;
 if(now>=a.expiry){CancelState(a,"EXPIRED",now);return;}
 if(!BrokerSessionNow(now)||!NewsAllowed(now)){CancelState(a,"SESSION_OR_NEWS",now);return;}
 MqlRates bar[];ArraySetAsSeries(bar,true);
 if(CopyRates(_Symbol,PERIOD_M5,1,1,bar)!=1)return;
 if((a.side=="BUY"&&bar[0].close<a.invalid)||(a.side=="SELL"&&bar[0].close>a.invalid)){
  CancelState(a,"STRUCTURAL_INVALIDATION",now);return;
 }
 if(now-a.armed < InpMinSecondsAfterArm)return; // cannot enter on event creation tick
 double price=a.side=="BUY"?q.ask:q.bid;
 if(price>=a.low && price<=a.high && !a.touched){
  a.touched=true;a.touchTime=now;
  Trace("R1",a.id,"TOUCHED","WAIT_CLOSED_M1_REJECTION");
 }
 if(!a.touched)return;
 if(InpR1ConfirmationMode==P5_M1_REJECTION){
  if(now-a.touchTime>InpR1MaxConfirmSeconds){a.touched=false;a.touchTime=0;return;}
  MqlRates m1[];ArraySetAsSeries(m1,true);
  if(CopyRates(_Symbol,PERIOD_M1,1,1,m1)!=1)return;
  datetime closeTime=m1[0].time+60;
  if(closeTime<=a.touchTime)return; // M1 must CLOSE strictly after touch; no future candle
  double mid=(m1[0].low+m1[0].high)*0.5;
  bool confirms=a.side=="BUY"?(m1[0].close>m1[0].open&&m1[0].close>=mid):
                              (m1[0].close<m1[0].open&&m1[0].close<=mid);
  if(!confirms)return;
 }else{
  if(price<a.low||price>a.high||!R1ClosedBarConfirms(a.side))return;
 }
 MqlTick live;
 if(!TradableNow(now,live))return;
 double entry=a.side=="BUY"?live.ask:live.bid;
 double maxGap=InpR1EntryMaxDistancePoints*_Point;
 if(InpR1ConfirmationMode==P5_M1_REJECTION){
  if(a.side=="BUY"&&(entry<a.low||entry>a.high+maxGap))return;
  if(a.side=="SELL"&&(entry>a.high||entry<a.low-maxGap))return;
 }else if(entry<a.low||entry>a.high)return;
 double local=0,atr=ATRClosed(atr5);
 if(!NearestM5Swing(a.side,local)||atr<=0){Trace("R1",a.id,"REJECT","NO_LOCAL_M5_SWING_OR_ATR");rejected++;CancelState(a,"SWING_NOT_AVAILABLE",now);return;}
 double buf=MathMax(_Point*5,atr*InpR1M5AtrBuffer);
 double sl=AlignPrice(a.side=="BUY"?local-buf:local+buf,a.side=="BUY"?-1:1);
 double tp=AlignPrice(a.side=="BUY"?entry+InpRewardRisk*(entry-sl):entry-InpRewardRisk*(sl-entry),a.side=="BUY"?1:-1);
 string why="";double lot=0;
 if(!StopsOK(a.side,entry,sl,tp,false,live,why)||!RiskLot(a.side,entry,sl,lot,why)){
  Trace("R1",a.id,"REJECT",why);rejected++;CancelState(a,"EXECUTION_REJECTED",now);return;
 }
 string note="P5_R1_"+StringSubstr(a.id,StringLen(a.id)-MathMin(StringLen(a.id),16));
 bool ok=a.side=="BUY"?trade.Buy(lot,_Symbol,0.0,sl,tp,note):trade.Sell(lot,_Symbol,0.0,sl,tp,note);
 uint rc=trade.ResultRetcode();
 if(!ok||(rc!=TRADE_RETCODE_DONE&&rc!=TRADE_RETCODE_DONE_PARTIAL)){
  Trace("R1",a.id,"BROKER_REJECT",IntegerToString(rc)+"|"+trade.ResultRetcodeDescription());rejected++;CancelState(a,"BROKER_REJECTED",now);return;
 }
 accepted++;Trace("R1",a.id,"MARKET_ACCEPTED","lot="+DoubleToString(lot,2));
 a.on=false;retired++;
}
void ManageR2(Active &a,datetime now){
 if(!a.on)return;
 if(now>=a.expiry ||!NewsAllowed(now)||!BrokerSessionNow(now))a.cancelRequested=true;
 MqlRates b[];ArraySetAsSeries(b,true);
 if(CopyRates(_Symbol,PERIOD_M15,1,1,b)==1 && ((a.side=="BUY"&&b[0].close<a.invalid)||(a.side=="SELL"&&b[0].close>a.invalid)))a.cancelRequested=true;
 if(a.cancelRequested)CancelPending(a,"EXPIRED_NEWS_SESSION_OR_INVALIDATED",now);
 else if(a.ticket!=0&&!OrderSelect(a.ticket)){
  Trace("R2",a.id,"ORDER_NO_LONGER_PENDING","possible_fill_or_cancel_see_deal_history");a.on=false;
 }
}
int OnInit(){
 if(!MQLInfoInteger(MQL_TESTER)){Print("P5 FATAL: This EA is disabled on any real/demo chart. MT5 Strategy Tester ONLY.");return INIT_FAILED;}
 if(_Symbol!=InpExpectedSymbol||_Period!=PERIOD_M5){Print("P5 FATAL: expected symbol / M5 mismatch");return INIT_FAILED;}
 if(InpRiskPercentPerTrade<=0||InpRiskPercentPerTrade>10.0||InpMaxAggregateRiskPct<=0||InpMaxAggregateRiskPct>10.0||
  InpMaximumSpreadPoints<=0||InpLotCap<=0||InpRewardRisk<=0||InpCommandMaximumDelaySeconds<0||
  InpWindowStartHourServer<0||InpWindowStartHourServer>23||InpWindowEndHourServer<1||InpWindowEndHourServer>24||
  InpMinSecondsAfterArm<1||InpCancelRetrySeconds<30||InpNewsLeadBufferSeconds<0||InpR1M5AtrBuffer<0||InpR2M15AtrBuffer<0||
  InpMaxActiveCandidatesPerEngine<1||InpMaxActiveCandidatesPerEngine>3||
  InpR1MaxConfirmSeconds<60||InpR1MaxConfirmSeconds>600||
  InpR1EntryMaxDistancePoints<0||InpR1EntryMaxDistancePoints>500){return INIT_PARAMETERS_INCORRECT;}
 for(int i=0;i<3;i++){ResetActive(r1[i]);ResetActive(r2[i]);}
 if(!ParseCommands())return INIT_FAILED;
 // Prevent cross-week tests even when user forgets to change dropdown.
 datetime expectedStart=StringToTime(InpResearchPeriod==P5_JAN_2026?"2026.01.06 00:00":"2026.02.02 00:00");
 datetime expectedEnd=expectedStart+7*86400;
 if(TimeCurrent()<expectedStart || TimeCurrent()>=expectedEnd){
  Print("P5 FATAL: selected period does not match Strategy Tester dates. Review InpResearchPeriod.");return INIT_FAILED;
 }
 for(int i=0;i<ArraySize(cmds);i++)if(cmds[i].at<expectedStart||cmds[i].at>=expectedEnd){
  Print("P5 FATAL: command timestamp belongs to wrong week");return INIT_FAILED;
 }
 newsReady=LoadNews();
 if(!newsReady&&!InpResearchAllowUnverifiedNews){Print("P5 FATAL no verified historical news-clear intervals. Fail closed.");return INIT_FAILED;}
 if(InpResearchAllowUnverifiedNews)Print("P5 WARNING: UNVERIFIED HISTORICAL NEWS OVERRIDE: research only, NOT valid profitability evidence.");
 atr5=iATR(_Symbol,PERIOD_M5,14);atr15=iATR(_Symbol,PERIOD_M15,14);
 if(atr5==INVALID_HANDLE||atr15==INVALID_HANDLE)return INIT_FAILED;
 trade.SetExpertMagicNumber(InpMagic);trade.SetDeviationInPoints(15);trade.SetTypeFillingBySymbol(_Symbol);
 testerReady=true;
 PrintFormat("P5 START | tester_only=1 | commands=%d | news=%s | R2=PENDING_LIMIT_ONLY | R1=M1_AFTER_TOUCH_M5_SWING_ATR | period=%d",ArraySize(cmds),InpResearchAllowUnverifiedNews?"UNVERIFIED_DIAGNOSTIC":"CLEAR_INTERVAL_REQUIRED",(int)InpResearchPeriod);
 return INIT_SUCCEEDED;
}
void OnTick(){
 if(!testerReady)return;
 datetime now=TimeCurrent();
 RunCommands(now); // apply causal cancellations before any attempt to trade this tick
 MqlTick q;
 if(!SymbolInfoTick(_Symbol,q)||q.ask<q.bid||q.ask<=0)return;
 for(int i=0;i<InpMaxActiveCandidatesPerEngine;i++)ManageR2(r2[i],now);
 for(int i=0;i<InpMaxActiveCandidatesPerEngine;i++)ManageR1(r1[i],now,q);
}
void OnDeinit(const int reason){
 if(atr5!=INVALID_HANDLE)IndicatorRelease(atr5);
 if(atr15!=INVALID_HANDLE)IndicatorRelease(atr15);
 PrintFormat("P5 SUMMARY|orders_accepted=%d|rejected=%d|states_retired=%d|history_required=TRUE|news=%s|MT5_HISTORY_TAB_REQUIRED",accepted,rejected,retired,InpResearchAllowUnverifiedNews?"UNVERIFIED":"INTERVALS_LOADED");
}