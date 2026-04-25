//+------------------------------------------------------------------+
//| HA_TDI_PolicyLadder v1p3.mq5                                     |
//| - NO SL anywhere                                                 |
//| - Entries: Heiken Ashi M5+M30+H1 + policy ladder gate            |
//| - Dynamic Basket TP (close ALL when profit >= dynamic target)    |
//| - Hedge after 5 days loss (HA MTF only, no TDI)                  |
//| - policy_pf.csv read from FILE_COMMON with ','                   |
//| - Two top-right colored buttons:                                 |
//|     1) TRADE: ON/OFF (blue when ON, gray when OFF)               |
//|     2) CLOSE ALL (red)                                           |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>

// --- Compatibility: some MT5 builds do not have PositionSelectByIndex()
bool PositionSelectByIndex(const int index)
  {
   ulong ticket = PositionGetTicket(index);
   if(ticket==0)
      return false;
   return PositionSelectByTicket(ticket);
  }

CTrade trade;

//--------------------------- INPUTS ---------------------------------
input string         InpPolicyFile           = "policy_pf.csv";  // Common\Files\
input int            InpMaxHedges            = 3;
input int            InpHedgeAddCooldownMin  = 3;
input int            InpMagic                = 251120251;
input int            InpMagic_2              = 26012026;

input ENUM_TIMEFRAMES InpTF_M5                = PERIOD_M5;
input ENUM_TIMEFRAMES InpTF_M30               = PERIOD_M15;
input ENUM_TIMEFRAMES InpTF_H1                = PERIOD_M30;
input ENUM_TIMEFRAMES InpTF_H4                = PERIOD_H1;

//Hedge Direction check
input ENUM_TIMEFRAMES InpHedgeTF_M5           = PERIOD_M5;
input ENUM_TIMEFRAMES InpHedgeTF_M30          = PERIOD_M15;

input double          InpLots_Normal           = 5;
input int             InpMaxTradesPerBar       = 3;
input int             InpMaxPositionsPerSymbol = 250;
input bool            InpOneTradePerBar        = true;

input int             InpATRPeriod             = 14;
input int             InpATR_MA_Period         = 48;

input int             InpMaxSpreadPipsFilter   = 30;
input double          InpBucketLowMax          = 1.0;
input double          InpBucketMidMax          = 2.0;
input double          InpBucketHighMax         = 3.0;

// Ladder quality gates
input int             InpMinTrades             = 250;
input double          InpMinBestPF             = 1.2;

// Normal entries behavior
input bool            InpAllowNormalEntries    = true;
input bool            InpUsePerTradeTP_Normal  = false;   // keep FALSE; basket closes dynamically

// Hedge routine settings
input bool            InpEnableHedge5D         = true;
input double          InpHedgeAfterDays        = 0.5;
input double          InpHedgeExtraProfitUSD   = 3000.0;
input double          InpHedgeMaxLot           = 50.0;
input bool            InpHedgeUseTP            = false;
input double          InpHedgeStartLoss        = 10000;

// Hedge harvest controls
input double          InpHedgeHarvestMinProfit = 5000.0;   // harvest only if hedge profit >= this
input int             InpHedgeHarvestMaxCycles = 0;       // max harvests per basket (0 = unlimited)
input int             InpHedgeHarvestCooldownMin = 0;     // minutes between harvests (0 = no cooldown)
input bool            InpAllowPartialClose    = true;  // broker allows partial close (e.g., RoboForex)

// Dynamic Basket TP (NO SL)
input bool            InpUseDynamicBasketTP    = true;
input double          InpTP_BasePips           = 8.0;    // baseline pips target (before ladder scaling)
input double          InpTP_MinUSD             = 300.0;   // floor
input double          InpTP_MaxUSD             = 5000.0; // cap
input double          InpFallbackTP_USD        = 3000.0;  // used when ok=false or dynamicTP disabled
input double          InpBasketCloseSlackUSD = 5.0;     // close basket when profit >= (target - slack)
input double          InpTP_ScaleByBestPF      = 0.0;    // 0=off. Example 0.25 small boost for high PF rows
input double          InpDynTargetUSD          = 3000.0; // your base target
input double          InpDynDipUSD             = 100.0;   // dip size in USD to count as a dip (tune this)
input int             InpDynDipConfirmTicks    = 3;   // number of consecutive meaningful dips before closing

input bool            InpPrintDebug            = true;

// State classifier knobs (no TDI)
input double          InpSqueezeATR_Ratio      = 0.70;
input double          InpBreakoutRangeATR      = 1.40;

//--------------------------- GLOBALS ---------------------------------
datetime g_lastBar=0;
datetime g_lastTradeBar=0;
bool     g_hedgeOpened=false;
datetime g_lastHedgeAttempt = 0;
bool     g_hedgeOpenedThisTick = false;
int      prevBar=0;
long     g_magicHedge = 0;
double   g_dynPeak = 0.0;
double   g_dynPrev = 0.0;
bool     g_dynActive = false;
double   g_dynPrevProfit = 0.0;
int      g_dynDownCount = 0;

// Buttons (top-right)
string   BTN_TOGGLE="BTN_TRADE_TOGGLE";
string   BTN_CLOSE ="BTN_CLOSE_ALL";
bool     g_tradeEnabled=true;

// Hedge harvest cycle tracking
int      g_harvestCycles=0;
datetime g_lastHarvestTime=0;

// ===== INPUTS =====
input int  InpPanelFontSize = 12;
input int  InpPanelX        = 10;
input int  InpPanelY        = 20;

// ===== INTERNAL =====
bool g_blink = false;
datetime g_lastBlink = 0;

//--------------------------- HELPERS --------------------------------
string Trim(string s)
  {
   int n=StringLen(s);
   while(n>0)
     {
      ushort ch=StringGetCharacter(s,n-1);
      if(ch==' ' || ch=='\r' || ch=='\n' || ch=='\t')
        {
         s=StringSubstr(s,0,n-1);
         n=StringLen(s);
        }
      else
         break;
     }
   while(StringLen(s)>0)
     {
      ushort ch=StringGetCharacter(s,0);
      if(ch==' ' || ch=='\r' || ch=='\n' || ch=='\t')
         s=StringSubstr(s,1);
      else
         break;
     }
   return s;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void CheckDynamicClose()
  {
   int posAll = CountPositionsAll();
   if(posAll <= 0)
     {
      // reset when basket empty
      g_dynActive = false;
      g_dynPrevProfit = 0.0;
      return;
     }

   double profit = BasketProfitUSD();

// Not active yet: wait until profit reaches target
   if(!g_dynActive)
     {
      if(profit >= InpDynTargetUSD)
        {
         g_dynActive = true;
         g_dynPrevProfit = profit;  // start tracking from activation point
         g_dynDownCount = 0;         // <<< REQUIRED reset

         if(InpPrintDebug)
            PrintFormat("DYN: activated profit=%.2f target=%.2f", profit, InpDynTargetUSD);
        }
      return;
     }

// --- DYN ACTIVE MODE ---
   double dip = g_dynPrevProfit - profit;  // compare to PREVIOUS TICK

   if(dip <= 0.0)
     {
      g_dynDownCount = 0;
      g_dynPrevProfit = profit;
      return;
     }

   if(dip >= InpDynDipUSD)
     {
      g_dynDownCount++;

      if(InpPrintDebug)
         PrintFormat("DYN: dip %d/%d prev=%.2f now=%.2f dip=%.2f",
                     g_dynDownCount, InpDynDipConfirmTicks,
                     g_dynPrevProfit, profit, dip);

      if(g_dynDownCount >= InpDynDipConfirmTicks)
        {
         if(InpPrintDebug)
            Print("DYN: confirmed dip -> closing basket");
         CloseAllOurPositions();
         g_dynActive=false;
         g_dynPrevProfit=0.0;
         g_dynDownCount=0;
         return;
        }
     }
   else
     {
      g_dynDownCount = 0;
     }

   g_dynPrevProfit = profit;

// Active: hold while profit is rising or flat
//   if(profit >= g_dynPrevProfit)
//     {
//      g_dynPrevProfit = profit;
//      g_dynDownCount = 0;
//      return;
//     }

// Profit is down vs previous tick
//   double dip = g_dynPrevProfit - profit;

// Only count it if the dip is meaningful
//   if(dip >= InpDynDipUSD)
//     {
//      g_dynDownCount++;

//      if(InpPrintDebug)
//         PrintFormat("DYN: dip %d/%d prev=%.2f now=%.2f dip=%.2f",
//                     g_dynDownCount, InpDynDipConfirmTicks,
//                     g_dynPrevProfit, profit, dip);
//
// Close only after N consecutive dips
//      if(g_dynDownCount >= InpDynDipConfirmTicks)
//        {
//         if(InpPrintDebug)
//            Print("DYN: confirmed dip -> closing basket");

//         CloseAllOurPositions();

// reset
//         g_dynActive = false;
//         g_dynPrevProfit = 0.0;
//         g_dynDownCount = 0;
//         return;
//        }
//     }
// Small dip: ignore (do NOT change prev, do NOT increment counter)

  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int countPosPerBar()
  {
   int tradeCount = 0;
   long currentBarTime = iTime(_Symbol, _Period, 0); // Get the open time of the current bar
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      string positionSymbol = PositionGetString(POSITION_SYMBOL);
      long positionTime = PositionGetInteger(POSITION_TIME); // Or POSITION_TIME_M15 for M15 bars, etc.

      if(positionSymbol == _Symbol)  // Check if it's the same symbol
        {
         // Check if the position was opened on the current bar
         // For M1 bars, this is simple: if (positionTime == currentBarTime)
         // For higher timeframes, you compare position time with bar open time
         if(positionTime >= currentBarTime)  // Position opened on or after current bar started
           {
            tradeCount++;
           }
         // Note: For more precise checks on higher timeframes (e.g., M5, H1),
         // you might need to compare the bar index (iBar - 1) to see if the trade
         // falls within the specific bar's range, not just if it opened on the bar's *start time*.
        }
     }

// tradeCount now holds the number of trades for the current bar
   return tradeCount;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void CreateLabel(string name,int y,color clr)
  {
   if(ObjectFind(0,name) < 0)
     {
      ObjectCreate(0,name,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_XDISTANCE,InpPanelX);
      ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
      ObjectSetInteger(0,name,OBJPROP_FONTSIZE,InpPanelFontSize);
      ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_BACK,false);
      ObjectSetString(0,name,OBJPROP_FONT,"Arial");
     }
  }

//--------------------------- MAGIC HELPERS ---------------------------
bool IsMainMagic(const long mg)
  {
   return (mg==(long)InpMagic || mg==(long)InpMagic_2);
  }

bool IsOurMagic(const long mg)
  {
   return (IsMainMagic(mg) || mg==(long)g_magicHedge);
  }

// ===== DISPLAY =====
bool IsHedgePosByComment(const string cmt)
  {
   return (StringFind(cmt,"HEDGE5D#"+IntegerToString(NextHedgeIndex()))>=0);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int CountHedgePositions()
  {
   int n = 0;
   for(int i=0; i<PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != (long)g_magicHedge)
         continue;
      n++;
     }
   return n;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int LastHedgeDir()
  {
   datetime newest = 0;
   int dir = 0;

   for(int i=0; i<PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != (long)g_magicHedge)
         continue;

      datetime t = (datetime)PositionGetInteger(POSITION_TIME);
      if(t >= newest)
        {
         newest = t;
         long type = PositionGetInteger(POSITION_TYPE);
         dir = (type == POSITION_TYPE_BUY) ? +1 : -1;
        }
     }
   return dir;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
datetime LastHedgeOpenTime()
  {
   datetime newest = 0;

   for(int i=0; i<PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != (long)g_magicHedge)
         continue;

      datetime t = (datetime)PositionGetInteger(POSITION_TIME);
      if(t > newest)
         newest = t;
     }
   return newest;   // 0 if none
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int NextHedgeIndex()
  {
   int mx=0;
   for(int i=0;i<PositionsTotal();i++)
     {
      if(!PositionSelectByIndex(i))
         continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol)
         continue;
      long mg = (long)PositionGetInteger(POSITION_MAGIC);
      if(!IsMainMagic(mg))
         continue;

      string cmt = PositionGetString(POSITION_COMMENT);
      int p = StringFind(cmt,"HEDGE5D#");
      if(p<0)
         continue;
      int h = StringFind(cmt,"#",p);
      if(h<0)
         continue;
      int idx = (int)StringToInteger(StringSubstr(cmt,h+1));
      if(idx>mx)
         mx=idx;
     }
   return mx+1;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void Display()
  {
   double pl     = AccountFloatingPL();
   double target = InpFallbackTP_USD;
   int    hedge  = CountHedgePositions();
   int    hPos   = 0;

// Auto spacing
   int lineH = InpPanelFontSize + 6;
   int y1 = InpPanelY;
   int y2 = y1 + lineH;
   int y3 = y2 + lineH;
   int y4 = y3 + lineH;

// Create labels
   CreateLabel("EA_LINE_PL", y1, clrLime);
   ObjectSetInteger(
      0,
      "EA_LINE_PL",
      OBJPROP_COLOR,
      pl >= 0 ? clrLime : clrRed
   );
   ObjectSetString(
      0,
      "EA_LINE_PL",
      OBJPROP_TEXT,
      StringFormat("P/L     : %10.2f", pl)
   );

   CreateLabel("EA_LINE_TP",    y2, clrDodgerBlue);

   if(hedge>0)
      hPos = -1;
   else
      hPos = +1;
   CreateLabel("EA_LINE_HEDGE", y3, clrSilver);
   ObjectSetInteger(
      0,
      "EA_LINE_HEDGE",
      OBJPROP_COLOR,
      hPos >= 0 ? clrSilver : clrRed
   );
   ObjectSetString(
      0,
      "EA_LINE_HEDGE",
      OBJPROP_TEXT,
      StringFormat("Hedge   : %10.2f", hedge)
   );

   CreateLabel("CUR_BAL", y4, clrYellowGreen);

// Right-aligned formatting
   string sPL = StringFormat("P/L     : %10.2f", pl);
   string sTP = StringFormat("TARGET  : %10.2f", target);
   string sHG = StringFormat("HEDGE   : %s", hedge ? "ON" : "OFF");
   string sBL = StringFormat("BALANCE   : %s", (string)AccountInfoDouble(ACCOUNT_BALANCE));

   ObjectSetString(0,"EA_LINE_PL",OBJPROP_TEXT,sPL);
   ObjectSetString(0,"EA_LINE_TP",OBJPROP_TEXT,sTP);
   ObjectSetString(0,"EA_LINE_HEDGE",OBJPROP_TEXT,sHG);
   ObjectSetString(0,"CUR_BAL",OBJPROP_TEXT,sBL);
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double PipSize()
  {
   if(_Digits==3 || _Digits==5)
      return _Point*10.0;
   return _Point;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double SpreadPips()
  {
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   return (ask-bid)/PipSize();
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
string SpreadBucket(double spread_pips)
  {
   if(spread_pips<=InpBucketLowMax)
      return "low";
   if(spread_pips<=InpBucketMidMax)
      return "mid";
   if(spread_pips<=InpBucketHighMax)
      return "high";
   return "xhigh";
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int HourUTCNow()
  {
   datetime t=TimeGMT();
   MqlDateTime dt;
   TimeToStruct(t,dt);
   return dt.hour;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int WeekdayUTCNow()
  {
   datetime t=TimeGMT();
   MqlDateTime dt;
   TimeToStruct(t,dt);
   return dt.day_of_week;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsNewBar(ENUM_TIMEFRAMES tf, datetime &lastBarTime)
  {
   datetime t = iTime(_Symbol, tf, 0);
   if(t <= 0)
      return false;

// first run: initialize, don't trigger
   if(lastBarTime == 0)
     {
      lastBarTime = t;
      return false;
     }

   if(t != lastBarTime)
     {
      lastBarTime = t;
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double NormalizeVolumeToStep(double vol)
  {
   double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step  =SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);

   if(vol<minLot)
      return 0.0;
   if(vol>maxLot)
      vol=maxLot;

   double steps=MathFloor(vol/step);
   double out=steps*step;
   if(out<minLot)
      return 0.0;
   return out;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double NormalizeLot(double lots)
  {
   double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step  =SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);

   if(lots<minLot)
      lots=minLot;
   if(lots>maxLot)
      lots=maxLot;
   if(lots>InpHedgeMaxLot)
      lots=InpHedgeMaxLot;

   double steps=MathFloor(lots/step);
   double out=steps*step;
   if(out<minLot)
      out=minLot;
   return out;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double PipValuePerLot()
  {
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double pip_size   = PipSize();
   if(tick_value<=0 || tick_size<=0)
      return 0.0;
   return tick_value * (pip_size / tick_size);
  }

//--------------------------- HEIKEN ASHI ----------------------------
bool GetHeikenAshi(ENUM_TIMEFRAMES tf, int shift, double &haOpen, double &haClose, double &haHigh, double &haLow)
  {
   MqlRates r[];
   int need=shift+10;
   if(CopyRates(_Symbol,tf,0,need,r)<need)
      return false;

   int total=need;
   double prev_haOpen=0, prev_haClose=0;
   bool first=true;

   for(int idx=total-1; idx>=0; idx--)
     {
      double o=r[idx].open, h=r[idx].high, l=r[idx].low, c=r[idx].close;
      double cur_haClose=(o+h+l+c)/4.0;
      double cur_haOpen=(first)?((o+c)/2.0):((prev_haOpen+prev_haClose)/2.0);
      double cur_haHigh=MathMax(h, MathMax(cur_haOpen,cur_haClose));
      double cur_haLow =MathMin(l, MathMin(cur_haOpen,cur_haClose));
      first=false;

      prev_haOpen=cur_haOpen;
      prev_haClose=cur_haClose;

      if(idx==shift)
        {
         haOpen=cur_haOpen;
         haClose=cur_haClose;
         haHigh=cur_haHigh;
         haLow=cur_haLow;
         return true;
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int HeikenTrendDir(ENUM_TIMEFRAMES tf)
  {
   double o1,c1,h1,l1, o2,c2,h2,l2;
   if(!GetHeikenAshi(tf,1,o1,c1,h1,l1))
      return 0;
   if(!GetHeikenAshi(tf,2,o2,c2,h2,l2))
      return 0;

   if(c1>o1 && c2>o2)
      return +1;
   if(c1<o1 && c2<o2)
      return -1;
   return 0;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int HA_MTF_Dir()
  {
   int d5  = HeikenTrendDir(InpTF_M5);
   int d30 = HeikenTrendDir(InpTF_M30);
   int d1  = HeikenTrendDir(InpTF_H1);
   int d4  = HeikenTrendDir(InpTF_H4);

   if(d5>0 && d30>0 && d1>0 && d4>0)
      return +1;
   if(d5<0 && d30<0 && d1<0 && d4<0)
      return -1;
   else
      return 0;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
// Hedge-only HA direction: 3 of 4 timeframes must agree
int Hedge_HA_MTF_Dir()
  {
   int d5  = HeikenTrendDir(InpHedgeTF_M5);
   int d30 = HeikenTrendDir(InpHedgeTF_M30);

   if(!((d5>0 && d30>0) || (d5<0 && d30<0)))
      return 0;

// RSI confirmation (use last closed bar shift=1)
   double rsi = iRSI(_Symbol, InpHedgeTF_M30, 14, PRICE_CLOSE);

   if(d5>0 && d30>0)
     {
      if(rsi < 25.0)
         return +1;   // or 55.0 for stricter
      return 0;
     }
   else
     {
      if(rsi > 75.0)
         return -1;   // or 45.0 for stricter
      return 0;
     }
  }

//--------------------------- ATR ------------------------------------
double ATR_Price(ENUM_TIMEFRAMES tf, int shift)
  {
   int h=iATR(_Symbol,tf,InpATRPeriod);
   if(h==INVALID_HANDLE)
      return 0;
   double buf[];
   ArraySetAsSeries(buf,true);
   if(CopyBuffer(h,0,shift,3,buf)<1)
     {
      IndicatorRelease(h);
      return 0;
     }
   IndicatorRelease(h);
   return buf[0];
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double ATR_MA_Price(ENUM_TIMEFRAMES tf, int shift)
  {
   int need = shift + InpATR_MA_Period + 5;
   int h=iATR(_Symbol,tf,InpATRPeriod);
   if(h==INVALID_HANDLE)
      return 0;

   double buf[];
   ArrayResize(buf,need);
   ArraySetAsSeries(buf,true);

   if(CopyBuffer(h,0,0,need,buf)<need)
     {
      IndicatorRelease(h);
      return 0;
     }
   IndicatorRelease(h);

   double sum=0;
   int cnt=0;
   for(int i=shift;i<shift+InpATR_MA_Period;i++)
     {
      if(i>=need)
         break;
      sum+=buf[i];
      cnt++;
     }
   if(cnt<=0)
      return 0;
   return sum/cnt;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
string ClassifyStateTF_NoTDI(ENUM_TIMEFRAMES tf)
  {
   double atr_now = ATR_Price(tf,1);
   double atr_ma  = ATR_MA_Price(tf,1);
   if(atr_now<=0 || atr_ma<=0)
      return "NEUTRAL";

   MqlRates r[];
   if(CopyRates(_Symbol,tf,1,1,r)<1)
      return "NEUTRAL";
   double range = r[0].high - r[0].low;

   if(atr_now < atr_ma * InpSqueezeATR_Ratio)
      return "SQUEEZE";
   if(range > atr_now * InpBreakoutRangeATR)
      return "BREAKOUT";
   return "NEUTRAL";
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
string CombinedMarketState_NoTDI()
  {
   string s5  = ClassifyStateTF_NoTDI(InpTF_M5);
   string s30 = ClassifyStateTF_NoTDI(InpTF_M30);
   string s1  = ClassifyStateTF_NoTDI(InpTF_H1);

   if(s1=="SQUEEZE" && s30=="SQUEEZE")
      return "SQUEEZE";
   if(s5=="BREAKOUT")
      return "BREAKOUT";
   if(s1=="BREAKOUT" && s30=="BREAKOUT")
      return "BREAKOUT";
   return "NEUTRAL";
  }

//--------------------------- LADDER ---------------------------------
struct LadderRow
  {
   string            state;
   int               hour_utc;
   int               weekday;
   string            spread_bucket;
   double            best_pf;
   double            tp_mult;
   double            step_pips;
   int               n_trades;
   string            error;
  };

LadderRow ladder[];
int ladder_count=0;

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int FindCol(string &cols[], string name)
  {
   for(int i=0;i<ArraySize(cols);i++)
      if(StringCompare(Trim(cols[i]),name,false)==0)
         return i;
   return -1;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool LoadLadder_CommonCSV(const string fileName)
  {
   ladder_count=0;
   ArrayResize(ladder,0);

// REQUIRED: FILE_COMMON and ',' delimiter
   int fh = FileOpen(fileName, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON, ',');
   if(fh==INVALID_HANDLE)
     {
      Print("Ladder file open failed (COMMON): ",fileName," err=",GetLastError());
      return false;
     }

   string header=Trim(FileReadString(fh));
   if(header=="")
     {
      FileClose(fh);
      Print("Ladder header empty");
      return false;
     }

   string cols[];
   StringSplit(header,',',cols);

   int c_state = FindCol(cols,"state");
   int c_hour  = FindCol(cols,"hour_utc");
   int c_wday  = FindCol(cols,"weekday");
   int c_sb    = FindCol(cols,"spread_bucket");
   int c_bestpf= FindCol(cols,"best_pf");
   int c_tpm   = FindCol(cols,"tp_mult");
   int c_step  = FindCol(cols,"step_pips");
   int c_ntr   = FindCol(cols,"n_trades");
   int c_err   = FindCol(cols,"error");

   if(c_state<0||c_hour<0||c_wday<0||c_sb<0||c_bestpf<0||c_tpm<0||c_ntr<0)
     {
      FileClose(fh);
      Print("Missing required ladder columns. Header=",header);
      return false;
     }

   while(!FileIsEnding(fh))
     {
      string line=Trim(FileReadString(fh));
      if(line=="" || StringGetCharacter(line,0)=='#')
         continue;

      string v[];
      int cc=StringSplit(line,',',v);
      if(cc<6)
         continue;

      LadderRow r;
      r.state         = (c_state<cc)?Trim(v[c_state]):"";
      r.hour_utc      = (c_hour<cc)?(int)StringToInteger(Trim(v[c_hour])):-1;
      r.weekday       = (c_wday<cc)?(int)StringToInteger(Trim(v[c_wday])):-1;
      r.spread_bucket = (c_sb<cc)?Trim(v[c_sb]):"";

      r.best_pf       = (c_bestpf<cc)?StringToDouble(Trim(v[c_bestpf])):0;
      r.tp_mult       = (c_tpm<cc)?StringToDouble(Trim(v[c_tpm])):0;
      r.step_pips     = (c_step<cc)?StringToDouble(Trim(v[c_step])):0;
      r.n_trades      = (c_ntr<cc)?(int)StringToInteger(Trim(v[c_ntr])):0;
      r.error         = (c_err<cc)?Trim(v[c_err]):"";

      int n=ArraySize(ladder);
      ArrayResize(ladder,n+1);
      ladder[n]=r;
      ladder_count=n+1;
     }

   FileClose(fh);
   Print("Loaded ladder rows: ",ladder_count);
   return ladder_count>0;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool RowOK(const LadderRow &r)
  {
   if(r.error!="" && r.error!="0")
      return false;
   if(r.n_trades < InpMinTrades)
      return false;
   if(r.best_pf  < InpMinBestPF)
      return false;
   if(r.tp_mult  <= 0)
      return false;
   return true;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool PickBestRow(const string state, int hour_utc, int weekday, const string sb, LadderRow &out)
  {
   bool found=false;
   double best=-1;

   for(int i=0;i<ladder_count;i++)
     {
      LadderRow r = ladder[i];
      if(StringCompare(r.state,state,false)!=0)
         continue;
      if(r.hour_utc!=hour_utc)
         continue;
      if(r.weekday!=weekday)
         continue;
      if(StringCompare(r.spread_bucket,sb,false)!=0)
         continue;
      if(!RowOK(r))
         continue;

      if(r.best_pf>best)
        {
         best=r.best_pf;
         out=r;
         found=true;
        }
     }
   return found;
  }

//--------------------------- POSITIONS -------------------------------
bool IsOurPos(ulong ticket)
  {
   if(!PositionSelectByTicket(ticket))
      return false;

   if(PositionGetString(POSITION_SYMBOL)!=_Symbol)
      return false;

   long mg = (long)PositionGetInteger(POSITION_MAGIC);
   if(!IsOurMagic(mg))
      return false;

   return true;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int CountPositionsAll()
  {
   int cnt=0,total=PositionsTotal();
   for(int i=0;i<total;i++)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0)
         continue;
      if(IsOurPos(ticket))
         cnt++;
     }
   return cnt;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
datetime OldestOpenTime_All()
  {
   datetime oldest = 0;
   for(int i=0;i<PositionsTotal();i++)
     {
      if(!PositionSelectByIndex(i))
         continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol)
         continue;
      long mg = (long)PositionGetInteger(POSITION_MAGIC);
      if(!IsMainMagic(mg))
         continue;

      datetime t = (datetime)PositionGetInteger(POSITION_TIME);
      if(oldest==0 || t < oldest)
         oldest = t;
     }
   return oldest;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool HasHedgePos()
  {
   int total=PositionsTotal();
   for(int i=0;i<total;i++)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0)
         continue;
      if(!IsOurPos(ticket))
         continue;

      string cmt=PositionGetString(POSITION_COMMENT);
      if(StringFind(cmt,"HEDGE5D#"+IntegerToString(NextHedgeIndex()))>=0)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Account-wide floating P/L (positions only, includes manual trades)|
//| Net = profit + swap + commission                                 |
//+------------------------------------------------------------------+
double AccountFloatingPL()
  {
   double p=0.0;
   int total=PositionsTotal();
   for(int i=0;i<total;i++)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      p += PositionGetDouble(POSITION_PROFIT);
      p += PositionGetDouble(POSITION_SWAP);
      p += 0.0;
     }
   return p;
  }

double BasketProfitUSD_AllSymbols()
  {
   double p=0.0;
   int total=PositionsTotal();
   for(int i=0;i<total;i++)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      long mg = (long)PositionGetInteger(POSITION_MAGIC);
      if(!IsOurMagic(mg)) continue;

      // Net floating P/L (profit + swap + commission)
      p += PositionGetDouble(POSITION_PROFIT)
         + PositionGetDouble(POSITION_SWAP);
     }
   return p;
  }

double BasketProfitUSD()
  {
   double p=0.0;
   int total=PositionsTotal();
   for(int i=0;i<total;i++)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0)
         continue;
      if(!IsOurPos(ticket))
         continue;
      p += PositionGetDouble(POSITION_PROFIT)
         + PositionGetDouble(POSITION_SWAP);
     }
   return p;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double BasketNetLots()
  {
   double lots=0.0;
   int total=PositionsTotal();
   for(int i=0;i<total;i++)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0)
         continue;
      if(!IsOurPos(ticket))
         continue;
      lots += PositionGetDouble(POSITION_VOLUME);
     }
   return lots;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void CloseAllOurPositions()
{
   const int MAX_PASSES = 5;   // how many full retries
   const int SLEEP_MS   = 250; // pause between passes

   MqlTick tick;

   for(int pass=1; pass<=MAX_PASSES; pass++)
   {
      bool anyLeft = false;

      for(int i=PositionsTotal()-1; i>=0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket==0) continue;

         if(!PositionSelectByTicket(ticket)) continue;
         if(!IsOurPos(ticket)) continue;

         anyLeft = true;

         if(!trade.PositionClose(ticket))
         {
            if(InpPrintDebug)
               PrintFormat("CLOSE FAILED pass=%d ticket=%I64u ret=%d err=%d",
                           pass, ticket, (int)trade.ResultRetcode(), (int)GetLastError());
         }
         else
         {
            if(InpPrintDebug)
               PrintFormat("CLOSE OK pass=%d ticket=%I64u", pass, ticket);
         }
      }

      if(!anyLeft) break;

      // refresh tick (optional but helps on busy/requotes)
      SymbolInfoTick(_Symbol, tick);

      Sleep(SLEEP_MS);
   }

   if(InpPrintDebug)
   {
      int left=0;
      for(int i=0;i<PositionsTotal();i++)
      {
         ulong ticket=PositionGetTicket(i);
         if(ticket==0) continue;
         if(!PositionSelectByTicket(ticket)) continue;
         if(IsOurPos(ticket)) left++;
      }
      if(left>0) Print("WARNING: CloseAllOurPositions left open positions: ", left);
   }

   g_hedgeOpenedThisTick = false;
}

//--------------------------- POLICY PIPS -----------------------------
double ExpectedPipsFromPolicy(const LadderRow &row)
  {
   double atr=ATR_Price(InpTF_M5,1);
   if(atr<=0)
      return 0.0;
   double pips=(atr / PipSize()) * row.tp_mult;
   if(pips<1.0)
      pips=1.0;
   return pips;
  }

// Dynamic basket TP in USD
double DynamicTargetUSD(const LadderRow &row)
  {
   double pipVal = PipValuePerLot();
   double netLots = BasketNetLots();
   if(pipVal<=0 || netLots<=0)
      return InpTP_MinUSD;

   double mult = row.tp_mult;
   if(InpTP_ScaleByBestPF>0.0 && row.best_pf>0.0)
      mult *= (1.0 + InpTP_ScaleByBestPF * (row.best_pf-1.0));

   double targetPips = InpTP_BasePips * mult;
   if(targetPips < 1.0)
      targetPips = 1.0;

   double usd = targetPips * pipVal * netLots;

   if(usd < InpTP_MinUSD)
      usd = InpTP_MinUSD;
   if(usd > InpTP_MaxUSD)
      usd = InpTP_MaxUSD;
   return usd;
  }

//--------------------------- HEDGE OPEN ------------------------------
bool TryOpenHedge5D(const LadderRow &row)
  {
   if(g_hedgeOpenedThisTick)
     {
      if(InpPrintDebug)
         //Print("HEDGE: blocked -> already opened this tick");
         return false;
     }
   if(!InpEnableHedge5D)
     {
      if(InpPrintDebug)
         //Print("HEDGE: blocked -> InpEnableHedge5D=false");
         return false;
     }
   int posAll=CountPositionsAll();
   if(posAll<=0)
     {
      if(InpPrintDebug)
         //Print("HEDGE: blocked -> posAll<=0 (magic/symbol mismatch?)");
         return false;
     }
   int dir=0;
   bool placed=false;
   double profitAll = BasketProfitUSD();
   double loss = -profitAll;
   int hedgeN = CountHedgePositions();
   if(profitAll>=0.0)
     {
      if(InpPrintDebug)
         //PrintFormat("HEDGE: blocked -> basket not red profitAll=%.2f",profitAll);
         return false;
     }

   if(loss>InpHedgeStartLoss && hedgeN < InpMaxHedges)
     {
      // Sync hedge flag with reality (harvest may close hedge while basket still has positions)
      g_hedgeOpened = (CountHedgePositions()>0);

      datetime lastH = LastHedgeOpenTime();
      datetime now = (datetime)TimeTradeServer(); // IMPORTANT: same time basis as POSITION_TIME
      if(lastH > 0 && InpHedgeAddCooldownMin > 0)
        {
         long diff_sec = (long)(now - lastH);
         if(diff_sec < 0)
            diff_sec = 0;             // protect against negative time drift

         double mins = (double)diff_sec / 60.0;

         if(mins < (double)InpHedgeAddCooldownMin)
           {
            if(InpPrintDebug)
               //Print("HEDGE: blocked -> cooldown not met; mins=", DoubleToString(mins,2),
               //      " need=", InpHedgeAddCooldownMin);
               return false;
           }
        }

      datetime oldest = OldestOpenTime_All();
      if(oldest <= 0)
        {
         if(InpPrintDebug)
            //Print("HEDGE: blocked -> oldest<=0 (no basket positions?)");
            return false;
        }

      // Use trade server time (same basis as POSITION_TIME)
      long agedSec = (long)(now - oldest);
      if(agedSec < 0)
         agedSec = 0;

      long needSec = (long)InpHedgeAfterDays * 86400L;

      // Only apply age rule when there is NO hedge open yet
      if(hedgeN <= 0)
        {
         if(agedSec < needSec)
           {
            if(InpPrintDebug)
               //Print("HEDGE: blocked -> age not met; agedSec=", (int)agedSec,
               //      " needSec=", (int)needSec);
               return false;
           }
        }

      dir = Hedge_HA_MTF_Dir();
      int lastDir = LastHedgeDir();

      if(lastDir!=0 && CountHedgePositions()>1)
        {
         int wantDir = -lastDir; // MUST alternate
         if(dir != wantDir)
           {
            if(InpPrintDebug)
               //Print("HEDGE: blocked -> need opposite dir vs last hedge");
               return false;
           }
        }

      // Throttle ONLY when adding additional hedges (not the first hedge)
      if(hedgeN > 0 && InpHedgeAddCooldownMin > 0)
        {
         datetime now = (datetime)TimeTradeServer();

         if(g_lastHedgeAttempt > 0 &&
            (now - g_lastHedgeAttempt) < (InpHedgeAddCooldownMin * 60))
           {
            if(InpPrintDebug)
               //Print("HEDGE: blocked -> local throttle (additional hedge)");
               return false;
           }
        }

      if(dir==0)
        {
         //Print("HekenAshi not in favor");
         return false;
        }
      double expPips = ExpectedPipsFromPolicy(row);
      double pipVal  = PipValuePerLot();
      if(pipVal<=0)
         return false;
      if(expPips<=0)
        {
         // Fallback: ATR-based expected pips (policy row missing/invalid)
         double atr = ATR_Price(InpTF_M5,1);
         expPips = (atr>0 ? (atr / PipSize()) : 0.0);
        }
      if(expPips<=1.0)
         expPips = 5.0;
      double needProfit = loss + InpHedgeExtraProfitUSD;
      double lotsRaw = needProfit / (pipVal * expPips);
      double lots = NormalizeLot(lotsRaw);
      if(lots<=0)
         return false;

      double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);

      double sl=0.0, tp=0.0; // NO SL. TP optional but default false.
      if(InpHedgeUseTP)
        {
         if(dir>0)
            tp = NormalizeDouble(ask + expPips*PipSize(), _Digits);
         if(dir<0)
            tp = NormalizeDouble(bid - expPips*PipSize(), _Digits);
        }

      trade.SetExpertMagicNumber((int)g_magicHedge);

      if(dir>0)
         placed = trade.Buy(lots,_Symbol,ask,sl,tp,"HEDGE5D#"+IntegerToString(NextHedgeIndex()));
      if(dir<0)
         placed = trade.Sell(lots,_Symbol,bid,sl,tp,"HEDGE5D#"+IntegerToString(NextHedgeIndex()));

      if(!placed)
        {
         if(InpPrintDebug)
            PrintFormat("HEDGE: ORDER FAILED retcode=%d lastError=%d", (int)trade.ResultRetcode(), (int)GetLastError());
         return false;
        }
      if(placed)
        {
         g_hedgeOpenedThisTick = true;   // <<< THIS IS THE KEY
         g_lastHedgeAttempt = (datetime)TimeTradeServer();
         g_hedgeOpened = true;

         if(InpPrintDebug)
            PrintFormat("HEDGE5D OPENED: dir=%s lots=%.2f",
                        (dir>0?"BUY":"SELL"), lots);
        }
     }
   else
     {
      if(hedgeN>=InpMaxHedges)
        {
         if(InpPrintDebug)
            Print("HEDGE: blocked -> max hedges reached");
         return false;
        }
     }
   return placed;
  }

//--------------------------- HEDGE HARVEST CLOSE ----------------------
// If hedge has floating profit, close hedge + close losing orders up to that profit.
// Example: hedge profit = 3000 -> close hedge + close losing orders whose total loss <= 3000.
void HedgeHarvestClose()
  {
   int total=PositionsTotal();
   if(total<=0)
      g_hedgeOpenedThisTick = false;
   return;

   for(int i=total-1;i>=0;i--)
     {
      ulong hedgeTicket=PositionGetTicket(i);
      if(hedgeTicket==0)
         continue;
      if(!IsOurPos(hedgeTicket))
         continue;

      string hcmt=PositionGetString(POSITION_COMMENT);
      if(StringFind(hcmt,"HEDGE5D#"+IntegerToString(NextHedgeIndex()))<0)
         continue;

      double hedgeProfit=PositionGetDouble(POSITION_PROFIT);
      if(hedgeProfit < InpHedgeHarvestMinProfit)
         continue;

      // harvest cycle guards
      if(InpHedgeHarvestMaxCycles>0 && g_harvestCycles>=InpHedgeHarvestMaxCycles)
         continue;
      if(InpHedgeHarvestCooldownMin>0 && g_lastHarvestTime>0 && (TimeCurrent()-g_lastHarvestTime) < (InpHedgeHarvestCooldownMin*60))
         continue;

      // collect losing non-hedge positions
      ulong ltickets[];
      double losses[];
      int n=0;

      int total2=PositionsTotal();
      for(int j=total2-1;j>=0;j--)
        {
         ulong t=PositionGetTicket(j);
         if(t==0)
            continue;
         if(t==hedgeTicket)
            continue;
         if(!IsOurPos(t))
            continue;

         string cmt=PositionGetString(POSITION_COMMENT);
         if(StringFind(cmt,"HEDGE5D#"+IntegerToString(NextHedgeIndex()))>=0)
            continue;

         double pr=PositionGetDouble(POSITION_PROFIT);
         if(pr<0.0)
           {
            ArrayResize(ltickets,n+1);
            ArrayResize(losses,n+1);
            ltickets[n]=t;
            losses[n]=-pr;
            n++;
           }
        }


      // Harvest selection (best-fit greedy):
      // We want total closed losing-sum as CLOSE AS POSSIBLE to hedgeProfit without exceeding it.
      // Algorithm: repeatedly pick the single loss that best fits the remaining budget (<=remain, closest to remain).
      // This is more reliable than "largest-first" greedy when you have mixed loss sizes.

      ulong sel[];
      double selLoss=0.0;
      double remain=hedgeProfit;

      ulong  partial_ticket=0;
      double partial_volume=0.0;


      bool used[];
      ArrayResize(used,n);
      for(int u=0;u<n;u++)
         used[u]=false;

      while(remain>0.0)
        {
         int bestIdx=-1;
         double bestFit=-1.0;
         for(int k=0;k<n;k++)
           {
            if(used[k])
               continue;
            double L=losses[k];
            if(L<=0)
               continue;
            if(L<=remain)
              {
               if(L>bestFit)
                 {
                  bestFit=L;
                  bestIdx=k;
                 }
              }
           }
         if(bestIdx<0)
            break;

         used[bestIdx]=true;

         int msz=ArraySize(sel);
         ArrayResize(sel,msz+1);
         sel[msz]=ltickets[bestIdx];

         selLoss += losses[bestIdx];
         remain  -= losses[bestIdx];
        }


      // If nothing fits (all single losses > hedgeProfit), use partial close on the "best" losing position
      // so hedge profit can still pay down loss. Requires broker partial close support.
      if(InpAllowPartialClose && ArraySize(sel)==0 && n>0 && remain>0.0)
        {
         // pick the smallest loss that is still larger than remain (closest above remain)
         int pick=-1;
         double bestAbove=1e100;
         for(int k=0;k<n;k++)
           {
            double L=losses[k];
            if(L>remain && L<bestAbove)
              {
               bestAbove=L;
               pick=k;
              }
           }
         // if none above, pick the largest loss (shouldn't happen if sel empty, but safe)
         if(pick<0)
           {
            double mx=-1;
            for(int k=0;k<n;k++)
              {
               if(losses[k]>mx)
                 {
                  mx=losses[k];
                  pick=k;
                 }
              }
           }

         if(pick>=0)
           {
            ulong pt = ltickets[pick];
            if(PositionSelectByTicket(pt))
              {
               double vol = PositionGetDouble(POSITION_VOLUME);
               double L   = losses[pick]; // abs loss for full position
               if(vol>0 && L>0)
                 {
                  // close fraction so estimated realized loss ~= remain (<= hedgeProfit)
                  double frac = remain / L;
                  if(frac>0.95)
                     frac=0.95; // avoid accidental full close from rounding
                  if(frac<0.01)
                     frac=0.01;

                  double partVol = NormalizeVolumeToStep(vol * frac);
                  if(partVol>0.0 && partVol < vol)
                    {
                     // Mark this ticket for partial close after hedge is closed
                     // We store it by pushing into sel[] and using a sentinel via negative remain in selLoss calc later.
                     int msz=ArraySize(sel);
                     ArrayResize(sel,msz+1);
                     sel[msz]=pt;
                     selLoss += remain; // approximate amount paid down
                     remain = 0.0;
                     // We will perform partial close in the close loop by detecting requested volume.
                    }
                 }
              }
           }
        }

      trade.SetExpertMagicNumber(InpMagic);

      // close hedge first to lock in profit, then close selected losers
      if(!trade.PositionClose(hedgeTicket))
        {
         if(InpPrintDebug)
            Print("HedgeHarvest: failed to close hedge ticket=",hedgeTicket," err=",GetLastError());
         return;
        }


      // Hedge is now closed; allow new hedge to open later if needed
      g_hedgeOpened=false;
      g_hedgeOpenedThisTick = false;
      int closedN=0;
      for(int z=0; z<ArraySize(sel); z++)
        {
         ulong t=sel[z];
         if(!PositionSelectByTicket(t))
            continue;

         if(t==partial_ticket && partial_volume>0.0)
           {
            if(trade.PositionClosePartial(t, partial_volume))
               closedN++;
           }
         else
           {
            if(trade.PositionClose(t))
               closedN++;
           }
        }

      if(InpPrintDebug)
         PrintFormat("HedgeHarvest: closed hedge profit=%.2f and %d losing orders totaling=%.2f (remain=%.2f)",
                     hedgeProfit, closedN, selLoss, remain);

      g_harvestCycles++;
      g_lastHarvestTime=TimeCurrent();

      return; // handle one hedge at a time
     }
  }


//--------------------------- BUTTONS (TOP-RIGHT, COLORED) ------------
// NOTE: Buttons look best on a clean chart background.
void Buttons_UpdateText()
  {
   if(ObjectFind(0,BTN_TOGGLE)>=0)
     {
      ObjectSetString(0,BTN_TOGGLE,OBJPROP_TEXT, g_tradeEnabled ? "TRADE: ON" : "TRADE: OFF");
      ObjectSetInteger(0,BTN_TOGGLE,OBJPROP_BGCOLOR, g_tradeEnabled ? clrDodgerBlue : clrGray);
      ObjectSetInteger(0,BTN_TOGGLE,OBJPROP_COLOR, clrWhite);
      ObjectSetInteger(0,BTN_TOGGLE,OBJPROP_BORDER_COLOR, clrBlack);
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void Buttons_Create()
  {
   int x=140, y=10;

// TRADE toggle
   if(ObjectFind(0,BTN_TOGGLE)<0)
     {
      ObjectCreate(0,BTN_TOGGLE,OBJ_BUTTON,0,0,0);
      ObjectSetInteger(0,BTN_TOGGLE,OBJPROP_CORNER,CORNER_RIGHT_UPPER);
      ObjectSetInteger(0,BTN_TOGGLE,OBJPROP_XDISTANCE,x);
      ObjectSetInteger(0,BTN_TOGGLE,OBJPROP_YDISTANCE,y);
      ObjectSetInteger(0,BTN_TOGGLE,OBJPROP_XSIZE,130);
      ObjectSetInteger(0,BTN_TOGGLE,OBJPROP_YSIZE,28);
      ObjectSetInteger(0,BTN_TOGGLE,OBJPROP_FONTSIZE,10);
      ObjectSetInteger(0,BTN_TOGGLE,OBJPROP_HIDDEN,false);
      ObjectSetInteger(0,BTN_TOGGLE,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,BTN_TOGGLE,OBJPROP_BACK,false);
     }

// CLOSE ALL
   if(ObjectFind(0,BTN_CLOSE)<0)
     {
      ObjectCreate(0,BTN_CLOSE,OBJ_BUTTON,0,0,0);
      ObjectSetInteger(0,BTN_CLOSE,OBJPROP_CORNER,CORNER_RIGHT_UPPER);
      ObjectSetInteger(0,BTN_CLOSE,OBJPROP_XDISTANCE,x);
      ObjectSetInteger(0,BTN_CLOSE,OBJPROP_YDISTANCE,y+38);
      ObjectSetInteger(0,BTN_CLOSE,OBJPROP_XSIZE,130);
      ObjectSetInteger(0,BTN_CLOSE,OBJPROP_YSIZE,28);
      ObjectSetInteger(0,BTN_CLOSE,OBJPROP_FONTSIZE,10);
      ObjectSetString(0,BTN_CLOSE,OBJPROP_TEXT,"CLOSE ALL");
      ObjectSetInteger(0,BTN_CLOSE,OBJPROP_BGCOLOR,clrFireBrick);
      ObjectSetInteger(0,BTN_CLOSE,OBJPROP_COLOR,clrWhite);
      ObjectSetInteger(0,BTN_CLOSE,OBJPROP_BORDER_COLOR,clrBlack);
      ObjectSetInteger(0,BTN_CLOSE,OBJPROP_HIDDEN,false);
      ObjectSetInteger(0,BTN_CLOSE,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,BTN_CLOSE,OBJPROP_BACK,false);
     }

   Buttons_UpdateText();
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void Buttons_Delete()
  {
   ObjectDelete(0,BTN_TOGGLE);
   ObjectDelete(0,BTN_CLOSE);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
  {
   if(id!=CHARTEVENT_OBJECT_CLICK)
      return;

   if(sparam==BTN_TOGGLE)
     {
      g_tradeEnabled = !g_tradeEnabled;
      Buttons_UpdateText();
      if(InpPrintDebug)
         Print("BUTTON: Trade ", (g_tradeEnabled?"ON":"OFF"));
      return;
     }

   if(sparam==BTN_CLOSE)
     {
      if(InpPrintDebug)
         Print("BUTTON: CLOSE ALL");
      CloseAllOurPositions();
      return;
     }
  }

//--------------------------- INIT / TICK -----------------------------
int OnInit()
  {
   g_magicHedge = (g_magicHedge==0 ? (InpMagic + 777) : g_magicHedge);

   if(InpPrintDebug)
      Print("EA START v1p13: debug prints enabled");

   trade.SetExpertMagicNumber(InpMagic);

   if(!LoadLadder_CommonCSV(InpPolicyFile))
      Print("ERROR: policy ladder not loaded from COMMON\\Files -> EA will not trade.");

   Buttons_Create();
   ObjectDelete(0, "EA_PANEL");
   ChartSetInteger(0, CHART_SHOW_TRADE_LEVELS, false);
   ChartSetInteger(0, CHART_SHOW_OBJECT_DESCR, false);

   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(IsNewBar(_Period,g_lastBar))
      if(CountHedgePositions()>=InpMaxHedges)
         g_hedgeOpenedThisTick = true;
      else
         g_hedgeOpenedThisTick = false;
   else
      if(CountHedgePositions()>=InpMaxHedges)
         g_hedgeOpenedThisTick = true;

   Display();
   if(CountHedgePositions() == 0)
      g_lastHedgeAttempt = 0;

   if(ladder_count<=0)
     {
      if(InpPrintDebug)
         Print("WARN: ladder_count<=0 (policy_pf not loaded). Hedge will use ATR fallback; normal entries disabled.");
     }
   double sp=SpreadPips();
   bool allow_entries = true;
   if(InpMaxSpreadPipsFilter>0 && sp>InpMaxSpreadPipsFilter)
      allow_entries=false;

   int posAll=CountPositionsAll();
   if(posAll==0)
     {
      g_hedgeOpened=false;
      g_harvestCycles=0;
      g_lastHarvestTime=0;
     }

// Hedge harvest: when hedge has profit, close hedge + close losers up to that profit
   if(posAll>0)
      HedgeHarvestClose();

// current ladder row
   string state = CombinedMarketState_NoTDI();
   int hour=HourUTCNow();
   int wday=WeekdayUTCNow();
   string sb=SpreadBucket(sp);

   LadderRow row;
   ZeroMemory(row);
   bool ok = false;
   if(ladder_count>0)
      ok = PickBestRow(state,hour,wday,sb,row);
// 1) Dynamic basket TP: close ALL when profit >= dynamic target
// 1) Basket close (ALWAYS evaluated when positions exist)
   if(posAll>0)
      CheckDynamicClose();

// 2) Hedge routine (after 5 days loss)
   TryOpenHedge5D(row);
// 3) Normal entries (only if trade enabled)
   if(!g_tradeEnabled)
      allow_entries=false;

   if(!InpAllowNormalEntries)
      allow_entries=false;

   bool newbar = IsNewBar(_Period,g_lastBar);

   if(posAll>=InpMaxPositionsPerSymbol)
      allow_entries=false;

   if(!newbar)
     {
      if(InpOneTradePerBar)
        {
         if(countPosPerBar()>0)
            allow_entries=false;
        }
      else
        {
         if(countPosPerBar()>=InpMaxTradesPerBar)
            allow_entries=false;
        }
     }

   if(!allow_entries)
      return;

   int dir = HA_MTF_Dir();
   if(dir==0)
      return;

   datetime curBar=iTime(_Symbol,_Period,0);
   if(InpOneTradePerBar && g_lastTradeBar==curBar)
      return;

   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);

   double sl=0.0;
   double tp=0.0; // per-trade TP off; dynamic basket TP handles exits

   double lots=NormalizeLot(InpLots_Normal);
   trade.SetExpertMagicNumber(InpMagic);

   bool placed=false;
   if(dir>0)
      placed=trade.Buy(lots,_Symbol,ask,sl,tp,"NORMAL_MTF");
   else
      placed=trade.Sell(lots,_Symbol,bid,sl,tp,"NORMAL_MTF");

   if(placed)
      g_lastTradeBar=curBar;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   Buttons_Delete();
  }
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
