// XAU MARKET ZONES BACKTEST v2 STRICT TRADABLE ZONES
// SEPARATE Strategy Tester build. Does NOT modify or depend on the live EA.
// Reconstructs the live R1/Worker zones locally from CLOSED historical candles,
// keeps LOCKED zone identity, uses the same simple M5 confirmation concept,
// opens tester-only trades, attaches actual SL/TP, and runs the active manager.
//
// IMPORTANT:
// - Tester only. Refuses to initialize on a normal/live chart.
// - No WebRequest / Worker dependency.
// - R2 is intentionally NOT used as an entry gate because the current live
//   v2.9 treats R2 as "CAUTION ONLY" after the simple-decision redesign.
// - Local zone refresh is once per closed M1 bar. This avoids look-ahead and
//   approximates the live Worker refresh while keeping a one-year test practical.
// - IMPORTANT v2 correction: WATCH_TRANSITION and WATCH_HIGH_VOLATILITY zones
//   are observation zones only. They cannot generate READY/entries by default.
//   This directly tests whether the true tradable regimes have edge.

#property strict

#include <Trade/Trade.mqh>
CTrade trade;

// ============================================================
// INPUTS
// ============================================================

input double InpLot = 0.01;
input int    InpEntriesPerReadySignal = 1;
input int    InpMaxOpenPositions = 1;
input long   InpMagicNumber = 26101301;
input int    InpMaxDeviationPoints = 50;

// Live simple-decision equivalents.
input int    InpConfirmLookbackM5Bars = 3;
input double InpRR = 2.0;
input double InpSLBufferZoneFraction = 0.25;

// Active manager equivalents from live v2.9.
input bool   InpEnableTradeManager = true;
input bool   InpEnablePartialClose = true;
input double InpPartialAtR = 1.0;
input double InpPartialClosePercent = 50.0;
input bool   InpMoveToBE = true;
input double InpBEAtR = 1.0;
input double InpBEPlusR = 0.05;
input bool   InpEnableTrailing = true;
input double InpTrailStartR = 1.5;
input double InpTrailGapR = 0.50;
input double InpTrailStepR = 0.25;

// Test controls.
input bool   InpOneSignalPerM5Bar = true;
input bool   InpPrintSignalJournal = true;

// Worker semantics: WATCH_* zones are analysis/observation only.
// Keep false for the strict test. Turning this true recreates v1 behavior.
input bool   InpTradeWatchOnlyZones = false;

// ============================================================
// DATA STRUCTURES
// ============================================================

struct TFMetrics
{
   bool valid;

   double close;
   double previous_close;

   double ema9;
   double ema20;
   double ema50;

   double rsi14;
   double atr14;
   double atr_ratio;

   double ema_sep_atr;
   double ema20_slope_atr;

   double high20;
   double low20;
   double previous_high20;
   double previous_low20;

   double range_width_atr;
   int upper_touches;
   int lower_touches;

   double last_range;
   double body;
   double close_position;

   datetime candle_time;
};

struct RawZones
{
   bool valid;

   string regime;
   string strategy;
   bool watch_only;
   string zone_type;

   bool has_buy;
   double buy_low;
   double buy_high;
   double buy_invalidation;
   ENUM_TIMEFRAMES buy_invalidation_tf;

   bool has_sell;
   double sell_low;
   double sell_high;
   double sell_invalidation;
   ENUM_TIMEFRAMES sell_invalidation_tf;
};

struct LockedZone
{
   bool active;
   string side;

   double low;
   double high;
   double invalidation;
   ENUM_TIMEFRAMES invalidation_tf;

   string source_regime;
   string source_strategy;
   datetime created_at;
};

// ============================================================
// GLOBALS
// ============================================================

LockedZone g_buyZone;
LockedZone g_sellZone;

datetime g_lastM1Bar = 0;
datetime g_lastM5Bar = 0;
string g_lastTradedSignalKey = "";

bool g_basketSeenOpen = false;
bool g_tp1Done = false;

long g_zoneRefreshes = 0;
long g_zoneAdoptions = 0;
long g_watchZonesSkipped = 0;
long g_zoneInvalidations = 0;
long g_readySignals = 0;
long g_ordersOpened = 0;
long g_orderFailures = 0;
long g_tp1Events = 0;
long g_beMoves = 0;
long g_trailMoves = 0;

// ============================================================
// BASIC HELPERS
// ============================================================

double NPrice(double value)
{
   return NormalizeDouble(value, _Digits);
}

bool ValidZone(double low, double high)
{
   return
      MathIsValidNumber(low) &&
      MathIsValidNumber(high) &&
      low > 0.0 &&
      high > low;
}

void ResetLockedZone(LockedZone &z)
{
   z.active = false;
   z.side = "";
   z.low = 0.0;
   z.high = 0.0;
   z.invalidation = 0.0;
   z.invalidation_tf = PERIOD_M5;
   z.source_regime = "";
   z.source_strategy = "";
   z.created_at = 0;
}

bool IsXAUFamily()
{
   return StringFind(_Symbol, "XAUUSD") >= 0;
}

datetime ClosedBarTime(ENUM_TIMEFRAMES tf)
{
   return (datetime)iTime(_Symbol, tf, 1);
}

// ============================================================
// ARRAY / INDICATOR MATH MATCHING WORKER
// ============================================================

double Median(double &values[])
{
   int n = ArraySize(values);
   if(n <= 0)
      return 0.0;

   double copy[];
   ArrayResize(copy, n);

   for(int i = 0; i < n; i++)
      copy[i] = values[i];

   ArraySort(copy);

   int middle = n / 2;

   if((n % 2) == 0)
      return (copy[middle - 1] + copy[middle]) / 2.0;

   return copy[middle];
}

void BuildEMA(double &values[], int period, double &out[])
{
   int n = ArraySize(values);
   ArrayResize(out, n);

   if(n <= 0)
      return;

   double multiplier = 2.0 / (period + 1.0);
   double current = values[0];

   out[0] = current;

   for(int i = 1; i < n; i++)
   {
      current =
         values[i] * multiplier +
         current * (1.0 - multiplier);

      out[i] = current;
   }
}

double ATRPrefix(MqlRates &bars[], int endExclusive, int period)
{
   if(endExclusive < period + 1)
      return 0.0;

   int trCount = endExclusive - 1;
   if(trCount < period)
      return 0.0;

   double current = 0.0;

   for(int i = 1; i <= period; i++)
   {
      double high = bars[i].high;
      double low = bars[i].low;
      double prevClose = bars[i - 1].close;

      double tr =
         MathMax(
            high - low,
            MathMax(
               MathAbs(high - prevClose),
               MathAbs(low - prevClose)
            )
         );

      current += tr;
   }

   current /= period;

   for(int i = period + 1; i < endExclusive; i++)
   {
      double high = bars[i].high;
      double low = bars[i].low;
      double prevClose = bars[i - 1].close;

      double tr =
         MathMax(
            high - low,
            MathMax(
               MathAbs(high - prevClose),
               MathAbs(low - prevClose)
            )
         );

      current =
         (
            current * (period - 1) +
            tr
         ) / period;
   }

   return current;
}

double RSIWorker(double &values[], int period)
{
   int n = ArraySize(values);

   if(n <= period)
      return 50.0;

   double gain = 0.0;
   double loss = 0.0;

   for(int i = 1; i <= period; i++)
   {
      double change = values[i] - values[i - 1];

      if(change >= 0.0)
         gain += change;
      else
         loss += -change;
   }

   double avgGain = gain / period;
   double avgLoss = loss / period;

   for(int i = period + 1; i < n; i++)
   {
      double change = values[i] - values[i - 1];
      double currentGain = change > 0.0 ? change : 0.0;
      double currentLoss = change < 0.0 ? -change : 0.0;

      avgGain =
         (
            avgGain * (period - 1) +
            currentGain
         ) / period;

      avgLoss =
         (
            avgLoss * (period - 1) +
            currentLoss
         ) / period;
   }

   if(avgLoss == 0.0)
      return 100.0;

   double rs = avgGain / avgLoss;

   return 100.0 - 100.0 / (1.0 + rs);
}

bool BuildMetrics(ENUM_TIMEFRAMES tf, TFMetrics &m)
{
   m.valid = false;

   MqlRates series[];
   ArraySetAsSeries(series, true);

   int copied =
      CopyRates(
         _Symbol,
         tf,
         1,
         120,
         series
      );

   if(copied < 60)
      return false;

   // Convert to chronological order, oldest -> newest, matching Worker arrays.
   MqlRates bars[];
   ArrayResize(bars, copied);

   for(int i = 0; i < copied; i++)
      bars[i] = series[copied - 1 - i];

   double closes[];
   ArrayResize(closes, copied);

   for(int i = 0; i < copied; i++)
      closes[i] = bars[i].close;

   double ema9Series[];
   double ema20Series[];
   double ema50Series[];

   BuildEMA(closes, 9, ema9Series);
   BuildEMA(closes, 20, ema20Series);
   BuildEMA(closes, 50, ema50Series);

   double currentAtr =
      ATRPrefix(
         bars,
         copied,
         14
      );

   if(currentAtr <= 0.0)
      return false;

   // Worker rollingAtrValues(...,14,31), then removes the latest point.
   double atrHistory[];
   int atrCount = 0;

   int minimumBars = 15;
   int start =
      MathMax(
         minimumBars,
         copied - 31 + 1
      );

   for(int end = start; end <= copied; end++)
   {
      double value =
         ATRPrefix(
            bars,
            end,
            14
         );

      if(value > 0.0)
      {
         ArrayResize(atrHistory, atrCount + 1);
         atrHistory[atrCount] = value;
         atrCount++;
      }
   }

   // Remove current ATR from historical median source.
   if(atrCount > 1)
      ArrayResize(atrHistory, atrCount - 1);

   double medianAtr =
      Median(atrHistory);

   double atrRatio =
      medianAtr > 0.0
      ? currentAtr / medianAtr
      : 1.0;

   double rsi14 =
      RSIWorker(
         closes,
         14
      );

   double ema20SlopeAtr = 0.0;

   if(
      copied >= 6 &&
      currentAtr > 0.0
   )
   {
      ema20SlopeAtr =
         (
            ema20Series[copied - 1] -
            ema20Series[copied - 6]
         ) / currentAtr;
   }

   int recentStart = copied - 20;
   int previousStart = copied - 21;

   if(previousStart < 0)
      return false;

   double high20 = bars[recentStart].high;
   double low20 = bars[recentStart].low;

   for(int i = recentStart; i < copied; i++)
   {
      high20 = MathMax(high20, bars[i].high);
      low20 = MathMin(low20, bars[i].low);
   }

   double previousHigh20 = bars[previousStart].high;
   double previousLow20 = bars[previousStart].low;

   for(int i = previousStart; i <= copied - 2; i++)
   {
      previousHigh20 = MathMax(previousHigh20, bars[i].high);
      previousLow20 = MathMin(previousLow20, bars[i].low);
   }

   double rangeWidth = high20 - low20;
   double rangeWidthAtr =
      currentAtr > 0.0
      ? rangeWidth / currentAtr
      : 0.0;

   double touchTolerance =
      currentAtr * 0.25;

   int upperTouches = 0;
   int lowerTouches = 0;

   for(int i = recentStart; i < copied; i++)
   {
      if(MathAbs(bars[i].high - high20) <= touchTolerance)
         upperTouches++;

      if(MathAbs(bars[i].low - low20) <= touchTolerance)
         lowerTouches++;
   }

   MqlRates last = bars[copied - 1];
   MqlRates previous = bars[copied - 2];

   double lastRange = last.high - last.low;
   double body = MathAbs(last.close - last.open);
   double closePosition = 0.5;

   if(lastRange > 0.0)
      closePosition = (last.close - last.low) / lastRange;

   double ema20 = ema20Series[copied - 1];
   double ema50 = ema50Series[copied - 1];

   double emaSepAtr =
      currentAtr > 0.0
      ? MathAbs(ema20 - ema50) / currentAtr
      : 0.0;

   m.close = last.close;
   m.previous_close = previous.close;
   m.ema9 = ema9Series[copied - 1];
   m.ema20 = ema20;
   m.ema50 = ema50;
   m.rsi14 = rsi14;
   m.atr14 = currentAtr;
   m.atr_ratio = atrRatio;
   m.ema_sep_atr = emaSepAtr;
   m.ema20_slope_atr = ema20SlopeAtr;
   m.high20 = high20;
   m.low20 = low20;
   m.previous_high20 = previousHigh20;
   m.previous_low20 = previousLow20;
   m.range_width_atr = rangeWidthAtr;
   m.upper_touches = upperTouches;
   m.lower_touches = lowerTouches;
   m.last_range = lastRange;
   m.body = body;
   m.close_position = closePosition;
   m.candle_time = last.time;
   m.valid = true;

   return true;
}

// ============================================================
// LOCAL R1 REGIME + ZONE RECONSTRUCTION
// ============================================================

bool BuildRawZones(RawZones &z)
{
   z.valid = false;
   z.has_buy = false;
   z.has_sell = false;
   z.watch_only = false;
   z.regime = "TRANSITION";
   z.strategy = "NONE";
   z.zone_type = "AUTO_R1";

   TFMetrics h1, m30, m15, m5, m1;

   if(
      !BuildMetrics(PERIOD_H1, h1) ||
      !BuildMetrics(PERIOD_M30, m30) ||
      !BuildMetrics(PERIOD_M15, m15) ||
      !BuildMetrics(PERIOD_M5, m5) ||
      !BuildMetrics(PERIOD_M1, m1)
   )
      return false;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   bool highVolatility =
      (
         m5.atr_ratio >= 1.80
      ) ||
      (
         m5.last_range >=
         m5.atr14 * 2.20
      );

   bool breakoutUp =
      (
         m5.close >
         m5.previous_high20 +
         m5.atr14 * 0.10
      ) &&
      (
         m5.body >=
         m5.atr14 * 0.55
      ) &&
      (
         m5.close_position >= 0.75
      ) &&
      (
         m15.close > m15.ema20
      );

   bool breakoutDown =
      (
         m5.close <
         m5.previous_low20 -
         m5.atr14 * 0.10
      ) &&
      (
         m5.body >=
         m5.atr14 * 0.55
      ) &&
      (
         m5.close_position <= 0.25
      ) &&
      (
         m15.close < m15.ema20
      );

   bool trendUp =
      h1.close > h1.ema20 &&
      h1.ema20 > h1.ema50 &&
      h1.ema20_slope_atr > 0.05 &&
      m30.close > m30.ema20 &&
      m30.ema20 > m30.ema50 &&
      m30.ema20_slope_atr > 0.05 &&
      m15.close > m15.ema20 &&
      m15.rsi14 >= 52.0;

   bool trendDown =
      h1.close < h1.ema20 &&
      h1.ema20 < h1.ema50 &&
      h1.ema20_slope_atr < -0.05 &&
      m30.close < m30.ema20 &&
      m30.ema20 < m30.ema50 &&
      m30.ema20_slope_atr < -0.05 &&
      m15.close < m15.ema20 &&
      m15.rsi14 <= 48.0;

   bool rangeState =
      m30.ema_sep_atr < 0.25 &&
      MathAbs(m30.ema20_slope_atr) < 0.10 &&
      m30.rsi14 >= 43.0 &&
      m30.rsi14 <= 57.0 &&
      m30.range_width_atr >= 2.0 &&
      m30.range_width_atr <= 6.0 &&
      m30.upper_touches >= 2 &&
      m30.lower_touches >= 2;

   if(highVolatility)
   {
      z.regime = "HIGH_VOLATILITY";
      z.strategy = "NO_TRADE";
   }
   else if(breakoutUp)
   {
      z.regime = "BREAKOUT_UP";
      z.strategy = "BREAKOUT_RETEST_BUY";
   }
   else if(breakoutDown)
   {
      z.regime = "BREAKOUT_DOWN";
      z.strategy = "BREAKOUT_RETEST_SELL";
   }
   else if(trendUp)
   {
      z.regime = "TREND_UP";
      z.strategy = "TREND_PULLBACK_BUY";
   }
   else if(trendDown)
   {
      z.regime = "TREND_DOWN";
      z.strategy = "TREND_PULLBACK_SELL";
   }
   else if(rangeState)
   {
      z.regime = "RANGE";
      z.strategy = "RANGE_REVERSION";
   }

   if(
      z.regime == "HIGH_VOLATILITY" ||
      z.strategy == "NO_TRADE"
   )
   {
      z.watch_only = true;
      z.zone_type = "WATCH_HIGH_VOLATILITY";

      bool bearishImpulse =
         m1.close < m1.ema9 &&
         m5.close < m5.ema20;

      bool bullishImpulse =
         m1.close > m1.ema9 &&
         m5.close > m5.ema20;

      if(bearishImpulse)
      {
         z.has_sell = true;
         z.sell_low = NPrice(m1.ema9 - 0.35 * m1.atr14);
         z.sell_high = NPrice(m1.ema9 + 0.35 * m1.atr14);
         z.sell_invalidation = NPrice(MathMax(m1.high20, m1.ema9 + 0.75 * m1.atr14));
         z.sell_invalidation_tf = PERIOD_M1;

         z.has_buy = true;
         z.buy_low = NPrice(m1.low20);
         z.buy_high = NPrice(m1.low20 + 0.60 * m1.atr14);
         z.buy_invalidation = NPrice(m1.low20 - 0.25 * m1.atr14);
         z.buy_invalidation_tf = PERIOD_M1;
      }
      else if(bullishImpulse)
      {
         z.has_buy = true;
         z.buy_low = NPrice(m1.ema9 - 0.35 * m1.atr14);
         z.buy_high = NPrice(m1.ema9 + 0.35 * m1.atr14);
         z.buy_invalidation = NPrice(MathMin(m1.low20, m1.ema9 - 0.75 * m1.atr14));
         z.buy_invalidation_tf = PERIOD_M1;

         z.has_sell = true;
         z.sell_low = NPrice(m1.high20 - 0.60 * m1.atr14);
         z.sell_high = NPrice(m1.high20);
         z.sell_invalidation = NPrice(m1.high20 + 0.25 * m1.atr14);
         z.sell_invalidation_tf = PERIOD_M1;
      }
      else
      {
         z.has_buy = true;
         z.buy_low = NPrice(m1.low20);
         z.buy_high = NPrice(m1.low20 + 0.50 * m1.atr14);
         z.buy_invalidation = NPrice(m1.low20 - 0.25 * m1.atr14);
         z.buy_invalidation_tf = PERIOD_M1;

         z.has_sell = true;
         z.sell_low = NPrice(m1.high20 - 0.50 * m1.atr14);
         z.sell_high = NPrice(m1.high20);
         z.sell_invalidation = NPrice(m1.high20 + 0.25 * m1.atr14);
         z.sell_invalidation_tf = PERIOD_M1;
      }
   }
   else if(
      z.regime == "TRANSITION" ||
      z.strategy == "NONE"
   )
   {
      z.watch_only = true;
      z.zone_type = "WATCH_TRANSITION";

      z.has_buy = true;
      z.buy_low = NPrice(m5.low20);
      z.buy_high = NPrice(m5.low20 + 0.35 * m5.atr14);
      z.buy_invalidation = NPrice(m5.low20 - 0.25 * m5.atr14);
      z.buy_invalidation_tf = PERIOD_M5;

      z.has_sell = true;
      z.sell_low = NPrice(m5.high20 - 0.35 * m5.atr14);
      z.sell_high = NPrice(m5.high20);
      z.sell_invalidation = NPrice(m5.high20 + 0.25 * m5.atr14);
      z.sell_invalidation_tf = PERIOD_M5;
   }
   else if(z.strategy == "TREND_PULLBACK_BUY")
   {
      double ref =
         MathAbs(tick.ask - m5.ema20) <=
         MathAbs(tick.ask - m5.ema50)
         ? m5.ema20
         : m5.ema50;

      z.has_buy = true;
      z.buy_low = NPrice(ref - 0.45 * m5.atr14);
      z.buy_high = NPrice(ref + 0.45 * m5.atr14);
      z.buy_invalidation =
         NPrice(
            MathMin(m5.low20, m30.low20) -
            0.20 * m5.atr14
         );
      z.buy_invalidation_tf = PERIOD_M5;
   }
   else if(z.strategy == "TREND_PULLBACK_SELL")
   {
      double ref =
         MathAbs(tick.bid - m5.ema20) <=
         MathAbs(tick.bid - m5.ema50)
         ? m5.ema20
         : m5.ema50;

      z.has_sell = true;
      z.sell_low = NPrice(ref - 0.45 * m5.atr14);
      z.sell_high = NPrice(ref + 0.45 * m5.atr14);
      z.sell_invalidation =
         NPrice(
            MathMax(m5.high20, m30.high20) +
            0.20 * m5.atr14
         );
      z.sell_invalidation_tf = PERIOD_M5;
   }
   else if(z.strategy == "BREAKOUT_RETEST_BUY")
   {
      double level = m5.previous_high20;

      z.has_buy = true;
      z.buy_low = NPrice(level - 0.15 * m5.atr14);
      z.buy_high = NPrice(level + 0.45 * m5.atr14);
      z.buy_invalidation =
         NPrice(
            MathMin(
               m5.low20,
               level - 0.45 * m5.atr14
            )
         );
      z.buy_invalidation_tf = PERIOD_M5;
   }
   else if(z.strategy == "BREAKOUT_RETEST_SELL")
   {
      double level = m5.previous_low20;

      z.has_sell = true;
      z.sell_low = NPrice(level - 0.45 * m5.atr14);
      z.sell_high = NPrice(level + 0.15 * m5.atr14);
      z.sell_invalidation =
         NPrice(
            MathMax(
               m5.high20,
               level + 0.45 * m5.atr14
            )
         );
      z.sell_invalidation_tf = PERIOD_M5;
   }
   else if(z.strategy == "RANGE_REVERSION")
   {
      double width = m30.high20 - m30.low20;

      z.has_buy = true;
      z.buy_low = NPrice(m30.low20);
      z.buy_high = NPrice(m30.low20 + 0.20 * width);
      z.buy_invalidation = NPrice(m30.low20 - 0.25 * m5.atr14);
      z.buy_invalidation_tf = PERIOD_M5;

      z.has_sell = true;
      z.sell_low = NPrice(m30.high20 - 0.20 * width);
      z.sell_high = NPrice(m30.high20);
      z.sell_invalidation = NPrice(m30.high20 + 0.25 * m5.atr14);
      z.sell_invalidation_tf = PERIOD_M5;
   }

   z.valid = z.has_buy || z.has_sell;
   return z.valid;
}

// ============================================================
// LOCKED ZONE LIFECYCLE
// ============================================================

bool RawZoneAlreadyInvalidated(
   string side,
   double invalidation,
   ENUM_TIMEFRAMES tf
)
{
   if(invalidation <= 0.0)
      return false;

   double closedPrice = iClose(_Symbol, tf, 1);

   if(closedPrice <= 0.0)
      return false;

   if(side == "BUY")
      return closedPrice < invalidation;

   return closedPrice > invalidation;
}

void AdoptZone(
   LockedZone &dest,
   string side,
   double low,
   double high,
   double invalidation,
   ENUM_TIMEFRAMES tf,
   string regime,
   string strategy
)
{
   if(
      dest.active ||
      !ValidZone(low, high) ||
      RawZoneAlreadyInvalidated(side, invalidation, tf)
   )
      return;

   dest.active = true;
   dest.side = side;
   dest.low = low;
   dest.high = high;
   dest.invalidation = invalidation;
   dest.invalidation_tf = tf;
   dest.source_regime = regime;
   dest.source_strategy = strategy;
   dest.created_at = TimeCurrent();

   g_zoneAdoptions++;

   if(InpPrintSignalJournal)
   {
      Print(
         "ZONE LOCKED | ",
         side,
         " | ",
         DoubleToString(low, _Digits),
         "-",
         DoubleToString(high, _Digits),
         " | fail=",
         DoubleToString(invalidation, _Digits),
         " | ",
         regime,
         " / ",
         strategy
      );
   }
}

void EvaluateZoneInvalidation(LockedZone &z)
{
   if(!z.active || z.invalidation <= 0.0)
      return;

   double closedPrice =
      iClose(
         _Symbol,
         z.invalidation_tf,
         1
      );

   if(closedPrice <= 0.0)
      return;

   bool invalid =
      z.side == "BUY"
      ? closedPrice < z.invalidation
      : closedPrice > z.invalidation;

   if(!invalid)
      return;

   if(InpPrintSignalJournal)
   {
      Print(
         "ZONE INVALIDATED | ",
         z.side,
         " | close=",
         DoubleToString(closedPrice, _Digits),
         " | fail=",
         DoubleToString(z.invalidation, _Digits)
      );
   }

   g_zoneInvalidations++;
   ResetLockedZone(z);
}

void RefreshLocalZones()
{
   EvaluateZoneInvalidation(g_buyZone);
   EvaluateZoneInvalidation(g_sellZone);

   RawZones raw;

   if(!BuildRawZones(raw))
      return;

   // v2 strict gate:
   // Worker labels HIGH_VOLATILITY / TRANSITION areas as WATCH only.
   // They must not become locked tradable zones unless explicitly requested.
   if(
      raw.watch_only &&
      !InpTradeWatchOnlyZones
   )
   {
      g_watchZonesSkipped++;
      g_zoneRefreshes++;

      if(
         InpPrintSignalJournal &&
         (g_watchZonesSkipped <= 10 || (g_watchZonesSkipped % 500) == 0)
      )
      {
         Print(
            "WATCH ZONE SKIPPED | ",
            raw.zone_type,
            " | ",
            raw.regime,
            " / ",
            raw.strategy
         );
      }

      return;
   }

   if(
      !g_buyZone.active &&
      raw.has_buy
   )
   {
      AdoptZone(
         g_buyZone,
         "BUY",
         raw.buy_low,
         raw.buy_high,
         raw.buy_invalidation,
         raw.buy_invalidation_tf,
         raw.regime,
         raw.strategy
      );
   }

   if(
      !g_sellZone.active &&
      raw.has_sell
   )
   {
      AdoptZone(
         g_sellZone,
         "SELL",
         raw.sell_low,
         raw.sell_high,
         raw.sell_invalidation,
         raw.sell_invalidation_tf,
         raw.regime,
         raw.strategy
      );
   }

   g_zoneRefreshes++;
}

// ============================================================
// SIMPLE DECISION / M5 CONFIRMATION
// ============================================================

bool PriceInsideLockedZone(string side)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   double mid = (tick.bid + tick.ask) / 2.0;

   if(side == "BUY")
      return g_buyZone.active && mid >= g_buyZone.low && mid <= g_buyZone.high;

   if(side == "SELL")
      return g_sellZone.active && mid >= g_sellZone.low && mid <= g_sellZone.high;

   return false;
}

bool BarTouches(MqlRates &bar, LockedZone &z)
{
   if(!z.active)
      return false;

   return
      bar.high >= z.low &&
      bar.low <= z.high;
}

string MostRecentTouchedZoneSide()
{
   MqlRates bars[];
   ArraySetAsSeries(bars, true);

   int lookback =
      MathMax(
         1,
         InpConfirmLookbackM5Bars
      );

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
         g_buyZone.active &&
         BarTouches(bars[i], g_buyZone)
      )
         buyTouch = bars[i].time;

      if(
         sellTouch == 0 &&
         g_sellZone.active &&
         BarTouches(bars[i], g_sellZone)
      )
         sellTouch = bars[i].time;

      if(buyTouch > 0 && sellTouch > 0)
         break;
   }

   if(buyTouch == 0 && sellTouch == 0)
      return "NONE";

   return
      buyTouch >= sellTouch
      ? "BUY"
      : "SELL";
}

double DistanceToZone(LockedZone &z)
{
   if(!z.active)
      return DBL_MAX;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return DBL_MAX;

   double mid = (tick.bid + tick.ask) / 2.0;

   if(mid < z.low)
      return z.low - mid;

   if(mid > z.high)
      return mid - z.high;

   return 0.0;
}

string SimpleActionSide()
{
   bool insideBuy = PriceInsideLockedZone("BUY");
   bool insideSell = PriceInsideLockedZone("SELL");

   if(insideBuy && !insideSell)
      return "BUY";

   if(insideSell && !insideBuy)
      return "SELL";

   string recent = MostRecentTouchedZoneSide();

   if(recent == "BUY" || recent == "SELL")
      return recent;

   double buyDistance = DistanceToZone(g_buyZone);
   double sellDistance = DistanceToZone(g_sellZone);

   if(buyDistance == DBL_MAX && sellDistance == DBL_MAX)
      return "NONE";

   return
      buyDistance <= sellDistance
      ? "BUY"
      : "SELL";
}

bool SimpleM5Confirmation(
   string side,
   string &reason,
   datetime &signalBarTime
)
{
   reason = "NONE";
   signalBarTime = 0;

   LockedZone zone;

   if(side == "BUY")
      zone = g_buyZone;
   else if(side == "SELL")
      zone = g_sellZone;
   else
      return false;

   if(!zone.active)
      return false;

   int lookback =
      MathMax(
         1,
         InpConfirmLookbackM5Bars
      );

   MqlRates bars[];
   ArraySetAsSeries(bars, true);

   int copied =
      CopyRates(
         _Symbol,
         PERIOD_M5,
         1,
         lookback + 2,
         bars
      );

   if(copied < 2)
      return false;

   bool recentTouch = false;

   int maxTouch =
      MathMin(
         lookback - 1,
         copied - 1
      );

   for(int i = 0; i <= maxTouch; i++)
   {
      if(BarTouches(bars[i], zone))
      {
         recentTouch = true;
         break;
      }
   }

   if(!recentTouch)
      return false;

   MqlRates last = bars[0];
   MqlRates prev = bars[1];

   double mid =
      (zone.low + zone.high) / 2.0;

   if(BarTouches(last, zone))
   {
      if(side == "BUY" && last.close > zone.high)
      {
         reason = "M5_BULLISH_REJECTION";
         signalBarTime = last.time;
         return true;
      }

      if(side == "SELL" && last.close < zone.low)
      {
         reason = "M5_BEARISH_REJECTION";
         signalBarTime = last.time;
         return true;
      }
   }

   if(
      side == "BUY" &&
      last.close > last.open &&
      last.close >= mid
   )
   {
      reason = "M5_BULLISH_CLOSE";
      signalBarTime = last.time;
      return true;
   }

   if(
      side == "SELL" &&
      last.close < last.open &&
      last.close <= mid
   )
   {
      reason = "M5_BEARISH_CLOSE";
      signalBarTime = last.time;
      return true;
   }

   if(
      side == "BUY" &&
      last.close > prev.high
   )
   {
      reason = "M5_BREAK_PREVIOUS_HIGH";
      signalBarTime = last.time;
      return true;
   }

   if(
      side == "SELL" &&
      last.close < prev.low
   )
   {
      reason = "M5_BREAK_PREVIOUS_LOW";
      signalBarTime = last.time;
      return true;
   }

   return false;
}

// ============================================================
// TESTER ENTRY / EXECUTION
// ============================================================

int CountOurOpenPositions()
{
   int count = 0;
   int total = PositionsTotal();

   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      count++;
   }

   return count;
}

double NormalizeLot(double lot)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(step <= 0.0)
      step = 0.01;

   lot =
      MathFloor(lot / step + 1e-8) * step;

   lot =
      MathMax(
         minLot,
         MathMin(maxLot, lot)
      );

   int digits = 2;
   if(step < 0.01)
      digits = 3;

   return NormalizeDouble(lot, digits);
}

bool BuildEntryPlan(
   string side,
   double &entry,
   double &sl,
   double &tp
)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   LockedZone zone;

   if(side == "BUY")
      zone = g_buyZone;
   else if(side == "SELL")
      zone = g_sellZone;
   else
      return false;

   if(!zone.active)
      return false;

   entry =
      side == "BUY"
      ? tick.ask
      : tick.bid;

   double zoneWidth =
      MathMax(
         zone.high - zone.low,
         _Point * 10.0
      );

   double slBuffer =
      MathMax(
         zoneWidth * InpSLBufferZoneFraction,
         _Point * 10.0
      );

   if(side == "BUY")
      sl = NPrice(zone.invalidation - slBuffer);
   else
      sl = NPrice(zone.invalidation + slBuffer);

   double risk = MathAbs(entry - sl);

   if(risk <= _Point)
      return false;

   if(side == "BUY")
   {
      if(sl >= entry)
         return false;

      tp = NPrice(entry + risk * InpRR);
   }
   else
   {
      if(sl <= entry)
         return false;

      tp = NPrice(entry - risk * InpRR);
   }

   return true;
}

bool OpenTesterTrade(
   string side,
   string reason,
   datetime signalBarTime
)
{
   if(CountOurOpenPositions() >= InpMaxOpenPositions)
      return false;

   string key =
      side + "_" +
      IntegerToString((long)signalBarTime);

   if(
      InpOneSignalPerM5Bar &&
      key == g_lastTradedSignalKey
   )
      return false;

   double entry = 0.0;
   double sl = 0.0;
   double tp = 0.0;

   if(!BuildEntryPlan(side, entry, sl, tp))
      return false;

   double lot = NormalizeLot(InpLot);

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpMaxDeviationPoints);

   int entries =
      MathMax(
         1,
         InpEntriesPerReadySignal
      );

   bool openedAny = false;

   for(int n = 0; n < entries; n++)
   {
      if(CountOurOpenPositions() >= InpMaxOpenPositions)
         break;

      bool ok =
         side == "BUY"
         ? trade.Buy(
              lot,
              _Symbol,
              0.0,
              sl,
              tp,
              "LOCAL_REPLAY_" + reason
           )
         : trade.Sell(
              lot,
              _Symbol,
              0.0,
              sl,
              tp,
              "LOCAL_REPLAY_" + reason
           );

      if(ok)
      {
         openedAny = true;
         g_ordersOpened++;
      }
      else
      {
         g_orderFailures++;

         if(InpPrintSignalJournal)
         {
            Print(
               "ORDER FAILED | ",
               side,
               " | retcode=",
               trade.ResultRetcode(),
               " | ",
               trade.ResultRetcodeDescription()
            );
         }
      }
   }

   if(openedAny)
   {
      g_lastTradedSignalKey = key;
      g_tp1Done = false;
      g_basketSeenOpen = true;

      if(InpPrintSignalJournal)
      {
         Print(
            "READY -> OPEN | ",
            side,
            " | reason=",
            reason,
            " | entry=",
            DoubleToString(entry, _Digits),
            " | SL=",
            DoubleToString(sl, _Digits),
            " | TP=",
            DoubleToString(tp, _Digits)
         );
      }
   }

   return openedAny;
}

void EvaluateAndTrade()
{
   if(CountOurOpenPositions() >= InpMaxOpenPositions)
      return;

   string side = SimpleActionSide();

   if(side != "BUY" && side != "SELL")
      return;

   if(!InpTradeWatchOnlyZones)
   {
      LockedZone selected =
         side == "BUY"
         ? g_buyZone
         : g_sellZone;

      if(
         selected.source_strategy == "NONE" ||
         selected.source_strategy == "NO_TRADE" ||
         selected.source_regime == "TRANSITION" ||
         selected.source_regime == "HIGH_VOLATILITY"
      )
      {
         return;
      }
   }

   string reason;
   datetime signalBarTime = 0;

   if(
      !SimpleM5Confirmation(
         side,
         reason,
         signalBarTime
      )
   )
      return;

   g_readySignals++;

   OpenTesterTrade(
      side,
      reason,
      signalBarTime
   );
}

// ============================================================
// ACTIVE TRADE MANAGER
// ============================================================

double InitialRiskForSelectedPosition()
{
   double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   double tp = PositionGetDouble(POSITION_TP);

   if(
      entry > 0.0 &&
      tp > 0.0 &&
      InpRR > 0.0
   )
      return MathAbs(tp - entry) / InpRR;

   return 0.0;
}

double PositionR(string side, double entry, double risk, MqlTick &tick)
{
   if(risk <= _Point)
      return -999.0;

   double favorable =
      side == "BUY"
      ? tick.bid - entry
      : entry - tick.ask;

   return favorable / risk;
}

bool BetterSL(
   string side,
   double currentSL,
   double candidateSL
)
{
   if(currentSL <= 0.0)
      return true;

   if(side == "BUY")
      return candidateSL > currentSL + _Point;

   return candidateSL < currentSL - _Point;
}

bool SLValidNow(
   string side,
   double sl,
   MqlTick &tick
)
{
   long stops =
      SymbolInfoInteger(
         _Symbol,
         SYMBOL_TRADE_STOPS_LEVEL
      );

   long freeze =
      SymbolInfoInteger(
         _Symbol,
         SYMBOL_TRADE_FREEZE_LEVEL
      );

   double distance =
      MathMax(
         (double)stops,
         (double)freeze
      ) * _Point;

   distance =
      MathMax(
         distance,
         _Point
      );

   if(side == "BUY")
      return sl < tick.bid - distance;

   return sl > tick.ask + distance;
}

void MoveStops()
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   int total = PositionsTotal();

   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(
         ticket == 0 ||
         !PositionSelectByTicket(ticket) ||
         PositionGetString(POSITION_SYMBOL) != _Symbol ||
         PositionGetInteger(POSITION_MAGIC) != InpMagicNumber
      )
         continue;

      long type = PositionGetInteger(POSITION_TYPE);
      string side = type == POSITION_TYPE_BUY ? "BUY" : "SELL";

      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      double risk = InitialRiskForSelectedPosition();

      if(risk <= _Point)
         continue;

      double r =
         PositionR(
            side,
            entry,
            risk,
            tick
         );

      double lockR = -999.0;
      bool trailing = false;

      if(
         InpEnableTrailing &&
         r >= InpTrailStartR &&
         InpTrailStepR > 0.0
      )
      {
         double rawLock =
            r -
            MathMax(0.0, InpTrailGapR);

         lockR =
            MathFloor(
               rawLock / InpTrailStepR
            ) * InpTrailStepR;

         lockR =
            MathMax(
               lockR,
               InpBEPlusR
            );

         trailing = true;
      }
      else if(
         InpMoveToBE &&
         r >= InpBEAtR
      )
      {
         lockR =
            MathMax(
               0.0,
               InpBEPlusR
            );
      }

      if(lockR <= -900.0)
         continue;

      double candidateSL =
         side == "BUY"
         ? entry + lockR * risk
         : entry - lockR * risk;

      candidateSL = NPrice(candidateSL);

      if(
         !BetterSL(
            side,
            currentSL,
            candidateSL
         ) ||
         !SLValidNow(
            side,
            candidateSL,
            tick
         )
      )
         continue;

      // Position may have hit TP/SL between the scan and this modification.
      if(!PositionSelectByTicket(ticket))
         continue;

      if(
         PositionGetString(POSITION_SYMBOL) != _Symbol ||
         PositionGetInteger(POSITION_MAGIC) != InpMagicNumber
      )
         continue;

      currentTP = PositionGetDouble(POSITION_TP);

      if(
         trade.PositionModify(
            ticket,
            candidateSL,
            currentTP
         )
      )
      {
         if(trailing)
            g_trailMoves++;
         else
            g_beMoves++;
      }
   }
}

double BasketR()
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return 0.0;

   double weighted = 0.0;
   double volumeSum = 0.0;

   int total = PositionsTotal();

   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(
         ticket == 0 ||
         !PositionSelectByTicket(ticket) ||
         PositionGetString(POSITION_SYMBOL) != _Symbol ||
         PositionGetInteger(POSITION_MAGIC) != InpMagicNumber
      )
         continue;

      long type = PositionGetInteger(POSITION_TYPE);
      string side = type == POSITION_TYPE_BUY ? "BUY" : "SELL";

      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double risk = InitialRiskForSelectedPosition();
      double volume = PositionGetDouble(POSITION_VOLUME);

      if(risk <= _Point || volume <= 0.0)
         continue;

      double r =
         PositionR(
            side,
            entry,
            risk,
            tick
         );

      weighted += r * volume;
      volumeSum += volume;
   }

   if(volumeSum <= 0.0)
      return 0.0;

   return weighted / volumeSum;
}

double TotalOurVolume()
{
   double volume = 0.0;

   int total = PositionsTotal();

   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(
         ticket == 0 ||
         !PositionSelectByTicket(ticket) ||
         PositionGetString(POSITION_SYMBOL) != _Symbol ||
         PositionGetInteger(POSITION_MAGIC) != InpMagicNumber
      )
         continue;

      volume += PositionGetDouble(POSITION_VOLUME);
   }

   return volume;
}

void TryPartialClose()
{
   if(
      !InpEnablePartialClose ||
      g_tp1Done ||
      CountOurOpenPositions() <= 0
   )
      return;

   double basketR = BasketR();

   if(basketR < InpPartialAtR)
      return;

   double totalVolume = TotalOurVolume();
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(step <= 0.0)
      step = 0.01;

   double targetClose =
      totalVolume *
      MathMax(
         0.0,
         MathMin(100.0, InpPartialClosePercent)
      ) / 100.0;

   targetClose =
      MathFloor(
         targetClose / step + 1e-8
      ) * step;

   targetClose =
      NormalizeDouble(
         targetClose,
         2
      );

   // Mark TP1 done even when 0.01 cannot be split. That mirrors real lot constraints
   // and prevents repeated attempts every tick.
   if(targetClose < minLot)
   {
      g_tp1Done = true;
      g_tp1Events++;

      if(InpPrintSignalJournal)
      {
         Print(
            "TP1 REACHED | partial skipped by broker min lot | basketR=",
            DoubleToString(basketR, 2)
         );
      }

      return;
   }

   double closed = 0.0;
   int total = PositionsTotal();

   for(int i = total - 1; i >= 0 && closed < targetClose - step * 0.5; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(
         ticket == 0 ||
         !PositionSelectByTicket(ticket) ||
         PositionGetString(POSITION_SYMBOL) != _Symbol ||
         PositionGetInteger(POSITION_MAGIC) != InpMagicNumber
      )
         continue;

      double volume = PositionGetDouble(POSITION_VOLUME);
      double remainingNeed = targetClose - closed;
      double partial = MathMin(volume, remainingNeed);

      partial =
         MathFloor(
            partial / step + 1e-8
         ) * step;

      partial =
         NormalizeDouble(
            partial,
            2
         );

      if(partial < minLot)
         continue;

      bool ok = false;

      if(
         partial < volume - step * 0.5 &&
         volume - partial >= minLot
      )
      {
         ok =
            trade.PositionClosePartial(
               ticket,
               partial
            );
      }
      else
      {
         ok =
            trade.PositionClose(
               ticket
            );

         if(ok)
            partial = volume;
      }

      if(ok)
         closed += partial;
   }

   g_tp1Done = true;
   g_tp1Events++;

   if(InpPrintSignalJournal)
   {
      Print(
         "TP1 REACHED | basketR=",
         DoubleToString(basketR, 2),
         " | target close=",
         DoubleToString(targetClose, 2),
         " | closed=",
         DoubleToString(closed, 2)
      );
   }
}

void ManageTrades()
{
   int count = CountOurOpenPositions();

   if(count <= 0)
   {
      if(g_basketSeenOpen)
      {
         g_basketSeenOpen = false;
         g_tp1Done = false;
      }

      return;
   }

   if(!g_basketSeenOpen)
   {
      g_basketSeenOpen = true;
      g_tp1Done = false;
   }

   if(!InpEnableTradeManager)
      return;

   TryPartialClose();
   MoveStops();
}

// ============================================================
// EVENTS
// ============================================================

int OnInit()
{
   if(!MQLInfoInteger(MQL_TESTER))
   {
      Print("REFUSED: XAU_MARKET_ZONES_BACKTEST_v2_STRICT_TRADABLE_ZONES is Strategy Tester only.");
      return INIT_FAILED;
   }

   if(!IsXAUFamily())
   {
      Print("REFUSED: XAUUSD-family symbol required. Current=", _Symbol);
      return INIT_FAILED;
   }

   ResetLockedZone(g_buyZone);
   ResetLockedZone(g_sellZone);

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpMaxDeviationPoints);

   Print(
      "LOCAL REPLAY TESTER STARTED | symbol=",
      _Symbol,
      " | lot=",
      DoubleToString(InpLot, 2),
      " | entries/signal=",
      InpEntriesPerReadySignal,
      " | max positions=",
      InpMaxOpenPositions,
      " | RR=",
      DoubleToString(InpRR, 2),
      " | trade_watch_zones=",
      (InpTradeWatchOnlyZones ? "YES" : "NO")
   );

   return INIT_SUCCEEDED;
}

void OnTick()
{
   ManageTrades();

   datetime m1 =
      ClosedBarTime(PERIOD_M1);

   if(
      m1 > 0 &&
      m1 != g_lastM1Bar
   )
   {
      g_lastM1Bar = m1;
      RefreshLocalZones();
   }

   // Invalidation is checked every tick against the most recent CLOSED
   // candle of the zone's own timeframe.
   EvaluateZoneInvalidation(g_buyZone);
   EvaluateZoneInvalidation(g_sellZone);

   datetime m5 =
      ClosedBarTime(PERIOD_M5);

   if(
      m5 > 0 &&
      m5 != g_lastM5Bar
   )
   {
      g_lastM5Bar = m5;
      EvaluateAndTrade();
   }
}

void OnDeinit(const int reason)
{
   Print(
      "LOCAL REPLAY SUMMARY | zone_refreshes=",
      g_zoneRefreshes,
      " | zone_adoptions=",
      g_zoneAdoptions,
      " | watch_zones_skipped=",
      g_watchZonesSkipped,
      " | zone_invalidations=",
      g_zoneInvalidations,
      " | ready_signals=",
      g_readySignals,
      " | orders_opened=",
      g_ordersOpened,
      " | order_failures=",
      g_orderFailures,
      " | tp1_events=",
      g_tp1Events,
      " | BE_moves=",
      g_beMoves,
      " | trail_moves=",
      g_trailMoves
   );
}
