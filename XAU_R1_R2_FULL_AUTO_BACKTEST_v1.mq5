// XAU R1 + R2 FULL AUTO BACKTEST v1
// Local Strategy Tester port of the live R1 Watch + R2 Swing auto-signal pipeline.
// No WebRequest, no Cloudflare dependency.
// Designed for XAUUSD family symbols and "Every tick based on real ticks".
//
// Parity scope:
// 1) R1 regime detection
// 2) R1 automatic decision/watch zones
// 3) R2 Swing state + Pullback/Breakout/Retest/Range candidates
// 4) R1 zone gate
// 5) Automatic Market/Limit/Stop execution
// 6) Pending expiry + structural invalidation
// 7) TP1 partial close + TP2 + M15 structural protection
//
// This tester intentionally excludes cloud transport, D1 journal, HTTP ACKs and UI pages.

#property strict

#include <Trade/Trade.mqh>

CTrade trade;

// ============================================================
// INPUTS
// ============================================================

input long   InpMagicNumber                 = 2601001;
input int    InpEvaluateEverySeconds        = 10;
input int    InpMaxDeviationPoints          = 50;
input int    InpMinimumR2Score              = 70;
input double InpSafetyMaxLot                = 1.00;
input double InpTP1ClosePercent             = 50.0;
input bool   InpEnableStructureManagement   = true;
input int    InpStructureCheckEverySeconds  = 15;
input bool   InpUsePendingExpiration        = true;
input bool   InpLogDecisions                = true;
input bool   InpShowVisualStatus             = true;

// ============================================================
// TYPES
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

struct R1State
{
   bool valid;
   string regime;
   string strategy;
   double bid;
   double ask;
   double spread_points;
   TFMetrics h1;
   TFMetrics m30;
   TFMetrics m15;
   TFMetrics m5;
   TFMetrics m1;
};

struct R1Zones
{
   bool valid;
   bool watch_only;
   string zone_type;
   double buy_low;
   double buy_high;
   double sell_low;
   double sell_high;
};

struct BreakStrength
{
   bool confirmed;
   int score;
   string grade;
   double level;
   bool compression;
};

struct R2Candidate
{
   bool exists;
   bool allowed;
   string strategy;
   string side;
   string order_type;
   int score;
   double entry;
   double sl;
   double tp1;
   double tp2;
   double rr1;
   int expiry_hours;
   double zone_low;
   double zone_high;
   double invalidation;
   double breakout_level;
   double breakout_buffer;
   string breakout_grade;
   string notes;
};

struct R2Result
{
   bool valid;
   string market_state;
   bool high_volatility;
   R2Candidate setup;
};

struct PendingState
{
   bool active;
   ulong ticket;
   string key;
   string side;
   string strategy;
   string order_type;
   double entry;
   double sl;
   double tp1;
   double tp2;
   double invalidation;
   double lot;
   datetime placed_at;
   datetime expires_at;
};

struct PositionState
{
   bool active;
   string side;
   string strategy;
   double entry;
   double sl;
   double tp1;
   double tp2;
   double initial_risk;
   double initial_lot;
   bool tp1_done;
   datetime open_time;
};

// ============================================================
// GLOBALS
// ============================================================

datetime g_lastEval = 0;
datetime g_lastStructureCheck = 0;
string g_lastSetupKey = "";
string g_processedSetupKeys[];
int g_processedSetupKeyCount = 0;

PendingState g_pending;
PositionState g_pos;

long g_setupsEvaluated = 0;
long g_readySetups = 0;
long g_zoneRejected = 0;
long g_placementRejected = 0;
long g_ordersPlaced = 0;
long g_marketOrders = 0;
long g_pendingOrders = 0;
long g_pendingExpired = 0;
long g_pendingInvalidated = 0;
long g_tp1Hits = 0;

// ============================================================
// UTILS
// ============================================================

double RoundN(double value, int digits)
{
   double p = MathPow(10.0, digits);
   return MathRound(value * p) / p;
}

double Clamp(double value, double low, double high)
{
   return MathMax(low, MathMin(high, value));
}

bool ValidNumber(double v)
{
   return MathIsValidNumber(v) && v != DBL_MAX && v != -DBL_MAX;
}

bool IsBuyOrderType(string orderType)
{
   return StringFind(orderType, "BUY") == 0;
}

bool IsPendingOrderType(string orderType)
{
   return orderType == "BUY_LIMIT" ||
          orderType == "SELL_LIMIT" ||
          orderType == "BUY_STOP" ||
          orderType == "SELL_STOP";
}

double NormalizePrice(double price)
{
   return NormalizeDouble(price, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
}

double NormalizeVolume(double volume)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(minLot <= 0.0) minLot = 0.01;
   if(maxLot <= 0.0) maxLot = volume;
   if(step <= 0.0) step = 0.01;

   volume = MathMax(minLot, MathMin(maxLot, volume));

   if(InpSafetyMaxLot > 0.0)
      volume = MathMin(volume, InpSafetyMaxLot);

   volume = MathFloor((volume + 1e-12) / step) * step;

   return NormalizeDouble(volume, 2);
}

double CalculateLotByBalance()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double lot = MathFloor(balance / 100.0) * 0.01;
   if(lot < 0.01) lot = 0.01;
   return NormalizeVolume(lot);
}

// ============================================================
// INDICATOR MATH, MATCHES WORKER FORMULAS
// ============================================================

void EmaSeries(double &values[], int n, int period, double &out[])
{
   ArrayResize(out, n);
   if(n <= 0) return;

   double multiplier = 2.0 / (period + 1.0);
   double current = values[0];
   out[0] = current;

   for(int i = 1; i < n; i++)
   {
      current = values[i] * multiplier + current * (1.0 - multiplier);
      out[i] = current;
   }
}

double RsiValues(double &values[], int n, int period)
{
   if(n <= period)
      return 50.0;

   double gain = 0.0;
   double loss = 0.0;

   for(int i = 1; i <= period; i++)
   {
      double change = values[i] - values[i - 1];
      if(change >= 0.0) gain += change;
      else loss += -change;
   }

   double avgGain = gain / period;
   double avgLoss = loss / period;

   for(int i = period + 1; i < n; i++)
   {
      double change = values[i] - values[i - 1];
      double currentGain = change > 0.0 ? change : 0.0;
      double currentLoss = change < 0.0 ? -change : 0.0;

      avgGain = ((avgGain * (period - 1)) + currentGain) / period;
      avgLoss = ((avgLoss * (period - 1)) + currentLoss) / period;
   }

   if(avgLoss == 0.0)
      return 100.0;

   double rs = avgGain / avgLoss;
   return 100.0 - 100.0 / (1.0 + rs);
}

double AtrPrefix(MqlRates &rates[], int n, int period)
{
   if(n - 1 < period)
      return 0.0;

   double tr[];
   ArrayResize(tr, n - 1);

   for(int i = 1; i < n; i++)
   {
      double high = rates[i].high;
      double low = rates[i].low;
      double prevClose = rates[i - 1].close;

      tr[i - 1] = MathMax(
         high - low,
         MathMax(
            MathAbs(high - prevClose),
            MathAbs(low - prevClose)
         )
      );
   }

   double current = 0.0;
   for(int i = 0; i < period; i++)
      current += tr[i];

   current /= period;

   for(int i = period; i < ArraySize(tr); i++)
      current = ((current * (period - 1)) + tr[i]) / period;

   return current;
}

double Median(double &values[], int n)
{
   if(n <= 0) return 0.0;

   double temp[];
   ArrayResize(temp, n);

   for(int i = 0; i < n; i++)
      temp[i] = values[i];

   ArraySort(temp);

   if((n % 2) == 1)
      return temp[n / 2];

   return (temp[n / 2 - 1] + temp[n / 2]) / 2.0;
}

bool BuildMetrics(ENUM_TIMEFRAMES tf, int requestedCount, TFMetrics &m)
{
   m.valid = false;

   MqlRates rates[];
   int copied = CopyRates(_Symbol, tf, 1, requestedCount, rates);

   if(copied < 60)
      return false;

   ArraySetAsSeries(rates, false);

   double closes[];
   ArrayResize(closes, copied);

   for(int i = 0; i < copied; i++)
      closes[i] = rates[i].close;

   double ema9Series[];
   double ema20Series[];
   double ema50Series[];

   EmaSeries(closes, copied, 9, ema9Series);
   EmaSeries(closes, copied, 20, ema20Series);
   EmaSeries(closes, copied, 50, ema50Series);

   double currentAtr = AtrPrefix(rates, copied, 14);

   double atrHistory[];
   int atrCount = 0;
   int minimumBars = 15;
   int start = MathMax(minimumBars, copied - 31 + 1);

   for(int end = start; end <= copied; end++)
   {
      double v = AtrPrefix(rates, end, 14);
      if(ValidNumber(v) && v > 0.0)
      {
         ArrayResize(atrHistory, atrCount + 1);
         atrHistory[atrCount++] = v;
      }
   }

   int histCount = MathMax(0, atrCount - 1);
   if(histCount > 30)
      histCount = 30;

   double hist[];
   ArrayResize(hist, histCount);

   int firstHist = MathMax(0, atrCount - 1 - histCount);

   for(int i = 0; i < histCount; i++)
      hist[i] = atrHistory[firstHist + i];

   double medAtr = Median(hist, histCount);
   double atrRatio = (medAtr > 0.0) ? currentAtr / medAtr : 1.0;
   double rsi = RsiValues(closes, copied, 14);

   double slope = 0.0;
   if(copied >= 6 && currentAtr > 0.0)
      slope = (ema20Series[copied - 1] - ema20Series[copied - 6]) / currentAtr;

   int recentStart = copied - 20;
   int prevStart = copied - 21;

   if(recentStart < 0 || prevStart < 0)
      return false;

   double high20 = -DBL_MAX;
   double low20 = DBL_MAX;
   double previousHigh20 = -DBL_MAX;
   double previousLow20 = DBL_MAX;

   for(int i = recentStart; i < copied; i++)
   {
      high20 = MathMax(high20, rates[i].high);
      low20 = MathMin(low20, rates[i].low);
   }

   for(int i = prevStart; i < copied - 1; i++)
   {
      previousHigh20 = MathMax(previousHigh20, rates[i].high);
      previousLow20 = MathMin(previousLow20, rates[i].low);
   }

   double rangeWidth = high20 - low20;
   double rangeWidthAtr = currentAtr > 0.0 ? rangeWidth / currentAtr : 0.0;
   double touchTolerance = currentAtr * 0.25;

   int upperTouches = 0;
   int lowerTouches = 0;

   for(int i = recentStart; i < copied; i++)
   {
      if(MathAbs(rates[i].high - high20) <= touchTolerance)
         upperTouches++;

      if(MathAbs(rates[i].low - low20) <= touchTolerance)
         lowerTouches++;
   }

   MqlRates last = rates[copied - 1];
   MqlRates previous = rates[copied - 2];

   double lastRange = last.high - last.low;
   double body = MathAbs(last.close - last.open);
   double closePosition = 0.5;

   if(lastRange > 0.0)
      closePosition = (last.close - last.low) / lastRange;

   double ema20 = ema20Series[copied - 1];
   double ema50 = ema50Series[copied - 1];
   double emaSepAtr = currentAtr > 0.0 ? MathAbs(ema20 - ema50) / currentAtr : 0.0;

   m.valid = true;
   m.close = RoundN(last.close, 4);
   m.previous_close = RoundN(previous.close, 4);
   m.ema9 = RoundN(ema9Series[copied - 1], 4);
   m.ema20 = RoundN(ema20, 4);
   m.ema50 = RoundN(ema50, 4);
   m.rsi14 = RoundN(rsi, 2);
   m.atr14 = RoundN(currentAtr, 4);
   m.atr_ratio = RoundN(atrRatio, 3);
   m.ema_sep_atr = RoundN(emaSepAtr, 3);
   m.ema20_slope_atr = RoundN(slope, 3);
   m.high20 = RoundN(high20, 4);
   m.low20 = RoundN(low20, 4);
   m.previous_high20 = RoundN(previousHigh20, 4);
   m.previous_low20 = RoundN(previousLow20, 4);
   m.range_width_atr = RoundN(rangeWidthAtr, 3);
   m.upper_touches = upperTouches;
   m.lower_touches = lowerTouches;
   m.last_range = RoundN(lastRange, 4);
   m.body = RoundN(body, 4);
   m.close_position = RoundN(closePosition, 3);
   m.candle_time = last.time;

   return true;
}

// ============================================================
// R1 REGIME + ZONES
// ============================================================

bool CalculateR1(R1State &r1)
{
   r1.valid = false;

   if(!BuildMetrics(PERIOD_H1, 120, r1.h1)) return false;
   if(!BuildMetrics(PERIOD_M30, 120, r1.m30)) return false;
   if(!BuildMetrics(PERIOD_M15, 150, r1.m15)) return false;
   if(!BuildMetrics(PERIOD_M5, 200, r1.m5)) return false;
   if(!BuildMetrics(PERIOD_M1, 200, r1.m1)) return false;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   r1.bid = tick.bid;
   r1.ask = tick.ask;
   r1.spread_points = _Point > 0.0 ? (tick.ask - tick.bid) / _Point : 0.0;

   bool highVol =
      r1.m5.atr_ratio >= 1.80 ||
      r1.m5.last_range >= r1.m5.atr14 * 2.20;

   bool breakoutUp =
      r1.m5.close > r1.m5.previous_high20 + r1.m5.atr14 * 0.10 &&
      r1.m5.body >= r1.m5.atr14 * 0.55 &&
      r1.m5.close_position >= 0.75 &&
      r1.m15.close > r1.m15.ema20;

   bool breakoutDown =
      r1.m5.close < r1.m5.previous_low20 - r1.m5.atr14 * 0.10 &&
      r1.m5.body >= r1.m5.atr14 * 0.55 &&
      r1.m5.close_position <= 0.25 &&
      r1.m15.close < r1.m15.ema20;

   bool trendUp =
      r1.h1.close > r1.h1.ema20 &&
      r1.h1.ema20 > r1.h1.ema50 &&
      r1.h1.ema20_slope_atr > 0.05 &&
      r1.m30.close > r1.m30.ema20 &&
      r1.m30.ema20 > r1.m30.ema50 &&
      r1.m30.ema20_slope_atr > 0.05 &&
      r1.m15.close > r1.m15.ema20 &&
      r1.m15.rsi14 >= 52.0;

   bool trendDown =
      r1.h1.close < r1.h1.ema20 &&
      r1.h1.ema20 < r1.h1.ema50 &&
      r1.h1.ema20_slope_atr < -0.05 &&
      r1.m30.close < r1.m30.ema20 &&
      r1.m30.ema20 < r1.m30.ema50 &&
      r1.m30.ema20_slope_atr < -0.05 &&
      r1.m15.close < r1.m15.ema20 &&
      r1.m15.rsi14 <= 48.0;

   bool range =
      r1.m30.ema_sep_atr < 0.25 &&
      MathAbs(r1.m30.ema20_slope_atr) < 0.10 &&
      r1.m30.rsi14 >= 43.0 &&
      r1.m30.rsi14 <= 57.0 &&
      r1.m30.range_width_atr >= 2.0 &&
      r1.m30.range_width_atr <= 6.0 &&
      r1.m30.upper_touches >= 2 &&
      r1.m30.lower_touches >= 2;

   r1.regime = "TRANSITION";
   r1.strategy = "NONE";

   if(highVol)
   {
      r1.regime = "HIGH_VOLATILITY";
      r1.strategy = "NO_TRADE";
   }
   else if(breakoutUp)
   {
      r1.regime = "BREAKOUT_UP";
      r1.strategy = "BREAKOUT_RETEST_BUY";
   }
   else if(breakoutDown)
   {
      r1.regime = "BREAKOUT_DOWN";
      r1.strategy = "BREAKOUT_RETEST_SELL";
   }
   else if(trendUp)
   {
      r1.regime = "TREND_UP";
      r1.strategy = "TREND_PULLBACK_BUY";
   }
   else if(trendDown)
   {
      r1.regime = "TREND_DOWN";
      r1.strategy = "TREND_PULLBACK_SELL";
   }
   else if(range)
   {
      r1.regime = "RANGE";
      r1.strategy = "RANGE_REVERSION";
   }

   r1.valid = true;
   return true;
}

void SetZone(double a, double b, double &low, double &high)
{
   low = RoundN(MathMin(a, b), 2);
   high = RoundN(MathMax(a, b), 2);
}

R1Zones CalculateR1Zones(R1State &r1)
{
   R1Zones z;
   z.valid = false;
   z.watch_only = false;
   z.zone_type = "AUTO_R1";
   z.buy_low = 0.0;
   z.buy_high = 0.0;
   z.sell_low = 0.0;
   z.sell_high = 0.0;

   if(!r1.valid)
      return z;

   if(r1.regime == "HIGH_VOLATILITY" || r1.strategy == "NO_TRADE")
   {
      z.watch_only = true;
      z.zone_type = "WATCH_HIGH_VOLATILITY";

      bool bearishImpulse =
         r1.m1.close < r1.m1.ema9 &&
         r1.m5.close < r1.m5.ema20;

      bool bullishImpulse =
         r1.m1.close > r1.m1.ema9 &&
         r1.m5.close > r1.m5.ema20;

      if(bearishImpulse)
      {
         SetZone(
            r1.m1.ema9 - 0.35 * r1.m1.atr14,
            r1.m1.ema9 + 0.35 * r1.m1.atr14,
            z.sell_low,
            z.sell_high
         );

         SetZone(
            r1.m1.low20,
            r1.m1.low20 + 0.60 * r1.m1.atr14,
            z.buy_low,
            z.buy_high
         );
      }
      else if(bullishImpulse)
      {
         SetZone(
            r1.m1.ema9 - 0.35 * r1.m1.atr14,
            r1.m1.ema9 + 0.35 * r1.m1.atr14,
            z.buy_low,
            z.buy_high
         );

         SetZone(
            r1.m1.high20 - 0.60 * r1.m1.atr14,
            r1.m1.high20,
            z.sell_low,
            z.sell_high
         );
      }
      else
      {
         SetZone(
            r1.m1.low20,
            r1.m1.low20 + 0.50 * r1.m1.atr14,
            z.buy_low,
            z.buy_high
         );

         SetZone(
            r1.m1.high20 - 0.50 * r1.m1.atr14,
            r1.m1.high20,
            z.sell_low,
            z.sell_high
         );
      }
   }
   else if(r1.regime == "TRANSITION" || r1.strategy == "NONE")
   {
      z.watch_only = true;
      z.zone_type = "WATCH_TRANSITION";

      SetZone(
         r1.m5.low20,
         r1.m5.low20 + 0.35 * r1.m5.atr14,
         z.buy_low,
         z.buy_high
      );

      SetZone(
         r1.m5.high20 - 0.35 * r1.m5.atr14,
         r1.m5.high20,
         z.sell_low,
         z.sell_high
      );
   }
   else if(r1.strategy == "TREND_PULLBACK_BUY")
   {
      double ref =
         MathAbs(r1.ask - r1.m5.ema20) <= MathAbs(r1.ask - r1.m5.ema50)
         ? r1.m5.ema20
         : r1.m5.ema50;

      SetZone(
         ref - 0.45 * r1.m5.atr14,
         ref + 0.45 * r1.m5.atr14,
         z.buy_low,
         z.buy_high
      );
   }
   else if(r1.strategy == "TREND_PULLBACK_SELL")
   {
      double ref =
         MathAbs(r1.bid - r1.m5.ema20) <= MathAbs(r1.bid - r1.m5.ema50)
         ? r1.m5.ema20
         : r1.m5.ema50;

      SetZone(
         ref - 0.45 * r1.m5.atr14,
         ref + 0.45 * r1.m5.atr14,
         z.sell_low,
         z.sell_high
      );
   }
   else if(r1.strategy == "BREAKOUT_RETEST_BUY")
   {
      double level = r1.m5.previous_high20;

      SetZone(
         level - 0.15 * r1.m5.atr14,
         level + 0.45 * r1.m5.atr14,
         z.buy_low,
         z.buy_high
      );
   }
   else if(r1.strategy == "BREAKOUT_RETEST_SELL")
   {
      double level = r1.m5.previous_low20;

      SetZone(
         level - 0.45 * r1.m5.atr14,
         level + 0.15 * r1.m5.atr14,
         z.sell_low,
         z.sell_high
      );
   }
   else if(r1.strategy == "RANGE_REVERSION")
   {
      double width = r1.m30.high20 - r1.m30.low20;

      SetZone(
         r1.m30.low20,
         r1.m30.low20 + 0.20 * width,
         z.buy_low,
         z.buy_high
      );

      SetZone(
         r1.m30.high20 - 0.20 * width,
         r1.m30.high20,
         z.sell_low,
         z.sell_high
      );
   }

   z.valid =
      (z.buy_high > z.buy_low && z.buy_low > 0.0) ||
      (z.sell_high > z.sell_low && z.sell_low > 0.0);

   return z;
}

// ============================================================
// R2 ENGINE
// ============================================================

BreakStrength R2BreakoutStrength(
   string side,
   TFMetrics &m15,
   TFMetrics &m30,
   TFMetrics &h1,
   R1State &r1
)
{
   BreakStrength s;

   bool buy = side == "BUY";
   double level = buy ? m15.previous_high20 : m15.previous_low20;
   double atr = MathMax(m15.atr14, 0.01);
   double beyond = buy ? m15.close - level : level - m15.close;

   bool bodyPass = m15.body >= 0.55 * atr;
   bool closePass = buy ? m15.close_position >= 0.75 : m15.close_position <= 0.25;
   bool closeBeyond = beyond > 0.0;

   bool htfAligned =
      buy
      ? (h1.close > h1.ema20 || m30.close > m30.ema20)
      : (h1.close < h1.ema20 || m30.close < m30.ema20);

   bool compression =
      buy
      ? (m15.upper_touches >= 2 || (m15.high20 - m15.close) <= 0.35 * atr)
      : (m15.lower_touches >= 2 || (m15.close - m15.low20) <= 0.35 * atr);

   int score = 0;

   if(compression) score += 20;
   if(ValidNumber(level)) score += 20;

   if(bodyPass && closePass && closeBeyond)
      score += 20;
   else if(closeBeyond)
      score += 10;

   if(htfAligned) score += 15;

   if(buy ? m15.rsi14 >= 52.0 : m15.rsi14 <= 48.0)
      score += 10;

   if(r1.spread_points <= 30.0)
      score += 5;

   if(MathAbs(beyond) <= 0.80 * atr || !closeBeyond)
      score += 10;

   s.confirmed = closeBeyond && bodyPass && closePass;
   s.score = MathMin(100, score);
   s.grade = score >= 80 ? "A" : score >= 70 ? "B" : "C";
   s.level = level;
   s.compression = compression;

   return s;
}

R2Candidate EmptyCandidate()
{
   R2Candidate c;
   c.exists = false;
   c.allowed = false;
   c.strategy = "NONE";
   c.side = "";
   c.order_type = "NONE";
   c.score = 0;
   c.entry = 0.0;
   c.sl = 0.0;
   c.tp1 = 0.0;
   c.tp2 = 0.0;
   c.rr1 = 0.0;
   c.expiry_hours = 0;
   c.zone_low = 0.0;
   c.zone_high = 0.0;
   c.invalidation = 0.0;
   c.breakout_level = 0.0;
   c.breakout_buffer = 0.0;
   c.breakout_grade = "";
   c.notes = "";
   return c;
}

R2Candidate PullbackCandidate(
   string side,
   R1State &r1,
   bool highVol
)
{
   R2Candidate c = EmptyCandidate();
   c.exists = true;

   bool buy = side == "BUY";
   double current = buy ? r1.ask : r1.bid;
   double atr = MathMax(r1.m15.atr14, 0.01);

   double refs[4];
   refs[0] = r1.m15.ema20;
   refs[1] = r1.m15.ema50;
   refs[2] = r1.m30.ema20;
   refs[3] = buy ? r1.m15.low20 : r1.m15.high20;

   double center = refs[0];
   double bestDistance = DBL_MAX;
   bool foundDirectional = false;

   for(int i = 0; i < 4; i++)
   {
      bool directional =
         buy
         ? refs[i] <= current + 0.15 * atr
         : refs[i] >= current - 0.15 * atr;

      if(directional)
      {
         double d = MathAbs(refs[i] - current);
         if(!foundDirectional || d < bestDistance)
         {
            foundDirectional = true;
            bestDistance = d;
            center = refs[i];
         }
      }
   }

   if(!foundDirectional)
   {
      bestDistance = DBL_MAX;

      for(int i = 0; i < 4; i++)
      {
         double d = MathAbs(refs[i] - current);
         if(d < bestDistance)
         {
            bestDistance = d;
            center = refs[i];
         }
      }
   }

   double halfWidth = 0.20 * atr;
   double zoneLow = center - halfWidth;
   double zoneHigh = center + halfWidth;
   bool inZone = current >= zoneLow && current <= zoneHigh;
   double entry = RoundN(inZone ? current : center, 2);

   double invalidation =
      buy
      ? MathMin(r1.m15.low20, r1.m30.low20)
      : MathMax(r1.m15.high20, r1.m30.high20);

   double sl = RoundN(
      buy
      ? invalidation - 0.20 * atr
      : invalidation + 0.20 * atr,
      2
   );

   double risk = MathAbs(entry - sl);

   double target1 =
      buy
      ? MathMax(r1.m15.high20, r1.m30.close)
      : MathMin(r1.m15.low20, r1.m30.close);

   double tp1 = target1;

   if(risk > 0.0 && MathAbs(tp1 - entry) / risk < 1.30)
      tp1 = buy ? entry + 1.30 * risk : entry - 1.30 * risk;

   double tp2 =
      buy
      ? MathMax(r1.m30.high20, entry + 2.0 * risk)
      : MathMin(r1.m30.low20, entry - 2.0 * risk);

   double rr1 = risk > 0.0 ? MathAbs(tp1 - entry) / risk : 0.0;

   int score = 0;

   bool h1Bias = buy ? r1.h1.close > r1.h1.ema20 : r1.h1.close < r1.h1.ema20;
   bool m30Align = buy ? r1.m30.close >= r1.m30.ema20 : r1.m30.close <= r1.m30.ema20;
   bool valueGood = MathAbs(current - center) <= 0.75 * atr || !inZone;
   bool m5Behavior =
      buy
      ? (r1.m5.close >= r1.m5.ema20 || r1.m5.rsi14 >= 50.0)
      : (r1.m5.close <= r1.m5.ema20 || r1.m5.rsi14 <= 50.0);

   if(h1Bias) score += 25;
   if(m30Align) score += 20;
   if(valueGood) score += 20;

   if(
      MathAbs(center - r1.m15.ema20) <= 0.35 * atr ||
      MathAbs(center - r1.m30.ema20) <= 0.35 * atr
   )
      score += 10;

   if(m5Behavior) score += 10;
   if(rr1 >= 1.30) score += 10;
   if(r1.spread_points <= 30.0) score += 5;
   if(highVol) score = MathMax(0, score - 5);

   bool allowed =
      score >= InpMinimumR2Score &&
      rr1 >= 1.30 &&
      risk >= 0.60 * atr &&
      risk <= 1.50 * atr;

   c.allowed = allowed;
   c.strategy = buy ? "PULLBACK_BUY" : "PULLBACK_SELL";
   c.side = side;
   c.order_type = inZone ? (buy ? "BUY" : "SELL") : (buy ? "BUY_LIMIT" : "SELL_LIMIT");
   c.score = MathMin(100, MathMax(0, score));
   c.entry = RoundN(entry, 2);
   c.sl = RoundN(sl, 2);
   c.tp1 = RoundN(tp1, 2);
   c.tp2 = RoundN(tp2, 2);
   c.rr1 = RoundN(rr1, 3);
   c.expiry_hours = highVol ? 4 : (score >= 80 ? 12 : 8);
   c.zone_low = RoundN(zoneLow, 2);
   c.zone_high = RoundN(zoneHigh, 2);
   c.invalidation = RoundN(invalidation, 2);
   c.notes = inZone ? "Price already inside value zone" : "Prefer limit entry at value zone";

   return c;
}

R2Candidate BreakoutCandidate(
   string side,
   R1State &r1,
   BreakStrength &strength,
   bool highVol
)
{
   R2Candidate c = EmptyCandidate();
   c.exists = true;

   bool buy = side == "BUY";
   double atr = MathMax(r1.m15.atr14, 0.01);
   string grade = strength.grade;

   double factor =
      highVol
      ? 0.15
      : grade == "A"
        ? 0.08
        : 0.12;

   double spreadPrice = MathMax(0.0, r1.ask - r1.bid);
   double buffer = MathMax(factor * atr, 2.0 * spreadPrice);

   double level = strength.level;
   double entry = RoundN(buy ? level + buffer : level - buffer, 2);

   double invalidation = buy ? r1.m15.low20 : r1.m15.high20;

   double sl = RoundN(
      buy
      ? invalidation - 0.20 * atr
      : invalidation + 0.20 * atr,
      2
   );

   double risk = MathAbs(entry - sl);
   double tp1 = buy ? r1.m30.high20 : r1.m30.low20;

   if(risk > 0.0 && MathAbs(tp1 - entry) / risk < 1.30)
      tp1 = buy ? entry + 1.30 * risk : entry - 1.30 * risk;

   double tp2 =
      buy
      ? MathMax(r1.h1.high20, entry + 2.0 * risk)
      : MathMin(r1.h1.low20, entry - 2.0 * risk);

   double rr1 = risk > 0.0 ? MathAbs(tp1 - entry) / risk : 0.0;

   int score = strength.score;
   bool roomGood = rr1 >= 1.30;

   if(!roomGood)
      score = MathMax(0, score - 10);

   bool riskGood = risk >= 0.60 * atr && risk <= 1.50 * atr;

   bool chase =
      buy
      ? r1.ask > entry + 0.60 * atr
      : r1.bid < entry - 0.60 * atr;

   bool allowed =
      score >= InpMinimumR2Score &&
      roomGood &&
      riskGood &&
      !chase &&
      grade != "C";

   c.allowed = allowed;
   c.strategy = buy ? "BREAKOUT_BUY" : "BREAKOUT_SELL";
   c.side = side;
   c.order_type = buy ? "BUY_STOP" : "SELL_STOP";
   c.score = MathMin(100, MathMax(0, score));
   c.entry = RoundN(entry, 2);
   c.sl = RoundN(sl, 2);
   c.tp1 = RoundN(tp1, 2);
   c.tp2 = RoundN(tp2, 2);
   c.rr1 = RoundN(rr1, 3);
   c.expiry_hours = highVol ? 3 : (grade == "A" ? 6 : 4);
   c.breakout_level = RoundN(level, 2);
   c.breakout_grade = grade;
   c.breakout_buffer = RoundN(buffer, 2);
   c.invalidation = RoundN(invalidation, 2);
   c.notes = chase ? "Do not chase" : "Stop entry structurally usable";

   return c;
}

R2Candidate RetestCandidate(
   string side,
   R1State &r1,
   BreakStrength &strength,
   bool highVol
)
{
   R2Candidate c = EmptyCandidate();
   c.exists = true;

   bool buy = side == "BUY";
   double current = buy ? r1.ask : r1.bid;
   double atr = MathMax(r1.m15.atr14, 0.01);
   double level = strength.level;

   double width =
      (highVol ? 0.30 : strength.grade == "A" ? 0.15 : 0.20) * atr;

   double zoneLow = level - width;
   double zoneHigh = level + width;
   bool inZone = current >= zoneLow && current <= zoneHigh;

   bool held =
      buy
      ? r1.m15.close >= level - 0.20 * atr
      : r1.m15.close <= level + 0.20 * atr;

   bool confirm =
      buy
      ? (r1.m5.close >= r1.m5.ema20 && r1.m5.rsi14 >= 50.0)
      : (r1.m5.close <= r1.m5.ema20 && r1.m5.rsi14 <= 50.0);

   double entry = RoundN(inZone && confirm ? current : level, 2);

   double invalidation =
      buy
      ? MathMin(r1.m15.low20, level - 0.45 * atr)
      : MathMax(r1.m15.high20, level + 0.45 * atr);

   double sl = RoundN(
      buy
      ? invalidation - 0.20 * atr
      : invalidation + 0.20 * atr,
      2
   );

   double risk = MathAbs(entry - sl);
   double tp1 = buy ? r1.m30.high20 : r1.m30.low20;

   if(risk > 0.0 && MathAbs(tp1 - entry) / risk < 1.30)
      tp1 = buy ? entry + 1.30 * risk : entry - 1.30 * risk;

   double tp2 =
      buy
      ? MathMax(r1.h1.high20, entry + 2.0 * risk)
      : MathMin(r1.h1.low20, entry - 2.0 * risk);

   double rr1 = risk > 0.0 ? MathAbs(tp1 - entry) / risk : 0.0;

   bool htfAligned =
      buy
      ? (r1.h1.close > r1.h1.ema20 || r1.m30.close > r1.m30.ema20)
      : (r1.h1.close < r1.h1.ema20 || r1.m30.close < r1.m30.ema20);

   int score =
      20 +
      20 +
      (held ? 20 : 0) +
      (htfAligned ? 15 : 0) +
      (confirm ? 10 : 0) +
      (rr1 >= 1.30 ? 10 : 0) +
      (r1.spread_points <= 30.0 ? 5 : 0);

   bool allowed =
      score >= InpMinimumR2Score &&
      held &&
      rr1 >= 1.30;

   c.allowed = allowed;
   c.strategy = buy ? "RETEST_BUY" : "RETEST_SELL";
   c.side = side;
   c.order_type = inZone && confirm ? (buy ? "BUY" : "SELL") : (buy ? "BUY_LIMIT" : "SELL_LIMIT");
   c.score = MathMin(100, MathMax(0, score));
   c.entry = RoundN(entry, 2);
   c.sl = RoundN(sl, 2);
   c.tp1 = RoundN(tp1, 2);
   c.tp2 = RoundN(tp2, 2);
   c.rr1 = RoundN(rr1, 3);
   c.expiry_hours = highVol ? 4 : 8;
   c.zone_low = RoundN(zoneLow, 2);
   c.zone_high = RoundN(zoneHigh, 2);
   c.breakout_level = RoundN(level, 2);
   c.invalidation = RoundN(invalidation, 2);
   c.notes = held ? "Broken level holding" : "Retest failed to hold";

   return c;
}

R2Candidate RangeCandidate(string side, R1State &r1)
{
   R2Candidate c = EmptyCandidate();
   c.exists = true;

   bool buy = side == "BUY";
   double current = buy ? r1.ask : r1.bid;
   double width = r1.m30.high20 - r1.m30.low20;
   double pos = width > 0.0 ? (current - r1.m30.low20) / width : 0.5;
   double atr = MathMax(r1.m15.atr14, 0.01);
   double edge = buy ? r1.m30.low20 : r1.m30.high20;
   double zoneWidth = 0.20 * width;

   double zoneLow = buy ? r1.m30.low20 : r1.m30.high20 - zoneWidth;
   double zoneHigh = buy ? r1.m30.low20 + zoneWidth : r1.m30.high20;

   bool inZone = current >= zoneLow && current <= zoneHigh;
   double entry = RoundN(inZone ? current : edge, 2);

   double sl = RoundN(
      buy
      ? r1.m30.low20 - 0.25 * atr
      : r1.m30.high20 + 0.25 * atr,
      2
   );

   double risk = MathAbs(entry - sl);
   double midpoint = (r1.m30.high20 + r1.m30.low20) / 2.0;
   double tp1 = midpoint;

   if(risk > 0.0 && MathAbs(tp1 - entry) / risk < 1.30)
      tp1 = buy ? entry + 1.30 * risk : entry - 1.30 * risk;

   double tp2 = buy ? r1.m30.high20 : r1.m30.low20;
   double rr1 = risk > 0.0 ? MathAbs(tp1 - entry) / risk : 0.0;

   bool neutral = pos >= 0.40 && pos <= 0.60;

   bool confirm =
      buy
      ? (r1.m5.close >= r1.m5.ema20 || r1.m5.close_position >= 0.55)
      : (r1.m5.close <= r1.m5.ema20 || r1.m5.close_position <= 0.45);

   int score =
      25 +
      15 +
      15 +
      (inZone ? 15 : 8) +
      (confirm ? 10 : 0) +
      (rr1 >= 1.30 ? 15 : 0) +
      (r1.spread_points <= 30.0 ? 5 : 0);

   bool allowed =
      score >= InpMinimumR2Score &&
      !neutral &&
      rr1 >= 1.30;

   c.allowed = allowed;
   c.strategy = buy ? "RANGE_BUY" : "RANGE_SELL";
   c.side = side;
   c.order_type = inZone && confirm ? (buy ? "BUY" : "SELL") : (buy ? "BUY_LIMIT" : "SELL_LIMIT");
   c.score = MathMin(100, MathMax(0, score));
   c.entry = RoundN(entry, 2);
   c.sl = RoundN(sl, 2);
   c.tp1 = RoundN(tp1, 2);
   c.tp2 = RoundN(tp2, 2);
   c.rr1 = RoundN(rr1, 3);
   c.expiry_hours = 6;
   c.zone_low = RoundN(zoneLow, 2);
   c.zone_high = RoundN(zoneHigh, 2);
   c.invalidation = RoundN(buy ? r1.m30.low20 : r1.m30.high20, 2);
   c.notes = neutral ? "No entry in middle of range" : "Range edge setup";

   return c;
}

int CandidatePriority(R2Candidate &c, string marketState)
{
   if(StringFind(marketState, "TREND") >= 0 && StringFind(c.strategy, "PULLBACK") >= 0)
      return 4;

   if(StringFind(marketState, "BREAKOUT") >= 0 && StringFind(c.strategy, "BREAKOUT") >= 0)
      return 4;

   if(StringFind(marketState, "RANGE") >= 0 && StringFind(c.strategy, "RANGE") >= 0)
      return 4;

   if(StringFind(c.strategy, "RETEST") >= 0)
      return 3;

   return 2;
}

R2Candidate SelectBestCandidate(R2Candidate &candidates[], int count, string marketState)
{
   if(count <= 0)
      return EmptyCandidate();

   int highest = 0;

   for(int i = 1; i < count; i++)
   {
      if(candidates[i].score > candidates[highest].score)
         highest = i;
   }

   int bestValid = -1;

   for(int i = 0; i < count; i++)
   {
      if(!candidates[i].allowed || candidates[i].score < InpMinimumR2Score)
         continue;

      if(bestValid < 0)
      {
         bestValid = i;
         continue;
      }

      int scoreDiff = candidates[i].score - candidates[bestValid].score;

      if(MathAbs(scoreDiff) >= 5)
      {
         if(scoreDiff > 0)
            bestValid = i;

         continue;
      }

      int pNew = CandidatePriority(candidates[i], marketState);
      int pOld = CandidatePriority(candidates[bestValid], marketState);

      if(pNew > pOld)
      {
         bestValid = i;
         continue;
      }

      if(pNew == pOld)
      {
         if(candidates[i].rr1 > candidates[bestValid].rr1)
            bestValid = i;
         else if(
            candidates[i].rr1 == candidates[bestValid].rr1 &&
            MathAbs(candidates[i].entry - candidates[i].sl) <
            MathAbs(candidates[bestValid].entry - candidates[bestValid].sl)
         )
            bestValid = i;
      }
   }

   return bestValid >= 0 ? candidates[bestValid] : candidates[highest];
}

R2Result CalculateR2(R1State &r1)
{
   R2Result result;
   result.valid = false;
   result.market_state = "SWING_TRANSITION";
   result.high_volatility = false;
   result.setup = EmptyCandidate();

   if(!r1.valid)
      return result;

   bool highVol =
      r1.m15.atr_ratio >= 1.80 ||
      r1.m15.last_range >= r1.m15.atr14 * 2.20;

   bool trendUp =
      r1.h1.close > r1.h1.ema20 &&
      r1.h1.ema20_slope_atr >= -0.02 &&
      r1.m30.close > r1.m30.ema20 &&
      r1.m30.ema20_slope_atr >= -0.03;

   bool trendDown =
      r1.h1.close < r1.h1.ema20 &&
      r1.h1.ema20_slope_atr <= 0.02 &&
      r1.m30.close < r1.m30.ema20 &&
      r1.m30.ema20_slope_atr <= 0.03;

   bool rangeState =
      r1.m30.ema_sep_atr < 0.35 &&
      MathAbs(r1.m30.ema20_slope_atr) < 0.12 &&
      r1.m30.rsi14 >= 40.0 &&
      r1.m30.rsi14 <= 60.0 &&
      r1.m30.upper_touches >= 2 &&
      r1.m30.lower_touches >= 2;

   BreakStrength breakoutUp = R2BreakoutStrength("BUY", r1.m15, r1.m30, r1.h1, r1);
   BreakStrength breakoutDown = R2BreakoutStrength("SELL", r1.m15, r1.m30, r1.h1, r1);

   string marketState = "SWING_TRANSITION";

   if(breakoutUp.confirmed && breakoutUp.score >= 70)
      marketState = "SWING_BREAKOUT_UP";
   else if(breakoutDown.confirmed && breakoutDown.score >= 70)
      marketState = "SWING_BREAKOUT_DOWN";
   else if(trendUp)
      marketState = "SWING_TREND_UP";
   else if(trendDown)
      marketState = "SWING_TREND_DOWN";
   else if(rangeState)
      marketState = "SWING_RANGE";
   else if(highVol)
      marketState = "SWING_HIGH_VOLATILITY";

   R2Candidate candidates[];
   int count = 0;

   if(marketState == "SWING_TREND_UP" || (highVol && trendUp))
   {
      ArrayResize(candidates, count + 1);
      candidates[count++] = PullbackCandidate("BUY", r1, highVol);

      ArrayResize(candidates, count + 1);
      candidates[count++] = BreakoutCandidate("BUY", r1, breakoutUp, highVol);
   }
   else if(marketState == "SWING_TREND_DOWN" || (highVol && trendDown))
   {
      ArrayResize(candidates, count + 1);
      candidates[count++] = PullbackCandidate("SELL", r1, highVol);

      ArrayResize(candidates, count + 1);
      candidates[count++] = BreakoutCandidate("SELL", r1, breakoutDown, highVol);
   }
   else if(marketState == "SWING_BREAKOUT_UP")
   {
      ArrayResize(candidates, count + 1);
      candidates[count++] = BreakoutCandidate("BUY", r1, breakoutUp, highVol);

      ArrayResize(candidates, count + 1);
      candidates[count++] = RetestCandidate("BUY", r1, breakoutUp, highVol);
   }
   else if(marketState == "SWING_BREAKOUT_DOWN")
   {
      ArrayResize(candidates, count + 1);
      candidates[count++] = BreakoutCandidate("SELL", r1, breakoutDown, highVol);

      ArrayResize(candidates, count + 1);
      candidates[count++] = RetestCandidate("SELL", r1, breakoutDown, highVol);
   }
   else if(marketState == "SWING_RANGE")
   {
      ArrayResize(candidates, count + 1);
      candidates[count++] = RangeCandidate("BUY", r1);

      ArrayResize(candidates, count + 1);
      candidates[count++] = RangeCandidate("SELL", r1);
   }
   else
   {
      R2Candidate upCompression = BreakoutCandidate("BUY", r1, breakoutUp, highVol);
      R2Candidate downCompression = BreakoutCandidate("SELL", r1, breakoutDown, highVol);

      if(upCompression.score >= 80)
      {
         ArrayResize(candidates, count + 1);
         candidates[count++] = upCompression;
      }

      if(downCompression.score >= 80)
      {
         ArrayResize(candidates, count + 1);
         candidates[count++] = downCompression;
      }
   }

   result.valid = true;
   result.market_state = marketState;
   result.high_volatility = highVol;
   result.setup = SelectBestCandidate(candidates, count, marketState);

   return result;
}

// ============================================================
// R1 ZONE GATE + ORDER PLACEMENT
// ============================================================

bool ZoneGate(
   R2Candidate &setup,
   R1Zones &zones,
   R1State &r1,
   string &reason
)
{
   bool buy = setup.side == "BUY";
   bool breakoutFamily =
      StringFind(setup.strategy, "BREAKOUT") >= 0 ||
      StringFind(setup.strategy, "RETEST") >= 0;

   double low = 0.0;
   double high = 0.0;

   if(buy)
   {
      if(breakoutFamily)
      {
         low = zones.sell_low;
         high = zones.sell_high;
      }
      else
      {
         low = zones.buy_low;
         high = zones.buy_high;
      }
   }
   else
   {
      if(breakoutFamily)
      {
         low = zones.buy_low;
         high = zones.buy_high;
      }
      else
      {
         low = zones.sell_low;
         high = zones.sell_high;
      }
   }

   if(!(high > low) || low <= 0.0)
   {
      reason = "NO_RELEVANT_R1_ZONE";
      return false;
   }

   double current = buy ? r1.ask : r1.bid;
   double atr = MathMax(r1.m15.atr14, 0.01);
   double spreadPrice = MathMax(0.0, r1.ask - r1.bid);

   double proximity = MathMax(
      0.35 * atr,
      MathMax(3.0 * spreadPrice, 0.10)
   );

   bool currentInside = current >= low && current <= high;
   bool entryInside = setup.entry >= low && setup.entry <= high;

   double distanceToZone =
      current < low
      ? low - current
      : current > high
        ? current - high
        : 0.0;

   bool directionalBreak = false;

   if(breakoutFamily && buy && current >= high)
      directionalBreak = (current - high) <= MathMax(0.60 * atr, proximity);

   if(breakoutFamily && !buy && current <= low)
      directionalBreak = (low - current) <= MathMax(0.60 * atr, proximity);

   bool nearZone = distanceToZone <= proximity;
   bool allowed = currentInside || entryInside || nearZone || directionalBreak;

   reason =
      allowed
      ? directionalBreak
        ? "R1_ZONE_BREAKOUT_ARMED"
        : currentInside
          ? "PRICE_INSIDE_R1_ZONE"
          : entryInside
            ? "R2_ENTRY_INSIDE_R1_ZONE"
            : "PRICE_NEAR_R1_ZONE"
      : "R2_SETUP_TOO_FAR_FROM_RELEVANT_R1_ZONE";

   return allowed;
}

bool PlacementValid(R2Candidate &setup, R1State &r1, string &reason)
{
   if(setup.order_type == "BUY_LIMIT" && !(setup.entry < r1.ask))
   {
      reason = "BUY_LIMIT_ENTRY_IS_NOT_BELOW_ASK";
      return false;
   }

   if(setup.order_type == "BUY_STOP" && !(setup.entry > r1.ask))
   {
      reason = "BUY_STOP_ENTRY_IS_NOT_ABOVE_ASK";
      return false;
   }

   if(setup.order_type == "SELL_LIMIT" && !(setup.entry > r1.bid))
   {
      reason = "SELL_LIMIT_ENTRY_IS_NOT_ABOVE_BID";
      return false;
   }

   if(setup.order_type == "SELL_STOP" && !(setup.entry < r1.bid))
   {
      reason = "SELL_STOP_ENTRY_IS_NOT_BELOW_BID";
      return false;
   }

   reason = "ORDER_PLACEMENT_RELATION_VALID";
   return true;
}

string SetupKey(R2Candidate &setup, R1Zones &zones)
{
   double zoneLow = 0.0;
   double zoneHigh = 0.0;

   bool breakoutFamily =
      StringFind(setup.strategy, "BREAKOUT") >= 0 ||
      StringFind(setup.strategy, "RETEST") >= 0;

   if(setup.side == "BUY")
   {
      zoneLow = breakoutFamily ? zones.sell_low : zones.buy_low;
      zoneHigh = breakoutFamily ? zones.sell_high : zones.buy_high;
   }
   else
   {
      zoneLow = breakoutFamily ? zones.buy_low : zones.sell_low;
      zoneHigh = breakoutFamily ? zones.buy_high : zones.sell_high;
   }

   return
      setup.strategy + "|" +
      setup.order_type + "|" +
      IntegerToString((int)MathRound(setup.entry * 100.0)) + "|" +
      IntegerToString((int)MathRound(setup.sl * 100.0)) + "|" +
      IntegerToString((int)MathRound(zoneLow * 100.0)) + "|" +
      IntegerToString((int)MathRound(zoneHigh * 100.0));
}

bool ValidateLevels(R2Candidate &c)
{
   if(c.side == "BUY")
      return c.sl < c.entry &&
             c.entry < c.tp1 &&
             c.tp1 <= c.tp2;

   if(c.side == "SELL")
      return c.tp2 <= c.tp1 &&
             c.tp1 < c.entry &&
             c.entry < c.sl;

   return false;
}

bool SetupAlreadyProcessed(string key)
{
   for(int i = 0; i < g_processedSetupKeyCount; i++)
   {
      if(g_processedSetupKeys[i] == key)
         return true;
   }

   return false;
}

void MarkSetupProcessed(string key)
{
   if(key == "" || SetupAlreadyProcessed(key))
      return;

   ArrayResize(g_processedSetupKeys, g_processedSetupKeyCount + 1);
   g_processedSetupKeys[g_processedSetupKeyCount++] = key;
}

// ============================================================
// EXECUTION
// ============================================================

void ResetPending()
{
   g_pending.active = false;
   g_pending.ticket = 0;
   g_pending.key = "";
   g_pending.side = "";
   g_pending.strategy = "";
   g_pending.order_type = "";
   g_pending.entry = 0.0;
   g_pending.sl = 0.0;
   g_pending.tp1 = 0.0;
   g_pending.tp2 = 0.0;
   g_pending.invalidation = 0.0;
   g_pending.lot = 0.0;
   g_pending.placed_at = 0;
   g_pending.expires_at = 0;
}

void ResetPositionState()
{
   g_pos.active = false;
   g_pos.side = "";
   g_pos.strategy = "";
   g_pos.entry = 0.0;
   g_pos.sl = 0.0;
   g_pos.tp1 = 0.0;
   g_pos.tp2 = 0.0;
   g_pos.initial_risk = 0.0;
   g_pos.initial_lot = 0.0;
   g_pos.tp1_done = false;
   g_pos.open_time = 0;
}

bool AttachPositionFromPending()
{
   if(!g_pending.active)
      return false;

   if(!PositionSelect(_Symbol))
      return false;

   g_pos.active = true;
   g_pos.side = g_pending.side;
   g_pos.strategy = g_pending.strategy;
   g_pos.entry = PositionGetDouble(POSITION_PRICE_OPEN);
   g_pos.sl = g_pending.sl;
   g_pos.tp1 = g_pending.tp1;
   g_pos.tp2 = g_pending.tp2;
   g_pos.initial_risk = MathAbs(g_pos.entry - g_pos.sl);
   g_pos.initial_lot = PositionGetDouble(POSITION_VOLUME);
   g_pos.tp1_done = false;
   g_pos.open_time = (datetime)PositionGetInteger(POSITION_TIME);

   if(InpLogDecisions)
      Print(
         "BACKTEST FILL | ",
         g_pos.strategy,
         " | ",
         g_pending.order_type,
         " | entry=",
         DoubleToString(g_pos.entry, _Digits),
         " | sl=",
         DoubleToString(g_pos.sl, _Digits),
         " | tp1=",
         DoubleToString(g_pos.tp1, _Digits),
         " | tp2=",
         DoubleToString(g_pos.tp2, _Digits)
      );

   ResetPending();
   return true;
}

bool OpenMarket(R2Candidate &c, double lot)
{
   bool ok = false;

   if(c.side == "BUY")
      ok = trade.Buy(lot, _Symbol, 0.0, NormalizePrice(c.sl), NormalizePrice(c.tp2), "R2_" + c.strategy);
   else
      ok = trade.Sell(lot, _Symbol, 0.0, NormalizePrice(c.sl), NormalizePrice(c.tp2), "R2_" + c.strategy);

   if(!ok)
      return false;

   if(!PositionSelect(_Symbol))
      return false;

   g_pos.active = true;
   g_pos.side = c.side;
   g_pos.strategy = c.strategy;
   g_pos.entry = PositionGetDouble(POSITION_PRICE_OPEN);
   g_pos.sl = c.sl;
   g_pos.tp1 = c.tp1;
   g_pos.tp2 = c.tp2;
   g_pos.initial_risk = MathAbs(g_pos.entry - g_pos.sl);
   g_pos.initial_lot = PositionGetDouble(POSITION_VOLUME);
   g_pos.tp1_done = false;
   g_pos.open_time = (datetime)PositionGetInteger(POSITION_TIME);

   g_ordersPlaced++;
   g_marketOrders++;

   return true;
}

bool PlacePending(R2Candidate &c, double lot, string key)
{
   datetime expiration = 0;
   ENUM_ORDER_TYPE_TIME typeTime = ORDER_TIME_GTC;

   if(InpUsePendingExpiration && c.expiry_hours > 0)
   {
      expiration = TimeCurrent() + c.expiry_hours * 3600;
      typeTime = ORDER_TIME_SPECIFIED;
   }

   bool ok = false;
   double entry = NormalizePrice(c.entry);
   double sl = NormalizePrice(c.sl);
   double tp2 = NormalizePrice(c.tp2);

   if(c.order_type == "BUY_LIMIT")
      ok = trade.BuyLimit(lot, entry, _Symbol, sl, tp2, typeTime, expiration, "R2_" + c.strategy);
   else if(c.order_type == "SELL_LIMIT")
      ok = trade.SellLimit(lot, entry, _Symbol, sl, tp2, typeTime, expiration, "R2_" + c.strategy);
   else if(c.order_type == "BUY_STOP")
      ok = trade.BuyStop(lot, entry, _Symbol, sl, tp2, typeTime, expiration, "R2_" + c.strategy);
   else if(c.order_type == "SELL_STOP")
      ok = trade.SellStop(lot, entry, _Symbol, sl, tp2, typeTime, expiration, "R2_" + c.strategy);

   if(!ok)
      return false;

   g_pending.active = true;
   g_pending.ticket = trade.ResultOrder();
   g_pending.key = key;
   g_pending.side = c.side;
   g_pending.strategy = c.strategy;
   g_pending.order_type = c.order_type;
   g_pending.entry = c.entry;
   g_pending.sl = c.sl;
   g_pending.tp1 = c.tp1;
   g_pending.tp2 = c.tp2;
   g_pending.invalidation = c.invalidation;
   g_pending.lot = lot;
   g_pending.placed_at = TimeCurrent();
   g_pending.expires_at = expiration;

   g_ordersPlaced++;
   g_pendingOrders++;

   return true;
}

void TryExecuteSetup(R1State &r1, R1Zones &zones, R2Result &r2)
{
   g_setupsEvaluated++;

   R2Candidate c = r2.setup;

   if(!c.exists || !c.allowed || c.score < InpMinimumR2Score)
      return;

   if(!ValidateLevels(c))
   {
      if(InpLogDecisions)
         Print("BACKTEST REJECT | reason=INVALID_LEVELS | strategy=", c.strategy);

      return;
   }

   string zoneReason = "";
   if(!ZoneGate(c, zones, r1, zoneReason))
   {
      g_zoneRejected++;

      if(InpLogDecisions)
         Print(
            "BACKTEST WATCH | ",
            c.strategy,
            " | score=",
            c.score,
            " | reason=",
            zoneReason
         );

      return;
   }

   string placementReason = "";
   if(IsPendingOrderType(c.order_type) && !PlacementValid(c, r1, placementReason))
   {
      g_placementRejected++;

      if(InpLogDecisions)
         Print(
            "BACKTEST WATCH | ",
            c.strategy,
            " | order=",
            c.order_type,
            " | reason=",
            placementReason
         );

      return;
   }

   string key = SetupKey(c, zones);

   if(SetupAlreadyProcessed(key))
      return;

   // Mirrors the live Worker journal behavior:
   // a structural setup key is processed only once during the test.
   MarkSetupProcessed(key);
   g_lastSetupKey = key;
   g_readySetups++;

   double lot = CalculateLotByBalance();
   if(lot <= 0.0)
      return;

   bool ok =
      IsPendingOrderType(c.order_type)
      ? PlacePending(c, lot, key)
      : OpenMarket(c, lot);

   if(InpLogDecisions)
   {
      Print(
         ok ? "BACKTEST EXECUTE | " : "BACKTEST ORDER_FAILED | ",
         c.strategy,
         " | order=",
         c.order_type,
         " | state=",
         r2.market_state,
         " | score=",
         c.score,
         " | entry=",
         DoubleToString(c.entry, _Digits),
         " | sl=",
         DoubleToString(c.sl, _Digits),
         " | tp1=",
         DoubleToString(c.tp1, _Digits),
         " | tp2=",
         DoubleToString(c.tp2, _Digits),
         " | rr1=",
         DoubleToString(c.rr1, 2),
         " | lot=",
         DoubleToString(lot, 2),
         " | zone=",
         zoneReason
      );
   }
}

// ============================================================
// PENDING LIFECYCLE
// ============================================================

void ManagePending()
{
   if(!g_pending.active)
      return;

   if(AttachPositionFromPending())
      return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   if(
      g_pending.expires_at > 0 &&
      TimeCurrent() >= g_pending.expires_at
   )
   {
      if(OrderSelect(g_pending.ticket))
         trade.OrderDelete(g_pending.ticket);

      g_pendingExpired++;

      if(InpLogDecisions)
         Print("BACKTEST PENDING EXPIRED | ", g_pending.strategy);

      ResetPending();
      return;
   }

   bool invalidated = false;

   if(g_pending.side == "BUY" && g_pending.invalidation > 0.0)
      invalidated = tick.bid <= g_pending.invalidation;

   if(g_pending.side == "SELL" && g_pending.invalidation > 0.0)
      invalidated = tick.ask >= g_pending.invalidation;

   if(invalidated)
   {
      if(OrderSelect(g_pending.ticket))
         trade.OrderDelete(g_pending.ticket);

      g_pendingInvalidated++;

      if(InpLogDecisions)
         Print(
            "BACKTEST PENDING INVALIDATED | ",
            g_pending.strategy,
            " | invalidation=",
            DoubleToString(g_pending.invalidation, _Digits)
         );

      ResetPending();
      return;
   }

   if(!OrderSelect(g_pending.ticket))
   {
      if(!AttachPositionFromPending())
         ResetPending();
   }
}

// ============================================================
// POSITION MANAGEMENT
// ============================================================

bool ClosePartial(double requestedVolume)
{
   if(!g_pos.active || !PositionSelect(_Symbol))
      return false;

   ulong ticket = (ulong)PositionGetInteger(POSITION_TICKET);
   double currentVolume = PositionGetDouble(POSITION_VOLUME);

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(minLot <= 0.0) minLot = 0.01;
   if(step <= 0.0) step = 0.01;

   double closeVolume = MathFloor(requestedVolume / step) * step;
   closeVolume = NormalizeDouble(closeVolume, 2);

   double remaining = NormalizeDouble(currentVolume - closeVolume, 2);

   if(closeVolume < minLot || remaining < minLot)
      return trade.PositionClose(ticket);

   ENUM_ACCOUNT_MARGIN_MODE mode =
      (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);

   if(mode == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      return trade.PositionClosePartial(ticket, closeVolume);

   if(g_pos.side == "BUY")
      return trade.Sell(closeVolume, _Symbol, 0.0, 0.0, 0.0, "R2_TP1");
   else
      return trade.Buy(closeVolume, _Symbol, 0.0, 0.0, 0.0, "R2_TP1");
}

double LatestConfirmedM15Structure(string side)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);

   int copied = CopyRates(_Symbol, PERIOD_M15, 1, 40, rates);

   if(copied < 7)
      return 0.0;

   for(int i = 2; i <= copied - 3; i++)
   {
      if(rates[i].time <= g_pos.open_time)
         continue;

      if(side == "BUY")
      {
         bool pivotLow =
            rates[i].low < rates[i - 1].low &&
            rates[i].low < rates[i - 2].low &&
            rates[i].low <= rates[i + 1].low &&
            rates[i].low <= rates[i + 2].low;

         if(pivotLow)
            return rates[i].low;
      }
      else
      {
         bool pivotHigh =
            rates[i].high > rates[i - 1].high &&
            rates[i].high > rates[i - 2].high &&
            rates[i].high >= rates[i + 1].high &&
            rates[i].high >= rates[i + 2].high;

         if(pivotHigh)
            return rates[i].high;
      }
   }

   return 0.0;
}

bool TrailBehindM15Structure()
{
   if(!g_pos.active || !PositionSelect(_Symbol))
      return false;

   double structure = LatestConfirmedM15Structure(g_pos.side);
   if(structure <= 0.0)
      return false;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   long stopLevelPoints = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double brokerDistance = stopLevelPoints * _Point;
   double spreadDistance = MathMax(0.0, tick.ask - tick.bid);
   double buffer = MathMax(brokerDistance, spreadDistance * 1.5);

   if(buffer < _Point)
      buffer = _Point;

   double newSL = 0.0;

   if(g_pos.side == "BUY")
   {
      newSL = structure - buffer;

      if(
         newSL <= g_pos.sl + _Point ||
         newSL >= tick.bid - brokerDistance
      )
         return false;
   }
   else
   {
      newSL = structure + buffer;

      if(
         (g_pos.sl > 0.0 && newSL >= g_pos.sl - _Point) ||
         newSL <= tick.ask + brokerDistance
      )
         return false;
   }

   newSL = NormalizePrice(newSL);
   ulong ticket = (ulong)PositionGetInteger(POSITION_TICKET);

   if(!trade.PositionModify(ticket, newSL, NormalizePrice(g_pos.tp2)))
      return false;

   g_pos.sl = newSL;

   if(InpLogDecisions)
      Print(
         "BACKTEST STRUCTURE TRAIL | newSL=",
         DoubleToString(newSL, _Digits)
      );

   return true;
}

void ManagePosition()
{
   if(!g_pos.active)
      return;

   if(!PositionSelect(_Symbol))
   {
      ResetPositionState();
      return;
   }

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   double currentPrice = g_pos.side == "BUY" ? tick.bid : tick.ask;
   double favorableMove =
      g_pos.side == "BUY"
      ? currentPrice - g_pos.entry
      : g_pos.entry - currentPrice;

   double currentR =
      g_pos.initial_risk > 0.0
      ? favorableMove / g_pos.initial_risk
      : 0.0;

   bool hitTP1 =
      g_pos.side == "BUY"
      ? currentPrice >= g_pos.tp1
      : currentPrice <= g_pos.tp1;

   if(!g_pos.tp1_done && g_pos.tp1 > 0.0 && hitTP1)
   {
      double currentVolume = PositionGetDouble(POSITION_VOLUME);
      double fraction = Clamp(InpTP1ClosePercent, 0.0, 100.0) / 100.0;

      if(ClosePartial(currentVolume * fraction))
      {
         g_tp1Hits++;

         if(PositionSelect(_Symbol))
         {
            g_pos.tp1_done = true;

            if(InpLogDecisions)
               Print("BACKTEST TP1 | ", g_pos.strategy);

            if(InpEnableStructureManagement)
               TrailBehindM15Structure();
         }
         else
         {
            ResetPositionState();
         }

         return;
      }
   }

   if(!InpEnableStructureManagement)
      return;

   if(
      g_lastStructureCheck == 0 ||
      TimeCurrent() - g_lastStructureCheck >= InpStructureCheckEverySeconds
   )
   {
      if(currentR >= 1.0 || g_pos.tp1_done)
         TrailBehindM15Structure();

      g_lastStructureCheck = TimeCurrent();
   }
}

// ============================================================
// VISUAL STATUS
// ============================================================

void ShowStatus(R1State &r1, R1Zones &zones, R2Result &r2)
{
   if(!InpShowVisualStatus)
      return;

   string setupName = r2.setup.exists ? r2.setup.strategy : "NONE";
   string orderType = r2.setup.exists ? r2.setup.order_type : "NONE";

   Comment(
      "XAU R1 + R2 BACKTEST v1\n",
      "R1: ", r1.regime, " / ", r1.strategy, "\n",
      "R2: ", r2.market_state, "\n",
      "Setup: ", setupName,
      " | Order: ", orderType,
      " | Score: ", IntegerToString(r2.setup.score), "\n",
      "BUY zone: ",
      DoubleToString(zones.buy_low, _Digits),
      " - ",
      DoubleToString(zones.buy_high, _Digits),
      "\nSELL zone: ",
      DoubleToString(zones.sell_low, _Digits),
      " - ",
      DoubleToString(zones.sell_high, _Digits),
      "\nPending: ",
      g_pending.active ? "YES" : "NO",
      " | Position: ",
      g_pos.active ? "YES" : "NO"
   );
}

// ============================================================
// EA EVENTS
// ============================================================

int OnInit()
{
   if(StringFind(_Symbol, "XAUUSD") < 0)
   {
      Print("This tester is intended for XAUUSD-family symbols.");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpMaxDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   ResetPending();
   ResetPositionState();

   Print("XAU R1 + R2 FULL AUTO BACKTEST v1 initialized on ", _Symbol);

   return INIT_SUCCEEDED;
}

void OnTick()
{
   ManagePending();
   ManagePosition();

   if(g_pending.active || g_pos.active)
      return;

   datetime now = TimeCurrent();

   if(
      g_lastEval != 0 &&
      now - g_lastEval < InpEvaluateEverySeconds
   )
      return;

   g_lastEval = now;

   R1State r1;
   if(!CalculateR1(r1))
      return;

   R1Zones zones = CalculateR1Zones(r1);
   R2Result r2 = CalculateR2(r1);

   ShowStatus(r1, zones, r2);

   if(InpLogDecisions && r2.setup.exists)
   {
      Print(
         "BACKTEST R2 STATE | market=",
         r2.market_state,
         " | strategy=",
         r2.setup.strategy,
         " | order=",
         r2.setup.order_type,
         " | score=",
         r2.setup.score,
         " | allowed=",
         r2.setup.allowed ? "true" : "false"
      );
   }

   TryExecuteSetup(r1, zones, r2);
}

void OnTradeTransaction(
   const MqlTradeTransaction &trans,
   const MqlTradeRequest &request,
   const MqlTradeResult &result
)
{
   if(g_pending.active)
      AttachPositionFromPending();

   if(g_pos.active && !PositionSelect(_Symbol))
      ResetPositionState();
}

void OnDeinit(const int reason)
{
   Comment("");

   Print(
      "BACKTEST SUMMARY | evaluated=",
      g_setupsEvaluated,
      " | ready=",
      g_readySetups,
      " | orders=",
      g_ordersPlaced,
      " | market=",
      g_marketOrders,
      " | pending=",
      g_pendingOrders,
      " | zone_reject=",
      g_zoneRejected,
      " | placement_reject=",
      g_placementRejected,
      " | pending_expired=",
      g_pendingExpired,
      " | pending_invalidated=",
      g_pendingInvalidated,
      " | tp1_hits=",
      g_tp1Hits,
      " | unique_setups=",
      g_processedSetupKeyCount
   );
}
