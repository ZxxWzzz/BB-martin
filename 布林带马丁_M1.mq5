//+------------------------------------------------------------------+
//|                                           布林带马丁_M1.mq5       |
//|              布林带震荡 + 马丁格尔 黄金M1 v2.0                      |
//+------------------------------------------------------------------+
//|  策略: M1高频震荡回归马丁                                           |
//|  入场: BB(30,2.2)触轨 + RSI(22/78) + 单边过滤 + 斜率过滤           |
//|  加仓: 递增间距(5→18覆盖100刀) + 中轨移动确认 + K线间隔             |
//|  出场: 回中轨止盈 / 篮子止盈 / 风控强平                             |
//+------------------------------------------------------------------+
#property copyright   "布林带马丁 M1 v2.0"
#property version     "2.00"
#property description "高频震荡回归马丁 (XAU M1)"
#property strict

#include <Trade\Trade.mqh>

//--- 信号参数
input group              "=== 信号 ==="
input int                Inp_BB_Period    = 30;          // BB周期
input double             Inp_BB_Dev       = 2.2;         // BB偏差
input int                Inp_RSI_Period   = 14;          // RSI周期
input double             Inp_RSI_OB       = 78.0;        // RSI做空阈值
input double             Inp_RSI_OS       = 22.0;        // RSI做多阈值

//--- 单边过滤
input group              "=== 单边过滤 ==="
input int                Inp_OB_Lookback  = 5;           // 外轨检测K线数
input int                Inp_OB_MaxClose  = 2;           // 最大允许外轨收盘数
input int                Inp_SlopeBars    = 8;           // 斜率检测K线数
input double             Inp_SlopeATR     = 0.7;         // 斜率ATR倍数阈值
input double             Inp_WidthATR     = 5.0;         // 带宽ATR上限

//--- 马丁加仓
input group              "=== 马丁加仓 ==="
input int                Inp_MaxLayers    = 11;          // 最大层数
input double             Inp_StartLots    = 0.01;        // 首单手数
input double             Inp_LotMulti     = 1.25;        // 加仓倍数
input double             Inp_MaxTotalLots = 0.60;        // 最大总手数
input string             Inp_GapSeq       = "5,6,7,8,9,10,11,12,14,18"; // 加仓间距序列(USD)
input double             Inp_MidMove      = 1.0;         // 中轨移动确认(USD)
input int                Inp_MinBars      = 2;           // 加仓最小K线间隔

//--- 出场
input group              "=== 出场 ==="
input double             Inp_TP_Basket    = 8.0;         // 篮子止盈(USD)
input double             Inp_TP_MidMin    = 2.0;         // 回中轨最低盈利(USD)

//--- 风控
input group              "=== 风控 ==="
input double             Inp_MaxDD_Pct    = 15.0;        // 最大回撤%
input double             Inp_DailyLoss_Pct= 5.0;         // 日亏上限%
input double             Inp_MaxFloat_Pct = 12.0;        // 浮亏强平%

//--- 交易
input group              "=== 交易 ==="
input int                Inp_MagicNumber  = 20260622;    // 魔术号
input int                Inp_MaxSpread    = 80;          // 最大点差(0=不限)
input int                Inp_Slippage     = 30;          // 滑点
input int                Inp_StartHour    = 3;           // 交易开始时
input int                Inp_EndHour      = 22;          // 交易结束时

//--- 数据导出
input group              "=== 导出 ==="
input bool               Inp_Export       = true;        // 启用导出
input int                Inp_ExportMs     = 1000;        // 导出节流(ms)

//--- 调试
input bool               Inp_Debug        = true;

//--- 全局变量
CTrade         trade;
int            bbHandle, rsiHandle, atrHandle;
double         peakEquity, dayStartEquity;
int            lastDay, barCount;
int            cycleDirection;     // 0=空仓, 1=多, -1=空
int            cycleLayer;
string         panelName = "BBMartin";
bool           dayLocked;

// 加仓控制
double         gapSequence[10];
int            gapCount;
double         lastAddMidline;     // 上次加仓时的中轨值
int            lastAddBar;         // 上次加仓时的K线编号

// 数据导出
uint           lastExportTick = 0;
int            exportCycleId  = 0;
datetime       cycleOpenTime  = 0;
double         cycleEntryPrice= 0;

//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING DetectFilling()
{
   long fm = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fm & SYMBOL_FILLING_FOK) != 0) return ORDER_FILLING_FOK;
   if((fm & SYMBOL_FILLING_IOC) != 0) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

void ParseGapSequence()
{
   gapCount = 0;
   string parts[];
   int n = StringSplit(Inp_GapSeq, ',', parts);
   for(int i = 0; i < n && i < 10; i++)
   {
      gapSequence[i] = StringToDouble(parts[i]);
      gapCount++;
   }
}

double GetGapForLayer(int layer)
{
   int idx = layer - 1;  // layer 2 → idx 1 → gapSequence[0]
   if(idx < 1) return gapSequence[0];
   idx--;
   if(idx >= gapCount) return gapSequence[gapCount - 1];
   return gapSequence[idx];
}

int OnInit()
{
   ParseGapSequence();

   bbHandle = iBands(_Symbol, PERIOD_CURRENT, Inp_BB_Period, 0, Inp_BB_Dev, PRICE_CLOSE);
   if(bbHandle == INVALID_HANDLE) { Print("BB创建失败"); return INIT_FAILED; }

   rsiHandle = iRSI(_Symbol, PERIOD_CURRENT, Inp_RSI_Period, PRICE_CLOSE);
   if(rsiHandle == INVALID_HANDLE) { Print("RSI创建失败"); return INIT_FAILED; }

   atrHandle = iATR(_Symbol, PERIOD_CURRENT, 14);
   if(atrHandle == INVALID_HANDLE) { Print("ATR创建失败"); return INIT_FAILED; }

   ENUM_ORDER_TYPE_FILLING ft = DetectFilling();
   trade.SetExpertMagicNumber(Inp_MagicNumber);
   trade.SetDeviationInPoints(Inp_Slippage);
   trade.SetTypeFilling(ft);

   peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   dayStartEquity = peakEquity;
   MqlDateTime dt; TimeTradeServer(dt); lastDay = dt.day;
   barCount = 0;
   dayLocked = false;
   lastAddBar = 0;
   lastAddMidline = 0;
   SyncCycleState();

   Print("=== 布林带马丁 M1 v2.0 ===");
   Print("品种=", _Symbol, " BB(", Inp_BB_Period, ",", Inp_BB_Dev, ") RSI(",
         Inp_RSI_Period, ") OB=", Inp_RSI_OB, " OS=", Inp_RSI_OS);
   Print("层数=", Inp_MaxLayers, " 倍数=", Inp_LotMulti, " MaxLots=", Inp_MaxTotalLots);
   Print("间距序列=", Inp_GapSeq, " 中轨确认=", Inp_MidMove, " MinBars=", Inp_MinBars);
   Print("篮子TP=", Inp_TP_Basket, " 中轨TP最低=", Inp_TP_MidMin);
   Print("DD熔断=", Inp_MaxDD_Pct, "% 日亏=", Inp_DailyLoss_Pct, "% 浮亏=", Inp_MaxFloat_Pct, "%");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(bbHandle != INVALID_HANDLE) IndicatorRelease(bbHandle);
   if(rsiHandle != INVALID_HANDLE) IndicatorRelease(rsiHandle);
   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
   ObjectsDeleteAll(0, panelName);
}

void OnTick()
{
   UpdatePeakEquity();

   if(cycleDirection != 0)
   {
      if(CheckForceClose()) return;
      CheckTakeProfit();
      if(cycleDirection != 0) CheckMartingaleAdd();
   }

   if(!IsNewBar()) return;
   barCount++;
   CheckNewDay();

   if(cycleDirection == 0) CheckEntry();

   UpdatePanel();
   ExportState();
   ExportEquitySnapshot();
}

bool IsNewBar()
{
   static datetime last = 0;
   datetime cur = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(cur == last) return false;
   last = cur;
   return true;
}

void UpdatePeakEquity()
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(cycleDirection == 0)
      peakEquity = eq;
   else if(eq > peakEquity)
      peakEquity = eq;
}

void CheckNewDay()
{
   MqlDateTime dt; TimeTradeServer(dt);
   if(dt.day != lastDay)
   {
      lastDay = dt.day;
      dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      dayLocked = false;
      if(Inp_Debug) Print("[日切] 新一天 权益=", DoubleToString(dayStartEquity, 2));
   }
}

//+------------------------------------------------------------------+
//| 风控计算                                                           |
//+------------------------------------------------------------------+
double GetDrawdownPct()
{
   if(peakEquity <= 0) return 0;
   return (peakEquity - AccountInfoDouble(ACCOUNT_EQUITY)) / peakEquity * 100.0;
}

double GetDailyLossPct()
{
   if(dayStartEquity <= 0) return 0;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq >= dayStartEquity) return 0;
   return (dayStartEquity - eq) / dayStartEquity * 100.0;
}

double GetFloatLossPct()
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal <= 0) return 0;
   double fl = eq - bal;
   if(fl >= 0) return 0;
   return MathAbs(fl) / bal * 100.0;
}

bool CheckForceClose()
{
   bool force = false;
   string reason = "";

   double dd = GetDrawdownPct();
   if(dd >= Inp_MaxDD_Pct) { force = true; reason = StringFormat("回撤熔断 DD=%.1f%%", dd); }

   double fl = GetFloatLossPct();
   if(!force && fl >= Inp_MaxFloat_Pct) { force = true; reason = StringFormat("浮亏强平 %.1f%%", fl); }

   double dayL = GetDailyLossPct();
   if(!force && dayL >= Inp_DailyLoss_Pct) { force = true; reason = StringFormat("日亏上限 %.1f%%", dayL); dayLocked = true; }

   if(force)
   {
      Print("[风控] ", reason, " 强制平仓!");
      ExportTradeClose(reason);
      CloseAllPositions();
      cycleDirection = 0;
      cycleLayer = 0;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| 入场逻辑: BB触轨 + RSI极值 + 单边过滤 + 斜率过滤 + 带宽过滤        |
//+------------------------------------------------------------------+
bool IsTradeTime()
{
   MqlDateTime dt; TimeTradeServer(dt);
   return (dt.hour >= Inp_StartHour && dt.hour < Inp_EndHour);
}

bool CheckOuterBandFilter(bool isBuy)
{
   int count = 0;
   double bb_band[];
   ArraySetAsSeries(bb_band, true);

   int bufIdx = isBuy ? 2 : 1; // lower for buy, upper for sell
   if(CopyBuffer(bbHandle, bufIdx, 1, Inp_OB_Lookback, bb_band) < Inp_OB_Lookback) return false;

   for(int i = 0; i < Inp_OB_Lookback; i++)
   {
      double cl = iClose(_Symbol, PERIOD_CURRENT, i + 1);
      if(isBuy && cl <= bb_band[i]) count++;
      if(!isBuy && cl >= bb_band[i]) count++;
   }

   return (count > Inp_OB_MaxClose);
}

bool CheckSlopeFilter(bool isBuy)
{
   double bb_mid[];
   ArraySetAsSeries(bb_mid, true);
   if(CopyBuffer(bbHandle, 0, 1, Inp_SlopeBars + 1, bb_mid) < Inp_SlopeBars + 1) return false;

   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(atrHandle, 0, 1, 1, atr) < 1) return false;
   if(atr[0] <= 0) return false;

   double slope = bb_mid[0] - bb_mid[Inp_SlopeBars];
   double threshold = atr[0] * Inp_SlopeATR;

   if(isBuy && slope < -threshold) return true;   // 中轨快速下行，禁止做多
   if(!isBuy && slope > threshold) return true;    // 中轨快速上行，禁止做空
   return false;
}

bool CheckBBWidthFilter()
{
   double bb_u[], bb_l[], atr[];
   ArraySetAsSeries(bb_u, true);
   ArraySetAsSeries(bb_l, true);
   ArraySetAsSeries(atr, true);

   if(CopyBuffer(bbHandle, 1, 1, 1, bb_u) < 1) return false;
   if(CopyBuffer(bbHandle, 2, 1, 1, bb_l) < 1) return false;
   if(CopyBuffer(atrHandle, 0, 1, 1, atr) < 1) return false;
   if(atr[0] <= 0) return false;

   double width = bb_u[0] - bb_l[0];
   return (width > atr[0] * Inp_WidthATR);
}

void CheckEntry()
{
   if(!IsTradeTime()) return;
   if(dayLocked) return;
   if(Inp_MaxSpread > 0 && SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > Inp_MaxSpread) return;

   double bb_upper[], bb_middle[], bb_lower[];
   ArraySetAsSeries(bb_upper, true);
   ArraySetAsSeries(bb_middle, true);
   ArraySetAsSeries(bb_lower, true);
   if(CopyBuffer(bbHandle, 1, 0, 3, bb_upper) < 3) return;
   if(CopyBuffer(bbHandle, 0, 0, 3, bb_middle) < 3) return;
   if(CopyBuffer(bbHandle, 2, 0, 3, bb_lower) < 3) return;

   double close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   if(close1 == 0) return;

   bool touchUpper = (close1 >= bb_upper[1]);
   bool touchLower = (close1 <= bb_lower[1]);

   if(!touchUpper && !touchLower) return;

   // RSI确认
   double rsi[];
   ArraySetAsSeries(rsi, true);
   if(CopyBuffer(rsiHandle, 0, 0, 3, rsi) < 3) return;

   if(touchUpper && rsi[1] < Inp_RSI_OB) return;
   if(touchLower && rsi[1] > Inp_RSI_OS) return;

   // 单边过滤: 连续收在外轨外
   bool isBuy = touchLower;
   if(CheckOuterBandFilter(isBuy))
   {
      if(Inp_Debug) Print("[过滤] 单边推进 ", isBuy?"多":"空", " 被拦截");
      return;
   }

   // 斜率过滤: 中轨快速移动
   if(CheckSlopeFilter(isBuy))
   {
      if(Inp_Debug) Print("[过滤] 中轨斜率过大 ", isBuy?"多":"空", " 被拦截");
      return;
   }

   // 带宽过滤: 布林带异常扩张
   if(CheckBBWidthFilter())
   {
      if(Inp_Debug) Print("[过滤] 布林带宽异常 被拦截");
      return;
   }

   // 风控检查
   if(GetDrawdownPct() >= Inp_MaxDD_Pct) return;
   if(GetDailyLossPct() >= Inp_DailyLoss_Pct) return;

   // 开仓
   double lots = Inp_StartLots;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(touchLower)
   {
      if(Inp_Debug)
         Print(">>> 做多 Cl=", DoubleToString(close1,_Digits),
               " Lower=", DoubleToString(bb_lower[1],_Digits),
               " RSI=", DoubleToString(rsi[1],1));

      if(trade.Buy(lots, _Symbol, ask, 0, 0, "M1多L1"))
      {
         cycleDirection = 1;
         cycleLayer = 1;
         lastAddBar = barCount;
         lastAddMidline = bb_middle[0];
         exportCycleId++;
         cycleOpenTime = TimeCurrent();
         cycleEntryPrice = ask;
         Print("开多L1 @", ask, " Lots=", lots);
      }
   }
   else if(touchUpper)
   {
      if(Inp_Debug)
         Print(">>> 做空 Cl=", DoubleToString(close1,_Digits),
               " Upper=", DoubleToString(bb_upper[1],_Digits),
               " RSI=", DoubleToString(rsi[1],1));

      if(trade.Sell(lots, _Symbol, bid, 0, 0, "M1空L1"))
      {
         cycleDirection = -1;
         cycleLayer = 1;
         lastAddBar = barCount;
         lastAddMidline = bb_middle[0];
         exportCycleId++;
         cycleOpenTime = TimeCurrent();
         cycleEntryPrice = bid;
         Print("开空L1 @", bid, " Lots=", lots);
      }
   }
}

//+------------------------------------------------------------------+
//| 加仓逻辑: 递增间距 + 中轨移动确认 + K线间隔                         |
//+------------------------------------------------------------------+
void CheckMartingaleAdd()
{
   if(cycleLayer >= Inp_MaxLayers) return;

   // K线间隔检查
   if(barCount - lastAddBar < Inp_MinBars) return;

   double nextLots = GetLayerLots(cycleLayer + 1);
   double totalAfter = GetCurrentTotalLots() + nextLots;
   if(totalAfter > Inp_MaxTotalLots) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double lastOpenPrice = GetLastOpenPrice();
   if(lastOpenPrice == 0) return;

   // 当前层的间距(USD转价格点)
   double gapUSD = GetGapForLayer(cycleLayer + 1);
   double pointVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE) /
                     SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double gapPrice = (pointVal > 0) ? gapUSD / (pointVal * Inp_StartLots) : gapUSD;

   // 中轨移动确认
   double bb_mid[];
   ArraySetAsSeries(bb_mid, true);
   if(CopyBuffer(bbHandle, 0, 0, 1, bb_mid) < 1) return;
   double midNow = bb_mid[0];

   if(cycleDirection == 1)
   {
      // 做多: 价格下跌够间距 且 中轨也下移了
      if(ask <= lastOpenPrice - gapPrice)
      {
         double midDrop = lastAddMidline - midNow;
         if(midDrop < Inp_MidMove && cycleLayer >= 2) return; // L2起才要求中轨确认

         string comment = StringFormat("M1多L%d", cycleLayer + 1);
         if(trade.Buy(nextLots, _Symbol, ask, 0, 0, comment))
         {
            cycleLayer++;
            lastAddBar = barCount;
            lastAddMidline = midNow;
            Print("+加仓 多L", cycleLayer, " @", ask, " Gap=", gapUSD,
                  " Lots=", nextLots, " 总=", DoubleToString(GetCurrentTotalLots(), 2));
         }
      }
   }
   else if(cycleDirection == -1)
   {
      // 做空: 价格上涨够间距 且 中轨也上移了
      if(bid >= lastOpenPrice + gapPrice)
      {
         double midRise = midNow - lastAddMidline;
         if(midRise < Inp_MidMove && cycleLayer >= 2) return;

         string comment = StringFormat("M1空L%d", cycleLayer + 1);
         if(trade.Sell(nextLots, _Symbol, bid, 0, 0, comment))
         {
            cycleLayer++;
            lastAddBar = barCount;
            lastAddMidline = midNow;
            Print("+加仓 空L", cycleLayer, " @", bid, " Gap=", gapUSD,
                  " Lots=", nextLots, " 总=", DoubleToString(GetCurrentTotalLots(), 2));
         }
      }
   }
}

double GetLayerLots(int layer)
{
   double lots = Inp_StartLots;
   for(int i = 1; i < layer; i++)
      lots *= Inp_LotMulti;

   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   lots = MathFloor(lots / step) * step;
   lots = MathMax(lots, minLot);
   lots = MathMin(lots, maxLot);
   return NormalizeDouble(lots, 2);
}

double GetCurrentTotalLots()
{
   double total = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i); if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != Inp_MagicNumber) continue;
      total += PositionGetDouble(POSITION_VOLUME);
   }
   return total;
}

double GetLastOpenPrice()
{
   double lastPrice = 0;
   datetime lastTime = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i); if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != Inp_MagicNumber) continue;

      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      if(openTime > lastTime)
      {
         lastTime = openTime;
         lastPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      }
   }
   return lastPrice;
}

//+------------------------------------------------------------------+
//| 出场逻辑: 篮子止盈 / 回中轨止盈                                     |
//+------------------------------------------------------------------+
void CheckTakeProfit()
{
   double totalProfit = CalcTotalProfit();

   // 篮子止盈
   if(totalProfit >= Inp_TP_Basket)
   {
      Print("<<< 篮子止盈! 盈利=", DoubleToString(totalProfit, 2), " 层数=", cycleLayer);
      ExportTradeClose("TP_BASKET");
      CloseAllPositions();
      cycleDirection = 0;
      cycleLayer = 0;
      return;
   }

   // 回中轨止盈
   if(totalProfit >= Inp_TP_MidMin)
   {
      double bb_middle[];
      ArraySetAsSeries(bb_middle, true);
      if(CopyBuffer(bbHandle, 0, 0, 2, bb_middle) < 2) return;

      double price = (cycleDirection == 1) ?
                     SymbolInfoDouble(_Symbol, SYMBOL_BID) :
                     SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      bool crossMiddle = false;
      if(cycleDirection == 1 && price >= bb_middle[0]) crossMiddle = true;
      if(cycleDirection == -1 && price <= bb_middle[0]) crossMiddle = true;

      if(crossMiddle)
      {
         Print("<<< 回中轨止盈 盈利=", DoubleToString(totalProfit, 2), " 层数=", cycleLayer);
         ExportTradeClose("TP_MIDDLE");
         CloseAllPositions();
         cycleDirection = 0;
         cycleLayer = 0;
      }
   }
}

double CalcTotalProfit()
{
   double tot = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i); if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != Inp_MagicNumber) continue;
      tot += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   return tot;
}

void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i); if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != Inp_MagicNumber) continue;
      if(!trade.PositionClose(t))
         Print("平仓失败 ticket=", t, " err=", trade.ResultRetcode());
   }
}

//+------------------------------------------------------------------+
//| 状态同步(EA重启时恢复持仓状态)                                      |
//+------------------------------------------------------------------+
void SyncCycleState()
{
   cycleDirection = 0;
   cycleLayer = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i); if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != Inp_MagicNumber) continue;

      cycleLayer++;
      long pt = PositionGetInteger(POSITION_TYPE);
      if(pt == POSITION_TYPE_BUY) cycleDirection = 1;
      else cycleDirection = -1;
   }

   if(cycleLayer == 0) cycleDirection = 0;

   // 恢复中轨记录
   if(cycleDirection != 0)
   {
      double bb_mid[];
      ArraySetAsSeries(bb_mid, true);
      if(CopyBuffer(bbHandle, 0, 0, 1, bb_mid) >= 1)
         lastAddMidline = bb_mid[0];
   }
}

//+------------------------------------------------------------------+
//| 面板显示                                                           |
//+------------------------------------------------------------------+
void UpdatePanel()
{
   int y = 30, lh = 18;
   double dd = GetDrawdownPct();
   double dayL = GetDailyLossPct();
   double fl = GetFloatLossPct();
   double pnl = CalcTotalProfit();
   double totalLots = GetCurrentTotalLots();

   string dir = (cycleDirection == 1) ? "做多" : (cycleDirection == -1) ? "做空" : "空仓";

   CreateLbl(panelName+"t", 10, y, "=== BB马丁 M1 v2.0 ===", clrGold); y += lh + 4;
   CreateLbl(panelName+"d", 10, y, StringFormat("%s L:%d/%d 手数:%.2f/%.2f", dir, cycleLayer, Inp_MaxLayers, totalLots, Inp_MaxTotalLots),
             cycleDirection==1?clrLime:cycleDirection==-1?clrRed:clrGray); y += lh;

   if(cycleDirection != 0)
   {
      double nextGap = (cycleLayer < Inp_MaxLayers) ? GetGapForLayer(cycleLayer + 1) : 0;
      CreateLbl(panelName+"p", 10, y, StringFormat("浮盈:%.2f 篮子TP:%.1f", pnl, Inp_TP_Basket),
                pnl >= 0 ? clrLime : clrRed); y += lh;
      CreateLbl(panelName+"g", 10, y, StringFormat("下层间距:$%.0f 中轨确认:$%.1f", nextGap, Inp_MidMove), clrAqua); y += lh;
   }
   else
   {
      CreateLbl(panelName+"p", 10, y, "", clrBlack); y += lh;
      CreateLbl(panelName+"g", 10, y, "", clrBlack); y += lh;
   }

   CreateLbl(panelName+"dd", 10, y, StringFormat("DD:%.1f%% 日亏:%.1f%% 浮亏:%.1f%%", dd, dayL, fl),
             dd > 8 ? clrRed : clrWhite); y += lh;

   if(dayLocked)
   { CreateLbl(panelName+"lk", 10, y, "!! 当日已锁定 !!", clrRed); }
   else
   { CreateLbl(panelName+"lk", 10, y, "", clrBlack); }

   ChartRedraw();
}

void CreateLbl(string nm, int x, int y, string txt, color c)
{
   if(ObjectFind(0, nm) < 0)
   {
      ObjectCreate(0, nm, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, nm, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetString(0, nm, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, nm, OBJPROP_FONTSIZE, 10);
      ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
   }
   ObjectSetInteger(0, nm, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, nm, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, nm, OBJPROP_TEXT, txt);
   ObjectSetInteger(0, nm, OBJPROP_COLOR, c);
}

//+------------------------------------------------------------------+
//| 数据导出: 实时状态                                                  |
//+------------------------------------------------------------------+
void ExportState()
{
   if(!Inp_Export) return;
   uint now = GetTickCount();
   if(now - lastExportTick < (uint)Inp_ExportMs) return;
   lastExportTick = now;

   int h = FileOpen("bb_martin_state.json", FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h == INVALID_HANDLE) return;

   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   double mg  = AccountInfoDouble(ACCOUNT_MARGIN);
   double fm  = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double ml  = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   long   spd = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);

   double bb_u[], bb_m[], bb_l[];
   ArraySetAsSeries(bb_u, true); ArraySetAsSeries(bb_m, true); ArraySetAsSeries(bb_l, true);
   CopyBuffer(bbHandle, 1, 0, 1, bb_u);
   CopyBuffer(bbHandle, 0, 0, 1, bb_m);
   CopyBuffer(bbHandle, 2, 0, 1, bb_l);

   double rsiVal = 0;
   double r[]; ArraySetAsSeries(r, true);
   if(CopyBuffer(rsiHandle, 0, 0, 1, r) > 0) rsiVal = r[0];

   double atrVal = 0;
   double a[]; ArraySetAsSeries(a, true);
   if(CopyBuffer(atrHandle, 0, 0, 1, a) > 0) atrVal = a[0];

   string json = "{\n";
   json += StringFormat("\"timestamp\":\"%s\",\n", TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS));
   json += "\"account\":{";
   json += StringFormat("\"balance\":%.2f,\"equity\":%.2f,\"margin\":%.2f,\"free_margin\":%.2f,\"margin_level\":%.1f", bal, eq, mg, fm, ml);
   json += "},\n";

   json += "\"cycle\":{";
   json += StringFormat("\"active\":%s,", cycleDirection != 0 ? "true" : "false");
   json += StringFormat("\"direction\":%d,", cycleDirection);
   json += StringFormat("\"direction_label\":\"%s\",", cycleDirection==1?"BUY":cycleDirection==-1?"SELL":"IDLE");
   json += StringFormat("\"layer_count\":%d,", cycleLayer);
   json += StringFormat("\"max_layers\":%d,", Inp_MaxLayers);
   json += StringFormat("\"total_lots\":%.2f,", GetCurrentTotalLots());
   json += StringFormat("\"max_total_lots\":%.2f,", Inp_MaxTotalLots);
   json += StringFormat("\"floating_pnl\":%.2f,", CalcTotalProfit());
   json += StringFormat("\"tp_target\":%.2f,", Inp_TP_Basket);
   json += StringFormat("\"cycle_id\":%d", exportCycleId);
   json += "},\n";

   // positions array
   json += "\"positions\":[";
   bool first = true;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i); if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != Inp_MagicNumber) continue;

      if(!first) json += ",";
      first = false;
      json += "{";
      json += StringFormat("\"ticket\":%I64u,", t);
      json += StringFormat("\"type\":\"%s\",", PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY?"BUY":"SELL");
      json += StringFormat("\"lots\":%.2f,", PositionGetDouble(POSITION_VOLUME));
      json += StringFormat("\"open_price\":%s,", DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), _Digits));
      json += StringFormat("\"open_time\":\"%s\",", TimeToString((datetime)PositionGetInteger(POSITION_TIME), TIME_DATE|TIME_SECONDS));
      json += StringFormat("\"profit\":%.2f,", PositionGetDouble(POSITION_PROFIT));
      json += StringFormat("\"swap\":%.2f", PositionGetDouble(POSITION_SWAP));
      json += "}";
   }
   json += "],\n";

   json += "\"risk\":{";
   json += StringFormat("\"drawdown_pct\":%.2f,", GetDrawdownPct());
   json += StringFormat("\"daily_loss_pct\":%.2f,", GetDailyLossPct());
   json += StringFormat("\"float_loss_pct\":%.2f,", GetFloatLossPct());
   json += StringFormat("\"peak_equity\":%.2f,", peakEquity);
   json += StringFormat("\"day_start_equity\":%.2f,", dayStartEquity);
   json += StringFormat("\"day_locked\":%s", dayLocked?"true":"false");
   json += "},\n";

   json += "\"indicators\":{";
   json += StringFormat("\"bb_upper\":%s,", DoubleToString(bb_u[0], _Digits));
   json += StringFormat("\"bb_middle\":%s,", DoubleToString(bb_m[0], _Digits));
   json += StringFormat("\"bb_lower\":%s,", DoubleToString(bb_l[0], _Digits));
   json += StringFormat("\"bb_width\":%.2f,", bb_u[0] - bb_l[0]);
   json += StringFormat("\"rsi\":%.1f,", rsiVal);
   json += StringFormat("\"atr\":%.2f,", atrVal);
   json += StringFormat("\"spread\":%d,", (int)spd);
   json += StringFormat("\"bid\":%s,", DoubleToString(bid, _Digits));
   json += StringFormat("\"ask\":%s", DoubleToString(ask, _Digits));
   json += "}\n";

   json += "}";
   FileWriteString(h, json);
   FileClose(h);
}

//+------------------------------------------------------------------+
//| 数据导出: 交易记录                                                  |
//+------------------------------------------------------------------+
void ExportTradeClose(string closeReason)
{
   if(!Inp_Export) return;

   int h = FileOpen("bb_martin_trades.jsonl", FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h == INVALID_HANDLE) return;
   FileSeek(h, 0, SEEK_END);

   double profit = CalcTotalProfit();
   long duration = (long)(TimeCurrent() - cycleOpenTime);

   string line = "{";
   line += StringFormat("\"cycle_id\":%d,", exportCycleId);
   line += StringFormat("\"direction\":\"%s\",", cycleDirection==1?"BUY":"SELL");
   line += StringFormat("\"open_time\":\"%s\",", TimeToString(cycleOpenTime, TIME_DATE|TIME_SECONDS));
   line += StringFormat("\"close_time\":\"%s\",", TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS));
   line += StringFormat("\"layers_used\":%d,", cycleLayer);
   line += StringFormat("\"total_lots\":%.2f,", GetCurrentTotalLots());
   line += StringFormat("\"profit\":%.2f,", profit);
   line += StringFormat("\"close_reason\":\"%s\",", closeReason);
   line += StringFormat("\"duration_sec\":%d,", (int)duration);
   line += StringFormat("\"entry_price\":%s", DoubleToString(cycleEntryPrice, _Digits));
   line += "}\n";

   FileWriteString(h, line);
   FileClose(h);
}

//+------------------------------------------------------------------+
//| 数据导出: 权益快照                                                  |
//+------------------------------------------------------------------+
void ExportEquitySnapshot()
{
   if(!Inp_Export) return;

   int h = FileOpen("bb_martin_equity.jsonl", FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h == INVALID_HANDLE) return;
   FileSeek(h, 0, SEEK_END);

   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double fl  = CalcTotalProfit();

   string line = StringFormat("{\"t\":\"%s\",\"eq\":%.2f,\"bal\":%.2f,\"fl\":%.2f}\n",
                              TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), eq, bal, fl);
   FileWriteString(h, line);
   FileClose(h);
}
