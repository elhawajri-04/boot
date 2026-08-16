//+------------------------------------------------------------------+
//|                                  No_Counter_Trades_Clean.mq5     |
//|        Session Breakout Strategy - FTMO Fixed Lots Edition       |
//+------------------------------------------------------------------+
#property copyright "FTMO Fixed Lots Edition - Clean"
#property version   "3.80"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//==================== Anchor Candle Settings ====================
input group "=== Anchor Candles (Broker Server Time) ==="
input int InpAnchor1Hour = 9;
input int InpAnchor1Min  = 0;
input int InpAnchor2Hour = 16;
input int InpAnchor2Min  = 30;

//==================== Money Management ====================
input group "=== Money Management ==="
input bool   InpUseDynamicLots = true;   // Calculate lot size based on % risk instead of fixed lots
input double InpRiskPercent    = 0.5;    // % Risk per trade based on Equity (if InpUseDynamicLots = true)
input double InpLots           = 0.10;   // Fixed Lot size (used only if InpUseDynamicLots = false)
input double InpRR             = 2.0;    // Risk to Reward Ratio

//==================== Spread Filter ====================
input group "=== Spread Protection ==="
input bool   InpUseSpreadFilter    = true;
input double InpMaxSpreadPoints    = 350;  // Maximum allowed spread in points at entry

//==================== Trade Frequency Guard ====================
input group "=== Trade Frequency Guard ==="
input bool   InpUseMaxTradesPerDay = true;
input int    InpMaxTradesPerDay    = 4;    // Maximum new trades per day

//==================== Counter Stop Order (Reversal on Original SL) ====================
input group "=== Counter Stop Order ==="
input bool   InpUseCounterOrder      = true;  // Place opposite pending Stop order at original SL level
input double InpCounterSLPoints      = 10;    // Counter order SL distance (points)
input double InpCounterTPPoints      = 10;    // Counter order TP distance (points)
input double InpCounterLotMultiplier = 5.0;   // Counter order lot = original lot * this multiplier
input bool   InpCancelCounterOnParentClose = true; // Delete counter pending order if parent trade closes before it triggers

//==================== FTMO Protection (Two-Layer) ====================
input group "=== FTMO Protection ==="
input bool   InpUseFTMOProtection = true;   // Master switch for all FTMO safety checks
input double InpHardFloorPercent  = 3.5;    // Internal safety trigger (% of Initial Balance) - this is what actually closes & blocks
input double InpDailyLossPercent  = 4.0;    // FTMO official daily loss limit (% of Initial Balance) - reference only, hard floor trips first
input double InpTotalLossPercent  = 8.0;    // FTMO max total loss limit (% of Initial Balance)

//==================== General ====================
input group "=== General ==="
input bool   InpAllowSimultaneous  = false;
input ulong  InpMagic              = 203002;

//==================== Global Variables ====================
datetime g_last_bar_time  = 0;

double   g_anchorAHigh    = EMPTY_VALUE;
double   g_anchorALow     = EMPTY_VALUE;
bool     g_anchorAActive  = false;

double   g_anchorBHigh    = EMPTY_VALUE;
double   g_anchorBLow     = EMPTY_VALUE;
bool     g_anchorBActive  = false;

// Trades Counter
int      g_tradesToday    = 0;
datetime g_tradesCounterDay = 0;

//==================== FTMO Protection State (Two-Layer) ====================
double   g_initialBalance   = 0.0;   // Balance snapshot taken once at EA init (proxy for account Initial Balance)
datetime g_dayStartDate     = 0;     // midnight (server time) of the current trading day
double   g_dayStartBalance  = 0.0;   // account balance captured at the start of the day
bool     g_dailyBlocked     = false; // true once hard floor / daily loss tripped for the current day
bool     g_totalBlocked     = false; // true once total loss floor tripped - permanent until manual reset

//==================== Counter Order Tracking ====================
struct CounterOrderLink
{
   ulong parentTicket;   // position ticket of the original trade
   ulong counterTicket;  // pending order ticket of the opposite Stop order
};
CounterOrderLink g_counterLinks[];

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetTypeFillingBySymbol(_Symbol);

   g_last_bar_time = 0;
   g_anchorAHigh   = EMPTY_VALUE;
   g_anchorALow    = EMPTY_VALUE;
   g_anchorAActive = false;
   g_anchorBHigh   = EMPTY_VALUE;
   g_anchorBLow    = EMPTY_VALUE;
   g_anchorBActive = false;
   g_tradesToday   = 0;

   ArrayResize(g_counterLinks, 0);

   // --- FTMO protection init ---
   g_initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_dayStartDate    = 0;    // force CheckFTMOProtection() below to snapshot day-start balance
   g_dayStartBalance = g_initialBalance;
   g_dailyBlocked    = false;
   g_totalBlocked    = false;

   CheckFTMOProtection(); // set up today's start balance immediately

   Print("EA Ready | Lot Mode: ", (InpUseDynamicLots ? "Dynamic (% Risk)" : "Fixed Lots"));

   if(InpUseFTMOProtection)
      Print("FTMO Protection ON | Initial Balance: ", DoubleToString(g_initialBalance, 2),
            " | Hard Floor: ", DoubleToString(InpHardFloorPercent, 2), "%",
            " | Daily Loss Ref: ", DoubleToString(InpDailyLossPercent, 2), "%",
            " | Total Loss: ", DoubleToString(InpTotalLossPercent, 2), "%");
   else
      Print("FTMO Protection OFF - trading with no daily/total loss safeguard!");

   if(InpUseCounterOrder)
      Print("Counter Stop Order ON | SL: ", DoubleToString(InpCounterSLPoints, 0),
            " pts | TP: ", DoubleToString(InpCounterTPPoints, 0),
            " pts | Lot Multiplier: x", DoubleToString(InpCounterLotMultiplier, 2),
            " | Auto-cancel on parent close: ", (InpCancelCounterOnParentClose ? "Yes" : "No"));

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
}

//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC)  == (long)InpMagic)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
bool IsSpreadHealthy()
{
   if(!InpUseSpreadFilter) return true;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spreadPoints = (ask - bid) / _Point;

   if(spreadPoints <= InpMaxSpreadPoints) return true;

   Print("Trade Canceled: Current spread (", DoubleToString(spreadPoints, 1),
         ") exceeds maximum allowed limit (", DoubleToString(InpMaxSpreadPoints, 1), ").");
   return false;
}

//+------------------------------------------------------------------+
bool HasReachedMaxTradesToday()
{
   if(!InpUseMaxTradesPerDay) return false;
   if(g_tradesToday >= InpMaxTradesPerDay)
   {
      Print("Max daily trades limit reached (", InpMaxTradesPerDay, ").");
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
// Normalize a raw lot value to the symbol's min/max/step constraints
//+------------------------------------------------------------------+
double NormalizeLots(double lots)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(lotStep > 0)
      lots = MathFloor(lots / lotStep) * lotStep;

   if(lots < minLot) lots = minLot;
   if(lots > maxLot) lots = maxLot;

   return lots;
}

//+------------------------------------------------------------------+
// Calculate lot size based on a fixed risk percentage of Equity and actual SL distance
//+------------------------------------------------------------------+
double CalculateDynamicLots(double slDistancePoints)
{
   if(slDistancePoints <= 0) return 0.0;

   double equity     = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount = equity * (InpRiskPercent / 100.0);

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0) tickSize = _Point;

   // Value of 1 point per 1.0 lot
   double valuePerPointPerLot = tickValue * (_Point / tickSize);
   if(valuePerPointPerLot <= 0) return 0.0;

   double slRiskPerLot = slDistancePoints * valuePerPointPerLot;
   if(slRiskPerLot <= 0) return 0.0;

   double lots = riskAmount / slRiskPerLot;
   lots = NormalizeLots(lots);

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(lots < minLot)
   {
      Print("Calculated lot size (", DoubleToString(lots, 2), ") is below minimum allowed lot size (", minLot,
            ") - Trade canceled to prevent higher risk than specified.");
      return 0.0;
   }

   return lots;
}

//+------------------------------------------------------------------+
void CloseAllMyPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC)  == (long)InpMagic)
         trade.PositionClose(ticket);
   }
}

//+------------------------------------------------------------------+
//| Finds a currently open position (our symbol/magic) that does not |
//| yet have a counter order linked to it. Used right after a market |
//| order executes to reliably get its position ticket, avoiding the |
//| history-cache lookup which can lag by a tick in the Strategy     |
//| Tester and silently return 0.                                    |
//+------------------------------------------------------------------+
ulong FindUnlinkedPositionTicket()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagic) continue;

      bool linked = false;
      for(int j = 0; j < ArraySize(g_counterLinks); j++)
      {
         if(g_counterLinks[j].parentTicket == ticket) { linked = true; break; }
      }
      if(!linked) return ticket;
   }
   return 0;
}

//+------------------------------------------------------------------+
//| Places the opposite pending Stop order at the original trade's   |
//| SL price:                                                        |
//|   Original BUY  (SL below entry) -> SELL STOP at that SL level   |
//|   Original SELL (SL above entry) -> BUY STOP  at that SL level   |
//| Lot = original lot * InpCounterLotMultiplier                     |
//| Its own SL/TP sit InpCounterPoints away on each side              |
//+------------------------------------------------------------------+
void PlaceCounterOrder(ulong parentPositionTicket, double parentSL, bool originalIsBuy, double originalLots)
{
   if(!InpUseCounterOrder) return;
   if(parentSL <= 0) return;

   double counterLots = NormalizeLots(originalLots * InpCounterLotMultiplier);
   if(counterLots <= 0) return;

   double slDist = InpCounterSLPoints * _Point;
   double tpDist = InpCounterTPPoints * _Point;
   double price  = parentSL;
   double sl, tp;
   bool sent = false;

   if(originalIsBuy)
   {
      // Original BUY -> its SL is below entry -> place SELL STOP at that level
      // A Sell Stop triggers as price falls to 'price', so its own SL sits above (loss if price reverses up)
      // and its own TP sits below (profit if price keeps falling)
      sl = price + slDist;
      tp = price - tpDist;
      sent = trade.SellStop(counterLots, NormalizeDouble(price, _Digits), _Symbol,
                             NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits),
                             ORDER_TIME_GTC, 0, "Counter SellStop");
   }
   else
   {
      // Original SELL -> its SL is above entry -> place BUY STOP at that level
      // A Buy Stop triggers as price rises to 'price', so its own SL sits below
      // and its own TP sits above
      sl = price - slDist;
      tp = price + tpDist;
      sent = trade.BuyStop(counterLots, NormalizeDouble(price, _Digits), _Symbol,
                            NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits),
                            ORDER_TIME_GTC, 0, "Counter BuyStop");
   }

   if(sent)
   {
      ulong counterTicket = trade.ResultOrder();
      int n = ArraySize(g_counterLinks);
      ArrayResize(g_counterLinks, n + 1);
      g_counterLinks[n].parentTicket  = parentPositionTicket;
      g_counterLinks[n].counterTicket = counterTicket;

      PrintFormat("Counter order placed | Parent Pos #%I64u | %s Stop @ %s | Lot %.2f | SL %s | TP %s",
                  parentPositionTicket, (originalIsBuy ? "Sell" : "Buy"),
                  DoubleToString(price, _Digits), counterLots,
                  DoubleToString(sl, _Digits), DoubleToString(tp, _Digits));
   }
   else
   {
      Print("Counter order FAILED | Retcode: ", trade.ResultRetcode(), " (", trade.ResultRetcodeDescription(), ")");
   }
}

//+------------------------------------------------------------------+
//| Housekeeping for counter orders: if InpCancelCounterOnParentClose |
//| is true and the parent position no longer exists (closed by TP,  |
//| manual close, FTMO block, etc.) while the counter order is still |
//| pending (never triggered), delete the pending counter order so   |
//| it doesn't sit there orphaned. If the counter order already      |
//| triggered (became its own position) or was removed some other    |
//| way, we just stop tracking it - the resulting position is left   |
//| alone either way.                                                 |
//+------------------------------------------------------------------+
void ManageCounterOrders()
{
   for(int i = ArraySize(g_counterLinks) - 1; i >= 0; i--)
   {
      ulong parentTicket  = g_counterLinks[i].parentTicket;
      ulong counterTicket = g_counterLinks[i].counterTicket;

      bool parentExists    = PositionSelectByTicket(parentTicket);
      bool counterIsPending = OrderSelect(counterTicket);

      if(!parentExists)
      {
         if(InpCancelCounterOnParentClose && counterIsPending)
         {
            trade.OrderDelete(counterTicket);
            Print("Parent position closed - Counter pending order deleted | Ticket: ", counterTicket);
         }
         ArrayRemove(g_counterLinks, i, 1);
      }
      else if(!counterIsPending)
      {
         // Counter order triggered into a position (or was removed manually) - stop tracking
         ArrayRemove(g_counterLinks, i, 1);
      }
   }
}

//+------------------------------------------------------------------+
//| Reset the daily trade counter when the calendar day changes      |
//+------------------------------------------------------------------+
void UpdateTradesCounterDay()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime todayMidnight = StructToTime(dt);

   if(todayMidnight != g_tradesCounterDay)
   {
      g_tradesCounterDay = todayMidnight;
      g_tradesToday = 0;
   }
}

//+------------------------------------------------------------------+
//| FTMO PROTECTION (Two-Layer):                                     |
//| Layer 1 - Hard Floor (InpHardFloorPercent, e.g. 3.5%): internal  |
//|   safety trigger measured against Initial Balance from day-start |
//|   balance. This is what actually closes everything and blocks    |
//|   new trades for the rest of the day - BEFORE the real FTMO      |
//|   daily limit is reached, to absorb slippage/gap risk.           |
//| Layer 2 - Total Loss (InpTotalLossPercent, e.g. 8.0%): measured  |
//|   directly against Initial Balance, permanent trip for the whole |
//|   life of the account/challenge.                                 |
//| InpDailyLossPercent (4.0%) is the real FTMO ceiling, kept purely |
//| for reference/logging - the Hard Floor always trips first.       |
//| NOTE: FTMO's own day boundary is 00:00 CE(S)T on the broker's    |
//| side, which may NOT match your MT5 terminal/server time exactly. |
//| Verify the offset against your broker before going live.         |
//+------------------------------------------------------------------+
void CheckFTMOProtection()
{
   if(!InpUseFTMOProtection) return;

   // --- Day rollover: reset day-start balance snapshot + lift daily block ---
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime todayMidnight = StructToTime(dt);

   if(todayMidnight != g_dayStartDate)
   {
      g_dayStartDate    = todayMidnight;
      g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      g_dailyBlocked    = false; // new day -> daily block lifts (total block does NOT)
      double hardFloorPreview = g_dayStartBalance - g_initialBalance * (InpHardFloorPercent / 100.0);
      double dailyRefPreview  = g_dayStartBalance - g_initialBalance * (InpDailyLossPercent / 100.0);
      PrintFormat("New trading day | Day-start balance = %s | Hard Floor (%.1f%%) = %s | Daily Ref (%.1f%%) = %s",
                  DoubleToString(g_dayStartBalance, 2), InpHardFloorPercent, DoubleToString(hardFloorPreview, 2),
                  InpDailyLossPercent, DoubleToString(dailyRefPreview, 2));
   }

   if(g_totalBlocked) return; // total loss already tripped, nothing more to check

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   // --- Layer 2: Total Loss check (from Initial Balance, permanent trip) ---
   double totalFloor = g_initialBalance * (1.0 - InpTotalLossPercent / 100.0);
   if(equity <= totalFloor)
   {
      if(!g_totalBlocked)
      {
         Print("!!! TOTAL LOSS FLOOR HIT !!! Equity: ", DoubleToString(equity, 2),
               " <= Floor: ", DoubleToString(totalFloor, 2), " - closing everything, EA stops trading permanently.");
         CloseAllMyPositions();
      }
      g_totalBlocked = true;
      g_dailyBlocked = true;
      return;
   }

   if(g_dailyBlocked) return; // already tripped today - stay flat until next day

   // --- Layer 1: Hard Floor check (internal safety margin, tighter than official daily loss) ---
   double hardFloor = g_dayStartBalance - g_initialBalance * (InpHardFloorPercent / 100.0);
   if(equity <= hardFloor)
   {
      g_dailyBlocked = true;
      PrintFormat("!!! DAILY HARD FLOOR HIT !!! Equity %s <= Floor %s (day start balance %s, hard floor %.1f%%). Closing all positions.",
                  DoubleToString(equity, 2), DoubleToString(hardFloor, 2), DoubleToString(g_dayStartBalance, 2), InpHardFloorPercent);
      CloseAllMyPositions();
   }
}

//+------------------------------------------------------------------+
void ExecuteBreakout(const double entry, const double slLevel, const bool isBuy,
                     const double anchorHigh, const double anchorLow)
{
   if(InpUseFTMOProtection && (g_dailyBlocked || g_totalBlocked)) return;
   if(!InpAllowSimultaneous && HasOpenPosition()) return;
   if(HasReachedMaxTradesToday()) return;
   if(!IsSpreadHealthy()) return;

   double sl, tp, riskPoints, lots;
   bool   sent = false;

   if(isBuy)
   {
      sl = slLevel;
      riskPoints = (entry - sl) / _Point;
      if(riskPoints <= 0) return;

      lots = InpUseDynamicLots ? CalculateDynamicLots(riskPoints) : InpLots;
      if(lots <= 0) return;

      tp = entry + (riskPoints * _Point) * InpRR;

      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      sent = trade.Buy(lots, _Symbol, ask, NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits), "FTMO Breakout Buy");
   }
   else
   {
      sl = slLevel;
      riskPoints = (sl - entry) / _Point;
      if(riskPoints <= 0) return;

      lots = InpUseDynamicLots ? CalculateDynamicLots(riskPoints) : InpLots;
      if(lots <= 0) return;

      tp = entry - (riskPoints * _Point) * InpRR;

      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      sent = trade.Sell(lots, _Symbol, bid, NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits), "FTMO Breakout Sell");
   }

   // Order Execution Check
   uint retcode = trade.ResultRetcode();
   if(sent && retcode == TRADE_RETCODE_DONE)
   {
      g_tradesToday++;
      Print("Trade Executed Successfully | Lot: ", DoubleToString(lots, 2),
            " | Trades Today: ", g_tradesToday, "/", InpMaxTradesPerDay);

      // --- Place the opposite pending Stop order at this trade's SL level ---
      if(InpUseCounterOrder)
      {
         ulong positionTicket = FindUnlinkedPositionTicket();
         if(positionTicket > 0)
            PlaceCounterOrder(positionTicket, sl, isBuy, lots);
         else
            Print("Counter order SKIPPED - could not find the new position ticket to link it to.");
      }
   }
   else
   {
      Print("Trade Execution Failed | Retcode: ", retcode,
            " (", trade.ResultRetcodeDescription(), ")");
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   CheckFTMOProtection();
   UpdateTradesCounterDay();
   ManageCounterOrders();

   if(InpUseFTMOProtection && (g_dailyBlocked || g_totalBlocked)) return;

   datetime curTime = iTime(_Symbol, _Period, 0);
   if(curTime == g_last_bar_time) return;
   g_last_bar_time = curTime;

   int bars = iBars(_Symbol, _Period);
   if(bars < 3) return;

   int cur = 1;

   datetime barOpenTime = iTime(_Symbol, _Period, cur);
   MqlDateTime dt;
   TimeToStruct(barOpenTime, dt);

   bool isAnchor1 = (dt.hour == InpAnchor1Hour && dt.min == InpAnchor1Min);
   bool isAnchor2 = (dt.hour == InpAnchor2Hour && dt.min == InpAnchor2Min);

   double curHigh  = iHigh (_Symbol, _Period, cur);
   double curLow   = iLow  (_Symbol, _Period, cur);
   double curClose = iClose (_Symbol, _Period, cur);

   if(isAnchor1)
   {
      g_anchorAHigh   = curHigh;
      g_anchorALow    = curLow;
      g_anchorAActive = true;
      g_anchorBActive = false;
      return;
   }

   if(isAnchor2)
   {
      g_anchorBHigh   = curHigh;
      g_anchorBLow    = curLow;
      g_anchorBActive = true;
      g_anchorAActive = false;
      return;
   }

   if(g_anchorAActive)
   {
      if(curClose > g_anchorAHigh)
      {
         ExecuteBreakout(curClose, g_anchorALow, true, g_anchorAHigh, g_anchorALow);
         g_anchorAActive = false;
      }
      else if(curClose < g_anchorALow)
      {
         ExecuteBreakout(curClose, g_anchorAHigh, false, g_anchorAHigh, g_anchorALow);
         g_anchorAActive = false;
      }
   }

   if(g_anchorBActive)
   {
      if(curClose > g_anchorBHigh)
      {
         ExecuteBreakout(curClose, g_anchorBLow, true, g_anchorBHigh, g_anchorBLow);
         g_anchorBActive = false;
      }
      else if(curClose < g_anchorBLow)
      {
         ExecuteBreakout(curClose, g_anchorBHigh, false, g_anchorBHigh, g_anchorBLow);
         g_anchorBActive = false;
      }
   }
}
//+------------------------------------------------------------------+
