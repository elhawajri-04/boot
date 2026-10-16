// XAU historical exporter, offline only, no EA trade calls, no Worker requests.
// Save as MQL5/Scripts/XAU_Historical_Exporter.mq5, compile, run on XAUUSD.s.
#property strict
#property script_show_inputs
#property version "1.00"

input string InpStartServer = "2025.01.06 00:00"; // inclusive, broker server clock
input string InpEndServer   = "2025.01.13 00:00"; // exclusive, broker server clock
input int    InpWarmupDays  = 30; // rates only, warm up H1/M30 structures
input string InpPrefix     = "xau_20250106"; // use different prefix per week/month
input bool   InpExportTicks = true; // full bid/ask tick stream for quote accuracy
input int    InpTickChunkSeconds = 60; // bounded CopyTicksRange allocation

string BarName(const string tf)
{
   return InpPrefix+"_"+tf+".csv";
}
int CsvWriter(const string filename)
{
   int handle = FileOpen(filename,FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON,',',CP_UTF8);
   if(handle == INVALID_HANDLE)
      PrintFormat("EXPORT FAILED | cannot open %s | error %d",filename,GetLastError());
   return handle;
}

bool ExportBars(const ENUM_TIMEFRAMES tf,const string suffix,
                const datetime fromTime,const datetime toExclusive)
{
   int f=CsvWriter(BarName(suffix));
   if(f==INVALID_HANDLE)return false;
   FileWrite(f,"t","o","h","l","c","tick_volume","spread_points","real_volume");
   long count=0;
   int emptyDays=0,errors=0;
   for(datetime from=fromTime; from<toExclusive; from+=86400)
   {
      datetime until=from+86400;
      if(until>toExclusive)until=toExclusive;
      MqlRates bars[];
      ResetLastError();
      int copied=CopyRates(_Symbol,tf,from,until-1,bars);
      if(copied<0)
      {
         errors++;
         PrintFormat("BARS WARNING | %s | %s | err=%d",suffix,TimeToString(from),GetLastError());
         continue;
      }
      if(copied==0){emptyDays++;continue;}
      // CopyRates places oldest bar at the start of physical array.
      for(int i=0;i<copied;i++)
      {
         if(bars[i].time<fromTime || bars[i].time>=toExclusive)continue;
         FileWrite(f,(long)bars[i].time,
                   DoubleToString(bars[i].open,_Digits),
                   DoubleToString(bars[i].high,_Digits),
                   DoubleToString(bars[i].low,_Digits),
                   DoubleToString(bars[i].close,_Digits),
                   (long)bars[i].tick_volume,(int)bars[i].spread,(long)bars[i].real_volume);
         count++;
      }
   }
   FileClose(f);
   PrintFormat("BARS | %s | count=%I64d emptyDays=%d readErrors=%d",suffix,count,emptyDays,errors);
   // Empty trading days are normal (weekends/holidays); read errors are not.
   return (count>=60 && errors==0);
}

bool ExportTicks(const datetime fromTime,const datetime toExclusive)
{
   int f=CsvWriter(InpPrefix+"_ticks.csv");
   if(f==INVALID_HANDLE)return false;
   FileWrite(f,"time_msc","bid","ask","flags");
   long written=0;
   int errors=0,empty=0;
   const int seconds=MathMax(5,MathMin(900,InpTickChunkSeconds));
   // Intervals are half-open and non-overlapping to avoid duplicate boundary ticks.
   for(datetime from=fromTime;from<toExclusive;from+=(datetime)seconds)
   {
      datetime to=from+seconds;
      if(to>toExclusive)to=toExclusive;
      ulong first=(ulong)from*1000;
      ulong last=(ulong)to*1000-1;
      MqlTick ticks[];
      ResetLastError();
      int count=CopyTicksRange(_Symbol,ticks,COPY_TICKS_ALL,first,last);
      if(count<0)
      {
         errors++;
         PrintFormat("TICK ERROR | %s .. %s | err=%d",TimeToString(from),TimeToString(to),GetLastError());
         if(errors>=10)break;
         continue;
      }
      if(count==0){empty++;continue;}
      for(int i=0;i<count;i++)
      {
         if(ticks[i].time_msc<(long)first||ticks[i].time_msc>(long)last)continue;
         FileWrite(f,(long)ticks[i].time_msc,
                   DoubleToString(ticks[i].bid,_Digits),
                   DoubleToString(ticks[i].ask,_Digits),
                   (uint)ticks[i].flags);
         written++;
      }
   }
   FileClose(f);
   PrintFormat("TICKS | written=%I64d emptyChunks=%d errors=%d",written,empty,errors);
   return (written>0 && errors==0);
}

void WriteMetadata(const datetime start,const datetime stop,bool ok)
{
   int f=CsvWriter(InpPrefix+"_meta.csv");
   if(f==INVALID_HANDLE)return;
   FileWrite(f,"key","value");
   FileWrite(f,"format_version","1");
   FileWrite(f,"symbol",_Symbol);
   FileWrite(f,"digits",IntegerToString(_Digits));
   FileWrite(f,"point",DoubleToString(_Point,8));
   FileWrite(f,"start_server_unix",(long)start);
   FileWrite(f,"end_server_unix_exclusive",(long)stop);
   FileWrite(f,"warmup_days",InpWarmupDays);
   FileWrite(f,"ticks_exported",InpExportTicks?"true":"false");
   FileWrite(f,"export_status",ok?"OK":"INCOMPLETE");
   FileClose(f);
}

void OnStart()
{
   const datetime start=StringToTime(InpStartServer);
   const datetime end=StringToTime(InpEndServer);
   if(start<=0 || end<=start || InpWarmupDays<0 || InpWarmupDays>180 ||
      StringLen(InpPrefix)<3 || StringFind(InpPrefix,"/")>=0 ||
      StringFind(InpPrefix,"\\")>=0)
   {
      Print("INVALID EXPORT INPUTS | set broker-local start/end, warmup 0..180, simple prefix");
      return;
   }
   datetime warm=start-(datetime)(InpWarmupDays*86400);
   bool ok=true;
   ok=ExportBars(PERIOD_M1,"M1",warm,end) && ok;
   ok=ExportBars(PERIOD_M5,"M5",warm,end) && ok;
   ok=ExportBars(PERIOD_M15,"M15",warm,end) && ok;
   ok=ExportBars(PERIOD_M30,"M30",warm,end) && ok;
   ok=ExportBars(PERIOD_H1,"H1",warm,end) && ok;
   if(InpExportTicks)
      ok=ExportTicks(start,end) && ok;
   WriteMetadata(start,end,ok);
   PrintFormat("XAU HISTORICAL EXPORT %s | %s | %s | files in Terminal/Common/Files",
               ok?"COMPLETE":"INCOMPLETE",_Symbol,InpPrefix);
   Print("Only use COMPLETE exports. Verify bars and tick timestamps agree with broker clock.");
}