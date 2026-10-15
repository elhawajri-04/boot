//+------------------------------------------------------------------+
//| XAU_Bridge_ReadOnly_Diagnostics_v1.mq5                          |
//| Standalone MT5 SCRIPT: no orders, no position modifications.     |
//| Compile in MetaEditor > Scripts and run on the same XAUUSD chart.|
//+------------------------------------------------------------------+
#property strict
#property script_show_inputs
#property version "1.00"

input string InpWorkerURL =
   "https://xau-live-bridge.r7ed2015.workers.dev";
// Read-only GET /zones/latest requires the SAME X-Bridge-Key as the EA.
// Keep the actual token private; do not include it in screenshots/logs.
input string InpWorkerWriteToken = "";
input int InpTimeoutMs = 6000;
input int InpMaxMarketAgeSeconds = 30;
input int InpMaxQuoteAgeSeconds = 30;

int g_pass = 0;
int g_warn = 0;
int g_fail = 0;

void RecordCheck(string label, bool ok, string detail="")
{
   if(ok) g_pass++; else g_fail++;
   Print((ok?"PASS | ":"FAIL | ")+label+
         (detail==""?"":" | "+detail));
}

void RecordWarning(string label,string detail="")
{
   g_warn++;
   Print("WARN | "+label+(detail==""?"":" | "+detail));
}

string ProbeURL(string endpoint)
{
   // Timestamp cache buster for each GET; no backdating or caching assumed.
   string separator=StringFind(endpoint,"?")>=0?"&":"?";
   return InpWorkerURL+endpoint+separator+"cb="+
          IntegerToString((long)GetTickCount());
}

int GetReadOnly(string endpoint,string &response,uint &durationMs)
{
   string url=ProbeURL(endpoint);
   string header="Cache-Control: no-cache\r\n";
   if(InpWorkerWriteToken!="")
      header+="X-Bridge-Key: "+InpWorkerWriteToken+"\r\n";
   char data[];
   char bytes[];
   string responseHeaders="";
   ArrayResize(data,0);
   ResetLastError();
   uint started=GetTickCount();
   int status=WebRequest("GET",url,header,InpTimeoutMs,
                         data,bytes,responseHeaders);
   durationMs=(uint)(GetTickCount()-started);
   if(status==-1)
   {
      int error=GetLastError();
      Print("WebRequest failed | endpoint="+endpoint+
            " | MT5 error="+IntegerToString(error)+
            " | Allow domain in Tools > Options > Expert Advisors.");
      response="";
      return -1;
   }
   response=CharArrayToString(bytes,0,-1,CP_UTF8);
   return status;
}

bool HttpGood(int status,string content)
{
   return status>=200 && status<300 &&
          StringFind(content,"\"ok\":true")>=0;
}

// Minimal flat-field number scanner; NEVER prints the full JSON or token.
double GetJSONNumber(string content,string key,double fallback=-1.0)
{
   string needle="\""+key+"\":";
   int p=StringFind(content,needle);
   if(p<0)return fallback;
   p+=StringLen(needle);
   int end=StringLen(content);
   while(p<end)
   {
      ushort c=StringGetCharacter(content,p);
      if(c==' '||c==9||c==10||c==13){p++;continue;}
      break;
   }
   int begin=p;
   while(p<end)
   {
      ushort c=StringGetCharacter(content,p);
      bool numeric=(c>='0'&&c<='9')||c=='-'||c=='+'||
                   c=='.'||c=='e'||c=='E';
      if(!numeric)break;
      p++;
   }
   if(p==begin)return fallback;
   return StringToDouble(StringSubstr(content,begin,p-begin));
}

void OnStart()
{
   Print("=== XAU BRIDGE READ-ONLY DIAGNOSTIC v1 START ===");
   Print("This script DOES NOT open/cancel trades or POST to Worker.");
   Print("Market symbol: "+_Symbol+" | Terminal connected="+
         (TerminalInfoInteger(TERMINAL_CONNECTED)?"YES":"NO"));

   if(_Symbol!="XAUUSD.s")
      RecordWarning("Symbol differs from the Worker-configured XAUUSD.s",
                    "Current="+_Symbol);

   MqlTick tick;
   bool quote=SymbolInfoTick(_Symbol,tick);
   RecordCheck("MT5 quote available",quote);
   datetime brokerNow=TimeTradeServer();
   RecordCheck("MT5 broker server time available",brokerNow>0);
   MqlDateTime dt;
   ZeroMemory(dt);
   if(brokerNow>0)TimeToStruct(brokerNow,dt);
   int localSeconds=dt.hour*3600+dt.min*60+dt.sec;

   if(quote&&brokerNow>0)
   {
      long tickAge=(long)(brokerNow-tick.time);
      Print("LOCAL QUOTE | Bid "+DoubleToString(tick.bid,_Digits)+
            " | Ask "+DoubleToString(tick.ask,_Digits)+
            " | Broker "+TimeToString(brokerNow,TIME_DATE|TIME_SECONDS)+
            " | LatestTickAge "+IntegerToString(tickAge)+" seconds");
      RecordCheck("Broker's actual tick age",
                  tickAge>=-2 && tickAge<=InpMaxQuoteAgeSeconds,
                  IntegerToString(tickAge)+"s");
   }

   uint latency=0;
   string health="";
   int status=GetReadOnly("/health",health,latency);
   RecordCheck("GET /health",HttpGood(status,health),
               "HTTP="+IntegerToString(status)+
               " | RTT="+IntegerToString(latency)+"ms");
   RecordCheck("Deployed broker-server Worker build",
               StringFind(health,"BROKER_SERVER_09_22")>=0);

   string latest="";
   status=GetReadOnly("/latest",latest,latency);
   bool latestOK=HttpGood(status,latest);
   RecordCheck("GET /latest (MT5 -> Worker)",latestOK,
               "HTTP="+IntegerToString(status)+
               " | RTT="+IntegerToString(latency)+"ms");

   if(latestOK)
   {
      double age=GetJSONNumber(latest,"market_age_seconds",999999);
      double cloudMs=GetJSONNumber(latest,"cloud_updated_at",0);
      double serverMs=GetJSONNumber(latest,"server_time",0);
      double serverDay=GetJSONNumber(latest,"broker_server_day_of_week",-1);
      double clockSeconds=GetJSONNumber(
         latest,"broker_server_seconds_of_day",-1);
      double cloudBid=GetJSONNumber(latest,"bid",-1);
      double cloudAsk=GetJSONNumber(latest,"ask",-1);
      Print("WORKER MARKET | age="+DoubleToString(age,1)+
            "s | bid="+DoubleToString(cloudBid,_Digits)+
            " | ask="+DoubleToString(cloudAsk,_Digits));
      RecordCheck("Worker stored market freshness",
                  age>=0 && age<=InpMaxMarketAgeSeconds,
                  DoubleToString(age,1)+"s");
      RecordCheck("Worker receipt timestamps present",
                  cloudMs>0 && serverMs>0 && serverMs>=cloudMs);
      RecordCheck("Broker clock carried in /latest",
                  serverDay>=0 && serverDay<=6 &&
                  clockSeconds>=0 && clockSeconds<86400);
      if(brokerNow>0 && clockSeconds>=0)
      {
         int drift=(int)MathAbs(clockSeconds-localSeconds);
         drift=MathMin(drift,86400-drift);
         RecordCheck("MT5 vs Worker broker clock agreement",
                     drift<=MathMax(60,InpMaxMarketAgeSeconds*2),
                     "delta="+IntegerToString(drift)+"s");
      }
      bool frames=true;
      string names[5]={"M1","M5","M15","M30","H1"};
      for(int i=0;i<5;i++)
         frames=frames && StringFind(latest,"\""+names[i]+"\":[")>=0;
      RecordCheck("All five candle timeframes included",frames);
      if(quote && cloudBid>0 && cloudAsk>0)
      {
         double difference=MathMax(MathAbs(tick.bid-cloudBid),
                                   MathAbs(tick.ask-cloudAsk));
         Print("QUOTE DIFFERENCE | "+
               DoubleToString(difference,2)+
               " USD price units (market may move between reads)");
         if(difference>2.0)
            RecordWarning("Large price gap: verify quote timing/spread",
                          DoubleToString(difference,2));
      }

      // generated_at is MT5 broker-server wall time encoded as timestamp;
      // do NOT compare it directly to Cloudflare UTC as quote freshness.
   }

   string r2="";
   status=GetReadOnly("/r2",r2,latency);
   bool r2OK=HttpGood(status,r2);
   RecordCheck("GET /r2 (Worker -> MT5)",r2OK,
               "HTTP="+IntegerToString(status)+
               " | RTT="+IntegerToString(latency)+"ms");
   if(r2OK)
   {
      RecordCheck("R2 structure received",
                  StringFind(r2,"\"market_state\"")>=0 &&
                  StringFind(r2,"\"selector\"")>=0 &&
                  StringFind(r2,"\"setup\"")>=0);
   }

   if(InpWorkerWriteToken=="")
   {
      RecordWarning("Authenticated /zones/latest NOT checked",
                    "Provide token locally in script Inputs; never share token");
   }
   else
   {
      string zones="";
      status=GetReadOnly("/zones/latest?symbol="+_Symbol,zones,latency);
      bool zonesOK=HttpGood(status,zones);
      RecordCheck("GET /zones/latest (Worker -> MT5 authenticated)",
                  zonesOK,
                  "HTTP="+IntegerToString(status)+
                  " | RTT="+IntegerToString(latency)+"ms");
      if(zonesOK)
      {
         RecordCheck("R1 zones envelope fields",
            StringFind(zones,"\"zones\"")>=0 &&
            StringFind(zones,"\"r2_audit_status\"")>=0);
         if(StringFind(zones,"\"zones\":null")>=0)
            RecordWarning("Zones response is null",
               "Valid when no qualified zone or market is stale");
      }
   }

   string results="";
   status=GetReadOnly("/bot-results?limit=5",results,latency);
   bool resultsOK=HttpGood(status,results);
   RecordCheck("GET /bot-results",resultsOK,
      "HTTP="+IntegerToString(status)+
      " | RTT="+IntegerToString(latency)+"ms");
   if(resultsOK)
      RecordCheck("Real-auto basket feed active",
                  StringFind(results,"\"REAL_AUTO_BASKETS\"")>=0);
   Print("DIAGNOSTICS TOTAL | PASS "+IntegerToString(g_pass)+
         " | WARN "+IntegerToString(g_warn)+
         " | FAIL "+IntegerToString(g_fail));
   Print("IMPORTANT: GET checks do NOT prove that live trades were placed");
   Print("or that MT5 /trade/event OPEN/CLOSE POSTs reached Worker.");
   Print("=== XAU BRIDGE READ-ONLY DIAGNOSTIC END ===");
}
