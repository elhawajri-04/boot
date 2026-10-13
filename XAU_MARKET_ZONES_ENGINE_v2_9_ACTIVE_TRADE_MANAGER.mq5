// XAU Market Zones Engine v2.9 ACTIVE TRADE MANAGER
// Does NOT open trades from zone signals.
// It may automatically attach SL/TP protection to open XAU positions when enabled.
// Sends multi-timeframe market snapshots to the Worker, draws locked zones,
// visualizes readiness, and manages protection for existing positions.

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

input bool InpShowZoneEngineStatus = true;
input bool InpShowZoneStrengthReasons = true;
input bool InpCleanChartMode = true;
input bool InpShowR2TradeLevels = false;
input bool InpShowCompactPanel = true;

// Clean panel layout.
// Defaults place the panel BELOW MT5 one-click trading controls.
input ENUM_BASE_CORNER InpPanelCorner = CORNER_LEFT_UPPER;
input int InpPanelX = 12;
input int InpPanelY = 118;
input int InpPanelWidth = 320;
input int InpPanelHeight = 198;
input int InpPanelRowHeight = 18;
input int InpPanelFontSize = 9;
input int InpPanelTitleFontSize = 11;

input color InpPanelBgColor = C'18,22,27';
input color InpPanelBorderColor = C'62,72,82';
input color InpPanelTextColor = C'226,231,235';
input color InpPanelMutedColor = C'158,168,178';
input color InpPanelBuyColor = C'76,190,125';
input color InpPanelSellColor = C'232,96,96';
input color InpPanelWaitColor = C'229,184,75';
input color InpPanelWarningColor = C'232,151,76';

// HARD SAFETY:
// Zone-signal trade opening remains disabled in code.
// v2.7 can ONLY modify SL/TP protection on already-open positions.


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
input int InpMaxPendingOrders = 1;


// Hard safety ceiling
input double InpSafetyMaxLot = 1.00;


// Optional market-order drift protection.
// 0.0 disables the old scalp-style $1 drift restriction.
input double InpMaxMarketEntryDriftUSD = 0.00;

// R2 trade management
input double InpTP1ClosePercent = 50.0;
input bool InpEnableR2StructureManagement = true;
input int InpStructureCheckEverySeconds = 15;

// R1 scalp/watch reference zones from Worker /zones/latest.
// Keep OFF during normal R2 swing trading. Turn ON only when R1/scalp zones are requested.
input bool InpDrawDecisionZones = true;
input int InpZonePollEverySeconds = 5;
input bool InpAlertOnZoneEntry = true;
input color InpBuyZoneColor = clrLimeGreen;
input color InpSellZoneColor = clrTomato;
input color InpR1ArmedTriggerColor = clrGold;
input color InpZoneInvalidationColor = clrGold;

// Persistent zone lifecycle.
// Once a BUY/SELL zone is accepted, its side + price band are frozen.
// A later Worker refresh cannot flip or move that zone.
// A new opposite-side zone may appear only as a separate secondary zone.
input bool InpLockZoneIdentity = true;
input bool InpPersistZoneLifecycle = true;
input bool InpResetPersistentZonesOnInit = false;
// 0 = no time expiry; structural invalidation is authoritative.
input double InpPersistentZoneMaxAgeHours = 0.0;

// Simple decision layer.
// The locked zones stay analytical; this layer gives one clear action.
// One practical M5 confirmation is enough. R2 opposite bias is caution only.
input bool   InpSimpleDecisionMode = true;
input int    InpSimpleConfirmLookbackM5Bars = 3;
input double InpSimpleRR = 2.0;
input double InpSimpleSLBufferZoneFraction = 0.25;
input int    InpR2OppositeCautionScore = 70;

// READY latch: once a valid decision appears, do not erase it on the next candle.
// If the user opens a position on this symbol, the panel switches to ACTIVE.
input bool   InpLatchReadySignal = true;
input int    InpReadyLatchMinutes = 30;

// Automatic broker-side protection for already-open positions.
// Missing-only is safest: manual SL/TP levels are never overwritten by default.
input bool   InpAutoProtectPositions = true;
input bool   InpAutoSetActualSL = true;
input bool   InpAutoSetActualTP = true;
input bool   InpAutoProtectExistingPositions = true;
input bool   InpOverwriteExistingProtection = false;

// Active trade manager.
// Works on ALL open positions for the current XAU symbol, including manual trades.
// Stage 1: at +1R, close part of the basket and move survivors to protected BE.
// Stage 2: from +1.5R, trail profit using R-based steps.
// Final TP remains the actual 2R TP already attached to each position.
input bool   InpEnableActiveTradeManager = true;
input bool   InpManagerEnablePartialClose = true;
input double InpManagerPartialAtR = 1.0;
input double InpManagerPartialClosePercent = 50.0;
input bool   InpManagerMoveToBE = true;
input double InpManagerBEAtR = 1.0;
input double InpManagerBEPlusR = 0.05;
input bool   InpManagerEnableTrailing = true;
input double InpManagerTrailStartR = 1.5;
input double InpManagerTrailGapR = 0.50;
input double InpManagerTrailStepR = 0.25;

// R2 live setup visualization from /r2
input bool InpDrawR2Setup = true;
input int InpR2PollEverySeconds = 5;
input color InpR2BuyZoneColor = clrDeepSkyBlue;
input color InpR2SellZoneColor = clrOrangeRed;
input color InpR2EntryColor = clrDodgerBlue;
input color InpR2SLColor = clrRed;
input color InpR2TP1Color = clrLimeGreen;
input color InpR2TP2Color = clrGreen;
input color InpR2BreakoutColor = clrGold;
input color InpR2InvalidationColor = clrDarkOrange;
input color InpR2InfoColor = clrWhite;


// ============================================================
// GLOBALS
// ============================================================

datetime g_lastMarketSend = 0;
datetime g_lastSignalPoll = 0;

string g_lastHandledSignal = "";

datetime g_lastZonePoll = 0;

string g_zoneAnalysisId = "";
string g_zoneType = "";
string g_zoneWatchReason = "";
string g_r2AuditStatus = "WATCH";
string g_r2AuditReason = "";
string g_r2Trigger = "NONE";
int g_r2TriggerCount = 0;
bool g_r2TriggerReady = false;

int g_buyTriggerCount = 0;
string g_buyTrigger1 = "NONE";
string g_buyTrigger2 = "NONE";
int g_sellTriggerCount = 0;
string g_sellTrigger1 = "NONE";
string g_sellTrigger2 = "NONE";

double g_buyZoneLow = 0.0;
double g_buyZoneHigh = 0.0;
double g_sellZoneLow = 0.0;
double g_sellZoneHigh = 0.0;

double g_buyInvalidation = 0.0;
double g_sellInvalidation = 0.0;
string g_buyInvalidationTf = "";
string g_sellInvalidationTf = "";
string g_buyInvalidationRule = "";
string g_sellInvalidationRule = "";
string g_buyInvalidationReason = "";
string g_sellInvalidationReason = "";

bool g_insideBuyZone = false;
bool g_insideSellZone = false;

// ============================================================
// PERSISTENT ZONE LIFECYCLE
// ============================================================

struct PersistentZoneState
{
   bool active;
   string side;
   string zone_id;
   string source_analysis_id;
   string zone_type;
   string watch_reason;
   double low;
   double high;
   double invalidation;
   string invalidation_tf;
   string invalidation_rule;
   string invalidation_reason;
   datetime created_at;
   datetime last_seen_at;
};

PersistentZoneState g_pBuyZone;
PersistentZoneState g_pSellZone;
string g_lockedPrimarySide = "";
string g_dynamicFocusSide = "";
string g_focusReason = "";

string g_simpleDecision = "WAIT";
string g_simpleDecisionSide = "NONE";
string g_simpleConfirmText = "NONE";
string g_simpleWhy = "";
string g_recentZoneSide = "NONE";
datetime g_recentZoneTouchTime = 0;
double g_simpleEntry = 0.0;
double g_simpleSL = 0.0;
double g_simpleTP = 0.0;

// Latched decision state.
bool     g_readyLatched = false;
string   g_latchedSide = "NONE";
string   g_latchedWhy = "";
double   g_latchedEntry = 0.0;
double   g_latchedSL = 0.0;
double   g_latchedTP = 0.0;
datetime g_latchedAt = 0;

// Aggregated ACTIVE position dashboard state.
int    g_activePositionCount = 0;
int    g_activeBuyCount = 0;
int    g_activeSellCount = 0;
double g_activeTotalVolume = 0.0;
double g_activeAvgEntry = 0.0;
double g_activeFloatingPnL = 0.0;
string g_activeSLState = "NOT SET";
string g_activeTPState = "NOT SET";
double g_activeSLValue = 0.0;
double g_activeTPValue = 0.0;
double g_activePlanSLGuide = 0.0;
double g_activePlanTPGuide = 0.0;

// Auto-protection runtime state.
bool   g_protectionScanRequested = true;
int    g_protectionAppliedLastScan = 0;
int    g_protectionFailedLastScan = 0;
string g_protectionStatus = "IDLE";

// Active trade manager runtime + persistent basket state.
string   g_managerFile = "";
bool     g_managerBasketActive = false;
string   g_managerSide = "NONE";
double   g_managerInitialVolume = 0.0;
int      g_managerInitialPositions = 0;
bool     g_managerTP1Done = false;
datetime g_managerStartedAt = 0;
double   g_managerBasketR = 0.0;
string   g_managerStatus = "OFF";

string g_zoneLifecycleFile = "";
string g_lastZoneLifecycleEvent = "";

string ZONE_BUY_OBJECT = "R1_BUY_WAIT_ZONE";
string ZONE_SELL_OBJECT = "R1_SELL_WAIT_ZONE";

string R1_BUY_LOW_LINE = "R1_BUY_ZONE_LOW";
string R1_BUY_HIGH_LINE = "R1_BUY_ZONE_HIGH";
string R1_SELL_LOW_LINE = "R1_SELL_ZONE_LOW";
string R1_SELL_HIGH_LINE = "R1_SELL_ZONE_HIGH";
string R1_BUY_INVALIDATION_LINE = "R1_BUY_INVALIDATION";
string R1_SELL_INVALIDATION_LINE = "R1_SELL_INVALIDATION";
string R1_ARMED_TRIGGER_LINE = "R1_ARMED_TRIGGER";
string R1_ARMED_SL_LINE = "R1_ARMED_SL";
string R1_ARMED_TP_LINE = "R1_ARMED_TP";

string g_r1ArmedState = "";
string g_r1ArmedSide = "";
string g_r1ArmedOrderType = "";
double g_r1ArmedEntry = 0.0;
double g_r1ArmedSL = 0.0;
double g_r1ArmedTP = 0.0;
double g_r1ArmedRR = 0.0;

// R2 visual state
datetime g_lastR2Poll = 0;
string g_r2MarketState = "";
string g_r2Strategy = "";
string g_r2OrderType = "";
string g_r2Side = "";
double g_r2ZoneLow = 0.0;
double g_r2ZoneHigh = 0.0;
double g_r2Entry = 0.0;
double g_r2SL = 0.0;
double g_r2TP1 = 0.0;
double g_r2TP2 = 0.0;
double g_r2BreakoutLevel = 0.0;
double g_r2Invalidation = 0.0;
double g_r2RR = 0.0;
double g_r2ExpiryHours = 0.0;
int g_r2Score = 0;
bool g_r2Allowed = false;

string R2_ZONE_OBJECT = "R2_ACTIVE_ZONE";
string R2_ENTRY_OBJECT = "R2_ENTRY";
string R2_SL_OBJECT = "R2_SL";
string R2_TP1_OBJECT = "R2_TP1";
string R2_TP2_OBJECT = "R2_TP2";
string R2_BREAKOUT_OBJECT = "R2_BREAKOUT_LEVEL";
string R2_INVALIDATION_OBJECT = "R2_INVALIDATION";
string R2_INFO_OBJECT = "R2_INFO";
string ZONE_PANEL_OBJECT = "ZONE_ENGINE_PANEL";
string ZONE_PANEL_HEADER_OBJECT = "ZONE_ENGINE_PANEL_HEADER";
string ZONE_PANEL_ROW_PREFIX = "ZONE_ENGINE_ROW_";


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
// PERSISTENT ZONE LIFECYCLE HELPERS
// ============================================================

void ResetPersistentZone(PersistentZoneState &z)
{
   z.active = false;
   z.side = "";
   z.zone_id = "";
   z.source_analysis_id = "";
   z.zone_type = "";
   z.watch_reason = "";
   z.low = 0.0;
   z.high = 0.0;
   z.invalidation = 0.0;
   z.invalidation_tf = "";
   z.invalidation_rule = "";
   z.invalidation_reason = "";
   z.created_at = 0;
   z.last_seen_at = 0;
}

ENUM_TIMEFRAMES ZoneTimeframeFromText(string tf)
{
   string value = tf;
   StringToUpper(value);

   if(value == "M1")  return PERIOD_M1;
   if(value == "M5")  return PERIOD_M5;
   if(value == "M15") return PERIOD_M15;
   if(value == "M30") return PERIOD_M30;
   if(value == "H1")  return PERIOD_H1;
   if(value == "H4")  return PERIOD_H4;
   if(value == "D1")  return PERIOD_D1;

   return PERIOD_M5;
}

double LastClosedZoneTFPrice(string tf)
{
   ENUM_TIMEFRAMES timeframe = ZoneTimeframeFromText(tf);
   return iClose(_Symbol, timeframe, 1);
}

bool PersistentZoneStructurallyInvalidated(PersistentZoneState &z)
{
   if(!z.active || z.invalidation <= 0.0)
      return false;

   double closedPrice = LastClosedZoneTFPrice(z.invalidation_tf);
   if(closedPrice <= 0.0)
      return false;

   if(z.side == "BUY")
      return closedPrice < z.invalidation;

   if(z.side == "SELL")
      return closedPrice > z.invalidation;

   return false;
}

bool PersistentZoneExpired(PersistentZoneState &z)
{
   if(
      !z.active ||
      InpPersistentZoneMaxAgeHours <= 0.0 ||
      z.created_at <= 0
   )
      return false;

   double ageSeconds =
      (double)(TimeCurrent() - z.created_at);

   return
      ageSeconds >=
      InpPersistentZoneMaxAgeHours * 3600.0;
}

void WritePersistentZoneState(int handle, PersistentZoneState &z)
{
   FileWrite(handle, z.active ? "1" : "0");
   FileWrite(handle, z.side);
   FileWrite(handle, z.zone_id);
   FileWrite(handle, z.source_analysis_id);
   FileWrite(handle, z.zone_type);
   FileWrite(handle, z.watch_reason);
   FileWrite(handle, DoubleToString(z.low, _Digits));
   FileWrite(handle, DoubleToString(z.high, _Digits));
   FileWrite(handle, DoubleToString(z.invalidation, _Digits));
   FileWrite(handle, z.invalidation_tf);
   FileWrite(handle, z.invalidation_rule);
   FileWrite(handle, z.invalidation_reason);
   FileWrite(handle, IntegerToString((long)z.created_at));
   FileWrite(handle, IntegerToString((long)z.last_seen_at));
}

bool ReadPersistentZoneState(int handle, PersistentZoneState &z)
{
   if(FileIsEnding(handle))
      return false;

   z.active = FileReadString(handle) == "1";
   z.side = FileReadString(handle);
   z.zone_id = FileReadString(handle);
   z.source_analysis_id = FileReadString(handle);
   z.zone_type = FileReadString(handle);
   z.watch_reason = FileReadString(handle);
   z.low = StringToDouble(FileReadString(handle));
   z.high = StringToDouble(FileReadString(handle));
   z.invalidation = StringToDouble(FileReadString(handle));
   z.invalidation_tf = FileReadString(handle);
   z.invalidation_rule = FileReadString(handle);
   z.invalidation_reason = FileReadString(handle);
   z.created_at = (datetime)StringToInteger(FileReadString(handle));
   z.last_seen_at = (datetime)StringToInteger(FileReadString(handle));

   return true;
}

void SavePersistentZoneLifecycle()
{
   if(!InpPersistZoneLifecycle || g_zoneLifecycleFile == "")
      return;

   int handle =
      FileOpen(
         g_zoneLifecycleFile,
         FILE_WRITE |
         FILE_TXT |
         FILE_ANSI |
         FILE_COMMON
      );

   if(handle == INVALID_HANDLE)
   {
      Print("Could not save persistent zone lifecycle state. Error=", GetLastError());
      return;
   }

   FileWrite(handle, "PZV1");
   FileWrite(handle, g_lockedPrimarySide);
   FileWrite(handle, g_lastZoneLifecycleEvent);
   WritePersistentZoneState(handle, g_pBuyZone);
   WritePersistentZoneState(handle, g_pSellZone);
   FileClose(handle);
}

bool LoadPersistentZoneLifecycle()
{
   if(
      !InpPersistZoneLifecycle ||
      g_zoneLifecycleFile == "" ||
      !FileIsExist(g_zoneLifecycleFile, FILE_COMMON)
   )
      return false;

   int handle =
      FileOpen(
         g_zoneLifecycleFile,
         FILE_READ |
         FILE_TXT |
         FILE_ANSI |
         FILE_COMMON
      );

   if(handle == INVALID_HANDLE)
      return false;

   if(FileIsEnding(handle))
   {
      FileClose(handle);
      return false;
   }

   string version = FileReadString(handle);
   if(version != "PZV1")
   {
      FileClose(handle);
      return false;
   }

   g_lockedPrimarySide = FileReadString(handle);
   g_lastZoneLifecycleEvent = FileReadString(handle);

   bool okBuy = ReadPersistentZoneState(handle, g_pBuyZone);
   bool okSell = ReadPersistentZoneState(handle, g_pSellZone);

   FileClose(handle);

   if(!okBuy || !okSell)
   {
      ResetPersistentZone(g_pBuyZone);
      ResetPersistentZone(g_pSellZone);
      g_lockedPrimarySide = "";
      return false;
   }

   Print(
      "Persistent zones recovered | PRIMARY=",
      g_lockedPrimarySide,
      " | BUY_ACTIVE=",
      g_pBuyZone.active,
      " | SELL_ACTIVE=",
      g_pSellZone.active
   );

   return true;
}

void SyncPersistentZonesToGlobals()
{
   if(g_pBuyZone.active)
   {
      g_buyZoneLow = g_pBuyZone.low;
      g_buyZoneHigh = g_pBuyZone.high;
      g_buyInvalidation = g_pBuyZone.invalidation;
      g_buyInvalidationTf = g_pBuyZone.invalidation_tf;
      g_buyInvalidationRule = g_pBuyZone.invalidation_rule;
      g_buyInvalidationReason = g_pBuyZone.invalidation_reason;
   }
   else
   {
      g_buyZoneLow = 0.0;
      g_buyZoneHigh = 0.0;
      g_buyInvalidation = 0.0;
      g_buyInvalidationTf = "";
      g_buyInvalidationRule = "";
      g_buyInvalidationReason = "";
   }

   if(g_pSellZone.active)
   {
      g_sellZoneLow = g_pSellZone.low;
      g_sellZoneHigh = g_pSellZone.high;
      g_sellInvalidation = g_pSellZone.invalidation;
      g_sellInvalidationTf = g_pSellZone.invalidation_tf;
      g_sellInvalidationRule = g_pSellZone.invalidation_rule;
      g_sellInvalidationReason = g_pSellZone.invalidation_reason;
   }
   else
   {
      g_sellZoneLow = 0.0;
      g_sellZoneHigh = 0.0;
      g_sellInvalidation = 0.0;
      g_sellInvalidationTf = "";
      g_sellInvalidationRule = "";
      g_sellInvalidationReason = "";
   }
}

string ZoneAnalysisIdForSide(bool buy)
{
   if(InpLockZoneIdentity)
   {
      if(buy && g_pBuyZone.active)
         return g_pBuyZone.source_analysis_id;

      if(!buy && g_pSellZone.active)
         return g_pSellZone.source_analysis_id;
   }

   return g_zoneAnalysisId;
}

string ZoneTypeForSide(bool buy)
{
   if(InpLockZoneIdentity)
   {
      if(buy && g_pBuyZone.active)
         return g_pBuyZone.zone_type;

      if(!buy && g_pSellZone.active)
         return g_pSellZone.zone_type;
   }

   return g_zoneType;
}

string ZoneWatchReasonForSide(bool buy)
{
   if(InpLockZoneIdentity)
   {
      if(buy && g_pBuyZone.active)
         return g_pBuyZone.watch_reason;

      if(!buy && g_pSellZone.active)
         return g_pSellZone.watch_reason;
   }

   return g_zoneWatchReason;
}

bool RawZoneAlreadyInvalidated(
   string side,
   double invalidation,
   string invalidationTf
)
{
   if(invalidation <= 0.0)
      return false;

   string tf =
      invalidationTf == ""
      ? "M5"
      : invalidationTf;

   double closedPrice =
      LastClosedZoneTFPrice(tf);

   if(closedPrice <= 0.0)
      return false;

   if(side == "BUY")
      return closedPrice < invalidation;

   if(side == "SELL")
      return closedPrice > invalidation;

   return false;
}


void AdoptPersistentZone(
   PersistentZoneState &z,
   string side,
   string analysisId,
   string zoneType,
   string watchReason,
   double low,
   double high,
   double invalidation,
   string invalidationTf,
   string invalidationRule,
   string invalidationReason
)
{
   if(z.active || !ValidZone(low, high))
      return;

   if(
      RawZoneAlreadyInvalidated(
         side,
         invalidation,
         invalidationTf
      )
   )
   {
      Print(
         "ZONE LIFECYCLE | SKIP STALE ",
         side,
         " | raw Worker zone is already structurally invalidated | ",
         DoubleToString(low, _Digits),
         "-",
         DoubleToString(high, _Digits)
      );

      return;
   }

   datetime now = TimeCurrent();

   z.active = true;
   z.side = side;
   z.zone_id =
      side + "_" +
      IntegerToString((long)now) + "_" +
      analysisId;
   z.source_analysis_id = analysisId;
   z.zone_type = zoneType;
   z.watch_reason = watchReason;
   z.low = low;
   z.high = high;
   z.invalidation = invalidation;
   z.invalidation_tf = invalidationTf == "" ? "M5" : invalidationTf;
   z.invalidation_rule = invalidationRule;
   z.invalidation_reason = invalidationReason;
   z.created_at = now;
   z.last_seen_at = now;

   g_lastZoneLifecycleEvent =
      "NEW " + side + " LOCKED " +
      DoubleToString(low, _Digits) + "-" +
      DoubleToString(high, _Digits);

   Print(
      "ZONE LIFECYCLE | NEW ",
      side,
      " | ID=",
      z.zone_id,
      " | ",
      DoubleToString(low, _Digits),
      "-",
      DoubleToString(high, _Digits),
      " | INV=",
      DoubleToString(invalidation, _Digits),
      " ",
      z.invalidation_tf
   );

   SavePersistentZoneLifecycle();
}

void InvalidatePersistentZone(PersistentZoneState &z, string cause)
{
   if(!z.active)
      return;

   string side = z.side;
   double oldLow = z.low;
   double oldHigh = z.high;

   g_lastZoneLifecycleEvent =
      side + " INVALIDATED | " +
      cause + " | " +
      DoubleToString(oldLow, _Digits) + "-" +
      DoubleToString(oldHigh, _Digits);

   Print(
      "ZONE LIFECYCLE | ",
      g_lastZoneLifecycleEvent
   );

   if(g_lockedPrimarySide == side)
      g_lockedPrimarySide = "";

   ResetPersistentZone(z);
   SavePersistentZoneLifecycle();
}

void EvaluatePersistentZoneLifecycle()
{
   if(!InpLockZoneIdentity)
      return;

   if(g_pBuyZone.active)
   {
      if(PersistentZoneStructurallyInvalidated(g_pBuyZone))
      {
         string tf = g_pBuyZone.invalidation_tf == "" ? "M5" : g_pBuyZone.invalidation_tf;
         InvalidatePersistentZone(
            g_pBuyZone,
            tf + " CLOSE BELOW " +
            DoubleToString(g_pBuyZone.invalidation, _Digits)
         );
      }
      else if(PersistentZoneExpired(g_pBuyZone))
      {
         InvalidatePersistentZone(g_pBuyZone, "EXPIRED");
      }
   }

   if(g_pSellZone.active)
   {
      if(PersistentZoneStructurallyInvalidated(g_pSellZone))
      {
         string tf = g_pSellZone.invalidation_tf == "" ? "M5" : g_pSellZone.invalidation_tf;
         InvalidatePersistentZone(
            g_pSellZone,
            tf + " CLOSE ABOVE " +
            DoubleToString(g_pSellZone.invalidation, _Digits)
         );
      }
      else if(PersistentZoneExpired(g_pSellZone))
      {
         InvalidatePersistentZone(g_pSellZone, "EXPIRED");
      }
   }

   SyncPersistentZonesToGlobals();
}

// ============================================================
// AUTO SL/TP PROTECTION
// ============================================================

bool BuildProtectionPlanForPosition(
   string side,
   double positionEntry,
   double &planSL,
   double &planTP
)
{
   planSL = 0.0;
   planTP = 0.0;

   if(side != "BUY" && side != "SELL")
      return false;

   // Best source: the exact plan that was shown when READY was issued.
   if(
      g_readyLatched &&
      g_latchedSide == side &&
      g_latchedSL > 0.0
   )
   {
      planSL = g_latchedSL;

      if(g_latchedTP > 0.0)
         planTP = g_latchedTP;

      return true;
   }

   bool buy = side == "BUY";

   double zoneLow =
      buy
      ? g_buyZoneLow
      : g_sellZoneLow;

   double zoneHigh =
      buy
      ? g_buyZoneHigh
      : g_sellZoneHigh;

   double invalidation =
      buy
      ? g_buyInvalidation
      : g_sellInvalidation;

   if(!ValidZone(zoneLow, zoneHigh))
      return false;

   double zoneWidth =
      MathMax(
         zoneHigh - zoneLow,
         _Point * 10.0
      );

   double slBuffer =
      MathMax(
         zoneWidth *
         InpSimpleSLBufferZoneFraction,
         _Point * 10.0
      );

   if(buy)
   {
      double baseSL =
         invalidation > 0.0
         ? invalidation
         : zoneLow;

      planSL =
         NormalizeDouble(
            baseSL - slBuffer,
            _Digits
         );
   }
   else
   {
      double baseSL =
         invalidation > 0.0
         ? invalidation
         : zoneHigh;

      planSL =
         NormalizeDouble(
            baseSL + slBuffer,
            _Digits
         );
   }

   if(
      positionEntry <= 0.0 ||
      planSL <= 0.0
   )
      return false;

   double risk =
      MathAbs(
         positionEntry -
         planSL
      );

   if(risk <= _Point)
      return false;

   planTP =
      NormalizeDouble(
         buy
         ? positionEntry + risk * InpSimpleRR
         : positionEntry - risk * InpSimpleRR,
         _Digits
      );

   return true;
}


bool ProtectionLevelValidNow(
   string side,
   bool isSL,
   double level,
   MqlTick &tick
)
{
   if(level <= 0.0)
      return false;

   long stopsLevelPoints =
      SymbolInfoInteger(
         _Symbol,
         SYMBOL_TRADE_STOPS_LEVEL
      );

   long freezeLevelPoints =
      SymbolInfoInteger(
         _Symbol,
         SYMBOL_TRADE_FREEZE_LEVEL
      );

   double minDistance =
      MathMax(
         (double)stopsLevelPoints,
         (double)freezeLevelPoints
      ) * _Point;

   // Small tolerance so a broker with zero stop-level still gets
   // a correctly-sided price.
   minDistance =
      MathMax(
         minDistance,
         _Point
      );

   if(side == "BUY")
   {
      if(isSL)
         return level < tick.bid - minDistance;

      return level > tick.bid + minDistance;
   }

   if(side == "SELL")
   {
      if(isSL)
         return level > tick.ask + minDistance;

      return level < tick.ask - minDistance;
   }

   return false;
}


void AutoProtectOpenPositions()
{
   g_protectionAppliedLastScan = 0;
   g_protectionFailedLastScan = 0;

   if(!InpAutoProtectPositions)
   {
      g_protectionStatus = "OFF";
      return;
   }

   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
   {
      g_protectionStatus = "NO TICK";
      return;
   }

   trade.SetExpertMagicNumber(
      InpMagicNumber
   );

   trade.SetDeviationInPoints(
      InpMaxDeviationPoints
   );

   int total = PositionsTotal();
   int eligible = 0;
   int missingProtection = 0;

   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      eligible++;

      long type =
         PositionGetInteger(
            POSITION_TYPE
         );

      string side =
         type == POSITION_TYPE_BUY
         ? "BUY"
         : (
            type == POSITION_TYPE_SELL
            ? "SELL"
            : "NONE"
           );

      if(side == "NONE")
         continue;

      double entry =
         PositionGetDouble(
            POSITION_PRICE_OPEN
         );

      double currentSL =
         PositionGetDouble(
            POSITION_SL
         );

      double currentTP =
         PositionGetDouble(
            POSITION_TP
         );

      bool needSL =
         InpAutoSetActualSL &&
         (
            InpOverwriteExistingProtection ||
            currentSL <= 0.0
         );

      bool needTP =
         InpAutoSetActualTP &&
         (
            InpOverwriteExistingProtection ||
            currentTP <= 0.0
         );

      if(!needSL && !needTP)
         continue;

      missingProtection++;

      if(
         !InpAutoProtectExistingPositions &&
         !g_protectionScanRequested
      )
         continue;

      double planSL = 0.0;
      double planTP = 0.0;

      if(
         !BuildProtectionPlanForPosition(
            side,
            entry,
            planSL,
            planTP
         )
      )
      {
         continue;
      }

      double newSL = currentSL;
      double newTP = currentTP;
      bool canModify = false;

      if(
         needSL &&
         ProtectionLevelValidNow(
            side,
            true,
            planSL,
            tick
         )
      )
      {
         newSL = planSL;
         canModify = true;
      }

      if(
         needTP &&
         ProtectionLevelValidNow(
            side,
            false,
            planTP,
            tick
         )
      )
      {
         newTP = planTP;
         canModify = true;
      }

      if(!canModify)
         continue;

      // Never erase a valid existing level just because the other
      // side of protection is unavailable.
      if(!needSL)
         newSL = currentSL;

      if(!needTP)
         newTP = currentTP;

      ResetLastError();

      if(
         trade.PositionModify(
            ticket,
            newSL,
            newTP
         )
      )
      {
         g_protectionAppliedLastScan++;

         Print(
            "AUTO PROTECTION APPLIED | ticket=",
            ticket,
            " | ",
            side,
            " | SL=",
            DoubleToString(newSL, _Digits),
            " | TP=",
            DoubleToString(newTP, _Digits)
         );
      }
      else
      {
         g_protectionFailedLastScan++;

         Print(
            "AUTO PROTECTION FAILED | ticket=",
            ticket,
            " | retcode=",
            trade.ResultRetcode(),
            " | ",
            trade.ResultRetcodeDescription(),
            " | error=",
            GetLastError()
         );
      }
   }

   if(eligible == 0)
   {
      g_protectionStatus = "ON | NO OPEN POSITIONS";
   }
   else if(g_protectionFailedLastScan > 0)
   {
      g_protectionStatus =
         "ON | FAILED " +
         IntegerToString(
            g_protectionFailedLastScan
         );
   }
   else if(g_protectionAppliedLastScan > 0)
   {
      g_protectionStatus =
         "ON | APPLIED " +
         IntegerToString(
            g_protectionAppliedLastScan
         );
   }
   else if(missingProtection > 0)
   {
      g_protectionStatus =
         "ON | WAITING VALID SL/TP LEVEL";
   }
   else
   {
      g_protectionStatus =
         "ON | ALL PROTECTED";
   }

   g_protectionScanRequested = false;
}


// ============================================================
// ACTIVE TRADE MANAGER
// ============================================================

void ResetManagerBasketState()
{
   g_managerBasketActive = false;
   g_managerSide = "NONE";
   g_managerInitialVolume = 0.0;
   g_managerInitialPositions = 0;
   g_managerTP1Done = false;
   g_managerStartedAt = 0;
   g_managerBasketR = 0.0;
}


void SaveManagerBasketState()
{
   if(g_managerFile == "")
      return;

   if(!g_managerBasketActive)
   {
      if(FileIsExist(g_managerFile, FILE_COMMON))
         FileDelete(g_managerFile, FILE_COMMON);

      return;
   }

   int handle =
      FileOpen(
         g_managerFile,
         FILE_WRITE |
         FILE_TXT |
         FILE_ANSI |
         FILE_COMMON
      );

   if(handle == INVALID_HANDLE)
      return;

   FileWrite(handle, "MGR1");
   FileWrite(handle, g_managerBasketActive ? "1" : "0");
   FileWrite(handle, g_managerSide);
   FileWrite(handle, DoubleToString(g_managerInitialVolume, 2));
   FileWrite(handle, IntegerToString(g_managerInitialPositions));
   FileWrite(handle, g_managerTP1Done ? "1" : "0");
   FileWrite(handle, IntegerToString((long)g_managerStartedAt));
   FileClose(handle);
}


bool LoadManagerBasketState()
{
   if(
      g_managerFile == "" ||
      !FileIsExist(g_managerFile, FILE_COMMON)
   )
      return false;

   int handle =
      FileOpen(
         g_managerFile,
         FILE_READ |
         FILE_TXT |
         FILE_ANSI |
         FILE_COMMON
      );

   if(handle == INVALID_HANDLE)
      return false;

   if(FileIsEnding(handle))
   {
      FileClose(handle);
      return false;
   }

   string version = FileReadString(handle);

   if(version != "MGR1")
   {
      FileClose(handle);
      return false;
   }

   g_managerBasketActive = FileReadString(handle) == "1";
   g_managerSide = FileReadString(handle);
   g_managerInitialVolume = StringToDouble(FileReadString(handle));
   g_managerInitialPositions = (int)StringToInteger(FileReadString(handle));
   g_managerTP1Done = FileReadString(handle) == "1";
   g_managerStartedAt = (datetime)StringToInteger(FileReadString(handle));

   FileClose(handle);

   return g_managerBasketActive;
}


double InitialRiskFromPosition()
{
   double entry =
      PositionGetDouble(
         POSITION_PRICE_OPEN
      );

   double tp =
      PositionGetDouble(
         POSITION_TP
      );

   if(
      entry > 0.0 &&
      tp > 0.0 &&
      InpSimpleRR > 0.0
   )
   {
      double risk =
         MathAbs(tp - entry) /
         InpSimpleRR;

      if(risk > _Point)
         return risk;
   }

   double sl =
      PositionGetDouble(
         POSITION_SL
      );

   long type =
      PositionGetInteger(
         POSITION_TYPE
      );

   if(entry > 0.0 && sl > 0.0)
   {
      if(
         type == POSITION_TYPE_BUY &&
         sl < entry
      )
         return entry - sl;

      if(
         type == POSITION_TYPE_SELL &&
         sl > entry
      )
         return sl - entry;
   }

   return 0.0;
}


double CurrentPositionR(
   string side,
   double entry,
   double initialRisk,
   MqlTick &tick
)
{
   if(
      initialRisk <= _Point ||
      entry <= 0.0
   )
      return -999.0;

   double favorable =
      side == "BUY"
      ? tick.bid - entry
      : entry - tick.ask;

   return
      favorable /
      initialRisk;
}


bool ImprovePositionSL(
   ulong ticket,
   string side,
   double candidateSL
)
{
   if(
      ticket == 0 ||
      candidateSL <= 0.0 ||
      !PositionSelectByTicket(ticket)
   )
      return false;

   double currentSL =
      PositionGetDouble(
         POSITION_SL
      );

   double currentTP =
      PositionGetDouble(
         POSITION_TP
      );

   if(side == "BUY")
   {
      if(
         currentSL > 0.0 &&
         candidateSL <= currentSL + _Point
      )
         return false;
   }
   else if(side == "SELL")
   {
      if(
         currentSL > 0.0 &&
         candidateSL >= currentSL - _Point
      )
         return false;
   }
   else
   {
      return false;
   }

   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   candidateSL =
      NormalizeDouble(
         candidateSL,
         _Digits
      );

   if(
      !ProtectionLevelValidNow(
         side,
         true,
         candidateSL,
         tick
      )
   )
      return false;

   ResetLastError();

   if(
      !trade.PositionModify(
         ticket,
         candidateSL,
         currentTP
      )
   )
   {
      Print(
         "TRADE MANAGER SL MODIFY FAILED | ticket=",
         ticket,
         " | retcode=",
         trade.ResultRetcode(),
         " | ",
         trade.ResultRetcodeDescription(),
         " | error=",
         GetLastError()
      );

      return false;
   }

   Print(
      "TRADE MANAGER SL MOVED | ticket=",
      ticket,
      " | ",
      side,
      " | newSL=",
      DoubleToString(candidateSL, _Digits)
   );

   return true;
}


double CalculateBasketR(
   string side,
   MqlTick &tick
)
{
   double weightedR = 0.0;
   double totalVolume = 0.0;

   int total = PositionsTotal();

   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(
         ticket == 0 ||
         !PositionSelectByTicket(ticket) ||
         PositionGetString(POSITION_SYMBOL) != _Symbol
      )
         continue;

      long type =
         PositionGetInteger(
            POSITION_TYPE
         );

      string positionSide =
         type == POSITION_TYPE_BUY
         ? "BUY"
         : "SELL";

      if(positionSide != side)
         continue;

      double entry =
         PositionGetDouble(
            POSITION_PRICE_OPEN
         );

      double volume =
         PositionGetDouble(
            POSITION_VOLUME
         );

      double risk =
         InitialRiskFromPosition();

      double r =
         CurrentPositionR(
            side,
            entry,
            risk,
            tick
         );

      if(r <= -900.0)
         continue;

      weightedR +=
         r * volume;

      totalVolume += volume;
   }

   if(totalVolume <= 0.0)
      return 0.0;

   return
      weightedR /
      totalVolume;
}


double CurrentSymbolSideVolume(
   string side
)
{
   double totalVolume = 0.0;
   int total = PositionsTotal();

   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(
         ticket == 0 ||
         !PositionSelectByTicket(ticket) ||
         PositionGetString(POSITION_SYMBOL) != _Symbol
      )
         continue;

      long type =
         PositionGetInteger(
            POSITION_TYPE
         );

      if(
         side == "BUY" &&
         type != POSITION_TYPE_BUY
      )
         continue;

      if(
         side == "SELL" &&
         type != POSITION_TYPE_SELL
      )
         continue;

      totalVolume +=
         PositionGetDouble(
            POSITION_VOLUME
         );
   }

   return totalVolume;
}


int CurrentSymbolSidePositions(
   string side
)
{
   int count = 0;
   int total = PositionsTotal();

   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(
         ticket == 0 ||
         !PositionSelectByTicket(ticket) ||
         PositionGetString(POSITION_SYMBOL) != _Symbol
      )
         continue;

      long type =
         PositionGetInteger(
            POSITION_TYPE
         );

      if(
         side == "BUY" &&
         type == POSITION_TYPE_BUY
      )
         count++;

      if(
         side == "SELL" &&
         type == POSITION_TYPE_SELL
      )
         count++;
   }

   return count;
}


double NormalizeVolumeFloor(
   double volume
)
{
   double step =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_VOLUME_STEP
      );

   double minLot =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_VOLUME_MIN
      );

   if(step <= 0.0)
      step = 0.01;

   double result =
      MathFloor(
         volume / step + 1e-8
      ) * step;

   result =
      NormalizeDouble(
         result,
         2
      );

   if(result < minLot)
      return 0.0;

   return result;
}


bool CloseBasketVolume(
   string side,
   double targetCloseVolume
)
{
   double target =
      NormalizeVolumeFloor(
         targetCloseVolume
      );

   if(target <= 0.0)
      return false;

   ulong tickets[];
   double entries[];
   double volumes[];

   int count = 0;
   int total = PositionsTotal();

   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(
         ticket == 0 ||
         !PositionSelectByTicket(ticket) ||
         PositionGetString(POSITION_SYMBOL) != _Symbol
      )
         continue;

      long type =
         PositionGetInteger(
            POSITION_TYPE
         );

      if(
         side == "BUY" &&
         type != POSITION_TYPE_BUY
      )
         continue;

      if(
         side == "SELL" &&
         type != POSITION_TYPE_SELL
      )
         continue;

      ArrayResize(tickets, count + 1);
      ArrayResize(entries, count + 1);
      ArrayResize(volumes, count + 1);

      tickets[count] = ticket;
      entries[count] =
         PositionGetDouble(
            POSITION_PRICE_OPEN
         );
      volumes[count] =
         PositionGetDouble(
            POSITION_VOLUME
         );

      count++;
   }

   if(count <= 0)
      return false;

   // Close the least favorable entries first:
   // BUY -> highest entry first, SELL -> lowest entry first.
   for(int a = 0; a < count - 1; a++)
   {
      for(int b = a + 1; b < count; b++)
      {
         bool swapNeeded =
            side == "BUY"
            ? entries[b] > entries[a]
            : entries[b] < entries[a];

         if(swapNeeded)
         {
            ulong t = tickets[a];
            tickets[a] = tickets[b];
            tickets[b] = t;

            double e = entries[a];
            entries[a] = entries[b];
            entries[b] = e;

            double v = volumes[a];
            volumes[a] = volumes[b];
            volumes[b] = v;
         }
      }
   }

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

   double closedVolume = 0.0;

   for(int i = 0; i < count; i++)
   {
      double remainingTarget =
         target -
         closedVolume;

      if(remainingTarget < minLot - 1e-8)
         break;

      if(!PositionSelectByTicket(tickets[i]))
         continue;

      double currentVolume =
         PositionGetDouble(
            POSITION_VOLUME
         );

      if(currentVolume <= 0.0)
         continue;

      bool success = false;

      // If the requested amount can leave a valid runner,
      // partially close this ticket. Otherwise close the whole ticket.
      double partial =
         NormalizeVolumeFloor(
            MathMin(
               currentVolume,
               remainingTarget
            )
         );

      double remainingPosition =
         NormalizeDouble(
            currentVolume -
            partial,
            2
         );

      if(
         partial >= minLot &&
         partial < currentVolume - 1e-8 &&
         remainingPosition >= minLot
      )
      {
         success =
            trade.PositionClosePartial(
               tickets[i],
               partial
            );

         if(success)
            closedVolume += partial;
      }
      else if(
         currentVolume <=
         remainingTarget + step * 0.5
      )
      {
         success =
            trade.PositionClose(
               tickets[i]
            );

         if(success)
            closedVolume += currentVolume;
      }

      if(!success)
      {
         Print(
            "TRADE MANAGER PARTIAL CLOSE FAILED | ticket=",
            tickets[i],
            " | retcode=",
            trade.ResultRetcode(),
            " | ",
            trade.ResultRetcodeDescription()
         );
      }

      if(
         closedVolume >=
         target - step * 0.5
      )
         break;
   }

   Print(
      "TRADE MANAGER TP1 BASKET CLOSE | target=",
      DoubleToString(target, 2),
      " | closed=",
      DoubleToString(closedVolume, 2)
   );

   return
      closedVolume >
      0.0;
}


void ManageIndividualStops(
   string side,
   MqlTick &tick
)
{
   int total = PositionsTotal();

   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(
         ticket == 0 ||
         !PositionSelectByTicket(ticket) ||
         PositionGetString(POSITION_SYMBOL) != _Symbol
      )
         continue;

      long type =
         PositionGetInteger(
            POSITION_TYPE
         );

      string positionSide =
         type == POSITION_TYPE_BUY
         ? "BUY"
         : "SELL";

      if(positionSide != side)
         continue;

      double entry =
         PositionGetDouble(
            POSITION_PRICE_OPEN
         );

      double risk =
         InitialRiskFromPosition();

      if(risk <= _Point)
         continue;

      double currentR =
         CurrentPositionR(
            side,
            entry,
            risk,
            tick
         );

      if(currentR <= -900.0)
         continue;

      double lockR = -999.0;

      if(
         InpManagerEnableTrailing &&
         currentR >= InpManagerTrailStartR &&
         InpManagerTrailStepR > 0.0
      )
      {
         double rawLockR =
            currentR -
            MathMax(
               0.0,
               InpManagerTrailGapR
            );

         lockR =
            MathFloor(
               rawLockR /
               InpManagerTrailStepR
            ) *
            InpManagerTrailStepR;

         lockR =
            MathMax(
               lockR,
               InpManagerBEPlusR
            );
      }
      else if(
         InpManagerMoveToBE &&
         currentR >= InpManagerBEAtR
      )
      {
         lockR =
            MathMax(
               0.0,
               InpManagerBEPlusR
            );
      }

      if(lockR <= -900.0)
         continue;

      double candidateSL =
         side == "BUY"
         ? entry + lockR * risk
         : entry - lockR * risk;

      ImprovePositionSL(
         ticket,
         side,
         candidateSL
      );
   }
}


void InitializeOrRefreshManagerBasket(
   string side
)
{
   double currentVolume =
      CurrentSymbolSideVolume(
         side
      );

   int currentPositions =
      CurrentSymbolSidePositions(
         side
      );

   if(
      currentVolume <= 0.0 ||
      currentPositions <= 0
   )
      return;

   if(
      !g_managerBasketActive ||
      g_managerSide != side
   )
   {
      ResetManagerBasketState();

      g_managerBasketActive = true;
      g_managerSide = side;
      g_managerInitialVolume = currentVolume;
      g_managerInitialPositions = currentPositions;
      g_managerTP1Done = false;
      g_managerStartedAt = TimeCurrent();

      SaveManagerBasketState();

      return;
   }

   // If more positions were added before TP1, include them in the basket.
   if(
      !g_managerTP1Done &&
      currentVolume >
      g_managerInitialVolume + 0.0001
   )
   {
      g_managerInitialVolume = currentVolume;
      g_managerInitialPositions = currentPositions;
      SaveManagerBasketState();
   }
}


void ManageActiveBasketPositions()
{
   if(!InpEnableActiveTradeManager)
   {
      g_managerStatus = "OFF";
      return;
   }

   string side = "NONE";

   if(
      g_activeBuyCount > 0 &&
      g_activeSellCount == 0
   )
      side = "BUY";
   else if(
      g_activeSellCount > 0 &&
      g_activeBuyCount == 0
   )
      side = "SELL";
   else if(
      g_activeBuyCount > 0 &&
      g_activeSellCount > 0
   )
   {
      g_managerStatus = "PAUSED | MIXED BUY/SELL";
      return;
   }

   if(side == "NONE")
   {
      if(g_managerBasketActive)
      {
         ResetManagerBasketState();
         SaveManagerBasketState();
      }

      g_managerStatus = "IDLE | NO POSITIONS";
      return;
   }

   InitializeOrRefreshManagerBasket(
      side
   );

   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
   {
      g_managerStatus = "WAITING TICK";
      return;
   }

   g_managerBasketR =
      CalculateBasketR(
         side,
         tick
      );

   // TP1 stage: reduce basket exposure once at the configured R.
   if(
      InpManagerEnablePartialClose &&
      !g_managerTP1Done &&
      g_managerBasketR >= InpManagerPartialAtR
   )
   {
      double step =
         SymbolInfoDouble(
            _Symbol,
            SYMBOL_VOLUME_STEP
         );

      if(step <= 0.0)
         step = 0.01;

      double keepPercent =
         100.0 -
         MathMax(
            0.0,
            MathMin(
               100.0,
               InpManagerPartialClosePercent
            )
         );

      double targetRemaining =
         g_managerInitialVolume *
         keepPercent /
         100.0;

      targetRemaining =
         MathCeil(
            targetRemaining /
            step - 1e-8
         ) *
         step;

      targetRemaining =
         NormalizeDouble(
            targetRemaining,
            2
         );

      double currentVolume =
         CurrentSymbolSideVolume(
            side
         );

      double needClose =
         currentVolume -
         targetRemaining;

      if(needClose > step * 0.5)
      {
         CloseBasketVolume(
            side,
            needClose
         );
      }

      currentVolume =
         CurrentSymbolSideVolume(
            side
         );

      if(
         currentVolume <=
         targetRemaining +
         step * 0.5
      )
      {
         g_managerTP1Done = true;
         SaveManagerBasketState();
      }
   }

   // BE / trailing applies to all surviving positions.
   ManageIndividualStops(
      side,
      tick
   );

   string stage =
      g_managerTP1Done
      ? "TP1 DONE"
      : "TP1 WAIT";

   if(
      InpManagerEnableTrailing &&
      g_managerBasketR >=
      InpManagerTrailStartR
   )
   {
      stage += " | TRAIL";
   }
   else if(
      InpManagerMoveToBE &&
      g_managerBasketR >=
      InpManagerBEAtR
   )
   {
      stage += " | BE";
   }

   g_managerStatus =
      stage +
      " | R " +
      DoubleToString(
         g_managerBasketR,
         2
      );
}


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

   if(
      InpDrawR2Setup &&
      InpR2PollEverySeconds < 1
   )
   {
      Print(
         "InpR2PollEverySeconds must be at least 1."
      );

      return INIT_PARAMETERS_INCORRECT;
   }

   g_zoneLifecycleFile =
      "XAU_ZONE_LIFECYCLE_" +
      _Symbol +
      ".txt";

   g_managerFile =
      "XAU_ACTIVE_MANAGER_" +
      _Symbol +
      ".txt";

   ResetManagerBasketState();
   LoadManagerBasketState();

   ResetPersistentZone(g_pBuyZone);
   ResetPersistentZone(g_pSellZone);

   if(InpResetPersistentZonesOnInit)
   {
      g_lockedPrimarySide = "";
      g_lastZoneLifecycleEvent = "MANUAL RESET ON INIT";

      if(
         FileIsExist(
            g_zoneLifecycleFile,
            FILE_COMMON
         )
      )
      {
         FileDelete(
            g_zoneLifecycleFile,
            FILE_COMMON
         );
      }
   }
   else
   {
      LoadPersistentZoneLifecycle();
      SyncPersistentZonesToGlobals();
   }

   EventSetTimer(1);

   Print(
      "XAU Market Zones Engine v2.9 ACTIVE TRADE MANAGER started on ",
      _Symbol,
      " | SIGNAL OPENING DISABLED | AUTO PROTECTION=", (InpAutoProtectPositions ? "ON" : "OFF")
   );

   if(InpDrawDecisionZones)
   {
      PollDecisionZones();
      g_lastZonePoll = TimeCurrent();
   }

   if(InpDrawR2Setup)
   {
      PollR2Visuals();
      g_lastR2Poll = TimeCurrent();
   }

   g_protectionScanRequested = true;

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

   SavePersistentZoneLifecycle();
   SaveManagerBasketState();

   DeleteDecisionZoneObjects();
   DeleteR2VisualObjects();
   DeleteCompactZonePanel();
   Comment("");
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
   // R2 LIVE SETUP VISUALIZATION
   // --------------------------------------------------------

   if(
      InpDrawR2Setup &&
      (
         g_lastR2Poll == 0 ||
         now - g_lastR2Poll >=
         InpR2PollEverySeconds
      )
   )
   {
      PollR2Visuals();

      g_lastR2Poll =
         now;
   }

   AutoProtectOpenPositions();

   string managerSideSnapshot = "NONE";
   GetOpenSymbolPositionSummary(
      managerSideSnapshot
   );

   ManageActiveBasketPositions();

   if(InpShowZoneEngineStatus)
      DrawCompactZonePanel();
}


// ============================================================
// TICK
// ============================================================

void OnTick()
{
   CheckZoneEntryAlert();

   if(InpShowZoneEngineStatus)
      DrawCompactZonePanel();
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


string ZoneInvalidationRuleText(bool buy)
{
   string rule =
      buy
      ? g_buyInvalidationRule
      : g_sellInvalidationRule;

   if(rule == "")
      return "NONE";

   StringReplace(
      rule,
      "_",
      " "
   );

   return rule;
}


string ZoneInvalidationReason(bool buy)
{
   string reason =
      buy
      ? g_buyInvalidationReason
      : g_sellInvalidationReason;

   if(reason == "")
      return "No structural invalidation level available.";

   return reason;
}


double ZoneInvalidationPrice(bool buy)
{
   return
      buy
      ? g_buyInvalidation
      : g_sellInvalidation;
}


int BaseZoneStrengthScore(bool buy)
{
   if(!ValidZone(
         buy ? g_buyZoneLow : g_sellZoneLow,
         buy ? g_buyZoneHigh : g_sellZoneHigh
      ))
      return 0;

   string analysisId = ZoneAnalysisIdForSide(buy);
   string zoneType = ZoneTypeForSide(buy);

   if(StringFind(analysisId, "BREAKOUT_RETEST_BUY") >= 0)
      return buy ? 86 : 68;

   if(StringFind(analysisId, "BREAKOUT_RETEST_SELL") >= 0)
      return buy ? 68 : 86;

   if(StringFind(analysisId, "TREND_PULLBACK_BUY") >= 0)
      return buy ? 82 : 68;

   if(StringFind(analysisId, "TREND_PULLBACK_SELL") >= 0)
      return buy ? 68 : 82;

   if(StringFind(analysisId, "RANGE_REVERSION") >= 0)
      return 76;

   if(zoneType == "WATCH_HIGH_VOLATILITY")
      return 72;

   if(zoneType == "WATCH_TRANSITION")
      return 70;

   return 72;
}


bool R2LocationReadyForSide(bool buy)
{
   string side =
      buy
      ? "BUY"
      : "SELL";

   if(g_r2Side != side)
      return false;

   // READY means score, RR, relevant R1 location, one confirmation
   // and order-placement relation are all acceptable.
   if(g_r2AuditStatus == "READY")
      return true;

   // While still WATCH, do not allow a far-away R2 setup to promote
   // a remote zone to PRIMARY or inflate its grade.
   if(
      StringFind(
         g_r2AuditReason,
         "TOO_FAR_FROM_RELEVANT_R1_ZONE"
      ) >= 0
   )
      return false;

   if(
      StringFind(
         g_r2AuditReason,
         "WAIT_FOR_GOOD_ZONE"
      ) >= 0
   )
      return false;

   // If it is only waiting for the single confirmation, location is good.
   if(
      StringFind(
         g_r2AuditReason,
         "WAIT_ONE_CONFIRMATION"
      ) >= 0
   )
      return true;

   // Score/RR waits are not considered actionable alignment yet.
   return false;
}


int ZoneStrengthScore(bool buy)
{
   int score = BaseZoneStrengthScore(buy);

   if(score <= 0)
      return 0;

   string side =
      buy
      ? "BUY"
      : "SELL";

   if(
      g_r2Side == side &&
      g_r2Score >= 70 &&
      R2LocationReadyForSide(buy)
   )
   {
      if(g_r2Score >= 85)
         score += 12;
      else if(g_r2Score >= 75)
         score += 8;
      else
         score += 5;
   }
   else if(
      g_r2Side != "" &&
      g_r2Side != side &&
      g_r2Score >= 70 &&
      R2LocationReadyForSide(!buy)
   )
   {
      score -= 8;
   }

   if(
      g_zoneType == "WATCH_HIGH_VOLATILITY" ||
      g_zoneType == "WATCH_TRANSITION"
   )
   {
      score = MathMin(score, 79);
   }

   return MathMax(0, MathMin(100, score));
}


string ZoneGrade(bool buy)
{
   int score = ZoneStrengthScore(buy);

   if(score <= 0)
      return "N/A";

   if(score >= 90)
      return "A+";

   if(score >= 80)
      return "A";

   return "B";
}


string ZoneBias(bool buy)
{
   if(!ValidZone(
         buy ? g_buyZoneLow : g_sellZoneLow,
         buy ? g_buyZoneHigh : g_sellZoneHigh
      ))
      return "NONE";

   string side =
      buy
      ? "BUY"
      : "SELL";

   if(
      g_r2Side == side &&
      g_r2Score >= 70 &&
      R2LocationReadyForSide(buy)
   )
      return "PRIMARY";

   if(
      g_r2Side != "" &&
      g_r2Side != side &&
      g_r2Score >= 70 &&
      R2LocationReadyForSide(!buy)
   )
      return "COUNTER-TREND";

   if(
      g_zoneType == "WATCH_HIGH_VOLATILITY" ||
      g_zoneType == "WATCH_TRANSITION"
   )
      return "WATCH ONLY";

   return "SECONDARY";
}


string BaseZoneReason(bool buy)
{
   string analysisId = ZoneAnalysisIdForSide(buy);
   string zoneType = ZoneTypeForSide(buy);

   if(StringFind(analysisId, "BREAKOUT_RETEST_BUY") >= 0)
   {
      return buy
         ? "M5 previous 20-bar high breakout retest + ATR buffer"
         : "Opposite-side reaction area";
   }

   if(StringFind(analysisId, "BREAKOUT_RETEST_SELL") >= 0)
   {
      return buy
         ? "Opposite-side reaction area"
         : "M5 previous 20-bar low breakout retest + ATR buffer";
   }

   if(StringFind(analysisId, "TREND_PULLBACK_BUY") >= 0)
   {
      return buy
         ? "R1 uptrend value near M5 EMA20/EMA50 + ATR pullback band"
         : "Opposite-side reaction area";
   }

   if(StringFind(analysisId, "TREND_PULLBACK_SELL") >= 0)
   {
      return buy
         ? "Opposite-side reaction area"
         : "R1 downtrend value near M5 EMA20/EMA50 + ATR pullback band";
   }

   if(StringFind(analysisId, "RANGE_REVERSION") >= 0)
   {
      return buy
         ? "M30 range lower edge, outer 20% mean-reversion zone"
         : "M30 range upper edge, outer 20% mean-reversion zone";
   }

   if(zoneType == "WATCH_HIGH_VOLATILITY")
   {
      return buy
         ? "M1/M5 reaction support during high volatility"
         : "M1/M5 reaction resistance during high volatility";
   }

   if(zoneType == "WATCH_TRANSITION")
   {
      return buy
         ? "M5 20-bar low + ATR support edge while regime transitions"
         : "M5 20-bar high + ATR resistance edge while regime transitions";
   }

   return buy
      ? "R1 structural buy reaction area"
      : "R1 structural sell reaction area";
}


string ZoneReason(bool buy)
{
   if(!ValidZone(
         buy ? g_buyZoneLow : g_sellZoneLow,
         buy ? g_buyZoneHigh : g_sellZoneHigh
      ))
      return "No valid zone";

   string reason = BaseZoneReason(buy);
   string side =
      buy
      ? "BUY"
      : "SELL";

   if(
      g_r2Side == side &&
      g_r2Score >= 70
   )
   {
      reason +=
         " | R2 " +
         g_r2Strategy +
         " score " +
         IntegerToString(g_r2Score) +
         " aligned with " +
         g_r2MarketState;
   }
   else if(
      g_r2Side != "" &&
      g_r2Side != side &&
      g_r2Score >= 70
   )
   {
      reason +=
         " | Counter to R2 " +
         g_r2Strategy +
         " score " +
         IntegerToString(g_r2Score);
   }
   else
   {
      string sideWatchReason =
         ZoneWatchReasonForSide(buy);

      if(sideWatchReason != "")
      {
         reason +=
            " | " +
            sideWatchReason;
      }
   }

   return reason;
}


void DeleteDecisionZoneObjects()
{
   ObjectDelete(0, ZONE_BUY_OBJECT);
   ObjectDelete(0, ZONE_SELL_OBJECT);

   ObjectDelete(0, R1_BUY_LOW_LINE);
   ObjectDelete(0, R1_BUY_HIGH_LINE);
   ObjectDelete(0, R1_SELL_LOW_LINE);
   ObjectDelete(0, R1_SELL_HIGH_LINE);

   ObjectDelete(0, R1_BUY_INVALIDATION_LINE);
   ObjectDelete(0, R1_SELL_INVALIDATION_LINE);

   ObjectDelete(0, R1_ARMED_TRIGGER_LINE);
   ObjectDelete(0, R1_ARMED_SL_LINE);
   ObjectDelete(0, R1_ARMED_TP_LINE);
   DeleteCompactZonePanel();

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


void DrawR1HLine(
   string name,
   double price,
   color lineColor,
   ENUM_LINE_STYLE lineStyle,
   int width,
   string tooltip
)
{
   if(price <= 0.0)
   {
      ObjectDelete(0, name);
      return;
   }

   if(ObjectFind(0, name) < 0)
   {
      ResetLastError();

      if(
         !ObjectCreate(
            0,
            name,
            OBJ_HLINE,
            0,
            0,
            price
         )
      )
      {
         Print(
            "Could not create R1 line ",
            name,
            ". Error=",
            GetLastError()
         );

         return;
      }
   }

   ObjectSetDouble(
      0,
      name,
      OBJPROP_PRICE,
      price
   );

   ObjectSetInteger(
      0,
      name,
      OBJPROP_COLOR,
      lineColor
   );

   ObjectSetInteger(
      0,
      name,
      OBJPROP_STYLE,
      lineStyle
   );

   ObjectSetInteger(
      0,
      name,
      OBJPROP_WIDTH,
      width
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


double DistanceToZone(
   double price,
   double low,
   double high
)
{
   if(!ValidZone(low, high))
      return DBL_MAX;

   if(price < low)
      return low - price;

   if(price > high)
      return price - high;

   return 0.0;
}


string NearestZoneSide()
{
   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return "NONE";

   double mid =
      (tick.bid + tick.ask) /
      2.0;

   double buyDistance =
      DistanceToZone(
         mid,
         g_buyZoneLow,
         g_buyZoneHigh
      );

   double sellDistance =
      DistanceToZone(
         mid,
         g_sellZoneLow,
         g_sellZoneHigh
      );

   if(
      buyDistance == DBL_MAX &&
      sellDistance == DBL_MAX
   )
      return "NONE";

   return
      buyDistance <= sellDistance
      ? "BUY"
      : "SELL";
}


string ComputeDynamicPrimarySide()
{
   bool buyValid =
      ValidZone(
         g_buyZoneLow,
         g_buyZoneHigh
      );

   bool sellValid =
      ValidZone(
         g_sellZoneLow,
         g_sellZoneHigh
      );

   if(!buyValid && !sellValid)
      return "NONE";

   // R2 may override only when its relevant zone is already actionable.
   if(
      buyValid &&
      g_r2Side == "BUY" &&
      g_r2Score >= 70 &&
      R2LocationReadyForSide(true)
   )
      return "BUY";

   if(
      sellValid &&
      g_r2Side == "SELL" &&
      g_r2Score >= 70 &&
      R2LocationReadyForSide(false)
   )
      return "SELL";

   if(buyValid && !sellValid)
      return "BUY";

   if(sellValid && !buyValid)
      return "SELL";

   int buyScore =
      ZoneStrengthScore(true);

   int sellScore =
      ZoneStrengthScore(false);

   // Clear quality advantage wins.
   if(buyScore >= sellScore + 5)
      return "BUY";

   if(sellScore >= buyScore + 5)
      return "SELL";

   // Comparable quality: the nearest zone is the one worth watching now.
   return NearestZoneSide();
}


string CurrentFocusSide()
{
   bool buyValid =
      ValidZone(
         g_buyZoneLow,
         g_buyZoneHigh
      );

   bool sellValid =
      ValidZone(
         g_sellZoneLow,
         g_sellZoneHigh
      );

   g_focusReason = "";

   if(!buyValid && !sellValid)
   {
      g_dynamicFocusSide = "NONE";
      g_focusReason = "NO VALID LOCKED ZONES";
      return g_dynamicFocusSide;
   }

   // Strongest case: R2 has a fully valid entry on a locked side.
   if(
      buyValid &&
      g_r2Side == "BUY" &&
      g_r2Score >= 70 &&
      R2LocationReadyForSide(true)
   )
   {
      g_dynamicFocusSide = "BUY";
      g_focusReason =
         "R2 BUY " +
         g_r2Strategy +
         " SCORE " +
         IntegerToString(g_r2Score) +
         " ENTRY VALID";
      return g_dynamicFocusSide;
   }

   if(
      sellValid &&
      g_r2Side == "SELL" &&
      g_r2Score >= 70 &&
      R2LocationReadyForSide(false)
   )
   {
      g_dynamicFocusSide = "SELL";
      g_focusReason =
         "R2 SELL " +
         g_r2Strategy +
         " SCORE " +
         IntegerToString(g_r2Score) +
         " ENTRY VALID";
      return g_dynamicFocusSide;
   }

   // If only one locked zone exists, focus must be that side.
   if(buyValid && !sellValid)
   {
      g_dynamicFocusSide = "BUY";
      g_focusReason = "ONLY LOCKED BUY ZONE ACTIVE";
      return g_dynamicFocusSide;
   }

   if(sellValid && !buyValid)
   {
      g_dynamicFocusSide = "SELL";
      g_focusReason = "ONLY LOCKED SELL ZONE ACTIVE";
      return g_dynamicFocusSide;
   }

   // Both zones exist. Prefer the side with a meaningful quality edge.
   int buyScore = ZoneStrengthScore(true);
   int sellScore = ZoneStrengthScore(false);

   if(buyScore >= sellScore + 5)
   {
      g_dynamicFocusSide = "BUY";
      g_focusReason =
         "BUY QUALITY " +
         IntegerToString(buyScore) +
         " > SELL " +
         IntegerToString(sellScore);
      return g_dynamicFocusSide;
   }

   if(sellScore >= buyScore + 5)
   {
      g_dynamicFocusSide = "SELL";
      g_focusReason =
         "SELL QUALITY " +
         IntegerToString(sellScore) +
         " > BUY " +
         IntegerToString(buyScore);
      return g_dynamicFocusSide;
   }

   // Comparable quality: focus the nearest locked zone.
   g_dynamicFocusSide = NearestZoneSide();
   g_focusReason =
      "COMPARABLE QUALITY | NEAREST " +
      g_dynamicFocusSide;

   return g_dynamicFocusSide;
}


string PrimarySide()
{
   if(!InpLockZoneIdentity)
      return ComputeDynamicPrimarySide();

   bool buyValid =
      ValidZone(
         g_buyZoneLow,
         g_buyZoneHigh
      );

   bool sellValid =
      ValidZone(
         g_sellZoneLow,
         g_sellZoneHigh
      );

   if(g_lockedPrimarySide == "BUY" && buyValid)
      return "BUY";

   if(g_lockedPrimarySide == "SELL" && sellValid)
      return "SELL";

   g_lockedPrimarySide = ComputeDynamicPrimarySide();

   if(g_lockedPrimarySide == "NONE")
      g_lockedPrimarySide = "";

   if(g_lockedPrimarySide != "")
   {
      g_lastZoneLifecycleEvent =
         "PRIMARY LOCKED " +
         g_lockedPrimarySide;

      Print(
         "ZONE LIFECYCLE | PRIMARY LOCKED ",
         g_lockedPrimarySide
      );

      SavePersistentZoneLifecycle();
      return g_lockedPrimarySide;
   }

   return "NONE";
}

bool IsStrongCounterTrend(string primarySide)
{
   if(g_r2Score < 85)
      return false;

   if(g_r2Side != "BUY" && g_r2Side != "SELL")
      return false;

   return g_r2Side != primarySide;
}


int RequiredConfirmations(string primarySide)
{
   return
      IsStrongCounterTrend(primarySide)
      ? 2
      : 1;
}


int DirectionalConfirmationCount(string primarySide)
{
   if(primarySide == "BUY")
      return g_buyTriggerCount;

   if(primarySide == "SELL")
      return g_sellTriggerCount;

   return 0;
}


string DirectionalConfirmationText(string primarySide)
{
   string first =
      primarySide == "BUY"
      ? g_buyTrigger1
      : g_sellTrigger1;

   string second =
      primarySide == "BUY"
      ? g_buyTrigger2
      : g_sellTrigger2;

   string text = "";

   if(first != "" && first != "NONE")
      text = first;

   if(
      second != "" &&
      second != "NONE"
   )
   {
      if(text != "")
         text += " + ";

      text += second;
   }

   if(text == "")
      return "NONE";

   return text;
}


bool ZoneTriggerSatisfied(string primarySide)
{
   return
      DirectionalConfirmationCount(primarySide) >=
      RequiredConfirmations(primarySide);
}


bool HasReadyTradePlan(string primarySide)
{
   if(
      g_r2AuditStatus != "READY" ||
      !g_r2TriggerReady ||
      !ZoneTriggerSatisfied(primarySide)
   )
      return false;

   if(g_r2Side != primarySide)
      return false;

   if(g_r2Entry <= 0.0 || g_r2SL <= 0.0 || g_r2TP1 <= 0.0)
      return false;

   if(primarySide == "BUY")
      return g_r2SL < g_r2Entry && g_r2TP1 > g_r2Entry;

   if(primarySide == "SELL")
      return g_r2SL > g_r2Entry && g_r2TP1 < g_r2Entry;

   return false;
}


string TradePlanText(string primarySide)
{
   if(!HasReadyTradePlan(primarySide))
   {
      string waitText =
         "STATUS: WAIT";

      if(g_r2AuditReason != "")
         waitText += " | " + g_r2AuditReason;

      waitText +=
         "\nTRADE PLAN: NOT READY";

      return waitText;
   }

   string plan =
      "STATUS: READY | " +
      g_r2Strategy +
      " | " +
      g_r2OrderType +
      "\nENTRY: " +
      DoubleToString(g_r2Entry, _Digits) +
      "\nSL: " +
      DoubleToString(g_r2SL, _Digits) +
      "\nTP1: " +
      DoubleToString(g_r2TP1, _Digits);

   if(g_r2TP2 > 0.0)
   {
      plan +=
         " | TP2: " +
         DoubleToString(g_r2TP2, _Digits);
   }

   plan +=
      "\nRR1: " +
      DoubleToString(g_r2RR, 2);

   return plan;
}


string CompactZoneReason(bool buy)
{
   string reason = "";
   string analysisId = ZoneAnalysisIdForSide(buy);
   string zoneType = ZoneTypeForSide(buy);

   if(StringFind(analysisId, "BREAKOUT_RETEST_BUY") >= 0)
      reason = buy ? "M5 breakout retest support" : "Opposite reaction zone";
   else if(StringFind(analysisId, "BREAKOUT_RETEST_SELL") >= 0)
      reason = buy ? "Opposite reaction zone" : "M5 breakout retest resistance";
   else if(StringFind(analysisId, "TREND_PULLBACK_BUY") >= 0)
      reason = buy ? "M5 EMA20/50 pullback support" : "Opposite reaction zone";
   else if(StringFind(analysisId, "TREND_PULLBACK_SELL") >= 0)
      reason = buy ? "Opposite reaction zone" : "M5 EMA20/50 pullback resistance";
   else if(StringFind(analysisId, "RANGE_REVERSION") >= 0)
      reason = buy ? "M30 range lower edge" : "M30 range upper edge";
   else if(zoneType == "WATCH_HIGH_VOLATILITY")
      reason = buy ? "M1/M5 volatility support" : "M1/M5 volatility resistance";
   else if(zoneType == "WATCH_TRANSITION")
      reason = buy ? "M5 structural support edge" : "M5 structural resistance edge";
   else
      reason = buy ? "Structural buy reaction area" : "Structural sell reaction area";

   string side = buy ? "BUY" : "SELL";

   if(
      g_r2Side == side &&
      g_r2Score >= 70
   )
   {
      if(R2LocationReadyForSide(buy))
      {
         reason +=
            " + R2 " +
            g_r2Strategy +
            " " +
            IntegerToString(g_r2Score);
      }
      else
      {
         reason +=
            " | R2 bias " +
            g_r2Side +
            " " +
            IntegerToString(g_r2Score) +
            " not at zone";
      }
   }
   else if(
      g_r2Side != "" &&
      g_r2Side != side &&
      g_r2Score >= 70 &&
      R2LocationReadyForSide(!buy)
   )
   {
      reason +=
         " | counter to R2 " +
         g_r2Side +
         " " +
         IntegerToString(g_r2Score);
   }

   return reason;
}


bool M5BarTouchesZone(
   MqlRates &bar,
   double zoneLow,
   double zoneHigh
)
{
   return
      ValidZone(zoneLow, zoneHigh) &&
      bar.high >= zoneLow &&
      bar.low <= zoneHigh;
}


string MostRecentTouchedZoneSide()
{
   g_recentZoneSide = "NONE";
   g_recentZoneTouchTime = 0;

   int lookback =
      MathMax(
         1,
         InpSimpleConfirmLookbackM5Bars
      );

   MqlRates bars[];
   ArraySetAsSeries(bars, true);

   int copied =
      CopyRates(
         _Symbol,
         PERIOD_M5,
         1,
         lookback,
         bars
      );

   if(copied <= 0)
      return "NONE";

   datetime buyTouch = 0;
   datetime sellTouch = 0;

   for(int i = 0; i < copied; i++)
   {
      if(
         buyTouch == 0 &&
         ValidZone(g_buyZoneLow, g_buyZoneHigh) &&
         M5BarTouchesZone(
            bars[i],
            g_buyZoneLow,
            g_buyZoneHigh
         )
      )
      {
         buyTouch = bars[i].time;
      }

      if(
         sellTouch == 0 &&
         ValidZone(g_sellZoneLow, g_sellZoneHigh) &&
         M5BarTouchesZone(
            bars[i],
            g_sellZoneLow,
            g_sellZoneHigh
         )
      )
      {
         sellTouch = bars[i].time;
      }

      if(buyTouch > 0 && sellTouch > 0)
         break;
   }

   if(buyTouch == 0 && sellTouch == 0)
      return "NONE";

   if(buyTouch >= sellTouch)
   {
      g_recentZoneSide = "BUY";
      g_recentZoneTouchTime = buyTouch;
   }
   else
   {
      g_recentZoneSide = "SELL";
      g_recentZoneTouchTime = sellTouch;
   }

   return g_recentZoneSide;
}


string SimpleActionSide()
{
   bool insideBuy = PriceInsideZone("BUY");
   bool insideSell = PriceInsideZone("SELL");

   // 1) Current interaction always wins.
   if(insideBuy && !insideSell)
      return "BUY";

   if(insideSell && !insideBuy)
      return "SELL";

   // 2) If price just reacted from a locked zone, keep evaluating that
   // side for the confirmation window. R2 is caution only, never selector.
   string recentSide =
      MostRecentTouchedZoneSide();

   if(recentSide == "BUY" || recentSide == "SELL")
      return recentSide;

   // 3) No recent interaction: watch the nearest locked zone.
   return NearestZoneSide();
}

bool SimpleM5Confirmation(
   string side,
   string &confirmText
)
{
   confirmText = "NONE";

   bool buy = side == "BUY";
   bool sell = side == "SELL";

   if(!buy && !sell)
      return false;

   double zoneLow =
      buy
      ? g_buyZoneLow
      : g_sellZoneLow;

   double zoneHigh =
      buy
      ? g_buyZoneHigh
      : g_sellZoneHigh;

   if(!ValidZone(zoneLow, zoneHigh))
      return false;

   int lookback =
      MathMax(
         1,
         InpSimpleConfirmLookbackM5Bars
      );

   MqlRates bars[];
   ArraySetAsSeries(bars, true);

   int needBars = lookback + 2;
   int copied =
      CopyRates(
         _Symbol,
         PERIOD_M5,
         1,
         needBars,
         bars
      );

   if(copied < 2)
      return false;

   bool recentTouch = false;

   int maxTouchIndex =
      MathMin(
         lookback - 1,
         copied - 1
      );

   for(int i = 0; i <= maxTouchIndex; i++)
   {
      if(M5BarTouchesZone(bars[i], zoneLow, zoneHigh))
      {
         recentTouch = true;
         break;
      }
   }

   if(!recentTouch)
      return false;

   MqlRates last = bars[0];
   MqlRates prev = bars[1];

   double zoneMid =
      (zoneLow + zoneHigh) /
      2.0;

   // 1) Clean rejection: candle interacted with the zone and closed
   // back out in the intended direction.
   if(
      M5BarTouchesZone(last, zoneLow, zoneHigh)
   )
   {
      if(buy && last.close > zoneHigh)
      {
         confirmText = "M5 BULLISH REJECTION";
         return true;
      }

      if(sell && last.close < zoneLow)
      {
         confirmText = "M5 BEARISH REJECTION";
         return true;
      }
   }

   // 2) Practical directional close after a recent touch.
   if(
      buy &&
      last.close > last.open &&
      last.close >= zoneMid
   )
   {
      confirmText = "M5 BULLISH CLOSE";
      return true;
   }

   if(
      sell &&
      last.close < last.open &&
      last.close <= zoneMid
   )
   {
      confirmText = "M5 BEARISH CLOSE";
      return true;
   }

   // 3) Micro structure break after a recent touch.
   if(
      buy &&
      last.close > prev.high
   )
   {
      confirmText = "M5 BREAK PREVIOUS HIGH";
      return true;
   }

   if(
      sell &&
      last.close < prev.low
   )
   {
      confirmText = "M5 BREAK PREVIOUS LOW";
      return true;
   }

   return false;
}


void ClearReadyLatch()
{
   g_readyLatched = false;
   g_latchedSide = "NONE";
   g_latchedWhy = "";
   g_latchedEntry = 0.0;
   g_latchedSL = 0.0;
   g_latchedTP = 0.0;
   g_latchedAt = 0;
}


void LatchReadyDecision()
{
   if(!InpLatchReadySignal)
      return;

   if(
      g_simpleDecision != "BUY READY" &&
      g_simpleDecision != "SELL READY"
   )
      return;

   g_readyLatched = true;
   g_latchedSide = g_simpleDecisionSide;
   g_latchedWhy = g_simpleWhy;
   g_latchedEntry = g_simpleEntry;
   g_latchedSL = g_simpleSL;
   g_latchedTP = g_simpleTP;
   g_latchedAt = TimeCurrent();
}


bool ReadyLatchStillValid()
{
   if(!InpLatchReadySignal || !g_readyLatched)
      return false;

   if(g_latchedSide != "BUY" && g_latchedSide != "SELL")
      return false;

   // Structural invalidation cancels the latch immediately.
   if(g_latchedSide == "BUY")
   {
      if(
         !ValidZone(g_buyZoneLow, g_buyZoneHigh) ||
         (
            g_buyInvalidation > 0.0 &&
            LastClosedZoneTFPrice(
               g_buyInvalidationTf == ""
               ? "M5"
               : g_buyInvalidationTf
            ) < g_buyInvalidation
         )
      )
      {
         ClearReadyLatch();
         return false;
      }
   }
   else
   {
      if(
         !ValidZone(g_sellZoneLow, g_sellZoneHigh) ||
         (
            g_sellInvalidation > 0.0 &&
            LastClosedZoneTFPrice(
               g_sellInvalidationTf == ""
               ? "M5"
               : g_sellInvalidationTf
            ) > g_sellInvalidation
         )
      )
      {
         ClearReadyLatch();
         return false;
      }
   }

   if(
      InpReadyLatchMinutes > 0 &&
      g_latchedAt > 0 &&
      TimeCurrent() - g_latchedAt >
      InpReadyLatchMinutes * 60
   )
   {
      // Do not clear while an actual position is open.
      if(!HasPositionOnSymbol())
      {
         ClearReadyLatch();
         return false;
      }
   }

   return true;
}


void ResetActiveDashboardState()
{
   g_activePositionCount = 0;
   g_activeBuyCount = 0;
   g_activeSellCount = 0;
   g_activeTotalVolume = 0.0;
   g_activeAvgEntry = 0.0;
   g_activeFloatingPnL = 0.0;
   g_activeSLState = "NOT SET";
   g_activeTPState = "NOT SET";
   g_activeSLValue = 0.0;
   g_activeTPValue = 0.0;
   g_activePlanSLGuide = 0.0;
   g_activePlanTPGuide = 0.0;
}

bool GetOpenSymbolPositionSummary(string &side)
{
   ResetActiveDashboardState();
   side = "NONE";

   int total = PositionsTotal();
   double weightedEntry = 0.0;
   int slSetCount = 0;
   int tpSetCount = 0;
   bool slMixed = false;
   bool tpMixed = false;
   double firstSL = 0.0;
   double firstTP = 0.0;
   double priceTolerance = MathMax(_Point * 2.0, 0.0000001);

   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      long type = PositionGetInteger(POSITION_TYPE);
      double volume = PositionGetDouble(POSITION_VOLUME);
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      double profit = PositionGetDouble(POSITION_PROFIT);
      double swap = PositionGetDouble(POSITION_SWAP);

      g_activePositionCount++;

      if(type == POSITION_TYPE_BUY)
         g_activeBuyCount++;
      else if(type == POSITION_TYPE_SELL)
         g_activeSellCount++;

      g_activeTotalVolume += volume;
      weightedEntry += entry * volume;
      g_activeFloatingPnL += profit + swap;

      if(sl > 0.0)
      {
         slSetCount++;
         if(firstSL <= 0.0)
            firstSL = sl;
         else if(MathAbs(sl - firstSL) > priceTolerance)
            slMixed = true;
      }

      if(tp > 0.0)
      {
         tpSetCount++;
         if(firstTP <= 0.0)
            firstTP = tp;
         else if(MathAbs(tp - firstTP) > priceTolerance)
            tpMixed = true;
      }
   }

   if(g_activePositionCount <= 0)
      return false;

   if(g_activeTotalVolume > 0.0)
      g_activeAvgEntry = weightedEntry / g_activeTotalVolume;

   if(g_activeBuyCount > 0 && g_activeSellCount == 0)
      side = "BUY";
   else if(g_activeSellCount > 0 && g_activeBuyCount == 0)
      side = "SELL";
   else
      side = "MIXED";

   if(slSetCount == 0)
      g_activeSLState = "NOT SET";
   else if(slSetCount < g_activePositionCount)
      g_activeSLState = "PARTIAL " + IntegerToString(slSetCount) + "/" + IntegerToString(g_activePositionCount);
   else if(slMixed)
      g_activeSLState = "MIXED LEVELS";
   else
   {
      g_activeSLState = "SET";
      g_activeSLValue = firstSL;
   }

   if(tpSetCount == 0)
      g_activeTPState = "NOT SET";
   else if(tpSetCount < g_activePositionCount)
      g_activeTPState = "PARTIAL " + IntegerToString(tpSetCount) + "/" + IntegerToString(g_activePositionCount);
   else if(tpMixed)
      g_activeTPState = "MIXED LEVELS";
   else
   {
      g_activeTPState = "SET";
      g_activeTPValue = firstTP;
   }

   return true;
}

void BuildActivePlanGuide(string side)
{
   g_activePlanSLGuide = 0.0;
   g_activePlanTPGuide = 0.0;

   if(side != "BUY" && side != "SELL")
      return;

   bool buy = side == "BUY";

   double zoneLow = buy ? g_buyZoneLow : g_sellZoneLow;
   double zoneHigh = buy ? g_buyZoneHigh : g_sellZoneHigh;
   double invalidation = buy ? g_buyInvalidation : g_sellInvalidation;

   if(!ValidZone(zoneLow, zoneHigh))
      return;

   double zoneWidth = MathMax(zoneHigh - zoneLow, _Point * 10.0);
   double slBuffer = MathMax(zoneWidth * InpSimpleSLBufferZoneFraction, _Point * 10.0);

   if(buy)
   {
      double baseSL = invalidation > 0.0 ? invalidation : zoneLow;
      g_activePlanSLGuide = NormalizeDouble(baseSL - slBuffer, _Digits);
   }
   else
   {
      double baseSL = invalidation > 0.0 ? invalidation : zoneHigh;
      g_activePlanSLGuide = NormalizeDouble(baseSL + slBuffer, _Digits);
   }

   if(g_activeAvgEntry <= 0.0 || g_activePlanSLGuide <= 0.0)
      return;

   double risk = MathAbs(g_activeAvgEntry - g_activePlanSLGuide);
   if(risk <= _Point)
      return;

   g_activePlanTPGuide =
      NormalizeDouble(
         buy
         ? g_activeAvgEntry + risk * InpSimpleRR
         : g_activeAvgEntry - risk * InpSimpleRR,
         _Digits
      );
}

void BuildSimpleDecision()
{
   // First priority: if there is an actual open trade on this symbol,
   // keep the screen in ACTIVE state. Do not fall back to WAIT just
   // because the one-candle confirmation has expired.
   string activeSide = "NONE";

   if(GetOpenSymbolPositionSummary(activeSide))
   {
      BuildActivePlanGuide(activeSide);

      if(activeSide == "MIXED")
      {
         g_simpleDecision = "MIXED ACTIVE";
         g_simpleDecisionSide = "NONE";
         g_simpleConfirmText = "HEDGED POSITIONS";
         g_simpleWhy =
            "BUY " + IntegerToString(g_activeBuyCount) +
            " / SELL " + IntegerToString(g_activeSellCount) +
            " | REVIEW EXPOSURE";
         g_simpleEntry = 0.0;
         g_simpleSL = 0.0;
         g_simpleTP = 0.0;
         return;
      }

      g_simpleDecision = activeSide + " ACTIVE";
      g_simpleDecisionSide = activeSide;
      g_simpleConfirmText = g_readyLatched ? g_latchedWhy : "OPEN POSITION";
      g_simpleWhy =
         IntegerToString(g_activePositionCount) +
         " OPEN " + activeSide +
         " POSITION" +
         (g_activePositionCount == 1 ? "" : "S");

      g_simpleEntry = g_activeAvgEntry;

      // Actual broker-side SL/TP only. Plan guides are separate.
      g_simpleSL = g_activeSLState == "SET" ? g_activeSLValue : 0.0;
      g_simpleTP = g_activeTPState == "SET" ? g_activeTPValue : 0.0;

      return;
   }

   g_simpleDecision = "WAIT";
   g_simpleDecisionSide = "NONE";
   g_simpleConfirmText = "NONE";
   g_simpleWhy = "WAIT FOR PRICE AT A VALID ZONE";
   g_simpleEntry = 0.0;
   g_simpleSL = 0.0;
   g_simpleTP = 0.0;

   // Second priority: preserve a recently issued READY signal.
   if(ReadyLatchStillValid())
   {
      g_simpleDecision = g_latchedSide + " READY";
      g_simpleDecisionSide = g_latchedSide;
      g_simpleConfirmText = g_latchedWhy;
      g_simpleWhy =
         g_latchedWhy +
         " | SIGNAL LATCHED";
      g_simpleEntry = g_latchedEntry;
      g_simpleSL = g_latchedSL;
      g_simpleTP = g_latchedTP;
      return;
   }

   if(!InpSimpleDecisionMode)
      return;

   string side = SimpleActionSide();

   if(side != "BUY" && side != "SELL")
   {
      g_simpleWhy = "NO VALID LOCKED ZONE";
      return;
   }

   bool buy = side == "BUY";

   double zoneLow =
      buy
      ? g_buyZoneLow
      : g_sellZoneLow;

   double zoneHigh =
      buy
      ? g_buyZoneHigh
      : g_sellZoneHigh;

   double invalidation =
      buy
      ? g_buyInvalidation
      : g_sellInvalidation;

   if(!ValidZone(zoneLow, zoneHigh))
   {
      g_simpleWhy = "NO VALID " + side + " ZONE";
      return;
   }

   g_simpleDecisionSide = side;

   string confirmation = "NONE";
   bool confirmed =
      SimpleM5Confirmation(
         side,
         confirmation
      );

   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
   {
      g_simpleWhy = "WAIT FOR MARKET TICK";
      return;
   }

   double currentEntry =
      buy
      ? tick.ask
      : tick.bid;

   double zoneWidth =
      MathMax(
         zoneHigh - zoneLow,
         _Point * 10.0
      );

   double slBuffer =
      MathMax(
         zoneWidth *
         InpSimpleSLBufferZoneFraction,
         _Point * 10.0
      );

   if(buy)
   {
      double baseSL =
         invalidation > 0.0
         ? invalidation
         : zoneLow;

      g_simpleSL =
         NormalizeDouble(
            baseSL - slBuffer,
            _Digits
         );
   }
   else
   {
      double baseSL =
         invalidation > 0.0
         ? invalidation
         : zoneHigh;

      g_simpleSL =
         NormalizeDouble(
            baseSL + slBuffer,
            _Digits
         );
   }

   double risk =
      MathAbs(
         currentEntry -
         g_simpleSL
      );

   if(risk <= _Point)
   {
      g_simpleWhy = "WAIT | INVALID RISK DISTANCE";
      return;
   }

   g_simpleEntry =
      NormalizeDouble(
         currentEntry,
         _Digits
      );

   g_simpleTP =
      NormalizeDouble(
         buy
         ? g_simpleEntry + risk * InpSimpleRR
         : g_simpleEntry - risk * InpSimpleRR,
         _Digits
      );

   bool nearOrRecentlyTouched = false;

   // A valid M5 confirmation already proves recent interaction.
   if(confirmed)
      nearOrRecentlyTouched = true;
   else if(PriceInsideZone(side))
      nearOrRecentlyTouched = true;

   if(!nearOrRecentlyTouched)
   {
      g_simpleWhy =
         "WAIT FOR " +
         side +
         " ZONE + ONE M5 CONFIRMATION";
      return;
   }

   if(!confirmed)
   {
      g_simpleWhy =
         "NEED ONE M5 " +
         (buy ? "BULLISH" : "BEARISH") +
         " CONFIRMATION";
      return;
   }

   g_simpleConfirmText = confirmation;
   g_simpleDecision = side + " READY";
   g_simpleWhy = confirmation;

   LatchReadyDecision();
}


string SimpleR2Text()
{
   if(
      g_r2Side == "" ||
      g_r2Side == "NONE" ||
      g_r2Score <= 0
   )
      return "R2: NEUTRAL / NO STRONG BIAS";

   if(
      g_simpleDecisionSide != "NONE" &&
      g_r2Side != g_simpleDecisionSide &&
      g_r2Score >= InpR2OppositeCautionScore
   )
   {
      return
         "R2: " +
         g_r2Side +
         " " +
         IntegerToString(g_r2Score) +
         " | CAUTION ONLY";
   }

   if(g_r2Side == g_simpleDecisionSide)
   {
      return
         "R2: " +
         g_r2Side +
         " " +
         IntegerToString(g_r2Score) +
         " | ALIGNED";
   }

   return
      "R2: " +
      g_r2Side +
      " " +
      IntegerToString(g_r2Score);
}


string PanelRowName(int row)
{
   return
      ZONE_PANEL_ROW_PREFIX +
      IntegerToString(row);
}


void DeleteCompactZonePanel()
{
   ObjectDelete(0, ZONE_PANEL_OBJECT);
   ObjectDelete(0, ZONE_PANEL_HEADER_OBJECT);

   for(int i = 0; i < 14; i++)
      ObjectDelete(0, PanelRowName(i));
}


void DrawPanelBox(
   string name,
   int x,
   int y,
   int width,
   int height,
   color bg,
   color border
)
{
   if(ObjectFind(0, name) < 0)
   {
      if(
         !ObjectCreate(
            0,
            name,
            OBJ_RECTANGLE_LABEL,
            0,
            0,
            0
         )
      )
      {
         return;
      }
   }

   ObjectSetInteger(0, name, OBJPROP_CORNER, InpPanelCorner);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, height);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, name, OBJPROP_COLOR, border);
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTED, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}


void DrawPanelBackground(color headerColor)
{
   DrawPanelBox(
      ZONE_PANEL_OBJECT,
      InpPanelX,
      InpPanelY,
      InpPanelWidth,
      InpPanelHeight,
      InpPanelBgColor,
      InpPanelBorderColor
   );

   DrawPanelBox(
      ZONE_PANEL_HEADER_OBJECT,
      InpPanelX,
      InpPanelY,
      InpPanelWidth,
      30,
      headerColor,
      headerColor
   );
}


void DrawPanelRow(
   int row,
   string text,
   color textColor,
   int fontSize = 0
)
{
   string name =
      PanelRowName(row);

   if(ObjectFind(0, name) < 0)
   {
      if(
         !ObjectCreate(
            0,
            name,
            OBJ_LABEL,
            0,
            0,
            0
         )
      )
      {
         return;
      }
   }

   int actualFontSize =
      fontSize > 0
      ? fontSize
      : InpPanelFontSize;

   int y =
      row == 0
      ? InpPanelY + 7
      : InpPanelY + 35 + (row - 1) * InpPanelRowHeight;

   ObjectSetInteger(0, name, OBJPROP_CORNER, InpPanelCorner);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, InpPanelX + 12);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, actualFontSize);
   ObjectSetInteger(0, name, OBJPROP_COLOR, textColor);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTED, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);

   ObjectSetString(0, name, OBJPROP_FONT, "Segoe UI");
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_TOOLTIP, text);
}

bool PriceInsideZone(string side)
{
   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   double mid =
      (tick.bid + tick.ask) /
      2.0;

   if(side == "BUY")
   {
      return
         ValidZone(g_buyZoneLow, g_buyZoneHigh) &&
         mid >= g_buyZoneLow &&
         mid <= g_buyZoneHigh;
   }

   if(side == "SELL")
   {
      return
         ValidZone(g_sellZoneLow, g_sellZoneHigh) &&
         mid >= g_sellZoneLow &&
         mid <= g_sellZoneHigh;
   }

   return false;
}


string PanelMarketStatus(string primarySide)
{
   if(
      (primarySide == "BUY" || primarySide == "SELL") &&
      HasReadyTradePlan(primarySide)
   )
   {
      return
         "READY " +
         primarySide;
   }

   if(primarySide == "BUY" && PriceInsideZone("BUY"))
      return "IN BUY ZONE";

   if(primarySide == "SELL" && PriceInsideZone("SELL"))
      return "IN SELL ZONE";

   return "WAIT";
}


void DrawCompactZonePanel()
{
   if(!InpShowCompactPanel || !InpShowZoneEngineStatus)
   {
      DeleteCompactZonePanel();
      return;
   }

   BuildSimpleDecision();

   bool readyBuy = g_simpleDecision == "BUY READY";
   bool readySell = g_simpleDecision == "SELL READY";
   bool activeBuy = g_simpleDecision == "BUY ACTIVE";
   bool activeSell = g_simpleDecision == "SELL ACTIVE";
   bool activeMixed = g_simpleDecision == "MIXED ACTIVE";
   bool activeTrade = activeBuy || activeSell || activeMixed;

   color statusColor =
      (readyBuy || activeBuy)
      ? InpPanelBuyColor
      : (
         (readySell || activeSell)
         ? InpPanelSellColor
         : (
            activeMixed
            ? InpPanelWarningColor
            : InpPanelWaitColor
           )
        );

   DrawPanelBackground(statusColor);

   // Clear rows that might have been used by a prior state.
   for(int i = 0; i < 14; i++)
   {
      string rowName = PanelRowName(i);

      if(ObjectFind(0, rowName) >= 0)
         ObjectSetString(0, rowName, OBJPROP_TEXT, "");
   }

   DrawPanelRow(
      0,
      g_simpleDecision,
      clrWhite,
      InpPanelTitleFontSize
   );

   // ============================================================
   // ACTIVE POSITION VIEW
   // ============================================================
   if(activeTrade)
   {
      string activeSide =
         activeBuy
         ? "BUY"
         : (
            activeSell
            ? "SELL"
            : "MIXED"
           );

      DrawPanelRow(
         1,
         "POSITIONS  " +
         IntegerToString(g_activePositionCount) +
         "   |   " +
         DoubleToString(g_activeTotalVolume, 2) +
         " LOT   |   " +
         activeSide,
         InpPanelTextColor
      );

      if(!activeMixed)
      {
         DrawPanelRow(
            2,
            "AVG ENTRY  " +
            DoubleToString(g_activeAvgEntry, _Digits) +
            "   |   FLOAT  $" +
            DoubleToString(g_activeFloatingPnL, 2),
            g_activeFloatingPnL >= 0.0
            ? InpPanelBuyColor
            : InpPanelSellColor
         );
      }
      else
      {
         DrawPanelRow(
            2,
            "BUY " +
            IntegerToString(g_activeBuyCount) +
            "   |   SELL " +
            IntegerToString(g_activeSellCount) +
            "   |   FLOAT $" +
            DoubleToString(g_activeFloatingPnL, 2),
            InpPanelWarningColor
         );
      }

      string slLine = "SL  ";
      if(g_activeSLState == "SET" && g_activeSLValue > 0.0)
      {
         slLine +=
            DoubleToString(g_activeSLValue, _Digits) +
            "   |   ALL SET";
      }
      else
      {
         slLine += g_activeSLState;
      }

      DrawPanelRow(
         3,
         slLine,
         g_activeSLState == "SET"
         ? InpPanelBuyColor
         : InpPanelSellColor
      );

      string tpLine = "TP  ";

      if(g_activeTPState == "SET" && g_activeTPValue > 0.0)
      {
         tpLine +=
            DoubleToString(g_activeTPValue, _Digits) +
            "   |   ALL SET";
      }
      else if(g_activeTPState == "MIXED LEVELS")
      {
         tpLine =
            "TP  " +
            DoubleToString(InpSimpleRR, 1) +
            "R PER POSITION   |   ALL SET";
      }
      else
      {
         tpLine += g_activeTPState;
      }

      DrawPanelRow(
         4,
         tpLine,
         (
            g_activeTPState == "SET" ||
            g_activeTPState == "MIXED LEVELS"
         )
         ? InpPanelBuyColor
         : InpPanelWaitColor
      );

      if(!activeMixed)
      {
         if(activeBuy)
         {
            DrawPanelRow(
               5,
               "ZONE  BUY  " +
               DoubleToString(g_buyZoneLow, _Digits) +
               " - " +
               DoubleToString(g_buyZoneHigh, _Digits),
               InpPanelBuyColor
            );

            DrawPanelRow(
               6,
               "FAIL  M5 CLOSE < " +
               DoubleToString(g_buyInvalidation, _Digits) +
               "   |   ANALYSIS ONLY",
               InpPanelMutedColor
            );
         }
         else
         {
            DrawPanelRow(
               5,
               "ZONE  SELL  " +
               DoubleToString(g_sellZoneLow, _Digits) +
               " - " +
               DoubleToString(g_sellZoneHigh, _Digits),
               InpPanelSellColor
            );

            DrawPanelRow(
               6,
               "FAIL  M5 CLOSE > " +
               DoubleToString(g_sellInvalidation, _Digits) +
               "   |   ANALYSIS ONLY",
               InpPanelMutedColor
            );
         }
      }
      else
      {
         DrawPanelRow(
            5,
            "MIXED EXPOSURE   |   REVIEW POSITIONS",
            InpPanelWarningColor
         );
      }

      string protectLine =
         "PROTECTION  " +
         g_protectionStatus;

      DrawPanelRow(
         7,
         protectLine,
         StringFind(g_protectionStatus, "ALL PROTECTED") >= 0
         ? InpPanelBuyColor
         : (
            StringFind(g_protectionStatus, "FAILED") >= 0
            ? InpPanelSellColor
            : InpPanelMutedColor
           )
      );

      DrawPanelRow(
         8,
         "MANAGER  " +
         g_managerStatus,
         StringFind(g_managerStatus, "PAUSED") >= 0
         ? InpPanelWarningColor
         : (
            StringFind(g_managerStatus, "TRAIL") >= 0 ||
            StringFind(g_managerStatus, "TP1 DONE") >= 0
            ? InpPanelBuyColor
            : InpPanelMutedColor
           )
      );

      DrawPanelRow(
         9,
         SimpleR2Text(),
         StringFind(SimpleR2Text(), "CAUTION") >= 0
         ? InpPanelWarningColor
         : InpPanelMutedColor
      );

      ChartRedraw(0);
      return;
   }

   // ============================================================
   // READY / WAIT VIEW
   // ============================================================
   string side =
      g_simpleDecisionSide;

   if(side != "BUY" && side != "SELL")
      side = SimpleActionSide();

   if(side == "BUY" && ValidZone(g_buyZoneLow, g_buyZoneHigh))
   {
      DrawPanelRow(
         1,
         "ZONE  BUY  " +
         DoubleToString(g_buyZoneLow, _Digits) +
         " - " +
         DoubleToString(g_buyZoneHigh, _Digits),
         InpPanelBuyColor
      );
   }
   else if(side == "SELL" && ValidZone(g_sellZoneLow, g_sellZoneHigh))
   {
      DrawPanelRow(
         1,
         "ZONE  SELL  " +
         DoubleToString(g_sellZoneLow, _Digits) +
         " - " +
         DoubleToString(g_sellZoneHigh, _Digits),
         InpPanelSellColor
      );
   }
   else
   {
      DrawPanelRow(
         1,
         "ZONE  NONE",
         InpPanelMutedColor
      );
   }

   if(readyBuy || readySell)
   {
      DrawPanelRow(
         2,
         "ENTRY  " +
         DoubleToString(g_simpleEntry, _Digits),
         InpPanelTextColor
      );

      DrawPanelRow(
         3,
         "SL  " +
         DoubleToString(g_simpleSL, _Digits),
         InpPanelSellColor
      );

      DrawPanelRow(
         4,
         "TP  " +
         DoubleToString(g_simpleTP, _Digits) +
         "   |   " +
         DoubleToString(InpSimpleRR, 1) +
         "R",
         InpPanelBuyColor
      );

      DrawPanelRow(
         5,
         "WHY  " +
         g_simpleWhy,
         InpPanelTextColor
      );

      DrawPanelRow(
         6,
         "AUTO PROTECT  " +
         (
            InpAutoProtectPositions
            ? "ON"
            : "OFF"
         ),
         InpAutoProtectPositions
         ? InpPanelBuyColor
         : InpPanelWarningColor
      );

      DrawPanelRow(
         7,
         SimpleR2Text(),
         StringFind(SimpleR2Text(), "CAUTION") >= 0
         ? InpPanelWarningColor
         : InpPanelMutedColor
      );

      DrawPanelRow(
         8,
         "MANAGER  " +
         (
            InpEnableActiveTradeManager
            ? "ON | TP1 " +
              DoubleToString(InpManagerPartialAtR, 1) +
              "R | BE " +
              DoubleToString(InpManagerBEAtR, 1) +
              "R | TRAIL " +
              DoubleToString(InpManagerTrailStartR, 1) +
              "R"
            : "OFF"
         ),
         InpEnableActiveTradeManager
         ? InpPanelMutedColor
         : InpPanelWarningColor
      );
   }
   else
   {
      string recentLine = "LAST TOUCH  NONE";

      if(
         g_recentZoneSide != "NONE" &&
         g_recentZoneTouchTime > 0
      )
      {
         recentLine =
            "LAST TOUCH  " +
            g_recentZoneSide +
            "  " +
            TimeToString(
               g_recentZoneTouchTime,
               TIME_MINUTES
            );
      }

      DrawPanelRow(
         2,
         recentLine,
         InpPanelMutedColor
      );

      DrawPanelRow(
         3,
         "NEED  ONE M5 " +
         (
            side == "BUY"
            ? "BULLISH"
            : (
               side == "SELL"
               ? "BEARISH"
               : ""
              )
         ) +
         " CONFIRMATION",
         InpPanelTextColor
      );

      if(side == "BUY" && g_buyInvalidation > 0.0)
      {
         DrawPanelRow(
            4,
            "FAIL  M5 CLOSE < " +
            DoubleToString(g_buyInvalidation, _Digits),
            InpPanelMutedColor
         );
      }
      else if(side == "SELL" && g_sellInvalidation > 0.0)
      {
         DrawPanelRow(
            4,
            "FAIL  M5 CLOSE > " +
            DoubleToString(g_sellInvalidation, _Digits),
            InpPanelMutedColor
         );
      }

      DrawPanelRow(
         5,
         "AUTO PROTECT  " +
         (
            InpAutoProtectPositions
            ? "ON"
            : "OFF"
         ),
         InpAutoProtectPositions
         ? InpPanelBuyColor
         : InpPanelWarningColor
      );

      DrawPanelRow(
         6,
         SimpleR2Text(),
         StringFind(SimpleR2Text(), "CAUTION") >= 0
         ? InpPanelWarningColor
         : InpPanelMutedColor
      );

      DrawPanelRow(
         7,
         "MANAGER  " +
         (
            InpEnableActiveTradeManager
            ? "ON | TP1 " +
              DoubleToString(InpManagerPartialAtR, 1) +
              "R | BE " +
              DoubleToString(InpManagerBEAtR, 1) +
              "R | TRAIL " +
              DoubleToString(InpManagerTrailStartR, 1) +
              "R"
            : "OFF"
         ),
         InpEnableActiveTradeManager
         ? InpPanelMutedColor
         : InpPanelWarningColor
      );
   }

   ChartRedraw(0);
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
      "LOCKED BUY WAIT ZONE " +
      DoubleToString(g_buyZoneLow, _Digits) +
      " - " +
      DoubleToString(g_buyZoneHigh, _Digits) +
      " | " +
      ZoneGrade(true) +
      " | " +
      ZoneBias(true) +
      " | " +
      ZoneReason(true) +
      " | INVALIDATION " +
      DoubleToString(g_buyInvalidation, _Digits) +
      " | " +
      ZoneInvalidationRuleText(true) +
      " | " +
      ZoneInvalidationReason(true)
   );

   DrawDecisionZoneBand(
      ZONE_SELL_OBJECT,
      g_sellZoneLow,
      g_sellZoneHigh,
      InpSellZoneColor,
      "LOCKED SELL WAIT ZONE " +
      DoubleToString(g_sellZoneLow, _Digits) +
      " - " +
      DoubleToString(g_sellZoneHigh, _Digits) +
      " | " +
      ZoneGrade(false) +
      " | " +
      ZoneBias(false) +
      " | " +
      ZoneReason(false) +
      " | INVALIDATION " +
      DoubleToString(g_sellInvalidation, _Digits) +
      " | " +
      ZoneInvalidationRuleText(false) +
      " | " +
      ZoneInvalidationReason(false)
   );

   if(
      !InpCleanChartMode &&
      ValidZone(g_buyZoneLow, g_buyZoneHigh)
   )
   {
      DrawR1HLine(
         R1_BUY_LOW_LINE,
         g_buyZoneLow,
         InpBuyZoneColor,
         STYLE_DOT,
         1,
         "R1 BUY ZONE LOW"
      );

      DrawR1HLine(
         R1_BUY_HIGH_LINE,
         g_buyZoneHigh,
         InpBuyZoneColor,
         STYLE_DOT,
         1,
         "R1 BUY ZONE HIGH"
      );
   }
   else
   {
      ObjectDelete(0, R1_BUY_LOW_LINE);
      ObjectDelete(0, R1_BUY_HIGH_LINE);
   }

   if(
      !InpCleanChartMode &&
      ValidZone(g_sellZoneLow, g_sellZoneHigh)
   )
   {
      DrawR1HLine(
         R1_SELL_LOW_LINE,
         g_sellZoneLow,
         InpSellZoneColor,
         STYLE_DOT,
         1,
         "R1 SELL ZONE LOW"
      );

      DrawR1HLine(
         R1_SELL_HIGH_LINE,
         g_sellZoneHigh,
         InpSellZoneColor,
         STYLE_DOT,
         1,
         "R1 SELL ZONE HIGH"
      );
   }
   else
   {
      ObjectDelete(0, R1_SELL_LOW_LINE);
      ObjectDelete(0, R1_SELL_HIGH_LINE);
   }

   if(
      ValidZone(g_buyZoneLow, g_buyZoneHigh) &&
      g_buyInvalidation > 0.0
   )
   {
      DrawR1HLine(
         R1_BUY_INVALIDATION_LINE,
         g_buyInvalidation,
         InpZoneInvalidationColor,
         STYLE_DASHDOT,
         2,
         "BUY ZONE INVALIDATION | " +
         DoubleToString(g_buyInvalidation, _Digits) +
         " | " +
         ZoneInvalidationRuleText(true) +
         " | " +
         ZoneInvalidationReason(true)
      );
   }
   else
   {
      ObjectDelete(0, R1_BUY_INVALIDATION_LINE);
   }

   if(
      ValidZone(g_sellZoneLow, g_sellZoneHigh) &&
      g_sellInvalidation > 0.0
   )
   {
      DrawR1HLine(
         R1_SELL_INVALIDATION_LINE,
         g_sellInvalidation,
         InpZoneInvalidationColor,
         STYLE_DASHDOT,
         2,
         "SELL ZONE INVALIDATION | " +
         DoubleToString(g_sellInvalidation, _Digits) +
         " | " +
         ZoneInvalidationRuleText(false) +
         " | " +
         ZoneInvalidationReason(false)
      );
   }
   else
   {
      ObjectDelete(0, R1_SELL_INVALIDATION_LINE);
   }

   bool armedVisible =
      !InpCleanChartMode &&
      (
      g_r1ArmedState == "READY" ||
      g_r1ArmedState == "ARMED_BLOCKED_REGIME" ||
      g_r1ArmedState == "ARMED_BLOCKED_FILTER"
      );

   if(armedVisible && g_r1ArmedEntry > 0.0)
   {
      ENUM_LINE_STYLE armedStyle =
         g_r1ArmedState == "READY"
         ? STYLE_SOLID
         : STYLE_DASH;

      int armedWidth =
         g_r1ArmedState == "READY"
         ? 2
         : 1;

      DrawR1HLine(
         R1_ARMED_TRIGGER_LINE,
         g_r1ArmedEntry,
         InpR1ArmedTriggerColor,
         armedStyle,
         armedWidth,
         "R1 " +
         g_r1ArmedOrderType +
         " TRIGGER | " +
         g_r1ArmedState
      );

      if(g_r1ArmedSL > 0.0)
      {
         DrawR1HLine(
            R1_ARMED_SL_LINE,
            g_r1ArmedSL,
            clrRed,
            STYLE_DASH,
            1,
            "R1 ARMED SL"
         );
      }

      if(g_r1ArmedTP > 0.0)
      {
         DrawR1HLine(
            R1_ARMED_TP_LINE,
            g_r1ArmedTP,
            clrLimeGreen,
            STYLE_DASH,
            1,
            "R1 ARMED TP | RR=" +
            DoubleToString(
               g_r1ArmedRR,
               2
            )
         );
      }
   }
   else
   {
      ObjectDelete(0, R1_ARMED_TRIGGER_LINE);
      ObjectDelete(0, R1_ARMED_SL_LINE);
      ObjectDelete(0, R1_ARMED_TP_LINE);
   }

   DrawCompactZonePanel();
   ChartRedraw(0);
}

void ClearDecisionZoneState()
{
   ResetPersistentZone(g_pBuyZone);
   ResetPersistentZone(g_pSellZone);
   g_lockedPrimarySide = "";
   g_lastZoneLifecycleEvent = "ZONE STATE CLEARED";
   SavePersistentZoneLifecycle();

   g_zoneAnalysisId = "";
   g_zoneType = "";
   g_zoneWatchReason = "";
   g_r2AuditStatus = "WATCH";
   g_r2AuditReason = "";
   g_r2Trigger = "NONE";
   g_r2TriggerCount = 0;
   g_r2TriggerReady = false;
   g_buyTriggerCount = 0;
   g_buyTrigger1 = "NONE";
   g_buyTrigger2 = "NONE";
   g_sellTriggerCount = 0;
   g_sellTrigger1 = "NONE";
   g_sellTrigger2 = "NONE";

   g_buyZoneLow = 0.0;
   g_buyZoneHigh = 0.0;
   g_sellZoneLow = 0.0;
   g_sellZoneHigh = 0.0;

   g_buyInvalidation = 0.0;
   g_sellInvalidation = 0.0;
   g_buyInvalidationTf = "";
   g_sellInvalidationTf = "";
   g_buyInvalidationRule = "";
   g_sellInvalidationRule = "";
   g_buyInvalidationReason = "";
   g_sellInvalidationReason = "";

   g_insideBuyZone = false;
   g_insideSellZone = false;

   g_r1ArmedState = "";
   g_r1ArmedSide = "";
   g_r1ArmedOrderType = "";
   g_r1ArmedEntry = 0.0;
   g_r1ArmedSL = 0.0;
   g_r1ArmedTP = 0.0;
   g_r1ArmedRR = 0.0;

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
            "No saved R1 scalp reference zones. Clearing R1 chart zones."
         );
      }

      if(InpLockZoneIdentity)
      {
         EvaluatePersistentZoneLifecycle();
         RefreshDecisionZoneObjects();

         Print(
            "Worker returned zones:null | persistent locked zones retained until structural invalidation."
         );

         return;
      }

      ClearDecisionZoneState();
      return;
   }

   string analysisId =
      JsonGetString(
         response,
         "analysis_id"
      );

   string zoneType =
      JsonGetString(
         response,
         "zone_type"
      );

   string zoneWatchReason =
      JsonGetString(
         response,
         "watch_reason"
      );

   string r2AuditStatus =
      JsonGetString(
         response,
         "r2_audit_status"
      );

   string r2AuditReason =
      JsonGetString(
         response,
         "r2_reason"
      );

   string r2Trigger =
      JsonGetString(
         response,
         "r2_trigger"
      );

   int r2TriggerCount =
      (int)JsonGetDouble(
         response,
         "r2_trigger_count"
      );

   bool r2TriggerReady =
      JsonGetDouble(
         response,
         "r2_trigger_ready"
      ) > 0.5;

   int buyTriggerCount =
      (int)JsonGetDouble(
         response,
         "buy_trigger_count"
      );

   string buyTrigger1 =
      JsonGetString(
         response,
         "buy_trigger_1"
      );

   string buyTrigger2 =
      JsonGetString(
         response,
         "buy_trigger_2"
      );

   int sellTriggerCount =
      (int)JsonGetDouble(
         response,
         "sell_trigger_count"
      );

   string sellTrigger1 =
      JsonGetString(
         response,
         "sell_trigger_1"
      );

   string sellTrigger2 =
      JsonGetString(
         response,
         "sell_trigger_2"
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

   double buyInvalidation =
      JsonGetDouble(
         response,
         "buy_invalidation"
      );

   double sellInvalidation =
      JsonGetDouble(
         response,
         "sell_invalidation"
      );

   string buyInvalidationTf =
      JsonGetString(
         response,
         "buy_invalidation_tf"
      );

   string sellInvalidationTf =
      JsonGetString(
         response,
         "sell_invalidation_tf"
      );

   string buyInvalidationRule =
      JsonGetString(
         response,
         "buy_invalidation_rule"
      );

   string sellInvalidationRule =
      JsonGetString(
         response,
         "sell_invalidation_rule"
      );

   string buyInvalidationReason =
      JsonGetString(
         response,
         "buy_invalidation_reason"
      );

   string sellInvalidationReason =
      JsonGetString(
         response,
         "sell_invalidation_reason"
      );

   string armedState =
      JsonGetString(
         response,
         "armed_state"
      );

   string armedSide =
      JsonGetString(
         response,
         "armed_side"
      );

   string armedOrderType =
      JsonGetString(
         response,
         "armed_order_type"
      );

   double armedEntry =
      JsonGetDouble(
         response,
         "armed_entry"
      );

   double armedSL =
      JsonGetDouble(
         response,
         "armed_sl"
      );

   double armedTP =
      JsonGetDouble(
         response,
         "armed_tp"
      );

   double armedRR =
      JsonGetDouble(
         response,
         "armed_rr"
      );

   g_zoneAnalysisId =
      analysisId;

   g_zoneType =
      zoneType;

   g_zoneWatchReason =
      zoneWatchReason;

   g_r2AuditStatus =
      r2AuditStatus == ""
      ? "WATCH"
      : r2AuditStatus;

   g_r2AuditReason =
      r2AuditReason;

   g_r2Trigger =
      r2Trigger == ""
      ? "NONE"
      : r2Trigger;

   g_r2TriggerCount =
      r2TriggerCount;

   g_r2TriggerReady =
      r2TriggerReady;

   g_buyTriggerCount =
      buyTriggerCount;

   g_buyTrigger1 =
      buyTrigger1 == ""
      ? "NONE"
      : buyTrigger1;

   g_buyTrigger2 =
      buyTrigger2 == ""
      ? "NONE"
      : buyTrigger2;

   g_sellTriggerCount =
      sellTriggerCount;

   g_sellTrigger1 =
      sellTrigger1 == ""
      ? "NONE"
      : sellTrigger1;

   g_sellTrigger2 =
      sellTrigger2 == ""
      ? "NONE"
      : sellTrigger2;

   if(InpLockZoneIdentity)
   {
      EvaluatePersistentZoneLifecycle();

      if(!g_pBuyZone.active && ValidZone(buyLow, buyHigh))
      {
         AdoptPersistentZone(
            g_pBuyZone,
            "BUY",
            analysisId,
            zoneType,
            zoneWatchReason,
            buyLow,
            buyHigh,
            buyInvalidation,
            buyInvalidationTf,
            buyInvalidationRule,
            buyInvalidationReason
         );
      }
      else if(g_pBuyZone.active)
      {
         g_pBuyZone.last_seen_at = TimeCurrent();
      }

      if(!g_pSellZone.active && ValidZone(sellLow, sellHigh))
      {
         AdoptPersistentZone(
            g_pSellZone,
            "SELL",
            analysisId,
            zoneType,
            zoneWatchReason,
            sellLow,
            sellHigh,
            sellInvalidation,
            sellInvalidationTf,
            sellInvalidationRule,
            sellInvalidationReason
         );
      }
      else if(g_pSellZone.active)
      {
         g_pSellZone.last_seen_at = TimeCurrent();
      }

      SyncPersistentZonesToGlobals();
      SavePersistentZoneLifecycle();
   }
   else
   {
      g_buyZoneLow = buyLow;
      g_buyZoneHigh = buyHigh;
      g_sellZoneLow = sellLow;
      g_sellZoneHigh = sellHigh;

      g_buyInvalidation = buyInvalidation;
      g_sellInvalidation = sellInvalidation;
      g_buyInvalidationTf = buyInvalidationTf;
      g_sellInvalidationTf = sellInvalidationTf;
      g_buyInvalidationRule = buyInvalidationRule;
      g_sellInvalidationRule = sellInvalidationRule;
      g_buyInvalidationReason = buyInvalidationReason;
      g_sellInvalidationReason = sellInvalidationReason;
   }

   g_r1ArmedState =
      armedState;

   g_r1ArmedSide =
      armedSide;

   g_r1ArmedOrderType =
      armedOrderType;

   g_r1ArmedEntry =
      armedEntry;

   g_r1ArmedSL =
      armedSL;

   g_r1ArmedTP =
      armedTP;

   g_r1ArmedRR =
      armedRR;

   g_insideBuyZone = false;
   g_insideSellZone = false;

   RefreshDecisionZoneObjects();

   Print(
      "Market wait zones updated from Worker. Analysis=",
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
      ),
      " BUY_GRADE=",
      ZoneGrade(true),
      " SELL_GRADE=",
      ZoneGrade(false),
      " BUY_INV=",
      DoubleToString(g_buyInvalidation, _Digits),
      " SELL_INV=",
      DoubleToString(g_sellInvalidation, _Digits),
      " ARMED=",
      g_r1ArmedState,
      " ",
      g_r1ArmedOrderType,
      " @",
      DoubleToString(
         g_r1ArmedEntry,
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
         "XAU entered R1 scalp reference BUY zone: " +
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
         "XAU entered R1 scalp reference SELL zone: " +
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
// R2 LIVE SETUP VISUALIZATION FROM /r2
// ============================================================

void DeleteR2Object(
   string name
)
{
   ObjectDelete(
      0,
      name
   );
}


void DeleteR2TradeObjects()
{
   DeleteR2Object(R2_ZONE_OBJECT);
   DeleteR2Object(R2_ENTRY_OBJECT);
   DeleteR2Object(R2_SL_OBJECT);
   DeleteR2Object(R2_TP1_OBJECT);
   DeleteR2Object(R2_TP2_OBJECT);
   DeleteR2Object(R2_BREAKOUT_OBJECT);
   DeleteR2Object(R2_INVALIDATION_OBJECT);
}


void DeleteR2VisualObjects()
{
   DeleteR2TradeObjects();
   DeleteR2Object(R2_INFO_OBJECT);
   ChartRedraw(0);
}


void ResetR2VisualState()
{
   g_r2MarketState = "";
   g_r2Strategy = "";
   g_r2OrderType = "";
   g_r2Side = "";

   g_r2ZoneLow = 0.0;
   g_r2ZoneHigh = 0.0;
   g_r2Entry = 0.0;
   g_r2SL = 0.0;
   g_r2TP1 = 0.0;
   g_r2TP2 = 0.0;
   g_r2BreakoutLevel = 0.0;
   g_r2Invalidation = 0.0;
   g_r2RR = 0.0;
   g_r2ExpiryHours = 0.0;
   g_r2Score = 0;
   g_r2Allowed = false;
}


void DrawR2HLine(
   string name,
   double price,
   color lineColor,
   ENUM_LINE_STYLE lineStyle,
   int width,
   string tooltip
)
{
   if(price <= 0.0)
   {
      DeleteR2Object(name);
      return;
   }

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
            OBJ_HLINE,
            0,
            0,
            price
         )
      )
      {
         Print(
            "Could not create R2 line ",
            name,
            ". Error=",
            GetLastError()
         );

         return;
      }
   }

   ObjectSetDouble(
      0,
      name,
      OBJPROP_PRICE,
      price
   );

   ObjectSetInteger(
      0,
      name,
      OBJPROP_COLOR,
      lineColor
   );

   ObjectSetInteger(
      0,
      name,
      OBJPROP_STYLE,
      lineStyle
   );

   ObjectSetInteger(
      0,
      name,
      OBJPROP_WIDTH,
      width
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


void DrawR2Info(
   string text,
   color textColor
)
{
   if(
      ObjectFind(
         0,
         R2_INFO_OBJECT
      ) < 0
   )
   {
      ResetLastError();

      if(
         !ObjectCreate(
            0,
            R2_INFO_OBJECT,
            OBJ_LABEL,
            0,
            0,
            0
         )
      )
      {
         Print(
            "Could not create R2 info label. Error=",
            GetLastError()
         );

         return;
      }
   }

   ObjectSetInteger(
      0,
      R2_INFO_OBJECT,
      OBJPROP_CORNER,
      CORNER_LEFT_UPPER
   );

   ObjectSetInteger(
      0,
      R2_INFO_OBJECT,
      OBJPROP_XDISTANCE,
      10
   );

   ObjectSetInteger(
      0,
      R2_INFO_OBJECT,
      OBJPROP_YDISTANCE,
      20
   );

   ObjectSetInteger(
      0,
      R2_INFO_OBJECT,
      OBJPROP_COLOR,
      textColor
   );

   ObjectSetInteger(
      0,
      R2_INFO_OBJECT,
      OBJPROP_FONTSIZE,
      9
   );

   ObjectSetInteger(
      0,
      R2_INFO_OBJECT,
      OBJPROP_SELECTABLE,
      false
   );

   ObjectSetInteger(
      0,
      R2_INFO_OBJECT,
      OBJPROP_HIDDEN,
      false
   );

   ObjectSetString(
      0,
      R2_INFO_OBJECT,
      OBJPROP_TEXT,
      text
   );

   ObjectSetString(
      0,
      R2_INFO_OBJECT,
      OBJPROP_TOOLTIP,
      text
   );
}


void RefreshR2VisualObjects()
{
   DeleteR2TradeObjects();

   if(InpCleanChartMode || !InpShowR2TradeLevels)
   {
      DeleteR2Object(R2_INFO_OBJECT);

      if(InpDrawDecisionZones)
      {
         RefreshDecisionZoneObjects();
      }

      ChartRedraw(0);
      return;
   }

   color sideColor =
      g_r2Side == "SELL"
      ? InpR2SellZoneColor
      : InpR2BuyZoneColor;

   string info =
      "R2 | " +
      g_r2MarketState;

   if(
      !g_r2Allowed ||
      g_r2Strategy == "" ||
      g_r2Strategy == "NONE"
   )
   {
      info +=
         "\nSETUP: NONE";

      DrawR2Info(
         info,
         InpR2InfoColor
      );

      ChartRedraw(0);
      return;
   }

   if(
      ValidZone(
         g_r2ZoneLow,
         g_r2ZoneHigh
      )
   )
   {
      DrawDecisionZoneBand(
         R2_ZONE_OBJECT,
         g_r2ZoneLow,
         g_r2ZoneHigh,
         sideColor,
         "R2 " +
         g_r2Strategy +
         " ZONE " +
         DoubleToString(
            g_r2ZoneLow,
            _Digits
         ) +
         " - " +
         DoubleToString(
            g_r2ZoneHigh,
            _Digits
         )
      );
   }

   DrawR2HLine(
      R2_ENTRY_OBJECT,
      g_r2Entry,
      InpR2EntryColor,
      STYLE_SOLID,
      2,
      "R2 ENTRY " +
      DoubleToString(
         g_r2Entry,
         _Digits
      ) +
      " | " +
      g_r2OrderType
   );

   DrawR2HLine(
      R2_SL_OBJECT,
      g_r2SL,
      InpR2SLColor,
      STYLE_SOLID,
      2,
      "R2 STOP LOSS " +
      DoubleToString(
         g_r2SL,
         _Digits
      )
   );

   DrawR2HLine(
      R2_TP1_OBJECT,
      g_r2TP1,
      InpR2TP1Color,
      STYLE_DASH,
      2,
      "R2 TP1 " +
      DoubleToString(
         g_r2TP1,
         _Digits
      )
   );

   DrawR2HLine(
      R2_TP2_OBJECT,
      g_r2TP2,
      InpR2TP2Color,
      STYLE_DASH,
      2,
      "R2 TP2 " +
      DoubleToString(
         g_r2TP2,
         _Digits
      )
   );

   DrawR2HLine(
      R2_BREAKOUT_OBJECT,
      g_r2BreakoutLevel,
      InpR2BreakoutColor,
      STYLE_DOT,
      1,
      "R2 BREAKOUT LEVEL " +
      DoubleToString(
         g_r2BreakoutLevel,
         _Digits
      )
   );

   DrawR2HLine(
      R2_INVALIDATION_OBJECT,
      g_r2Invalidation,
      InpR2InvalidationColor,
      STYLE_DASHDOT,
      1,
      "R2 STRUCTURAL INVALIDATION " +
      DoubleToString(
         g_r2Invalidation,
         _Digits
      )
   );

   info +=
      "\n" +
      g_r2Strategy +
      " | " +
      g_r2OrderType +
      " | SCORE " +
      IntegerToString(
         g_r2Score
      );

   info +=
      "\nENTRY " +
      DoubleToString(
         g_r2Entry,
         _Digits
      ) +
      " | SL " +
      DoubleToString(
         g_r2SL,
         _Digits
      );

   info +=
      "\nTP1 " +
      DoubleToString(
         g_r2TP1,
         _Digits
      ) +
      " | TP2 " +
      DoubleToString(
         g_r2TP2,
         _Digits
      );

   info +=
      "\nRR1 " +
      DoubleToString(
         g_r2RR,
         2
      ) +
      " | EXP " +
      DoubleToString(
         g_r2ExpiryHours,
         1
      ) +
      "h";

   if(
      ValidZone(
         g_r2ZoneLow,
         g_r2ZoneHigh
      )
   )
   {
      info +=
         "\nZONE " +
         DoubleToString(
            g_r2ZoneLow,
            _Digits
         ) +
         " - " +
         DoubleToString(
            g_r2ZoneHigh,
            _Digits
         );
   }

   if(g_r2BreakoutLevel > 0.0)
   {
      info +=
         "\nBREAKOUT " +
         DoubleToString(
            g_r2BreakoutLevel,
            _Digits
         );
   }

   if(g_r2Invalidation > 0.0)
   {
      info +=
         "\nINVALIDATION " +
         DoubleToString(
            g_r2Invalidation,
            _Digits
         );
   }

   DrawR2Info(
      info,
      sideColor
   );

   ChartRedraw(0);
}


void PollR2Visuals()
{
   if(!InpDrawR2Setup)
   {
      DeleteR2VisualObjects();
      ResetR2VisualState();
      return;
   }

   string url =
      InpWorkerBaseURL +
      "/r2?cb=" +
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
         "R2 visual poll failed. HTTP=",
         status,
         " response=",
         response
      );

      return;
   }

   int setupPos =
      StringFind(
         response,
         "\"setup\":"
      );

   int metricsPos =
      StringFind(
         response,
         "\"metrics\":",
         setupPos >= 0
         ? setupPos
         : 0
      );

   if(
      setupPos < 0 ||
      metricsPos <= setupPos
   )
   {
      Print(
         "R2 visual poll could not isolate setup object."
      );

      return;
   }

   string setupJson =
      StringSubstr(
         response,
         setupPos,
         metricsPos - setupPos
      );

   ResetR2VisualState();

   g_r2MarketState =
      JsonGetString(
         response,
         "market_state"
      );

   g_r2Allowed =
      StringFind(
         setupJson,
         "\"allowed\":true"
      ) >= 0;

   g_r2Strategy =
      JsonGetString(
         setupJson,
         "strategy"
      );

   g_r2Side =
      JsonGetString(
         setupJson,
         "side"
      );

   g_r2OrderType =
      JsonGetString(
         setupJson,
         "order_type"
      );

   g_r2Score =
      (int)JsonGetDouble(
         setupJson,
         "score"
      );

   g_r2Entry =
      JsonGetDouble(
         setupJson,
         "entry"
      );

   g_r2SL =
      JsonGetDouble(
         setupJson,
         "sl"
      );

   g_r2TP1 =
      JsonGetDouble(
         setupJson,
         "tp1"
      );

   g_r2TP2 =
      JsonGetDouble(
         setupJson,
         "tp2"
      );

   g_r2RR =
      JsonGetDouble(
         setupJson,
         "rr_tp1"
      );

   g_r2ExpiryHours =
      JsonGetDouble(
         setupJson,
         "expiry_hours"
      );

   g_r2ZoneLow =
      JsonGetDouble(
         setupJson,
         "zone_low"
      );

   g_r2ZoneHigh =
      JsonGetDouble(
         setupJson,
         "zone_high"
      );

   g_r2BreakoutLevel =
      JsonGetDouble(
         setupJson,
         "breakout_level"
      );

   g_r2Invalidation =
      JsonGetDouble(
         setupJson,
         "invalidation"
      );

   RefreshR2VisualObjects();

   if(InpDrawDecisionZones)
      RefreshDecisionZoneObjects();
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
   Print(
      "ZONE ENGINE SAFETY | signal ignored | ",
      signalId,
      " | ",
      side,
      " | execution is disabled"
   );

   return;

   g_lastHandledSignal =
      signalId;

   bool isMarket =
      side == "BUY" ||
      side == "SELL";

   bool isPending =
      side == "BUY_LIMIT" ||
      side == "SELL_LIMIT" ||
      side == "BUY_STOP" ||
      side == "SELL_STOP";

   if(
      !isMarket &&
      !isPending
   )
   {
      AckSignal(
         signalId,
         "failed"
      );

      return;
   }

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

   bool buySide =
      side == "BUY" ||
      side == "BUY_LIMIT" ||
      side == "BUY_STOP";

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
   // MANUAL CONFIRMATION
   // --------------------------------------------------------

   string confirmation =
      "NEW XAU SIGNAL\n\n" +
      "Order type: " +
      side +
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
      AckSignal(
         signalId,
         "rejected"
      );

      return;
   }

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

int CountManagedPendingOrders()
{
   int count = 0;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
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

      ENUM_ORDER_TYPE type =
         (ENUM_ORDER_TYPE)
         OrderGetInteger(
            ORDER_TYPE
         );

      bool isPending =
         type == ORDER_TYPE_BUY_LIMIT ||
         type == ORDER_TYPE_SELL_LIMIT ||
         type == ORDER_TYPE_BUY_STOP ||
         type == ORDER_TYPE_SELL_STOP ||
         type == ORDER_TYPE_BUY_STOP_LIMIT ||
         type == ORDER_TYPE_SELL_STOP_LIMIT;

      if(
         symbol == _Symbol &&
         magic == InpMagicNumber &&
         isPending
      )
      {
         count++;
      }
   }

   return count;
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
   Print(
      "ZONE ENGINE SAFETY | ExecuteTrade blocked | ",
      signalId,
      " | ",
      side
   );

   return;

   trade.SetExpertMagicNumber(
      InpMagicNumber
   );

   trade.SetDeviationInPoints(
      InpMaxDeviationPoints
   );

   bool pendingRequested =
      side == "BUY_LIMIT" ||
      side == "SELL_LIMIT" ||
      side == "BUY_STOP" ||
      side == "SELL_STOP";

   if(
      pendingRequested &&
      CountManagedPendingOrders() >=
      InpMaxPendingOrders
   )
   {
      Print(
         "Pending-order limit reached. Max=",
         InpMaxPendingOrders,
         " Signal=",
         signalId,
         " Type=",
         side
      );

      AckSignal(
         signalId,
         "rejected"
      );

      return;
   }

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
   g_protectionScanRequested = true;

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