// XAU Advanced Bridge R2 Swing v2
// Pending lifecycle + TP1/TP2 + structural M15 management
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
