//+------------------------------------------------------------------+
//| MT5_Export_Quote_Ticks.mq5                                        |
//| Read-only historical quote tick exporter for XAUUSD.s            |
//| NO trading, no changes to an attached EA or Worker.              |
//| Tick QUOTE updates are NOT COMEX executed trade volumes.         |
//+------------------------------------------------------------------+
#property strict
#property script_show_inputs

input int    InpLookbackCalendarDays = 3;
input int    InpChunkMinutes         = 10;
input int    InpMaxExportRows        = 1500000;
input string InpOutputCSV            = "XAU_QuoteTicks_MT5.csv";

void OnStart()
{
   if(InpLookbackCalendarDays < 1 || InpLookbackCalendarDays > 60 ||
      InpChunkMinutes < 1 || InpChunkMinutes > 120 ||
      InpMaxExportRows < 100 || InpOutputCSV == "")
   {
      Print("MT5_QUOTE_EXPORT ERROR: invalid export inputs");
      return;
   }

   // Use the server timestamp as the end of a read-only historical request.
   datetime serverNow = TimeTradeServer();
   if(serverNow <= 0)
   {
      Print("MT5_QUOTE_EXPORT ERROR: no server time");
      return;
   }

   ulong toMs   = (ulong)serverNow * 1000;
   ulong spanMs = (ulong)InpLookbackCalendarDays * (ulong)86400000;
   if(toMs <= spanMs)
   {
      Print("MT5_QUOTE_EXPORT ERROR: invalid time span");
      return;
   }
   ulong fromMs = toMs - spanMs;
   ulong chunkMs = (ulong)InpChunkMinutes * (ulong)60000;

   string fileName = InpOutputCSV;
   int f = FileOpen(fileName, FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
   if(f == INVALID_HANDLE)
   {
      Print("MT5_QUOTE_EXPORT ERROR opening file; MQL5 code=", GetLastError());
      return;
   }
   FileWrite(f, "time_msc", "bid", "ask", "flags", "symbol");

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   int written = 0;
   int badQuotes = 0;
   int failedChunks = 0;
   ulong lastWrittenMs = 0;
   ulong cursor = fromMs;
   MqlTick batch[];

   while(cursor <= toMs)
   {
      ulong until = cursor + chunkMs - 1;
      if(until > toMs || until < cursor)
         until = toMs;

      ResetLastError();
      int n = CopyTicksRange(_Symbol, batch, COPY_TICKS_INFO, cursor, until);
      if(n < 0)
      {
         Print("MT5_QUOTE_EXPORT ERROR: CopyTicksRange on ", _Symbol,
               " from_ms=", cursor, " to_ms=", until,
               " MQL5 code=", GetLastError());
         failedChunks++;
         break;
      }

      for(int i=0; i<n; i++)
      {
         if(batch[i].bid <= 0 || batch[i].ask < batch[i].bid || batch[i].time_msc <= 0)
         {
            badQuotes++;
            continue;
         }
         // Export all valid quote updates including timestamps shared by multiple ticks.
         FileWrite(f,
                   IntegerToString(batch[i].time_msc),
                   DoubleToString(batch[i].bid, digits),
                   DoubleToString(batch[i].ask, digits),
                   IntegerToString((long)batch[i].flags),
                   _Symbol);
         written++;
         lastWrittenMs = (ulong)batch[i].time_msc;
         if(written >= InpMaxExportRows)
         {
            Print("MT5_QUOTE_EXPORT ERROR: safety row cap reached (", written,
                  "). Increase InpMaxExportRows or reduce calendar days.");
            failedChunks++;
            break;
         }
      }
      if(failedChunks > 0)
         break;
      if(until == toMs)
         break;
      cursor = until + 1; // CopyTicksRange upper bound is inclusive.
   }

   FileClose(f);
   if(failedChunks > 0 || written == 0)
   {
      // Never allow an incomplete export to masquerade as complete research input.
      bool removed = FileDelete(fileName, FILE_COMMON);
      Print("MT5_QUOTE_EXPORT FAILED: rows=", written,
            ", partial file removed=", removed,
            ", badQuotes=", badQuotes);
      return;
   }

   Print("MT5_QUOTE_EXPORT SUCCESS: symbol=", _Symbol,
         " rows=", written, " skipped=", badQuotes,
         " lastTickMs=", lastWrittenMs);
   Print("CSV path: ", TerminalInfoString(TERMINAL_COMMONDATA_PATH),
         "\\Files\\", fileName);
   Print("WARNING: quote-update counts, NOT executed COMEX volume/Delta.");
}
