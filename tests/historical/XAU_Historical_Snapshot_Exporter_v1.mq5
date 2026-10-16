// XAU historical snapshot exporter, isolated Strategy Tester utility.
// NOT THE LIVE EA: no orders, no WebRequest, no Worker mutation.
#property strict
input int InpCaptureEverySeconds=60; // use 10 for detailed parity; very large output
input int InpMaxRows=3000;           // bound exported size per tester run
input int InpBrokerUtcOffsetMinutes=120; // broker UTC offset for TEST DATE, not Palestine time
input bool InpUseLondonSession=true;
input string InpOutputFile="XAU_HISTORICAL_SNAPSHOTS_v1.jsonl";
int fileHandle=INVALID_HANDLE;
datetime lastSave=0;
int rows=0;

datetime LastSunday01UTC(int y,int month)
{
 MqlDateTime x;ZeroMemory(x);x.year=y;x.mon=month;x.day=31;
 MqlDateTime t;TimeToStruct(StructToTime(x),t);
 x.day=31-t.day_of_week;x.hour=1;
 return StructToTime(x);
}
bool UKSummer(datetime utc)
{
 MqlDateTime t;TimeToStruct(utc,t);
 return utc>=LastSunday01UTC(t.year,3) && utc<LastSunday01UTC(t.year,10);
}
bool WindowBounds(datetime brokerTime,int &start,int &stop)
{
 start=0;stop=86400;
 if(!InpUseLondonSession)return true;
 int shift=InpBrokerUtcOffsetMinutes*60;
 if(MathAbs(shift)>50400)return false;
 datetime utc=brokerTime-(datetime)shift;
 MqlDateTime t;TimeToStruct(utc,t);
 t.hour=0;t.min=0;t.sec=0;
 datetime utcMidnight=StructToTime(t);
 MqlDateTime current;TimeToStruct(brokerTime,current);
 for(int i=-1;i<=1;i++)
 {
    datetime day=utcMidnight+(datetime)(i*86400);
    int londonUtcOpen=UKSummer(day+8*3600)?7:8;
    datetime brokerOpen=day+(datetime)(londonUtcOpen*3600+shift);
    MqlDateTime op;TimeToStruct(brokerOpen,op);
    if(op.year==current.year && op.mon==current.mon && op.day==current.day)
    {
      start=op.hour*3600+op.min*60+op.sec;
      return start<stop;
    }
 }
 return false;
}
string RatesJson(ENUM_TIMEFRAMES tf,int count)
{
 MqlRates r[];ArraySetAsSeries(r,true);
 int copied=CopyRates(_Symbol,tf,0,count,r);
 if(copied<60)return "[]";
 string out="[";
 for(int i=copied-1;i>=0;i--)
 {
   out+="{\"t\":"+IntegerToString((long)r[i].time);
   out+=",\"o\":"+DoubleToString(r[i].open,_Digits);
   out+=",\"h\":"+DoubleToString(r[i].high,_Digits);
   out+=",\"l\":"+DoubleToString(r[i].low,_Digits);
   out+=",\"c\":"+DoubleToString(r[i].close,_Digits);
   out+=",\"v\":"+IntegerToString((long)r[i].tick_volume)+"}";
   if(i>0)out+=",";
 }
 return out+"]";
}
int OnInit()
{
 if(!MQLInfoInteger(MQL_TESTER))
 {
   Print("HISTORICAL EXPORTER: Strategy Tester only, refusing live chart.");
   return INIT_FAILED;
 }
 if(StringFind(_Symbol,"XAUUSD")<0)return INIT_FAILED;
 if(InpCaptureEverySeconds<1 || InpMaxRows<1)return INIT_PARAMETERS_INCORRECT;
 fileHandle=FileOpen(InpOutputFile,FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
 if(fileHandle==INVALID_HANDLE)
 {
   Print("Cannot open export file: ",InpOutputFile," code=",GetLastError());
   return INIT_FAILED;
 }
 Print("HISTORICAL EXPORT START | ",InpOutputFile," | offset_minutes=",
       InpBrokerUtcOffsetMinutes," | sample_sec=",InpCaptureEverySeconds);
 return INIT_SUCCEEDED;
}
void OnTick()
{
 if(rows>=InpMaxRows)return;
 datetime now=TimeCurrent();
 if(now<=0 || (lastSave>0 && now-lastSave<InpCaptureEverySeconds))return;
 MqlTick tick;if(!SymbolInfoTick(_Symbol,tick))return;
 int start=0,stop=0;
 bool valid=WindowBounds(now,start,stop);
 MqlDateTime d;TimeToStruct(now,d);
 int sec=d.hour*3600+d.min*60+d.sec;
 string a=RatesJson(PERIOD_M1,200);
 string b=RatesJson(PERIOD_M5,200);
 string c=RatesJson(PERIOD_M15,150);
 string e=RatesJson(PERIOD_M30,120);
 string f=RatesJson(PERIOD_H1,120);
 if(a=="[]" || b=="[]" || c=="[]" || e=="[]" || f=="[]")return;
 string out="{";
 out+="\"symbol\":\""+_Symbol+"\",";
 out+="\"generated_at\":"+IntegerToString((long)now)+",";
 out+="\"broker_server_day_of_week\":"+IntegerToString(d.day_of_week)+",";
 out+="\"broker_server_seconds_of_day\":"+IntegerToString(sec)+",";
 out+="\"broker_session_policy\":\"LONDON_0800_TO_SERVER_2359_V1\",";
 out+="\"broker_session_enabled\":"+(InpUseLondonSession?"true":"false")+",";
 out+="\"broker_session_window_valid\":"+(valid?"true":"false")+",";
 out+="\"broker_session_open_seconds\":"+IntegerToString(start)+",";
 out+="\"broker_session_close_seconds\":"+IntegerToString(stop)+",";
 out+="\"broker_server_utc_offset_minutes\":"+IntegerToString(InpBrokerUtcOffsetMinutes)+",";
 out+="\"bid\":"+DoubleToString(tick.bid,_Digits)+",";
 out+="\"ask\":"+DoubleToString(tick.ask,_Digits)+",";
 out+="\"spread_points\":"+DoubleToString((tick.ask-tick.bid)/_Point,1)+",";
 out+="\"point\":"+DoubleToString(_Point,_Digits)+",";
 out+="\"digits\":"+IntegerToString(_Digits)+",";
 // CalendarValueHistory is unavailable in MT5 Tester. DO NOT fabricate an approval.
 out+="\"news_policy\":{\"schema\":1,\"source\":\"HISTORICAL_CALENDAR_NOT_REPLAYED\",";
 out+="\"enabled\":true,\"risk\":\"UNKNOWN\",\"decision\":\"UNKNOWN\",";
 out+="\"entry_allowed\":false,\"calendar_healthy\":false,";
 out+="\"checked_at_server\":"+IntegerToString((long)now)+",";
 out+="\"calendar_checked_at_server\":0},";
 out+="\"M1\":"+a+",\"M5\":"+b+",\"M15\":"+c+",\"M30\":"+e+",\"H1\":"+f+"}";
 FileWriteString(fileHandle,out+"\r\n");
 rows++;lastSave=now;
 if(rows%100==0){FileFlush(fileHandle);Print("EXPORT PROGRESS ",rows);}
}
void OnDeinit(const int why)
{
 if(fileHandle!=INVALID_HANDLE){FileFlush(fileHandle);FileClose(fileHandle);}
 Print("HISTORICAL EXPORT COMPLETE | rows=",rows,
       " | file=",InpOutputFile," | DOES NOT EXECUTE TRADES");
}
