// XAU GOLD TREND-PULLBACK ENGINE v1
// TESTER ONLY, fresh rebuild based on a simple trend/location/trigger architecture.
// No Cloudflare, no WebRequest, no grid, no martingale, no averaging.
//
// Core model:
// H1 = trend regime
// M15 = pullback location
// M5 = execution trigger
// One position at a time
// Fixed hard SL on every trade
// TP1 partial at 1R, TP2 at 2R
// Risk-based position sizing with hard lot cap and margin check
// Daily risk guard + max trades/day
//
// This is a research/backtest build. Past/backtest performance does not guarantee future results.

#property strict

#include <Trade/Trade.mqh>

CTrade trade;

// ============================================================
// INPUTS
// ============================================================

input long   InpMagicNumber              = 26100901;

// Risk
input double InpRiskPercent              = 0.75;
input double InpMaxLot                   = 0.03;
input double InpMaxMarginUsagePercent    = 70.0;
input double InpMaxDailyLossPercent      = 2.50;
input int    InpMaxTradesPerDay          = 4;

// Market filters
input double InpMaxSpreadUSD             = 0.60;
input int    InpSessionStartHour         = 7;
input int    InpSessionEndHour           = 20;

// Trend regime
input double InpMinH1ADX                 = 20.0;
input double InpMinH1SlopeATR            = 0.03;

// Pullback location
input double InpZoneATRPad               = 0.15;
input double InpMaxDistanceFromZoneATR   = 0.25;
input double InpBuyRSIMin                = 38.0;
input double InpBuyRSIMax                = 60.0;
input double InpSellRSIMin               = 40.0;
input double InpSellRSIMax               = 62.0;

// Trigger
input int    InpMinTriggerCount          = 1;

// Trade structure
input int    InpSwingLookbackM15         = 8;
input double InpSLATRBuffer              = 0.20;
input double InpTP1_R                    = 1.00;
input double InpTP2_R                    = 2.00;
input double InpTP1ClosePercent          = 50.0;
input double InpBreakEvenLockR           = 0.05;

// Anti-overtrading
input int    InpCooldownMinutes          = 15;

// Tester / logs
input bool   InpShowStatus               = true;
input bool   InpLogTrades                = true;

// ============================================================
// GLOBALS
// ============================================================

int hH1EMA50  = INVALID_HANDLE;
int hH1EMA200 = INVALID_HANDLE;
int hH1ATR    = INVALID_HANDLE;
int hH1ADX    = INVALID_HANDLE;

int hM15EMA20 = INVALID_HANDLE;
int hM15EMA50 = INVALID_HANDLE;
int hM15ATR   = INVALID_HANDLE;
int hM15RSI   = INVALID_HANDLE;

int hM5EMA9   = INVALID_HANDLE;
int hM5RSI    = INVALID_HANDLE;

datetime g_lastM5Bar = 0;
datetime g_lastEntryTime = 0;

int g_dayKey = -1;
double g_dayStartEquity = 0.0;
int g_tradesToday = 0;

bool g_positionTracked = false;
double g_entry = 0.0;
double g_initialSL = 0.0;
double g_initialRisk = 0.0;
double g_tp1 = 0.0;
double g_tp2 = 0.0;
double g_initialVolume = 0.0;
bool g_tp1Done = false;
string g_side = "";

long g_setups = 0;
long g_locationPass = 0;
long g_triggerPass = 0;
long g_orders = 0;
long g_buyOrders = 0;
long g_sellOrders = 0;
long g_tp1Hits = 0;
long g_dailyGuardBlocks = 0;
long g_spreadBlocks = 0;
long g_sessionBlocks = 0;

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

bool BufferValue(
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

bool GetClosedRates(
   ENUM_TIMEFRAMES tf,
   int count,
   MqlRates &rates[]
)
{
   ArraySetAsSeries(rates, true);

   return CopyRates(
      _Symbol,
      tf,
      1,
      count,
      rates
   ) == count;
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
   double h = -DBL_MAX;

   for(int i = start; i < start + count; i++)
      h = MathMax(h, rates[i].high);

   return h;
}

double LowestLow(MqlRates &rates[], int start, int count)
{
   double l = DBL_MAX;

   for(int i = start; i < start + count; i++)
      l = MathMin(l, rates[i].low);

   return l;
}

int CurrentDayKey()
{
   MqlDateTime tm;
   TimeToStruct(TimeCurrent(), tm);

   return tm.year * 10000 + tm.mon * 100 + tm.day;
}

void ResetDailyStateIfNeeded()
{
   int key = CurrentDayKey();

   if(key == g_dayKey)
      return;

   g_dayKey = key;
   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_tradesToday = 0;
}

bool DailyGuardAllowsTrade()
{
   ResetDailyStateIfNeeded();

   if(g_tradesToday >= InpMaxTradesPerDay)
   {
      g_dailyGuardBlocks++;
      return false;
   }

   if(g_dayStartEquity <= 0.0)
      return true;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double minEquity =
      g_dayStartEquity *
      (1.0 - InpMaxDailyLossPercent / 100.0);

   if(equity <= minEquity)
   {
      g_dailyGuardBlocks++;
      return false;
   }

   return true;
}

bool SessionAllowsTrade()
{
   MqlDateTime tm;
   TimeToStruct(TimeCurrent(), tm);

   int h = tm.hour;

   if(InpSessionStartHour == InpSessionEndHour)
      return true;

   if(InpSessionStartHour < InpSessionEndHour)
      return h >= InpSessionStartHour && h < InpSessionEndHour;

   return h >= InpSessionStartHour || h < InpSessionEndHour;
}

bool SpreadAllowsTrade(MqlTick &tick)
{
   return (tick.ask - tick.bid) <= InpMaxSpreadUSD;
}

double NormalizeVolumeDown(double volume)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(minLot <= 0.0) minLot = 0.01;
   if(step <= 0.0) step = 0.01;
   if(maxLot <= 0.0) maxLot = volume;

   double cap = MathMin(maxLot, InpMaxLot);
   volume = MathMin(volume, cap);

   double steps = MathFloor((volume + 1e-12) / step);
   double normalized = steps * step;

   if(normalized < minLot)
      return 0.0;

   return NormalizeDouble(normalized, 2);
}

double RiskLot(
   string side,
   double entry,
   double sl
)
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * InpRiskPercent / 100.0;

   if(riskMoney <= 0.0)
      return 0.0;

   ENUM_ORDER_TYPE orderType =
      side == "BUY"
      ? ORDER_TYPE_BUY
      : ORDER_TYPE_SELL;

   double oneLotLoss = 0.0;

   if(!OrderCalcProfit(
         orderType,
         _Symbol,
         1.0,
         entry,
         sl,
         oneLotLoss
      ))
      return 0.0;

   oneLotLoss = MathAbs(oneLotLoss);

   if(oneLotLoss <= 0.0)
      return 0.0;

   double lot = NormalizeVolumeDown(riskMoney / oneLotLoss);

   if(lot <= 0.0)
      return 0.0;

   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double maxMargin = freeMargin * InpMaxMarginUsagePercent / 100.0;
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   if(step <= 0.0) step = 0.01;
   if(minLot <= 0.0) minLot = 0.01;

   while(lot >= minLot)
   {
      double requiredMargin = 0.0;

      if(
         OrderCalcMargin(
            orderType,
            _Symbol,
            lot,
            entry,
            requiredMargin
         ) &&
         requiredMargin <= maxMargin
      )
      {
         return NormalizeVolumeDown(lot);
      }

      lot = NormalizeVolumeDown(lot - step);
   }

   return 0.0;
}

bool CooldownAllowsTrade()
{
   if(g_lastEntryTime <= 0)
      return true;

   return
      TimeCurrent() - g_lastEntryTime >=
      InpCooldownMinutes * 60;
}

// ============================================================
// MARKET MODEL
// ============================================================

struct SetupState
{
   bool valid;
   string side;
   string trend;
   string location;
   string trigger;
   int trigger_count;
   double zone_low;
   double zone_high;
   double entry;
   double sl;
   double tp1;
   double tp2;
   double rr2;
   double atr15;
};

SetupState EmptySetup()
{
   SetupState s;

   s.valid = false;
   s.side = "NONE";
   s.trend = "NONE";
   s.location = "NONE";
   s.trigger = "NONE";
   s.trigger_count = 0;
   s.zone_low = 0.0;
   s.zone_high = 0.0;
   s.entry = 0.0;
   s.sl = 0.0;
   s.tp1 = 0.0;
   s.tp2 = 0.0;
   s.rr2 = 0.0;
   s.atr15 = 0.0;

   return s;
}

string H1Trend(
   MqlRates &h1[],
   double ema50,
   double ema50Old,
   double ema200,
   double atr1,
   double adx,
   double plusDI,
   double minusDI
)
{
   if(atr1 <= 0.0)
      return "NONE";

   double slopeATR =
      (ema50 - ema50Old) / atr1;

   bool buy =
      h1[0].close > ema50 &&
      ema50 > ema200 &&
      slopeATR >= InpMinH1SlopeATR &&
      adx >= InpMinH1ADX &&
      plusDI > minusDI;

   bool sell =
      h1[0].close < ema50 &&
      ema50 < ema200 &&
      slopeATR <= -InpMinH1SlopeATR &&
      adx >= InpMinH1ADX &&
      minusDI > plusDI;

   if(buy) return "BUY";
   if(sell) return "SELL";

   return "NONE";
}

SetupState EvaluateSetup()
{
   SetupState s = EmptySetup();

   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return s;

   MqlRates h1[];
   MqlRates m15[];
   MqlRates m5[];

   if(!GetClosedRates(PERIOD_H1, 6, h1))
      return s;

   int m15Count = MathMax(20, InpSwingLookbackM15 + 4);

   if(!GetClosedRates(PERIOD_M15, m15Count, m15))
      return s;

   if(!GetClosedRates(PERIOD_M5, 8, m5))
      return s;

   double h1EMA50 = 0.0;
   double h1EMA50Old = 0.0;
   double h1EMA200 = 0.0;
   double h1ATR = 0.0;
   double h1ADX = 0.0;
   double h1PlusDI = 0.0;
   double h1MinusDI = 0.0;

   double m15EMA20 = 0.0;
   double m15EMA50 = 0.0;
   double m15ATR = 0.0;
   double m15RSI = 0.0;

   double m5EMA9 = 0.0;
   double m5EMA9Prev = 0.0;
   double m5RSI = 0.0;

   if(!BufferValue(hH1EMA50, 0, 1, h1EMA50)) return s;
   if(!BufferValue(hH1EMA50, 0, 4, h1EMA50Old)) return s;
   if(!BufferValue(hH1EMA200, 0, 1, h1EMA200)) return s;
   if(!BufferValue(hH1ATR, 0, 1, h1ATR)) return s;
   if(!BufferValue(hH1ADX, 0, 1, h1ADX)) return s;
   if(!BufferValue(hH1ADX, 1, 1, h1PlusDI)) return s;
   if(!BufferValue(hH1ADX, 2, 1, h1MinusDI)) return s;

   if(!BufferValue(hM15EMA20, 0, 1, m15EMA20)) return s;
   if(!BufferValue(hM15EMA50, 0, 1, m15EMA50)) return s;
   if(!BufferValue(hM15ATR, 0, 1, m15ATR)) return s;
   if(!BufferValue(hM15RSI, 0, 1, m15RSI)) return s;

   if(!BufferValue(hM5EMA9, 0, 1, m5EMA9)) return s;
   if(!BufferValue(hM5EMA9, 0, 2, m5EMA9Prev)) return s;
   if(!BufferValue(hM5RSI, 0, 1, m5RSI)) return s;

   string trend =
      H1Trend(
         h1,
         h1EMA50,
         h1EMA50Old,
         h1EMA200,
         h1ATR,
         h1ADX,
         h1PlusDI,
         h1MinusDI
      );

   s.trend = trend;
   s.atr15 = m15ATR;

   if(trend == "NONE" || m15ATR <= 0.0)
      return s;

   bool buy = trend == "BUY";

   double zoneLow =
      MathMin(m15EMA20, m15EMA50) -
      InpZoneATRPad * m15ATR;

   double zoneHigh =
      MathMax(m15EMA20, m15EMA50) +
      InpZoneATRPad * m15ATR;

   s.zone_low = NormalizePrice(zoneLow);
   s.zone_high = NormalizePrice(zoneHigh);

   double price = buy ? tick.ask : tick.bid;

   double distance = 0.0;

   if(price < zoneLow)
      distance = zoneLow - price;
   else if(price > zoneHigh)
      distance = price - zoneHigh;

   bool m15Touched =
      m15[0].low <= zoneHigh &&
      m15[0].high >= zoneLow;

   bool nearZone =
      distance <=
      InpMaxDistanceFromZoneATR * m15ATR;

   bool rsiLocation =
      buy
      ? (
           m15RSI >= InpBuyRSIMin &&
           m15RSI <= InpBuyRSIMax
        )
      : (
           m15RSI >= InpSellRSIMin &&
           m15RSI <= InpSellRSIMax
        );

   bool locationGood =
      m15Touched &&
      nearZone &&
      rsiLocation;

   s.location =
      locationGood
      ? "GOOD"
      : "WAIT";

   if(!locationGood)
      return s;

   g_locationPass++;

   MqlRates b = m5[0];
   MqlRates prev = m5[1];

   double body = MathAbs(b.close - b.open);
   double lowerWick = MathMin(b.open, b.close) - b.low;
   double upperWick = b.high - MathMax(b.open, b.close);
   double closePos = CandleClosePosition(b);

   bool rejection =
      buy
      ? (
           b.close > b.open &&
           closePos >= 0.65 &&
           lowerWick >= 0.50 * MathMax(body, _Point)
        )
      : (
           b.close < b.open &&
           closePos <= 0.35 &&
           upperWick >= 0.50 * MathMax(body, _Point)
        );

   bool emaRecapture =
      buy
      ? (
           b.close > m5EMA9 &&
           prev.close <= m5EMA9Prev &&
           m5RSI >= 50.0
        )
      : (
           b.close < m5EMA9 &&
           prev.close >= m5EMA9Prev &&
           m5RSI <= 50.0
        );

   double priorHigh =
      MathMax(
         m5[1].high,
         MathMax(m5[2].high, m5[3].high)
      );

   double priorLow =
      MathMin(
         m5[1].low,
         MathMin(m5[2].low, m5[3].low)
      );

   bool microBreak =
      buy
      ? b.close > priorHigh
      : b.close < priorLow;

   int triggers = 0;
   string triggerText = "";

   if(rejection)
   {
      triggers++;
      triggerText = "REJECTION";
   }

   if(emaRecapture)
   {
      triggers++;

      if(triggerText != "") triggerText += "+";
      triggerText += "EMA9_RECAPTURE";
   }

   if(microBreak)
   {
      triggers++;

      if(triggerText != "") triggerText += "+";
      triggerText += "MICRO_BREAK";
   }

   s.trigger_count = triggers;
   s.trigger =
      triggerText == ""
      ? "NONE"
      : triggerText;

   if(triggers < InpMinTriggerCount)
      return s;

   g_triggerPass++;

   double swing =
      buy
      ? LowestLow(m15, 0, InpSwingLookbackM15)
      : HighestHigh(m15, 0, InpSwingLookbackM15);

   double entry =
      buy
      ? tick.ask
      : tick.bid;

   double sl =
      buy
      ? swing - InpSLATRBuffer * m15ATR
      : swing + InpSLATRBuffer * m15ATR;

   double risk = MathAbs(entry - sl);

   if(risk <= 0.0)
      return s;

   // Avoid structurally absurd stops that usually indicate stale location.
   if(risk < 0.45 * m15ATR || risk > 2.50 * m15ATR)
      return s;

   double tp1 =
      buy
      ? entry + InpTP1_R * risk
      : entry - InpTP1_R * risk;

   double tp2 =
      buy
      ? entry + InpTP2_R * risk
      : entry - InpTP2_R * risk;

   s.valid = true;
   s.side = trend;
   s.entry = NormalizePrice(entry);
   s.sl = NormalizePrice(sl);
   s.tp1 = NormalizePrice(tp1);
   s.tp2 = NormalizePrice(tp2);
   s.rr2 = InpTP2_R;

   return s;
}

// ============================================================
// EXECUTION
// ============================================================

bool OpenSetup(SetupState &s)
{
   if(!s.valid)
      return false;

   double lot =
      RiskLot(
         s.side,
         s.entry,
         s.sl
      );

   if(lot <= 0.0)
      return false;

   bool ok = false;

   if(s.side == "BUY")
   {
      ok = trade.Buy(
         lot,
         _Symbol,
         0.0,
         s.sl,
         s.tp2,
         "GOLD_TREND_PULLBACK"
      );
   }
   else
   {
      ok = trade.Sell(
         lot,
         _Symbol,
         0.0,
         s.sl,
         s.tp2,
         "GOLD_TREND_PULLBACK"
      );
   }

   if(!ok)
   {
      if(InpLogTrades)
      {
         Print(
            "ORDER FAILED | ",
            trade.ResultRetcode(),
            " | ",
            trade.ResultRetcodeDescription()
         );
      }

      return false;
   }

   if(!PositionSelect(_Symbol))
      return false;

   g_positionTracked = true;
   g_entry = PositionGetDouble(POSITION_PRICE_OPEN);
   g_initialSL = s.sl;
   g_initialRisk = MathAbs(g_entry - g_initialSL);
   g_tp1 =
      s.side == "BUY"
      ? g_entry + InpTP1_R * g_initialRisk
      : g_entry - InpTP1_R * g_initialRisk;
   g_tp2 =
      s.side == "BUY"
      ? g_entry + InpTP2_R * g_initialRisk
      : g_entry - InpTP2_R * g_initialRisk;
   g_initialVolume = PositionGetDouble(POSITION_VOLUME);
   g_tp1Done = false;
   g_side = s.side;
   g_lastEntryTime = TimeCurrent();

   g_tradesToday++;
   g_orders++;

   if(s.side == "BUY") g_buyOrders++;
   else g_sellOrders++;

   if(InpLogTrades)
   {
      Print(
         "EXECUTE | ",
         s.side,
         " | trigger=",
         s.trigger,
         " | zone=",
         DoubleToString(s.zone_low, _Digits),
         "-",
         DoubleToString(s.zone_high, _Digits),
         " | entry=",
         DoubleToString(g_entry, _Digits),
         " | sl=",
         DoubleToString(g_initialSL, _Digits),
         " | tp1=",
         DoubleToString(g_tp1, _Digits),
         " | tp2=",
         DoubleToString(g_tp2, _Digits),
         " | lot=",
         DoubleToString(g_initialVolume, 2),
         " | risk%=",
         DoubleToString(InpRiskPercent, 2)
      );
   }

   return true;
}

double NormalizeCloseVolume(double requested)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(minLot <= 0.0) minLot = 0.01;
   if(step <= 0.0) step = 0.01;

   double v =
      MathFloor(
         (requested + 1e-12) / step
      ) * step;

   return NormalizeDouble(v, 2);
}

bool ClosePartialAtTP1()
{
   if(!PositionSelect(_Symbol))
      return false;

   ulong ticket =
      (ulong)PositionGetInteger(POSITION_TICKET);

   double volume =
      PositionGetDouble(POSITION_VOLUME);

   double minLot =
      SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   if(minLot <= 0.0) minLot = 0.01;

   double closeVolume =
      NormalizeCloseVolume(
         volume *
         Clamp(
            InpTP1ClosePercent,
            0.0,
            100.0
         ) /
         100.0
      );

   double remain =
      NormalizeCloseVolume(
         volume - closeVolume
      );

   if(
      closeVolume < minLot ||
      remain < minLot
   )
   {
      // If the lot is too small to split, keep full position for TP2
      // but still move the stop to locked break-even.
      return true;
   }

   return
      trade.PositionClosePartial(
         ticket,
         closeVolume
      );
}

void ManagePosition()
{
   if(!PositionSelect(_Symbol))
   {
      g_positionTracked = false;
      return;
   }

   if(!g_positionTracked)
   {
      // Safety reconstruction if the tester event order changed.
      g_positionTracked = true;
      g_entry = PositionGetDouble(POSITION_PRICE_OPEN);
      g_initialSL = PositionGetDouble(POSITION_SL);
      g_initialRisk = MathAbs(g_entry - g_initialSL);
      g_initialVolume = PositionGetDouble(POSITION_VOLUME);

      long type = PositionGetInteger(POSITION_TYPE);
      g_side =
         type == POSITION_TYPE_BUY
         ? "BUY"
         : "SELL";

      g_tp1 =
         g_side == "BUY"
         ? g_entry + InpTP1_R * g_initialRisk
         : g_entry - InpTP1_R * g_initialRisk;

      g_tp2 =
         g_side == "BUY"
         ? g_entry + InpTP2_R * g_initialRisk
         : g_entry - InpTP2_R * g_initialRisk;
   }

   if(g_tp1Done || g_initialRisk <= 0.0)
      return;

   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return;

   double current =
      g_side == "BUY"
      ? tick.bid
      : tick.ask;

   bool hit =
      g_side == "BUY"
      ? current >= g_tp1
      : current <= g_tp1;

   if(!hit)
      return;

   if(!ClosePartialAtTP1())
      return;

   if(!PositionSelect(_Symbol))
   {
      g_tp1Done = true;
      return;
   }

   double lock =
      g_side == "BUY"
      ? g_entry + InpBreakEvenLockR * g_initialRisk
      : g_entry - InpBreakEvenLockR * g_initialRisk;

   ulong ticket =
      (ulong)PositionGetInteger(POSITION_TICKET);

   if(
      trade.PositionModify(
         ticket,
         NormalizePrice(lock),
         NormalizePrice(g_tp2)
      )
   )
   {
      g_tp1Done = true;
      g_tp1Hits++;

      if(InpLogTrades)
      {
         Print(
            "TP1 HIT | ",
            g_side,
            " | lockedSL=",
            DoubleToString(lock, _Digits)
         );
      }
   }
}

// ============================================================
// STATUS
// ============================================================

void ShowStatus(SetupState &s)
{
   if(!InpShowStatus)
      return;

   string state =
      PositionSelect(_Symbol)
      ? "IN POSITION"
      : s.valid
        ? "READY"
        : "WAIT";

   Comment(
      "XAU GOLD TREND-PULLBACK ENGINE v1\n",
      "STATE: ", state, "\n",
      "H1 TREND: ", s.trend, "\n",
      "M15 LOCATION: ", s.location,
      " | ",
      DoubleToString(s.zone_low, _Digits),
      " - ",
      DoubleToString(s.zone_high, _Digits),
      "\nM5 TRIGGER: ",
      IntegerToString(s.trigger_count),
      " | ",
      s.trigger,
      "\nTODAY TRADES: ",
      IntegerToString(g_tradesToday),
      "/",
      IntegerToString(InpMaxTradesPerDay),
      "\nDAY START EQUITY: ",
      DoubleToString(g_dayStartEquity, 2),
      " | EQUITY: ",
      DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2)
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
         "TESTER ONLY: XAU_GOLD_TREND_PULLBACK_BACKTEST_v1 cannot run on a normal chart."
      );

      return INIT_FAILED;
   }

   if(StringFind(_Symbol, "XAUUSD") < 0)
   {
      Print("This tester is for XAUUSD-family symbols.");
      return INIT_FAILED;
   }

   if(_Period != PERIOD_M5)
   {
      Print("Run this tester on M5.");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   hH1EMA50  = iMA(_Symbol, PERIOD_H1, 50, 0, MODE_EMA, PRICE_CLOSE);
   hH1EMA200 = iMA(_Symbol, PERIOD_H1, 200, 0, MODE_EMA, PRICE_CLOSE);
   hH1ATR    = iATR(_Symbol, PERIOD_H1, 14);
   hH1ADX    = iADX(_Symbol, PERIOD_H1, 14);

   hM15EMA20 = iMA(_Symbol, PERIOD_M15, 20, 0, MODE_EMA, PRICE_CLOSE);
   hM15EMA50 = iMA(_Symbol, PERIOD_M15, 50, 0, MODE_EMA, PRICE_CLOSE);
   hM15ATR   = iATR(_Symbol, PERIOD_M15, 14);
   hM15RSI   = iRSI(_Symbol, PERIOD_M15, 14, PRICE_CLOSE);

   hM5EMA9   = iMA(_Symbol, PERIOD_M5, 9, 0, MODE_EMA, PRICE_CLOSE);
   hM5RSI    = iRSI(_Symbol, PERIOD_M5, 14, PRICE_CLOSE);

   if(
      hH1EMA50  == INVALID_HANDLE ||
      hH1EMA200 == INVALID_HANDLE ||
      hH1ATR    == INVALID_HANDLE ||
      hH1ADX    == INVALID_HANDLE ||
      hM15EMA20 == INVALID_HANDLE ||
      hM15EMA50 == INVALID_HANDLE ||
      hM15ATR   == INVALID_HANDLE ||
      hM15RSI   == INVALID_HANDLE ||
      hM5EMA9   == INVALID_HANDLE ||
      hM5RSI    == INVALID_HANDLE
   )
   {
      Print("Indicator handle creation failed.");
      return INIT_FAILED;
   }

   ResetDailyStateIfNeeded();

   Print(
      "XAU GOLD TREND-PULLBACK ENGINE v1 initialized | ",
      _Symbol,
      " | M5 execution | H1 trend | M15 location"
   );

   return INIT_SUCCEEDED;
}

void OnTick()
{
   ResetDailyStateIfNeeded();
   ManagePosition();

   datetime currentM5 =
      iTime(
         _Symbol,
         PERIOD_M5,
         0
      );

   if(currentM5 <= 0)
      return;

   if(currentM5 == g_lastM5Bar)
      return;

   g_lastM5Bar = currentM5;

   SetupState s = EvaluateSetup();
   ShowStatus(s);

   if(PositionSelect(_Symbol))
      return;

   g_setups++;

   if(!SessionAllowsTrade())
   {
      g_sessionBlocks++;
      return;
   }

   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return;

   if(!SpreadAllowsTrade(tick))
   {
      g_spreadBlocks++;
      return;
   }

   if(!DailyGuardAllowsTrade())
      return;

   if(!CooldownAllowsTrade())
      return;

   if(!s.valid)
      return;

   OpenSetup(s);
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
      g_positionTracked = false;
      g_tp1Done = false;
      g_side = "";
   }
}

void OnDeinit(const int reason)
{
   Comment("");

   if(hH1EMA50  != INVALID_HANDLE) IndicatorRelease(hH1EMA50);
   if(hH1EMA200 != INVALID_HANDLE) IndicatorRelease(hH1EMA200);
   if(hH1ATR    != INVALID_HANDLE) IndicatorRelease(hH1ATR);
   if(hH1ADX    != INVALID_HANDLE) IndicatorRelease(hH1ADX);
   if(hM15EMA20 != INVALID_HANDLE) IndicatorRelease(hM15EMA20);
   if(hM15EMA50 != INVALID_HANDLE) IndicatorRelease(hM15EMA50);
   if(hM15ATR   != INVALID_HANDLE) IndicatorRelease(hM15ATR);
   if(hM15RSI   != INVALID_HANDLE) IndicatorRelease(hM15RSI);
   if(hM5EMA9   != INVALID_HANDLE) IndicatorRelease(hM5EMA9);
   if(hM5RSI    != INVALID_HANDLE) IndicatorRelease(hM5RSI);

   Print(
      "SUMMARY | setups=",
      g_setups,
      " | location_pass=",
      g_locationPass,
      " | trigger_pass=",
      g_triggerPass,
      " | orders=",
      g_orders,
      " | buys=",
      g_buyOrders,
      " | sells=",
      g_sellOrders,
      " | tp1_hits=",
      g_tp1Hits,
      " | daily_guard_blocks=",
      g_dailyGuardBlocks,
      " | spread_blocks=",
      g_spreadBlocks,
      " | session_blocks=",
      g_sessionBlocks
   );
}
