// XAU HYBRID PUBLIC-EDGE BACKTEST v1
// TESTER ONLY, fresh implementation. No code copied from proprietary EAs.
//
// Public-behavior synthesis:
// A) TREND_MOMENTUM: H1 momentum/trend engine inspired by publicly described
//    AurumAlert / CCI Duo Rider behavior.
// B) RANGE_BREAKOUT: M1 session-range OCO-style breakout inspired by the
//    publicly described AurumAlert / Range Sniper behavior.
// C) PRECISION_SCALP: short-duration liquid-session engine inspired by the
//    observable holding-time / win-rate behavior of public Gold scalpers.
//
// Macro permission layer: H4 trend+momentum voting inspired by the public
// Golden Viper description.
// Master router: regime-adaptive architecture inspired by public multi-regime
// Gold systems such as CWDT.
//
// Explicit exclusions: no grid, no martingale, no averaging into losers.
// Historical/backtest profitability is not guaranteed.

#property strict

#include <Trade/Trade.mqh>

CTrade trade;

// ============================================================
// INPUTS
// ============================================================

input long   InpMagicNumber                 = 26100911;

// Portfolio risk
input double InpTrendRiskPercent            = 0.50;
input double InpRangeRiskPercent            = 0.40;
input double InpScalpRiskPercent            = 0.30;
input double InpMaxLot                      = 0.03;
input double InpMaxMarginUsagePercent       = 70.0;
input double InpDailyLossLimitPercent       = 2.00;
input double InpEquityPeakDDStopPercent     = 8.00;
input int    InpMaxTradesPerDay             = 5;

// Global execution
input double InpMaxSpreadUSD                = 0.65;
input int    InpCooldownMinutes             = 12;

// Router thresholds
input double InpTrendADXMin                 = 22.0;
input double InpTrendEMASepATRMin           = 0.45;
input double InpRangeADXMax                 = 21.0;
input double InpScalpADXMin                 = 16.0;

// Engine A, H1 Trend/Momentum
input int    InpTrendFastCCIPeriod           = 14;
input int    InpTrendSlowCCIPeriod           = 50;
input double InpTrendRSIBuyMin               = 52.0;
input double InpTrendRSISellMax              = 48.0;
input double InpTrendSLPricePercent          = 0.35;
input double InpTrendSLATRMin                = 1.40;
input double InpTrendTargetR                 = 2.80;
input double InpTrendTrailStartR             = 1.10;
input double InpTrendTrailATR                = 1.20;
input int    InpTrendMaxHoldHours            = 48;

// Engine B, M1 Session Range Breakout
input int    InpRangeBuildStartHour          = 7;
input int    InpRangeBuildStartMinute        = 0;
input int    InpRangeBuildEndHour            = 7;
input int    InpRangeBuildEndMinute          = 30;
input int    InpRangeTradeEndHour            = 12;
input int    InpRangeTradeEndMinute          = 0;
input int    InpRangeCloseHour               = 20;
input int    InpRangeCloseMinute             = 0;
input double InpRangeMinATR                  = 0.30;
input double InpRangeMaxATR                  = 1.30;
input double InpRangeBreakBufferATR          = 0.08;
input double InpRangeSLExtraRange            = 0.15;
input double InpRangeTargetR                 = 1.60;
input double InpRangeBreakEvenR              = 0.80;

// Engine C, Precision Scalp
input int    InpScalpStartHour               = 8;
input int    InpScalpEndHour                 = 19;
input double InpScalpATRRatioMin             = 0.65;
input double InpScalpATRRatioMax             = 1.60;
input double InpScalpMaxPullbackATR          = 0.25;
input double InpScalpTargetR                 = 0.95;
input double InpScalpBreakEvenR              = 0.55;
input int    InpScalpTimeStopMinutes         = 30;
input int    InpMaxScalpsPerDay              = 2;

// UI/logs
input bool   InpShowStatus                   = true;
input bool   InpLogTrades                    = true;

// ============================================================
// INDICATOR HANDLES
// ============================================================

// H4 macro-vote layer
int hH4EMA200 = INVALID_HANDLE;
int hH4MACD   = INVALID_HANDLE;
int hH4TRIX   = INVALID_HANDLE;
int hH4ICHI   = INVALID_HANDLE;

// H1 router / trend engine
int hH1EMA20  = INVALID_HANDLE;
int hH1EMA200 = INVALID_HANDLE;
int hH1ATR    = INVALID_HANDLE;
int hH1ADX    = INVALID_HANDLE;
int hH1RSI    = INVALID_HANDLE;
int hH1CCIFast= INVALID_HANDLE;
int hH1CCISlow= INVALID_HANDLE;

// M15 router / range
int hM15ATR   = INVALID_HANDLE;
int hM15ADX   = INVALID_HANDLE;

// M5 scalp router
int hM5EMA20  = INVALID_HANDLE;
int hM5EMA50  = INVALID_HANDLE;
int hM5ATR    = INVALID_HANDLE;
int hM5ADX    = INVALID_HANDLE;

// M1 scalp trigger
int hM1EMA9   = INVALID_HANDLE;
int hM1EMA20  = INVALID_HANDLE;
int hM1ATR    = INVALID_HANDLE;
int hM1RSI    = INVALID_HANDLE;

// ============================================================
// GLOBAL STATE
// ============================================================

datetime g_lastM1Bar = 0;
datetime g_lastEntryTime = 0;
datetime g_lastTrendSignalBar = 0;

int g_dayKey = -1;
double g_dayStartEquity = 0.0;
double g_equityPeak = 0.0;

int g_tradesToday = 0;
int g_scalpsToday = 0;
int g_rangeTradedDay = -1;

string g_positionEngine = "";
string g_positionSide = "";
double g_entry = 0.0;
double g_initialSL = 0.0;
double g_initialRisk = 0.0;
double g_target = 0.0;
datetime g_positionOpenTime = 0;
bool g_breakEvenDone = false;

long g_routerTrend = 0;
long g_routerRange = 0;
long g_routerScalp = 0;
long g_routerNone = 0;

long g_trendSignals = 0;
long g_rangeSignals = 0;
long g_scalpSignals = 0;

long g_orders = 0;
long g_trendOrders = 0;
long g_rangeOrders = 0;
long g_scalpOrders = 0;

long g_riskBlocks = 0;
long g_spreadBlocks = 0;
long g_cooldownBlocks = 0;

// ============================================================
// TYPES
// ============================================================

struct TradePlan
{
   bool valid;
   string engine;
   string side;
   string reason;
   double entry;
   double sl;
   double tp;
   double risk_percent;
};

struct SessionRange
{
   bool valid;
   double high;
   double low;
   double width;
   int bars;
};

// ============================================================
// UTILS
// ============================================================

double NormalizePrice(double price)
{
   return NormalizeDouble(
      price,
      (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)
   );
}

double Clamp(double v, double lo, double hi)
{
   return MathMax(lo, MathMin(hi, v));
}

bool CopyVal(
   int handle,
   int buffer,
   int shift,
   double &value
)
{
   if(handle == INVALID_HANDLE)
      return false;

   double tmp[1];

   if(CopyBuffer(handle, buffer, shift, 1, tmp) != 1)
      return false;

   value = tmp[0];

   return MathIsValidNumber(value);
}

bool GetRates(
   ENUM_TIMEFRAMES tf,
   int shift,
   int count,
   MqlRates &rates[]
)
{
   ArraySetAsSeries(rates, true);

   return CopyRates(
      _Symbol,
      tf,
      shift,
      count,
      rates
   ) == count;
}

int DayKey(datetime t)
{
   MqlDateTime tm;
   TimeToStruct(t, tm);

   return tm.year * 10000 + tm.mon * 100 + tm.day;
}

int MinuteOfDay(datetime t)
{
   MqlDateTime tm;
   TimeToStruct(t, tm);

   return tm.hour * 60 + tm.min;
}

datetime TodayStart()
{
   MqlDateTime tm;
   TimeToStruct(TimeCurrent(), tm);

   tm.hour = 0;
   tm.min = 0;
   tm.sec = 0;

   return StructToTime(tm);
}

bool InMinuteWindow(int nowMin, int startMin, int endMin)
{
   if(startMin == endMin)
      return true;

   if(startMin < endMin)
      return nowMin >= startMin && nowMin < endMin;

   return nowMin >= startMin || nowMin < endMin;
}

double CandleClosePosition(MqlRates &bar)
{
   double range = bar.high - bar.low;

   if(range <= 0.0)
      return 0.5;

   return (bar.close - bar.low) / range;
}

double HighestHigh(MqlRates &rates[], int start, int count)
{
   double result = -DBL_MAX;

   for(int i = start; i < start + count; i++)
      result = MathMax(result, rates[i].high);

   return result;
}

double LowestLow(MqlRates &rates[], int start, int count)
{
   double result = DBL_MAX;

   for(int i = start; i < start + count; i++)
      result = MathMin(result, rates[i].low);

   return result;
}

TradePlan EmptyPlan()
{
   TradePlan p;

   p.valid = false;
   p.engine = "NONE";
   p.side = "NONE";
   p.reason = "";
   p.entry = 0.0;
   p.sl = 0.0;
   p.tp = 0.0;
   p.risk_percent = 0.0;

   return p;
}

void ResetDailyIfNeeded()
{
   int key = DayKey(TimeCurrent());

   if(key == g_dayKey)
      return;

   g_dayKey = key;
   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_tradesToday = 0;
   g_scalpsToday = 0;

   if(g_equityPeak <= 0.0)
      g_equityPeak = g_dayStartEquity;
}

void UpdateEquityPeak()
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);

   if(eq > g_equityPeak)
      g_equityPeak = eq;
}

bool RiskGuardAllowsNewTrade()
{
   ResetDailyIfNeeded();
   UpdateEquityPeak();

   if(g_tradesToday >= InpMaxTradesPerDay)
   {
      g_riskBlocks++;
      return false;
   }

   double eq = AccountInfoDouble(ACCOUNT_EQUITY);

   if(
      g_dayStartEquity > 0.0 &&
      eq <=
      g_dayStartEquity *
      (1.0 - InpDailyLossLimitPercent / 100.0)
   )
   {
      g_riskBlocks++;
      return false;
   }

   if(
      g_equityPeak > 0.0 &&
      eq <=
      g_equityPeak *
      (1.0 - InpEquityPeakDDStopPercent / 100.0)
   )
   {
      g_riskBlocks++;
      return false;
   }

   return true;
}

bool CooldownAllows()
{
   if(g_lastEntryTime <= 0)
      return true;

   bool ok =
      TimeCurrent() - g_lastEntryTime >=
      InpCooldownMinutes * 60;

   if(!ok)
      g_cooldownBlocks++;

   return ok;
}

bool SpreadAllows(MqlTick &tick)
{
   bool ok =
      (tick.ask - tick.bid) <=
      InpMaxSpreadUSD;

   if(!ok)
      g_spreadBlocks++;

   return ok;
}

double NormalizeVolumeDown(double volume)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(minLot <= 0.0) minLot = 0.01;
   if(maxLot <= 0.0) maxLot = volume;
   if(step <= 0.0) step = 0.01;

   volume = MathMin(volume, MathMin(maxLot, InpMaxLot));

   double normalized =
      MathFloor((volume + 1e-12) / step) *
      step;

   normalized = NormalizeDouble(normalized, 2);

   if(normalized < minLot)
      return 0.0;

   return normalized;
}

double RiskLot(
   string side,
   double entry,
   double sl,
   double riskPercent
)
{
   double riskMoney =
      AccountInfoDouble(ACCOUNT_EQUITY) *
      riskPercent /
      100.0;

   if(riskMoney <= 0.0)
      return 0.0;

   ENUM_ORDER_TYPE type =
      side == "BUY"
      ? ORDER_TYPE_BUY
      : ORDER_TYPE_SELL;

   double oneLotPL = 0.0;

   if(
      !OrderCalcProfit(
         type,
         _Symbol,
         1.0,
         entry,
         sl,
         oneLotPL
      )
   )
      return 0.0;

   double oneLotLoss = MathAbs(oneLotPL);

   if(oneLotLoss <= 0.0)
      return 0.0;

   double lot =
      NormalizeVolumeDown(
         riskMoney / oneLotLoss
      );

   if(lot <= 0.0)
      return 0.0;

   double freeMargin =
      AccountInfoDouble(ACCOUNT_MARGIN_FREE);

   double maxMargin =
      freeMargin *
      InpMaxMarginUsagePercent /
      100.0;

   double step =
      SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   double minLot =
      SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   if(step <= 0.0) step = 0.01;
   if(minLot <= 0.0) minLot = 0.01;

   while(lot >= minLot)
   {
      double required = 0.0;

      if(
         OrderCalcMargin(
            type,
            _Symbol,
            lot,
            entry,
            required
         ) &&
         required <= maxMargin
      )
      {
         return lot;
      }

      lot =
         NormalizeVolumeDown(
            lot - step
         );

      if(lot <= 0.0)
         break;
   }

   return 0.0;
}

// ============================================================
// H4 MACRO VOTE, GOLDEN-VIPER-STYLE CONFLUENCE
// ============================================================

int MacroVotes(string side)
{
   bool buy = side == "BUY";

   MqlRates h4[];

   if(!GetRates(PERIOD_H4, 1, 3, h4))
      return 0;

   double ema200 = 0.0;
   double macdMain = 0.0;
   double macdSignal = 0.0;
   double trix1 = 0.0;
   double trix2 = 0.0;
   double tenkan = 0.0;
   double kijun = 0.0;

   if(!CopyVal(hH4EMA200, 0, 1, ema200)) return 0;
   if(!CopyVal(hH4MACD, 0, 1, macdMain)) return 0;
   if(!CopyVal(hH4MACD, 1, 1, macdSignal)) return 0;
   if(!CopyVal(hH4TRIX, 0, 1, trix1)) return 0;
   if(!CopyVal(hH4TRIX, 0, 2, trix2)) return 0;
   if(!CopyVal(hH4ICHI, 0, 1, tenkan)) return 0;
   if(!CopyVal(hH4ICHI, 1, 1, kijun)) return 0;

   int votes = 0;

   if(
      buy
      ? h4[0].close > ema200
      : h4[0].close < ema200
   )
      votes++;

   if(
      buy
      ? macdMain > macdSignal
      : macdMain < macdSignal
   )
      votes++;

   if(
      buy
      ? trix1 > trix2
      : trix1 < trix2
   )
      votes++;

   if(
      buy
      ? tenkan > kijun
      : tenkan < kijun
   )
      votes++;

   return votes;
}

// ============================================================
// REGIME ROUTER
// ============================================================

string DetectRegime()
{
   MqlRates h1[];

   if(!GetRates(PERIOD_H1, 1, 3, h1))
      return "NONE";

   double h1EMA20 = 0.0;
   double h1EMA200 = 0.0;
   double h1ATR = 0.0;
   double h1ADX = 0.0;
   double m15ADX = 0.0;
   double m5ADX = 0.0;

   if(!CopyVal(hH1EMA20, 0, 1, h1EMA20)) return "NONE";
   if(!CopyVal(hH1EMA200, 0, 1, h1EMA200)) return "NONE";
   if(!CopyVal(hH1ATR, 0, 1, h1ATR)) return "NONE";
   if(!CopyVal(hH1ADX, 0, 1, h1ADX)) return "NONE";
   if(!CopyVal(hM15ADX, 0, 1, m15ADX)) return "NONE";
   if(!CopyVal(hM5ADX, 0, 1, m5ADX)) return "NONE";

   if(h1ATR <= 0.0)
      return "NONE";

   double sepATR =
      MathAbs(h1EMA20 - h1EMA200) /
      h1ATR;

   bool strongTrend =
      h1ADX >= InpTrendADXMin &&
      sepATR >= InpTrendEMASepATRMin;

   if(strongTrend)
   {
      g_routerTrend++;
      return "TREND";
   }

   int nowMin = MinuteOfDay(TimeCurrent());

   int rangeStart =
      InpRangeBuildEndHour * 60 +
      InpRangeBuildEndMinute;

   int rangeEnd =
      InpRangeTradeEndHour * 60 +
      InpRangeTradeEndMinute;

   bool rangeWindow =
      InMinuteWindow(
         nowMin,
         rangeStart,
         rangeEnd
      );

   if(
      rangeWindow &&
      m15ADX <= InpRangeADXMax
   )
   {
      g_routerRange++;
      return "RANGE_BREAKOUT";
   }

   int scalpStart = InpScalpStartHour * 60;
   int scalpEnd = InpScalpEndHour * 60;

   if(
      InMinuteWindow(
         nowMin,
         scalpStart,
         scalpEnd
      ) &&
      m5ADX >= InpScalpADXMin
   )
   {
      g_routerScalp++;
      return "SCALP";
   }

   g_routerNone++;
   return "NONE";
}

// ============================================================
// ENGINE A: H1 TREND / MOMENTUM
// ============================================================

TradePlan EvaluateTrendEngine()
{
   TradePlan p = EmptyPlan();

   MqlRates h1[];

   if(!GetRates(PERIOD_H1, 1, 6, h1))
      return p;

   if(h1[0].time == g_lastTrendSignalBar)
      return p;

   double ema20 = 0.0;
   double ema200 = 0.0;
   double atr = 0.0;
   double adx = 0.0;
   double plusDI = 0.0;
   double minusDI = 0.0;
   double rsi = 0.0;

   double cciFast1 = 0.0;
   double cciFast2 = 0.0;
   double cciFast4 = 0.0;
   double cciSlow1 = 0.0;
   double cciSlow2 = 0.0;

   if(!CopyVal(hH1EMA20, 0, 1, ema20)) return p;
   if(!CopyVal(hH1EMA200, 0, 1, ema200)) return p;
   if(!CopyVal(hH1ATR, 0, 1, atr)) return p;
   if(!CopyVal(hH1ADX, 0, 1, adx)) return p;
   if(!CopyVal(hH1ADX, 1, 1, plusDI)) return p;
   if(!CopyVal(hH1ADX, 2, 1, minusDI)) return p;
   if(!CopyVal(hH1RSI, 0, 1, rsi)) return p;

   if(!CopyVal(hH1CCIFast, 0, 1, cciFast1)) return p;
   if(!CopyVal(hH1CCIFast, 0, 2, cciFast2)) return p;
   if(!CopyVal(hH1CCIFast, 0, 4, cciFast4)) return p;
   if(!CopyVal(hH1CCISlow, 0, 1, cciSlow1)) return p;
   if(!CopyVal(hH1CCISlow, 0, 2, cciSlow2)) return p;

   bool buyTrend =
      h1[0].close > ema20 &&
      ema20 > ema200 &&
      adx >= InpTrendADXMin &&
      plusDI > minusDI &&
      rsi >= InpTrendRSIBuyMin &&
      MacroVotes("BUY") >= 3;

   bool sellTrend =
      h1[0].close < ema20 &&
      ema20 < ema200 &&
      adx >= InpTrendADXMin &&
      minusDI > plusDI &&
      rsi <= InpTrendRSISellMax &&
      MacroVotes("SELL") >= 3;

   if(!buyTrend && !sellTrend)
      return p;

   string side =
      buyTrend
      ? "BUY"
      : "SELL";

   bool buy = side == "BUY";

   bool cciCross =
      buy
      ? (
           cciFast1 > cciSlow1 &&
           cciFast2 <= cciSlow2
        )
      : (
           cciFast1 < cciSlow1 &&
           cciFast2 >= cciSlow2
        );

   bool divergence =
      buy
      ? (
           h1[0].low < h1[3].low &&
           cciFast1 > cciFast4
        )
      : (
           h1[0].high > h1[3].high &&
           cciFast1 < cciFast4
        );

   if(!cciCross && !divergence)
      return p;

   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return p;

   double entry =
      buy
      ? tick.ask
      : tick.bid;

   double pctDistance =
      entry *
      InpTrendSLPricePercent /
      100.0;

   double stopDistance =
      MathMax(
         pctDistance,
         InpTrendSLATRMin * atr
      );

   double sl =
      buy
      ? entry - stopDistance
      : entry + stopDistance;

   double tp =
      buy
      ? entry + InpTrendTargetR * stopDistance
      : entry - InpTrendTargetR * stopDistance;

   p.valid = true;
   p.engine = "TREND_MOMENTUM";
   p.side = side;
   p.reason =
      cciCross && divergence
      ? "CCI_CROSS+DIVERGENCE"
      : cciCross
        ? "CCI_CROSS"
        : "CCI_DIVERGENCE";
   p.entry = NormalizePrice(entry);
   p.sl = NormalizePrice(sl);
   p.tp = NormalizePrice(tp);
   p.risk_percent = InpTrendRiskPercent;

   g_lastTrendSignalBar = h1[0].time;
   g_trendSignals++;

   return p;
}

// ============================================================
// ENGINE B: M1 SESSION RANGE BREAKOUT, VIRTUAL OCO
// ============================================================

SessionRange BuildTodayRange()
{
   SessionRange r;

   r.valid = false;
   r.high = 0.0;
   r.low = 0.0;
   r.width = 0.0;
   r.bars = 0;

   datetime start =
      TodayStart() +
      InpRangeBuildStartHour * 3600 +
      InpRangeBuildStartMinute * 60;

   datetime stop =
      TodayStart() +
      InpRangeBuildEndHour * 3600 +
      InpRangeBuildEndMinute * 60;

   if(TimeCurrent() < stop)
      return r;

   MqlRates bars[];
   ArraySetAsSeries(bars, false);

   int copied =
      CopyRates(
         _Symbol,
         PERIOD_M1,
         start,
         stop - 1,
         bars
      );

   if(copied < 10)
      return r;

   double hi = -DBL_MAX;
   double lo = DBL_MAX;

   for(int i = 0; i < copied; i++)
   {
      hi = MathMax(hi, bars[i].high);
      lo = MathMin(lo, bars[i].low);
   }

   if(!(hi > lo))
      return r;

   r.valid = true;
   r.high = hi;
   r.low = lo;
   r.width = hi - lo;
   r.bars = copied;

   return r;
}

TradePlan EvaluateRangeBreakout()
{
   TradePlan p = EmptyPlan();

   if(g_rangeTradedDay == g_dayKey)
      return p;

   int nowMin = MinuteOfDay(TimeCurrent());

   int startMin =
      InpRangeBuildEndHour * 60 +
      InpRangeBuildEndMinute;

   int endMin =
      InpRangeTradeEndHour * 60 +
      InpRangeTradeEndMinute;

   if(!InMinuteWindow(nowMin, startMin, endMin))
      return p;

   SessionRange r = BuildTodayRange();

   if(!r.valid)
      return p;

   double atr15 = 0.0;
   double adx15 = 0.0;

   if(!CopyVal(hM15ATR, 0, 1, atr15)) return p;
   if(!CopyVal(hM15ADX, 0, 1, adx15)) return p;

   if(atr15 <= 0.0)
      return p;

   double rangeATR = r.width / atr15;

   if(
      rangeATR < InpRangeMinATR ||
      rangeATR > InpRangeMaxATR ||
      adx15 > InpRangeADXMax
   )
      return p;

   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return p;

   double buffer =
      MathMax(
         InpRangeBreakBufferATR * atr15,
         2.0 * (tick.ask - tick.bid)
      );

   double buyStop = r.high + buffer;
   double sellStop = r.low - buffer;

   bool buyBreak =
      tick.ask >= buyStop;

   bool sellBreak =
      tick.bid <= sellStop;

   if(!buyBreak && !sellBreak)
      return p;

   string side =
      buyBreak
      ? "BUY"
      : "SELL";

   // Avoid taking a breakout directly against a unanimous H4 macro vote.
   if(
      side == "BUY" &&
      MacroVotes("SELL") >= 4
   )
      return p;

   if(
      side == "SELL" &&
      MacroVotes("BUY") >= 4
   )
      return p;

   bool buy = side == "BUY";

   double entry =
      buy
      ? tick.ask
      : tick.bid;

   double sl =
      buy
      ? r.low - InpRangeSLExtraRange * r.width
      : r.high + InpRangeSLExtraRange * r.width;

   double risk = MathAbs(entry - sl);

   if(risk <= 0.0)
      return p;

   double tp =
      buy
      ? entry + InpRangeTargetR * risk
      : entry - InpRangeTargetR * risk;

   p.valid = true;
   p.engine = "RANGE_BREAKOUT";
   p.side = side;
   p.reason = "SESSION_RANGE_VIRTUAL_OCO";
   p.entry = NormalizePrice(entry);
   p.sl = NormalizePrice(sl);
   p.tp = NormalizePrice(tp);
   p.risk_percent = InpRangeRiskPercent;

   g_rangeSignals++;

   return p;
}

// ============================================================
// ENGINE C: PRECISION SCALP
// ============================================================

double ATRAverage(
   int handle,
   int startShift,
   int count
)
{
   if(handle == INVALID_HANDLE || count <= 0)
      return 0.0;

   double values[];
   ArrayResize(values, count);

   int copied =
      CopyBuffer(
         handle,
         0,
         startShift,
         count,
         values
      );

   if(copied != count)
      return 0.0;

   double sum = 0.0;

   for(int i = 0; i < count; i++)
      sum += values[i];

   return sum / count;
}

TradePlan EvaluateScalpEngine()
{
   TradePlan p = EmptyPlan();

   if(g_scalpsToday >= InpMaxScalpsPerDay)
      return p;

   int nowMin = MinuteOfDay(TimeCurrent());

   if(
      !InMinuteWindow(
         nowMin,
         InpScalpStartHour * 60,
         InpScalpEndHour * 60
      )
   )
      return p;

   MqlRates m5[];
   MqlRates m1[];

   if(!GetRates(PERIOD_M5, 1, 6, m5))
      return p;

   if(!GetRates(PERIOD_M1, 1, 8, m1))
      return p;

   double m5EMA20 = 0.0;
   double m5EMA50 = 0.0;
   double m5ATR = 0.0;
   double m5ADX = 0.0;

   double m1EMA9 = 0.0;
   double m1EMA9Prev = 0.0;
   double m1EMA20 = 0.0;
   double m1ATR = 0.0;
   double m1RSI = 0.0;

   if(!CopyVal(hM5EMA20, 0, 1, m5EMA20)) return p;
   if(!CopyVal(hM5EMA50, 0, 1, m5EMA50)) return p;
   if(!CopyVal(hM5ATR, 0, 1, m5ATR)) return p;
   if(!CopyVal(hM5ADX, 0, 1, m5ADX)) return p;

   if(!CopyVal(hM1EMA9, 0, 1, m1EMA9)) return p;
   if(!CopyVal(hM1EMA9, 0, 2, m1EMA9Prev)) return p;
   if(!CopyVal(hM1EMA20, 0, 1, m1EMA20)) return p;
   if(!CopyVal(hM1ATR, 0, 1, m1ATR)) return p;
   if(!CopyVal(hM1RSI, 0, 1, m1RSI)) return p;

   if(m5ATR <= 0.0 || m1ATR <= 0.0)
      return p;

   double avgATR =
      ATRAverage(
         hM5ATR,
         2,
         20
      );

   if(avgATR <= 0.0)
      return p;

   double atrRatio = m5ATR / avgATR;

   if(
      atrRatio < InpScalpATRRatioMin ||
      atrRatio > InpScalpATRRatioMax ||
      m5ADX < InpScalpADXMin
   )
      return p;

   bool buyTrend =
      m5[0].close > m5EMA20 &&
      m5EMA20 > m5EMA50 &&
      MacroVotes("BUY") >= 2;

   bool sellTrend =
      m5[0].close < m5EMA20 &&
      m5EMA20 < m5EMA50 &&
      MacroVotes("SELL") >= 2;

   if(!buyTrend && !sellTrend)
      return p;

   string side =
      buyTrend
      ? "BUY"
      : "SELL";

   bool buy = side == "BUY";

   MqlRates b = m1[0];
   MqlRates prev = m1[1];

   double distanceEMA20 =
      MathAbs(b.close - m1EMA20);

   bool pullbackNear =
      distanceEMA20 <=
      InpScalpMaxPullbackATR * m1ATR;

   bool rejection =
      buy
      ? (
           b.close > b.open &&
           CandleClosePosition(b) >= 0.65 &&
           (MathMin(b.open,b.close) - b.low) >=
           0.40 * MathMax(MathAbs(b.close-b.open), _Point)
        )
      : (
           b.close < b.open &&
           CandleClosePosition(b) <= 0.35 &&
           (b.high - MathMax(b.open,b.close)) >=
           0.40 * MathMax(MathAbs(b.close-b.open), _Point)
        );

   bool emaRecapture =
      buy
      ? (
           b.close > m1EMA9 &&
           prev.close <= m1EMA9Prev &&
           m1RSI >= 50.0
        )
      : (
           b.close < m1EMA9 &&
           prev.close >= m1EMA9Prev &&
           m1RSI <= 50.0
        );

   double priorHigh =
      MathMax(
         m1[1].high,
         MathMax(m1[2].high, m1[3].high)
      );

   double priorLow =
      MathMin(
         m1[1].low,
         MathMin(m1[2].low, m1[3].low)
      );

   bool microBreak =
      buy
      ? b.close > priorHigh
      : b.close < priorLow;

   if(
      !pullbackNear ||
      !(rejection || emaRecapture || microBreak)
   )
      return p;

   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return p;

   double entry =
      buy
      ? tick.ask
      : tick.bid;

   double swing =
      buy
      ? LowestLow(m1, 0, 5)
      : HighestHigh(m1, 0, 5);

   double sl =
      buy
      ? swing - 0.20 * m1ATR
      : swing + 0.20 * m1ATR;

   double risk = MathAbs(entry - sl);

   if(
      risk < 0.20 * m5ATR ||
      risk > 1.20 * m5ATR
   )
      return p;

   double tp =
      buy
      ? entry + InpScalpTargetR * risk
      : entry - InpScalpTargetR * risk;

   p.valid = true;
   p.engine = "PRECISION_SCALP";
   p.side = side;
   p.reason =
      rejection
      ? "REJECTION"
      : emaRecapture
        ? "EMA9_RECAPTURE"
        : "MICRO_BREAK";
   p.entry = NormalizePrice(entry);
   p.sl = NormalizePrice(sl);
   p.tp = NormalizePrice(tp);
   p.risk_percent = InpScalpRiskPercent;

   g_scalpSignals++;

   return p;
}

// ============================================================
// EXECUTION
// ============================================================

bool OpenPlan(TradePlan &p)
{
   if(!p.valid)
      return false;

   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   if(!SpreadAllows(tick))
      return false;

   if(!RiskGuardAllowsNewTrade())
      return false;

   if(!CooldownAllows())
      return false;

   double lot =
      RiskLot(
         p.side,
         p.entry,
         p.sl,
         p.risk_percent
      );

   if(lot <= 0.0)
      return false;

   bool ok = false;

   if(p.side == "BUY")
   {
      ok = trade.Buy(
         lot,
         _Symbol,
         0.0,
         p.sl,
         p.tp,
         p.engine
      );
   }
   else
   {
      ok = trade.Sell(
         lot,
         _Symbol,
         0.0,
         p.sl,
         p.tp,
         p.engine
      );
   }

   if(!ok)
   {
      if(InpLogTrades)
      {
         Print(
            "ORDER FAILED | ",
            p.engine,
            " | ",
            trade.ResultRetcode(),
            " | ",
            trade.ResultRetcodeDescription()
         );
      }

      return false;
   }

   if(!PositionSelect(_Symbol))
      return false;

   g_positionEngine = p.engine;
   g_positionSide = p.side;
   g_entry = PositionGetDouble(POSITION_PRICE_OPEN);
   g_initialSL = p.sl;
   g_initialRisk = MathAbs(g_entry - g_initialSL);
   g_target = p.tp;
   g_positionOpenTime = TimeCurrent();
   g_breakEvenDone = false;

   g_lastEntryTime = TimeCurrent();
   g_tradesToday++;
   g_orders++;

   if(p.engine == "TREND_MOMENTUM")
      g_trendOrders++;
   else if(p.engine == "RANGE_BREAKOUT")
   {
      g_rangeOrders++;
      g_rangeTradedDay = g_dayKey;
   }
   else if(p.engine == "PRECISION_SCALP")
   {
      g_scalpOrders++;
      g_scalpsToday++;
   }

   if(InpLogTrades)
   {
      Print(
         "EXECUTE | engine=",
         p.engine,
         " | side=",
         p.side,
         " | reason=",
         p.reason,
         " | entry=",
         DoubleToString(g_entry, _Digits),
         " | sl=",
         DoubleToString(p.sl, _Digits),
         " | tp=",
         DoubleToString(p.tp, _Digits),
         " | lot=",
         DoubleToString(lot, 2),
         " | risk%=",
         DoubleToString(p.risk_percent, 2)
      );
   }

   return true;
}

bool ModifyPositionSL(double newSL)
{
   if(!PositionSelect(_Symbol))
      return false;

   ulong ticket =
      (ulong)PositionGetInteger(POSITION_TICKET);

   double currentTP =
      PositionGetDouble(POSITION_TP);

   return trade.PositionModify(
      ticket,
      NormalizePrice(newSL),
      NormalizePrice(currentTP)
   );
}

void ManageTrendPosition(
   MqlTick &tick,
   double currentR
)
{
   if(
      g_positionEngine != "TREND_MOMENTUM" ||
      g_initialRisk <= 0.0
   )
      return;

   if(
      TimeCurrent() - g_positionOpenTime >=
      InpTrendMaxHoldHours * 3600
   )
   {
      ulong ticket =
         (ulong)PositionGetInteger(POSITION_TICKET);

      trade.PositionClose(ticket);
      return;
   }

   if(currentR < InpTrendTrailStartR)
      return;

   double atr = 0.0;

   if(!CopyVal(hH1ATR, 0, 1, atr))
      return;

   double candidate =
      g_positionSide == "BUY"
      ? tick.bid - InpTrendTrailATR * atr
      : tick.ask + InpTrendTrailATR * atr;

   double currentSL =
      PositionGetDouble(POSITION_SL);

   if(g_positionSide == "BUY")
   {
      if(
         candidate > currentSL &&
         candidate < tick.bid
      )
         ModifyPositionSL(candidate);
   }
   else
   {
      if(
         (
            currentSL <= 0.0 ||
            candidate < currentSL
         ) &&
         candidate > tick.ask
      )
         ModifyPositionSL(candidate);
   }
}

void ManageRangePosition(
   MqlTick &tick,
   double currentR
)
{
   if(g_positionEngine != "RANGE_BREAKOUT")
      return;

   int nowMin = MinuteOfDay(TimeCurrent());

   int closeMin =
      InpRangeCloseHour * 60 +
      InpRangeCloseMinute;

   if(nowMin >= closeMin)
   {
      ulong ticket =
         (ulong)PositionGetInteger(POSITION_TICKET);

      trade.PositionClose(ticket);
      return;
   }

   if(
      !g_breakEvenDone &&
      currentR >= InpRangeBreakEvenR
   )
   {
      double lock =
         g_positionSide == "BUY"
         ? g_entry + 0.05 * g_initialRisk
         : g_entry - 0.05 * g_initialRisk;

      if(ModifyPositionSL(lock))
         g_breakEvenDone = true;
   }
}

void ManageScalpPosition(
   MqlTick &tick,
   double currentR
)
{
   if(g_positionEngine != "PRECISION_SCALP")
      return;

   if(
      TimeCurrent() - g_positionOpenTime >=
      InpScalpTimeStopMinutes * 60
   )
   {
      ulong ticket =
         (ulong)PositionGetInteger(POSITION_TICKET);

      trade.PositionClose(ticket);
      return;
   }

   if(
      !g_breakEvenDone &&
      currentR >= InpScalpBreakEvenR
   )
   {
      double lock =
         g_positionSide == "BUY"
         ? g_entry + 0.03 * g_initialRisk
         : g_entry - 0.03 * g_initialRisk;

      if(ModifyPositionSL(lock))
         g_breakEvenDone = true;
   }
}

void ManagePosition()
{
   if(!PositionSelect(_Symbol))
   {
      g_positionEngine = "";
      g_positionSide = "";
      g_entry = 0.0;
      g_initialSL = 0.0;
      g_initialRisk = 0.0;
      g_target = 0.0;
      g_positionOpenTime = 0;
      g_breakEvenDone = false;
      return;
   }

   if(g_positionEngine == "")
   {
      g_positionEngine =
         PositionGetString(POSITION_COMMENT);

      long type =
         PositionGetInteger(POSITION_TYPE);

      g_positionSide =
         type == POSITION_TYPE_BUY
         ? "BUY"
         : "SELL";

      g_entry =
         PositionGetDouble(POSITION_PRICE_OPEN);

      g_initialSL =
         PositionGetDouble(POSITION_SL);

      g_initialRisk =
         MathAbs(g_entry - g_initialSL);

      g_target =
         PositionGetDouble(POSITION_TP);

      g_positionOpenTime =
         (datetime)PositionGetInteger(POSITION_TIME);
   }

   if(g_initialRisk <= 0.0)
      return;

   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return;

   double current =
      g_positionSide == "BUY"
      ? tick.bid
      : tick.ask;

   double favorable =
      g_positionSide == "BUY"
      ? current - g_entry
      : g_entry - current;

   double currentR =
      favorable /
      g_initialRisk;

   ManageTrendPosition(tick, currentR);
   ManageRangePosition(tick, currentR);
   ManageScalpPosition(tick, currentR);
}

// ============================================================
// STATUS
// ============================================================

void ShowStatus(string regime, TradePlan &plan)
{
   if(!InpShowStatus)
      return;

   Comment(
      "XAU HYBRID PUBLIC-EDGE BACKTEST v1\n",
      "ROUTER: ",
      regime,
      "\nPLAN: ",
      plan.valid ? plan.engine : "NONE",
      " | ",
      plan.valid ? plan.side : "WAIT",
      "\nREASON: ",
      plan.reason,
      "\nH4 MACRO VOTES B/S: ",
      IntegerToString(MacroVotes("BUY")),
      "/",
      IntegerToString(MacroVotes("SELL")),
      "\nTODAY TRADES: ",
      IntegerToString(g_tradesToday),
      "/",
      IntegerToString(InpMaxTradesPerDay),
      " | SCALPS ",
      IntegerToString(g_scalpsToday),
      "/",
      IntegerToString(InpMaxScalpsPerDay),
      "\nEQUITY: ",
      DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2),
      " | DAY START ",
      DoubleToString(g_dayStartEquity, 2),
      " | PEAK ",
      DoubleToString(g_equityPeak, 2)
   );
}

// ============================================================
// EVENTS
// ============================================================

int OnInit()
{
   if(!MQLInfoInteger(MQL_TESTER))
   {
      Print(
         "TESTER ONLY: XAU_HYBRID_PUBLIC_EDGE_BACKTEST_v1 cannot run outside Strategy Tester."
      );

      return INIT_FAILED;
   }

   if(StringFind(_Symbol, "XAUUSD") < 0)
   {
      Print("This EA is intended for XAUUSD-family symbols.");
      return INIT_FAILED;
   }

   if(_Period != PERIOD_M5)
   {
      Print("Run this hybrid tester on M5.");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   hH4EMA200 = iMA(_Symbol, PERIOD_H4, 200, 0, MODE_EMA, PRICE_CLOSE);
   hH4MACD   = iMACD(_Symbol, PERIOD_H4, 12, 26, 9, PRICE_CLOSE);
   hH4TRIX   = iTriX(_Symbol, PERIOD_H4, 14, PRICE_CLOSE);
   hH4ICHI   = iIchimoku(_Symbol, PERIOD_H4, 9, 26, 52);

   hH1EMA20   = iMA(_Symbol, PERIOD_H1, 20, 0, MODE_EMA, PRICE_CLOSE);
   hH1EMA200  = iMA(_Symbol, PERIOD_H1, 200, 0, MODE_EMA, PRICE_CLOSE);
   hH1ATR     = iATR(_Symbol, PERIOD_H1, 14);
   hH1ADX     = iADX(_Symbol, PERIOD_H1, 14);
   hH1RSI     = iRSI(_Symbol, PERIOD_H1, 14, PRICE_CLOSE);
   hH1CCIFast = iCCI(_Symbol, PERIOD_H1, InpTrendFastCCIPeriod, PRICE_TYPICAL);
   hH1CCISlow = iCCI(_Symbol, PERIOD_H1, InpTrendSlowCCIPeriod, PRICE_TYPICAL);

   hM15ATR = iATR(_Symbol, PERIOD_M15, 14);
   hM15ADX = iADX(_Symbol, PERIOD_M15, 14);

   hM5EMA20 = iMA(_Symbol, PERIOD_M5, 20, 0, MODE_EMA, PRICE_CLOSE);
   hM5EMA50 = iMA(_Symbol, PERIOD_M5, 50, 0, MODE_EMA, PRICE_CLOSE);
   hM5ATR   = iATR(_Symbol, PERIOD_M5, 14);
   hM5ADX   = iADX(_Symbol, PERIOD_M5, 14);

   hM1EMA9  = iMA(_Symbol, PERIOD_M1, 9, 0, MODE_EMA, PRICE_CLOSE);
   hM1EMA20 = iMA(_Symbol, PERIOD_M1, 20, 0, MODE_EMA, PRICE_CLOSE);
   hM1ATR   = iATR(_Symbol, PERIOD_M1, 14);
   hM1RSI   = iRSI(_Symbol, PERIOD_M1, 14, PRICE_CLOSE);

   int handles[] =
   {
      hH4EMA200,
      hH4MACD,
      hH4TRIX,
      hH4ICHI,
      hH1EMA20,
      hH1EMA200,
      hH1ATR,
      hH1ADX,
      hH1RSI,
      hH1CCIFast,
      hH1CCISlow,
      hM15ATR,
      hM15ADX,
      hM5EMA20,
      hM5EMA50,
      hM5ATR,
      hM5ADX,
      hM1EMA9,
      hM1EMA20,
      hM1ATR,
      hM1RSI
   };

   for(int i = 0; i < ArraySize(handles); i++)
   {
      if(handles[i] == INVALID_HANDLE)
      {
         Print("Indicator handle creation failed at index ", i);
         return INIT_FAILED;
      }
   }

   ResetDailyIfNeeded();
   g_equityPeak = AccountInfoDouble(ACCOUNT_EQUITY);

   Print(
      "XAU HYBRID PUBLIC-EDGE BACKTEST v1 initialized | ",
      _Symbol,
      " | chart=M5"
   );

   return INIT_SUCCEEDED;
}

void OnTick()
{
   ResetDailyIfNeeded();
   UpdateEquityPeak();
   ManagePosition();

   if(PositionSelect(_Symbol))
      return;

   // Engine B needs tick-level monitoring once the session range exists.
   string regime = DetectRegime();

   if(regime == "RANGE_BREAKOUT")
   {
      TradePlan rangePlan =
         EvaluateRangeBreakout();

      if(rangePlan.valid)
      {
         ShowStatus(regime, rangePlan);
         OpenPlan(rangePlan);
         return;
      }
   }

   datetime currentM1 =
      iTime(
         _Symbol,
         PERIOD_M1,
         0
      );

   if(currentM1 <= 0)
      return;

   if(currentM1 == g_lastM1Bar)
      return;

   g_lastM1Bar = currentM1;

   TradePlan plan = EmptyPlan();

   if(regime == "TREND")
      plan = EvaluateTrendEngine();
   else if(regime == "SCALP")
      plan = EvaluateScalpEngine();

   ShowStatus(regime, plan);

   if(plan.valid)
      OpenPlan(plan);
}

void OnTradeTransaction(
   const MqlTradeTransaction &trans,
   const MqlTradeRequest &request,
   const MqlTradeResult &result
)
{
   if(
      trans.type != TRADE_TRANSACTION_DEAL_ADD ||
      trans.deal == 0
   )
      return;

   if(!HistoryDealSelect(trans.deal))
      return;

   long magic =
      HistoryDealGetInteger(
         trans.deal,
         DEAL_MAGIC
      );

   if(magic != InpMagicNumber)
      return;

   long entryType =
      HistoryDealGetInteger(
         trans.deal,
         DEAL_ENTRY
      );

   if(
      entryType == DEAL_ENTRY_OUT &&
      !PositionSelect(_Symbol)
   )
   {
      g_positionEngine = "";
      g_positionSide = "";
      g_entry = 0.0;
      g_initialSL = 0.0;
      g_initialRisk = 0.0;
      g_target = 0.0;
      g_positionOpenTime = 0;
      g_breakEvenDone = false;
   }
}

void OnDeinit(const int reason)
{
   Comment("");

   int handles[] =
   {
      hH4EMA200,
      hH4MACD,
      hH4TRIX,
      hH4ICHI,
      hH1EMA20,
      hH1EMA200,
      hH1ATR,
      hH1ADX,
      hH1RSI,
      hH1CCIFast,
      hH1CCISlow,
      hM15ATR,
      hM15ADX,
      hM5EMA20,
      hM5EMA50,
      hM5ATR,
      hM5ADX,
      hM1EMA9,
      hM1EMA20,
      hM1ATR,
      hM1RSI
   };

   for(int i = 0; i < ArraySize(handles); i++)
   {
      if(handles[i] != INVALID_HANDLE)
         IndicatorRelease(handles[i]);
   }

   Print(
      "HYBRID SUMMARY | router trend=",
      g_routerTrend,
      " range=",
      g_routerRange,
      " scalp=",
      g_routerScalp,
      " none=",
      g_routerNone,
      " | signals trend=",
      g_trendSignals,
      " range=",
      g_rangeSignals,
      " scalp=",
      g_scalpSignals,
      " | orders total=",
      g_orders,
      " trend=",
      g_trendOrders,
      " range=",
      g_rangeOrders,
      " scalp=",
      g_scalpOrders,
      " | risk_blocks=",
      g_riskBlocks,
      " spread_blocks=",
      g_spreadBlocks,
      " cooldown_blocks=",
      g_cooldownBlocks
   );
}
