// XAU Market Zones Engine v4.0 ICT SMC ADAPTIVE MARKET PENDING
// Supports R1 READY auto market execution and R2 auto pending execution when enabled.
// It may automatically attach SL/TP protection to open XAU positions when enabled.
// Sends multi-timeframe market snapshots to the Worker, draws locked zones,
// visualizes readiness, manages protection for existing positions,
// and paper-tracks READY-quality signals for live performance statistics.

#property strict

#include <Trade/Trade.mqh>

CTrade trade;


// ============================================================
// INPUTS
// ============================================================

// Existing production Worker v2.4 with news-policy synchronization.
// Switch to a separate isolated Worker and set telemetry-only for testing.
input string InpWorkerBaseURL =
   "https://xau-live-bridge.r7ed2015.workers.dev";
// FALSE = R1/R2 execution and position management are permitted by their own
// inputs, guards, account permissions and broker order validation.
input bool InpTelemetryOnlyStagingMode = false;
input bool InpICTSMCObserveOnly = true; // display live ICT/SMC; no new orders until turned off
input double InpICTSMCMaxMarketDriftUSD = 1.0;

input string InpWriteToken = "";

input int InpMarketSendEverySeconds = 10;
input int InpSignalPollEverySeconds = 1;
input int InpTimeoutMs = 5000;

// Read-only integrated bridge health monitor; never modifies trading decisions.
input bool InpEnableIntegratedBridgeMonitor = true;
input int InpBridgeProbeEverySeconds = 25;
input int InpBridgeMaxMarketAgeSeconds = 30;
input int InpBridgeMaxBrokerTickAgeSeconds = 30;
input double InpBridgeMaxQuoteDifferenceUSD = 2.0;

input bool InpShowZoneEngineStatus = true;
input bool InpShowZoneStrengthReasons = true;
input bool InpCleanChartMode = true;
// Clear chart: WATCH zones use outline bands without duplicate HLINE edges.
input bool InpMinimalWatchDrawings = true;
input bool InpDistinctTradeLineStyles = true;
// Visual-only: move ALL EA line/band descriptions into one upper-right legend.
input bool InpShowUnifiedChartLegend = true;
input int InpLegendRightMargin = 26;
input int InpLegendTopMargin = 36;
input int InpLegendWidth = 418;
input int InpLegendRowHeight = 19;
input int InpLegendFontSize = 9;
input color InpLegendBackground = C'13,18,26';
input color InpLegendBorder = C'51,63,77';
input bool InpShowR2TradeLevels = true; // R2 trade levels visible even with clean chart when enabled
input bool InpShowCompactPanel = true;
// DISPLAY ONLY: set false to hide the broker-real PERFORMANCE card.
// Historical performance calculations and tracking continue normally.
input bool InpShowPerformanceSection = true;
input bool InpShowManagementSection = false;
input bool InpShowBridgeSection = true; // show complete verified bridge diagnostics
// Optional extra diagnostic rows. Main trading rows remain visible.
input bool InpShowAdvancedSetupDetails = false;
input bool InpShowAdvancedSafetyDetails = false;

// Clean panel layout.
// Defaults place the panel BELOW MT5 one-click trading controls.
input ENUM_BASE_CORNER InpPanelCorner = CORNER_LEFT_UPPER;
input int InpPanelX = 14;
input int InpPanelY = 118;
input int InpPanelWidth = 585;
input int InpPanelHeight = 654;
input int InpPanelRowHeight = 18;
input int InpPanelSectionGap = 11; // Space between the six dashboard cards
input int InpPanelFontSize = 9;
input int InpPanelTitleFontSize = 12;

input color InpPanelBgColor = C'12,17,24';
input color InpPanelBorderColor = C'42,57,70';
input color InpPanelTextColor = C'232,238,245';
input color InpPanelMutedColor = C'156,170,184';
input color InpPanelR1Color = C'56,192,135';
input color InpPanelR2Color = C'98,172,241';
input color InpPanelBuyColor = C'52,199,118';
input color InpPanelSellColor = C'255,107,107';
input color InpPanelWaitColor = C'218,182,84';
input color InpPanelWarningColor = C'255,184,77';

// HARD SAFETY:
// Legacy Worker /signal auto-opening remains disabled in ExecuteTrade().
// Automated R1/R2 execution is governed by the dedicated executor inputs.
// No manual BUY/SELL execution buttons are created.


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

// Maximum combined loss if all CURRENT XAU positions hit their SL.
// Example: 10.0 = do not allow a NEW XAU position to remain open
// if total SL risk would exceed 10% of the current account balance.
input bool   InpEnableMaxSLRiskGuard = true;
input double InpMaxSLRiskPercent = 10.0;


// BUY/SELL on-chart controls were removed in v3.5.27.
// Automated execution and risk settings are unchanged.

// R1 does not use any arbitrary price-distance cap.
// Broker SL validation and account-percent risk limits still apply.

// Automatic READY-signal executor.
// R1 auto-enabled by request. Use only with the broker, session, news and risk guards enabled.
// Each READY signal sends ONE market order with volume computed from
// the remaining 5% R1 budget, broker minimum lot, volume step and margin.
input bool   InpEnableAutoSignalExecutor = true; // R1 READY auto execution enabled
input double InpAutoExecutorMaxSLRiskPercent = 5.0; // R1 default account risk cap, adjustable in Inputs
input bool   InpAutoExecutorRequireFlatAtSignal = false;
input int    InpR1FailedSignalRetrySeconds = 30; // broker retry cooldown
input bool   InpPersistAutoExecutorState = true;
input bool   InpResetAutoExecutorStateOnInit = false;

// v3.5.27: stabilize existing R2 pending orders without modifying trading logic.
input bool InpR2KeepArmedPlan = true;
input bool InpR2CancelOnConfirmedOpposite = true;
input int InpR2OppositeCancelMinScore = 80;
input bool InpR2DeletePendingOnDeinit = false;
input bool InpEnableTradeAuditLog = true;
input int InpAuditRepeatSeconds = 300;
input bool InpEnableLearningAudit = true;
input int InpLearningLookbackDays = 90;
input int InpLearningMinClosedBaskets = 30;
// Optional learning-based risk reduction, OFF until forward tested.
input bool InpEnableLearnedRiskThrottle = false;

// R2 pending-order executor.
// Independent from the R1 READY market executor.
// Supports BUY_LIMIT / SELL_LIMIT / BUY_STOP / SELL_STOP.
// Only R2 setups explicitly marked allowed by the R2 engine can be armed.
// R1 READY market trades and R2 pending orders MAY COEXIST.
// ONE risk-sized pending order is placed per new R2 setup. Existing pending
// orders and filled positions are not consolidated or modified on upgrade.
// R1 and R2 have no arbitrary SL price-distance ceiling. Both still
// require broker-valid stops and broker-calculated SL risk within account caps.
input bool   InpEnableR2PendingExecutor = true; // Pending only
input int    InpR2FailedPlanRetrySeconds = 30; // avoid repeated broker rejections
input int    InpR2PendingMinScore = 70;
input double InpR2PendingMinRR = 1.00;
input bool   InpR2PendingUseTP2AsFinal = true;
// Each strategy has its OWN share of account balance.
input double InpR2AutoMaxSLRiskPercent = 5.0;
// R1 uses InpAutoExecutorMaxSLRiskPercent (default 5%).
// Combined XAU risk defaults to 10%, adjustable with InpMaxSLRiskPercent
// while InpEnableMaxSLRiskGuard remains true.
// R1 and R2 new entries: 08:00 London local (GMT/BST) to the END
// of 23:59 broker server time, broker Mon-Fri. Other management is 24h.
input bool InpEnableBrokerServerAutoWindow = true;
input bool InpUseLondonOpenAutoWindow = true;
input int InpAutoOpenServerHour = 9; // fallback only when London auto OFF
// Fixed close boundary, cannot be overwritten by saved MT5 .set inputs.
const int InpAutoCloseServerHour = 23;
const int InpAutoCloseServerMinute = 59;
// Strategy Tester has simulated TimeGMT equal to server time.
// Set historical broker UTC offset manually; default 9999 fails closed.
input int InpTesterBrokerUTCOffsetMinutes = 9999;


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
// Visual-only Worker reference bands. NEVER used for R1 auto entry.
input bool InpDrawR1WorkerWatchZones = true;
input color InpR1WatchBuyColor = C'30,210,173';
input color InpR1WatchSellColor = C'255,201,65';
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
input double InpPersistentZoneMaxAgeHours = 4.0;
input double InpR1ZoneHardMaxAgeHours = 4.0;
input double InpR1MinimumNewZoneShiftUSD = 1.50;
input int InpR1MaxFeedAgeSeconds = 30;
input bool InpR1RequireTradableWorkerContext = true;
input bool InpR1RotateToFreshTradableZone = true;
input int InpR1MinimumLockMinutes = 20;

// Simple decision layer.
// The locked zones stay analytical; this layer gives one clear action.
// One practical M5 confirmation is enough. R2 opposite bias is caution only.
input bool   InpSimpleDecisionMode = true;
input int    InpSimpleConfirmLookbackM5Bars = 3;
input double InpSimpleRR = 2.0;
// Legacy setting retained for saved input compatibility. R1 now uses ATR buffer below.
input double InpSimpleSLBufferZoneFraction = 0.25;
// R1 only, closed M5 swing stop. Structural zone invalidation is NOT a trade SL.
input int    InpR1ScalpSwingLookbackM5Bars = 16;
input int    InpR1ScalpPivotStrength = 1; // completed bars on each side of pivot
input int    InpR1ScalpATRPeriod = 14;
input double InpR1ScalpSwingZoneToleranceATR = 0.75;
input double InpR1ScalpSLBufferATR = 0.15;
input double InpR1ScalpMaxStopATR = 2.00; // adaptive, NOT a fixed gold-dollar limit
input double InpR1ScalpMinStopATR = 0.20;

input int    InpR2OppositeCautionScore = 70;

// READY latch: once a valid decision appears, do not erase it on the next candle.
// If the user opens a position on this symbol, the panel switches to ACTIVE.
input bool   InpLatchReadySignal = true;
input int    InpReadyLatchMinutes = 30;


// Live paper-performance tracker.
// MONITOR ONLY: never opens, closes, or modifies a broker position.
// It evaluates the same R1 simple READY logic with one virtual trade at a time.
input bool   InpEnableLivePerformanceTracker = false;
input bool   InpShowLivePerformanceOnPanel = false;
input bool   InpPersistLivePerformance = false;
input bool   InpWriteLivePerformanceCsv = false;
input bool   InpResetLivePerformanceOnInit = false;

// BROKER-REAL auto performance only, read directly from MT5 trade history.
// Never estimates virtual/paper trades or counts manual/panel/system tests.
// 0 days = full available account history; all closed legs in a basket are
// aggregated into ONE logical result using the broker's entry comment.
input int    InpRealAutoPerformanceLookbackDays = 0;
input int    InpRealAutoPerformanceRefreshSeconds = 15;

// MT5 built-in economic-calendar guard. All event times are BROKER SERVER time.
// Applies to unattended AUTO R1/R2 entries, not analytics or position management.
input bool   InpEnableUSDNewsGuard = true;
input bool   InpNewsGuardFailClosed = true;
input int    InpNewsPreHighMinutes = 30;
input int    InpNewsPostHighMinutes = 30;
input bool   InpNewsIncludeModerateUSD = false;
input int    InpNewsPreModerateMinutes = 15;
input int    InpNewsPostModerateMinutes = 10;
input bool   InpNewsBlockUntimedHighUSD = false; // no indefinite news blackouts by default
input int    InpNewsRefreshSeconds = 60;
input int    InpNewsPreCriticalMinutes = 45;
input int    InpNewsPostCriticalMinutes = 30;
input bool   InpNewsTierSelfTestOnInit = true;
// Unscheduled headline backup: fast spread/M1 shock checks.
input bool   InpNewsPriceShockGuard = true;
input int    InpNewsMaxSpreadPoints = 35;
input double InpNewsM1SpikeMultiple = 4.0;
input int    InpNewsShockHoldMinutes = 10;

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
input bool InpDrawR2WatchZones = true; // visual only; never trade
input color InpR2WatchBuyColor = C'187,135,255';
input color InpR2WatchSellColor = C'255,220,0';
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
// Distinct incoming candidate from currently locked, displayed trade zone.
datetime g_r1LastFreshFeedServer=0;
double g_r1WorkerBuyLow=0.0,g_r1WorkerBuyHigh=0.0;
double g_r1WorkerSellLow=0.0,g_r1WorkerSellHigh=0.0;
string g_r1LastFeedState="WAIT_FIRST_UPDATE";
string g_r1RetireReason="NONE";
bool g_r1RetiredBuy=false,g_r1RetiredSell=false;
double g_r1RetiredBuyLow=0.0,g_r1RetiredBuyHigh=0.0;
double g_r1RetiredSellLow=0.0,g_r1RetiredSellHigh=0.0;
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

// Prevent an expired/missed READY from instantly re-latching from the same
// already-closed M5 confirmation bar.
datetime g_readyBlockedConfirmBar = 0;
string   g_readyBlockedSide = "NONE";

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

// Max SL-risk guard runtime state.
// Manual MT5 orders cannot be blocked before the broker executes them,
// so a newly-opened XAU position that pushes total SL risk above the cap
// is closed immediately on the next timer cycle. Existing positions are not
// force-closed merely because the EA starts while already above the cap.
bool   g_riskGuardCheckRequested = false;
ulong  g_riskGuardNewPositionTicket = 0;
datetime g_riskGuardNextRetryAt=0;
string g_riskGuardStatus = "OFF";
double g_riskGuardCurrentRiskMoney = 0.0;
double g_riskGuardCurrentRiskPercent = 0.0;


// Auto executor runtime state.
string g_autoExecutionStatus = "OFF";
string g_autoLastSignalKey = ""; // last broker-confirmed successful signal
string g_autoLastAttemptSignalKey = "";
datetime g_autoLastAttemptAt = 0;
string g_autoStateFile = "";
bool   g_autoExecutionInProgress = false;

// R2 pending executor runtime.
string g_r2PendingExecutionStatus = "OFF";
bool g_ictR1ModelOK=false,g_ictR1Allowed=false,g_ictR2ModelOK=false;
string g_ictR1OrderType="NONE",g_ictR1Side="NONE",g_ictR1SetupKey="",g_ictR1Reason="";
double g_ictR1Entry=0.0,g_ictR1SL=0.0,g_ictR1TP=0.0;
string g_r2PendingPlanKey = "";
string g_r2LastAttemptPlanKey = "";
datetime g_r2LastAttemptAt = 0;
bool   g_r2PendingExecutionInProgress = false;

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
// Unique chart objects: WATCH levels are not tradeable locked R1 zones.
string R1_WATCH_BUY_BAND = "R1_WATCH_REFERENCE_BUY";
string R1_WATCH_SELL_BAND = "R1_WATCH_REFERENCE_SELL";
string R1_WATCH_BUY_LOW = "R1_WATCH_BUY_LOW";
string R1_WATCH_BUY_HIGH = "R1_WATCH_BUY_HIGH";
string R1_WATCH_SELL_LOW = "R1_WATCH_SELL_LOW";
string R1_WATCH_SELL_HIGH = "R1_WATCH_SELL_HIGH";
string R1_WATCH_BUY_TEXT = "R1_WATCH_BUY_LABEL";
string R1_WATCH_SELL_TEXT = "R1_WATCH_SELL_LABEL";

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
bool g_r2PendingProtocolOK = false;
bool g_r2PendingViable = false;
string g_r2PendingOnlyReason = "WAIT_FOR_WORKER_R2";
datetime g_r2LastFreshPollServer = 0;
double g_r2WatchBuyLow=0.0,g_r2WatchBuyHigh=0.0;
double g_r2WatchSellLow=0.0,g_r2WatchSellHigh=0.0;
bool g_r2WatchAvailable=false;
string g_r2WatchSource="WAIT_FOR_WORKER_V2_6";

string R2_ZONE_OBJECT = "R2_ACTIVE_ZONE";
string R2_ENTRY_OBJECT = "R2_ENTRY";
string R2_SL_OBJECT = "R2_SL";
string R2_TP1_OBJECT = "R2_TP1";
string R2_TP2_OBJECT = "R2_TP2";
string R2_BREAKOUT_OBJECT = "R2_BREAKOUT_LEVEL";
string R2_INVALIDATION_OBJECT = "R2_INVALIDATION";
string R2_INFO_OBJECT = "R2_INFO";
string R2_WATCH_BUY_BAND="R2_SWING_WATCH_BUY";
string R2_WATCH_SELL_BAND="R2_SWING_WATCH_SELL";
string R2_WATCH_BUY_LOW="R2_WATCH_BUY_LOW";
string R2_WATCH_BUY_HIGH="R2_WATCH_BUY_HIGH";
string R2_WATCH_SELL_LOW="R2_WATCH_SELL_LOW";
string R2_WATCH_SELL_HIGH="R2_WATCH_SELL_HIGH";
string R2_WATCH_BUY_LABEL="R2_WATCH_BUY_TEXT";
string R2_WATCH_SELL_LABEL="R2_WATCH_SELL_TEXT";
string ZONE_LEGEND_BG_OBJECT = "XAU_V42_TOP_RIGHT_LEGEND_BG";
string ZONE_LEGEND_ROW_PREFIX = "XAU_V42_TOP_RIGHT_LEGEND_ROW_";
const int ZONE_LEGEND_MAX_ROWS = 28;
string ZONE_PANEL_OBJECT = "ZONE_ENGINE_PANEL";
string ZONE_PANEL_HEADER_OBJECT = "ZONE_ENGINE_PANEL_HEADER";
string ZONE_PANEL_ROW_PREFIX = "ZONE_ENGINE_ROW_";


// ============================================================
// LIVE VIRTUAL PERFORMANCE TRACKER
// ============================================================

struct VirtualPerformanceTrade
{
   bool active;
   string signal_key;
   string side;
   string confirmation;
   string zone_type;
   string r2_side;
   int r2_score;
   bool r2_aligned;
   bool r2_caution;

   double entry;
   double sl;
   double tp;
   double risk;

   datetime open_time;

   double mfe_r;
   double mae_r;
};

VirtualPerformanceTrade g_perfTrade;

string g_perfStateFile = "";
string g_perfHistoryFile = "";
string g_perfLastCandidateKey = "";

int g_perfSignals = 0;
int g_perfWins = 0;
int g_perfLosses = 0;
int g_perfSkippedOverlap = 0;

int g_perfCurrentLossStreak = 0;
int g_perfMaxLossStreak = 0;

int g_perfBuyTrades = 0;
int g_perfBuyWins = 0;
int g_perfSellTrades = 0;
int g_perfSellWins = 0;

double g_perfTotalR = 0.0;
double g_perfGrossWinR = 0.0;
double g_perfGrossLossR = 0.0;
double g_perfTotalHoldSeconds = 0.0;


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

double R1EffectiveZoneMaxAgeHours()
{
   double hard=MathMax(0.10,InpR1ZoneHardMaxAgeHours);
   if(InpPersistentZoneMaxAgeHours>0.0)
      return MathMin(hard,InpPersistentZoneMaxAgeHours);
   return hard; // Ignore old saved 0 = forever
}
bool PersistentZoneExpired(PersistentZoneState &z)
{
   if(!z.active)return false;
   if(z.created_at<=0)return true;
   double age=(double)(TimeTradeServer()-z.created_at);
   if(age < -30.0)return true;
   return age>=R1EffectiveZoneMaxAgeHours()*3600.0;
}
bool R1RearmDistanceValid(string side,double low,double high)
{
   bool retired=(side=="BUY"?g_r1RetiredBuy:g_r1RetiredSell);
   if(!retired)return true;
   double oldLow=side=="BUY"?g_r1RetiredBuyLow:g_r1RetiredSellLow;
   double oldHigh=side=="BUY"?g_r1RetiredBuyHigh:g_r1RetiredSellHigh;
   return MathMax(MathAbs(low-oldLow),MathAbs(high-oldHigh))>=
          MathMax(0.25,InpR1MinimumNewZoneShiftUSD);
}
bool R1ZoneShouldRotate(PersistentZoneState &z,
                        double low,double high,string incomingType)
{
   if(!InpR1RotateToFreshTradableZone || !z.active ||
      !ValidZone(low,high) ||
      StringFind(incomingType,"WATCH")>=0 ||
      incomingType=="" || HasPositionOnSymbol())
      return false;
   if(TimeTradeServer()<z.created_at+
      MathMax(5,InpR1MinimumLockMinutes)*60)
      return false;
   return MathMax(MathAbs(low-z.low),MathAbs(high-z.high))>=
      MathMax(0.25,InpR1MinimumNewZoneShiftUSD);
}
bool R1EntryAllowedForSide(string side,string &why)
{
   why="";
   datetime now=TimeTradeServer();
   if(g_r1LastFreshFeedServer<=0 ||
      now<g_r1LastFreshFeedServer-5 ||
      now-g_r1LastFreshFeedServer>MathMax(10,InpR1MaxFeedAgeSeconds))
   {why="R1 FEED STALE OR MISSING";return false;}
   if(InpR1RequireTradableWorkerContext &&
      (StringFind(g_zoneType,"WATCH")>=0 ||
       g_zoneType=="" || StringFind(g_zoneAnalysisId,"WATCH_")==0))
   {why="R1 WORKER WATCH ONLY";return false;}
   if(side!="BUY" && side!="SELL")
   {why="R1 NO VALID SIDE";return false;}
   if(InpLockZoneIdentity)
   {
      if(side=="BUY" && (!g_pBuyZone.active || PersistentZoneExpired(g_pBuyZone)))
      {why="R1 BUY ZONE EXPIRED";return false;}
      if(side=="SELL" && (!g_pSellZone.active || PersistentZoneExpired(g_pSellZone)))
      {why="R1 SELL ZONE EXPIRED";return false;}
   }
   return true;
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

   FileWrite(handle, "PZV2");
   FileWrite(handle, g_lockedPrimarySide);
   FileWrite(handle, g_lastZoneLifecycleEvent);
   WritePersistentZoneState(handle, g_pBuyZone);
   WritePersistentZoneState(handle, g_pSellZone);
   FileWrite(handle,g_r1RetiredBuy?"1":"0");
   FileWrite(handle,DoubleToString(g_r1RetiredBuyLow,_Digits));
   FileWrite(handle,DoubleToString(g_r1RetiredBuyHigh,_Digits));
   FileWrite(handle,g_r1RetiredSell?"1":"0");
   FileWrite(handle,DoubleToString(g_r1RetiredSellLow,_Digits));
   FileWrite(handle,DoubleToString(g_r1RetiredSellHigh,_Digits));
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
   if(version != "PZV1" && version != "PZV2")
   {
      FileClose(handle);
      return false;
   }

   g_lockedPrimarySide = FileReadString(handle);
   g_lastZoneLifecycleEvent = FileReadString(handle);

   bool okBuy = ReadPersistentZoneState(handle, g_pBuyZone);
   bool okSell = ReadPersistentZoneState(handle, g_pSellZone);
   if(version=="PZV2" && okBuy && okSell && !FileIsEnding(handle))
   {
      g_r1RetiredBuy=FileReadString(handle)=="1";
      g_r1RetiredBuyLow=StringToDouble(FileReadString(handle));
      g_r1RetiredBuyHigh=StringToDouble(FileReadString(handle));
      g_r1RetiredSell=FileReadString(handle)=="1";
      g_r1RetiredSellLow=StringToDouble(FileReadString(handle));
      g_r1RetiredSellHigh=StringToDouble(FileReadString(handle));
   }
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
   if(!R1RearmDistanceValid(side,low,high))
   {
      AuditState("R1","ZONE_REJECT","RETIRED_ZONE_REPEATED_"+side);
      return;
   }

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
   if(side=="BUY")g_r1RetiredBuy=false;
   if(side=="SELL")g_r1RetiredSell=false;

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
   if(side=="BUY")
   {
      g_r1RetiredBuy=true;
      g_r1RetiredBuyLow=oldLow;
      g_r1RetiredBuyHigh=oldHigh;
   }
   else if(side=="SELL")
   {
      g_r1RetiredSell=true;
      g_r1RetiredSellLow=oldLow;
      g_r1RetiredSellHigh=oldHigh;
   }
   g_r1RetireReason=cause;
   AuditState("R1","ZONE_RETIRE",cause+" | "+side+" "+
      DoubleToString(oldLow,_Digits)+"-"+DoubleToString(oldHigh,_Digits));

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
         );      }
      else if(PersistentZoneExpired(g_pSellZone))
      {
         InvalidatePersistentZone(g_pSellZone, "EXPIRED");
      }
   }

   SyncPersistentZonesToGlobals();
}

// ============================================================
// R1 SCALP STOP: closest CONFIRMED CLOSED-M5 swing + ATR buffer.
// The distant zone invalidation level only invalidates a zone, NEVER
// supplies the stop of a new R1 scalp trade.
// ============================================================
double R1ScalpM5ATR()
{
   int period=MathMax(3,InpR1ScalpATRPeriod);
   datetime bar=iTime(_Symbol,PERIOD_M5,1);
   static datetime cachedBar=0;
   static double cachedValue=0.0;
   if(bar>0 && bar==cachedBar && cachedValue>0.0)
      return cachedValue;
   MqlRates rates[];
   ArraySetAsSeries(rates,true);
   int copied=CopyRates(_Symbol,PERIOD_M5,1,period+1,rates);
   if(copied<period+1)return 0.0;
   double sum=0.0;
   for(int i=0;i<period;i++)
   {
      double high=rates[i].high,low=rates[i].low;
      double prev=rates[i+1].close;
      sum+=MathMax(high-low,MathMax(MathAbs(high-prev),MathAbs(low-prev)));
   }
   double atr=sum/(double)period;
   if(atr<=_Point)return 0.0;
   cachedBar=bar;
   cachedValue=atr;
   return atr;
}

bool R1ScalpStopDistanceAllowed(string side,double entry,double sl,string &why)
{
   why="";
   double atr=R1ScalpM5ATR();
   if(atr<=0.0 || entry<=0.0 || sl<=0.0)
   {why="R1 M5 ATR UNAVAILABLE";return false;}
   if((side=="BUY" && sl>=entry) || (side=="SELL" && sl<=entry))
   {why="R1 WRONG SIDE SCALP SL";return false;}
   double distance=MathAbs(entry-sl);
   if(distance < atr*MathMax(0.05,InpR1ScalpMinStopATR))
   {why="R1 SCALP STOP TOO TIGHT VS M5 ATR";return false;}
   if(distance > atr*MathMax(0.25,InpR1ScalpMaxStopATR))
   {why="R1 SCALP STOP TOO WIDE VS M5 ATR";return false;}
   return true;
}

bool BuildR1ScalpStop(string side,double entry,double zoneLow,double zoneHigh,
                      double &stop,string &why)
{
   stop=0.0;
   why="";
   if((side!="BUY" && side!="SELL") || !ValidZone(zoneLow,zoneHigh))
   {why="NO VALID R1 ZONE";return false;}
   double atr=R1ScalpM5ATR();
   if(atr<=0.0)
   {why="NO CLOSED M5 ATR";return false;}
   int strength=MathMax(1,MathMin(3,InpR1ScalpPivotStrength));
   int lookback=MathMax(2*strength+3,InpR1ScalpSwingLookbackM5Bars);
   MqlRates bars[];
   ArraySetAsSeries(bars,true);
   int copied=CopyRates(_Symbol,PERIOD_M5,1,lookback+strength+1,bars);
   if(copied<lookback+strength+1)
   {why="NOT ENOUGH CLOSED M5 BARS";return false;}
   double tolerance=atr*MathMax(0.0,InpR1ScalpSwingZoneToleranceATR);
   double buffer=MathMax(_Point*2.0,atr*MathMax(0.01,InpR1ScalpSLBufferATR));
   double bestDistance=1.0e100;
   bool found=false;
   bool buy=(side=="BUY");
   // bars[0] is the last CLOSED M5 bar; no unfinished candle participates.
   // A pivot must be confirmed by `strength` newer CLOSED bars.
   for(int i=strength;i<lookback;i++)
   {
      double pivot=buy?bars[i].low:bars[i].high;
      if(buy && (pivot<zoneLow-tolerance || pivot>zoneHigh))continue;
      if(!buy && (pivot<zoneLow || pivot>zoneHigh+tolerance))continue;
      bool confirmed=true;
      for(int j=1;j<=strength;j++)
      {
         if(buy && !(pivot<bars[i-j].low && pivot<=bars[i+j].low))
         {confirmed=false;break;}
         if(!buy && !(pivot>bars[i-j].high && pivot>=bars[i+j].high))
         {confirmed=false;break;}
      }
      if(!confirmed)continue;
      // When pivot is inside the zone, the SL stays outside the zone edge.
      double candidate=buy?MathMin(pivot,zoneLow)-buffer:
                           MathMax(pivot,zoneHigh)+buffer;
      candidate=NormalizeDouble(candidate,_Digits);
      string distanceReason="";
      if(!R1ScalpStopDistanceAllowed(side,entry,candidate,distanceReason))
         continue;
      double distance=MathAbs(entry-candidate);
      if(distance<bestDistance)
      {bestDistance=distance;stop=candidate;found=true;}
   }
   if(!found)
   {why="NO CONFIRMED NEARBY M5 SCALP SWING / ATR LIMIT";return false;}
   why="CONFIRMED M5 SWING + ATR BUFFER";
   return true;
}

// ============================================================
// AUTO SL/TP PROTECTION
// ============================================================

bool BuildProtectionPlanForPosition(
   string side,double positionEntry,double &planSL,double &planTP)
{
   planSL=0.0;
   planTP=0.0;
   if(side!="BUY" && side!="SELL")return false;
   // Reuse the exact locked R1 READY plan when available.
   if(g_readyLatched && g_latchedSide==side &&
      g_latchedSL>0.0 && g_latchedTP>0.0)
   {
      planSL=g_latchedSL;
      planTP=g_latchedTP;
      return true;
   }
   // No R1 scalp SL is ever derived from g_buyInvalidation/g_sellInvalidation.
   // A missing local structure leaves the plan invalid, rather than supplying
   // a falsely wide structural stop to auto-protection.
   double low=side=="BUY"?g_buyZoneLow:g_sellZoneLow;
   double high=side=="BUY"?g_buyZoneHigh:g_sellZoneHigh;
   string why="";
   if(!BuildR1ScalpStop(side,positionEntry,low,high,planSL,why))
      return false;
   double risk=MathAbs(positionEntry-planSL);
   planTP=NormalizeDouble(side=="BUY"?
      positionEntry+risk*InpSimpleRR:
      positionEntry-risk*InpSimpleRR,_Digits);
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

      // CTrade success is not sufficient until broker retcode confirms it.
      bool modifyAccepted=trade.PositionModify(ticket,newSL,newTP);
      uint modifyRetcode=trade.ResultRetcode();
      if(modifyAccepted &&
         (modifyRetcode==TRADE_RETCODE_DONE ||
          modifyRetcode==TRADE_RETCODE_NO_CHANGES))
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
// MAX COMBINED SL-RISK GUARD
// ============================================================

double SelectedPositionRiskMoneyAtSL(bool &known)
{
   known = false;

   string symbol = PositionGetString(POSITION_SYMBOL);
   if(symbol != _Symbol)
      return 0.0;

   long type = PositionGetInteger(POSITION_TYPE);
   double volume = PositionGetDouble(POSITION_VOLUME);
   double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl = PositionGetDouble(POSITION_SL);

   if(volume <= 0.0 || entry <= 0.0)
      return 0.0;

   string side =
      type == POSITION_TYPE_BUY
      ? "BUY"
      : (
         type == POSITION_TYPE_SELL
         ? "SELL"
         : "NONE"
        );

   if(side == "NONE")
      return 0.0;

   // Never treat an unconfirmed stop plan as a broker-side SL.
   // An open position without a real SL makes current risk UNKNOWN.
   if(sl <= 0.0)
      return 0.0;

   // A stop already at breakeven/profit contributes no downside risk.
   if(type == POSITION_TYPE_BUY && sl >= entry)
   {
      known = true;
      return 0.0;
   }

   if(type == POSITION_TYPE_SELL && sl <= entry)
   {
      known = true;
      return 0.0;
   }

   double profitAtSL = 0.0;
   ENUM_ORDER_TYPE orderType =
      type == POSITION_TYPE_BUY
      ? ORDER_TYPE_BUY
      : ORDER_TYPE_SELL;

   if(
      !OrderCalcProfit(
         orderType,
         symbol,
         volume,
         entry,
         sl,
         profitAtSL
      )
   )
   {
      return 0.0;
   }

   known = true;
   return MathMax(0.0, -profitAtSL);
}

bool CalculateCurrentXAUTotalSLRisk(
   double &riskMoney,
   double &riskPercent,
   int &unknownPositions
)
{
   riskMoney = 0.0;
   riskPercent = 0.0;
   unknownPositions = 0;

   int total = PositionsTotal();

   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      bool known = false;
      double positionRisk = SelectedPositionRiskMoneyAtSL(known);

      if(!known)
      {
         unknownPositions++;
         continue;
      }

      riskMoney += positionRisk;
   }

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance > 0.0)
      riskPercent = (riskMoney / balance) * 100.0;

   return unknownPositions == 0;
}

ulong FindNewestXAUPositionTicket()
{
   ulong newestTicket = 0;
   long newestTimeMsc = -1;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      long timeMsc = PositionGetInteger(POSITION_TIME_MSC);

      if(timeMsc >= newestTimeMsc)
      {
         newestTimeMsc = timeMsc;
         newestTicket = ticket;
      }
   }

   return newestTicket;
}

void RequestRiskGuardCheckForNewPosition(ulong positionTicket)
{
   if(!InpEnableMaxSLRiskGuard)
      return;

   g_riskGuardNewPositionTicket = positionTicket;

   if(g_riskGuardNewPositionTicket == 0)
      g_riskGuardNewPositionTicket = FindNewestXAUPositionTicket();

   g_riskGuardCheckRequested = true;
}

void EnforceMaxSLRiskGuardForNewPosition()
{
   if(!InpEnableMaxSLRiskGuard)
   {
      g_riskGuardStatus = "OFF";
      g_riskGuardCheckRequested = false;
      g_riskGuardNewPositionTicket = 0;
      return;
   }

   if(InpMaxSLRiskPercent <= 0.0)
   {
      g_riskGuardStatus = "DISABLED BY LIMIT";
      g_riskGuardCheckRequested = false;
      g_riskGuardNewPositionTicket = 0;
      return;
   }

   double riskMoney = 0.0;
   double riskPercent = 0.0;
   int unknownPositions = 0;

   bool allKnown =
      CalculateCurrentXAUTotalSLRisk(
         riskMoney,
         riskPercent,
         unknownPositions
      );

   g_riskGuardCurrentRiskMoney = riskMoney;
   g_riskGuardCurrentRiskPercent = riskPercent;

   if(!g_riskGuardCheckRequested)
   {
      if(!allKnown)
      {
         g_riskGuardStatus =
            "WAIT SL | UNKNOWN " +
            IntegerToString(unknownPositions);
      }
      else
      {
         g_riskGuardStatus =
            "SL RISK " +
            DoubleToString(riskPercent, 1) +
            "% / " +
            DoubleToString(InpMaxSLRiskPercent, 1) +
            "%";
      }

      return;
   }

   ulong newTicket = g_riskGuardNewPositionTicket;

   if(newTicket == 0 || !PositionSelectByTicket(newTicket))
   {
      newTicket = FindNewestXAUPositionTicket();
   }

   if(newTicket == 0 || !PositionSelectByTicket(newTicket))
   {
      g_riskGuardCheckRequested = false;
      g_riskGuardNewPositionTicket = 0;
      return;
   }

   // AutoProtectOpenPositions() is called before this guard in OnTimer().
   // If risk is still unknown after that, reject the NEW trade rather than
   // allow additional exposure without a measurable stop-loss risk.
   bool exceeds =
      !allKnown ||
      riskPercent > InpMaxSLRiskPercent + 1e-8;

   if(!exceeds)
   {
      g_riskGuardStatus =
         "OK " +
         DoubleToString(riskPercent, 1) +
         "% / " +
         DoubleToString(InpMaxSLRiskPercent, 1) +
         "%";

      g_riskGuardCheckRequested = false;
      g_riskGuardNewPositionTicket = 0;
      return;
   }

   string reason =
      !allKnown
      ? "SL risk could not be measured for all XAU positions"
      : (
         "total SL risk " +
         DoubleToString(riskPercent, 2) +
         "% exceeds limit " +
         DoubleToString(InpMaxSLRiskPercent, 2) +
         "%"
        );

   // Do not silently abandon failed protective closes. Retry at most
   // once every five seconds until broker confirms the close.
   datetime guardNow=TimeTradeServer();
   if(g_riskGuardNextRetryAt>guardNow)return;
   g_riskGuardNextRetryAt=guardNow+5;
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpMaxDeviationPoints);

   ResetLastError();

   bool closeRequestAccepted =
      trade.PositionClose(
         newTicket
      );

   uint closeRetcode = trade.ResultRetcode();

   bool closeExecuted =
      closeRequestAccepted &&
      (
         closeRetcode == TRADE_RETCODE_DONE ||
         closeRetcode == TRADE_RETCODE_DONE_PARTIAL
      );

   if(closeExecuted)
   {
      g_riskGuardStatus = "BLOCKED NEW TRADE";

      Print(
         "MAX SL RISK GUARD | NEW POSITION CLOSED | ticket=",
         newTicket,
         " | ",
         reason,
         " | risk=$",
         DoubleToString(riskMoney, 2),
         " | balance=$",
         DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2),
         " | retcode=",
         closeRetcode
      );

      Alert(
         "XAU RISK GUARD: new trade blocked. ",
         reason
      );
   }
   else
   {
      g_riskGuardStatus = "BLOCK FAILED";

      Print(
         "MAX SL RISK GUARD | FAILED TO CLOSE NEW POSITION | ticket=",
         newTicket,
         " | requestAccepted=",
         closeRequestAccepted,
         " | retcode=",
         closeRetcode,
         " | ",
         trade.ResultRetcodeDescription(),
         " | error=",
         GetLastError()
      );
   }

   if(!closeExecuted)
   {
      // Preserve the failing ticket and retry; keep future risk blocked.
      g_riskGuardCheckRequested=true;
      g_riskGuardNewPositionTicket=newTicket;
      return;
   }
   g_riskGuardNextRetryAt=0;
   g_riskGuardCheckRequested = false;
   g_riskGuardNewPositionTicket = 0;
}


// ============================================================
// PANEL EXECUTION + AUTOMATIC READY EXECUTOR
// ============================================================

bool MarketTradeRetcodeExecuted()
{
   uint code = trade.ResultRetcode();

   return
      code == TRADE_RETCODE_DONE ||
      code == TRADE_RETCODE_DONE_PARTIAL;
}


double NormalizeOpenVolumeFloor(double volume)
{
   double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(minLot<=0.0 || maxLot<minLot || step<=0.0)return 0.0;
   double maximum=maxLot;
   if(InpSafetyMaxLot>0.0)maximum=MathMin(maximum,InpSafetyMaxLot);
   if(volume<minLot-1e-9 || maximum<minLot-1e-9)return 0.0;
   double capped=MathMin(volume,maximum);
   double stepCount=MathFloor((capped-minLot)/step+1e-9);
   if(stepCount<0.0)return 0.0;
   return NormalizeDouble(minLot+stepCount*step,8);
}


bool CalculateProposedMarketRiskMoney(
   string side,
   double volume,
   double entry,
   double sl,
   double &riskMoney
)
{
   riskMoney = 0.0;

   if(volume <= 0.0 || entry <= 0.0 || sl <= 0.0)
      return false;

   ENUM_ORDER_TYPE orderType;

   if(side == "BUY")
      orderType = ORDER_TYPE_BUY;
   else if(side == "SELL")
      orderType = ORDER_TYPE_SELL;
   else
      return false;

   double profitAtSL = 0.0;

   if(
      !OrderCalcProfit(
         orderType,
         _Symbol,
         volume,
         entry,
         sl,
         profitAtSL
      )
   )
   {
      return false;
   }

   riskMoney = MathMax(0.0, -profitAtSL);
   return true;
}


// No hidden 10% limit: the existing hard-risk Inputs setting can change the
// combined XAU ceiling intentionally, while defaulting to 10% for safety.
// If the general guard is disabled, retain a 10% auto-execution failsafe.
double EffectiveTotalXAUAutoRiskCapPercent()
{
   if(InpEnableMaxSLRiskGuard && InpMaxSLRiskPercent > 0.0)
      return InpMaxSLRiskPercent;
   return 10.0;
}

double EffectiveAutoRiskCapPercent()
{
   double cap = MathMax(0.0, InpAutoExecutorMaxSLRiskPercent);

   if(InpEnableMaxSLRiskGuard && InpMaxSLRiskPercent > 0.0)
   {
      if(cap <= 0.0)
         cap = InpMaxSLRiskPercent;
      else
         cap = MathMin(cap, InpMaxSLRiskPercent);
   }

   return cap;
}


bool SendProtectedMarketOrder(
   string side,
   double volume,
   double sl,
   double tp,
   string comment,
   string &resultText
)
{
   resultText = "";
   volume = NormalizeOpenVolumeFloor(volume);

   if(volume <= 0.0)
   {
      resultText = "INVALID LOT";
      return false;
   }

   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
   {
      resultText = "NO TICK";
      return false;
   }

   double currentPrice = side == "BUY" ? tick.ask : tick.bid;
   string stopError = "";

   if(!ValidateStops(side, currentPrice, sl, tp, stopError))
   {
      resultText = "INVALID SL/TP | " + stopError;
      return false;
   }

   if(
      !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ||
      !MQLInfoInteger(MQL_TRADE_ALLOWED) ||
      !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)
   )
   {
      resultText = "AUTOTRADING / ACCOUNT TRADING NOT ALLOWED";
      return false;
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpMaxDeviationPoints);

   ResetLastError();

   bool requestAccepted = false;

   if(side == "BUY")
   {
      requestAccepted =
         trade.Buy(
            volume,
            _Symbol,
            0.0,
            sl,
            tp,
            comment
         );
   }
   else if(side == "SELL")
   {
      requestAccepted =
         trade.Sell(
            volume,
            _Symbol,
            0.0,
            sl,
            tp,
            comment
         );
   }
   else
   {
      resultText = "INVALID SIDE";
      return false;
   }

   if(!requestAccepted || !MarketTradeRetcodeExecuted())
   {
      resultText =
         "FAILED " +
         IntegerToString((long)trade.ResultRetcode()) +
         " | " +
         trade.ResultRetcodeDescription();

      Print(
         "PANEL/AUTO ORDER FAILED | ",
         side,
         " | lot=",
         DoubleToString(volume, 2),
         " | retcode=",
         trade.ResultRetcode(),
         " | ",
         trade.ResultRetcodeDescription(),
         " | error=",
         GetLastError()
      );

      return false;
   }

   resultText =
      "DONE | " +
      side +
      " " +
      DoubleToString(volume, 2) +
      " LOT";

   return true;
}


bool BuildCurrentProtectedPlan(
   string side,
   double &entry,
   double &sl,
   double &tp,
   string &error
)
{
   entry = 0.0;
   sl = 0.0;
   tp = 0.0;
   error = "";

   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
   {      error = "NO MARKET TICK";
      return false;
   }

   entry = side == "BUY" ? tick.ask : tick.bid;

   if(!BuildProtectionPlanForPosition(side, entry, sl, tp))
   {
      error = "NO VALID " + side + " SL/TP PLAN";
      return false;
   }

   string stopError = "";

   if(!ValidateStops(side, entry, sl, tp, stopError))
   {
      error = "INVALID PLAN | " + stopError;
      return false;
   }

   return true;
}



bool BuildReadyExecutionPlan(
   string requestedSide,
   double &entry,
   double &sl,
   double &tp,
   string &signalKey,
   string &error,
   bool ignoreOpenPositions = false
)
{
   entry = 0.0;
   sl = 0.0;
   tp = 0.0;
   signalKey = "";
   error = "";

   BuildSimpleDecision(ignoreOpenPositions);

   string requiredDecision =
      requestedSide + " READY";

   if(g_simpleDecision != requiredDecision)
   {
      error =
         "WAIT | " +
         requestedSide +
         " IS NOT READY";

      return false;
   }

   if(
      g_simpleDecisionSide != requestedSide ||
      g_simpleSL <= 0.0 ||
      g_simpleTP <= 0.0
   )
   {
      error = "READY PLAN INCOMPLETE";
      return false;
   }

   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
   {
      error = "NO MARKET TICK";
      return false;
   }

   entry =
      requestedSide == "BUY"
      ? tick.ask
      : tick.bid;

   // Exact READY/latch SL and TP.
   sl = g_simpleSL;
   tp = g_simpleTP;

   // Revalidate live entry vs the locked scalp stop after price moves.
   string scalpDistanceReason="";
   if(!R1ScalpStopDistanceAllowed(requestedSide,entry,sl,scalpDistanceReason))
   {
      error=scalpDistanceReason;
      return false;
   }

   string stopError = "";

   if(
      !ValidateStops(
         requestedSide,
         entry,
         sl,
         tp,
         stopError
      )
   )
   {
      error =
         "READY LEVELS NO LONGER VALID | " +
         stopError;

      return false;
   }


   datetime signalStamp =
      g_readyLatched && g_latchedAt > 0
      ? g_latchedAt
      : iTime(_Symbol, PERIOD_M5, 1);

   signalKey =
      requestedSide + "|" +
      IntegerToString((long)signalStamp) + "|" +
      DoubleToString(sl, _Digits) + "|" +
      DoubleToString(tp, _Digits);

   return true;
}


bool PrecheckNewRiskAgainstCap(
   string side,
   double volume,
   double entry,
   double sl,
   double capPercent,
   double &projectedRiskMoney,
   double &projectedRiskPercent,
   string &error
)
{
   projectedRiskMoney = 0.0;
   projectedRiskPercent = 0.0;
   error = "";

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);

   if(balance <= 0.0)
   {
      error = "INVALID ACCOUNT BALANCE";
      return false;
   }

   double currentRiskMoney = 0.0;
   double currentRiskPercent = 0.0;
   int unknownPositions = 0;

   bool allKnown =
      CalculateCurrentXAUTotalSLRisk(
         currentRiskMoney,
         currentRiskPercent,
         unknownPositions
      );

   if(!allKnown)
   {
      error =
         "CURRENT SL RISK UNKNOWN | " +
         IntegerToString(unknownPositions) +
         " POSITION(S)";

      return false;
   }

   double newRiskMoney = 0.0;

   if(
      !CalculateProposedMarketRiskMoney(
         side,
         volume,
         entry,
         sl,
         newRiskMoney
      )
   )
   {
      error = "CANNOT CALCULATE NEW SL RISK";
      return false;
   }

   projectedRiskMoney = currentRiskMoney + newRiskMoney;
   projectedRiskPercent = projectedRiskMoney / balance * 100.0;

   if(
      capPercent > 0.0 &&
      projectedRiskPercent > capPercent + 1e-8
   )
   {
      error =
         "RISK " +
         DoubleToString(projectedRiskPercent, 2) +
         "% > CAP " +
         DoubleToString(capPercent, 2) +
         "%";

      return false;
   }

   return true;
}


void SaveAutoExecutorState()
{
   if(!InpPersistAutoExecutorState || g_autoStateFile == "")
      return;

   int handle =
      FileOpen(
         g_autoStateFile,
         FILE_WRITE |
         FILE_TXT |
         FILE_ANSI |
         FILE_COMMON
      );

   if(handle == INVALID_HANDLE)
      return;

   FileWrite(handle, "AUTO1");
   FileWrite(handle, g_autoLastSignalKey);
   FileWrite(handle, g_autoExecutionStatus);
   FileClose(handle);
}


bool LoadAutoExecutorState()
{
   if(
      !InpPersistAutoExecutorState ||
      g_autoStateFile == "" ||
      !FileIsExist(g_autoStateFile, FILE_COMMON)
   )
   {
      return false;
   }

   int handle =
      FileOpen(
         g_autoStateFile,
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

   if(version != "AUTO1")
   {
      FileClose(handle);
      return false;
   }

   g_autoLastSignalKey = FileReadString(handle);
   g_autoExecutionStatus = FileReadString(handle);

   FileClose(handle);
   return true;
}



string AutoBasketHashId(
   string prefix,
   string key
)
{
   uint hash = 2166136261;

   int length =
      StringLen(key);

   for(int i = 0; i < length; i++)
   {
      hash ^=
         (uint)
         StringGetCharacter(
            key,
            i
         );

      hash *=
         16777619;
   }

   return
      prefix +
      "-" +
      StringFormat(
         "%08X",
         hash
      );
}


string AutoBasketComment(
   string baseComment,
   string basketId
)
{
   string comment =
      baseComment;

   if(basketId != "")
   {
      comment +=
         "|" +
         basketId;
   }

   // Keep the broker comment comfortably inside the usual MT5 limit.
   if(StringLen(comment) > 31)
   {
      comment =
         StringSubstr(
            comment,
            0,
            31
         );
   }

   return comment;
}




bool IsPendingOrderType(ENUM_ORDER_TYPE type)
{
   return
      type == ORDER_TYPE_BUY_LIMIT ||
      type == ORDER_TYPE_SELL_LIMIT ||
      type == ORDER_TYPE_BUY_STOP ||
      type == ORDER_TYPE_SELL_STOP ||
      type == ORDER_TYPE_BUY_STOP_LIMIT ||
      type == ORDER_TYPE_SELL_STOP_LIMIT;
}


bool IsBuyPendingOrderType(ENUM_ORDER_TYPE type)
{
   return
      type == ORDER_TYPE_BUY_LIMIT ||
      type == ORDER_TYPE_BUY_STOP ||
      type == ORDER_TYPE_BUY_STOP_LIMIT;
}


bool IsR2ManagedPendingComment(string comment)
{
   return StringFind(comment, "XAU_R2P_") == 0;
}


int CountR2PendingOrders()
{
   int count = 0;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);

      if(ticket == 0)
         continue;

      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;

      if(OrderGetInteger(ORDER_MAGIC) != InpMagicNumber)
         continue;

      ENUM_ORDER_TYPE type =
         (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

      if(!IsPendingOrderType(type))
         continue;

      if(!IsR2ManagedPendingComment(OrderGetString(ORDER_COMMENT)))
         continue;

      count++;
   }

   return count;
}


string g_auditFile="";
string g_lastAuditR1="",g_lastAuditR2="";
datetime g_lastAuditR1At=0,g_lastAuditR2At=0;
void AuditEvent(string engine,string action,string reason,string detail,
                ulong ticket=0,double entry=0,double sl=0,double tp=0)
{
   if(!InpEnableTradeAuditLog)return;
   if(g_auditFile=="")
      g_auditFile="XAU_AUDIT_"+IntegerToString((long)AccountInfoInteger(ACCOUNT_LOGIN))+
                  "_"+_Symbol+"_"+IntegerToString(InpMagicNumber)+".csv";
   int h=FileOpen(g_auditFile,FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|
                 FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE,',');
   if(h==INVALID_HANDLE){Print("AUDIT FILE ERROR ",GetLastError());return;}
   if(FileSize(h)==0)
      FileWrite(h,"server_time","engine","event","reason","details","ticket","bid",
                "ask","entry","sl","tp");
   FileSeek(h,0,SEEK_END);
   StringReplace(detail,"\r"," ");
   StringReplace(detail,"\n"," ");
   StringReplace(detail,",",";");
   MqlTick tick;double bid=0.0,ask=0.0;
   if(SymbolInfoTick(_Symbol,tick)){bid=tick.bid;ask=tick.ask;}
   FileWrite(h,TimeToString(TimeTradeServer(),TIME_DATE|TIME_SECONDS),
             engine,action,reason,detail,IntegerToString((long)ticket),
             DoubleToString(bid,_Digits),DoubleToString(ask,_Digits),
             DoubleToString(entry,_Digits),DoubleToString(sl,_Digits),
             DoubleToString(tp,_Digits));
   FileClose(h);
   Print("AUDIT | ",engine," | ",action," | ",reason," | ",detail);
}
void AuditState(string engine,string reason,string detail)
{
   if(!InpEnableTradeAuditLog)return;
   datetime now=TimeTradeServer();
   string state=reason+"|"+detail;
   datetime prev=engine=="R1"?g_lastAuditR1At:g_lastAuditR2At;
   string last=engine=="R1"?g_lastAuditR1:g_lastAuditR2;
   if(state==last && now-prev<MathMax(60,InpAuditRepeatSeconds))return;
   if(engine=="R1"){g_lastAuditR1=state;g_lastAuditR1At=now;}
   else{g_lastAuditR2=state;g_lastAuditR2At=now;}
   AuditEvent(engine,"STATE",reason,detail);
}
string R2PendingSummary()
{
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong t=OrderGetTicket(i);
      if(t==0||OrderGetString(ORDER_SYMBOL)!=_Symbol||
         OrderGetInteger(ORDER_MAGIC)!=InpMagicNumber||
         !IsR2ManagedPendingComment(OrderGetString(ORDER_COMMENT)))continue;
      if(!IsPendingOrderType((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE)))continue;
      return "ticket="+IntegerToString((long)t)+
             " price="+DoubleToString(OrderGetDouble(ORDER_PRICE_OPEN),_Digits);
   }
   return "NONE";
}
string R2ArmedInvalidation()
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick))return "";
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong t=OrderGetTicket(i);
      if(t==0||OrderGetString(ORDER_SYMBOL)!=_Symbol||
         OrderGetInteger(ORDER_MAGIC)!=InpMagicNumber||
         !IsR2ManagedPendingComment(OrderGetString(ORDER_COMMENT)))continue;
      ENUM_ORDER_TYPE kind=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(!IsPendingOrderType(kind))continue;
      bool buy=kind==ORDER_TYPE_BUY_LIMIT||kind==ORDER_TYPE_BUY_STOP;
      double sl=OrderGetDouble(ORDER_SL);
      if(sl<=0)return "PENDING_WITHOUT_SL";
      if((buy&&tick.bid<=sl)||(!buy&&tick.ask>=sl))
         return "STRUCTURE_BROKE_BROKER_SL";
      if(InpR2CancelOnConfirmedOpposite && g_r2Allowed &&
         g_r2Score>=InpR2OppositeCancelMinScore &&
         ((buy&&g_r2Side=="SELL")||(!buy&&g_r2Side=="BUY")))
         return "CONFIRMED_OPPOSITE_R2";
   }
   return "";
}
bool R2AlreadyHasOpenPosition()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(t==0||!PositionSelectByTicket(t))continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         PositionGetInteger(POSITION_MAGIC)==InpMagicNumber &&
         StringFind(PositionGetString(POSITION_COMMENT),"XAU_R2P_")==0)
         return true;
   }
   return false;
}
bool DeleteR2PendingOrders(string reason)
{
   bool allDeleted = true;
   int deleted = 0;

   trade.SetExpertMagicNumber(InpMagicNumber);

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);

      if(ticket == 0)
         continue;

      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;

      if(OrderGetInteger(ORDER_MAGIC) != InpMagicNumber)
         continue;

      ENUM_ORDER_TYPE type =
         (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

      if(!IsPendingOrderType(type))
         continue;

      string comment = OrderGetString(ORDER_COMMENT);

      if(!IsR2ManagedPendingComment(comment))
         continue;

      ResetLastError();

      double beforeEntry=OrderGetDouble(ORDER_PRICE_OPEN);
       double beforeSL=OrderGetDouble(ORDER_SL);
       double beforeTP=OrderGetDouble(ORDER_TP);
       bool accepted = trade.OrderDelete(ticket);

      if(
         !accepted ||
         trade.ResultRetcode() != TRADE_RETCODE_DONE
      )
      {
         allDeleted = false;

         Print(
            "R2 PENDING DELETE FAILED | ticket=",
            ticket,
            " | ",
            trade.ResultRetcode(),
            " | ",
            trade.ResultRetcodeDescription(),
            " | reason=",
            reason
         );
      }
      else
      {
         deleted++;
         AuditEvent("R2","CANCEL","BROKER_DELETE",reason,
                    ticket,beforeEntry,beforeSL,beforeTP);
      }
   }

   if(deleted > 0)
   {
      Print(
         "R2 PENDING CANCELLED | count=",
         deleted,
         " | reason=",
         reason
      );
   }

   return allDeleted;
}


bool CalculateCurrentXAUPendingSLRisk(
   double &riskMoney,
   double &riskPercent,
   int &unknownOrders
)
{
   riskMoney = 0.0;
   riskPercent = 0.0;
   unknownOrders = 0;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);

   if(balance <= 0.0)
      return false;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);

      if(ticket == 0)
         continue;

      string symbol = OrderGetString(ORDER_SYMBOL);

      if(StringFind(symbol, "XAUUSD") < 0)
         continue;

      ENUM_ORDER_TYPE type =
         (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

      if(!IsPendingOrderType(type))
         continue;

      double volume = OrderGetDouble(ORDER_VOLUME_CURRENT);
      double entry = OrderGetDouble(ORDER_PRICE_OPEN);
      double sl = OrderGetDouble(ORDER_SL);

      if(volume <= 0.0 || entry <= 0.0 || sl <= 0.0)
      {
         unknownOrders++;
         continue;
      }

      string side =
         IsBuyPendingOrderType(type)
         ? "BUY"
         : "SELL";

      double oneRisk = 0.0;

      if(
         !CalculateProposedMarketRiskMoney(
            side,
            volume,
            entry,
            sl,
            oneRisk
         )
      )
      {
         unknownOrders++;
         continue;
      }

      riskMoney += oneRisk;
   }

   riskPercent = riskMoney / balance * 100.0;
   return unknownOrders == 0;
}


bool CalculateCurrentXAUPotentialSLRisk(
   double &riskMoney,
   double &riskPercent,
   int &unknownItems
)
{
   riskMoney = 0.0;
   riskPercent = 0.0;
   unknownItems = 0;

   double positionRiskMoney = 0.0;
   double positionRiskPercent = 0.0;
   int unknownPositions = 0;

   bool positionsKnown =
      CalculateCurrentXAUTotalSLRisk(
         positionRiskMoney,
         positionRiskPercent,
         unknownPositions
      );

   double pendingRiskMoney = 0.0;
   double pendingRiskPercent = 0.0;
   int unknownOrders = 0;

   bool pendingKnown =
      CalculateCurrentXAUPendingSLRisk(
         pendingRiskMoney,
         pendingRiskPercent,
         unknownOrders
      );

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);

   if(balance <= 0.0)
      return false;

   riskMoney = positionRiskMoney + pendingRiskMoney;
   riskPercent = riskMoney / balance * 100.0;
   unknownItems = unknownPositions + unknownOrders;

   return positionsKnown && pendingKnown;
}



// United Kingdom BST starts/ends 01:00 UTC last Sunday Mar/Oct.
datetime LondonDSTChangeUTC(int year,int month)
{
 MqlDateTime d;ZeroMemory(d);
 d.year=year;d.mon=month;d.day=31;
 MqlDateTime last;TimeToStruct(StructToTime(d),last);
 d.day=31-last.day_of_week;d.hour=1;
 return StructToTime(d);
}
bool LondonSummerAtUTC(datetime stamp)
{
 MqlDateTime u;TimeToStruct(stamp,u);
 return stamp>=LondonDSTChangeUTC(u.year,3) &&
        stamp<LondonDSTChangeUTC(u.year,10);
}
// Broker-local session bounds: identical source for EA and Worker.
bool AutoEntryWindowBounds(int &start,int &finish,int &offsetMinutes)
{
 start=0;finish=0;offsetMinutes=0;
 datetime serverNow=TimeTradeServer();
 if(serverNow<=0)return false;
 int h=MathMax(0,MathMin(23,InpAutoCloseServerHour));
 int m=MathMax(0,MathMin(59,InpAutoCloseServerMinute));
 finish=h*3600+(m+1)*60; // 23:59:59 inclusive
 if(!InpUseLondonOpenAutoWindow)
 {
   start=MathMax(0,MathMin(23,InpAutoOpenServerHour))*3600;
   return finish>start;
 }
 datetime utcNow=TimeGMT();
 if(utcNow<=0)return false;
 int shiftSeconds=0;
 if(MQLInfoInteger(MQL_TESTER))
 {
   if(InpTesterBrokerUTCOffsetMinutes==9999)return false;
   offsetMinutes=InpTesterBrokerUTCOffsetMinutes;
   shiftSeconds=offsetMinutes*60;
 }
 else
 {
   int shift=(int)(serverNow-utcNow);
   shiftSeconds=(int)MathRound((double)shift/900.0)*900;
   if(MathAbs(shift-shiftSeconds)>120)return false;
   offsetMinutes=shiftSeconds/60;
 }
 if(MathAbs(shiftSeconds)>14*3600)return false;
 MqlDateTime serverDay,utcDay;
 TimeToStruct(serverNow,serverDay);TimeToStruct(utcNow,utcDay);
 utcDay.hour=0;utcDay.min=0;utcDay.sec=0;
 datetime utcMidnight=StructToTime(utcDay);
 for(int i=-1;i<=1;i++)
 {
   datetime day=utcMidnight+(datetime)(i*86400);
   int openingUtc=LondonSummerAtUTC(day+8*3600)?7:8;
   datetime serverOpening=day+(datetime)(openingUtc*3600+shiftSeconds);
   MqlDateTime opening;TimeToStruct(serverOpening,opening);
   if(opening.year==serverDay.year && opening.mon==serverDay.mon &&
      opening.day==serverDay.day)
   {
     start=opening.hour*3600+opening.min*60+opening.sec;
     return start<finish;
   }
 }
 return false;
}
string AutoEntryWindowLabel()
{
 if(!InpEnableBrokerServerAutoWindow)return "FILTER OFF";
 int start=0,finish=0,offset=0;
 if(!AutoEntryWindowBounds(start,finish,offset))
    return "LONDON CLOCK UNAVAILABLE";
 string first=StringFormat("%02d:%02d",start/3600,(start%3600)/60);
 string last=StringFormat("%02d:%02d",(finish-1)/3600,
                          ((finish-1)%3600)/60);
 return InpUseLondonOpenAutoWindow
    ? "LONDON 08 UK | SRV "+first+"-"+last
    : "SERVER "+first+"-"+last;
}
bool AutoEntrySessionOpen(int &secondsToClose)
{
 secondsToClose=0;
 if(!InpEnableBrokerServerAutoWindow)
 {secondsToClose=86400;return true;}
 datetime now=TimeTradeServer();
 if(now<=0)return false;
 MqlDateTime broker;TimeToStruct(now,broker);
 if(broker.day_of_week==0 || broker.day_of_week==6)return false;
 int start=0,finish=0,offset=0;
 if(!AutoEntryWindowBounds(start,finish,offset))return false;
 int second=broker.hour*3600+broker.min*60+broker.sec;
 secondsToClose=MathMax(0,finish-second);
 return second>=start && secondsToClose>0;
}

string AutoEngineFromComment(string comment)
{
 if(StringFind(comment,"XAU_AUTO_")==0 || StringFind(comment,"XAU_R1P_")==0)return "R1";
 if(StringFind(comment,"XAU_R2P_")==0)return "R2";
 return "";
}
bool CalculateAutoEnginePotentialSLRisk(string engine,double &money,double &percent,int &unknown)
{
 money=0.0;percent=0.0;unknown=0;
 double balance=AccountInfoDouble(ACCOUNT_BALANCE);
 if(balance<=0.0)return false;
 for(int i=PositionsTotal()-1;i>=0;i--)
 {
  ulong ticket=PositionGetTicket(i);
  if(ticket==0||!PositionSelectByTicket(ticket))continue;
  if(PositionGetString(POSITION_SYMBOL)!=_Symbol)continue;
  if(PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber)continue;
  if(AutoEngineFromComment(PositionGetString(POSITION_COMMENT))!=engine)continue;
  bool known=false;
  double oneRisk=SelectedPositionRiskMoneyAtSL(known);
  if(!known){unknown++;continue;}
  money+=oneRisk;
 }
 for(int i=OrdersTotal()-1;i>=0;i--)
 {
  ulong ticket=OrderGetTicket(i); if(ticket==0)continue;
  if(OrderGetString(ORDER_SYMBOL)!=_Symbol)continue;
  if(OrderGetInteger(ORDER_MAGIC)!=InpMagicNumber)continue;
  ENUM_ORDER_TYPE type=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
  if(!IsPendingOrderType(type))continue;
  if(AutoEngineFromComment(OrderGetString(ORDER_COMMENT))!=engine)continue;
  double v=OrderGetDouble(ORDER_VOLUME_CURRENT);
  double price=OrderGetDouble(ORDER_PRICE_OPEN);
  double sl=OrderGetDouble(ORDER_SL);
  string side=IsBuyPendingOrderType(type)?"BUY":"SELL";
  double oneRisk=0.0;
  if(!CalculateProposedMarketRiskMoney(side,v,price,sl,oneRisk))
  {unknown++;continue;}
  money+=oneRisk;
 }
 percent=money/balance*100.0;
 return unknown==0;
}
bool PrecheckEngineAutoRisk(string engine,string side,double volume,double entry,
                            double sl,double capPercent,double &projectedMoney,
                            double &projectedPct,string &error)
{
 error=""; projectedMoney=0.0;projectedPct=0.0;
 double balance=AccountInfoDouble(ACCOUNT_BALANCE);
 if(balance<=0.0){error="INVALID ACCOUNT BALANCE";return false;}
 double engineMoney=0.0,enginePct=0.0,totalMoney=0.0,totalPct=0.0;
 int unknownEngine=0,unknownTotal=0;
 if(!CalculateAutoEnginePotentialSLRisk(engine,engineMoney,enginePct,unknownEngine))
 {error="UNKNOWN "+engine+" RISK";return false;}
 if(!CalculateCurrentXAUPotentialSLRisk(totalMoney,totalPct,unknownTotal))
 {error="UNKNOWN TOTAL XAU RISK";return false;}
 double newMoney=0.0;
 if(!CalculateProposedMarketRiskMoney(side,volume,entry,sl,newMoney))
 {error="CANNOT CALCULATE NEW RISK";return false;}
 projectedMoney=engineMoney+newMoney;
 projectedPct=projectedMoney/balance*100.0;
 if(capPercent<=0.0||projectedPct>capPercent+1e-8)
 {
  error=engine+" RISK "+DoubleToString(projectedPct,2)+
        "% > "+DoubleToString(capPercent,2)+"%";
  return false;
 }
 double totalCap=EffectiveTotalXAUAutoRiskCapPercent();
 double after=(totalMoney+newMoney)/balance*100.0;
 if(after>totalCap+1e-8)
 {
  error="TOTAL XAU RISK "+DoubleToString(after,2)+
        "% > "+DoubleToString(totalCap,2)+"%";
  return false;
 }
 return true;
}


// ONE order per signal, with affordable size rounded DOWN to broker step.
// Existing broker-confirmed positions AND pending orders consume risk budget.
bool CalculateSingleRiskSizedLot(string engine,string side,
                                 double entry,double sl,double engineCapPercent,
                                 double &volume,double &projectedPct,string &reason)
{
   volume=0.0;projectedPct=0.0;reason="";
   double balance=AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance<=0.0 || engineCapPercent<=0.0)
   {reason="INVALID BALANCE OR RISK CAP";return false;}
   double engineRisk=0.0,enginePct=0.0,totalRisk=0.0,totalPct=0.0;
   int engineUnknown=0,totalUnknown=0;
   if(!CalculateAutoEnginePotentialSLRisk(engine,engineRisk,enginePct,engineUnknown))
   {reason="UNKNOWN "+engine+" SL RISK";return false;}
   if(!CalculateCurrentXAUPotentialSLRisk(totalRisk,totalPct,totalUnknown))
   {reason="UNKNOWN TOTAL SL RISK";return false;}
   double available=MathMin(balance*engineCapPercent/100.0-engineRisk,
      balance*EffectiveTotalXAUAutoRiskCapPercent()/100.0-totalRisk);
   if(available<=0.0)
   {reason="NO RISK BUDGET";return false;}

   double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(minLot<=0.0 || maxLot<minLot || step<=0.0)
   {reason="INVALID BROKER LOT RULES";return false;}
   double minRisk=0.0;
   if(!CalculateProposedMarketRiskMoney(side,minLot,entry,sl,minRisk) ||
      minRisk<=0.0)
   {reason="CANNOT CALCULATE MIN LOT RISK";return false;}
   if(minRisk>available+1e-7)
   {reason="MIN LOT EXCEEDS AVAILABLE RISK";return false;}

   volume=NormalizeOpenVolumeFloor(minLot*available/minRisk);
   if(volume<minLot-1e-9)
   {reason="NO AFFORDABLE BROKER LOT";return false;}

   if(side!="BUY" && side!="SELL")
   {reason="INVALID ORDER SIDE";volume=0.0;return false;}
   ENUM_ORDER_TYPE marginSide=(side=="BUY")?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
   double freeMargin=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(freeMargin<=0.0)
   {reason="NO FREE MARGIN";volume=0.0;return false;}
   double marginNeeded=0.0;
   if(!OrderCalcMargin(marginSide,_Symbol,volume,entry,marginNeeded) ||
      marginNeeded<=0.0)
   {reason="MARGIN ESTIMATE UNAVAILABLE";volume=0.0;return false;}
   if(marginNeeded>freeMargin*0.95)
   {
      volume=NormalizeOpenVolumeFloor(volume*freeMargin*0.95/marginNeeded);
      if(volume<minLot-1e-9)
      {reason="MIN LOT EXCEEDS FREE MARGIN";return false;}
   }

   double projectedMoney=0.0;
   if(!PrecheckEngineAutoRisk(engine,side,volume,entry,sl,
                              engineCapPercent,projectedMoney,projectedPct,reason))
   {volume=0.0;return false;}
   return true;
}

// ============================================================
// NEWS GUARD — MT5 USD ECONOMIC CALENDAR + PRICE SHOCK
// ============================================================

datetime g_newsLastPoll=0;
datetime g_newsNextTime=0;
datetime g_newsNextBlockingTime=0;
int g_newsNextBlockingPre=0;
datetime g_newsBlockUntil=0;
string g_newsNextName="";
string g_newsNextRisk="NONE";
string g_newsBlockName="";
int g_newsBlockRisk=0;
int g_newsAttentionRisk=0;
string g_newsAttentionName="";
bool g_newsEntryBlocked=true;
string g_newsLastLoggedStatus="";
bool g_newsFeedHealthy=false;
string g_newsFeedStatus="NOT CHECKED";
datetime g_newsLastShock=0;
datetime g_newsShockUntil=0;
string g_newsShockReason="";
string g_newsStatus="NEWS CHECKING";

// GOLD NEWS RISK v3.5.27. Severity 1 LOW, 2 MEDIUM, 3 HIGH, 4 CRITICAL.
// Calendar importance alone is not an adequate proxy for XAUUSD risk.
string NewsRiskLabel(int r)
{
 if(r>=4)return "CRITICAL";
 if(r==3)return "HIGH";
 if(r==2)return "MEDIUM";
 if(r==1)return "LOW";
 return "NONE";
}
int GoldNewsRisk(string title,int importance)
{
 string t=title;
 StringToLower(t);
 if(StringFind(t,"eia")>=0 ||
    StringFind(t,"crude oil stocks")>=0 ||
    StringFind(t,"crude oil inventories")>=0 ||
    StringFind(t,"oil inventories")>=0 ||
    StringFind(t,"natural gas storage")>=0 ||
    StringFind(t,"gasoline inventories")>=0 ||
    StringFind(t,"distillate inventories")>=0 ||
    StringFind(t,"baker hughes")>=0 ||
    StringFind(t,"rig count")>=0)return 1;
 int level=1;
 if(importance==(int)CALENDAR_IMPORTANCE_HIGH)level=3;
 else if(importance==(int)CALENDAR_IMPORTANCE_MODERATE)level=2;
 if(StringFind(t,"fomc member")>=0 ||
    StringFind(t,"fed member")>=0 ||
    StringFind(t,"fed governor")>=0)return level;
 if(StringFind(t,"federal funds rate")>=0 ||
    StringFind(t,"fomc statement")>=0 ||
    StringFind(t,"fomc press conference")>=0 ||
    StringFind(t,"interest rate decision")>=0 ||
    StringFind(t,"fed rate decision")>=0 ||
    StringFind(t,"powell")>=0 ||
    StringFind(t,"fed chair")>=0 ||
    StringFind(t,"nonfarm payroll")>=0 ||
    StringFind(t,"non-farm payroll")>=0 ||
    StringFind(t,"non farm payroll")>=0 ||
    StringFind(t,"nonfarm employment")>=0 ||
    StringFind(t,"non-farm employment")>=0 ||
    StringFind(t,"consumer price index")>=0 ||
    StringFind(t,"cpi")>=0 ||
    StringFind(t,"core pce price")>=0 ||
    StringFind(t,"pce price index")>=0 ||
    StringFind(t,"pce inflation")>=0 ||
    StringFind(t,"unemployment rate")>=0)return 4;
 if(StringFind(t,"fomc minutes")>=0)return MathMax(level,3);
 return level;
}
bool NewsRiskBlocks(int level)
{
 return level>=3 || (level==2 && InpNewsIncludeModerateUSD);
}
int NewsPre(int level)
{
 if(level==4)return MathMax(0,InpNewsPreCriticalMinutes);
 if(level==3)return MathMax(0,InpNewsPreHighMinutes);
 if(level==2)return MathMax(0,InpNewsPreModerateMinutes);
 return 0;
}
int NewsPost(int level)
{
 if(level==4)return MathMax(0,InpNewsPostCriticalMinutes);
 if(level==3)return MathMax(0,InpNewsPostHighMinutes);
 if(level==2)return MathMax(0,InpNewsPostModerateMinutes);
 return 0;
}
bool NewsTierSelfTest()
{
 bool pass=
  GoldNewsRisk("EIA Crude Oil Stocks Change",(int)CALENDAR_IMPORTANCE_HIGH)==1 &&
  GoldNewsRisk("Natural Gas Storage",(int)CALENDAR_IMPORTANCE_HIGH)==1 &&
  GoldNewsRisk("CPI",(int)CALENDAR_IMPORTANCE_HIGH)==4 &&
  GoldNewsRisk("Nonfarm Payrolls",(int)CALENDAR_IMPORTANCE_HIGH)==4 &&
  GoldNewsRisk("Non-Farm Employment Change",(int)CALENDAR_IMPORTANCE_HIGH)==4 &&
  GoldNewsRisk("FOMC Statement",(int)CALENDAR_IMPORTANCE_HIGH)==4 &&
  GoldNewsRisk("Core PCE Price Index",(int)CALENDAR_IMPORTANCE_HIGH)==4 &&
  GoldNewsRisk("Retail Sales",(int)CALENDAR_IMPORTANCE_HIGH)==3 &&
  GoldNewsRisk("Factory Orders",(int)CALENDAR_IMPORTANCE_MODERATE)==2 &&
  !NewsRiskBlocks(1) && NewsRiskBlocks(3) && NewsRiskBlocks(4);
 Print("NEWS RISK SELFTEST | ",pass?"PASS":"FAIL",
       " | EIA LOW ALLOW | CPI NFP FOMC CRITICAL BLOCK");
 return pass;
}

bool RefreshNewsCalendar()
{
 if(!InpEnableUSDNewsGuard)
 {
  g_newsFeedHealthy=true;
  g_newsFeedStatus="OFF";
  g_newsNextTime=0;
  g_newsNextBlockingTime=0;
  g_newsBlockUntil=0;
  return true;
 }
 datetime now=TimeTradeServer();
 if(now<=0){g_newsFeedHealthy=false;g_newsFeedStatus="BAD CLOCK";return false;}
 if(g_newsLastPoll>0 && now-g_newsLastPoll<MathMax(10,InpNewsRefreshSeconds))
  return g_newsFeedHealthy;

 g_newsLastPoll=now;
 g_newsFeedHealthy=false;
 g_newsFeedStatus="CALENDAR UNAVAILABLE";
 g_newsNextTime=0;g_newsNextName="";g_newsNextRisk="NONE";
 g_newsNextBlockingTime=0;g_newsNextBlockingPre=0;
 g_newsBlockUntil=0;g_newsBlockName="";g_newsBlockRisk=0;
 g_newsAttentionRisk=0;g_newsAttentionName="";

 if(MQLInfoInteger(MQL_TESTER))
 {
  g_newsFeedStatus="CALENDAR UNAVAILABLE IN TESTER";
  return false;
 }

 MqlCalendarValue values[];
 ResetLastError();
 int n=CalendarValueHistory(values,now-3600,now+48*3600,NULL,"USD");
 if(n<0)
 {
  g_newsFeedStatus="CALENDAR ERROR "+IntegerToString(GetLastError());
  return false;
 }
 if(n==0)
 {
  g_newsFeedHealthy=true;
  g_newsFeedStatus="NO USD EVENTS NEXT 48H";
  return true;
 }

 for(int i=0;i<n;i++)
 {
  MqlCalendarEvent ev;
  if(!CalendarEventById(values[i].event_id,ev))
  {
   g_newsFeedStatus="CALENDAR EVENT LOOKUP FAILED";
   return false;
  }

  int level=GoldNewsRisk(ev.name,(int)ev.importance);
  bool blocking=NewsRiskBlocks(level);
  datetime at=values[i].time;
  if(at<=0)continue;
  if(ev.time_mode!=CALENDAR_TIMEMODE_DATETIME)
  {
   // Without exact release time, do not invent a pending-order deadline.
   if(blocking && level>=3 && InpNewsBlockUntimedHighUSD)
   {
    MqlDateTime eventDay,today;
    TimeToStruct(at,eventDay);TimeToStruct(now,today);
    if(eventDay.year==today.year && eventDay.mon==today.mon &&
       eventDay.day==today.day && level>=g_newsBlockRisk)
    {
     g_newsBlockUntil=now+3600;
     g_newsBlockName="UNTIMED: "+ev.name;
     g_newsBlockRisk=level;
    }
   }
   continue;
  }
  int before=NewsPre(level);
  int after=NewsPost(level);
  if(at>=now && (g_newsNextTime==0 || at<g_newsNextTime))
  {
   g_newsNextTime=at;
   g_newsNextName=ev.name;
   g_newsNextRisk=NewsRiskLabel(level);
  }
  if(blocking && at>=now &&
     (g_newsNextBlockingTime==0 || at<g_newsNextBlockingTime))
  {
   g_newsNextBlockingTime=at;
   g_newsNextBlockingPre=before;
  }
  // LOW/MEDIUM releases are visible as cautions even if no entry is blocked.
  int watchBefore=level==1?15:before;
  int watchAfter=level==1?10:after;
  if(now>=at-watchBefore*60 && now<=at+watchAfter*60 &&
     level>g_newsAttentionRisk)
  {
   g_newsAttentionRisk=level;
   g_newsAttentionName=ev.name;
  }
  if(blocking && now>=at-before*60 && now<=at+after*60)
  {
   datetime until=at+after*60;
   if(level>g_newsBlockRisk ||
      (level==g_newsBlockRisk && until>g_newsBlockUntil))
   {
    g_newsBlockUntil=until;
    g_newsBlockName=ev.name;
    g_newsBlockRisk=level;
   }
  }
 }

 g_newsFeedHealthy=true;
 g_newsFeedStatus="USD CALENDAR LIVE";
 return true;
}

void DetectSuddenNewsShock()
{
 if(!InpNewsPriceShockGuard)return;
 datetime now=TimeTradeServer();
 if(now<=0)return;
 if(g_newsLastShock>0&&now-g_newsLastShock<3)return;
 g_newsLastShock=now;
 MqlTick tick;
 if(!SymbolInfoTick(_Symbol,tick))return;

 string problem="";
 double spread=(tick.ask-tick.bid)/_Point;
 if(InpNewsMaxSpreadPoints>0&&spread>InpNewsMaxSpreadPoints)
  problem="SPREAD SPIKE "+DoubleToString(spread,0)+"pt";

 MqlRates m1[];
 ArraySetAsSeries(m1,true);
 int copied=CopyRates(_Symbol,PERIOD_M1,0,15,m1);
 if(copied>=14&&InpNewsM1SpikeMultiple>1.0)
 {
  double avg=0.0;
  for(int i=1;i<=12;i++)avg+=m1[i].high-m1[i].low;
  avg/=12.0;
  double currentRange=m1[0].high-m1[0].low;
  if(avg>_Point&&currentRange>InpNewsM1SpikeMultiple*avg)
   problem="M1 CANDLE PRICE SHOCK";
 }
 if(problem!="")
 {
  g_newsShockReason=problem;
  g_newsShockUntil=now+MathMax(1,InpNewsShockHoldMinutes)*60;
 }
}

bool NewsAllowsAutoEntry()
{
 if(!InpEnableUSDNewsGuard)
 {
  g_newsEntryBlocked=false;g_newsStatus="NEWS GUARD OFF";
  return true;
 }
 bool ok=RefreshNewsCalendar();
 DetectSuddenNewsShock();
 datetime now=TimeTradeServer();
 g_newsEntryBlocked=false;
 if(g_newsShockUntil>now)
 {
  g_newsStatus="NEWS BLOCK SHOCK: "+g_newsShockReason;
  g_newsEntryBlocked=true;
 }
 else if(!ok)
 {
  g_newsStatus="NEWS CALENDAR UNKNOWN: "+g_newsFeedStatus;
  g_newsEntryBlocked=InpNewsGuardFailClosed;
 }
 else if(g_newsBlockUntil>now)
 {
  g_newsStatus="NEWS BLOCK "+NewsRiskLabel(g_newsBlockRisk)+": "+g_newsBlockName;
  g_newsEntryBlocked=true;
 }
 else if(g_newsAttentionRisk==2)
  g_newsStatus="NEWS CAUTION MEDIUM: "+g_newsAttentionName;
 else if(g_newsAttentionRisk==1)
  g_newsStatus="NEWS LOW: "+g_newsAttentionName;
 else g_newsStatus="NEWS CLEAR";
 if(g_newsStatus!=g_newsLastLoggedStatus)
 {
  g_newsLastLoggedStatus=g_newsStatus;
  AuditEvent("NEWS","DECISION",g_newsEntryBlocked?"BLOCK":"ALLOW",g_newsStatus);
 }
 return !g_newsEntryBlocked;
}

datetime NextNewsPendingDeadline()
{
 if(!InpEnableUSDNewsGuard || !g_newsFeedHealthy ||
    g_newsNextBlockingTime<=0)return 0;
 // LOW / nonblocking MEDIUM never shorten the broker-side R2 expiry.
 return g_newsNextBlockingTime-MathMax(0,g_newsNextBlockingPre)*60;
}


// ============================================================
// INTEGRATED READ-ONLY BRIDGE DIAGNOSTICS
// ============================================================
// Reuse live /update POST, /zones/latest GET, and /r2 GET outcomes.
// A single additional GET is staggered per probe interval, after
// management and execution on OnTimer. Never called from OnTick.

datetime g_bridgeLastPostOK=0;
datetime g_bridgeLastR1OK=0;
datetime g_bridgeLastR2OK=0;
datetime g_bridgeLastHealthOK=0;
datetime g_bridgeLastCloudOK=0;
datetime g_bridgeLastResultsOK=0;
datetime g_bridgeLastProbe=0;
int g_bridgeProbeIndex=0;
double g_bridgeCloudAge=-1.0;
string g_bridgeLastWarning="";
bool g_bridgeLastCloudValid=false;

bool BridgeIsOK(int http,string json)
{
   return http>=200 && http<300 &&
          StringFind(json,"\"ok\":true")>=0;
}

bool BridgeRecent(datetime value,int maxSeconds)
{
   if(value<=0)return false;
   int age=(int)(TimeTradeServer()-value);
   return age>=-5 && age<=maxSeconds;
}

void BridgeObserve(string source,bool ok,int httpStatus)
{
   if(!InpEnableIntegratedBridgeMonitor)return;
   datetime now=TimeTradeServer();
   if(ok)
   {
      if(source=="POST")g_bridgeLastPostOK=now;
      else if(source=="R1")g_bridgeLastR1OK=now;
      else if(source=="R2")g_bridgeLastR2OK=now;
   }
   else
   {
      string message=source+" HTTP "+IntegerToString(httpStatus);
      if(g_bridgeLastWarning!=message)
      {
         Print("BRIDGE DIAGNOSTICS | "+message);
         g_bridgeLastWarning=message;
      }
      if(source=="POST")g_bridgeLastPostOK=0;
      else if(source=="R1")g_bridgeLastR1OK=0;
      else if(source=="R2")g_bridgeLastR2OK=0;
   }
}

void BridgeProbeOne()
{
   if(!InpEnableIntegratedBridgeMonitor)return;
   datetime now=TimeTradeServer();
   if(now<=0)return;
   int interval=MathMax(20,InpBridgeProbeEverySeconds);
   if(g_bridgeLastProbe>0 && now-g_bridgeLastProbe<interval)return;
   g_bridgeLastProbe=now;

   int step=g_bridgeProbeIndex%6;
   g_bridgeProbeIndex++;
   string url="";
   // v3.5.27: probe the compact news/snapshot heartbeat rather than
   // repeatedly downloading hundreds of M1/M5/M15/M30/H1 candles.
   if(step==0||step==3)url="/health";
   else if(step==2||step==5)url="/bot-results?limit=1";
   else url="/news/status";

   string join=StringFind(url,"?")>=0?"&":"?";
   string response="";
   int http=HttpGet(InpWorkerBaseURL+url+join+"cb="+
                    IntegerToString((long)GetTickCount()),response);
   bool ok=BridgeIsOK(http,response);
   string failReason=ok?"":"HTTP_NOT_OK_OR_JSON_NOT_OK";

   if(step==0||step==3)
   {
      // Strict version and strategy parity: old v2.8 must fail.
      if(ok && StringFind(response,"\"build\":\"XAU_V4_ICT_SMC_ADAPTIVE_MARKET_PENDING\"")<0)
      {ok=false;failReason="WRONG_WORKER_BUILD";}
      if(ok && StringFind(response,"\"strategy_model\":\"ICT_SMC_V4_LIVE\"")<0)
      {ok=false;failReason="WRONG_ICT_SMC_MODEL";}
      // Check stable capability flags, NOT the build-name string.
      // Worker v2.4 renamed BUILD_VERSION while retaining the same features.
      if(ok && StringFind(response,"\"service\":\"XAU Live Bridge\"")<0)
      {
         ok=false;failReason="MISSING_BRIDGE_SERVICE";
      }
      if(ok && StringFind(response,"\"bot_results_feed\":\"AUTO_BASKETS\"")<0)
      {
         ok=false;failReason="MISSING_AUTO_BASKETS";
      }
      if(ok && StringFind(response,"\"news_policy_sync\":\"MT5_AUTHORITATIVE_FAIL_CLOSED\"")<0)
      {
         ok=false;failReason="NEWS_POLICY_BUILD_MISMATCH";
      }
      g_bridgeLastHealthOK=ok?TimeTradeServer():0;
   }
   else if(step==2||step==5)
   {
      if(ok && StringFind(response,"\"REAL_AUTO_BASKETS\"")<0)
      {
         ok=false;failReason="MISSING_REAL_AUTO_BASKETS";
      }
      g_bridgeLastResultsOK=ok?TimeTradeServer():0;
   }
   else
   {
      // /news/status is built from the exact latest_market D1 row, which
      // the broker has uploaded. The endpoint also verifies policy schema,
      // source timestamp and Cloudflare receive-age (< 30 seconds).
      // A blocked news event is a VALID bridge response; UNKNOWN is not.
      if(ok &&
         (StringFind(response,"\"news_gate\":{")<0 ||
          StringFind(response,"\"source\":\"MT5_NEWS_POLICY_V1\"")<0 ||
          StringFind(response,"\"checked_at_server\":")<0 ||
          StringFind(response,"\"market_age_seconds\":")<0))
      {
         ok=false;failReason="NEWS_SNAPSHOT_FIELDS_MISSING";
      }
      if(ok && StringFind(response,"\"state\":\"UNKNOWN\"")>=0)
      {
         ok=false;failReason="NEWS_POLICY_UNKNOWN_OR_STALE";
      }
      if(ok &&
         StringFind(response,"\"state\":\"ALLOWED\"")<0 &&
         StringFind(response,"\"state\":\"BLOCKED\"")<0)
      {
         ok=false;failReason="NEWS_POLICY_STATE_INVALID";
      }
      g_bridgeCloudAge=ok?
           JsonGetDouble(response,"market_age_seconds"):-1.0;
      if(ok && (g_bridgeCloudAge<0 ||
         g_bridgeCloudAge>InpBridgeMaxMarketAgeSeconds))
      {
         ok=false;failReason="MARKET_AGE_OVER_LIMIT";
      }
      if(ok)
      {
         // Compare two BROKER SERVER clock values, not Cloudflare UTC.
         datetime brokerChecked=(datetime)JsonGetDouble(
            response,"checked_at_server");
         int clockDelta=(int)MathAbs((double)
                             (TimeTradeServer()-brokerChecked));
         ok=brokerChecked>0 &&
            clockDelta<=MathMax(60,InpBridgeMaxMarketAgeSeconds*2);
         if(!ok)failReason="NEWS_SNAPSHOT_BROKER_CLOCK_STALE";
      }
      g_bridgeLastCloudValid=ok;
      g_bridgeLastCloudOK=ok?TimeTradeServer():0;
   }
   if(!ok)
   {
      string message=url+" CHECK FAILED HTTP "+IntegerToString(http)+
                     " | "+failReason;
      if(message!=g_bridgeLastWarning)
      {
         Print("BRIDGE DIAGNOSTICS | "+message);
         g_bridgeLastWarning=message;
      }
   }
}

string BridgeOverall()
{
   if(!InpEnableIntegratedBridgeMonitor)return "OFF";
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))return "MT5 OFFLINE";
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick))return "TICK UNKNOWN";
   long age=(long)(TimeTradeServer()-tick.time);
   if(age< -5 || age>InpBridgeMaxBrokerTickAgeSeconds)
      return "TICK STALE";
   if(!BridgeRecent(g_bridgeLastPostOK,
                    MathMax(45,InpMarketSendEverySeconds*4)))
      return "UPLINK STALE";
   if(!BridgeRecent(g_bridgeLastHealthOK,
                    MathMax(185,InpBridgeProbeEverySeconds*9)))
      return "HEALTH UNKNOWN";
   if(!BridgeRecent(g_bridgeLastCloudOK,
                    MathMax(105,InpBridgeProbeEverySeconds*6)))
      return "CLOUD UNVERIFIED";
   if(InpDrawDecisionZones &&
      !BridgeRecent(g_bridgeLastR1OK,MathMax(60,InpZonePollEverySeconds*8)))
      return "R1 RX STALE";
   if(InpDrawR2Setup &&
      !BridgeRecent(g_bridgeLastR2OK,MathMax(60,InpR2PollEverySeconds*8)))
      return "R2 RX STALE";
   if(InpDrawDecisionZones && !g_ictR1ModelOK)return "R1 MODEL NOT VERIFIED";
   if(InpDrawR2Setup && !g_ictR2ModelOK)return "R2 MODEL NOT VERIFIED";
   if(InpDrawDecisionZones && !R1WatchFeedFresh())return "R1 DATA STALE";
   if(InpDrawR2Setup &&
      (g_r2LastFreshPollServer<=0 ||
       TimeTradeServer()-g_r2LastFreshPollServer>
       MathMax(20,InpR2PollEverySeconds*4)))
      return "R2 DATA STALE";
   return "OK | ICT/SMC V4";
}

string BridgeStatusUplink()
{
   if(!InpEnableIntegratedBridgeMonitor)return "MONITOR OFF";
   datetime now=TimeTradeServer();
   MqlTick tick;
   string age="?";
   if(SymbolInfoTick(_Symbol,tick))
      age=IntegerToString((long)(now-tick.time))+"s";
   string cloud=g_bridgeCloudAge>=0?
      DoubleToString(g_bridgeCloudAge,1)+"s@check":"?";
   return "MT5 > WORKER  "+
      (BridgeRecent(g_bridgeLastPostOK,
                    MathMax(45,InpMarketSendEverySeconds*4))?"OK":"WAIT")+
      "   |   TICK "+age+"   |   CLOUD "+cloud;
}

string BridgeStatusDownlink()
{
   if(!InpEnableIntegratedBridgeMonitor)return "MONITOR OFF";
   string r1=InpDrawDecisionZones?
      (BridgeRecent(g_bridgeLastR1OK,MathMax(60,InpZonePollEverySeconds*8))
       ?"OK":"WAIT"):"OFF";
   string r2=InpDrawR2Setup?
      (BridgeRecent(g_bridgeLastR2OK,MathMax(60,InpR2PollEverySeconds*8))
       ?"OK":"WAIT"):"OFF";
   string health=BridgeRecent(g_bridgeLastHealthOK,
                   MathMax(185,InpBridgeProbeEverySeconds*9))
       ?"OK":"WAIT";
   return "WORKER > MT5   R1 "+r1+" | R2 "+r2+
          " | BUILD "+health;
}

bool PrecheckNewPendingRiskAgainstCap(
   string side,
   double volume,
   double entry,
   double sl,
   double capPercent,
   double &projectedRiskMoney,
   double &projectedRiskPercent,
   string &error
)
{
   projectedRiskMoney = 0.0;
   projectedRiskPercent = 0.0;
   error = "";

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);

   if(balance <= 0.0)
   {
      error = "INVALID ACCOUNT BALANCE";
      return false;
   }

   double currentRiskMoney = 0.0;
   double currentRiskPercent = 0.0;
   int unknownItems = 0;

   bool allKnown =
      CalculateCurrentXAUPotentialSLRisk(
         currentRiskMoney,
         currentRiskPercent,
         unknownItems
      );

   if(!allKnown)
   {
      error =
         "POTENTIAL SL RISK UNKNOWN | " +
         IntegerToString(unknownItems) +
         " ITEM(S)";

      return false;
   }

   double newRiskMoney = 0.0;

   if(
      !CalculateProposedMarketRiskMoney(
         side,
         volume,
         entry,
         sl,
         newRiskMoney
      )
   )
   {
      error = "CANNOT CALCULATE PENDING SL RISK";
      return false;
   }

   projectedRiskMoney = currentRiskMoney + newRiskMoney;
   projectedRiskPercent = projectedRiskMoney / balance * 100.0;

   if(
      capPercent > 0.0 &&
      projectedRiskPercent > capPercent + 1e-8
   )
   {
      error =
         "RISK " +
         DoubleToString(projectedRiskPercent, 2) +
         "% > CAP " +
         DoubleToString(capPercent, 2) +
         "%";

      return false;
   }

   return true;
}


bool BuildR2PendingExecutionPlan(
   string &orderType,
   string &side,
   double &entry,
   double &sl,
   double &tp,
   datetime &expiry,
   string &planKey,
   string &error
)
{
   orderType = "";
   side = "NONE";
   entry = 0.0;
   sl = 0.0;
   tp = 0.0;
   expiry = 0;
   planKey = "";
   error = "";

   // Pending Only: reject unverified protocol or old R2 data for NEW
   // orders. Existing broker-pending orders are managed separately.
   if(!g_r2PendingProtocolOK)
   {
      error = "WORKER_PENDING_ONLY_PROTOCOL_MISSING";
      return false;
   }
   datetime brokerNow=TimeTradeServer();
   int maxR2Age=MathMax(20,InpR2PollEverySeconds*4);
   if(g_r2LastFreshPollServer<=0 ||
      brokerNow-g_r2LastFreshPollServer>maxR2Age ||
      brokerNow-g_r2LastFreshPollServer< -5)
   {
      error = "R2_DATA_STALE_NO_NEW_ORDER";
      return false;
   }
   if(!g_r2PendingViable)
   {
      error = "PENDING_ONLY_WAIT | "+g_r2PendingOnlyReason;
      return false;
   }
   if(!g_r2Allowed)
   {
      error = "R2_SETUP_NOT_ALLOWED | "+g_r2PendingOnlyReason;
      return false;
   }

   // A valid pending setup can only be executed with Worker v2.5;
   // direct BUY or SELL is never sent from the broker executor.
   bool supportedPending =
      g_r2OrderType == "BUY_LIMIT" ||
      g_r2OrderType == "SELL_LIMIT" ||
      g_r2OrderType == "BUY_STOP" ||
      g_r2OrderType == "SELL_STOP";

   if(!supportedPending)
   {
      error =
         "NO R2 PENDING PLAN | " +
         g_r2OrderType;

      return false;
   }

   if(
      g_r2Strategy == "" ||
      g_r2Strategy == "NONE"
   )
   {
      error = "R2 STRATEGY NONE";
      return false;
   }

   if(g_r2Score < InpR2PendingMinScore)
   {
      error =
         "R2 SCORE " +
         IntegerToString(g_r2Score) +
         " < " +
         IntegerToString(InpR2PendingMinScore);

      return false;
   }

   if(g_r2RR < InpR2PendingMinRR - 1e-8)
   {
      error =
         "R2 RR " +
         DoubleToString(g_r2RR, 2) +
         " < " +
         DoubleToString(InpR2PendingMinRR, 2);

      return false;
   }

   if(
      g_r2Entry <= 0.0 ||
      g_r2SL <= 0.0 ||
      g_r2TP1 <= 0.0
   )
   {
      error = "R2 PLAN INCOMPLETE";
      return false;
   }

   orderType = g_r2OrderType;

   side =
      (
         orderType == "BUY_LIMIT" ||
         orderType == "BUY_STOP"
      )
      ? "BUY"
      : "SELL";
   entry = g_r2Entry;
   sl = g_r2SL;

   tp =
      (
         InpR2PendingUseTP2AsFinal &&
         g_r2TP2 > 0.0
      )
      ? g_r2TP2
      : g_r2TP1;

   string stopError = "";

   if(!ValidateStops(side, entry, sl, tp, stopError))
   {
      error = "INVALID R2 SL/TP | " + stopError;
      return false;
   }

   // Wide structural SL is permitted for R2. Actual broker-side money risk
   // is calculated per chunk and the executor stops before the shared
   // account-percent SL-risk cap can be exceeded.

   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
   {
      error = "NO MARKET TICK";
      return false;
   }

   double brokerMinDistance =
      (double)SymbolInfoInteger(
         _Symbol,
         SYMBOL_TRADE_STOPS_LEVEL
      ) *
      _Point;

   if(orderType == "BUY_LIMIT")
   {
      if(entry >= tick.ask - brokerMinDistance)
      {
         error = "BUY_LIMIT ENTRY ALREADY REACHED / TOO CLOSE";
         return false;
      }
   }
   else if(orderType == "SELL_LIMIT")
   {
      if(entry <= tick.bid + brokerMinDistance)
      {
         error = "SELL_LIMIT ENTRY ALREADY REACHED / TOO CLOSE";
         return false;
      }
   }
   else if(orderType == "BUY_STOP")
   {
      if(entry <= tick.ask + brokerMinDistance)
      {
         error = "BUY_STOP ENTRY ALREADY REACHED / TOO CLOSE";
         return false;
      }
   }
   else if(orderType == "SELL_STOP")
   {
      if(entry >= tick.bid - brokerMinDistance)
      {
         error = "SELL_STOP ENTRY ALREADY REACHED / TOO CLOSE";
         return false;
      }
   }


   int secondsToClose=0;
   if(!AutoEntrySessionOpen(secondsToClose))
   {error="OUTSIDE BROKER AUTO SESSION";return false;}
   int expirySec=g_r2ExpiryHours>0.0?(int)MathRound(g_r2ExpiryHours*3600.0):3600;
   if(InpEnableBrokerServerAutoWindow)expirySec=MathMin(expirySec,secondsToClose);
   if(expirySec<=0){error="SESSION CLOSED";return false;}
   expiry=TimeTradeServer()+(datetime)expirySec;
   datetime newsExpiry=NextNewsPendingDeadline();
   if(newsExpiry>0&&newsExpiry<expiry)
      expiry=newsExpiry;
   if(expiry<=TimeTradeServer())
   {
      error="PENDING NEWS CUT-OFF";
      return false;
   }

   planKey =
      orderType + "|" +
      g_r2Strategy + "|" +
      DoubleToString(entry, _Digits) + "|" +
      DoubleToString(sl, _Digits) + "|" +
      DoubleToString(tp, _Digits) + "|" +
      IntegerToString(g_r2Score);

   return true;
}


bool ExistingR2PendingOrdersMatchPlan(
   string orderType,
   double entry,
   double sl,
   double tp
)
{
   int count = 0;
   double tolerance = MathMax(_Point * 2.0, 0.0000001);

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);

      if(ticket == 0)
         continue;

      if(OrderGetString(ORDER_SYMBOL) != _Symbol)         continue;

      if(OrderGetInteger(ORDER_MAGIC) != InpMagicNumber)
         continue;

      ENUM_ORDER_TYPE type =
         (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

      if(!IsPendingOrderType(type))
         continue;

      if(!IsR2ManagedPendingComment(OrderGetString(ORDER_COMMENT)))
         continue;

      bool typeMatches =
         (
            orderType == "BUY_LIMIT" &&
            type == ORDER_TYPE_BUY_LIMIT
         ) ||
         (
            orderType == "SELL_LIMIT" &&
            type == ORDER_TYPE_SELL_LIMIT
         ) ||
         (
            orderType == "BUY_STOP" &&
            type == ORDER_TYPE_BUY_STOP
         ) ||
         (
            orderType == "SELL_STOP" &&
            type == ORDER_TYPE_SELL_STOP
         );

      if(!typeMatches)
         return false;

      if(
         MathAbs(OrderGetDouble(ORDER_PRICE_OPEN) - entry) > tolerance ||
         MathAbs(OrderGetDouble(ORDER_SL) - sl) > tolerance ||
         MathAbs(OrderGetDouble(ORDER_TP) - tp) > tolerance
      )
      {
         return false;
      }

      count++;
   }

   return count > 0;
}


bool PendingTradeRetcodePlaced()
{
   uint code = trade.ResultRetcode();

   return
      code == TRADE_RETCODE_DONE ||
      code == TRADE_RETCODE_PLACED;
}


bool SendProtectedR2PendingOrder(
   string orderType,
   double volume,
   double entry,
   double sl,
   double tp,
   datetime expiry,
   string basketId,
   string &resultText
)
{
   resultText = "";
   volume = NormalizeOpenVolumeFloor(volume);

   if(volume <= 0.0)
   {
      resultText = "INVALID LOT";
      return false;
   }

   if(
      !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ||
      !MQLInfoInteger(MQL_TRADE_ALLOWED) ||
      !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)
   )
   {
      resultText = "AUTOTRADING / ACCOUNT TRADING NOT ALLOWED";
      return false;
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpMaxDeviationPoints);

   ENUM_ORDER_TYPE_TIME timeType =
      expiry > 0
      ? ORDER_TIME_SPECIFIED
      : ORDER_TIME_GTC;

   string baseComment = "XAU_R2P";

   if(orderType == "BUY_LIMIT")
      baseComment = "XAU_R2P_BUYL";
   else if(orderType == "SELL_LIMIT")
      baseComment = "XAU_R2P_SELLL";
   else if(orderType == "BUY_STOP")
      baseComment = "XAU_R2P_BUYS";
   else if(orderType == "SELL_STOP")
      baseComment = "XAU_R2P_SELLS";

   string comment =
      AutoBasketComment(
         baseComment,
         basketId
      );

   ResetLastError();

   bool accepted = false;

   if(orderType == "BUY_LIMIT")
   {
      accepted =
         trade.BuyLimit(
            volume,
            entry,
            _Symbol,
            sl,
            tp,
            timeType,
            expiry,
            comment
         );
   }
   else if(orderType == "SELL_LIMIT")
   {
      accepted =
         trade.SellLimit(
            volume,
            entry,
            _Symbol,
            sl,
            tp,
            timeType,
            expiry,
            comment
         );
   }
   else if(orderType == "BUY_STOP")
   {
      accepted =
         trade.BuyStop(
            volume,
            entry,
            _Symbol,
            sl,
            tp,
            timeType,
            expiry,
            comment
         );
   }
   else if(orderType == "SELL_STOP")
   {
      accepted =
         trade.SellStop(
            volume,
            entry,
            _Symbol,
            sl,
            tp,
            timeType,
            expiry,
            comment
         );
   }
   else
   {
      resultText = "INVALID PENDING TYPE";
      return false;
   }

   if(!accepted || !PendingTradeRetcodePlaced())
   {
      resultText =
         "FAILED " +
         IntegerToString((long)trade.ResultRetcode()) +
         " | " +
         trade.ResultRetcodeDescription();

      Print(
         "R2 PENDING ORDER FAILED | ",
         orderType,
         " | lot=",
         DoubleToString(volume, 2),
         " | entry=",
         DoubleToString(entry, _Digits),
         " | retcode=",
         trade.ResultRetcode(),
         " | ",
         trade.ResultRetcodeDescription(),
         " | error=",
         GetLastError()
      );

      return false;
   }

   resultText =
      "PLACED | " +
      orderType +
      " " +
      DoubleToString(volume, 2) +
      " LOT";

   return true;
}


// ===== ICT/SMC v4 dynamic order executor, embedded into v4 EA =====
bool ICT4Exposure(string engine)
{
 for(int i=PositionsTotal()-1;i>=0;i--)
 {
  ulong t=PositionGetTicket(i);
  if(t==0||!PositionSelectByTicket(t))continue;
  if(PositionGetString(POSITION_SYMBOL)!=_Symbol ||
     PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber)continue;
  if(AutoEngineFromComment(PositionGetString(POSITION_COMMENT))==engine)return true;
 }
 for(int i=OrdersTotal()-1;i>=0;i--)
 {
  ulong t=OrderGetTicket(i);if(t==0)continue;
  if(OrderGetString(ORDER_SYMBOL)!=_Symbol ||
     OrderGetInteger(ORDER_MAGIC)!=InpMagicNumber)continue;
  if(!IsPendingOrderType((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE)))continue;
  if(AutoEngineFromComment(OrderGetString(ORDER_COMMENT))==engine)return true;
 }
 return false;
}
bool ICT4PendingValid(string type,double entry)
{
 MqlTick t;if(!SymbolInfoTick(_Symbol,t))return false;
 double dist=MathMax(_Point*2,(double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point);
 if(type=="BUY_LIMIT")return entry<t.ask-dist;
 if(type=="SELL_LIMIT")return entry>t.bid+dist;
 if(type=="BUY_STOP")return entry>t.ask+dist;
 if(type=="SELL_STOP")return entry<t.bid-dist;
 return false;
}
bool ICT4Pending(string engine,string type,double lot,double entry,double sl,
                  double tp,datetime expiry,string basket,string &why)
{
 why="";
 if(!ICT4PendingValid(type,entry)){why="PENDING PRICE INVALID";return false;}
 if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ||
    !MQLInfoInteger(MQL_TRADE_ALLOWED) ||
    !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
 {why="AUTOTRADING DISABLED";return false;}
 lot=NormalizeOpenVolumeFloor(lot);
 if(lot<=0){why="INVALID LOT";return false;}
 trade.SetExpertMagicNumber(InpMagicNumber);
 trade.SetDeviationInPoints(InpMaxDeviationPoints);
 string prefix=engine=="R1"?"XAU_R1P_I4":"XAU_R2P_I4";
 string label=type=="BUY_LIMIT"?"BUYL":type=="SELL_LIMIT"?"SELLL":
              type=="BUY_STOP"?"BUYS":"SELLS";
 string comment=AutoBasketComment(prefix+label,basket);
 bool sent=false;
 if(type=="BUY_LIMIT")sent=trade.BuyLimit(lot,entry,_Symbol,sl,tp,ORDER_TIME_SPECIFIED,expiry,comment);
 else if(type=="SELL_LIMIT")sent=trade.SellLimit(lot,entry,_Symbol,sl,tp,ORDER_TIME_SPECIFIED,expiry,comment);
 else if(type=="BUY_STOP")sent=trade.BuyStop(lot,entry,_Symbol,sl,tp,ORDER_TIME_SPECIFIED,expiry,comment);
 else if(type=="SELL_STOP")sent=trade.SellStop(lot,entry,_Symbol,sl,tp,ORDER_TIME_SPECIFIED,expiry,comment);
 else {why="BAD PENDING TYPE";return false;}
 if(!sent || !PendingTradeRetcodePlaced())
 {why="BROKER REJECT "+IntegerToString((long)trade.ResultRetcode());return false;}
 why="PENDING ACCEPTED";
 return true;
}
void ICT4Execute(string engine)
{
 bool r1=engine=="R1";
 string status="WAIT | ICT SMC V4";
 do
 {
  if(!(r1?InpEnableAutoSignalExecutor:InpEnableR2PendingExecutor))
  {status="OFF | ENGINE";break;}
  if(InpICTSMCObserveOnly){status="MONITOR | ICT SMC V4";break;}
  bool verified=r1?g_ictR1ModelOK:g_ictR2ModelOK;
  datetime fresh=r1?g_r1LastFreshFeedServer:g_r2LastFreshPollServer;
  if(!verified||fresh<=0||TimeTradeServer()-fresh>
     MathMax(10,r1?InpR1MaxFeedAgeSeconds:InpR2PollEverySeconds*4))
  {status="BLOCK | WORKER MODEL/AGE";break;}
  if(!NewsAllowsAutoEntry()){status="BLOCK | NEWS";break;}
  int sessionLeft=0;
  if(!AutoEntrySessionOpen(sessionLeft)){status="OFF | SESSION";break;}
  string side=r1?g_ictR1Side:g_r2Side;
  string type=r1?g_ictR1OrderType:g_r2OrderType;
  double entry=r1?g_ictR1Entry:g_r2Entry;
  double sl=r1?g_ictR1SL:g_r2SL;
  double tp=r1?g_ictR1TP:
     ((InpR2PendingUseTP2AsFinal&&g_r2TP2>0)?g_r2TP2:g_r2TP1);
  bool allowed=r1?g_ictR1Allowed:g_r2Allowed;
  if(!r1 && (type!="BUY_LIMIT" && type!="SELL_LIMIT" &&
              type!="BUY_STOP" && type!="SELL_STOP"))
  {status="BLOCK | R2 MUST BE PENDING";break;}
  if(!allowed|| (side!="BUY"&&side!="SELL")||
     (type!=side && type!="BUY_LIMIT"&&type!="SELL_LIMIT"&&
      type!="BUY_STOP"&&type!="SELL_STOP"))
  {status="WAIT | NO ICT CONFIRMATION";break;}
  if(entry<=0||sl<=0||tp<=0){status="BLOCK | INCOMPLETE LEVELS";break;}
  if(ICT4Exposure(engine)){status="WAIT | ENGINE POSITION/ORDER";break;}
  MqlTick q;if(!SymbolInfoTick(_Symbol,q)){status="NO TICK";break;}
  double quote=side=="BUY"?q.ask:q.bid;
  double realEntry=type==side?quote:entry;
  if(type==side &&
     MathAbs(realEntry-entry)>MathMax(_Point*5,InpICTSMCMaxMarketDriftUSD))
  {status="WAIT | PRICE DRIFT";break;}
  if(type!=side&&!ICT4PendingValid(type,entry))
  {status="WAIT | PENDING LEVEL STALE";break;}
  string why="";
  if(!ValidateStops(side,realEntry,sl,tp,why))
  {status="BLOCK | "+why;break;}
  string setup=r1?g_ictR1SetupKey:
    g_r2Strategy+"|"+type+"|"+DoubleToString(entry,_Digits)+"|"+
    DoubleToString(sl,_Digits);
  if(StringLen(setup)<5){status="BLOCK | INVALID SETUP KEY";break;}
  string basket=AutoBasketHashId(engine,setup);
  string used="ICT4_"+IntegerToString((long)AccountInfoInteger(ACCOUNT_LOGIN))+
              "_"+engine+"_"+basket;
  if(GlobalVariableCheck(used)){status="DONE | ALREADY EXECUTED";break;}
  double cap=r1?EffectiveAutoRiskCapPercent()*LearningFactor("R1"):
    MathMax(0.0,InpR2AutoMaxSLRiskPercent)*LearningFactor("R2");
  if(InpEnableMaxSLRiskGuard&&InpMaxSLRiskPercent>0)
     cap=MathMin(cap,InpMaxSLRiskPercent);
  double lot=0,projected=0;
  if(!CalculateSingleRiskSizedLot(engine,side,realEntry,sl,cap,lot,projected,why))
  {status="BLOCK | "+why;break;}
  bool accepted=false;
  if(type==side)
  {
   string cm=engine=="R1"?"XAU_AUTO_I4"+side:"XAU_R2P_I4"+side+"M";
   accepted=SendProtectedMarketOrder(side,lot,sl,tp,
               AutoBasketComment(cm,basket),why);
  }
  else
  {
   int ttl=MathMin(r1?3600:21600,sessionLeft);
   datetime expiry=TimeTradeServer()+(datetime)MathMax(0,ttl);
   datetime newsCut=NextNewsPendingDeadline();
   if(newsCut>0&&newsCut<expiry)expiry=newsCut;
   if(expiry>TimeTradeServer()+30)
     accepted=ICT4Pending(engine,type,lot,entry,sl,tp,expiry,basket,why);
   else why="PENDING EXPIRES AT SESSION/NEWS";
  }
  if(accepted)
  {
   GlobalVariableSet(used,(double)TimeTradeServer());
   status=(type==side?"OPEN ":"ARMED ")+type+" 1x"+DoubleToString(lot,2);
   AuditEvent(engine,"EXECUTED",type,"ICT_SMC_V4",0,entry,sl,tp);
  }
  else status="REJECT | "+why;
 }while(false);
 if(r1)g_autoExecutionStatus=status;
 else g_r2PendingExecutionStatus=status;
}
void ProcessICT4Executors()
{
 ICT4Execute("R1");
 ICT4Execute("R2");
}
// ===== end ICT/SMC v4 executor =====

void ProcessR2PendingExecutor()
{
   if(!InpEnableR2PendingExecutor)
   {
      if(CountR2PendingOrders() > 0)
         DeleteR2PendingOrders("R2 PENDING EXECUTOR OFF");

      g_r2PendingExecutionStatus = "OFF";
      g_r2PendingPlanKey = "";
      return;
   }

   if(g_r2PendingExecutionInProgress)
      return;

   g_r2PendingExecutionInProgress = true;

   if(!NewsAllowsAutoEntry())
   {
      DeleteR2PendingOrders("NEWS GUARD");
      g_r2PendingExecutionStatus="BLOCK | NEWS";
      g_r2PendingPlanKey="";
      g_r2PendingExecutionInProgress=false;
      return;
   }
   int sessionSeconds=0;
   if(!AutoEntrySessionOpen(sessionSeconds))
   {
      DeleteR2PendingOrders("BROKER AUTO SESSION CLOSED");
      g_r2PendingExecutionStatus="OFF | SESSION CLOSED";
      g_r2PendingPlanKey="";
      g_r2PendingExecutionInProgress=false;
      return;
   }
   double capPercent=MathMax(0.0,InpR2AutoMaxSLRiskPercent)*LearningFactor("R2");
   if(InpEnableMaxSLRiskGuard&&InpMaxSLRiskPercent>0.0)
      capPercent=MathMin(capPercent,InpMaxSLRiskPercent);

   if(capPercent <= 0.0)
   {
      DeleteR2PendingOrders("INVALID RISK CAP");
      g_r2PendingExecutionStatus = "BLOCK | INVALID CAP";
      g_r2PendingExecutionInProgress = false;
      return;
   }

   // Independent 5% budgets; a separate total 10% risk cap still applies.
   // Broker-accepted R2 pending orders are now LOCKED. Do not reprice/replace
   // them on every Worker poll or convert them to market orders.
   if(InpR2KeepArmedPlan && CountR2PendingOrders()>0)
   {
      string why=R2ArmedInvalidation();
      // Never keep an order that now violates total or R2-only risk limits.
      if(why=="")
      {
         double money=0.0,pct=0.0;int unknown=0;
         bool known=CalculateCurrentXAUPotentialSLRisk(money,pct,unknown);
         double hardCap=EffectiveTotalXAUAutoRiskCapPercent();
         if(!known)why="UNVERIFIABLE_TOTAL_SL_RISK";
         else if(pct>hardCap+0.01)why="TOTAL_SL_RISK_CAP_EXCEEDED";
         double r2Money=0.0,r2Pct=0.0;int r2Unknown=0;
         bool r2Known=CalculateAutoEnginePotentialSLRisk(
            "R2",r2Money,r2Pct,r2Unknown);
         if(!r2Known)why="UNKNOWN_R2_SL_RISK";
         else if(r2Pct>capPercent+0.01)why="R2_SL_RISK_CAP_EXCEEDED";
      }
      if(why!="")
      {
         DeleteR2PendingOrders(why);
         g_r2PendingPlanKey="";
         g_r2PendingExecutionStatus="CANCEL | "+why;
         AuditState("R2","CANCEL",why);
      }
      else
      {
         g_r2PendingExecutionStatus="ARMED | LOCKED UNTIL EXPIRY";
         AuditState("R2","HOLD",R2PendingSummary());
      }
      g_r2PendingExecutionInProgress=false;
      return;
   }
   if(R2AlreadyHasOpenPosition())
   {
      g_r2PendingExecutionStatus="WAIT | R2 POSITION ALREADY ACTIVE";
      AuditState("R2","WAIT","ACTIVE_R2_POSITION");
      g_r2PendingExecutionInProgress=false;
      return;
   }

   string orderType = "";
   string side = "NONE";
   double entry = 0.0;
   double sl = 0.0;
   double tp = 0.0;
   datetime expiry = 0;
   string planKey = "";
   string planError = "";

   if(
      !BuildR2PendingExecutionPlan(
         orderType,
         side,
         entry,
         sl,
         tp,
         expiry,
         planKey,
         planError
      )
   )
   {
      DeleteR2PendingOrders(planError);
      g_r2PendingExecutionStatus = "WAIT | " + planError;
       AuditState("R2","REJECT",planError);
      g_r2PendingPlanKey = "";
      g_r2PendingExecutionInProgress = false;
      return;
   }

   // If this exact R2 plan was already armed and the broker-side orders
   // are no longer pending (for example because they triggered), do not
   // continuously re-arm the same pending plan. A changed R2 plan gets a new key.
   if(
      CountR2PendingOrders() == 0 &&
      g_r2PendingPlanKey != "" &&
      g_r2PendingPlanKey == planKey
   )
   {
      g_r2PendingExecutionStatus = "DONE | PLAN ALREADY ARMED";
      g_r2PendingExecutionInProgress = false;
      return;
   }

   if(
      CountR2PendingOrders() > 0 &&
      !ExistingR2PendingOrdersMatchPlan(
         orderType,
         entry,
         sl,
         tp
      )
   )
   {
      if(!DeleteR2PendingOrders("R2 PLAN CHANGED"))
      {
         g_r2PendingExecutionStatus = "BLOCK | CANNOT REPLACE OLD PLAN";
         g_r2PendingExecutionInProgress = false;
         return;
      }
   }

   // Mark consumed only when the broker actually accepted >=1 order.
   // A failed placement must remain eligible after a bounded cooldown.
   datetime nowR2Attempt=TimeTradeServer();
   if(planKey==g_r2LastAttemptPlanKey &&
      nowR2Attempt-g_r2LastAttemptAt<
      MathMax(5,InpR2FailedPlanRetrySeconds))
   {
      g_r2PendingExecutionStatus="WAIT | R2 RETRY COOLDOWN";
      g_r2PendingExecutionInProgress=false;
      return;
   }
   g_r2LastAttemptPlanKey=planKey;
   g_r2LastAttemptAt=nowR2Attempt;

   // R2 issues just one pending order, not multiple chunked tickets.
   // Any existing R2 positions and pending orders are left untouched.
   string basketId=AutoBasketHashId("R2",planKey);
   double lot=0.0,projectedPct=0.0;
   string stopReason="";
   if(!CalculateSingleRiskSizedLot("R2",side,entry,sl,capPercent,
                                   lot,projectedPct,stopReason))
   {
      g_r2PendingPlanKey="";
      g_r2PendingExecutionStatus="WAIT | "+stopReason;
      AuditState("R2","REJECT",stopReason);
      g_r2PendingExecutionInProgress=false;
      return;
   }
   if(!NewsAllowsAutoEntry())
   {
      g_r2PendingExecutionStatus="BLOCK | NEWS";
      g_r2PendingExecutionInProgress=false;
      return;
   }
   string orderResult="";
   if(!SendProtectedR2PendingOrder(orderType,lot,entry,sl,tp,expiry,
                                   basketId,orderResult))
   {
      g_r2PendingPlanKey="";
      g_r2PendingExecutionStatus="WAIT | "+orderResult;
      AuditEvent("R2","REJECT","ONE_PENDING_FAILED",orderResult);
   }
   else
   {
      g_r2PendingPlanKey=planKey;
      g_r2PendingExecutionStatus="ARMED 1x"+DoubleToString(lot,2)+
         " | "+orderType+" "+DoubleToString(entry,_Digits)+
         " | RISK "+DoubleToString(projectedPct,2)+"%";
      AuditEvent("R2","PLACED","ONE_RISK_SIZED_PENDING",
                 g_r2PendingExecutionStatus,0,entry,sl,tp);
      Print("R2 SINGLE PENDING ARMED | lot=",DoubleToString(lot,2),
            " | entry=",DoubleToString(entry,_Digits),
            " | SL=",DoubleToString(sl,_Digits),
            " | TP=",DoubleToString(tp,_Digits),
            " | projected risk=",DoubleToString(projectedPct,2),"%");
   }
   g_r2PendingExecutionInProgress = false;
}


void ProcessAutoSignalExecutorCore()
{
   if(!NewsAllowsAutoEntry())
   {
      g_autoExecutionStatus="BLOCK | NEWS";
      return;
   }
   if(!InpEnableAutoSignalExecutor)
   {
      g_autoExecutionStatus = "OFF";
      return;
   }

   if(g_autoExecutionInProgress)
      return;

   int sessionSeconds=0;
   if(!AutoEntrySessionOpen(sessionSeconds))
   {
      g_autoExecutionStatus="OFF | SESSION CLOSED";
      return;
   }
   double capPercent = EffectiveAutoRiskCapPercent()*LearningFactor("R1");
   if(capPercent <= 0.0)
   {
      g_autoExecutionStatus = "BLOCK | INVALID AUTO CAP";
      return;
   }

   if(
      InpAutoExecutorRequireFlatAtSignal &&
      HasPositionOnSymbol()
   )
   {
      g_autoExecutionStatus = "WAIT | POSITION ACTIVE";
      return;
   }

   BuildSimpleDecision(true);

   string side = "NONE";

   if(g_simpleDecision == "BUY READY")
      side = "BUY";
   else if(g_simpleDecision == "SELL READY")
      side = "SELL";
   else
   {
      g_autoExecutionStatus = "WAIT READY";
      return;
   }

   double entry = 0.0;
   double sl = 0.0;
   double tp = 0.0;
   string signalKey = "";
   string planError = "";

   if(
      !BuildReadyExecutionPlan(
         side,
         entry,
         sl,
         tp,
         signalKey,
         planError,
         true
      )
   )
   {
      g_autoExecutionStatus = "BLOCK | " + planError;
      return;
   }

   string r1EntryReason="";
   if(!R1EntryAllowedForSide(side,r1EntryReason))
   {
      g_autoExecutionStatus="BLOCK | "+r1EntryReason;
      AuditState("R1","BLOCK",r1EntryReason);
      return;
   }
   if(signalKey == "" || signalKey == g_autoLastSignalKey)
      return;

   // Failed signals can retry only after cooldown, not every market tick.
   datetime nowAttempt=TimeTradeServer();
   if(signalKey==g_autoLastAttemptSignalKey &&
      nowAttempt-g_autoLastAttemptAt<MathMax(5,InpR1FailedSignalRetrySeconds))
   {
      g_autoExecutionStatus="WAIT | RETRY COOLDOWN";
      return;
   }
   g_autoLastAttemptSignalKey=signalKey;
   g_autoLastAttemptAt=nowAttempt;
   g_autoExecutionInProgress=true;

   // One R1 READY => one broker market request with calculated lot.
   string basketId=AutoBasketHashId("R1",signalKey);
   string stopReason="";
   double fillLot=0.0,projectedPct=0.0;
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick))
      stopReason="NO TICK";
   else
   {
      double liveEntry=(side=="BUY")?tick.ask:tick.bid;
      string scalpWhy="",stopError="";
      if(!R1ScalpStopDistanceAllowed(side,liveEntry,sl,scalpWhy))
         stopReason=scalpWhy;
      else if(!ValidateStops(side,liveEntry,sl,tp,stopError))
         stopReason="READY LEVELS EXPIRED | "+stopError;
      else if(!NewsAllowsAutoEntry())
         stopReason="NEWS GUARD";
      else if(!CalculateSingleRiskSizedLot("R1",side,liveEntry,sl,
                    capPercent,fillLot,projectedPct,stopReason))
      {
         // CalculateSingleRiskSizedLot fills the reason and fails closed.
      }
      else
      {
         string orderResult="";
         if(SendProtectedMarketOrder(side,fillLot,sl,tp,
               AutoBasketComment("XAU_AUTO_"+side,basketId),orderResult))
         {
            g_autoLastSignalKey=signalKey;
            SaveAutoExecutorState();
            double money=0.0,pct=0.0;int unknown=0;
            bool known=CalculateAutoEnginePotentialSLRisk(
               "R1",money,pct,unknown);
            g_autoExecutionStatus="OPEN 1x"+DoubleToString(fillLot,2)+
               " | RISK "+(known?DoubleToString(pct,2)+"%":"UNKNOWN");
            AuditEvent("R1","EXECUTED",side,"ONE_SIZED_ORDER",0,entry,sl,tp);
            Print("R1 SINGLE ORDER EXECUTED | lot=",DoubleToString(fillLot,2),
                  " | SL=",DoubleToString(sl,_Digits),
                  " | TP=",DoubleToString(tp,_Digits),
                  " | projected risk=",DoubleToString(projectedPct,2),"%");
         }
         else stopReason=orderResult;
      }
   }
   if(g_autoLastSignalKey!=signalKey)
   {
      g_autoExecutionStatus="SKIP | "+(stopReason==""?"NO CAPACITY":stopReason);
      AuditEvent("R1","REJECT","SINGLE_ORDER_SKIP",stopReason);
   }

   g_autoExecutionInProgress = false;
   SaveAutoExecutorState();
}


void ProcessAutoSignalExecutor()
{
   // Learning runs whether or not Performance card is visible.
   if(InpEnableLearningAudit)RefreshRealAutoBrokerPerformance();
   ProcessAutoSignalExecutorCore();
   string state=g_autoExecutionStatus;
   string reason=state=="WAIT READY" ? g_simpleWhy+" | "+g_simpleConfirmText : state;
   if(StringFind(state,"OPEN")==0)AuditState("R1","EXECUTED",reason);
   else if(StringFind(state,"BLOCK")==0)AuditState("R1","BLOCK",reason);
   else if(StringFind(state,"SKIP")==0)AuditState("R1","REJECT",reason);
   else if(StringFind(state,"OFF")==0)AuditState("R1","OFF",reason);
   else AuditState("R1","WAIT",reason);
}
void DrawExecutionStatusRow()
{
 NewsAllowsAutoEntry();
 DrawPanelRow(18,
  "R1 "+g_autoExecutionStatus+" | R2 "+g_r2PendingExecutionStatus,
  InpPanelMutedColor);

 int secondsToClose=0;
 bool windowOpen=AutoEntrySessionOpen(secondsToClose);
 string windowLabel=AutoEntryWindowLabel()+" | ENTRY ";
 windowLabel+=(windowOpen?"OPEN":"CLOSED");
 DrawPanelRow(19,windowLabel,
  windowOpen?InpPanelBuyColor:InpPanelWarningColor);

 double riskMoney=0.0,riskPercent=0.0;
 int unknown=0;
 bool known=CalculateCurrentXAUPotentialSLRisk(
  riskMoney,riskPercent,unknown);
 double totalCap=EffectiveTotalXAUAutoRiskCapPercent();

 DrawPanelRow(20,
  "TOTAL SL "+(known?DoubleToString(riskPercent,2)+"%":"UNKNOWN")+
  "/"+DoubleToString(totalCap,1)+"% | OTHER OPEN "+
  IntegerToString(CountOtherOpenPositions()),
  known?InpPanelMutedColor:InpPanelSellColor);

 DrawPanelRow(21,g_newsStatus,
  StringFind(g_newsStatus,"CLEAR")>=0
   ? InpPanelBuyColor:InpPanelWarningColor);

 string next="NEXT HIGH USD: NO UPCOMING EVENT";
 if(g_newsNextTime>0)
  next="NEXT USD "+TimeToString(g_newsNextTime,TIME_DATE|TIME_MINUTES)+
       " | "+g_newsNextName;
 DrawPanelRow(22,StringSubstr(next,0,68),InpPanelMutedColor);
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
// LIVE VIRTUAL PERFORMANCE TRACKER HELPERS
// ============================================================

void ResetVirtualPerformanceTrade()
{
   g_perfTrade.active = false;
   g_perfTrade.signal_key = "";
   g_perfTrade.side = "";
   g_perfTrade.confirmation = "";
   g_perfTrade.zone_type = "";
   g_perfTrade.r2_side = "";
   g_perfTrade.r2_score = 0;
   g_perfTrade.r2_aligned = false;
   g_perfTrade.r2_caution = false;
   g_perfTrade.entry = 0.0;
   g_perfTrade.sl = 0.0;
   g_perfTrade.tp = 0.0;
   g_perfTrade.risk = 0.0;
   g_perfTrade.open_time = 0;
   g_perfTrade.mfe_r = 0.0;
   g_perfTrade.mae_r = 0.0;
}


void ResetVirtualPerformanceSummary()
{
   ResetVirtualPerformanceTrade();

   g_perfLastCandidateKey = "";

   g_perfSignals = 0;
   g_perfWins = 0;
   g_perfLosses = 0;
   g_perfSkippedOverlap = 0;

   g_perfCurrentLossStreak = 0;
   g_perfMaxLossStreak = 0;

   g_perfBuyTrades = 0;
   g_perfBuyWins = 0;
   g_perfSellTrades = 0;
   g_perfSellWins = 0;

   g_perfTotalR = 0.0;
   g_perfGrossWinR = 0.0;
   g_perfGrossLossR = 0.0;
   g_perfTotalHoldSeconds = 0.0;
}


void SaveVirtualPerformanceState()
{
   if(
      !InpPersistLivePerformance ||
      g_perfStateFile == ""
   )
   {
      return;
   }

   int handle =
      FileOpen(
         g_perfStateFile,
         FILE_WRITE |
         FILE_TXT |
         FILE_ANSI |
         FILE_COMMON
      );

   if(handle == INVALID_HANDLE)
   {
      Print(
         "PERF TRACKER | could not save state. Error=",
         GetLastError()
      );
      return;
   }

   FileWrite(handle, "PERF1");

   FileWrite(handle, IntegerToString(g_perfSignals));
   FileWrite(handle, IntegerToString(g_perfWins));
   FileWrite(handle, IntegerToString(g_perfLosses));
   FileWrite(handle, IntegerToString(g_perfSkippedOverlap));

   FileWrite(handle, IntegerToString(g_perfCurrentLossStreak));
   FileWrite(handle, IntegerToString(g_perfMaxLossStreak));

   FileWrite(handle, IntegerToString(g_perfBuyTrades));
   FileWrite(handle, IntegerToString(g_perfBuyWins));
   FileWrite(handle, IntegerToString(g_perfSellTrades));
   FileWrite(handle, IntegerToString(g_perfSellWins));

   FileWrite(handle, DoubleToString(g_perfTotalR, 8));
   FileWrite(handle, DoubleToString(g_perfGrossWinR, 8));
   FileWrite(handle, DoubleToString(g_perfGrossLossR, 8));
   FileWrite(handle, DoubleToString(g_perfTotalHoldSeconds, 2));

   FileWrite(handle, g_perfLastCandidateKey);

   FileWrite(handle, g_perfTrade.active ? "1" : "0");
   FileWrite(handle, g_perfTrade.signal_key);
   FileWrite(handle, g_perfTrade.side);
   FileWrite(handle, g_perfTrade.confirmation);
   FileWrite(handle, g_perfTrade.zone_type);
   FileWrite(handle, g_perfTrade.r2_side);
   FileWrite(handle, IntegerToString(g_perfTrade.r2_score));
   FileWrite(handle, g_perfTrade.r2_aligned ? "1" : "0");
   FileWrite(handle, g_perfTrade.r2_caution ? "1" : "0");

   FileWrite(handle, DoubleToString(g_perfTrade.entry, _Digits));
   FileWrite(handle, DoubleToString(g_perfTrade.sl, _Digits));
   FileWrite(handle, DoubleToString(g_perfTrade.tp, _Digits));
   FileWrite(handle, DoubleToString(g_perfTrade.risk, _Digits));

   FileWrite(handle, IntegerToString((long)g_perfTrade.open_time));

   FileWrite(handle, DoubleToString(g_perfTrade.mfe_r, 8));
   FileWrite(handle, DoubleToString(g_perfTrade.mae_r, 8));

   FileClose(handle);
}


bool LoadVirtualPerformanceState()
{
   if(
      !InpPersistLivePerformance ||
      g_perfStateFile == "" ||
      !FileIsExist(
         g_perfStateFile,
         FILE_COMMON
      )
   )
   {
      return false;
   }

   int handle =
      FileOpen(
         g_perfStateFile,
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

   string version =
      FileReadString(handle);

   if(version != "PERF1")
   {
      FileClose(handle);
      return false;
   }

   g_perfSignals =
      (int)StringToInteger(FileReadString(handle));

   g_perfWins =
      (int)StringToInteger(FileReadString(handle));

   g_perfLosses =
      (int)StringToInteger(FileReadString(handle));

   g_perfSkippedOverlap =
      (int)StringToInteger(FileReadString(handle));

   g_perfCurrentLossStreak =
      (int)StringToInteger(FileReadString(handle));

   g_perfMaxLossStreak =
      (int)StringToInteger(FileReadString(handle));

   g_perfBuyTrades =
      (int)StringToInteger(FileReadString(handle));

   g_perfBuyWins =
      (int)StringToInteger(FileReadString(handle));

   g_perfSellTrades =
      (int)StringToInteger(FileReadString(handle));

   g_perfSellWins =
      (int)StringToInteger(FileReadString(handle));

   g_perfTotalR =
      StringToDouble(FileReadString(handle));

   g_perfGrossWinR =
      StringToDouble(FileReadString(handle));

   g_perfGrossLossR =
      StringToDouble(FileReadString(handle));

   g_perfTotalHoldSeconds =
      StringToDouble(FileReadString(handle));

   g_perfLastCandidateKey =
      FileReadString(handle);

   g_perfTrade.active =
      FileReadString(handle) == "1";

   g_perfTrade.signal_key =
      FileReadString(handle);

   g_perfTrade.side =
      FileReadString(handle);

   g_perfTrade.confirmation =
      FileReadString(handle);

   g_perfTrade.zone_type =
      FileReadString(handle);

   g_perfTrade.r2_side =
      FileReadString(handle);

   g_perfTrade.r2_score =
      (int)StringToInteger(FileReadString(handle));

   g_perfTrade.r2_aligned =
      FileReadString(handle) == "1";

   g_perfTrade.r2_caution =
      FileReadString(handle) == "1";

   g_perfTrade.entry =
      StringToDouble(FileReadString(handle));

   g_perfTrade.sl =
      StringToDouble(FileReadString(handle));

   g_perfTrade.tp =
      StringToDouble(FileReadString(handle));

   g_perfTrade.risk =
      StringToDouble(FileReadString(handle));

   g_perfTrade.open_time =
      (datetime)StringToInteger(FileReadString(handle));

   g_perfTrade.mfe_r =
      StringToDouble(FileReadString(handle));

   g_perfTrade.mae_r =
      StringToDouble(FileReadString(handle));

   FileClose(handle);

   Print(
      "PERF TRACKER | state restored | closed=",
      g_perfWins + g_perfLosses,
      " | totalR=",
      DoubleToString(g_perfTotalR, 2),
      " | active=",
      (g_perfTrade.active ? "YES" : "NO")
   );

   return true;
}


void AppendVirtualPerformanceCsv(
   string resultText,
   double resultR,
   double exitPrice,
   datetime closeTime
)
{
   if(
      !InpWriteLivePerformanceCsv ||
      g_perfHistoryFile == ""
   )
   {
      return;
   }

   int handle =
      FileOpen(
         g_perfHistoryFile,
         FILE_READ |
         FILE_WRITE |
         FILE_CSV |
         FILE_ANSI |
         FILE_COMMON,
         ';'
      );

   if(handle == INVALID_HANDLE)
   {
      Print(
         "PERF TRACKER | could not write CSV. Error=",
         GetLastError()
      );
      return;
   }

   if(FileSize(handle) == 0)
   {
      FileWrite(
         handle,
         "signal_key",
         "side",
         "open_time",
         "close_time",
         "entry",
         "sl",
         "tp",
         "exit_price",
         "result",
         "result_r",
         "mfe_r",
         "mae_r",
         "hold_minutes",
         "confirmation",
         "zone_type",
         "r2_side",
         "r2_score",
         "r2_aligned",
         "r2_caution"
      );
   }

   FileSeek(
      handle,
      0,
      SEEK_END
   );

   double holdMinutes =
      g_perfTrade.open_time > 0
      ? (double)(closeTime - g_perfTrade.open_time) / 60.0
      : 0.0;

   FileWrite(
      handle,
      g_perfTrade.signal_key,
      g_perfTrade.side,
      TimeToString(
         g_perfTrade.open_time,
         TIME_DATE | TIME_SECONDS
      ),
      TimeToString(
         closeTime,
         TIME_DATE | TIME_SECONDS
      ),
      DoubleToString(g_perfTrade.entry, _Digits),
      DoubleToString(g_perfTrade.sl, _Digits),
      DoubleToString(g_perfTrade.tp, _Digits),
      DoubleToString(exitPrice, _Digits),
      resultText,
      DoubleToString(resultR, 4),
      DoubleToString(g_perfTrade.mfe_r, 4),
      DoubleToString(g_perfTrade.mae_r, 4),
      DoubleToString(holdMinutes, 1),
      g_perfTrade.confirmation,
      g_perfTrade.zone_type,
      g_perfTrade.r2_side,
      IntegerToString(g_perfTrade.r2_score),
      (g_perfTrade.r2_aligned ? "1" : "0"),
      (g_perfTrade.r2_caution ? "1" : "0")
   );

   FileClose(handle);
}


bool BuildVirtualPerformanceCandidate(
   string &signalKey,
   string &side,
   string &confirmation,
   double &entry,
   double &sl,
   double &tp
)
{
   signalKey = "";
   side = "";
   confirmation = "NONE";
   entry = 0.0;
   sl = 0.0;
   tp = 0.0;

   if(!InpSimpleDecisionMode)
      return false;

   side =
      SimpleActionSide();

   if(
      side != "BUY" &&
      side != "SELL"
   )
   {
      return false;
   }

   bool buy =
      side == "BUY";

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

   if(
      !SimpleM5Confirmation(
         side,
         confirmation
      )
   )
   {
      return false;
   }

   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   entry =
      buy
      ? tick.ask
      : tick.bid;

   string scalpReason="";
   if(!BuildR1ScalpStop(side,entry,zoneLow,zoneHigh,sl,scalpReason))
      return false;

   double risk =
      MathAbs(
         entry - sl
      );

   if(risk <= _Point)
      return false;

   tp =
      NormalizeDouble(
         buy
         ? entry + risk * InpSimpleRR
         : entry - risk * InpSimpleRR,
         _Digits
      );

   datetime signalBar =
      iTime(
         _Symbol,
         PERIOD_M5,
         1
      );

   if(signalBar <= 0)
      return false;

   signalKey =
      side + "|" +
      IntegerToString((long)signalBar) + "|" +
      DoubleToString(zoneLow, _Digits) + "|" +
      DoubleToString(zoneHigh, _Digits);

   return true;
}


void StartVirtualPerformanceTrade(
   string signalKey,
   string side,
   string confirmation,
   double entry,
   double sl,
   double tp
)
{
   ResetVirtualPerformanceTrade();

   g_perfTrade.active = true;
   g_perfTrade.signal_key = signalKey;
   g_perfTrade.side = side;
   g_perfTrade.confirmation = confirmation;
   g_perfTrade.zone_type =
      ZoneTypeForSide(
         side == "BUY"
      );

   g_perfTrade.r2_side = g_r2Side;
   g_perfTrade.r2_score = g_r2Score;

   g_perfTrade.r2_aligned =
      (
         g_r2Side == side &&
         g_r2Score > 0
      );

   g_perfTrade.r2_caution =
      (
         g_r2Side != "" &&
         g_r2Side != "NONE" &&
         g_r2Side != side &&
         g_r2Score >=
         InpR2OppositeCautionScore
      );

   g_perfTrade.entry = entry;
   g_perfTrade.sl = sl;
   g_perfTrade.tp = tp;

   g_perfTrade.risk =
      MathAbs(
         entry - sl
      );

   g_perfTrade.open_time =
      TimeCurrent();

   g_perfTrade.mfe_r = 0.0;
   g_perfTrade.mae_r = 0.0;

   g_perfSignals++;

   if(side == "BUY")
      g_perfBuyTrades++;
   else
      g_perfSellTrades++;

   SaveVirtualPerformanceState();

   Print(
      "PERF VIRTUAL OPEN | ",
      side,
      " | entry=",
      DoubleToString(entry, _Digits),
      " | SL=",
      DoubleToString(sl, _Digits),
      " | TP=",
      DoubleToString(tp, _Digits),
      " | confirm=",
      confirmation,
      " | R2=",
      g_r2Side,
      " ",
      g_r2Score
   );
}


void FinishVirtualPerformanceTrade(
   string resultText,
   double resultR,
   double exitPrice
)
{
   if(!g_perfTrade.active)
      return;

   datetime closeTime =
      TimeCurrent();

   if(resultR > 0.0)
   {
      g_perfWins++;
      g_perfGrossWinR += resultR;
      g_perfCurrentLossStreak = 0;

      if(g_perfTrade.side == "BUY")
         g_perfBuyWins++;
      else if(g_perfTrade.side == "SELL")
         g_perfSellWins++;
   }
   else
   {
      g_perfLosses++;
      g_perfGrossLossR +=
         MathAbs(resultR);

      g_perfCurrentLossStreak++;

      if(
         g_perfCurrentLossStreak >
         g_perfMaxLossStreak
      )
      {
         g_perfMaxLossStreak =
            g_perfCurrentLossStreak;
      }
   }

   g_perfTotalR += resultR;

   if(g_perfTrade.open_time > 0)
   {
      g_perfTotalHoldSeconds +=
         MathMax(
            0.0,
            (double)(
               closeTime -
               g_perfTrade.open_time
            )
         );
   }

   AppendVirtualPerformanceCsv(
      resultText,
      resultR,
      exitPrice,
      closeTime
   );

   Print(
      "PERF VIRTUAL CLOSE | ",
      g_perfTrade.side,
      " | ",
      resultText,
      " | R=",
      DoubleToString(resultR, 2),
      " | MFE=",
      DoubleToString(g_perfTrade.mfe_r, 2),
      "R | MAE=",
      DoubleToString(g_perfTrade.mae_r, 2),
      "R | TOTAL=",
      DoubleToString(g_perfTotalR, 2),
      "R"
   );

   ResetVirtualPerformanceTrade();
   SaveVirtualPerformanceState();
}


void UpdateActiveVirtualPerformanceTrade()
{
   if(!g_perfTrade.active)
      return;

   if(g_perfTrade.risk <= _Point)
   {
      Print(
         "PERF TRACKER | active virtual trade had invalid risk and was cleared."
      );

      ResetVirtualPerformanceTrade();
      SaveVirtualPerformanceState();
      return;
   }

   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return;

   double executablePrice =
      g_perfTrade.side == "BUY"
      ? tick.bid
      : tick.ask;

   double move =
      g_perfTrade.side == "BUY"
      ? executablePrice - g_perfTrade.entry
      : g_perfTrade.entry - executablePrice;

   double currentR =
      move /
      g_perfTrade.risk;

   bool changed = false;

   if(currentR > g_perfTrade.mfe_r)
   {
      g_perfTrade.mfe_r = currentR;
      changed = true;
   }

   if(currentR < g_perfTrade.mae_r)
   {
      g_perfTrade.mae_r = currentR;
      changed = true;
   }

   bool hitTP =
      g_perfTrade.side == "BUY"
      ? executablePrice >= g_perfTrade.tp
      : executablePrice <= g_perfTrade.tp;

   bool hitSL =
      g_perfTrade.side == "BUY"
      ? executablePrice <= g_perfTrade.sl
      : executablePrice >= g_perfTrade.sl;

   if(hitTP)
   {
      double resultR =
         MathAbs(
            g_perfTrade.tp -
            g_perfTrade.entry
         ) /
         g_perfTrade.risk;

      FinishVirtualPerformanceTrade(
         "TP",
         resultR,
         g_perfTrade.tp
      );

      return;
   }

   if(hitSL)
   {
      FinishVirtualPerformanceTrade(
         "SL",
         -1.0,
         g_perfTrade.sl
      );

      return;
   }

   if(changed)
      SaveVirtualPerformanceState();
}


void ProcessVirtualPerformanceTracker()
{
   if(!InpEnableLivePerformanceTracker)
      return;

   // First update the currently simulated position.
   UpdateActiveVirtualPerformanceTrade();

   string signalKey = "";
   string side = "";
   string confirmation = "NONE";

   double entry = 0.0;
   double sl = 0.0;
   double tp = 0.0;

   if(
      !BuildVirtualPerformanceCandidate(
         signalKey,
         side,
         confirmation,
         entry,
         sl,
         tp
      )
   )
   {
      return;
   }

   // One decision per closed M5 bar / locked-zone identity.
   if(
      signalKey == "" ||
      signalKey ==
      g_perfLastCandidateKey
   )
   {
      return;
   }

   g_perfLastCandidateKey =
      signalKey;

   // Mirror one-position behavior. A fresh signal that appears while
   // a virtual trade is already active is recorded as skipped once.
   if(g_perfTrade.active)
   {
      g_perfSkippedOverlap++;

      Print(
         "PERF VIRTUAL SKIP | active virtual trade already open | signal=",
         signalKey
      );

      SaveVirtualPerformanceState();
      return;
   }

   StartVirtualPerformanceTrade(
      signalKey,
      side,
      confirmation,
      entry,
      sl,
      tp
   );
}


double VirtualPerformanceProfitFactor()
{
   if(g_perfGrossLossR <= 0.0)
      return 0.0;

   return
      g_perfGrossWinR /
      g_perfGrossLossR;
}


double VirtualPerformanceExpectancyR()
{
   int closed =
      g_perfWins +
      g_perfLosses;

   if(closed <= 0)
      return 0.0;

   return
      g_perfTotalR /
      (double)closed;
}


double VirtualPerformanceWinRate()
{
   int closed =
      g_perfWins +
      g_perfLosses;

   if(closed <= 0)
      return 0.0;

   return
      100.0 *
      (double)g_perfWins /
      (double)closed;
}


double VirtualPerformanceAverageHoldHours()
{
   int closed =
      g_perfWins +
      g_perfLosses;

   if(closed <= 0)
      return 0.0;

   return
      g_perfTotalHoldSeconds /
      3600.0 /
      (double)closed;
}


double ActiveVirtualTradeR()
{
   if(
      !g_perfTrade.active ||
      g_perfTrade.risk <= _Point
   )
   {
      return 0.0;
   }

   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return 0.0;

   double executablePrice =
      g_perfTrade.side == "BUY"
      ? tick.bid
      : tick.ask;

   double move =
      g_perfTrade.side == "BUY"
      ? executablePrice - g_perfTrade.entry
      : g_perfTrade.entry - executablePrice;

   return
      move /
      g_perfTrade.risk;
}



struct RealAutoPositionHistory
{
 ulong position_id;
 string source;
 string basket_id;
 double in_volume;
 double out_volume;
 double net_money;
 datetime close_time;
 bool conflicted;
};

struct RealAutoBasketHistory
{
 string source;
 string basket_id;
 double net_money;
 datetime close_time;
 bool closed;
 bool conflicted;
 int leg_count;
};

struct RealAutoPerformanceTotals
{
 int closed;
 int wins;
 int losses;
 int breakeven;
 int active;
 int r1_closed;
 int r2_closed;
 int legacy_legs;
 double r1_net;
 double r2_net;
 double net;
 double gross_win;
 double gross_loss;
};

struct EngineLearning
{
 int closed,wins,losses;
 double gross_win,gross_loss,net,pf,factor;
};
EngineLearning g_learningR1,g_learningR2;
string g_learningDigest="";
void ResetEngineLearning(EngineLearning &v)
{
 v.closed=0;v.wins=0;v.losses=0;
 v.gross_win=0;v.gross_loss=0;v.net=0;v.pf=0;v.factor=1.0;
}
void LearnFromBasket(EngineLearning &v,double net)
{
 v.closed++;v.net+=net;
 if(net>0.005){v.wins++;v.gross_win+=net;}
 else if(net< -0.005){v.losses++;v.gross_loss-=net;}
}
void FinishEngineLearning(EngineLearning &v)
{
 v.pf=v.gross_loss>0.005 ? v.gross_win/v.gross_loss :
     (v.gross_win>0.005?99.0:0.0);
 v.factor=1.0;
 if(v.closed<MathMax(30,InpLearningMinClosedBaskets))return;
 if(v.pf<0.60)v.factor=0.25;
 else if(v.pf<0.85)v.factor=0.50;
}
double LearningFactor(string engine)
{
 if(!InpEnableLearningAudit||!InpEnableLearnedRiskThrottle)return 1.0;
 return engine=="R1"?g_learningR1.factor:g_learningR2.factor;
}
RealAutoPerformanceTotals g_realAutoPerf;
datetime g_realAutoPerfLastScan=0;
bool g_realAutoPerfAvailable=false;

void ResetRealAutoPerformanceTotals()
{
 g_realAutoPerf.closed=0;
 g_realAutoPerf.wins=0;
 g_realAutoPerf.losses=0;
 g_realAutoPerf.breakeven=0;
 g_realAutoPerf.active=0;
 g_realAutoPerf.r1_closed=0;
 g_realAutoPerf.r2_closed=0;
 g_realAutoPerf.legacy_legs=0;
 g_realAutoPerf.r1_net=0.0;
 g_realAutoPerf.r2_net=0.0;
 g_realAutoPerf.net=0.0;
 g_realAutoPerf.gross_win=0.0;
 g_realAutoPerf.gross_loss=0.0;
}

int FindRealAutoPosition(RealAutoPositionHistory &records[],ulong posId)
{
 for(int i=ArraySize(records)-1;i>=0;i--)
  if(records[i].position_id==posId)return i;
 return -1;
}

int FindRealAutoBasket(RealAutoBasketHistory &records[],
                       string source,string basketId)
{
 for(int i=ArraySize(records)-1;i>=0;i--)
  if(records[i].source==source&&records[i].basket_id==basketId)return i;
 return -1;
}

string BrokerRealAutoOpeningComment(ulong ticket)
{
 // The opening ORDER comment is authoritative. Broker closing comments
 // such as "[sl]" or "[tp]" are never used to classify the position.
 string comment=HistoryDealGetString(ticket,DEAL_COMMENT);
 if(AutoTradeSourceFromComment(comment)!="")return comment;

 ulong orderTicket=(ulong)HistoryDealGetInteger(ticket,DEAL_ORDER);
 if(orderTicket>0)
 {
  comment=HistoryOrderGetString(orderTicket,ORDER_COMMENT);
  if(AutoTradeSourceFromComment(comment)!="")return comment;
 }
 return "";
}

bool RealAutoOpeningMagicValid(ulong ticket)
{
 if(HistoryDealGetInteger(ticket,DEAL_MAGIC)==InpMagicNumber)
  return true;
 ulong orderTicket=(ulong)HistoryDealGetInteger(ticket,DEAL_ORDER);
 if(orderTicket==0)return false;
 return HistoryOrderGetInteger(orderTicket,ORDER_MAGIC)==InpMagicNumber;
}

bool IsRealAutoPositionStillOpen(ulong posId)
{
 for(int i=PositionsTotal()-1;i>=0;i--)
 {
  ulong ticket=PositionGetTicket(i);
  if(ticket==0||!PositionSelectByTicket(ticket))continue;
  if(PositionGetString(POSITION_SYMBOL)!=_Symbol)continue;
  if((ulong)PositionGetInteger(POSITION_IDENTIFIER)==posId)
   return true;
 }
 return false;
}

void RefreshRealAutoBrokerPerformance()
{
 datetime now=TimeCurrent();
 if(g_realAutoPerfLastScan>0&&
    now-g_realAutoPerfLastScan<
       MathMax(5,InpRealAutoPerformanceRefreshSeconds))
  return;
 g_realAutoPerfLastScan=now;
 g_realAutoPerfAvailable=false;
 ResetRealAutoPerformanceTotals();
 ResetEngineLearning(g_learningR1);
 ResetEngineLearning(g_learningR2);

 datetime begin=0;
 if(InpRealAutoPerformanceLookbackDays>0)
  begin=now-(datetime)((long)InpRealAutoPerformanceLookbackDays*86400);

 // This is broker ACTUAL history, not /results Worker events and not
 // panel simulations. Keep all selected deals loaded until both passes end.
 if(!HistorySelect(begin,now+60))
  return;

 RealAutoPositionHistory positions[];
 int dealCount=HistoryDealsTotal();

 // Pass 1: classify ONLY real R1/R2 EA entry deals, and recover basket_id.
 for(int i=0;i<dealCount;i++)
 {
  ulong ticket=HistoryDealGetTicket(i);
  if(ticket==0)continue;
  if(HistoryDealGetString(ticket,DEAL_SYMBOL)!=_Symbol)continue;

  long kind=HistoryDealGetInteger(ticket,DEAL_TYPE);
  if(kind!=DEAL_TYPE_BUY&&kind!=DEAL_TYPE_SELL)continue;
  long entryType=HistoryDealGetInteger(ticket,DEAL_ENTRY);
  if(entryType!=DEAL_ENTRY_IN&&entryType!=DEAL_ENTRY_INOUT)continue;

  string comment=BrokerRealAutoOpeningComment(ticket);
  string source=AutoTradeSourceFromComment(comment);
  if(source!="R1_AUTO"&&source!="R2_AUTO")continue;
  if(!RealAutoOpeningMagicValid(ticket))continue;

  ulong posId=(ulong)HistoryDealGetInteger(ticket,DEAL_POSITION_ID);
  if(posId==0)continue;

  string basketId=AutoTradeBasketIdFromComment(comment,source,posId);
  if(basketId=="")continue;

  int idx=FindRealAutoPosition(positions,posId);
  if(idx<0)
  {
   idx=ArraySize(positions);
   if(ArrayResize(positions,idx+1)!=idx+1)
   {
    g_realAutoPerfAvailable=false;
    return;
   }
   positions[idx].position_id=posId;
   positions[idx].source=source;
   positions[idx].basket_id=basketId;
   positions[idx].in_volume=0.0;
   positions[idx].out_volume=0.0;
   positions[idx].net_money=0.0;
   positions[idx].close_time=0;
   positions[idx].conflicted=false;
  }
  else if(positions[idx].source!=source||
          positions[idx].basket_id!=basketId)
  {
   // On a netting account, mixed strategies can share one position ID:
   // refuse to assign ambiguous P/L to an incorrect strategy.
   positions[idx].conflicted=true;
  }

  positions[idx].in_volume+=HistoryDealGetDouble(ticket,DEAL_VOLUME);
  if(entryType==DEAL_ENTRY_INOUT)
   positions[idx].conflicted=true;
 }

 // Pass 2: sum broker profit+commissions+swap+fees for ALL deals of each
 // classified position. Exit comments and exit DEAL_MAGIC may differ.
 for(int i=0;i<dealCount;i++)
 {
  ulong ticket=HistoryDealGetTicket(i);
  if(ticket==0)continue;
  if(HistoryDealGetString(ticket,DEAL_SYMBOL)!=_Symbol)continue;
  ulong posId=(ulong)HistoryDealGetInteger(ticket,DEAL_POSITION_ID);
  if(posId==0)continue;
  int idx=FindRealAutoPosition(positions,posId);
  if(idx<0)continue;

  long kind=HistoryDealGetInteger(ticket,DEAL_TYPE);
  if(kind!=DEAL_TYPE_BUY&&kind!=DEAL_TYPE_SELL)continue;
  long entryType=HistoryDealGetInteger(ticket,DEAL_ENTRY);

  // A manual or foreign-EA entry into the same NETTING position makes
  // source attribution ambiguous. Exclude that position/basket rather
  // than crediting manual profit or loss to R1/R2.
  if(entryType==DEAL_ENTRY_IN)
  {
   string entryComment=BrokerRealAutoOpeningComment(ticket);
   string entrySource=AutoTradeSourceFromComment(entryComment);
   if(entrySource!=positions[idx].source||
      !RealAutoOpeningMagicValid(ticket))
    positions[idx].conflicted=true;
  }

  if(entryType==DEAL_ENTRY_OUT||entryType==DEAL_ENTRY_OUT_BY)
  {
   positions[idx].out_volume+=HistoryDealGetDouble(ticket,DEAL_VOLUME);
   positions[idx].close_time=(datetime)MathMax((long)positions[idx].close_time,
                                            HistoryDealGetInteger(ticket,DEAL_TIME));
  }
  if(entryType==DEAL_ENTRY_INOUT)
   positions[idx].conflicted=true;

  positions[idx].net_money+=
   HistoryDealGetDouble(ticket,DEAL_PROFIT)+
   HistoryDealGetDouble(ticket,DEAL_COMMISSION)+
   HistoryDealGetDouble(ticket,DEAL_SWAP)+
   HistoryDealGetDouble(ticket,DEAL_FEE);
 }

 // One logical R1/R2 basket per explicit ID, regardless of 0.01 chunks.
 // Old pre-basket EA deals have no shared ID and therefore remain individually
 // tagged LEGACY positions. Never invent groupings from time proximity.
 RealAutoBasketHistory baskets[];
 for(int i=0;i<ArraySize(positions);i++)
 {
  int idx=FindRealAutoBasket(
   baskets,positions[i].source,positions[i].basket_id);
  if(idx<0)
  {
   idx=ArraySize(baskets);
   if(ArrayResize(baskets,idx+1)!=idx+1)
   {
    g_realAutoPerfAvailable=false;
    return;
   }
   baskets[idx].source=positions[i].source;
   baskets[idx].basket_id=positions[i].basket_id;
   baskets[idx].net_money=0.0;
   baskets[idx].close_time=0;
   baskets[idx].closed=true;
   baskets[idx].conflicted=false;
   baskets[idx].leg_count=0;
  }
  baskets[idx].net_money+=positions[i].net_money;
  baskets[idx].close_time=(datetime)MathMax((long)baskets[idx].close_time,
                                           (long)positions[i].close_time);
  baskets[idx].leg_count++;

  if(positions[i].conflicted)
   baskets[idx].conflicted=true;

  bool openByVolume=
   positions[i].out_volume+0.0000001<positions[i].in_volume;
  if(openByVolume||IsRealAutoPositionStillOpen(positions[i].position_id))
   baskets[idx].closed=false;

  if(StringFind(positions[i].basket_id,"LEGACY-")>=0)
   g_realAutoPerf.legacy_legs++;
 }

 for(int i=0;i<ArraySize(baskets);i++)
 {
  if(baskets[i].conflicted)continue;
  if(!baskets[i].closed)
  {
   g_realAutoPerf.active++;
   continue;
  }

  double net=baskets[i].net_money;
  g_realAutoPerf.closed++;
  g_realAutoPerf.net+=net;

  if(net>0.005)
  {
   g_realAutoPerf.wins++;
   g_realAutoPerf.gross_win+=net;
  }
  else if(net< -0.005)
  {
   g_realAutoPerf.losses++;
   g_realAutoPerf.gross_loss+=-net;
  }
  else g_realAutoPerf.breakeven++;

  if(InpEnableLearningAudit && baskets[i].close_time>0 &&
    (InpLearningLookbackDays<=0 ||
     baskets[i].close_time>=now-(datetime)((long)InpLearningLookbackDays*86400)))
  {
   if(baskets[i].source=="R1_AUTO")LearnFromBasket(g_learningR1,net);
   else if(baskets[i].source=="R2_AUTO")LearnFromBasket(g_learningR2,net);
  }
  if(baskets[i].source=="R1_AUTO")
  {
   g_realAutoPerf.r1_closed++;
   g_realAutoPerf.r1_net+=net;
  }
  else if(baskets[i].source=="R2_AUTO")
  {
   g_realAutoPerf.r2_closed++;
   g_realAutoPerf.r2_net+=net;
  }
 }

 FinishEngineLearning(g_learningR1);
 FinishEngineLearning(g_learningR2);
 g_realAutoPerfAvailable=true;
 if(InpEnableLearningAudit)
 {
  string digest="R1 "+IntegerToString(g_learningR1.closed)+
      " W "+IntegerToString(g_learningR1.wins)+" L "+IntegerToString(g_learningR1.losses)+
      " PF "+DoubleToString(g_learningR1.pf,2)+" riskx "+DoubleToString(g_learningR1.factor,2)+
      " | R2 "+IntegerToString(g_learningR2.closed)+
      " W "+IntegerToString(g_learningR2.wins)+" L "+IntegerToString(g_learningR2.losses)+
      " PF "+DoubleToString(g_learningR2.pf,2)+" riskx "+DoubleToString(g_learningR2.factor,2);
  if(digest!=g_learningDigest)
  {
   g_learningDigest=digest;
   AuditEvent("LEARN","RESULTS","BROKER_CLOSED_BASKETS",digest+
      " | mode="+(InpEnableLearnedRiskThrottle?"RISK_THROTTLE":"OBSERVE_ONLY"));
  }
 }
}

void DrawVirtualPerformanceRows()
{
 // Repurposed legacy function name: REAL broker results only.
 // No g_perfWins/g_perfLosses, simulated trades, or Worker paper stats.
 RefreshRealAutoBrokerPerformance();

 DrawPanelRow(14,"PERFORMANCE | REAL BROKER AUTO (ALL BUILDS)",InpPanelWaitColor);
 if(!g_realAutoPerfAvailable)
 {
  DrawPanelRow(15,"BROKER HISTORY UNAVAILABLE",InpPanelSellColor);
  DrawPanelRow(16,"No results shown until MT5 history loads",InpPanelMutedColor);
  DrawPanelRow(17,"R1 / R2 broker entries only",InpPanelMutedColor);
  return;
 }

 int c=g_realAutoPerf.closed;
 double wr=c>0?100.0*(double)g_realAutoPerf.wins/(double)c:0.0;
 string pf="-";
 if(g_realAutoPerf.gross_loss>0.005)
  pf=DoubleToString(
   g_realAutoPerf.gross_win/g_realAutoPerf.gross_loss,2);
 else if(g_realAutoPerf.gross_win>0.005)pf="INF";

 DrawPanelRow(15,
  "Closed "+IntegerToString(c)+
  " | W "+IntegerToString(g_realAutoPerf.wins)+
  " | L "+IntegerToString(g_realAutoPerf.losses)+
  " | BE "+IntegerToString(g_realAutoPerf.breakeven)+
  " | WR "+DoubleToString(wr,1)+"%",
  InpPanelTextColor);

 DrawPanelRow(16,
  "Net "+DoubleToString(g_realAutoPerf.net,2)+
  " | PF "+pf+
  " | Avg "+DoubleToString(
    c>0?g_realAutoPerf.net/(double)c:0.0,2),
  g_realAutoPerf.net>=0.0?InpPanelBuyColor:InpPanelSellColor);

 DrawPanelRow(17,
  "R1 "+IntegerToString(g_realAutoPerf.r1_closed)+
  " / "+DoubleToString(g_realAutoPerf.r1_net,2)+
  " | R2 "+IntegerToString(g_realAutoPerf.r2_closed)+
  " / "+DoubleToString(g_realAutoPerf.r2_net,2)+
  " | Active "+IntegerToString(g_realAutoPerf.active)+
  (g_realAutoPerf.legacy_legs>0
   ? " | Legacy legs "+IntegerToString(g_realAutoPerf.legacy_legs)
   : ""),
  InpPanelMutedColor);

 // LEGACY R1 positions without a common basket ID are counted separately.
 // They cannot be safely merged without a historical signal identifier.
}

// ============================================================
// INIT
// ============================================================

int OnInit()
{
   // Real accounts are permitted, but risk, news and broker guards remain.
   if(AccountInfoInteger(ACCOUNT_TRADE_MODE)==ACCOUNT_TRADE_MODE_REAL)
      Print("REAL ACCOUNT MODE | R1/R2 AUTO ENABLED SUBJECT TO TRADE GUARDS");
   if(StringFind(_Symbol, "XAUUSD") < 0)
   {
      Print(
         "This EA is intended for XAUUSD symbols only."
      );

      return INIT_FAILED;
   }

   if(InpTelemetryOnlyStagingMode &&
      (StringFind(InpWorkerBaseURL,"example.invalid")>=0 ||
       StringFind(InpWorkerBaseURL,"xau-live-bridge.r7ed2015.workers.dev")>=0))
   {
      Print("STAGING BLOCK: configure a separate Worker URL with its own D1.");
      Print("Do not use the production Worker or placeholder URL for testing.");
      return INIT_FAILED;
   }
   if(!InpTelemetryOnlyStagingMode &&
      StringFind(InpWorkerBaseURL,"example.invalid")>=0)
   {
      Print("ERROR: replace placeholder Worker URL before enabling execution.");
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
      "XAU_ICT4_ZONE_LIFECYCLE_" +
      _Symbol +
      ".txt";

   g_managerFile =
      "XAU_ACTIVE_MANAGER_" +
      _Symbol +
      ".txt";

   g_perfStateFile =
      "XAU_LIVE_PERF_" +
      _Symbol +
      ".txt";

   g_perfHistoryFile =
      "XAU_LIVE_PERF_HISTORY_" +
      _Symbol +
      ".csv";

   g_autoStateFile =
      "XAU_ICT4_AUTO_EXEC_STATE_" +
      _Symbol +
      ".txt";

   g_autoLastSignalKey = "";
   g_autoExecutionStatus = InpEnableAutoSignalExecutor ? "WAIT READY" : "OFF";
   g_r2PendingExecutionStatus = InpEnableR2PendingExecutor ? "WAIT R2 PENDING" : "OFF";
   g_r2PendingPlanKey = "";

   if(InpResetAutoExecutorStateOnInit)
   {
      if(FileIsExist(g_autoStateFile, FILE_COMMON))
         FileDelete(g_autoStateFile, FILE_COMMON);
   }
   else
   {
      LoadAutoExecutorState();
   }

   ResetVirtualPerformanceSummary();

   if(InpResetLivePerformanceOnInit)
   {
      if(
         FileIsExist(
            g_perfStateFile,
            FILE_COMMON
         )      )
      {
         FileDelete(
            g_perfStateFile,
            FILE_COMMON
         );
      }

      if(
         FileIsExist(
            g_perfHistoryFile,
            FILE_COMMON
         )
      )
      {
         FileDelete(
            g_perfHistoryFile,
            FILE_COMMON
         );
      }
   }
   else
   {
      LoadVirtualPerformanceState();
   }

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
      EvaluatePersistentZoneLifecycle();
      SyncPersistentZonesToGlobals();
   }

   EventSetTimer(1);

   Print(
      "XAU Market Zones Engine v4.0 ICT SMC ADAPTIVE started on ",
      _Symbol,
      " | EXECUTION GATED BY INPUTS/NEWS/RISK/SESSION | AUTO PROTECTION=", (InpAutoProtectPositions ? "ON" : "OFF"),
      " | MAX SL RISK GUARD=", (InpEnableMaxSLRiskGuard ? DoubleToString(InpMaxSLRiskPercent, 1) + "%" : "OFF"),
      " | AUTO EXEC=", (InpEnableAutoSignalExecutor ? DoubleToString(EffectiveAutoRiskCapPercent(), 1) + "%" : "OFF"),
      " | R2 PENDING=", (InpEnableR2PendingExecutor ? "ON" : "OFF")
   );

   if(InpNewsTierSelfTestOnInit && !NewsTierSelfTest())
   {
      Print("NEWS RISK SELFTEST FAILED: safety halt, fix classification before trading");
      return INIT_FAILED;
   }

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
   DrawUnifiedChartLegend();

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
   SaveVirtualPerformanceState();
   SaveAutoExecutorState();

   if(!InpTelemetryOnlyStagingMode && InpR2DeletePendingOnDeinit)
      DeleteR2PendingOrders("EA DEINIT - EXPLICIT");

   DeleteDecisionZoneObjects();
   DeleteR2VisualObjects();
   DeleteUnifiedChartLegend();
   DeleteCompactZonePanel();
   Comment("");
}


// ============================================================
// TIMER
// ============================================================

void OnTimer()
{
   NewsAllowsAutoEntry();
   datetime now =
      TimeCurrent();

   if(InpLockZoneIdentity)
      EvaluatePersistentZoneLifecycle();
   // Stale preview lines must disappear even when WebRequest fails.
   if(InpDrawDecisionZones && InpDrawR1WorkerWatchZones &&
      !R1WatchFeedFresh())
   {
      DeleteR1WatchReferenceObjects("BUY");
      DeleteR1WatchReferenceObjects("SELL");
   }
   if(InpDrawR2WatchZones && !R2WatchSnapshotFresh())
      DeleteR2WatchReferenceObjects();

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

   // Staging default is telemetry-only: prohibit EA-initiated broker
   // modifications, deletions, SL/TP management and auto entries.
   if(!InpTelemetryOnlyStagingMode)
   {
      AutoProtectOpenPositions();
      EnforceMaxSLRiskGuardForNewPosition();
      string managerSideSnapshot = "NONE";
      GetOpenSymbolPositionSummary(managerSideSnapshot);
      ManageActiveBasketPositions();
      ProcessICT4Executors();
   }
   // Read-only probe only AFTER management and strategy execution.
   BridgeProbeOne();
   // Virtual/paper tracker intentionally disabled: real broker stats only.

   DrawUnifiedChartLegend();
   if(InpShowZoneEngineStatus)
      DrawCompactZonePanel();
}


// ============================================================
// TICK
// ============================================================

void OnTick()
{
   CheckZoneEntryAlert();

   if(!InpTelemetryOnlyStagingMode)
   {
      ProcessICT4Executors();
   }
   // Virtual/paper tracker intentionally disabled: real broker stats only.

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

   if(StringFind(analysisId,"ICTSMC4_")==0)return 85;
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

   if(StringFind(analysisId,"ICTSMC4_")==0)
      return "ICT SMC FVG/OB structural zone";
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
   ObjectDelete(0,R1_WATCH_BUY_BAND);
   ObjectDelete(0,R1_WATCH_SELL_BAND);
   ObjectDelete(0,R1_WATCH_BUY_LOW);
   ObjectDelete(0,R1_WATCH_BUY_HIGH);
   ObjectDelete(0,R1_WATCH_SELL_LOW);
   ObjectDelete(0,R1_WATCH_SELL_HIGH);
   ObjectDelete(0,R1_WATCH_BUY_TEXT);
   ObjectDelete(0,R1_WATCH_SELL_TEXT);

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
      InpDistinctTradeLineStyles ?
         (StringFind(name,"INVALIDATION")>=0 ? STYLE_DASHDOT :
          StringFind(name,"TP")>=0 ? STYLE_DASH :
          StringFind(name,"SL")>=0 ? STYLE_DOT : lineStyle) : lineStyle
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
      "\n" // hide pop-up tooltip to avoid covering candles
   );
   // Keep chart annotations behind opaque dashboard panels.
   ObjectSetInteger(0,name,OBJPROP_BACK,true);
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
      "\n" // prevent long FVG/OB bands from covering price candles
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
         IntegerToString(g_r2Score) +         " ENTRY VALID";
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

   // A latched READY stays valid only while the CURRENT executable
   // market price is still between the stored READY SL and TP.
   MqlTick tick;

   if(SymbolInfoTick(_Symbol, tick))
   {
      double liveEntry =
         g_latchedSide == "BUY"
         ? tick.ask
         : tick.bid;

      bool levelsStillExecutable =
         g_latchedSide == "BUY"
         ? (
            g_latchedSL > 0.0 &&
            g_latchedTP > 0.0 &&
            g_latchedSL < liveEntry &&
            liveEntry < g_latchedTP
           )
         : (
            g_latchedSL > 0.0 &&
            g_latchedTP > 0.0 &&
            g_latchedTP < liveEntry &&
            liveEntry < g_latchedSL
           );

      if(!levelsStillExecutable)
      {
         g_readyBlockedConfirmBar =
            iTime(_Symbol, PERIOD_M5, 1);

         g_readyBlockedSide =
            g_latchedSide;

         Print(
            "READY AUTO-RESET | ",
            g_latchedSide,
            " | current=",
            DoubleToString(liveEntry, _Digits),
            " | SL=",
            DoubleToString(g_latchedSL, _Digits),
            " | TP=",
            DoubleToString(g_latchedTP, _Digits),
            " | reason=current price is no longer between READY SL and TP"
         );

         ClearReadyLatch();
         return false;
      }
   }

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
         g_readyBlockedConfirmBar =
            iTime(_Symbol, PERIOD_M5, 1);

         g_readyBlockedSide = "BUY";

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
         g_readyBlockedConfirmBar =
            iTime(_Symbol, PERIOD_M5, 1);

         g_readyBlockedSide = "SELL";

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
      if(!HasPositionOnSymbol())
      {
         g_readyBlockedConfirmBar =
            iTime(_Symbol, PERIOD_M5, 1);

         g_readyBlockedSide =
            g_latchedSide;

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
   g_activePlanSLGuide=0.0;
   g_activePlanTPGuide=0.0;
   if((side!="BUY" && side!="SELL") || g_activeAvgEntry<=0.0)
      return;
   double low=side=="BUY"?g_buyZoneLow:g_sellZoneLow;
   double high=side=="BUY"?g_buyZoneHigh:g_sellZoneHigh;
   string why="";
   if(!BuildR1ScalpStop(side,g_activeAvgEntry,low,high,
                        g_activePlanSLGuide,why))return;
   double risk=MathAbs(g_activeAvgEntry-g_activePlanSLGuide);
   g_activePlanTPGuide=NormalizeDouble(side=="BUY"?
      g_activeAvgEntry+risk*InpSimpleRR:
      g_activeAvgEntry-risk*InpSimpleRR,_Digits);
}

void BuildSimpleDecision(bool ignoreOpenPositions = false)
{
   // First priority: if there is an actual open trade on this symbol,
   // keep the screen in ACTIVE state. Do not fall back to WAIT just
   // because the one-candle confirmation has expired.
   string activeSide = "NONE";

   if(!ignoreOpenPositions && GetOpenSymbolPositionSummary(activeSide))
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

   // ICT v4 Worker contract owns the live dashboard READY, not classical R1.
   if(g_ictR1ModelOK)
   {
      g_simpleDecision=g_ictR1Allowed?(g_ictR1Side+" READY"):"WAIT";
      g_simpleDecisionSide=g_ictR1Side;
      g_simpleConfirmText=g_ictR1OrderType;
      g_simpleWhy="ICT/SMC | "+g_ictR1Reason;
      g_simpleEntry=g_ictR1Entry;
      g_simpleSL=g_ictR1SL;
      g_simpleTP=g_ictR1TP;
      return;
   }
   // No classical strategy fallback when the v4 Worker is missing.
   g_simpleDecision="WAIT";
   g_simpleDecisionSide="NONE";
   g_simpleConfirmText="ICT/SMC WORKER REQUIRED";
   g_simpleWhy="WAIT | ICT V4 MODEL NOT VERIFIED";
   g_simpleEntry=0.0;
   g_simpleSL=0.0;
   g_simpleTP=0.0;
   return;
   g_simpleDecision = "WAIT";
   g_simpleDecisionSide = "NONE";
   g_simpleConfirmText = "NONE";
   g_simpleWhy = "WAIT FOR PRICE AT A VALID ZONE";
   g_simpleEntry = 0.0;
   g_simpleSL = 0.0;
   g_simpleTP = 0.0;

   // Second priority: preserve a recently issued READY signal.
   // A cached READY cannot survive an expired or unverified zone.
   string r1FreshReason="";
   string r1Focus=SimpleActionSide();
   if(!R1EntryAllowedForSide(r1Focus,r1FreshReason))
   {
      g_simpleWhy=r1FreshReason;
      g_simpleConfirmText="WAIT | "+r1FreshReason;
      return;
   }
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

   if(!ValidZone(zoneLow, zoneHigh))
   {
      g_simpleWhy = "NO VALID " + side + " ZONE";
      return;
   }

   g_simpleDecisionSide = side;

   string confirmation = "NONE";   bool confirmed =
      SimpleM5Confirmation(
         side,
         confirmation
      );

   datetime currentClosedM5Bar =
      iTime(_Symbol, PERIOD_M5, 1);

   if(
      confirmed &&
      g_readyBlockedSide == side &&
      g_readyBlockedConfirmBar > 0 &&
      currentClosedM5Bar == g_readyBlockedConfirmBar
   )
   {
      confirmed = false;
      confirmation = "STALE READY BAR BLOCKED";
   }
   else if(
      g_readyBlockedConfirmBar > 0 &&
      currentClosedM5Bar != g_readyBlockedConfirmBar
   )
   {
      g_readyBlockedConfirmBar = 0;
      g_readyBlockedSide = "NONE";
   }

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

   // STRICT R1 SCALP STOP, confirmed M5 swing near zone, volatility scaled.
   // The structural invalidation stored on the zone remains reference only.
   string scalpReason="";
   if(!BuildR1ScalpStop(side,currentEntry,zoneLow,zoneHigh,
                        g_simpleSL,scalpReason))
   {
      g_simpleWhy="WAIT | "+scalpReason;
      return;
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
      if(confirmation == "STALE READY BAR BLOCKED")
      {
         g_simpleWhy =
            "WAIT | OLD READY EXPIRED | NEED NEW M5 CONFIRMATION";
      }
      else
      {
         g_simpleWhy =
            "NEED ONE M5 " +
            (buy ? "BULLISH" : "BEARISH") +
            " CONFIRMATION";
      }

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



void GetAutoPanelEngineStats(string engine,
 int &buys,int &sells,int &pending,double &openLot,double &pendingLot,
 string &pendingType,double &riskPercent,bool &riskKnown)
{
 buys=0;sells=0;pending=0;openLot=0.0;pendingLot=0.0;
 pendingType="NONE";riskPercent=0.0;riskKnown=false;
 for(int i=PositionsTotal()-1;i>=0;i--)
 {
  ulong ticket=PositionGetTicket(i);
  if(ticket==0||!PositionSelectByTicket(ticket))continue;
  if(PositionGetString(POSITION_SYMBOL)!=_Symbol)continue;
  if(PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber)continue;
  if(AutoEngineFromComment(PositionGetString(POSITION_COMMENT))!=engine)continue;
  long type=PositionGetInteger(POSITION_TYPE);
  if(type==POSITION_TYPE_BUY)buys++;
  else if(type==POSITION_TYPE_SELL)sells++;
  openLot+=PositionGetDouble(POSITION_VOLUME);
 }
 for(int i=OrdersTotal()-1;i>=0;i--)
 {
  ulong ticket=OrderGetTicket(i);if(ticket==0)continue;
  if(OrderGetString(ORDER_SYMBOL)!=_Symbol)continue;
  if(OrderGetInteger(ORDER_MAGIC)!=InpMagicNumber)continue;
  if(AutoEngineFromComment(OrderGetString(ORDER_COMMENT))!=engine)continue;
  ENUM_ORDER_TYPE type=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
  if(!IsPendingOrderType(type))continue;
  pending++;
  pendingLot+=OrderGetDouble(ORDER_VOLUME_CURRENT);
  string t="OTHER";
  if(type==ORDER_TYPE_BUY_LIMIT)t="BUY_LIMIT";
  else if(type==ORDER_TYPE_SELL_LIMIT)t="SELL_LIMIT";
  else if(type==ORDER_TYPE_BUY_STOP)t="BUY_STOP";
  else if(type==ORDER_TYPE_SELL_STOP)t="SELL_STOP";
  if(pendingType=="NONE")pendingType=t;
  else if(pendingType!=t)pendingType="MIXED";
 }
 double money=0.0;int unknown=0;
 riskKnown=CalculateAutoEnginePotentialSLRisk(
  engine,money,riskPercent,unknown);
}

int CountOtherOpenPositions()
{
 int n=0;
 for(int i=PositionsTotal()-1;i>=0;i--)
 {
  ulong ticket=PositionGetTicket(i);
  if(ticket==0||!PositionSelectByTicket(ticket))continue;
  if(PositionGetString(POSITION_SYMBOL)!=_Symbol)continue;
  if(PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber||
     AutoEngineFromComment(PositionGetString(POSITION_COMMENT))=="")
   n++;
 }
 return n;
}

void DrawAutoSourceRows()
{
 int b1=0,s1=0,p1=0,b2=0,s2=0,p2=0;
 double l1=0.0,pl1=0.0,r1=0.0,l2=0.0,pl2=0.0,r2=0.0;
 string t1="",t2="";bool k1=false,k2=false;
 GetAutoPanelEngineStats("R1",b1,s1,p1,l1,pl1,t1,r1,k1);
 GetAutoPanelEngineStats("R2",b2,s2,p2,l2,pl2,t2,r2,k2);

 DrawPanelRow(1,"[ REAL BROKER AUTO | R1 / R2 ]",InpPanelWaitColor);
 DrawPanelRow(2,
  "R1 BUY "+IntegerToString(b1)+" SELL "+IntegerToString(s1)+
  " | "+DoubleToString(l1,2)+"L | SL "+
  (k1?DoubleToString(r1,2)+"%":"UNKNOWN")+
  "/"+DoubleToString(EffectiveAutoRiskCapPercent(),1)+"%",
  InpPanelR1Color);
 DrawPanelRow(3,
  "R2 BUY "+IntegerToString(b2)+" SELL "+IntegerToString(s2)+
  " | "+DoubleToString(l2,2)+"L | SL "+
  (k2?DoubleToString(r2,2)+"%":"UNKNOWN")+
  "/"+DoubleToString(InpR2AutoMaxSLRiskPercent,1)+"%",
  InpPanelR2Color);
 DrawPanelRow(4,
  "R2 PENDING "+IntegerToString(p2)+" | "+t2+
  " | "+DoubleToString(pl2,2)+"L",
  p2>0?InpPanelR2Color:InpPanelMutedColor);
}

string PanelRowName(int row)
{
   return
      ZONE_PANEL_ROW_PREFIX +
      IntegerToString(row);
}



// ============================================================
// v3.5.30 FULL TEXT AUTO WRAP DASHBOARD (DISPLAY ONLY)
// ============================================================
// A section card contains its own heading and data rows.
// Disabled sections suppress BOTH labels and geometry; live cards reflow.
// On short charts, the panel moves up and uses tighter spacing.

// All visible dashboard lines are laid out BEFORE painting any background.
// Each text line is wrapped (never abbreviated) and stored for rendering.
#define DASH_MAX_LINES 180
string g_dashLineText[DASH_MAX_LINES];
color g_dashLineColor[DASH_MAX_LINES];
int g_dashLineFont[DASH_MAX_LINES];
int g_dashLineSection[DASH_MAX_LINES];
int g_dashLineCount=0;
int g_dashSectionRows[6];
int g_dashLineY[DASH_MAX_LINES];

void DashboardResetLines()
{
   g_dashLineCount=0;
   for(int i=0;i<6;i++)g_dashSectionRows[i]=0;
}

int DashboardSectionForRow(int row)
{
   if(row==0)return -1;
   if(row<=4)return 0;
   if(row<=9)return 1;
   if(row<=12)return 2;
   if(row<=16)return 3;
   if(row<=22)return 4;
   return 5;
}

// Estimate conservative visible character capacity for an MT5 OBJ_LABEL.
// No ellipses or trailing marker are emitted. Long words are split if needed.
int DashboardLineCapacity(int fontSize)
{
   int available=MathMax(100,DashboardPanelWidth()-49);
   int glyph=MathMax(7,(int)MathCeil((double)fontSize*0.85));
   return MathMax(9,available/glyph);
}

void DashboardAppend(string text,color c,int size,int section)
{
   // Never allocate text or row-height for any disabled section.
   // This also prevents future callers from leaking hidden-card text.
   if(section>=0 && !DashboardSectionVisible(section))return;
   if(g_dashLineCount>=DASH_MAX_LINES)return;
   int at=g_dashLineCount++;
   g_dashLineText[at]=text;
   g_dashLineColor[at]=c;
   g_dashLineFont[at]=size;
   g_dashLineSection[at]=section;
   if(section>=0&&section<6)g_dashSectionRows[section]++;
}

void DashboardCollectRow(int row,string message,color c,int fontSize=0)
{
   int section=DashboardSectionForRow(row);
   // Critical visibility gate: a hidden section must contribute ZERO text
   // and ZERO rows, not merely lose its background rectangle.
   if(section>=0 && !DashboardSectionVisible(section))return;
   int size=fontSize>0?fontSize:InpPanelFontSize;
   if(DashboardTitleRow(row))size=MathMax(size,InpPanelFontSize+1);
   int cap=DashboardLineCapacity(size);
   string remaining=message;
   // Keep complete source string, render it across as many rows as required.
   if(StringLen(remaining)==0)
   {
      DashboardAppend("",c,size,section);
      return;
   }
   while(StringLen(remaining)>0)
   {
      if(g_dashLineCount>=DASH_MAX_LINES)break;
      if(StringLen(remaining)<=cap)
      {
         DashboardAppend(remaining,c,size,section);
         break;
      }
      int cut=cap;
      for(int i=cap-1;i>=MathMax(0,cap/2);i--)
      {
         if(StringGetCharacter(remaining,i)==32)
         {cut=i;break;}
      }
      if(cut<1)cut=cap;
      DashboardAppend(StringSubstr(remaining,0,cut),c,size,section);
      remaining=StringSubstr(remaining,cut);
      StringTrimLeft(remaining);
   }
}

color g_dashHeaderColor=C'92,76,37';
void DashboardRenderFullText()
{
   // Every section height depends on the actual wrapped row count.
   DrawPanelBackground(g_dashHeaderColor);
   DrawDashboardCards();
   int top=DashboardPanelTop();
   int rh=DashboardRowHeight();
   int current=0;
   for(int i=0;i<g_dashLineCount;i++)
   {
      int section=g_dashLineSection[i];
      int y;
      if(section<0)
         y=top+8;
      else
      {
         while(current<section)current++;
         int seen=0;
         for(int j=0;j<i;j++)
            if(g_dashLineSection[j]==section)seen++;
         y=DashboardCardTop(section)+8+seen*rh;
      }
      string name="XAU_DASH_FULL_LINE_"+IntegerToString(i);
      if(ObjectFind(0,name)<0)
         ObjectCreate(0,name,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,name,OBJPROP_CORNER,InpPanelCorner);
      ObjectSetInteger(0,name,OBJPROP_XDISTANCE,InpPanelX+(section<0?16:22));
      ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
      ObjectSetInteger(0,name,OBJPROP_FONTSIZE,g_dashLineFont[i]);
      ObjectSetInteger(0,name,OBJPROP_COLOR,g_dashLineColor[i]);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
      ObjectSetInteger(0,name,OBJPROP_BACK,false);
      ObjectSetString(0,name,OBJPROP_FONT,
         (section<0 || (i>0 && (i==1 || g_dashLineSection[i]!=g_dashLineSection[i-1])))
         ?"Segoe UI Semibold":"Segoe UI");
      ObjectSetString(0,name,OBJPROP_TEXT,g_dashLineText[i]);
      ObjectSetString(0,name,OBJPROP_TOOLTIP,g_dashLineText[i]);
   }
   for(int i=g_dashLineCount;i<DASH_MAX_LINES;i++)
   {
      string old="XAU_DASH_FULL_LINE_"+IntegerToString(i);
      if(ObjectFind(0,old)>=0)ObjectDelete(0,old);
   }
}

int DashboardRowHeight()
{
   long chartHeight=ChartGetInteger(0,CHART_HEIGHT_IN_PIXELS,0);
   if(chartHeight>0 && chartHeight<690)
      return 20;
   if(chartHeight>0 && chartHeight<InpPanelY+660)
      return 20;
   return MathMax(17,InpPanelRowHeight);
}

int DashboardGap()
{
   long chartHeight=ChartGetInteger(0,CHART_HEIGHT_IN_PIXELS,0);
   if(chartHeight>0 && chartHeight<690)
      return 13;
   if(chartHeight>0 && chartHeight<InpPanelY+660)
      return 13;
   return MathMax(7,InpPanelSectionGap);
}

int DashboardPanelWidth()
{
   long width=ChartGetInteger(0,CHART_WIDTH_IN_PIXELS,0);
   if(width<=0)return MathMax(370,InpPanelWidth);
   // Allow the panel to shrink on narrower charts. Long label content
   // is shortened with a full-text hover tooltip.
   return MathMax(260,MathMin(InpPanelWidth,(int)width-InpPanelX-12));
}

bool DashboardSectionVisible(int section)
{
   if(section==2)return InpShowManagementSection;
   if(section==3)return InpShowPerformanceSection;
   if(section==5)return InpShowBridgeSection;
   return true;
}

int DashboardCardRowCount(int section)
{
   if(section<0 || section>5 || !DashboardSectionVisible(section))return 0;
   return g_dashSectionRows[section];
}

int DashboardFirstRow(int section)
{
   if(section==0)return 1;
   if(section==1)return 5;
   if(section==2)return 10;
   if(section==3)return 13;
   if(section==4)return 17;
   return 23;
}

int DashboardCalculatedHeight()
{
   int height=37+20;
   int visibleCards=0;
   for(int i=0;i<6;i++)
   {
      if(!DashboardSectionVisible(i))continue;
      height+=DashboardCardRowCount(i)*DashboardRowHeight()+14;
      visibleCards++;
   }
   height+=MathMax(0,visibleCards-1)*DashboardGap();
   return height;
}

int DashboardPanelHeight()
{
   // Size the panel from VISIBLE rows only, in every visibility mode.
   // A static minimum height used to leave a huge black empty area.
   return DashboardCalculatedHeight();
}

int DashboardPanelTop()
{
   long chartHeight=ChartGetInteger(0,CHART_HEIGHT_IN_PIXELS,0);
   int top=InpPanelY;
   if(chartHeight>0)
   {
      int lowestTop=(int)chartHeight-DashboardPanelHeight()-6;
      // Keep a modest top margin near the chart's native controls.
      top=MathMax(36,MathMin(top,lowestTop));
   }
   return top;
}

int DashboardCardTop(int section)
{
   int y=DashboardPanelTop()+37;
   for(int i=0;i<section;i++)
   {
      if(!DashboardSectionVisible(i))continue;
      y+=DashboardCardRowCount(i)*DashboardRowHeight()+
         14+DashboardGap();
   }
   return y;
}

int DashboardRowY(int row)
{
   if(row==0)return DashboardPanelTop()+8;
   for(int section=0;section<6;section++)
   {
      int first=DashboardFirstRow(section);
      int count=DashboardCardRowCount(section);
      if(row>=first && row<first+count)
         return DashboardCardTop(section)+7+
                (row-first)*DashboardRowHeight();
   }
   // Legacy non-dashboard labels, if used, cannot overlap our cards.
   return DashboardPanelTop()+37+(row-1)*DashboardRowHeight();
}

bool DashboardTitleRow(int row)
{
   return row==1 || row==5 || row==10 ||
          row==13 || row==17 || row==23;
}

string DashboardSafeText(string message,int fontSize)
{
   return message; // Never introduce ellipsis. Main panel uses wrapped labels.
}

void DeleteCompactZonePanel()
{
   ClearDashboardCards();
   for(int i=0;i<DASH_MAX_LINES;i++)
      ObjectDelete(0,"XAU_DASH_FULL_LINE_"+IntegerToString(i));
   ObjectDelete(0, ZONE_PANEL_OBJECT);
   ObjectDelete(0, ZONE_PANEL_HEADER_OBJECT);

   for(int i = 0; i < 30; i++)
      ObjectDelete(0, PanelRowName(i));

   // Remove leftover button objects created by previous EA versions.
   ObjectDelete(0, "XAU_PANEL_BUY_BUTTON");
   ObjectDelete(0, "XAU_PANEL_SELL_BUTTON");
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
   int width=DashboardPanelWidth();
   int top=DashboardPanelTop();
   DrawPanelBox(
      ZONE_PANEL_OBJECT,InpPanelX,top,
      width,DashboardPanelHeight(),
      InpPanelBgColor,InpPanelBorderColor
   );
   DrawPanelBox(
      ZONE_PANEL_HEADER_OBJECT,InpPanelX,top,
      width,32,headerColor,headerColor
   );
}

void DrawPanelRow(
   int row,
   string text,
   color textColor,
   int fontSize = 0
)
{
   string name=PanelRowName(row);
   if(ObjectFind(0,name)<0)
   {
      if(!ObjectCreate(0,name,OBJ_LABEL,0,0,0))
         return;
   }

   int actualFontSize=fontSize>0?fontSize:InpPanelFontSize;
   if(DashboardTitleRow(row))
      actualFontSize=MathMax(actualFontSize,InpPanelFontSize+1);

   ObjectSetInteger(0,name,OBJPROP_CORNER,InpPanelCorner);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,
      InpPanelX+(row==0?16:21));
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,DashboardRowY(row));
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,actualFontSize);
   ObjectSetInteger(0,name,OBJPROP_COLOR,textColor);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTED,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,name,OBJPROP_BACK,false);
   ObjectSetString(0,name,OBJPROP_FONT,
      (row==0 || DashboardTitleRow(row))
      ?"Segoe UI Semibold":"Segoe UI");
   ObjectSetString(0,name,OBJPROP_TEXT,
      DashboardSafeText(text,actualFontSize));
   // No information is lost: hover on a shortened line for full text.
   ObjectSetString(0,name,OBJPROP_TOOLTIP,text);
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



string PanelSectionTitle(string title)
{
   return "[ " + title + " ]";
}


string PanelHeaderStatusText()
{
   string suffix = "";

   string r2Text = SimpleR2Text();

   if(StringFind(r2Text, "CAUTION") >= 0)
      suffix = "  |  CAUTION";
   else if(StringFind(r2Text, "ALIGNED") >= 0)
      suffix = "  |  ALIGNED";

   return "STATUS  |  " + g_simpleDecision + suffix;
}


// ------------------------------------------------------------
// v3.5.11: Compact, broker-real dashboard.
// Dashboard styling only. Trading, news, position management,
// session hours and actual MT5 performance calculations unchanged.
// ------------------------------------------------------------
string DashboardRiskString(double risk,bool known,double limit)
{
   return (known ? DoubleToString(risk,2)+"%" : "UNKNOWN")+
          " / "+DoubleToString(limit,1)+"%";
}

void DrawDashboardCards()
{
   int x=InpPanelX+8;
   int width=DashboardPanelWidth()-16;
   color cardBg=C'18,25,34';
   color edge=C'35,48,62';
   string cards[6]={
      "XAU_DASH_CARD_LIVE",
      "XAU_DASH_CARD_SETUP",
      "XAU_DASH_CARD_MGMT",
      "XAU_DASH_CARD_PERF",
      "XAU_DASH_CARD_GUARDS",
      "XAU_DASH_CARD_BRIDGE"
   };
   string accents[6]={
      "XAU_DASH_ACC_LIVE",
      "XAU_DASH_ACC_SETUP",
      "XAU_DASH_ACC_MGMT",
      "XAU_DASH_ACC_PERF",
      "XAU_DASH_ACC_GUARDS",
      "XAU_DASH_ACC_BRIDGE"
   };
   color accentsColor[6];
   accentsColor[0]=InpPanelR1Color;
   accentsColor[1]=InpPanelWaitColor;
   accentsColor[2]=InpPanelMutedColor;
   accentsColor[3]=InpPanelR2Color;
   accentsColor[4]=InpPanelWarningColor;
   accentsColor[5]=InpPanelR2Color;

   for(int section=0;section<6;section++)
   {
      if(!DashboardSectionVisible(section))
      {
         ObjectDelete(0,cards[section]);
         ObjectDelete(0,accents[section]);
         continue;
      }
      int y=DashboardCardTop(section);
      int height=DashboardCardRowCount(section)*
                 DashboardRowHeight()+14;
      DrawPanelBox(cards[section],x,y,width,height,cardBg,edge);
      DrawPanelBox(accents[section],x+1,y+1,3,height-2,
                   accentsColor[section],accentsColor[section]);
   }
}

void ClearDashboardCards()
{
   ObjectDelete(0,"XAU_DASH_CARD_LIVE");
   ObjectDelete(0,"XAU_DASH_CARD_SETUP");
   ObjectDelete(0,"XAU_DASH_CARD_MGMT");
   ObjectDelete(0,"XAU_DASH_CARD_PERF");
   ObjectDelete(0,"XAU_DASH_CARD_GUARDS");
   ObjectDelete(0,"XAU_DASH_CARD_BRIDGE");
   ObjectDelete(0,"XAU_DASH_ACC_LIVE");
   ObjectDelete(0,"XAU_DASH_ACC_SETUP");
   ObjectDelete(0,"XAU_DASH_ACC_MGMT");
   ObjectDelete(0,"XAU_DASH_ACC_PERF");
   ObjectDelete(0,"XAU_DASH_ACC_GUARDS");
   ObjectDelete(0,"XAU_DASH_ACC_BRIDGE");
}

string DashboardZoneText(string side)
{
   if(side=="BUY" && ValidZone(g_buyZoneLow,g_buyZoneHigh))
      return "R1 ZONE  BUY  "+DoubleToString(g_buyZoneLow,_Digits)+
             " - "+DoubleToString(g_buyZoneHigh,_Digits);
   if(side=="SELL" && ValidZone(g_sellZoneLow,g_sellZoneHigh))
      return "R1 ZONE  SELL "+DoubleToString(g_sellZoneLow,_Digits)+
             " - "+DoubleToString(g_sellZoneHigh,_Digits);
   return "R1 ZONE  No valid setup";
}

string DashboardR1Trigger(string side,bool ready)
{
   if(ready)
      return "READY   Entry "+DoubleToString(g_simpleEntry,_Digits)+
             "  |  SL "+DoubleToString(g_simpleSL,_Digits);
   if(side=="BUY")return "TRIGGER   One M5 bullish close";
   if(side=="SELL")return "TRIGGER   One M5 bearish close";
   return "TRIGGER   Waiting for valid zone";
}

string DashboardR1Invalidation(string side,bool ready)
{
   if(ready)
      return "TARGET   "+DoubleToString(g_simpleTP,_Digits)+
             "  |  RR "+DoubleToString(InpSimpleRR,1)+"R";
   if(side=="BUY"&&g_buyInvalidation>0.0)
      return "ZONE INVALID   M5 close < "+DoubleToString(g_buyInvalidation,_Digits);
   if(side=="SELL"&&g_sellInvalidation>0.0)
      return "ZONE INVALID   M5 close > "+DoubleToString(g_sellInvalidation,_Digits);
   return "ZONE INVALID   Awaiting structural level";
}

void DrawCompactZonePanel()
{
   if(!InpShowCompactPanel || !InpShowZoneEngineStatus)
   {
      DeleteCompactZonePanel();
      return;
   }

   // Preserve the original combined ACTIVE status for the header/buttons;
   // real R1/R2 exposure always comes from the broker by comment+magic.
   BuildSimpleDecision();
   bool readyBuy=g_simpleDecision=="BUY READY";
   bool readySell=g_simpleDecision=="SELL READY";
   bool newsBlocked=InpEnableUSDNewsGuard && g_newsEntryBlocked;

   color headerColor=C'92,76,37';
   if(readyBuy)headerColor=C'27,106,77';
   else if(readySell)headerColor=C'130,57,63';
   else if(StringFind(g_simpleDecision,"ACTIVE")>=0)
      headerColor=C'39,78,115';
   if(newsBlocked)headerColor=C'118,74,30';

   g_dashHeaderColor=headerColor;
   DashboardResetLines();

   // Maximum row index 21; obsolete labels from previous versions clear.
   for(int i=0;i<30;i++)
   {
      string rowName=PanelRowName(i);
      if(ObjectFind(0,rowName)>=0)
         ObjectSetString(0,rowName,OBJPROP_TEXT,"");
   }

   string headline="XAU AUTO  |  "+g_simpleDecision;
   if(newsBlocked)headline+="  |  NEWS BLOCK";
   else if(StringFind(SimpleR2Text(),"CAUTION")>=0)
      headline+="  |  CAUTION";
   DashboardCollectRow(0,headline,clrWhite,InpPanelTitleFontSize);

   // -------- LIVE BROKER POSITIONS --------
   int r1B=0,r1S=0,r1P=0,r2B=0,r2S=0,r2P=0;
   double r1Lot=0,r1PLot=0,r1Risk=0;
   double r2Lot=0,r2PLot=0,r2Risk=0;
   string r1Type="",r2Type="";
   bool r1Known=false,r2Known=false;
   GetAutoPanelEngineStats("R1",r1B,r1S,r1P,r1Lot,r1PLot,
                           r1Type,r1Risk,r1Known);
   GetAutoPanelEngineStats("R2",r2B,r2S,r2P,r2Lot,r2PLot,
                           r2Type,r2Risk,r2Known);

   DashboardCollectRow(1,"LIVE AUTO  /  REAL POSITIONS",InpPanelTextColor);
   string r1State=(r1B+r1S==0)?"FLAT":
      "BUY "+IntegerToString(r1B)+"  SELL "+IntegerToString(r1S)+
      "  |  "+DoubleToString(r1Lot,2)+"L";
   string r2State=(r2B+r2S==0)?"FLAT":
      "BUY "+IntegerToString(r2B)+"  SELL "+IntegerToString(r2S)+
      "  |  "+DoubleToString(r2Lot,2)+"L";

   DashboardCollectRow(2,"R1   "+r1State+"  |  Risk "+
      DashboardRiskString(r1Risk,r1Known,EffectiveAutoRiskCapPercent()),
      InpPanelR1Color);
   DashboardCollectRow(3,"R2   "+r2State+"  |  Risk "+
      DashboardRiskString(r2Risk,r2Known,InpR2AutoMaxSLRiskPercent),
      InpPanelR2Color);

   string pending="R2 PENDING   "+IntegerToString(r2P);
   if(r2P>0)
      pending+="  |  "+r2Type+"  |  "+DoubleToString(r2PLot,2)+"L";
   DashboardCollectRow(4,pending,
      r2P>0 ? InpPanelR2Color : InpPanelMutedColor);
   // Critical execution state stays visible when diagnostic cards are hidden.
   DashboardCollectRow(4,"R1 EXEC "+g_autoExecutionStatus,
      StringFind(g_autoExecutionStatus,"BLOCK")>=0 ||
      StringFind(g_autoExecutionStatus,"SKIP")>=0 ?
      InpPanelWarningColor:InpPanelR1Color);
   DashboardCollectRow(4,"R2 EXEC "+g_r2PendingExecutionStatus,
      StringFind(g_r2PendingExecutionStatus,"BLOCK")>=0 ||
      StringFind(g_r2PendingExecutionStatus,"CANCEL")>=0 ?
      InpPanelWarningColor:InpPanelR2Color);

   // -------- R1 SETUP & R2 CONTEXT --------
   DashboardCollectRow(5,"TRADE SETUP  /  MARKET CONTEXT",InpPanelTextColor);
   string side=g_simpleDecisionSide;
   if(side!="BUY"&&side!="SELL")side=SimpleActionSide();
   if(side!="BUY"&&side!="SELL")
      side=NearestZoneSide();
   color zoneColor=(side=="BUY")?InpPanelBuyColor:
       ((side=="SELL")?InpPanelSellColor:InpPanelMutedColor);
   DashboardCollectRow(6,DashboardZoneText(side),zoneColor);

   bool ready=readyBuy||readySell;
   DashboardCollectRow(7,DashboardR1Trigger(side,ready),
      ready?InpPanelBuyColor:InpPanelTextColor);
   DashboardCollectRow(8,DashboardR1Invalidation(side,ready),
      InpPanelMutedColor);

   string r2Context=SimpleR2Text();
   if(StringFind(r2Context,"R2: ")==0)
      r2Context="R2 BIAS   "+StringSubstr(r2Context,4);
   DashboardCollectRow(9,r2Context,
      StringFind(r2Context,"CAUTION")>=0 ?
      InpPanelWarningColor : InpPanelR2Color);

   // R1 health and live worker candidate are display-only; never fake READY.
   datetime r1Now=TimeTradeServer();
   int r1FeedSeconds=(g_r1LastFreshFeedServer>0)?
      (int)MathMax(0,(double)(r1Now-g_r1LastFreshFeedServer)):-1;
   string r1FeedAge=(r1FeedSeconds<0)?"UNKNOWN":
      IntegerToString(r1FeedSeconds)+"s";
   double r1LockHours=-1;
   if(side=="BUY" && g_pBuyZone.active)
      r1LockHours=MathMax(0,(double)(r1Now-g_pBuyZone.created_at)/3600.0);
   else if(side=="SELL" && g_pSellZone.active)
      r1LockHours=MathMax(0,(double)(r1Now-g_pSellZone.created_at)/3600.0);
   string r1LockAge=r1LockHours<0?"NONE":
      DoubleToString(r1LockHours,1)+"h/"+DoubleToString(R1EffectiveZoneMaxAgeHours(),1)+"h";
   string r1Auto=(InpTelemetryOnlyStagingMode?"MONITOR":
      (InpEnableAutoSignalExecutor?"ON":"OFF"));
   if(InpShowAdvancedSetupDetails)
   {
      DashboardCollectRow(9,"R1 AUTO "+r1Auto+" | FEED "+r1FeedAge+
         " | LOCK "+r1LockAge,
         r1FeedSeconds>MathMax(10,InpR1MaxFeedAgeSeconds)?
         InpPanelWarningColor:InpPanelR1Color);
      if(ValidZone(g_r1WorkerBuyLow,g_r1WorkerBuyHigh) ||
         ValidZone(g_r1WorkerSellLow,g_r1WorkerSellHigh))
         DashboardCollectRow(9,
            (StringFind(g_zoneType,"WATCH")>=0?"R1 WATCH BUY ":"R1 FRESH BUY ")+
            DoubleToString(g_r1WorkerBuyLow,_Digits)+"-"+
            DoubleToString(g_r1WorkerBuyHigh,_Digits)+
            " SELL "+DoubleToString(g_r1WorkerSellLow,_Digits)+"-"+
            DoubleToString(g_r1WorkerSellHigh,_Digits),
            InpPanelMutedColor);
      DashboardCollectRow(9,"R1 STATUS "+g_simpleWhy,
         ready?InpPanelR1Color:InpPanelMutedColor);

      string r2VisualStatus="R2 WATCH WAIT | "+g_r2WatchSource;
      if(R2WatchSnapshotFresh())
         r2VisualStatus="R2 WATCH BUY "+
            DoubleToString(g_r2WatchBuyLow,_Digits)+"-"+
            DoubleToString(g_r2WatchBuyHigh,_Digits)+" SELL "+
            DoubleToString(g_r2WatchSellLow,_Digits)+"-"+
            DoubleToString(g_r2WatchSellHigh,_Digits);
      DashboardCollectRow(9,r2VisualStatus,
         R2WatchSnapshotFresh()?InpPanelR2Color:InpPanelMutedColor);
      DashboardCollectRow(9,"R2 STATUS "+
         (g_r2Allowed && g_r2PendingViable ?
          "PENDING CANDIDATE":"WATCH ONLY / NO ENTRY"),
         InpPanelMutedColor);
   }

   // -------- POSITION MANAGEMENT --------
   DashboardCollectRow(10,"POSITION MANAGEMENT",InpPanelTextColor);
   string managerLabel=InpEnableActiveTradeManager?"ON":"OFF";
   if(InpEnableActiveTradeManager && g_managerStatus!="" &&
      g_managerStatus!="OFF" && g_managerStatus!="WAIT")
      managerLabel=g_managerStatus;
   DashboardCollectRow(11,
      "PROTECT "+(InpAutoProtectPositions?"ON":"OFF")+
      "   |   MANAGER "+managerLabel,
      (InpAutoProtectPositions && InpEnableActiveTradeManager)
      ? InpPanelR1Color:InpPanelWarningColor);
   string mgmt="TP1 "+DoubleToString(InpManagerPartialAtR,1)+"R"+
      "   |   BE "+DoubleToString(InpManagerBEAtR,1)+"R"+
      "   |   TRAIL "+DoubleToString(InpManagerTrailStartR,1)+"R";
   if(!InpEnableActiveTradeManager)mgmt="Manager disabled";
   DashboardCollectRow(12,mgmt,InpPanelMutedColor);

   // -------- BROKER-REAL PERFORMANCE --------
   RefreshRealAutoBrokerPerformance();
   if(InpShowPerformanceSection)
   {
   DashboardCollectRow(13,"PERFORMANCE  /  REAL BROKER AUTO",InpPanelTextColor);
   if(g_realAutoPerfAvailable)
   {
      int closed=g_realAutoPerf.closed;
      double wr=closed>0?100.0*g_realAutoPerf.wins/(double)closed:0.0;
      string pf="N/A";
      if(g_realAutoPerf.gross_loss>0.005)
         pf=DoubleToString(g_realAutoPerf.gross_win/
                           g_realAutoPerf.gross_loss,2);
      else if(g_realAutoPerf.gross_win>0.005)pf="INF";

      DashboardCollectRow(14,"CLOSED "+IntegerToString(closed)+
         "   W "+IntegerToString(g_realAutoPerf.wins)+
         "   L "+IntegerToString(g_realAutoPerf.losses)+
         "   BE "+IntegerToString(g_realAutoPerf.breakeven)+
         "   WR "+DoubleToString(wr,1)+"%",InpPanelTextColor);
      if(g_realAutoPerf.legacy_legs>0)
         DashboardCollectRow(14,"LEGACY   "+IntegerToString(g_realAutoPerf.legacy_legs)+" ungrouped real positions",InpPanelMutedColor);
      DashboardCollectRow(15,"NET "+DoubleToString(g_realAutoPerf.net,2)+
         " USD   |   PF "+pf+
         "   |   AVG "+DoubleToString(
            closed>0?g_realAutoPerf.net/(double)closed:0.0,2)+" USD",
            g_realAutoPerf.net>=0.0?
            InpPanelR1Color:InpPanelSellColor);
      DashboardCollectRow(16,"R1 "+IntegerToString(g_realAutoPerf.r1_closed)+
         " / "+DoubleToString(g_realAutoPerf.r1_net,2)+
         "    |    R2 "+IntegerToString(g_realAutoPerf.r2_closed)+
         " / "+DoubleToString(g_realAutoPerf.r2_net,2),
         InpPanelMutedColor);
   }
   else
   {
      DashboardCollectRow(14,"Waiting for broker history",InpPanelWarningColor);
      DashboardCollectRow(15,"Only real R1/R2 closed baskets are counted",
         InpPanelMutedColor);
   }
   }

   // -------- OPERATING SAFETY --------
   int secondsLeft=0;
   bool session=AutoEntrySessionOpen(secondsLeft);
   string newsLabel="OFF";
   if(InpEnableUSDNewsGuard)
      newsLabel=newsBlocked?"BLOCKED":"CLEAR";

   DashboardCollectRow(17,"SESSION  /  SAFETY GUARDS",InpPanelTextColor);
   DashboardCollectRow(18,AutoEntryWindowLabel()+"  "+
      (session?"OPEN":"CLOSED")+"   |   NEWS "+newsLabel,
      (session && !newsBlocked)?InpPanelR1Color:InpPanelWarningColor);

   if(InpShowAdvancedSafetyDetails)
   {
      string newsReason=g_newsStatus;
      DashboardCollectRow(19,newsReason,
         newsBlocked?InpPanelWarningColor:
          (StringFind(newsReason,"CAUTION")>=0?
           InpPanelWarningColor:InpPanelMutedColor));

      // Long economic-event titles get their own line; no clipping at the edge.
      string nextTime="NEXT USD (SERVER)   None scheduled";
      string eventName="EVENT   No upcoming USD release";
      if(InpEnableUSDNewsGuard && !g_newsFeedHealthy)
      {
         nextTime="NEXT USD   CALENDAR UNAVAILABLE";
         eventName="EVENT   Check MT5 economic calendar";
      }
      else if(g_newsNextTime>0)
      {
         nextTime="NEXT USD (SERVER)   "+
            TimeToString(g_newsNextTime,TIME_DATE|TIME_MINUTES);
         eventName="EVENT "+g_newsNextRisk+"   "+g_newsNextName;
      }
      DashboardCollectRow(20,nextTime,InpPanelMutedColor);
      DashboardCollectRow(21,eventName,InpPanelMutedColor);
   }

   double totalRiskMoney=0.0,totalPct=0.0;
   int unknown=0;
   bool known=CalculateCurrentXAUPotentialSLRisk(
      totalRiskMoney,totalPct,unknown);
   double totalLimit=EffectiveTotalXAUAutoRiskCapPercent();

   string riskLine="TOTAL SL RISK  "+
      (known?DoubleToString(totalPct,2)+"%":"UNKNOWN")+
      " / "+DoubleToString(totalLimit,1)+"%";
   int otherCount=CountOtherOpenPositions();
   if(otherCount>0)
      riskLine+="   |   OTHER "+IntegerToString(otherCount);
   DashboardCollectRow(22,riskLine,
      known?InpPanelMutedColor:InpPanelWarningColor);

   // -------- INTEGRATED BRIDGE MONITOR --------
   string bridgeState=BridgeOverall();
   color bridgeColor=StringFind(bridgeState,"OK")==0 ? InpPanelR1Color :
      (bridgeState=="OFF" ? InpPanelMutedColor:InpPanelWarningColor);
   DashboardCollectRow(23,"BRIDGE   /   "+bridgeState,bridgeColor);
   DashboardCollectRow(24,BridgeStatusUplink(),InpPanelMutedColor);
   string resultsInfo=BridgeRecent(g_bridgeLastResultsOK,
      MathMax(240,InpBridgeProbeEverySeconds*12))
      ? "OK":"WAIT";
   string cloudAge=g_bridgeCloudAge>=0.0 ?
      DoubleToString(g_bridgeCloudAge,1)+"s":"unknown";
   DashboardCollectRow(25,"WORKER CLOUD   "+cloudAge+
      "   |   RESULTS "+resultsInfo,InpPanelMutedColor);
   DashboardCollectRow(26,BridgeStatusDownlink(),InpPanelR2Color);
   DashboardCollectRow(26,"V4 MODEL   R1 "+(g_ictR1ModelOK?"OK":"WAIT")+
      " | R2 "+(g_ictR2ModelOK?"OK":"WAIT"),
      (g_ictR1ModelOK&&g_ictR2ModelOK)?InpPanelR1Color:InpPanelWarningColor);

   DashboardRenderFullText();

   // Never recreate removed trading buttons after a version upgrade.
   ObjectDelete(0, "XAU_PANEL_BUY_BUTTON");
   ObjectDelete(0, "XAU_PANEL_SELL_BUTTON");
   ChartRedraw(0);
}

// --------------------------------------------------------------
// R1 worker WATCH: display-only chart references.
// These prices NEVER populate g_buyZoneLow/g_sellZoneLow, and never
// bypass R1EntryAllowedForSide() or the M5 / risk / news guards.
// --------------------------------------------------------------
void DeleteR1WatchReferenceObjects(string side)
{
   bool buy=side=="BUY";
   ObjectDelete(0,buy?R1_WATCH_BUY_BAND:R1_WATCH_SELL_BAND);
   ObjectDelete(0,buy?R1_WATCH_BUY_LOW:R1_WATCH_SELL_LOW);
   ObjectDelete(0,buy?R1_WATCH_BUY_HIGH:R1_WATCH_SELL_HIGH);
   ObjectDelete(0,buy?R1_WATCH_BUY_TEXT:R1_WATCH_SELL_TEXT);
}
bool R1WatchFeedFresh()
{
   datetime now=TimeTradeServer();
   return g_r1LastFreshFeedServer>0 &&
      now>=g_r1LastFreshFeedServer-5 &&
      now-g_r1LastFreshFeedServer<=MathMax(10,InpR1MaxFeedAgeSeconds);
}
// ============================================================
// V4.2 UNIFIED CHART LEGEND (VISUAL ONLY, NO EXECUTION CHANGES)
// Object existence controls rows so expired zones disappear immediately.
// Colors are read from the actual graphical objects, not assumed defaults.
// ============================================================
void DeleteUnifiedChartLegend()
{
   ObjectDelete(0,ZONE_LEGEND_BG_OBJECT);
   for(int i=0;i<ZONE_LEGEND_MAX_ROWS;i++)
      ObjectDelete(0,ZONE_LEGEND_ROW_PREFIX+IntegerToString(i));
}

void AppendLegendRow(string &descriptions[],color &tones[],
                     string caption,color lineTint)
{
   int n=ArraySize(descriptions);
   if(n>=ZONE_LEGEND_MAX_ROWS)return;
   ArrayResize(descriptions,n+1);
   ArrayResize(tones,n+1);
   descriptions[n]=caption;
   tones[n]=lineTint;
}

void AppendVisibleLegendObject(string &descriptions[],color &tones[],
                               string objName,string caption)
{
   if(ObjectFind(0,objName)<0)return;
   color tint=(color)ObjectGetInteger(0,objName,OBJPROP_COLOR);
   AppendLegendRow(descriptions,tones,caption,tint);
}

void DrawUnifiedChartLegend()
{
   // Purge price-anchored labels from any earlier EA deployment on this chart.
   ObjectDelete(0,R1_WATCH_BUY_TEXT);
   ObjectDelete(0,R1_WATCH_SELL_TEXT);
   ObjectDelete(0,R2_WATCH_BUY_LABEL);
   ObjectDelete(0,R2_WATCH_SELL_LABEL);
   ObjectDelete(0,R2_INFO_OBJECT);

   if(!InpShowUnifiedChartLegend)
   {
      DeleteUnifiedChartLegend();
      return;
   }

   string rows[];
   color tones[];
   if(InpDrawR2Setup && g_r2MarketState!="")
      AppendLegendRow(rows,tones,"R2 STATUS  |  "+g_r2MarketState,InpR2InfoColor);
   // WATCH outlines, distinct from order entry signals.
   AppendVisibleLegendObject(rows,tones,R1_WATCH_BUY_BAND,
      "R1 WATCH BUY  |  NO ENTRY");
   AppendVisibleLegendObject(rows,tones,R1_WATCH_SELL_BAND,
      "R1 WATCH SELL  |  NO ENTRY");
   AppendVisibleLegendObject(rows,tones,R2_WATCH_BUY_BAND,
      "R2 BUY  |  FVG/OB WATCH ONLY");
   // R2 SELL label matches the actual R2 WATCH SELL band and optional dotted lines.
   if(ObjectFind(0,R2_WATCH_SELL_BAND)>=0)
      AppendLegendRow(rows,tones,"R2 SELL  |  FVG/OB WATCH ONLY",InpR2WatchSellColor);
   // Live locked zones and structural context.
   AppendVisibleLegendObject(rows,tones,ZONE_BUY_OBJECT,
      "R1 LOCKED BUY ZONE");
   AppendVisibleLegendObject(rows,tones,ZONE_SELL_OBJECT,
      "R1 LOCKED SELL ZONE");
   AppendVisibleLegendObject(rows,tones,R1_BUY_LOW_LINE,
      "R1 BUY ZONE LOW");
   AppendVisibleLegendObject(rows,tones,R1_BUY_HIGH_LINE,
      "R1 BUY ZONE HIGH");
   AppendVisibleLegendObject(rows,tones,R1_SELL_LOW_LINE,
      "R1 SELL ZONE LOW");
   AppendVisibleLegendObject(rows,tones,R1_SELL_HIGH_LINE,
      "R1 SELL ZONE HIGH");
   AppendVisibleLegendObject(rows,tones,R1_BUY_INVALIDATION_LINE,
      "R1 BUY STRUCTURAL INVALIDATION");
   AppendVisibleLegendObject(rows,tones,R1_SELL_INVALIDATION_LINE,
      "R1 SELL STRUCTURAL INVALIDATION");
   AppendVisibleLegendObject(rows,tones,R1_ARMED_TRIGGER_LINE,
      "R1 ARMED TRIGGER  |  "+g_r1ArmedState);
   AppendVisibleLegendObject(rows,tones,R1_ARMED_SL_LINE,
      "R1 SCALP STOP LOSS");
   AppendVisibleLegendObject(rows,tones,R1_ARMED_TP_LINE,
      "R1 SCALP TAKE PROFIT");
   // R2 pending order plan levels. Never reinterpret/watch as executable.
   AppendVisibleLegendObject(rows,tones,R2_ZONE_OBJECT,
      "R2 ACTIVE SETUP ZONE");
   AppendVisibleLegendObject(rows,tones,R2_ENTRY_OBJECT,
      "R2 "+g_r2OrderType+" ENTRY  |  "+DoubleToString(g_r2Entry,_Digits));
   AppendVisibleLegendObject(rows,tones,R2_SL_OBJECT,
      "R2 STOP LOSS  |  "+DoubleToString(g_r2SL,_Digits));
   AppendVisibleLegendObject(rows,tones,R2_TP1_OBJECT,
      "R2 TP1  |  "+DoubleToString(g_r2TP1,_Digits));
   AppendVisibleLegendObject(rows,tones,R2_TP2_OBJECT,
      "R2 TP2  |  "+DoubleToString(g_r2TP2,_Digits));
   AppendVisibleLegendObject(rows,tones,R2_BREAKOUT_OBJECT,
      "R2 BREAKOUT LEVEL");
   AppendVisibleLegendObject(rows,tones,R2_INVALIDATION_OBJECT,
      "R2 STRUCTURAL INVALIDATION");

   int count=ArraySize(rows);
   if(count==0)
   {
      DeleteUnifiedChartLegend();
      return;
   }
   int right=MathMax(8,InpLegendRightMargin);
   int top=MathMax(14,InpLegendTopMargin);
   int step=MathMax(15,InpLegendRowHeight);
   int width=MathMax(300,InpLegendWidth);
   int height=12+count*step;
   if(ObjectFind(0,ZONE_LEGEND_BG_OBJECT)>=0 &&
      (ENUM_OBJECT)ObjectGetInteger(0,ZONE_LEGEND_BG_OBJECT,OBJPROP_TYPE)!=OBJ_RECTANGLE_LABEL)
      ObjectDelete(0,ZONE_LEGEND_BG_OBJECT);
   if(ObjectFind(0,ZONE_LEGEND_BG_OBJECT)<0)
      ObjectCreate(0,ZONE_LEGEND_BG_OBJECT,OBJ_RECTANGLE_LABEL,0,0,0);
   if(ObjectFind(0,ZONE_LEGEND_BG_OBJECT)>=0)
   {
      ObjectSetInteger(0,ZONE_LEGEND_BG_OBJECT,OBJPROP_CORNER,CORNER_RIGHT_UPPER);
      ObjectSetInteger(0,ZONE_LEGEND_BG_OBJECT,OBJPROP_XDISTANCE,right-8);
      ObjectSetInteger(0,ZONE_LEGEND_BG_OBJECT,OBJPROP_YDISTANCE,top-4);
      ObjectSetInteger(0,ZONE_LEGEND_BG_OBJECT,OBJPROP_XSIZE,width);
      ObjectSetInteger(0,ZONE_LEGEND_BG_OBJECT,OBJPROP_YSIZE,height);
      ObjectSetInteger(0,ZONE_LEGEND_BG_OBJECT,OBJPROP_BGCOLOR,InpLegendBackground);
      ObjectSetInteger(0,ZONE_LEGEND_BG_OBJECT,OBJPROP_COLOR,InpLegendBorder);
      ObjectSetInteger(0,ZONE_LEGEND_BG_OBJECT,OBJPROP_BORDER_TYPE,BORDER_FLAT);
      ObjectSetInteger(0,ZONE_LEGEND_BG_OBJECT,OBJPROP_BACK,false);
      ObjectSetInteger(0,ZONE_LEGEND_BG_OBJECT,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,ZONE_LEGEND_BG_OBJECT,OBJPROP_HIDDEN,true);
      ObjectSetString(0,ZONE_LEGEND_BG_OBJECT,OBJPROP_TOOLTIP,"\n");
   }
   for(int i=0;i<ZONE_LEGEND_MAX_ROWS;i++)
   {
      string name=ZONE_LEGEND_ROW_PREFIX+IntegerToString(i);
      if(i>=count){ObjectDelete(0,name);continue;}
      if(ObjectFind(0,name)>=0 &&
         (ENUM_OBJECT)ObjectGetInteger(0,name,OBJPROP_TYPE)!=OBJ_LABEL)
         ObjectDelete(0,name);
      if(ObjectFind(0,name)<0)ObjectCreate(0,name,OBJ_LABEL,0,0,0);
      if(ObjectFind(0,name)<0)continue;
      ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_RIGHT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_ANCHOR,ANCHOR_RIGHT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_XDISTANCE,right+5);
      ObjectSetInteger(0,name,OBJPROP_YDISTANCE,top+4+i*step);
      ObjectSetInteger(0,name,OBJPROP_FONTSIZE,MathMax(8,InpLegendFontSize));
      ObjectSetInteger(0,name,OBJPROP_COLOR,tones[i]);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_SELECTED,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
      ObjectSetInteger(0,name,OBJPROP_BACK,false);
      ObjectSetString(0,name,OBJPROP_FONT,"Consolas");
      ObjectSetString(0,name,OBJPROP_TEXT,rows[i]);
      ObjectSetString(0,name,OBJPROP_TOOLTIP,"\n");
   }
   ChartRedraw(0);
}

void DrawR1WatchReferenceSide(string side,double low,double high,
                              color watchColor)
{
   if(!ValidZone(low,high))
   {
      DeleteR1WatchReferenceObjects(side);
      return;
   }
   bool buy=side=="BUY";
   string band=buy?R1_WATCH_BUY_BAND:R1_WATCH_SELL_BAND;
   string lowLine=buy?R1_WATCH_BUY_LOW:R1_WATCH_SELL_LOW;
   string highLine=buy?R1_WATCH_BUY_HIGH:R1_WATCH_SELL_HIGH;
   string label=buy?R1_WATCH_BUY_TEXT:R1_WATCH_SELL_TEXT;
   string details="R1 WORKER WATCH "+side+" | VISUAL ONLY - NO ENTRY";
   // Unlike the tradeable zone, leave this rectangle UNFILLED.
   DrawDecisionZoneBand(band,low,high,watchColor,details);
   if(ObjectFind(0,band)>=0)
   {
      ObjectSetInteger(0,band,OBJPROP_FILL,false);
      ObjectSetInteger(0,band,OBJPROP_STYLE,STYLE_DASH);
      ObjectSetInteger(0,band,OBJPROP_WIDTH,1);
      ObjectSetInteger(0,band,OBJPROP_BACK,true);
      ObjectSetInteger(0,band,OBJPROP_SELECTABLE,false);
   }
   if(InpMinimalWatchDrawings)
   { ObjectDelete(0,lowLine); ObjectDelete(0,highLine); }
   else
   {
      DrawR1HLine(lowLine,low,watchColor,STYLE_DOT,1,details);
      DrawR1HLine(highLine,high,watchColor,STYLE_DOT,1,details);
   }
   // V4.2: never attach a caption to the price band or a candle.
   // A unified, color-matched OBJ_LABEL legend is drawn at chart top-right.
   ObjectDelete(0,label);
}
void DrawR1WatchReferenceZones()
{
   if(!InpDrawDecisionZones || !InpDrawR1WorkerWatchZones ||
      !R1WatchFeedFresh())
   {
      DeleteR1WatchReferenceObjects("BUY");
      DeleteR1WatchReferenceObjects("SELL");
      return;
   }
   // Do not duplicate an existing tradable LOCK at the same price.
   bool sameBuy=g_pBuyZone.active &&
      MathAbs(g_r1WorkerBuyLow-g_buyZoneLow)<=_Point &&
      MathAbs(g_r1WorkerBuyHigh-g_buyZoneHigh)<=_Point;
   bool sameSell=g_pSellZone.active &&
      MathAbs(g_r1WorkerSellLow-g_sellZoneLow)<=_Point &&
      MathAbs(g_r1WorkerSellHigh-g_sellZoneHigh)<=_Point;
   if(sameBuy)DeleteR1WatchReferenceObjects("BUY");
   else DrawR1WatchReferenceSide("BUY",g_r1WorkerBuyLow,
                                g_r1WorkerBuyHigh,InpR1WatchBuyColor);
   if(sameSell)DeleteR1WatchReferenceObjects("SELL");
   else DrawR1WatchReferenceSide("SELL",g_r1WorkerSellLow,
                                g_r1WorkerSellHigh,InpR1WatchSellColor);
}

void RefreshDecisionZoneObjects()
{
   if(!InpDrawDecisionZones)
   {
      DeleteDecisionZoneObjects();
      return;
   }

   // The candidate preview is independent of the tradable locked zone.
   DrawR1WatchReferenceZones();

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

   g_ictR1ModelOK=false;
   g_ictR1Allowed=false;
   string response = "";

   int status =
      HttpGet(
         url,
         response
      );

   BridgeObserve("R1",BridgeIsOK(status,response),status);
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

   if(StringFind(response,"\"strategy_model\":\"ICT_SMC_V4_LIVE\"")<0)
   {
      g_r1LastFreshFeedServer=0;
      g_r1LastFeedState="ICT_SMC_V4_WORKER_REQUIRED";
      ClearDecisionZoneState();
      return;
   }
   g_ictR1ModelOK=true;
   g_ictR1Allowed=StringFind(response,"\"r1_allowed\":true")>=0;
   g_ictR1OrderType=JsonGetString(response,"r1_order_type");
   g_ictR1Side=JsonGetString(response,"r1_side");
   g_ictR1SetupKey=JsonGetString(response,"r1_setup_key");
   g_ictR1Reason=JsonGetString(response,"r1_reason");
   g_ictR1Entry=JsonGetDouble(response,"r1_entry");
   g_ictR1SL=JsonGetDouble(response,"r1_sl");
   g_ictR1TP=JsonGetDouble(response,"r1_tp");
   bool hasAge=StringFind(response,"\"market_age_seconds\":")>=0;
   double feedAge=hasAge?JsonGetDouble(response,"market_age_seconds"):-1.0;
   if(!hasAge || feedAge<0.0 ||
      feedAge>(double)MathMax(10,InpR1MaxFeedAgeSeconds))
   {
      g_r1LastFreshFeedServer=0;
      g_r1LastFeedState="STALE_MARKET_FEED";
      AuditState("R1","FEED","STALE_OR_MISSING_AGE");
      EvaluatePersistentZoneLifecycle();
      return;
   }
   if(
      StringFind(
         response,
         "\"zones\":null"
      ) >= 0
   )
   {
      g_r1LastFreshFeedServer=0;
      g_r1LastFeedState="WORKER_NO_ZONES";
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

   // Incoming candidate is shown separately from locked decision zone.
   g_r1LastFreshFeedServer=TimeTradeServer();
   g_r1LastFeedState="FRESH";
   g_r1WorkerBuyLow=buyLow;
   g_r1WorkerBuyHigh=buyHigh;
   g_r1WorkerSellLow=sellLow;
   g_r1WorkerSellHigh=sellHigh;

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
      if(R1ZoneShouldRotate(g_pBuyZone,buyLow,buyHigh,zoneType))
         InvalidatePersistentZone(g_pBuyZone,"ROTATE_FRESH_WORKER");
      if(R1ZoneShouldRotate(g_pSellZone,sellLow,sellHigh,zoneType))
         InvalidatePersistentZone(g_pSellZone,"ROTATE_FRESH_WORKER");

      bool approvedR1Context=(zoneType!="" &&
         StringFind(zoneType,"WATCH")<0 &&
         StringFind(analysisId,"WATCH_")!=0);
      if(!g_pBuyZone.active && approvedR1Context &&
         ValidZone(buyLow, buyHigh))
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

      if(!g_pSellZone.active && approvedR1Context &&
         ValidZone(sellLow, sellHigh))
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

   // Log state CHANGES only; healthy 5s polling does not need
   // 1000s of duplicate lines in Experts. Dashboard still updates each tick.
   static string lastZonePrinted="";
   string thisZonePrinted=g_zoneAnalysisId+"|"+
      DoubleToString(g_buyZoneLow,_Digits)+"|"+
      DoubleToString(g_sellZoneLow,_Digits)+"|"+
      DoubleToString(g_r1WorkerBuyLow,_Digits)+"|"+
      DoubleToString(g_r1WorkerSellLow,_Digits);
   if(thisZonePrinted!=lastZonePrinted)
   {
   lastZonePrinted=thisZonePrinted;
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


void DeleteR2WatchReferenceObjects()
{
   DeleteR2Object(R2_WATCH_BUY_BAND);
   DeleteR2Object(R2_WATCH_SELL_BAND);
   DeleteR2Object(R2_WATCH_BUY_LOW);
   DeleteR2Object(R2_WATCH_BUY_HIGH);
   DeleteR2Object(R2_WATCH_SELL_LOW);
   DeleteR2Object(R2_WATCH_SELL_HIGH);
   DeleteR2Object(R2_WATCH_BUY_LABEL);
   DeleteR2Object(R2_WATCH_SELL_LABEL);
}
void DeleteR2VisualObjects()
{
   DeleteR2TradeObjects();
   DeleteR2WatchReferenceObjects();
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
   g_r2PendingProtocolOK = false;
   g_r2PendingViable = false;
   g_r2PendingOnlyReason = "WAIT_FOR_WORKER_R2";
   g_r2LastFreshPollServer = 0;
   g_r2WatchBuyLow=0.0;
   g_r2WatchBuyHigh=0.0;
   g_r2WatchSellLow=0.0;
   g_r2WatchSellHigh=0.0;
   g_r2WatchAvailable=false;
   g_r2WatchSource="WAIT_FOR_WORKER_V2_6";
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
      InpDistinctTradeLineStyles ?
         (StringFind(name,"INVALIDATION")>=0 ? STYLE_DASHDOT :
          StringFind(name,"TP")>=0 ? STYLE_DASH :
          StringFind(name,"SL")>=0 ? STYLE_DOT : lineStyle) : lineStyle
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
      "\n" // hide pop-up tooltip to avoid covering candles
   );
   // Keep chart annotations behind opaque dashboard panels.
   ObjectSetInteger(0,name,OBJPROP_BACK,true);
}


void DrawR2Info(string text,color textColor)
{
   // Full setup data remain available in the main dashboard and MT5 logs.
   // Do not draw a second free-floating, multiline caption over the chart.
   DeleteR2Object(R2_INFO_OBJECT);
}

// These R2 swing WATCH levels are VISUAL ONLY, not executable entry zones.
bool R2WatchSnapshotFresh()
{
   datetime now=TimeTradeServer();
   return g_r2WatchAvailable && g_r2LastFreshPollServer>0 &&
     now>=g_r2LastFreshPollServer-5 &&
     now-g_r2LastFreshPollServer<=MathMax(10,InpBridgeMaxMarketAgeSeconds);
}
void DrawR2WatchReferenceSide(string side,double low,double high,color tint)
{
   bool buy=side=="BUY";
   string band=buy?R2_WATCH_BUY_BAND:R2_WATCH_SELL_BAND;
   string lowName=buy?R2_WATCH_BUY_LOW:R2_WATCH_SELL_LOW;
   string highName=buy?R2_WATCH_BUY_HIGH:R2_WATCH_SELL_HIGH;
   string label=buy?R2_WATCH_BUY_LABEL:R2_WATCH_SELL_LABEL;
   if(!ValidZone(low,high))
   {
      DeleteR2Object(band);
      DeleteR2Object(lowName);
      DeleteR2Object(highName);
      DeleteR2Object(label);
      return;
   }
   string tip="R2 ICT/SMC "+side+" | M15 FVG/OB | WATCH ONLY";
   DrawDecisionZoneBand(band,low,high,tint,tip);
   if(ObjectFind(0,band)>=0)
   {
      ObjectSetInteger(0,band,OBJPROP_FILL,false);
      ObjectSetInteger(0,band,OBJPROP_STYLE,STYLE_DASH);
      ObjectSetInteger(0,band,OBJPROP_WIDTH,1);
      ObjectSetInteger(0,band,OBJPROP_SELECTABLE,false);
   }
   if(InpMinimalWatchDrawings)
   { DeleteR2Object(lowName); DeleteR2Object(highName); }
   else
   {
      DrawR2HLine(lowName,low,tint,STYLE_DOT,1,tip);
      DrawR2HLine(highName,high,tint,STYLE_DOT,1,tip);
   }
   // V4.2: one top-right legend owns ALL chart label rows.
   DeleteR2Object(label);
}
void DrawR2WatchReferenceZones()
{
   // Remove orphaned OBJ_TEXT labels from earlier builds once per attach.
   // The current ICT/SMC labels are OBJ_LABEL with fixed screen positions.
   static bool legacyWatchCleaned=false;
   if(!legacyWatchCleaned)
   {
      legacyWatchCleaned=true;
      int cleaned=0;
      for(int i=ObjectsTotal(0,0,-1)-1;i>=0;i--)
      {
         string name=ObjectName(0,i,0,-1);
         if(name=="")continue;
         if((ENUM_OBJECT)ObjectGetInteger(0,name,OBJPROP_TYPE)!=OBJ_TEXT)continue;
         string oldText=ObjectGetString(0,name,OBJPROP_TEXT);
         if(StringFind(oldText,"R2 WATCH BUY - NO ENTRY")>=0 ||
            StringFind(oldText,"R2 WATCH SELL - NO ENTRY")>=0)
         {
            if(ObjectDelete(0,name))cleaned++;
         }
      }
      if(cleaned>0)Print("ICT/SMC CHART CLEANUP | removed old overlapping R2 WATCH labels=",cleaned);
   }
   if(!InpDrawR2Setup || !InpDrawR2WatchZones ||
      !R2WatchSnapshotFresh())
   {
      DeleteR2WatchReferenceObjects();
      return;
   }
   DrawR2WatchReferenceSide("BUY",g_r2WatchBuyLow,
      g_r2WatchBuyHigh,InpR2WatchBuyColor);
   DrawR2WatchReferenceSide("SELL",g_r2WatchSellLow,
      g_r2WatchSellHigh,InpR2WatchSellColor);
}

void RefreshR2VisualObjects()
{
   // Always draw fresh swing WATCH previews when enabled.
   DrawR2WatchReferenceZones();
   DeleteR2TradeObjects();

   // Explicit R2 level display overrides general clean-chart mode.
   if(!InpShowR2TradeLevels)
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
            _Digits         )
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

   g_ictR2ModelOK=false;
   string response = "";

   int status =
      HttpGet(
         url,
         response
      );

   if(!BridgeIsOK(status,response))
   {
      BridgeObserve("R2",false,status);
      Print("R2 poll failed or malformed response. HTTP=",status);
      return;
   }

   // Adaptive v4 requires a new Worker; old pending-only routes fail closed.
   int modeAt=StringFind(response,"\"pending_only_mode\":true");
   int marketAt=StringFind(response,"\"market\":{");
   bool verified=StringFind(response,"\"strategy_model\":\"ICT_SMC_V4_LIVE\"")>=0;
   if(!verified || modeAt<0 || (marketAt>=0 && modeAt>marketAt))
   {
      ResetR2VisualState();
      BridgeObserve("R2",false,status);
      AuditState("R2","PROTOCOL","ICT_V4_R2_PENDING_ONLY_WORKER_REQUIRED");
      return;
   }
   // A successful HTTP response does not imply fresh price/candle data.
   double cloudAge=JsonGetDouble(response,"market_age_seconds");
   if(cloudAge<0 || cloudAge>InpBridgeMaxMarketAgeSeconds)
   {
      ResetR2VisualState();
      BridgeObserve("R2",false,status);
      AuditState("R2","STALE","CLOUD_R2_AGE="+DoubleToString(cloudAge,1));
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
      BridgeObserve("R2",false,status);
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
   g_r2PendingProtocolOK = true;
   g_ictR2ModelOK = true;
   g_r2PendingViable =
      StringFind(setupJson,"\"pending_viable\":true")>=0;
   g_r2PendingOnlyReason =
      JsonGetString(setupJson,"pending_only_reason");
   if(g_r2PendingOnlyReason=="")
      g_r2PendingOnlyReason="PENDING_NO_DETAIL";
   g_r2LastFreshPollServer=TimeTradeServer();

   // Worker v2.6 swing WATCH fields are not trading candidates.
   int watchAt=StringFind(response,"\"watch_zones\":{");
   int selectorAt=StringFind(response,"\"selector\":{",watchAt>=0?watchAt:0);
   if(watchAt>=0 && selectorAt>watchAt &&
      StringFind(response,"\"r2_watch_visual_schema\":1")>=0)
   {
      string watchJson=StringSubstr(response,watchAt,selectorAt-watchAt);
      if(StringFind(watchJson,"\"watch_only\":true")>=0 &&
         StringFind(watchJson,"\"tradable\":false")>=0 &&
         StringFind(watchJson,"\"available\":true")>=0 &&
         StringFind(watchJson,"\"source\":\"ICT_SMC_FVG_OB_M15\"")>=0)
      {
         g_r2WatchBuyLow=JsonGetDouble(watchJson,"watch_buy_low");
         g_r2WatchBuyHigh=JsonGetDouble(watchJson,"watch_buy_high");
         g_r2WatchSellLow=JsonGetDouble(watchJson,"watch_sell_low");
         g_r2WatchSellHigh=JsonGetDouble(watchJson,"watch_sell_high");
         g_r2WatchAvailable=
            ValidZone(g_r2WatchBuyLow,g_r2WatchBuyHigh) ||
            ValidZone(g_r2WatchSellLow,g_r2WatchSellHigh);
         if(g_r2WatchAvailable)
            g_r2WatchSource="ICT_SMC_FVG_OB_M15";
      }
   }

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

   BridgeObserve("R2",true,status);
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

   // Explicit broker SERVER wall-clock fields for Worker-side R2 session
   // gating. Cloudflare's UTC clock must not determine MT5 server hours.
   datetime brokerNow=TimeTradeServer();
   MqlDateTime brokerClock;
   TimeToStruct(brokerNow,brokerClock);
   int brokerSecondsOfDay=brokerClock.hour*3600+
      brokerClock.min*60+brokerClock.sec;
   int sessionStart=0,sessionEnd=0,brokerOffset=0;
   bool sessionValid=AutoEntryWindowBounds(sessionStart,sessionEnd,brokerOffset);
   string payload = "{";

   payload +=
      "\"broker_server_day_of_week\":"+
      IntegerToString(brokerClock.day_of_week)+",";

   payload +=
      "\"broker_server_seconds_of_day\":"+
      IntegerToString(brokerSecondsOfDay)+",";

   payload += "\"broker_session_policy\":\"LONDON_0800_TO_SERVER_2359_V1\",";
   payload += "\"broker_session_enabled\":"+
      (InpEnableBrokerServerAutoWindow?"true":"false")+",";
   payload += "\"broker_session_window_valid\":"+
      (sessionValid?"true":"false")+",";
   payload += "\"broker_session_open_seconds\":"+
      IntegerToString(sessionStart)+",";
   payload += "\"broker_session_close_seconds\":"+
      IntegerToString(sessionEnd)+",";
   payload += "\"broker_server_utc_offset_minutes\":"+
      IntegerToString(brokerOffset)+",";

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

   // News decision is evaluated in OnTimer BEFORE this market update.
   // Worker treats missing/stale telemetry as UNKNOWN, not an approval.
   string newsRisk="NONE";
   if(InpEnableUSDNewsGuard)
   {
      if(!g_newsFeedHealthy)newsRisk="UNKNOWN";
      else if(g_newsEntryBlocked && g_newsShockUntil>brokerNow)
         newsRisk="SHOCK";
      else if(g_newsEntryBlocked && g_newsBlockUntil>brokerNow)
         newsRisk=NewsRiskLabel(g_newsBlockRisk);
      else if(g_newsAttentionRisk>0)
         newsRisk=NewsRiskLabel(g_newsAttentionRisk);
      else
         newsRisk="NONE";
   }
   string newsSource=InpEnableUSDNewsGuard?"MT5_USD_CALENDAR":"GUARD_DISABLED";
   string newsDecision=g_newsEntryBlocked?"BLOCK":"ALLOW";
   if(InpEnableUSDNewsGuard && !g_newsFeedHealthy)
      newsDecision="UNKNOWN";
   if(g_newsShockUntil>brokerNow && InpEnableUSDNewsGuard)
      newsDecision="BLOCK";
   payload +=
      "\"news_policy\":{"+
      "\"schema\":1,"+
      "\"source\":\""+newsSource+"\","+
      "\"enabled\":"+(InpEnableUSDNewsGuard?"true":"false")+","+
      "\"risk\":\""+JsonEscape(newsRisk)+"\","+
      "\"decision\":\""+newsDecision+"\","+
      "\"entry_allowed\":"+(g_newsEntryBlocked?"false":"true")+","+
      "\"calendar_healthy\":"+(g_newsFeedHealthy?"true":"false")+","+
      "\"status\":\""+JsonEscape(g_newsStatus)+"\","+
      "\"checked_at_server\":"+IntegerToString(brokerNow)+","+
      "\"calendar_checked_at_server\":"+IntegerToString(g_newsLastPoll)+","+
      "\"next_blocking_event_server\":"+IntegerToString(g_newsNextBlockingTime)+
      "},";



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

   BridgeObserve("POST",BridgeIsOK(status,response),status);
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

      return;   }

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

      chunkFrom =         chunkTo +
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

      datetime dealTime =         (datetime)
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
// AUTO-TRADE RESULTS FEED
// Counts ONLY real broker trades opened by this EA automatically:
//   R1 auto market: XAU_AUTO_*
//   R2 auto pending: XAU_R2P_*
// Manual/panel/virtual/system-test trades are excluded.
// ============================================================

string AutoTradeSourceFromComment(string comment)
{
   if(StringFind(comment, "XAU_AUTO_") == 0)
      return "R1_AUTO";

   if(StringFind(comment, "XAU_R2P_") == 0)
      return "R2_AUTO";

   return "";
}


string AutoTradeBasketIdFromComment(
   string comment,
   string source,
   ulong positionId
)
{
   int separator =
      StringFind(
         comment,
         "|"
      );

   if(separator >= 0)
   {
      string basketId =
         StringSubstr(
            comment,
            separator + 1
         );

      if(basketId != "")
         return basketId;
   }

   // Compatibility fallback for positions created before v3.5.4.
   return
      (
         source == "R1_AUTO"
         ? "R1-LEGACY-"
         : "R2-LEGACY-"
      ) +
      IntegerToString(
         (long)positionId
      );
}


string DealOrderComment(ulong dealTicket)
{
   string comment =
      HistoryDealGetString(
         dealTicket,
         DEAL_COMMENT
      );

   if(comment != "")
      return comment;

   ulong orderTicket =
      (ulong)
      HistoryDealGetInteger(
         dealTicket,
         DEAL_ORDER
      );

   if(orderTicket > 0)
   {
      string orderComment =
         HistoryOrderGetString(
            orderTicket,
            ORDER_COMMENT
         );

      if(orderComment != "")
         return orderComment;
   }

   return "";
}


string AutoTradeSourceForPosition(ulong positionId)
{
   if(positionId == 0)
      return "";

   if(!HistorySelectByPosition(positionId))
      return "";

   int total =
      HistoryDealsTotal();

   for(int i = 0; i < total; i++)
   {
      ulong dealTicket =
         HistoryDealGetTicket(i);

      if(dealTicket == 0)
         continue;

      long entryType =
         HistoryDealGetInteger(
            dealTicket,
            DEAL_ENTRY
         );

      if(
         entryType != DEAL_ENTRY_IN &&
         entryType != DEAL_ENTRY_INOUT
      )
      {
         continue;
      }

      string source =
         AutoTradeSourceFromComment(
            DealOrderComment(dealTicket)
         );

      if(source != "")
         return source;
   }

   return "";
}

string AutoTradeCloseReason(long dealReason)
{
   if(dealReason == DEAL_REASON_SL)
      return "SL";

   if(dealReason == DEAL_REASON_TP)
      return "TP";

   if(dealReason == DEAL_REASON_EXPERT)
      return "EA";

   if(dealReason == DEAL_REASON_CLIENT)
      return "MANUAL_DESKTOP";

   if(dealReason == DEAL_REASON_MOBILE)
      return "MANUAL_MOBILE";

   if(dealReason == DEAL_REASON_WEB)
      return "MANUAL_WEB";

   return "OTHER";
}


bool SendAutoTradeEvent(
   string eventId,
   string eventType,
   string signalId,
   string source,
   string basketId,
   ulong positionId,
   ulong dealId,
   string side,
   double price,
   double volume,
   double sl,
   double tp,
   double profit,
   double commission,
   double swap,
   long eventTimeMs,
   string closeReason
)
{
   if(
      eventId == "" ||
      signalId == "" ||
      source == "" ||
      basketId == "" ||
      positionId == 0
   )
   {
      return false;
   }

   string payload = "{";

   payload +=
      "\"event_id\":\"" +
      JsonEscape(eventId) +
      "\",";

   payload +=
      "\"event_type\":\"" +
      JsonEscape(eventType) +
      "\",";

   payload +=
      "\"signal_id\":\"" +
      JsonEscape(signalId) +
      "\",";

   payload +=
      "\"symbol\":\"" +
      JsonEscape(_Symbol) +
      "\",";

   payload +=
      "\"position_id\":\"" +
      IntegerToString((long)positionId) +
      "\",";

   payload +=
      "\"deal_id\":\"" +
      IntegerToString((long)dealId) +
      "\",";

   payload +=
      "\"side\":\"" +
      JsonEscape(side) +
      "\",";

   payload +=
      "\"price\":" +
      DoubleToString(price, _Digits) +
      ",";

   payload +=
      "\"volume\":" +
      DoubleToString(volume, 2) +
      ",";

   payload +=
      "\"profit\":" +
      DoubleToString(profit, 2) +
      ",";

   payload +=
      "\"commission\":" +
      DoubleToString(commission, 2) +
      ",";

   payload +=
      "\"swap\":" +
      DoubleToString(swap, 2) +
      ",";

   payload +=
      "\"net_profit\":" +
      DoubleToString(
         profit +
         commission +
         swap,
         2
      ) +
      ",";

   payload +=
      "\"event_time\":" +
      IntegerToString(eventTimeMs) +
      ",";

   payload +=
      "\"basket_id\":\"" +
      JsonEscape(basketId) +
      "\",";

   payload +=
      "\"sl\":" +
      DoubleToString(sl, _Digits) +
      ",";

   payload +=
      "\"tp\":" +
      DoubleToString(tp, _Digits) +
      ",";

   payload +=
      "\"auto_trade\":true,";

   payload +=
      "\"auto_source\":\"" +
      JsonEscape(source) +
      "\"";

   if(closeReason != "")
   {
      payload +=
         ",\"close_reason\":\"" +
         JsonEscape(closeReason) +
         "\"";
   }

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
         "AUTO RESULT EVENT SENT | ",
         eventType,
         " | ",
         source,
         " | position=",
         positionId,
         " | net=",
         DoubleToString(
            profit +
            commission +
            swap,
            2
         )
      );

      return true;
   }

   Print(
      "AUTO RESULT EVENT FAILED | HTTP=",
      status,
      " | ",
      response
   );

   return false;
}


void ReportAutoOpenedDeal(ulong dealTicket)
{
   if(dealTicket == 0)
      return;

   string symbol =
      HistoryDealGetString(
         dealTicket,
         DEAL_SYMBOL
      );

   if(symbol != _Symbol)
      return;

   long entryType =
      HistoryDealGetInteger(
         dealTicket,
         DEAL_ENTRY
      );

   if(
      entryType != DEAL_ENTRY_IN &&
      entryType != DEAL_ENTRY_INOUT
   )
   {
      return;
   }

   long dealType =
      HistoryDealGetInteger(
         dealTicket,
         DEAL_TYPE
      );

   if(
      dealType != DEAL_TYPE_BUY &&
      dealType != DEAL_TYPE_SELL
   )
   {
      return;
   }

   string orderComment =
      DealOrderComment(
         dealTicket
      );

   string source =
      AutoTradeSourceFromComment(
         orderComment
      );

   if(source == "")
      return;

   ulong positionId =
      (ulong)
      HistoryDealGetInteger(
         dealTicket,
         DEAL_POSITION_ID
      );

   if(positionId == 0)
      return;

   string side =
      dealType == DEAL_TYPE_BUY
      ? "BUY"
      : "SELL";

   double price =
      HistoryDealGetDouble(
         dealTicket,
         DEAL_PRICE
      );

   double volume =
      HistoryDealGetDouble(
         dealTicket,
         DEAL_VOLUME
      );

   long eventTimeMs =
      HistoryDealGetInteger(
         dealTicket,
         DEAL_TIME_MSC
      );

   string basketId =
      AutoTradeBasketIdFromComment(
         orderComment,
         source,
         positionId
      );

   string signalId =
      "AUTO-" +
      basketId;

   string eventId =
      "AUTO-OPEN-" +
      IntegerToString(
         (long)positionId
      );

   double sl = 0.0;
   double tp = 0.0;

   ulong orderTicket =
      (ulong)
      HistoryDealGetInteger(
         dealTicket,
         DEAL_ORDER
      );

   if(orderTicket > 0)
   {
      sl =
         HistoryOrderGetDouble(
            orderTicket,
            ORDER_SL
         );

      tp =
         HistoryOrderGetDouble(
            orderTicket,
            ORDER_TP
         );
   }

   SendAutoTradeEvent(
      eventId,
      "OPEN",
      signalId,
      source,
      basketId,
      positionId,
      dealTicket,
      side,
      price,
      volume,
      sl,
      tp,
      0.0,
      0.0,
      0.0,
      eventTimeMs,
      ""
   );
}


void ReportAutoClosedPosition(ulong positionId)
{
   if(positionId == 0)
      return;

   // A partial close is not a finished trade.
   if(PositionExistsByIdentifier(positionId))
      return;

   if(!HistorySelectByPosition(positionId))
      return;

   string source =
      AutoTradeSourceForPosition(
         positionId
      );

   if(source == "")
      return;

   int total =
      HistoryDealsTotal();

   string openingComment = "";
   double plannedSL = 0.0;
   double plannedTP = 0.0;

   double totalProfit = 0.0;
   double totalCommission = 0.0;
   double totalSwap = 0.0;
   double totalClosedVolume = 0.0;

   double exitValue = 0.0;
   double exitWeight = 0.0;

   long latestTimeMs = 0;
   ulong latestDeal = 0;
   long latestReason = 0;
   string side = "";

   for(int i = 0; i < total; i++)
   {
      ulong dealTicket =
         HistoryDealGetTicket(i);

      if(dealTicket == 0)
         continue;

      long entryType =
         HistoryDealGetInteger(
            dealTicket,
            DEAL_ENTRY
         );

      long dealType =
         HistoryDealGetInteger(
            dealTicket,
            DEAL_TYPE
         );

      if(
         (
            entryType == DEAL_ENTRY_IN ||
            entryType == DEAL_ENTRY_INOUT
         ) &&
         (
            dealType == DEAL_TYPE_BUY ||
            dealType == DEAL_TYPE_SELL
         )
      )
      {
         if(side == "")
         {
            side =
               dealType == DEAL_TYPE_BUY
               ? "BUY"
               : "SELL";
         }

         if(openingComment == "")
         {
            openingComment =
               DealOrderComment(
                  dealTicket
               );

            ulong openingOrder =
               (ulong)
               HistoryDealGetInteger(
                  dealTicket,
                  DEAL_ORDER
               );

            if(openingOrder > 0)
            {
               plannedSL =
                  HistoryOrderGetDouble(
                     openingOrder,
                     ORDER_SL
                  );

               plannedTP =
                  HistoryOrderGetDouble(
                     openingOrder,
                     ORDER_TP
                  );
            }
         }

         continue;
      }

      if(
         entryType != DEAL_ENTRY_OUT &&
         entryType != DEAL_ENTRY_OUT_BY
      )
      {
         continue;
      }

      if(
         dealType != DEAL_TYPE_BUY &&
         dealType != DEAL_TYPE_SELL
      )
      {
         continue;
      }

      double profit =
         HistoryDealGetDouble(
            dealTicket,
            DEAL_PROFIT
         );

      double commission =
         HistoryDealGetDouble(
            dealTicket,
            DEAL_COMMISSION
         );

      double swap =
         HistoryDealGetDouble(
            dealTicket,
            DEAL_SWAP
         );

      double volume =
         HistoryDealGetDouble(
            dealTicket,
            DEAL_VOLUME
         );

      double price =
         HistoryDealGetDouble(
            dealTicket,
            DEAL_PRICE
         );

      long timeMs =
         HistoryDealGetInteger(
            dealTicket,
            DEAL_TIME_MSC
         );

      totalProfit += profit;
      totalCommission += commission;
      totalSwap += swap;
      totalClosedVolume += volume;

      if(volume > 0.0)
      {
         exitValue +=
            price *
            volume;

         exitWeight +=
            volume;
      }

      if(timeMs >= latestTimeMs)
      {
         latestTimeMs = timeMs;
         latestDeal = dealTicket;

         latestReason =
            HistoryDealGetInteger(
               dealTicket,
               DEAL_REASON
            );
      }
   }

   if(latestDeal == 0)
      return;

   double exitPrice =
      exitWeight > 0.0
      ? exitValue / exitWeight
      : HistoryDealGetDouble(
           latestDeal,
           DEAL_PRICE
        );

   string basketId =
      AutoTradeBasketIdFromComment(
         openingComment,
         source,
         positionId
      );

   string signalId =
      "AUTO-" +
      basketId;

   string eventId =
      "AUTO-CLOSE-" +
      IntegerToString(
         (long)positionId
      );

   SendAutoTradeEvent(
      eventId,
      "CLOSE",
      signalId,
      source,
      basketId,
      positionId,
      latestDeal,
      side,
      exitPrice,
      totalClosedVolume,
      plannedSL,
      plannedTP,
      totalProfit,
      totalCommission,
      totalSwap,
      latestTimeMs,
      AutoTradeCloseReason(
         latestReason
      )
   );
}


void ReportAutoTradeTransaction(
   const MqlTradeTransaction &trans
)
{
   if(
      trans.type !=
      TRADE_TRANSACTION_DEAL_ADD ||
      trans.deal == 0
   )
   {
      return;
   }

   ulong dealTicket =
      trans.deal;

   string symbol =
      HistoryDealGetString(
         dealTicket,
         DEAL_SYMBOL
      );

   if(symbol != _Symbol)
      return;

   long entryType =
      HistoryDealGetInteger(
         dealTicket,
         DEAL_ENTRY
      );

   if(
      entryType == DEAL_ENTRY_IN ||
      entryType == DEAL_ENTRY_INOUT
   )
   {
      ReportAutoOpenedDeal(
         dealTicket
      );

      return;
   }

   if(
      entryType == DEAL_ENTRY_OUT ||
      entryType == DEAL_ENTRY_OUT_BY
   )
   {
      ulong positionId =
         (ulong)
         HistoryDealGetInteger(
            dealTicket,
            DEAL_POSITION_ID
         );

      ReportAutoClosedPosition(
         positionId
      );
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

   // Invalidate MT5 real-history performance cache on every broker deal.
   if(trans.type==TRADE_TRANSACTION_DEAL_ADD)
      g_realAutoPerfLastScan=0;
   if(InpEnableTradeAuditLog && trans.symbol==_Symbol &&
      trans.type==TRADE_TRANSACTION_HISTORY_ADD && trans.order>0 &&
      HistoryOrderSelect(trans.order))
   {
      string cm=HistoryOrderGetString(trans.order,ORDER_COMMENT);
      if(IsR2ManagedPendingComment(cm))
      {
         long state=HistoryOrderGetInteger(trans.order,ORDER_STATE);
         string resultCode=state==ORDER_STATE_FILLED?"FILLED":
            state==ORDER_STATE_EXPIRED?"EXPIRED":
            state==ORDER_STATE_CANCELED?"CANCELED":"OTHER";
         AuditEvent("R2","BROKER_HISTORY",resultCode,cm,trans.order,
                    HistoryOrderGetDouble(trans.order,ORDER_PRICE_OPEN),
                    HistoryOrderGetDouble(trans.order,ORDER_SL),
                    HistoryOrderGetDouble(trans.order,ORDER_TP));
      }
   }

   // Report ONLY real automatic R1/R2 broker trades to /bot-results.
   ReportAutoTradeTransaction(trans);

   // Detect a newly-opened XAU position. Manual orders cannot be rejected
   // before broker execution, so the risk guard validates the new position
   // immediately after auto-protection has had a chance to attach its SL.
   if(
      InpEnableMaxSLRiskGuard &&
      trans.type == TRADE_TRANSACTION_DEAL_ADD &&
      trans.deal > 0
   )
   {
      string dealSymbol = HistoryDealGetString(trans.deal, DEAL_SYMBOL);
      long dealEntry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
      long dealType = HistoryDealGetInteger(trans.deal, DEAL_TYPE);

      bool isEntry =
         dealEntry == DEAL_ENTRY_IN ||
         dealEntry == DEAL_ENTRY_INOUT;

      bool isMarketSide =
         dealType == DEAL_TYPE_BUY ||
         dealType == DEAL_TYPE_SELL;

      if(
         dealSymbol == _Symbol &&
         isEntry &&
         isMarketSide
      )
      {
         // HARD GATE FOR MANUAL/LIVE ENTRIES:
         // Validate this position immediately on the trade transaction.
         // Waiting for OnTimer() allowed several rapid one-click entries
         // to stack before the previous version got a chance to react.
         RequestRiskGuardCheckForNewPosition(trans.position);
         EnforceMaxSLRiskGuardForNewPosition();
      }
   }

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

   g_state.mae_usd =      StringToDouble(
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