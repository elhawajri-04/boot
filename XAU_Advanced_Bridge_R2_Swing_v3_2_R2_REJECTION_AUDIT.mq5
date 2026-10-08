// XAU Advanced Bridge R2 Swing v3.1 AUTO PENDING + PRE EXEC AUDIT
// Automatic pending-order selection + pending lifecycle + TP1/TP2 + structural M15 management
// Generic BUY/SELL signals are converted automatically to Market / Limit / Stop from planned entry vs live price.
// Existing explicit pending orders are never flipped to another type; invalid setups are cancelled and must re-analyze.
// R1 analysis rules are not embedded or modified here.

#property strict

#include <Trade/Trade.mqh>

CTrade trade;


// ============================================================
// INPUTS
// ============================================================

input string InpWorkerBaseURL =
   "https://xau-live-bridge.r7ed2015.workers.dev";

input string InpWriteToken = "";

input int InpMarketSendEverySeconds = 10;
input int InpSignalPollEverySeconds = 1;
input int InpTimeoutMs = 5000;


// Candle counts
input int InpM1Count  = 200;
input int InpM5Count  = 200;
input int InpM15Count = 150;
input int InpM30Count = 120;
input int InpH1Count  = 120;


// Trading
input long InpMagicNumber = 2601001;

input int InpMaxDeviationPoints = 50;

input bool InpBlockIfPositionExists = true;
input bool InpEnablePendingOrders = true;
input bool InpEnablePreExecutionAudit = true;


// Hard safety ceiling
input double InpSafetyMaxLot = 1.00;


// Optional market-order drift protection.
// 0.0 disables the old scalp-style $1 drift restriction.
input double InpMaxMarketEntryDriftUSD = 0.00;

// R2 trade management
input double InpTP1ClosePercent = 50.0;
input bool InpEnableR2StructureManagement = true;
input int InpStructureCheckEverySeconds = 15;

// Decision zones synced from Worker /zones/latest
input bool InpDrawDecisionZones = true;
input int InpZonePollEverySeconds = 5;
input bool InpLogR2RejectionAudit = true;
input bool InpAlertOnZoneEntry = false;
input color InpBuyZoneColor = clrLimeGreen;
input color InpSellZoneColor = clrTomato;


// ============================================================
// GLOBALS
// ============================================================

datetime g_lastMarketSend = 0;
datetime g_lastSignalPoll = 0;

string g_lastHandledSignal = "";

datetime g_lastZonePoll = 0;

string g_zoneAnalysisId = "";

string g_lastR2AuditCore = "";
double g_lastR2AuditScore = -999.0;

double g_buyZoneLow = 0.0;
double g_buyZoneHigh = 0.0;
double g_sellZoneLow = 0.0;
double g_sellZoneHigh = 0.0;

bool g_insideBuyZone = false;
bool g_insideSellZone = false;

string ZONE_BUY_OBJECT = "R1_BUY_WAIT_ZONE";
string ZONE_SELL_OBJECT = "R1_SELL_WAIT_ZONE";


// ============================================================
// TRACKED TRADE STATE
// ============================================================

struct TrackedTrade
{
   bool active;

   string signal_id;

   ulong position_id;
   ulong open_deal_id;

   string side;

   double entry;
   double sl;
   double tp1;
   double tp2;

   double initial_lot;
   double lot;
   double initial_risk;

   datetime open_time;

   double mfe_price;
   double mae_price;

   double mfe_usd;
   double mae_usd;

   bool tp1_done;
   bool open_event_sent;
};

struct PendingTrade
{
   bool active;

   string signal_id;
   ulong order_ticket;

   string side;

   double entry;
   double sl;
   double tp1;
   double tp2;
   double lot;

   long expires_at_ms;
};

TrackedTrade g_state;
PendingTrade g_pending;

string g_stateFile = "";

datetime g_lastStructureCheck = 0;


// ============================================================
// INIT
// ============================================================

int OnInit()
{
   if(StringFind(_Symbol, "XAUUSD") < 0)
   {
      Print(
         "This EA is intended for XAUUSD symbols only."
      );

      return INIT_FAILED;
   }

   if(StringLen(InpWriteToken) == 0)
   {
      Print(
         "InpWriteToken is empty."
      );

      return INIT_FAILED;
   }

   if(
      InpDrawDecisionZones &&
      InpZonePollEverySeconds < 1
   )
   {
      Print(
         "InpZonePollEverySeconds must be at least 1."
      );

      return INIT_PARAMETERS_INCORRECT;
   }

   trade.SetExpertMagicNumber(
      InpMagicNumber
   );

   trade.SetDeviationInPoints(
      InpMaxDeviationPoints
   );

   g_stateFile =
      "XAU_Bridge_R2V2_State_" +
      IntegerToString(
         AccountInfoInteger(
            ACCOUNT_LOGIN
         )
      ) +
      "_" +
      _Symbol +
      ".txt";

   ResetTrackedState();
   ResetPendingState();

   LoadTrackedState();

   EventSetTimer(1);

   Print(
      "XAU Advanced Bridge started on ",
      _Symbol
   );

   // Recover position / pending state immediately
   CheckPendingTrade();
   CheckTrackedTrade();

   if(InpDrawDecisionZones)
   {
      PollDecisionZones();
      g_lastZonePoll = TimeCurrent();
   }

   return INIT_SUCCEEDED;
}


// ============================================================
// DEINIT
// ============================================================

void OnDeinit(
   const int reason
)
{
   EventKillTimer();

   if(g_state.active || g_pending.active)
      SaveTrackedState();

   DeleteDecisionZoneObjects();
}


// ============================================================
// TIMER
// ============================================================

void OnTimer()
{
   datetime now =
      TimeCurrent();

   // --------------------------------------------------------
   // MARKET DATA
   // --------------------------------------------------------

   if(
      g_lastMarketSend == 0 ||
      now - g_lastMarketSend >=
      InpMarketSendEverySeconds
   )
   {
      SendMarketSnapshot();

      g_lastMarketSend =
         now;
   }

   // --------------------------------------------------------
   // SIGNAL POLLING
   // --------------------------------------------------------

   if(
      g_lastSignalPoll == 0 ||
      now - g_lastSignalPoll >=
      InpSignalPollEverySeconds
   )
   {
      PollSignal();

      g_lastSignalPoll =
         now;
   }

   // --------------------------------------------------------
   // DECISION ZONES
   // --------------------------------------------------------

   if(
      InpDrawDecisionZones &&
      (
         g_lastZonePoll == 0 ||
         now - g_lastZonePoll >=
         InpZonePollEverySeconds
      )
   )
   {
      PollDecisionZones();

      g_lastZonePoll =
         now;
   }

   CheckZoneEntryAlert();

   // --------------------------------------------------------
   // TRACK PENDING + OPEN/CLOSED POSITION
   // --------------------------------------------------------

   CheckPendingTrade();
   CheckTrackedTrade();

   if(
      InpEnableR2StructureManagement &&
      g_state.active &&
      (
         g_lastStructureCheck == 0 ||
         now - g_lastStructureCheck >=
         InpStructureCheckEverySeconds
      )
   )
   {
      ManageR2Trade();

      g_lastStructureCheck =
         now;
   }
}


// ============================================================
// TICK
// ============================================================

void OnTick()
{
   CheckZoneEntryAlert();

   if(g_state.active)
      UpdateMfeMae();
}


// ============================================================
// DECISION ZONES FROM WORKER
// ============================================================

bool ValidZone(
   double low,
   double high
)
{
   return(
      low > 0.0 &&
      high > low
   );
}


void DeleteDecisionZoneObjects()
{
   ObjectDelete(
      0,
      ZONE_BUY_OBJECT
   );

   ObjectDelete(
      0,
      ZONE_SELL_OBJECT
   );

   ChartRedraw(0);
}


void DeleteDecisionZoneObject(
   string name
)
{
   ObjectDelete(
      0,
      name
   );
}


void DrawDecisionZoneBand(
   string name,
   double low,
   double high,
   color zoneColor,
   string tooltip
)
{
   if(!ValidZone(low, high))
   {
      DeleteDecisionZoneObject(
         name
      );

      return;
   }

   datetime leftTime =
      TimeCurrent() -
      2 * 86400;

   datetime rightTime =
      TimeCurrent() +
      7 * 86400;

   if(
      ObjectFind(
         0,
         name
      ) < 0
   )
   {
      ResetLastError();

      if(
         !ObjectCreate(
            0,
            name,
            OBJ_RECTANGLE,
            0,
            leftTime,
            high,
            rightTime,
            low
         )
      )
      {
         Print(
            "Could not create zone object ",
            name,
            ". Error=",
            GetLastError()
         );

         return;
      }
   }
   else
   {
      ObjectMove(
         0,
         name,
         0,
         leftTime,
         high
      );

      ObjectMove(
         0,
         name,
         1,
         rightTime,
         low
      );
   }

   ObjectSetInteger(
      0,
      name,
      OBJPROP_COLOR,
      zoneColor
   );

   ObjectSetInteger(
      0,
      name,
      OBJPROP_FILL,
      true
   );

   ObjectSetInteger(
      0,
      name,
      OBJPROP_BACK,
      true
   );

   ObjectSetInteger(
      0,
      name,
      OBJPROP_SELECTABLE,
      false
   );

   ObjectSetInteger(
      0,
      name,
      OBJPROP_SELECTED,
      false
   );

   ObjectSetInteger(
      0,
      name,
      OBJPROP_HIDDEN,
      false
   );

   ObjectSetString(
      0,
      name,
      OBJPROP_TOOLTIP,
      tooltip
   );
}


void RefreshDecisionZoneObjects()
{
   if(!InpDrawDecisionZones)
   {
      DeleteDecisionZoneObjects();
      return;
   }

   DrawDecisionZoneBand(
      ZONE_BUY_OBJECT,
      g_buyZoneLow,
      g_buyZoneHigh,
      InpBuyZoneColor,
      "R1 BUY WAIT ZONE " +
      DoubleToString(
         g_buyZoneLow,
         _Digits
      ) +
      " - " +
      DoubleToString(
         g_buyZoneHigh,
         _Digits
      )
   );

   DrawDecisionZoneBand(
      ZONE_SELL_OBJECT,
      g_sellZoneLow,
      g_sellZoneHigh,
      InpSellZoneColor,
      "R1 SELL WAIT ZONE " +
      DoubleToString(
         g_sellZoneLow,
         _Digits
      ) +
      " - " +
      DoubleToString(
         g_sellZoneHigh,
         _Digits
      )
   );

   ChartRedraw(0);
}


void ClearDecisionZoneState()
{
   g_zoneAnalysisId = "";

   g_buyZoneLow = 0.0;
   g_buyZoneHigh = 0.0;
   g_sellZoneLow = 0.0;
   g_sellZoneHigh = 0.0;

   g_insideBuyZone = false;
   g_insideSellZone = false;

   DeleteDecisionZoneObjects();
}



void LogR2AuditFromResponse(
   string response
)
{
   if(!InpLogR2RejectionAudit)
      return;

   string auditStatus =
      JsonGetString(
         response,
         "r2_audit_status"
      );

   if(auditStatus == "")
      return;

   string marketState =
      JsonGetString(
         response,
         "r2_market_state"
      );

   string strategy =
      JsonGetString(
         response,
         "r2_strategy"
      );

   string orderType =
      JsonGetString(
         response,
         "r2_order_type"
      );

   string reason =
      JsonGetString(
         response,
         "r2_reason"
      );

   double score =
      JsonGetDouble(
         response,
         "r2_score"
      );

   double allowedValue =
      JsonGetDouble(
         response,
         "r2_allowed"
      );

   double rrTp1 =
      JsonGetDouble(
         response,
         "r2_rr_tp1"
      );

   bool allowed =
      allowedValue >= 0.5;

   string core =
      auditStatus + "|" +
      marketState + "|" +
      strategy + "|" +
      orderType + "|" +
      (allowed ? "1" : "0") + "|" +
      reason;

   bool meaningfulScoreChange =
      g_lastR2AuditScore < -900.0 ||
      MathAbs(
         score -
         g_lastR2AuditScore
      ) >= 10.0;

   bool changed =
      core !=
      g_lastR2AuditCore ||
      meaningfulScoreChange;

   if(!changed)
      return;

   Print(
      "R2 STATE | status=",
      auditStatus,
      " | market=",
      marketState,
      " | strategy=",
      strategy,
      " | order=",
      orderType,
      " | score=",
      DoubleToString(
         score,
         0
      ),
      " | allowed=",
      allowed
      ? "true"
      : "false",
      " | rr1=",
      DoubleToString(
         rrTp1,
         2
      ),
      " | reason=",
      reason
   );

   g_lastR2AuditCore =
      core;

   g_lastR2AuditScore =
      score;
}


void PollDecisionZones()
{
   if(!InpDrawDecisionZones)
      return;

   string url =
      InpWorkerBaseURL +
      "/zones/latest?symbol=" +
      _Symbol +
      "&cb=" +
      IntegerToString(
         GetTickCount()
      );

   string response = "";

   int status =
      HttpGet(
         url,
         response
      );

   if(
      status < 200 ||
      status >= 300
   )
   {
      Print(
         "Zone poll failed. HTTP=",
         status,
         " response=",
         response
      );

      return;
   }

   LogR2AuditFromResponse(
      response
   );

   if(
      StringFind(
         response,
         "\"zones\":null"
      ) >= 0
   )
   {
      if(
         g_zoneAnalysisId != "" ||
         ValidZone(
            g_buyZoneLow,
            g_buyZoneHigh
         ) ||
         ValidZone(
            g_sellZoneLow,
            g_sellZoneHigh
         )
      )
      {
         Print(
            "No saved R1 decision zones. Clearing chart zones."
         );
      }

      ClearDecisionZoneState();
      return;
   }

   string analysisId =
      JsonGetString(
         response,
         "analysis_id"
      );

   double buyLow =
      JsonGetDouble(
         response,
         "buy_low"
      );

   double buyHigh =
      JsonGetDouble(
         response,
         "buy_high"
      );

   double sellLow =
      JsonGetDouble(
         response,
         "sell_low"
      );

   double sellHigh =
      JsonGetDouble(
         response,
         "sell_high"
      );

   bool changed =
      analysisId !=
      g_zoneAnalysisId ||
      MathAbs(
         buyLow -
         g_buyZoneLow
      ) > _Point / 2.0 ||
      MathAbs(
         buyHigh -
         g_buyZoneHigh
      ) > _Point / 2.0 ||
      MathAbs(
         sellLow -
         g_sellZoneLow
      ) > _Point / 2.0 ||
      MathAbs(
         sellHigh -
         g_sellZoneHigh
      ) > _Point / 2.0;

   if(!changed)
      return;

   g_zoneAnalysisId =
      analysisId;

   g_buyZoneLow =
      buyLow;

   g_buyZoneHigh =
      buyHigh;

   g_sellZoneLow =
      sellLow;

   g_sellZoneHigh =
      sellHigh;

   g_insideBuyZone = false;
   g_insideSellZone = false;

   RefreshDecisionZoneObjects();

   Print(
      "R1 zones updated from Worker. Analysis=",
      g_zoneAnalysisId,
      " BUY=",
      DoubleToString(
         g_buyZoneLow,
         _Digits
      ),
      "-",
      DoubleToString(
         g_buyZoneHigh,
         _Digits
      ),
      " SELL=",
      DoubleToString(
         g_sellZoneLow,
         _Digits
      ),
      "-",
      DoubleToString(
         g_sellZoneHigh,
         _Digits
      )
   );
}


void CheckZoneEntryAlert()
{
   if(
      !InpDrawDecisionZones ||
      !InpAlertOnZoneEntry
   )
   {
      return;
   }

   MqlTick tick;

   if(
      !SymbolInfoTick(
         _Symbol,
         tick
      )
   )
   {
      return;
   }

   double marketPrice =
      (
         tick.bid +
         tick.ask
      ) /
      2.0;

   bool insideBuy =
      ValidZone(
         g_buyZoneLow,
         g_buyZoneHigh
      ) &&
      marketPrice >=
      g_buyZoneLow &&
      marketPrice <=
      g_buyZoneHigh;

   bool insideSell =
      ValidZone(
         g_sellZoneLow,
         g_sellZoneHigh
      ) &&
      marketPrice >=
      g_sellZoneLow &&
      marketPrice <=
      g_sellZoneHigh;

   if(
      insideBuy &&
      !g_insideBuyZone
   )
   {
      string msg =
         "XAU entered R1 BUY waiting zone: " +
         DoubleToString(
            g_buyZoneLow,
            _Digits
         ) +
         " - " +
         DoubleToString(
            g_buyZoneHigh,
            _Digits
         );

      Alert(msg);
      Print(msg);
   }

   if(
      insideSell &&
      !g_insideSellZone
   )
   {
      string msg =
         "XAU entered R1 SELL waiting zone: " +
         DoubleToString(
            g_sellZoneLow,
            _Digits
         ) +
         " - " +
         DoubleToString(
            g_sellZoneHigh,
            _Digits
         );

      Alert(msg);
      Print(msg);
   }

   g_insideBuyZone =
      insideBuy;

   g_insideSellZone =
      insideSell;
}


// ============================================================
// MARKET SNAPSHOT
// ============================================================

void SendMarketSnapshot()
{
   MqlTick tick;

   if(
      !SymbolInfoTick(
         _Symbol,
         tick
      )
   )
   {
      return;
   }

   string payload = "{";

   payload +=
      "\"symbol\":\"" +
      JsonEscape(_Symbol) +
      "\",";

   payload +=
      "\"generated_at\":" +
      IntegerToString(
         TimeTradeServer()
      ) +
      ",";

   payload +=
      "\"bid\":" +
      DoubleToString(
         tick.bid,
         _Digits
      ) +
      ",";

   payload +=
      "\"ask\":" +
      DoubleToString(
         tick.ask,
         _Digits
      ) +
      ",";

   double spreadPoints =
      (
         tick.ask -
         tick.bid
      ) /
      _Point;

   payload +=
      "\"spread_points\":" +
      DoubleToString(
         spreadPoints,
         0
      ) +
      ",";

   payload +=
      "\"point\":" +
      DoubleToString(
         _Point,
         _Digits
      ) +
      ",";

   payload +=
      "\"digits\":" +
      IntegerToString(
         _Digits
      ) +
      ",";

   payload +=
      "\"M1\":" +
      BuildRatesJson(
         PERIOD_M1,
         InpM1Count
      ) +
      ",";

   payload +=
      "\"M5\":" +
      BuildRatesJson(
         PERIOD_M5,
         InpM5Count
      ) +
      ",";

   payload +=
      "\"M15\":" +
      BuildRatesJson(
         PERIOD_M15,
         InpM15Count
      ) +
      ",";

   payload +=
      "\"M30\":" +
      BuildRatesJson(
         PERIOD_M30,
         InpM30Count
      ) +
      ",";

   payload +=
      "\"H1\":" +
      BuildRatesJson(
         PERIOD_H1,
         InpH1Count
      );

   payload += "}";

   string response = "";

   int status =
      HttpPostJson(
         InpWorkerBaseURL +
         "/update",
         payload,
         response
      );

   if(
      status < 200 ||
      status >= 300
   )
   {
      Print(
         "Market update failed. HTTP=",
         status,
         " response=",
         response
      );
   }
}


// ============================================================
// BUILD CANDLE JSON
// ============================================================

string BuildRatesJson(
   ENUM_TIMEFRAMES timeframe,
   int requestedCount
)
{
   MqlRates rates[];

   ArraySetAsSeries(
      rates,
      true
   );

   int copied =
      CopyRates(
         _Symbol,
         timeframe,
         0,
         requestedCount,
         rates
      );

   if(copied <= 0)
      return "[]";

   string result = "[";

   // Send oldest -> newest
   for(
      int i =
         copied - 1;
      i >= 0;
      i--
   )
   {
      result += "{";

      result +=
         "\"t\":" +
         IntegerToString(
            rates[i].time
         ) +
         ",";

      result +=
         "\"o\":" +
         DoubleToString(
            rates[i].open,
            _Digits
         ) +
         ",";

      result +=
         "\"h\":" +
         DoubleToString(
            rates[i].high,
            _Digits
         ) +
         ",";

      result +=
         "\"l\":" +
         DoubleToString(
            rates[i].low,
            _Digits
         ) +
         ",";

      result +=
         "\"c\":" +
         DoubleToString(
            rates[i].close,
            _Digits
         ) +
         ",";

      result +=
         "\"v\":" +
         IntegerToString(
            rates[i].tick_volume
         );

      result += "}";

      if(i > 0)
         result += ",";
   }

   result += "]";

   return result;
}


// ============================================================
// POLL SIGNAL
// ============================================================

void PollSignal()
{
   string url =
      InpWorkerBaseURL +
      "/signal/latest?symbol=" +
      _Symbol +
      "&cb=" +
      IntegerToString(
         GetTickCount()
      );

   string response = "";

   int status =
      HttpGet(
         url,
         response
      );

   if(
      status < 200 ||
      status >= 300
   )
   {
      return;
   }

   if(
      StringFind(
         response,
         "\"signal\":null"
      ) >= 0
   )
   {
      return;
   }

   string signalId =
      JsonGetString(
         response,
         "signal_id"
      );

   if(signalId == "")
      return;

   if(
      signalId ==
      g_lastHandledSignal
   )
   {
      return;
   }

   string side =
      StringToUpperCopy(
         JsonGetString(
            response,
            "side"
         )
      );

   double entry =
      JsonGetDouble(
         response,
         "entry_price"
      );

   double sl =
      JsonGetDouble(
         response,
         "sl"
      );

   double tp1 =
      JsonGetDouble(
         response,
         "tp1"
      );

   if(tp1 <= 0.0)
   {
      tp1 =
         JsonGetDouble(
            response,
            "tp"
         );
   }

   double tp2 =
      JsonGetDouble(
         response,
         "tp2"
      );

   if(tp2 <= 0.0)
      tp2 = tp1;

   long expiresAt =
      (long)
      JsonGetDouble(
         response,
         "expires_at"
      );

   long cloudNowMs =
      (long)
      TimeGMT() *
      1000;

   if(
      expiresAt > 0 &&
      cloudNowMs >
      expiresAt + 5000
   )
   {
      AckSignal(
         signalId,
         "expired"
      );

      g_lastHandledSignal =
         signalId;

      return;
   }

   ProcessSignal(
      signalId,
      side,
      entry,
      sl,
      tp1,
      tp2,
      expiresAt
   );
}


// ============================================================
// AUTOMATIC ORDER-TYPE SELECTION
// ============================================================

double AutomaticEntryTolerance(
   const MqlTick &tick
)
{
   double spread =
      MathMax(
         0.0,
         tick.ask - tick.bid
      );

   double stopDistance =
      (double)
      SymbolInfoInteger(
         _Symbol,
         SYMBOL_TRADE_STOPS_LEVEL
      ) *
      _Point;

   return MathMax(
      MathMax(
         spread * 3.0,
         stopDistance
      ),
      _Point * 10.0
   );
}


bool IsExplicitPendingSide(
   string side
)
{
   return(
      side == "BUY_LIMIT" ||
      side == "SELL_LIMIT" ||
      side == "BUY_STOP" ||
      side == "SELL_STOP"
   );
}


string ResolveAutomaticExecutionSide(
   string requestedSide,
   double referenceEntry,
   const MqlTick &tick,
   string &reason
)
{
   reason = "";

   // Never mutate an already explicit setup model.
   // If the Worker intentionally sends LIMIT or STOP, keep it exactly as-is.
   if(IsExplicitPendingSide(requestedSide))
   {
      reason =
         "Explicit pending type preserved.";

      return requestedSide;
   }

   bool buySide =
      requestedSide == "BUY";

   bool sellSide =
      requestedSide == "SELL";

   if(!buySide && !sellSide)
      return "";

   // Missing planned entry means immediate market execution.
   if(referenceEntry <= 0.0)
   {
      reason =
         "No planned entry supplied; market execution retained.";

      return requestedSide;
   }

   double currentPrice =
      buySide
      ? tick.ask
      : tick.bid;

   double tolerance =
      AutomaticEntryTolerance(
         tick
      );

   double delta =
      referenceEntry -
      currentPrice;

   // If the planned entry is effectively at market, do not manufacture
   // a pending order because of normal spread / polling movement.
   if(
      MathAbs(delta) <=
      tolerance
   )
   {
      reason =
         "Planned entry is within live-market tolerance; market execution selected.";

      return requestedSide;
   }

   if(buySide)
   {
      if(referenceEntry < tick.ask)
      {
         reason =
            "BUY setup waits below current Ask; BUY_LIMIT selected automatically.";

         return "BUY_LIMIT";
      }

      reason =
         "BUY setup requires confirmation above current Ask; BUY_STOP selected automatically.";

      return "BUY_STOP";
   }

   if(referenceEntry > tick.bid)
   {
      reason =
         "SELL setup waits above current Bid; SELL_LIMIT selected automatically.";

      return "SELL_LIMIT";
   }

   reason =
      "SELL setup requires confirmation below current Bid; SELL_STOP selected automatically.";

   return "SELL_STOP";
}


string InferExecutionModel(
   string side
)
{
   if(side == "BUY_LIMIT" || side == "SELL_LIMIT")
      return "LIMIT_VALUE_ENTRY";

   if(side == "BUY_STOP")
      return "BREAKOUT_CONFIRMATION";

   if(side == "SELL_STOP")
      return "BREAKDOWN_CONFIRMATION";

   if(side == "BUY" || side == "SELL")
      return "MARKET_CONFIRMATION";

   return "UNKNOWN";
}


string AuditZoneRelation(
   bool buySide,
   double price
)
{
   if(buySide && ValidZone(g_buyZoneLow, g_buyZoneHigh))
   {
      if(price >= g_buyZoneLow && price <= g_buyZoneHigh)
         return "INSIDE_BUY_ZONE";
      if(price < g_buyZoneLow)
         return "BELOW_BUY_ZONE";
      return "ABOVE_BUY_ZONE";
   }

   if(!buySide && ValidZone(g_sellZoneLow, g_sellZoneHigh))
   {
      if(price >= g_sellZoneLow && price <= g_sellZoneHigh)
         return "INSIDE_SELL_ZONE";
      if(price < g_sellZoneLow)
         return "BELOW_SELL_ZONE";
      return "ABOVE_SELL_ZONE";
   }

   return "NO_VALID_R1_ZONE";
}


void PrintPreExecutionAudit(
   string signalId,
   string side,
   string autoSelectionReason,
   const MqlTick &tick,
   double entry,
   double sl,
   double tp1,
   double tp2,
   double lot,
   long expiresAt
)
{
   if(!InpEnablePreExecutionAudit)
      return;

   bool buySide =
      StringFind(side, "BUY") == 0;

   double livePrice =
      buySide ? tick.ask : tick.bid;

   double risk =
      MathAbs(entry - sl);

   if(side == "BUY" || side == "SELL" || entry <= 0.0)
      risk = MathAbs(livePrice - sl);

   double reward1 =
      MathAbs(tp1 - (entry > 0.0 ? entry : livePrice));

   double reward2 =
      MathAbs(tp2 - (entry > 0.0 ? entry : livePrice));

   double rr1 =
      risk > 0.0 ? reward1 / risk : 0.0;

   double rr2 =
      risk > 0.0 ? reward2 / risk : 0.0;

   long nowMs =
      (long)TimeGMT() * 1000;

   long ttlSeconds =
      expiresAt > 0
      ? MathMax(0, (expiresAt - nowMs) / 1000)
      : 0;

   string zoneRelation =
      AuditZoneRelation(
         buySide,
         entry > 0.0 ? entry : livePrice
      );

   Print(
      "PRE_EXEC_AUDIT PASS | Signal=", signalId,
      " | Model=", InferExecutionModel(side),
      " | Order=", side,
      " | Bid=", DoubleToString(tick.bid, _Digits),
      " | Ask=", DoubleToString(tick.ask, _Digits),
      " | Entry=", DoubleToString(entry, _Digits),
      " | SL=", DoubleToString(sl, _Digits),
      " | TP1=", DoubleToString(tp1, _Digits),
      " | TP2=", DoubleToString(tp2, _Digits),
      " | RR1=", DoubleToString(rr1, 2),
      " | RR2=", DoubleToString(rr2, 2),
      " | Lot=", DoubleToString(lot, 2),
      " | TTLs=", IntegerToString((int)ttlSeconds),
      " | Zone=", zoneRelation
   );

   Print(
      "PRE_EXEC_AUDIT REASON | Signal=", signalId,
      " | ", autoSelectionReason
   );
}


bool PendingSetupInvalidated(
   string &reason
)
{
   reason = "";

   if(!g_pending.active)
      return false;

   MqlTick tick;

   if(
      !SymbolInfoTick(
         _Symbol,
         tick
      )
   )
   {
      // Network / tick failure is not a reason to destroy a valid order.
      return false;
   }

   bool buySide =
      StringFind(
         g_pending.side,
         "BUY"
      ) == 0;

   double spread =
      MathMax(
         0.0,
         tick.ask - tick.bid
      );

   double stopDistance =
      (double)
      SymbolInfoInteger(
         _Symbol,
         SYMBOL_TRADE_STOPS_LEVEL
      ) *
      _Point;

   double invalidationBuffer =
      MathMax(
         MathMax(
            spread * 2.0,
            stopDistance
         ),
         _Point * 10.0
      );

   // Hard setup failure before the pending order fills.
   if(
      buySide &&
      g_pending.sl > 0.0 &&
      tick.bid <= g_pending.sl
   )
   {
      reason =
         "BUY setup invalidated before entry: market reached/crossed planned SL.";

      return true;
   }

   if(
      !buySide &&
      g_pending.sl > 0.0 &&
      tick.ask >= g_pending.sl
   )
   {
      reason =
         "SELL setup invalidated before entry: market reached/crossed planned SL.";

      return true;
   }

   // Decision-zone invalidation is used only when the pending entry is
   // plausibly linked to the currently published R1 zone. This avoids
   // cancelling unrelated/manual signals because of a stale zone feed.
   double riskDistance =
      MathAbs(
         g_pending.entry -
         g_pending.sl
      );

   double linkBuffer =
      MathMax(
         riskDistance,
         invalidationBuffer * 4.0
      );

   if(
      buySide &&
      ValidZone(
         g_buyZoneLow,
         g_buyZoneHigh
      )
   )
   {
      bool linkedToBuyZone =
         g_pending.entry >=
         g_buyZoneLow - linkBuffer &&
         g_pending.entry <=
         g_buyZoneHigh + linkBuffer;

      if(
         linkedToBuyZone &&
         tick.bid <
         g_buyZoneLow -
         invalidationBuffer
      )
      {
         reason =
            "BUY setup invalidated: price broke below the active R1 buy decision zone.";

         return true;
      }
   }

   if(
      !buySide &&
      ValidZone(
         g_sellZoneLow,
         g_sellZoneHigh
      )
   )
   {
      bool linkedToSellZone =
         g_pending.entry >=
         g_sellZoneLow - linkBuffer &&
         g_pending.entry <=
         g_sellZoneHigh + linkBuffer;

      if(
         linkedToSellZone &&
         tick.ask >
         g_sellZoneHigh +
         invalidationBuffer
      )
      {
         reason =
            "SELL setup invalidated: price broke above the active R1 sell decision zone.";

         return true;
      }
   }

   return false;
}


// ============================================================
// PROCESS SIGNAL
// ============================================================

void ProcessSignal(
   string signalId,
   string side,
   double referenceEntry,
   double sl,
   double tp1,
   double tp2,
   long expiresAt
)
{
   g_lastHandledSignal =
      signalId;

   bool requestedMarketSide =
      side == "BUY" ||
      side == "SELL";

   bool requestedPendingSide =
      IsExplicitPendingSide(
         side
      );

   if(
      !requestedMarketSide &&
      !requestedPendingSide
   )
   {
      AckSignal(
         signalId,
         "failed"
      );

      return;
   }

   if(
      InpBlockIfPositionExists &&
      HasPositionOnSymbol()
   )
   {
      MessageBox(
         "A position is already open on " +
         _Symbol +
         ".\n\n"
         "The new signal will not be executed.",
         "XAU Bridge",
         MB_OK |
         MB_ICONWARNING
      );

      AckSignal(
         signalId,
         "rejected"
      );

      return;
   }

   if(
      g_pending.active ||
      HasPendingOrderOnSymbol()
   )
   {
      MessageBox(
         "A pending XAU order is already active.\n\n"
         "Cancel or resolve it before accepting a new R2 setup.",
         "XAU Bridge",
         MB_OK |
         MB_ICONWARNING
      );

      AckSignal(
         signalId,
         "rejected"
      );

      return;
   }

   MqlTick tick;

   if(
      !SymbolInfoTick(
         _Symbol,
         tick
      )
   )
   {
      AckSignal(
         signalId,
         "failed"
      );

      return;
   }

   string autoSelectionReason = "";

   string effectiveSide =
      ResolveAutomaticExecutionSide(
         side,
         referenceEntry,
         tick,
         autoSelectionReason
      );

   if(effectiveSide == "")
   {
      AckSignal(
         signalId,
         "failed"
      );

      return;
   }

   if(effectiveSide != side)
   {
      Print(
         "Automatic order type selected. Signal=",
         signalId,
         " Requested=",
         side,
         " Selected=",
         effectiveSide,
         " Reason=",
         autoSelectionReason
      );
   }

   side =
      effectiveSide;

   bool isMarket =
      side == "BUY" ||
      side == "SELL";

   bool isPending =
      IsExplicitPendingSide(
         side
      );

   if(
      isPending &&
      !InpEnablePendingOrders
   )
   {
      MessageBox(
         "Pending-order execution is disabled in EA inputs.",
         "XAU Bridge",
         MB_OK | MB_ICONWARNING
      );

      AckSignal(signalId, "rejected");
      return;
   }

   bool buySide =
      StringFind(
         side,
         "BUY"
      ) == 0;

   double currentPrice =
      buySide
      ? tick.ask
      : tick.bid;

   // --------------------------------------------------------
   // ENTRY DRIFT PROTECTION
   // --------------------------------------------------------

   if(
      isMarket &&
      referenceEntry > 0 &&
      InpMaxMarketEntryDriftUSD > 0
   )
   {
      double drift =
         MathAbs(
            currentPrice -
            referenceEntry
         );

      if(
         drift >
         InpMaxMarketEntryDriftUSD
      )
      {
         string msg =
            "Signal rejected because price moved too far.\n\n" +
            "Signal entry: " +
            DoubleToString(
               referenceEntry,
               _Digits
            ) +
            "\n" +
            "Current price: " +
            DoubleToString(
               currentPrice,
               _Digits
            ) +
            "\n" +
            "Drift: $" +
            DoubleToString(
               drift,
               2
            );

         MessageBox(
            msg,
            "XAU Bridge Price Protection",
            MB_OK |
            MB_ICONWARNING
         );

         AckSignal(
            signalId,
            "rejected"
         );

         return;
      }
   }

   // --------------------------------------------------------
   // VALIDATE SL/TP
   // --------------------------------------------------------

   string validationError = "";

   string baseSide =
      buySide
      ? "BUY"
      : "SELL";

   double validationPrice =
      isPending
      ? referenceEntry
      : currentPrice;

   if(
      !ValidateStops(
         baseSide,
         validationPrice,
         sl,
         tp2,
         validationError
      )
   )
   {
      MessageBox(
         validationError,
         "Invalid SL / TP",
         MB_OK |
         MB_ICONWARNING
      );

      AckSignal(
         signalId,
         "failed"
      );

      return;
   }

   if(
      !ValidateR2Targets(
         baseSide,
         validationPrice,
         sl,
         tp1,
         tp2,
         validationError
      )
   )
   {
      MessageBox(
         validationError,
         "Invalid R2 targets",
         MB_OK |
         MB_ICONWARNING
      );

      AckSignal(
         signalId,
         "failed"
      );

      return;
   }

   if(isPending)
   {
      if(referenceEntry <= 0)
      {
         AckSignal(signalId, "failed");
         return;
      }

      bool placementOk = true;

      if(side == "BUY_LIMIT" && referenceEntry >= tick.ask)
         placementOk = false;

      if(side == "SELL_LIMIT" && referenceEntry <= tick.bid)
         placementOk = false;

      if(side == "BUY_STOP" && referenceEntry <= tick.ask)
         placementOk = false;

      if(side == "SELL_STOP" && referenceEntry >= tick.bid)
         placementOk = false;

      if(!placementOk)
      {
         MessageBox(
            "Pending entry is no longer valid relative to current price. Re-analyze instead of moving the order.",
            "XAU Bridge Pending Protection",
            MB_OK | MB_ICONWARNING
         );

         AckSignal(signalId, "rejected");
         return;
      }
   }

   double lot =
      CalculateLotByBalance();

   if(lot <= 0)
   {
      AckSignal(
         signalId,
         "failed"
      );

      return;
   }

   // --------------------------------------------------------
   // PRE EXECUTION AUDIT
   // --------------------------------------------------------

   PrintPreExecutionAudit(
      signalId,
      side,
      autoSelectionReason,
      tick,
      referenceEntry,
      sl,
      tp1,
      tp2,
      lot,
      expiresAt
   );

   // --------------------------------------------------------
   // MANUAL CONFIRMATION
   // --------------------------------------------------------

   string confirmation =
      "NEW XAU SIGNAL\n\n" +
      "Order type: " +
      side +
      "\n" +
      "Auto selection: " +
      autoSelectionReason +
      "\n" +
      "Symbol: " +
      _Symbol +
      "\n" +
      "Current price: " +
      DoubleToString(
         currentPrice,
         _Digits
      ) +
      "\n" +
      "Planned entry: " +
      DoubleToString(
         referenceEntry,
         _Digits
      ) +
      "\n" +
      "Balance: $" +
      DoubleToString(
         AccountInfoDouble(
            ACCOUNT_BALANCE
         ),
         2
      ) +
      "\n" +
      "Calculated lot: " +
      DoubleToString(
         lot,
         2
      ) +
      "\n" +
      "SL: " +
      DoubleToString(
         sl,
         _Digits
      ) +
      "\n" +
      "TP1: " +
      DoubleToString(
         tp1,
         _Digits
      ) +
      "\n" +
      "TP2: " +
      DoubleToString(
         tp2,
         _Digits
      ) +
      "\n" +
      "Audit: check Experts for PRE_EXEC_AUDIT PASS" +
      "\n\n" +
      "Execute this trade?";

   int answer =
      MessageBox(
         confirmation,
         "XAU Bridge Trade Confirmation",
         MB_YESNO |
         MB_ICONQUESTION
      );

   if(answer != IDYES)
   {
      Print(
         "PRE_EXEC_AUDIT USER_REJECT | Signal=",
         signalId,
         " | Order=",
         side
      );

      AckSignal(
         signalId,
         "rejected"
      );

      return;
   }

   Print(
      "PRE_EXEC_AUDIT USER_APPROVED | Signal=",
      signalId,
      " | Order=",
      side
   );

   ExecuteTrade(
      signalId,
      side,
      referenceEntry,
      lot,
      sl,
      tp1,
      tp2,
      expiresAt
   );
}


// ============================================================
// EXECUTE TRADE
// ============================================================

void ExecuteTrade(
   string signalId,
   string side,
   double referenceEntry,
   double lot,
   double sl,
   double tp1,
   double tp2,
   long expiresAt
)
{
   trade.SetExpertMagicNumber(
      InpMagicNumber
   );

   trade.SetDeviationInPoints(
      InpMaxDeviationPoints
   );

   string comment =
      "XAUBridge";

   bool success =
      false;

   double brokerTP =
      tp2 > 0.0
      ? tp2
      : tp1;

   if(side == "BUY")
   {
      success = trade.Buy(lot, _Symbol, 0.0, sl, brokerTP, comment);
   }
   else if(side == "SELL")
   {
      success = trade.Sell(lot, _Symbol, 0.0, sl, brokerTP, comment);
   }
   else
   {
      datetime expiry = 0;
      ENUM_ORDER_TYPE_TIME timeType = ORDER_TIME_GTC;

      if(expiresAt > 0)
      {
         expiry = (datetime)(expiresAt / 1000);
         timeType = ORDER_TIME_SPECIFIED;
      }

      if(side == "BUY_LIMIT")
         success = trade.BuyLimit(lot, referenceEntry, _Symbol, sl, brokerTP, timeType, expiry, comment);
      else if(side == "SELL_LIMIT")
         success = trade.SellLimit(lot, referenceEntry, _Symbol, sl, brokerTP, timeType, expiry, comment);
      else if(side == "BUY_STOP")
         success = trade.BuyStop(lot, referenceEntry, _Symbol, sl, brokerTP, timeType, expiry, comment);
      else if(side == "SELL_STOP")
         success = trade.SellStop(lot, referenceEntry, _Symbol, sl, brokerTP, timeType, expiry, comment);
   }

   if(!success)
   {
      Print(
         "Trade open failed. Retcode=",
         trade.ResultRetcode(),
         " ",
         trade.ResultRetcodeDescription()
      );

      AckSignal(
         signalId,
         "failed"
      );

      return;
   }

   bool pendingPlaced =
      side == "BUY_LIMIT" ||
      side == "SELL_LIMIT" ||
      side == "BUY_STOP" ||
      side == "SELL_STOP";

   if(pendingPlaced)
   {
      ResetPendingState();

      g_pending.active =
         true;

      g_pending.signal_id =
         signalId;

      g_pending.order_ticket =
         trade.ResultOrder();

      g_pending.side =
         side;

      g_pending.entry =
         referenceEntry;

      g_pending.sl =
         sl;

      g_pending.tp1 =
         tp1;

      g_pending.tp2 =
         tp2;

      g_pending.lot =
         lot;

      g_pending.expires_at_ms =
         expiresAt;

      SaveTrackedState();

      AckSignal(signalId, "placed");

      Print(
         "Pending order placed. Signal=",
         signalId,
         " Order=",
         g_pending.order_ticket,
         " Type=",
         side,
         " Entry=",
         DoubleToString(referenceEntry, _Digits),
         " TP1=",
         DoubleToString(tp1, _Digits),
         " TP2=",
         DoubleToString(tp2, _Digits),
         " Lot=",
         DoubleToString(lot, 2)
      );

      return;
   }

   Sleep(150);

   if(
      !PositionSelect(
         _Symbol
      )
   )
   {
      Print(
         "Order succeeded but position could not be selected."
      );

      AckSignal(
         signalId,
         "failed"
      );

      return;
   }

   ulong positionIdentifier =
      (ulong)
      PositionGetInteger(
         POSITION_IDENTIFIER
      );

   ulong openDeal =
      trade.ResultDeal();

   double fillPrice =
      PositionGetDouble(
         POSITION_PRICE_OPEN
      );

   double volume =
      PositionGetDouble(
         POSITION_VOLUME
      );

   datetime openTime =
      (datetime)
      PositionGetInteger(
         POSITION_TIME
      );

   ResetTrackedState();

   g_state.active =
      true;

   g_state.signal_id =
      signalId;

   g_state.position_id =
      positionIdentifier;

   g_state.open_deal_id =
      openDeal;

   g_state.side =
      side;

   g_state.entry =
      fillPrice;

   g_state.sl =
      sl;

   g_state.tp1 =
      tp1;

   g_state.tp2 =
      tp2;

   g_state.initial_lot =
      volume;

   g_state.lot =
      volume;

   g_state.initial_risk =
      MathAbs(
         fillPrice -
         sl
      );

   g_state.open_time =
      openTime;

   g_state.mfe_price =
      fillPrice;

   g_state.mae_price =
      fillPrice;

   g_state.mfe_usd =
      0.0;

   g_state.mae_usd =
      0.0;

   g_state.tp1_done =
      false;

   g_state.open_event_sent =
      false;

   SaveTrackedState();

   SendOpenEvent();

   AckSignal(
      signalId,
      "executed"
   );

   Print(
      "Trade executed. Signal=",
      signalId,
      " PositionID=",
      positionIdentifier,
      " Lot=",
      DoubleToString(
         volume,
         2
      )
   );
}


// ============================================================
// SEND OPEN EVENT
// ============================================================

bool SendOpenEvent()
{
   if(!g_state.active)
      return false;

   if(
      g_state.open_event_sent
   )
   {
      return true;
   }

   string payload = "{";

   payload +=
      "\"event_id\":\"OPEN-" +
      JsonEscape(
         g_state.signal_id
      ) +
      "\",";

   payload +=
      "\"event_type\":\"OPEN\",";

   payload +=
      "\"signal_id\":\"" +
      JsonEscape(
         g_state.signal_id
      ) +
      "\",";

   payload +=
      "\"symbol\":\"" +
      JsonEscape(
         _Symbol
      ) +
      "\",";

   payload +=
      "\"position_id\":\"" +
      IntegerToString(
         (long)
         g_state.position_id
      ) +
      "\",";

   payload +=
      "\"deal_id\":\"" +
      IntegerToString(
         (long)
         g_state.open_deal_id
      ) +
      "\",";

   payload +=
      "\"side\":\"" +
      JsonEscape(
         g_state.side
      ) +
      "\",";

   payload +=
      "\"price\":" +
      DoubleToString(
         g_state.entry,
         _Digits
      ) +
      ",";

   payload +=
      "\"volume\":" +
      DoubleToString(
         g_state.initial_lot > 0.0
         ? g_state.initial_lot
         : g_state.lot,
         2
      ) +
      ",";

   payload +=
      "\"event_time\":" +
      IntegerToString(
         g_state.open_time
      );

   payload += "}";

   string response = "";

   int status =
      HttpPostJson(
         InpWorkerBaseURL +
         "/trade/event",
         payload,
         response
      );

   if(
      status >= 200 &&
      status < 300
   )
   {
      g_state.open_event_sent =
         true;

      SaveTrackedState();

      Print(
         "OPEN event sent successfully."
      );

      return true;
   }

   Print(
      "OPEN event failed. HTTP=",
      status,
      " response=",
      response
   );

   return false;
}


// ============================================================
// CHECK TRACKED TRADE
// ============================================================

void CheckTrackedTrade()
{
   if(!g_state.active)
      return;

   // Retry OPEN event if network failed earlier.
   if(
      !g_state.open_event_sent
   )
   {
      SendOpenEvent();
   }

   // Position still exists.
   if(
      PositionExistsByIdentifier(
         g_state.position_id
      )
   )
   {
      UpdateMfeMae();

      return;
   }

   // Position disappeared.
   // Read closing deal from history.
   SendCloseEventFromHistory();
}


// ============================================================
// LIVE MFE / MAE TRACKING
// ============================================================

void UpdateMfeMae()
{
   if(!g_state.active)
      return;

   if(
      !PositionExistsByIdentifier(
         g_state.position_id
      )
   )
   {
      return;
   }

   MqlTick tick;

   if(
      !SymbolInfoTick(
         _Symbol,
         tick
      )
   )
   {
      return;
   }

   double currentPrice = 0.0;

   // Use executable side of quote.
   if(
      g_state.side ==
      "BUY"
   )
   {
      currentPrice =
         tick.bid;
   }
   else
   {
      currentPrice =
         tick.ask;
   }

   double movement =
      0.0;

   if(
      g_state.side ==
      "BUY"
   )
   {
      movement =
         currentPrice -
         g_state.entry;
   }
   else
   {
      movement =
         g_state.entry -
         currentPrice;
   }

   bool changed =
      false;

   // Maximum Favorable Excursion
   if(
      movement >
      g_state.mfe_usd
   )
   {
      g_state.mfe_usd =
         movement;

      g_state.mfe_price =
         currentPrice;

      changed =
         true;
   }

   // Maximum Adverse Excursion
   if(
      movement <
      g_state.mae_usd
   )
   {
      g_state.mae_usd =
         movement;

      g_state.mae_price =
         currentPrice;

      changed =
         true;
   }

   if(changed)
      SaveTrackedState();
}


// ============================================================
// REBUILD MFE / MAE FROM HISTORICAL TICKS
// ============================================================
//
// This rebuilds the complete excursion from broker tick history.
//
// Example:
// Trade opened -> EA turned off -> market moves -> EA turned on.
// We can still recover the missing MFE/MAE from tick history.
//
// BUY:
//   MFE uses BID because BUY closes at BID.
//   MAE uses BID.
//
// SELL:
//   MFE uses ASK because SELL closes at ASK.
//   MAE uses ASK.
//
// mfe_usd / mae_usd mean GOLD PRICE MOVEMENT in dollars,
// not account-dollar PnL.
// ============================================================

bool RebuildMfeMaeFromHistoricalTicks(
   datetime closeTime
)
{
   if(!g_state.active)
      return false;

   if(
      g_state.open_time <= 0
   )
   {
      return false;
   }

   if(
      closeTime <=
      g_state.open_time
   )
   {
      return false;
   }

   ulong fromMs =
      (ulong)
      g_state.open_time *
      1000;

   ulong toMs =
      (
         (ulong)
         closeTime *
         1000
      ) +
      999;

   // Read ticks in 30-minute blocks
   // to avoid huge memory usage.
   ulong chunkSize =
      (ulong)
      30 *
      60 *
      1000;

   double bestMove =
      0.0;

   double worstMove =
      0.0;

   double bestPrice =
      g_state.entry;

   double worstPrice =
      g_state.entry;

   bool foundTicks =
      false;

   ulong chunkFrom =
      fromMs;

   while(
      chunkFrom <=
      toMs
   )
   {
      ulong chunkTo =
         chunkFrom +
         chunkSize -
         1;

      if(
         chunkTo >
         toMs
      )
      {
         chunkTo =
            toMs;
      }

      MqlTick ticks[];

      ResetLastError();

      int copied =
         CopyTicksRange(
            _Symbol,
            ticks,
            COPY_TICKS_ALL,
            chunkFrom,
            chunkTo
         );

      if(copied > 0)
      {
         foundTicks =
            true;

         for(
            int i = 0;
            i < copied;
            i++
         )
         {
            double price =
               0.0;

            if(
               g_state.side ==
               "BUY"
            )
            {
               price =
                  ticks[i].bid;
            }
            else
            {
               price =
                  ticks[i].ask;
            }

            if(price <= 0.0)
               continue;

            double movement =
               0.0;

            if(
               g_state.side ==
               "BUY"
            )
            {
               movement =
                  price -
                  g_state.entry;
            }
            else
            {
               movement =
                  g_state.entry -
                  price;
            }

            // ---------------------------------------------
            // MFE
            // ---------------------------------------------

            if(
               movement >
               bestMove
            )
            {
               bestMove =
                  movement;

               bestPrice =
                  price;
            }

            // ---------------------------------------------
            // MAE
            // ---------------------------------------------

            if(
               movement <
               worstMove
            )
            {
               worstMove =
                  movement;

               worstPrice =
                  price;
            }
         }
      }
      else
      {
         int err =
            GetLastError();

         if(err != 0)
         {
            Print(
               "CopyTicksRange warning. Error=",
               err,
               " From=",
               chunkFrom,
               " To=",
               chunkTo
            );
         }
      }

      if(
         chunkTo >=
         toMs
      )
      {
         break;
      }

      chunkFrom =
         chunkTo +
         1;
   }

   if(!foundTicks)
   {
      Print(
         "Historical tick rebuild unavailable. ",
         "Keeping live-tracked MFE/MAE."
      );

      return false;
   }

   g_state.mfe_price =
      bestPrice;

   g_state.mae_price =
      worstPrice;

   g_state.mfe_usd =
      bestMove;

   g_state.mae_usd =
      worstMove;

   SaveTrackedState();

   Print(
      "Historical MFE/MAE rebuilt. ",
      "MFE=$",
      DoubleToString(
         g_state.mfe_usd,
         2
      ),
      " at ",
      DoubleToString(
         g_state.mfe_price,
         _Digits
      ),
      " | MAE=$",
      DoubleToString(
         g_state.mae_usd,
         2
      ),
      " at ",
      DoubleToString(
         g_state.mae_price,
         _Digits
      )
   );

   return true;
}


// ============================================================
// SEND CLOSE EVENT FROM HISTORY
// ============================================================

bool SendCloseEventFromHistory()
{
   if(!g_state.active)
      return false;

   datetime fromTime =
      g_state.open_time -
      3600;

   datetime toTime =
      TimeCurrent() +
      60;

   if(
      !HistorySelect(
         fromTime,
         toTime
      )
   )
   {
      return false;
   }

   int deals =
      HistoryDealsTotal();

   if(deals <= 0)
      return false;

   ulong closeDeal =
      0;

   datetime closeTime =
      0;

   double closePrice =
      0.0;

   ENUM_DEAL_REASON closeReason =
      DEAL_REASON_EXPERT;

   double totalProfit =
      0.0;

   double totalCommission =
      0.0;

   double totalSwap =
      0.0;

   // --------------------------------------------------------
   // READ ALL DEALS FOR SAME POSITION
   // --------------------------------------------------------

   for(
      int i = 0;
      i < deals;
      i++
   )
   {
      ulong ticket =
         HistoryDealGetTicket(
            i
         );

      if(ticket == 0)
         continue;

      ulong posId =
         (ulong)
         HistoryDealGetInteger(
            ticket,
            DEAL_POSITION_ID
         );

      if(
         posId !=
         g_state.position_id
      )
      {
         continue;
      }

      totalProfit +=
         HistoryDealGetDouble(
            ticket,
            DEAL_PROFIT
         );

      totalCommission +=
         HistoryDealGetDouble(
            ticket,
            DEAL_COMMISSION
         );

      totalSwap +=
         HistoryDealGetDouble(
            ticket,
            DEAL_SWAP
         );

      ENUM_DEAL_ENTRY entryType =
         (ENUM_DEAL_ENTRY)
         HistoryDealGetInteger(
            ticket,
            DEAL_ENTRY
         );

      if(
         entryType ==
         DEAL_ENTRY_OUT ||
         entryType ==
         DEAL_ENTRY_OUT_BY
      )
      {
         datetime dealTime =
            (datetime)
            HistoryDealGetInteger(
               ticket,
               DEAL_TIME
            );

         if(
            dealTime >=
            closeTime
         )
         {
            closeTime =
               dealTime;

            closeDeal =
               ticket;

            closePrice =
               HistoryDealGetDouble(
                  ticket,
                  DEAL_PRICE
               );

            closeReason =
               (ENUM_DEAL_REASON)
               HistoryDealGetInteger(
                  ticket,
                  DEAL_REASON
               );
         }
      }
   }

   // Closing transaction may need a moment
   // to arrive in account history.
   if(closeDeal == 0)
      return false;


   // ========================================================
   // NEW:
   // REBUILD COMPLETE MFE / MAE FROM HISTORICAL TICKS
   // ========================================================

   RebuildMfeMaeFromHistoricalTicks(
      closeTime
   );


   string reason =
      DealReasonToString(
         closeReason
      );

   double netProfit =
      totalProfit +
      totalCommission +
      totalSwap;

   string eventId =
      "CLOSE-" +
      g_state.signal_id +
      "-" +
      IntegerToString(
         (long)
         closeDeal
      );

   string payload = "{";

   payload +=
      "\"event_id\":\"" +
      JsonEscape(
         eventId
      ) +
      "\",";

   payload +=
      "\"event_type\":\"CLOSE\",";

   payload +=
      "\"signal_id\":\"" +
      JsonEscape(
         g_state.signal_id
      ) +
      "\",";

   payload +=
      "\"symbol\":\"" +
      JsonEscape(
         _Symbol
      ) +
      "\",";

   payload +=
      "\"position_id\":\"" +
      IntegerToString(
         (long)
         g_state.position_id
      ) +
      "\",";

   payload +=
      "\"deal_id\":\"" +
      IntegerToString(
         (long)
         closeDeal
      ) +
      "\",";

   payload +=
      "\"side\":\"" +
      JsonEscape(
         g_state.side
      ) +
      "\",";

   payload +=
      "\"price\":" +
      DoubleToString(
         closePrice,
         _Digits
      ) +
      ",";

   payload +=
      "\"volume\":" +
      DoubleToString(
         g_state.initial_lot > 0.0
         ? g_state.initial_lot
         : g_state.lot,
         2
      ) +
      ",";

   payload +=
      "\"profit\":" +
      DoubleToString(
         totalProfit,
         2
      ) +
      ",";

   payload +=
      "\"commission\":" +
      DoubleToString(
         totalCommission,
         2
      ) +
      ",";

   payload +=
      "\"swap\":" +
      DoubleToString(
         totalSwap,
         2
      ) +
      ",";

   payload +=
      "\"net_profit\":" +
      DoubleToString(
         netProfit,
         2
      ) +
      ",";

   payload +=
      "\"close_reason\":\"" +
      JsonEscape(
         reason
      ) +
      "\",";

   payload +=
      "\"mfe_price\":" +
      DoubleToString(
         g_state.mfe_price,
         _Digits
      ) +
      ",";

   payload +=
      "\"mae_price\":" +
      DoubleToString(
         g_state.mae_price,
         _Digits
      ) +
      ",";

   payload +=
      "\"mfe_usd\":" +
      DoubleToString(
         g_state.mfe_usd,
         2
      ) +
      ",";

   payload +=
      "\"mae_usd\":" +
      DoubleToString(
         g_state.mae_usd,
         2
      ) +
      ",";

   payload +=
      "\"event_time\":" +
      IntegerToString(
         closeTime
      );

   payload += "}";

   string response = "";

   int status =
      HttpPostJson(
         InpWorkerBaseURL +
         "/trade/event",
         payload,
         response
      );

   if(
      status >= 200 &&
      status < 300
   )
   {
      Print(
         "CLOSE event sent. Net PnL=",
         DoubleToString(
            netProfit,
            2
         ),
         " Reason=",
         reason,
         " MFE=$",
         DoubleToString(
            g_state.mfe_usd,
            2
         ),
         " MAE=$",
         DoubleToString(
            g_state.mae_usd,
            2
         )
      );

      ClearTrackedState();

      return true;
   }

   Print(
      "CLOSE event failed. HTTP=",
      status,
      " response=",
      response
   );

   return false;
}


// ============================================================
// POSITION EXISTS BY IDENTIFIER
// ============================================================

bool PositionExistsByIdentifier(
   ulong identifier
)
{
   int total =
      PositionsTotal();

   for(
      int i = 0;
      i < total;
      i++
   )
   {
      ulong ticket =
         PositionGetTicket(
            i
         );

      if(ticket == 0)
         continue;

      if(
         !PositionSelectByTicket(
            ticket
         )
      )
      {
         continue;
      }

      ulong currentIdentifier =
         (ulong)
         PositionGetInteger(
            POSITION_IDENTIFIER
         );

      if(
         currentIdentifier ==
         identifier
      )
      {
         return true;
      }
   }

   return false;
}


// ============================================================
// POSITION EXISTS ON SYMBOL
// ============================================================

bool HasPositionOnSymbol()
{
   int total =
      PositionsTotal();

   for(
      int i = 0;
      i < total;
      i++
   )
   {
      ulong ticket =
         PositionGetTicket(
            i
         );

      if(ticket == 0)
         continue;

      if(
         !PositionSelectByTicket(
            ticket
         )
      )
      {
         continue;
      }

      string symbol =
         PositionGetString(
            POSITION_SYMBOL
         );

      if(symbol == _Symbol)
         return true;
   }

   return false;
}


// ============================================================
// DEAL REASON
// ============================================================

string DealReasonToString(
   ENUM_DEAL_REASON reason
)
{
   switch(reason)
   {
      case DEAL_REASON_SL:
         return "SL";

      case DEAL_REASON_TP:
         return "TP";

      case DEAL_REASON_SO:
         return "STOP_OUT";

      case DEAL_REASON_CLIENT:
         return "MANUAL_DESKTOP";

      case DEAL_REASON_MOBILE:
         return "MANUAL_MOBILE";

      case DEAL_REASON_WEB:
         return "MANUAL_WEB";

      case DEAL_REASON_EXPERT:
         return "EXPERT";

      default:
         return "OTHER";
   }
}


// ============================================================
// LOT CALCULATION
// ============================================================

double CalculateLotByBalance()
{
   double balance =
      AccountInfoDouble(
         ACCOUNT_BALANCE
      );

   double lot =
      MathFloor(
         balance /
         100.0
      ) *
      0.01;

   if(lot < 0.01)
      lot = 0.01;

   double minLot =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_VOLUME_MIN
      );

   double maxLot =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_VOLUME_MAX
      );

   double lotStep =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_VOLUME_STEP
      );

   if(minLot <= 0)
      minLot = 0.01;

   if(maxLot <= 0)
      maxLot = lot;

   if(lotStep <= 0)
      lotStep = 0.01;

   lot =
      MathMax(
         lot,
         minLot
      );

   lot =
      MathMin(
         lot,
         maxLot
      );

   if(
      InpSafetyMaxLot > 0
   )
   {
      lot =
         MathMin(
            lot,
            InpSafetyMaxLot
         );
   }

   lot =
      MathFloor(
         (
            lot +
            1e-12
         ) /
         lotStep
      ) *
      lotStep;

   return NormalizeDouble(
      lot,
      2
   );
}


// ============================================================
// VALIDATE SL / TP
// ============================================================

bool ValidateStops(
   string side,
   double currentPrice,
   double sl,
   double tp,
   string &error
)
{
   if(
      !MathIsValidNumber(sl) ||
      !MathIsValidNumber(tp)
   )
   {
      error =
         "Invalid SL or TP.";

      return false;
   }

   if(side == "BUY")
   {
      if(
         !(
            sl <
            currentPrice &&
            currentPrice <
            tp
         )
      )
      {
         error =
            "BUY requires:\n"
            "SL < Current Price < TP";

         return false;
      }
   }
   else
   {
      if(
         !(
            tp <
            currentPrice &&
            currentPrice <
            sl
         )
      )
      {
         error =
            "SELL requires:\n"
            "TP < Current Price < SL";

         return false;
      }
   }

   long stopLevelPoints =
      SymbolInfoInteger(
         _Symbol,
         SYMBOL_TRADE_STOPS_LEVEL
      );

   double minDistance =
      stopLevelPoints *
      _Point;

   if(minDistance > 0)
   {
      if(
         MathAbs(
            currentPrice -
            sl
         ) <
         minDistance
      )
      {
         error =
            "SL is too close to current price.";

         return false;
      }

      if(
         MathAbs(
            tp -
            currentPrice
         ) <
         minDistance
      )
      {
         error =
            "TP is too close to current price.";

         return false;
      }
   }

   return true;
}


// ============================================================
// VALIDATE R2 TARGETS
// ============================================================

bool ValidateR2Targets(
   string side,
   double entry,
   double sl,
   double tp1,
   double tp2,
   string &error
)
{
   if(
      !MathIsValidNumber(entry) ||
      !MathIsValidNumber(sl) ||
      !MathIsValidNumber(tp1) ||
      !MathIsValidNumber(tp2) ||
      entry <= 0.0 ||
      sl <= 0.0 ||
      tp1 <= 0.0 ||
      tp2 <= 0.0
   )
   {
      error =
         "Invalid R2 Entry / SL / TP1 / TP2.";

      return false;
   }

   if(side == "BUY")
   {
      if(
         !(
            sl < entry &&
            entry < tp1 &&
            tp1 <= tp2
         )
      )
      {
         error =
            "R2 BUY requires:\n"
            "SL < Entry < TP1 <= TP2";

         return false;
      }
   }
   else
   {
      if(
         !(
            tp2 <= tp1 &&
            tp1 < entry &&
            entry < sl
         )
      )
      {
         error =
            "R2 SELL requires:\n"
            "TP2 <= TP1 < Entry < SL";

         return false;
      }
   }

   return true;
}


// ============================================================
// PENDING ORDER HELPERS
// ============================================================

bool HasPendingOrderOnSymbol()
{
   int total =
      OrdersTotal();

   for(
      int i = 0;
      i < total;
      i++
   )
   {
      ulong ticket =
         OrderGetTicket(i);

      if(ticket == 0)
         continue;

      string symbol =
         OrderGetString(
            ORDER_SYMBOL
         );

      long magic =
         OrderGetInteger(
            ORDER_MAGIC
         );

      if(
         symbol != _Symbol ||
         magic != InpMagicNumber
      )
      {
         continue;
      }

      ENUM_ORDER_TYPE type =
         (ENUM_ORDER_TYPE)
         OrderGetInteger(
            ORDER_TYPE
         );

      if(
         type == ORDER_TYPE_BUY_LIMIT ||
         type == ORDER_TYPE_SELL_LIMIT ||
         type == ORDER_TYPE_BUY_STOP ||
         type == ORDER_TYPE_SELL_STOP ||
         type == ORDER_TYPE_BUY_STOP_LIMIT ||
         type == ORDER_TYPE_SELL_STOP_LIMIT
      )
      {
         return true;
      }
   }

   return false;
}


bool SelectTrackedPosition()
{
   int total =
      PositionsTotal();

   for(
      int i = 0;
      i < total;
      i++
   )
   {
      ulong ticket =
         PositionGetTicket(i);

      if(ticket == 0)
         continue;

      ulong identifier =
         (ulong)
         PositionGetInteger(
            POSITION_IDENTIFIER
         );

      if(
         identifier ==
         g_state.position_id
      )
      {
         return true;
      }
   }

   return false;
}


ulong FindEntryDealForPosition(
   ulong positionIdentifier,
   datetime fromTime
)
{
   if(
      !HistorySelect(
         fromTime - 3600,
         TimeCurrent() + 60
      )
   )
   {
      return 0;
   }

   int deals =
      HistoryDealsTotal();

   ulong bestDeal = 0;
   datetime bestTime = 0;

   for(
      int i = 0;
      i < deals;
      i++
   )
   {
      ulong deal =
         HistoryDealGetTicket(i);

      if(deal == 0)
         continue;

      ulong posId =
         (ulong)
         HistoryDealGetInteger(
            deal,
            DEAL_POSITION_ID
         );

      if(
         posId !=
         positionIdentifier
      )
      {
         continue;
      }

      ENUM_DEAL_ENTRY entryType =
         (ENUM_DEAL_ENTRY)
         HistoryDealGetInteger(
            deal,
            DEAL_ENTRY
         );

      if(
         entryType != DEAL_ENTRY_IN &&
         entryType != DEAL_ENTRY_INOUT
      )
      {
         continue;
      }

      datetime dealTime =
         (datetime)
         HistoryDealGetInteger(
            deal,
            DEAL_TIME
         );

      if(
         bestDeal == 0 ||
         dealTime < bestTime
      )
      {
         bestDeal = deal;
         bestTime = dealTime;
      }
   }

   return bestDeal;
}


bool ActivateFilledPendingPosition()
{
   if(!g_pending.active)
      return false;

   if(
      !PositionSelect(
         _Symbol
      )
   )
   {
      return false;
   }

   long magic =
      PositionGetInteger(
         POSITION_MAGIC
      );

   if(magic != InpMagicNumber)
      return false;

   ulong identifier =
      (ulong)
      PositionGetInteger(
         POSITION_IDENTIFIER
      );

   double fillPrice =
      PositionGetDouble(
         POSITION_PRICE_OPEN
      );

   double volume =
      PositionGetDouble(
         POSITION_VOLUME
      );

   datetime openTime =
      (datetime)
      PositionGetInteger(
         POSITION_TIME
      );

   string baseSide =
      StringFind(
         g_pending.side,
         "BUY"
      ) == 0
      ? "BUY"
      : "SELL";

   string signalId =
      g_pending.signal_id;

   double plannedSL =
      g_pending.sl;

   double plannedTP1 =
      g_pending.tp1;

   double plannedTP2 =
      g_pending.tp2;

   double plannedLot =
      g_pending.lot;

   ulong openDeal =
      FindEntryDealForPosition(
         identifier,
         openTime
      );

   ResetTrackedState();

   g_state.active =
      true;

   g_state.signal_id =
      signalId;

   g_state.position_id =
      identifier;

   g_state.open_deal_id =
      openDeal;

   g_state.side =
      baseSide;

   g_state.entry =
      fillPrice;

   g_state.sl =
      plannedSL;

   g_state.tp1 =
      plannedTP1;

   g_state.tp2 =
      plannedTP2;

   g_state.initial_lot =
      plannedLot > 0.0
      ? plannedLot
      : volume;

   g_state.lot =
      volume;

   g_state.initial_risk =
      MathAbs(
         fillPrice -
         plannedSL
      );

   g_state.open_time =
      openTime;

   g_state.mfe_price =
      fillPrice;

   g_state.mae_price =
      fillPrice;

   g_state.mfe_usd =
      0.0;

   g_state.mae_usd =
      0.0;

   g_state.tp1_done =
      false;

   g_state.open_event_sent =
      false;

   ResetPendingState();

   SaveTrackedState();

   SendOpenEvent();

   AckSignal(
      signalId,
      "executed"
   );

   Print(
      "Pending order filled and attached to R2 tracking. Signal=",
      signalId,
      " PositionID=",
      identifier,
      " Fill=",
      DoubleToString(
         fillPrice,
         _Digits
      )
   );

   return true;
}


void CheckPendingTrade()
{
   if(!g_pending.active)
      return;

   // Filled position may appear before the old order disappears.
   if(ActivateFilledPendingPosition())
      return;

   bool orderStillLive =
      OrderSelect(
         g_pending.order_ticket
      );

   if(orderStillLive)
   {
      string invalidationReason = "";

      if(
         PendingSetupInvalidated(
            invalidationReason
         )
      )
      {
         if(
            trade.OrderDelete(
               g_pending.order_ticket
            )
         )
         {
            AckSignal(
               g_pending.signal_id,
               "rejected"
            );

            Print(
               "Pending setup invalidated and order removed. Signal=",
               g_pending.signal_id,
               " Reason=",
               invalidationReason
            );

            ClearPendingState();
         }
         else
         {
            Print(
               "Pending invalidation detected but OrderDelete failed. Signal=",
               g_pending.signal_id,
               " Retcode=",
               trade.ResultRetcode(),
               " ",
               trade.ResultRetcodeDescription(),
               " Reason=",
               invalidationReason
            );
         }

         return;
      }

      long nowMs =
         (long)
         TimeGMT() *
         1000;

      if(
         g_pending.expires_at_ms > 0 &&
         nowMs >
         g_pending.expires_at_ms + 5000
      )
      {
         if(
            trade.OrderDelete(
               g_pending.order_ticket
            )
         )
         {
            AckSignal(
               g_pending.signal_id,
               "expired"
            );

            Print(
               "Expired pending order removed. Signal=",
               g_pending.signal_id
            );

            ClearPendingState();
         }
      }

      return;
   }

   // One more attempt in case the position appeared on the same transaction.
   if(ActivateFilledPendingPosition())
      return;

   string finalStatus =
      "rejected";

   if(
      HistoryOrderSelect(
         g_pending.order_ticket
      )
   )
   {
      ENUM_ORDER_STATE state =
         (ENUM_ORDER_STATE)
         HistoryOrderGetInteger(
            g_pending.order_ticket,
            ORDER_STATE
         );

      if(state == ORDER_STATE_EXPIRED)
         finalStatus = "expired";

      if(state == ORDER_STATE_FILLED)
      {
         // History can be visible a fraction before PositionSelect.
         return;
      }
   }

   AckSignal(
      g_pending.signal_id,
      finalStatus
   );

   Print(
      "Pending order is no longer active. Signal=",
      g_pending.signal_id,
      " Status=",
      finalStatus
   );

   ClearPendingState();
}


// ============================================================
// R2 POSITION MANAGEMENT
// ============================================================

double NormalizeVolumeForSymbol(
   double volume
)
{
   double minLot =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_VOLUME_MIN
      );

   double maxLot =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_VOLUME_MAX
      );

   double step =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_VOLUME_STEP
      );

   if(step <= 0.0)
      step = 0.01;

   volume =
      MathMax(
         minLot,
         MathMin(
            maxLot,
            volume
         )
      );

   volume =
      MathFloor(
         (
            volume +
            1e-12
         ) /
         step
      ) *
      step;

   return NormalizeDouble(
      volume,
      2
   );
}


bool ClosePartialTrackedPosition(
   double requestedVolume
)
{
   if(
      !g_state.active ||
      !SelectTrackedPosition()
   )
   {
      return false;
   }

   ulong positionTicket =
      (ulong)
      PositionGetInteger(
         POSITION_TICKET
      );

   double currentVolume =
      PositionGetDouble(
         POSITION_VOLUME
      );

   double minLot =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_VOLUME_MIN
      );

   double step =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_VOLUME_STEP
      );

   if(step <= 0.0)
      step = 0.01;

   double closeVolume =
      MathFloor(
         requestedVolume /
         step
      ) *
      step;

   closeVolume =
      NormalizeDouble(
         closeVolume,
         2
      );

   double remaining =
      NormalizeDouble(
         currentVolume -
         closeVolume,
         2
      );

   // If broker volume granularity cannot support a runner,
   // close the whole position at TP1 instead of creating invalid volume.
   if(
      closeVolume < minLot ||
      remaining < minLot
   )
   {
      Print(
         "TP1 partial split is smaller than broker minimum. Closing full position at TP1."
      );

      return trade.PositionClose(
         positionTicket
      );
   }

   ENUM_ACCOUNT_MARGIN_MODE marginMode =
      (ENUM_ACCOUNT_MARGIN_MODE)
      AccountInfoInteger(
         ACCOUNT_MARGIN_MODE
      );

   bool success = false;

   if(
      marginMode ==
      ACCOUNT_MARGIN_MODE_RETAIL_HEDGING
   )
   {
      success =
         trade.PositionClosePartial(
            positionTicket,
            closeVolume
         );
   }
   else
   {
      if(g_state.side == "BUY")
      {
         success =
            trade.Sell(
               closeVolume,
               _Symbol,
               0.0,
               0.0,
               0.0,
               "XAUBridge_TP1"
            );
      }
      else
      {
         success =
            trade.Buy(
               closeVolume,
               _Symbol,
               0.0,
               0.0,
               0.0,
               "XAUBridge_TP1"
            );
      }
   }

   if(!success)
   {
      Print(
         "TP1 partial close failed. Retcode=",
         trade.ResultRetcode(),
         " ",
         trade.ResultRetcodeDescription()
      );
   }

   return success;
}


double FindLatestConfirmedM15Structure(
   string side
)
{
   MqlRates rates[];

   ArraySetAsSeries(
      rates,
      true
   );

   int copied =
      CopyRates(
         _Symbol,
         PERIOD_M15,
         1,
         40,
         rates
      );

   if(copied < 7)
      return 0.0;

   for(
      int i = 2;
      i <= copied - 3;
      i++
   )
   {
      if(
         rates[i].time <=
         g_state.open_time
      )
      {
         continue;
      }

      if(side == "BUY")
      {
         bool pivotLow =
            rates[i].low <
            rates[i - 1].low &&
            rates[i].low <
            rates[i - 2].low &&
            rates[i].low <=
            rates[i + 1].low &&
            rates[i].low <=
            rates[i + 2].low;

         if(pivotLow)
            return rates[i].low;
      }
      else
      {
         bool pivotHigh =
            rates[i].high >
            rates[i - 1].high &&
            rates[i].high >
            rates[i - 2].high &&
            rates[i].high >=
            rates[i + 1].high &&
            rates[i].high >=
            rates[i + 2].high;

         if(pivotHigh)
            return rates[i].high;
      }
   }

   return 0.0;
}


bool TrailBehindM15Structure()
{
   if(
      !g_state.active ||
      !SelectTrackedPosition()
   )
   {
      return false;
   }

   double structure =
      FindLatestConfirmedM15Structure(
         g_state.side
      );

   if(structure <= 0.0)
      return false;

   MqlTick tick;

   if(
      !SymbolInfoTick(
         _Symbol,
         tick
      )
   )
   {
      return false;
   }

   long stopLevelPoints =
      SymbolInfoInteger(
         _Symbol,
         SYMBOL_TRADE_STOPS_LEVEL
      );

   double brokerDistance =
      stopLevelPoints *
      _Point;

   double spreadDistance =
      MathMax(
         0.0,
         tick.ask -
         tick.bid
      );

   double buffer =
      MathMax(
         brokerDistance,
         spreadDistance *
         1.5
      );

   if(buffer < _Point)
      buffer = _Point;

   double newSL = 0.0;

   if(g_state.side == "BUY")
   {
      newSL =
         structure -
         buffer;

      if(
         newSL <=
         g_state.sl + _Point ||
         newSL >=
         tick.bid - brokerDistance
      )
      {
         return false;
      }
   }
   else
   {
      newSL =
         structure +
         buffer;

      if(
         (
            g_state.sl > 0.0 &&
            newSL >=
            g_state.sl - _Point
         ) ||
         newSL <=
         tick.ask + brokerDistance
      )
      {
         return false;
      }
   }

   newSL =
      NormalizeDouble(
         newSL,
         _Digits
      );

   ulong positionTicket =
      (ulong)
      PositionGetInteger(
         POSITION_TICKET
      );

   double finalTP =
      g_state.tp2 > 0.0
      ? g_state.tp2
      : PositionGetDouble(
           POSITION_TP
        );

   if(
      !trade.PositionModify(
         positionTicket,
         newSL,
         finalTP
      )
   )
   {
      Print(
         "R2 structure SL modification failed. Retcode=",
         trade.ResultRetcode(),
         " ",
         trade.ResultRetcodeDescription()
      );

      return false;
   }

   g_state.sl =
      newSL;

   SaveTrackedState();

   Print(
      "R2 SL moved behind confirmed M15 structure. New SL=",
      DoubleToString(
         newSL,
         _Digits
      )
   );

   return true;
}


void ManageR2Trade()
{
   if(
      !InpEnableR2StructureManagement ||
      !g_state.active ||
      !SelectTrackedPosition()
   )
   {
      return;
   }

   MqlTick tick;

   if(
      !SymbolInfoTick(
         _Symbol,
         tick
      )
   )
   {
      return;
   }

   double currentPrice =
      g_state.side == "BUY"
      ? tick.bid
      : tick.ask;

   double favorableMove =
      g_state.side == "BUY"
      ? currentPrice -
        g_state.entry
      : g_state.entry -
        currentPrice;

   double currentR =
      g_state.initial_risk > 0.0
      ? favorableMove /
        g_state.initial_risk
      : 0.0;

   bool hitTP1 =
      g_state.side == "BUY"
      ? currentPrice >=
        g_state.tp1
      : currentPrice <=
        g_state.tp1;

   if(
      !g_state.tp1_done &&
      g_state.tp1 > 0.0 &&
      hitTP1
   )
   {
      double currentVolume =
         PositionGetDouble(
            POSITION_VOLUME
         );

      double fraction =
         MathMax(
            0.0,
            MathMin(
               100.0,
               InpTP1ClosePercent
            )
         ) /
         100.0;

      double requestedClose =
         currentVolume *
         fraction;

      if(
         ClosePartialTrackedPosition(
            requestedClose
         )
      )
      {
         // If the full position was closed because broker min lot
         // prevented a partial runner, CheckTrackedTrade will
         // complete the CLOSE event on the next timer cycle.
         if(SelectTrackedPosition())
         {
            g_state.lot =
               PositionGetDouble(
                  POSITION_VOLUME
               );

            g_state.tp1_done =
               true;

            SaveTrackedState();

            Print(
               "TP1 reached. Partial close completed. Runner volume=",
               DoubleToString(
                  g_state.lot,
                  2
               )
            );

            // After TP1, protect the runner only if a confirmed
            // M15 structure exists. No blind breakeven.
            TrailBehindM15Structure();
         }

         return;
      }
   }

   // Active management begins around +1R, but only behind
   // confirmed M15 structure. No fixed trailing and no blind BE.
   if(
      currentR >= 1.0 ||
      g_state.tp1_done
   )
   {
      TrailBehindM15Structure();
   }
}


// ============================================================
// TRADE TRANSACTION HOOK
// ============================================================

void OnTradeTransaction(
   const MqlTradeTransaction &trans,
   const MqlTradeRequest &request,
   const MqlTradeResult &result
)
{
   if(g_pending.active)
      ActivateFilledPendingPosition();

   if(g_state.active)
      CheckTrackedTrade();
}


// ============================================================
// SIGNAL ACK
// ============================================================

void AckSignal(
   string signalId,
   string statusText
)
{
   string payload = "{";

   payload +=
      "\"signal_id\":\"" +
      JsonEscape(
         signalId
      ) +
      "\",";

   payload +=
      "\"status\":\"" +
      JsonEscape(
         statusText
      ) +
      "\"";

   payload += "}";

   string response = "";

   int status =
      HttpPostJson(
         InpWorkerBaseURL +
         "/signal/ack",
         payload,
         response
      );

   if(
      status < 200 ||
      status >= 300
   )
   {
      Print(
         "Signal ACK failed. HTTP=",
         status,
         " response=",
         response
      );
   }
}


// ============================================================
// SAVE STATE
// ============================================================

void SaveTrackedState()
{
   if(
      !g_state.active &&
      !g_pending.active
   )
   {
      if(
         FileIsExist(
            g_stateFile,
            FILE_COMMON
         )
      )
      {
         FileDelete(
            g_stateFile,
            FILE_COMMON
         );
      }

      return;
   }

   int handle =
      FileOpen(
         g_stateFile,
         FILE_WRITE |
         FILE_TXT |
         FILE_ANSI |
         FILE_COMMON
      );

   if(
      handle ==
      INVALID_HANDLE
   )
   {
      Print(
         "Could not save R2 tracking state."
      );

      return;
   }

   FileWrite(handle, "R2V2");

   // Active position state
   FileWrite(handle, g_state.active ? "1" : "0");
   FileWrite(handle, g_state.signal_id);
   FileWrite(handle, IntegerToString((long)g_state.position_id));
   FileWrite(handle, IntegerToString((long)g_state.open_deal_id));
   FileWrite(handle, g_state.side);
   FileWrite(handle, DoubleToString(g_state.entry, _Digits));
   FileWrite(handle, DoubleToString(g_state.sl, _Digits));
   FileWrite(handle, DoubleToString(g_state.tp1, _Digits));
   FileWrite(handle, DoubleToString(g_state.tp2, _Digits));
   FileWrite(handle, DoubleToString(g_state.initial_lot, 2));
   FileWrite(handle, DoubleToString(g_state.lot, 2));
   FileWrite(handle, DoubleToString(g_state.initial_risk, 4));
   FileWrite(handle, IntegerToString(g_state.open_time));
   FileWrite(handle, DoubleToString(g_state.mfe_price, _Digits));
   FileWrite(handle, DoubleToString(g_state.mae_price, _Digits));
   FileWrite(handle, DoubleToString(g_state.mfe_usd, 4));
   FileWrite(handle, DoubleToString(g_state.mae_usd, 4));
   FileWrite(handle, g_state.tp1_done ? "1" : "0");
   FileWrite(handle, g_state.open_event_sent ? "1" : "0");

   // Pending state
   FileWrite(handle, g_pending.active ? "1" : "0");
   FileWrite(handle, g_pending.signal_id);
   FileWrite(handle, IntegerToString((long)g_pending.order_ticket));
   FileWrite(handle, g_pending.side);
   FileWrite(handle, DoubleToString(g_pending.entry, _Digits));
   FileWrite(handle, DoubleToString(g_pending.sl, _Digits));
   FileWrite(handle, DoubleToString(g_pending.tp1, _Digits));
   FileWrite(handle, DoubleToString(g_pending.tp2, _Digits));
   FileWrite(handle, DoubleToString(g_pending.lot, 2));
   FileWrite(handle, IntegerToString(g_pending.expires_at_ms));

   FileClose(handle);
}


// ============================================================
// LOAD STATE
// ============================================================

bool LoadTrackedState()
{
   if(
      !FileIsExist(
         g_stateFile,
         FILE_COMMON
      )
   )
   {
      return false;
   }

   int handle =
      FileOpen(
         g_stateFile,
         FILE_READ |
         FILE_TXT |
         FILE_ANSI |
         FILE_COMMON
      );

   if(
      handle ==
      INVALID_HANDLE
   )
   {
      return false;
   }

   ResetTrackedState();
   ResetPendingState();

   if(FileIsEnding(handle))
   {
      FileClose(handle);
      return false;
   }

   string version =
      FileReadString(handle);

   if(version != "R2V2")
   {
      FileClose(handle);

      Print(
         "Ignoring incompatible old EA state file."
      );

      return false;
   }

   g_state.active =
      FileReadString(handle) == "1";

   g_state.signal_id =
      FileReadString(handle);

   g_state.position_id =
      (ulong)
      StringToInteger(
         FileReadString(handle)
      );

   g_state.open_deal_id =
      (ulong)
      StringToInteger(
         FileReadString(handle)
      );

   g_state.side =
      FileReadString(handle);

   g_state.entry =
      StringToDouble(
         FileReadString(handle)
      );

   g_state.sl =
      StringToDouble(
         FileReadString(handle)
      );

   g_state.tp1 =
      StringToDouble(
         FileReadString(handle)
      );

   g_state.tp2 =
      StringToDouble(
         FileReadString(handle)
      );

   g_state.initial_lot =
      StringToDouble(
         FileReadString(handle)
      );

   g_state.lot =
      StringToDouble(
         FileReadString(handle)
      );

   g_state.initial_risk =
      StringToDouble(
         FileReadString(handle)
      );

   g_state.open_time =
      (datetime)
      StringToInteger(
         FileReadString(handle)
      );

   g_state.mfe_price =
      StringToDouble(
         FileReadString(handle)
      );

   g_state.mae_price =
      StringToDouble(
         FileReadString(handle)
      );

   g_state.mfe_usd =
      StringToDouble(
         FileReadString(handle)
      );

   g_state.mae_usd =
      StringToDouble(
         FileReadString(handle)
      );

   g_state.tp1_done =
      FileReadString(handle) == "1";

   g_state.open_event_sent =
      FileReadString(handle) == "1";

   g_pending.active =
      FileReadString(handle) == "1";

   g_pending.signal_id =
      FileReadString(handle);

   g_pending.order_ticket =
      (ulong)
      StringToInteger(
         FileReadString(handle)
      );

   g_pending.side =
      FileReadString(handle);

   g_pending.entry =
      StringToDouble(
         FileReadString(handle)
      );

   g_pending.sl =
      StringToDouble(
         FileReadString(handle)
      );

   g_pending.tp1 =
      StringToDouble(
         FileReadString(handle)
      );

   g_pending.tp2 =
      StringToDouble(
         FileReadString(handle)
      );

   g_pending.lot =
      StringToDouble(
         FileReadString(handle)
      );

   g_pending.expires_at_ms =
      (long)
      StringToInteger(
         FileReadString(handle)
      );

   FileClose(handle);

   if(g_state.active)
   {
      Print(
         "Recovered R2 position. Signal=",
         g_state.signal_id,
         " PositionID=",
         g_state.position_id
      );
   }

   if(g_pending.active)
   {
      Print(
         "Recovered R2 pending order. Signal=",
         g_pending.signal_id,
         " Order=",
         g_pending.order_ticket
      );
   }

   return(
      g_state.active ||
      g_pending.active
   );
}


// ============================================================
// CLEAR / RESET STATE
// ============================================================

void ClearTrackedState()
{
   ResetTrackedState();
   SaveTrackedState();
}


void ClearPendingState()
{
   ResetPendingState();
   SaveTrackedState();
}


void ResetTrackedState()
{
   g_state.active =
      false;

   g_state.signal_id =
      "";

   g_state.position_id =
      0;

   g_state.open_deal_id =
      0;

   g_state.side =
      "";

   g_state.entry =
      0.0;

   g_state.sl =
      0.0;

   g_state.tp1 =
      0.0;

   g_state.tp2 =
      0.0;

   g_state.initial_lot =
      0.0;

   g_state.lot =
      0.0;

   g_state.initial_risk =
      0.0;

   g_state.open_time =
      0;

   g_state.mfe_price =
      0.0;

   g_state.mae_price =
      0.0;

   g_state.mfe_usd =
      0.0;

   g_state.mae_usd =
      0.0;

   g_state.tp1_done =
      false;

   g_state.open_event_sent =
      false;
}


void ResetPendingState()
{
   g_pending.active =
      false;

   g_pending.signal_id =
      "";

   g_pending.order_ticket =
      0;

   g_pending.side =
      "";

   g_pending.entry =
      0.0;

   g_pending.sl =
      0.0;

   g_pending.tp1 =
      0.0;

   g_pending.tp2 =
      0.0;

   g_pending.lot =
      0.0;

   g_pending.expires_at_ms =
      0;
}


// ============================================================
// HTTP GET
// ============================================================

int HttpGet(
   string url,
   string &response
)
{
   char data[];
   char result[];

   ArrayResize(
      data,
      0
   );

   string responseHeaders = "";

   string headers =
      "X-Bridge-Key: " +
      InpWriteToken +
      "\r\n" +
      "Cache-Control: no-cache\r\n";

   ResetLastError();

   int status =
      WebRequest(
         "GET",
         url,
         headers,
         InpTimeoutMs,
         data,
         result,
         responseHeaders
      );

   if(status == -1)
   {
      Print(
         "GET WebRequest error: ",
         GetLastError(),
         " URL=",
         url
      );

      response = "";

      return -1;
   }

   response =
      CharArrayToString(
         result,
         0,
         -1,
         CP_UTF8
      );

   return status;
}


// ============================================================
// HTTP POST JSON
// ============================================================

int HttpPostJson(
   string url,
   string payload,
   string &response
)
{
   char data[];
   char result[];

   int converted =
      StringToCharArray(
         payload,
         data,
         0,
         WHOLE_ARRAY,
         CP_UTF8
      );

   if(converted > 0)
   {
      ArrayResize(
         data,
         converted - 1
      );
   }

   string responseHeaders = "";

   string headers =
      "Content-Type: application/json\r\n" +
      "X-Bridge-Key: " +
      InpWriteToken +
      "\r\n" +
      "Cache-Control: no-cache\r\n";

   ResetLastError();

   int status =
      WebRequest(
         "POST",
         url,
         headers,
         InpTimeoutMs,
         data,
         result,
         responseHeaders
      );

   if(status == -1)
   {
      Print(
         "POST WebRequest error: ",
         GetLastError(),
         " URL=",
         url
      );

      response = "";

      return -1;
   }

   response =
      CharArrayToString(
         result,
         0,
         -1,
         CP_UTF8
      );

   return status;
}


// ============================================================
// JSON GET STRING
// ============================================================

string JsonGetString(
   string json,
   string key
)
{
   string needle =
      "\"" +
      key +
      "\"";

   int keyPos =
      StringFind(
         json,
         needle
      );

   if(keyPos < 0)
      return "";

   int colon =
      StringFind(
         json,
         ":",
         keyPos +
         StringLen(
            needle
         )
      );

   if(colon < 0)
      return "";

   int firstQuote =
      StringFind(
         json,
         "\"",
         colon + 1
      );

   if(firstQuote < 0)
      return "";

   int secondQuote =
      StringFind(
         json,
         "\"",
         firstQuote + 1
      );

   if(secondQuote < 0)
      return "";

   return StringSubstr(
      json,
      firstQuote + 1,
      secondQuote -
      firstQuote -
      1
   );
}


// ============================================================
// JSON GET DOUBLE
// ============================================================

double JsonGetDouble(
   string json,
   string key
)
{
   string needle =
      "\"" +
      key +
      "\"";

   int keyPos =
      StringFind(
         json,
         needle
      );

   if(keyPos < 0)
      return 0.0;

   int colon =
      StringFind(
         json,
         ":",
         keyPos +
         StringLen(
            needle
         )
      );

   if(colon < 0)
      return 0.0;

   int pos =
      colon + 1;

   int len =
      StringLen(
         json
      );

   while(
      pos < len
   )
   {
      ushort ch =
         StringGetCharacter(
            json,
            pos
         );

      if(
         ch == ' ' ||
         ch == '\t'
      )
      {
         pos++;
      }
      else
      {
         break;
      }
   }

   int end =
      pos;

   while(
      end < len
   )
   {
      ushort ch =
         StringGetCharacter(
            json,
            end
         );

      if(
         ch == ',' ||
         ch == '}' ||
         ch == ']'
      )
      {
         break;
      }

      end++;
   }

   string numberText =
      StringSubstr(
         json,
         pos,
         end - pos
      );

   StringReplace(
      numberText,
      "\"",
      ""
   );

   return StringToDouble(
      numberText
   );
}


// ============================================================
// STRING TO UPPER
// ============================================================

string StringToUpperCopy(
   string value
)
{
   StringToUpper(
      value
   );

   return value;
}


// ============================================================
// JSON ESCAPE
// ============================================================

string JsonEscape(
   string value
)
{
   StringReplace(
      value,
      "\\",
      "\\\\"
   );

   StringReplace(
      value,
      "\"",
      "\\\""
   );

   StringReplace(
      value,
      "\r",
      "\\r"
   );

   StringReplace(
      value,
      "\n",
      "\\n"
   );

   return value;
}