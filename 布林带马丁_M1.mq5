//+------------------------------------------------------------------+
//|                                           布林带马丁_M1.mq5       |
//|              真距离驱动马丁 (XAU M1) v4.0                          |
//+------------------------------------------------------------------+
//|  v4.0 核心: 真正的马丁(距离驱动)                                    |
//|  ① L1开仓: BB+RSI 信号 + M30大势过滤 + M1过滤                      |
//|  ② L2-L11加仓: 距离驱动(USD序列), 不再依赖RSI/BB信号                |
//|  ③ 趋势保护: M30大势 + M1斜率/单边/带宽 + 流动性熔断                 |
//|  ④ 出场: 篮子$5 / 回中轨$1.5 / 风控强平                            |
//+------------------------------------------------------------------+
#property copyright   "布林带马丁 M1 v4.0"
#property version     "4.00"
#property description "真距离驱动马丁 (XAU M1) - M30大势过滤+流动性熔断"
#property strict

#include <Trade\Trade.mqh>

//--- 信号 (L1入场)
input group              "=== 信号 (L1入场) ==="
input int                Inp_BB_Period    = 30;          // BB周期(M1)
input double             Inp_BB_Dev       = 2.2;         // BB偏差(M1)
input int                Inp_RSI_Period   = 14;          // RSI周期
input double             Inp_RSI_OB       = 72.0;        // RSI做空触发(>=)
input double             Inp_RSI_OS       = 28.0;        // RSI做多触发(<=)

//--- L1入场过滤
input group              "=== L1入场过滤 ==="
input int                Inp_OB_Lookback  = 5;           // 外轨检测K线数
input int                Inp_OB_MaxClose  = 2;           // 最大允许外轨收盘数
input int                Inp_SlopeBars    = 8;           // M1中轨斜率检测K线数
input double             Inp_SlopeATR     = 0.7;         // M1斜率ATR倍数阈值
input double             Inp_WidthATR     = 5.0;         // 带宽ATR上限

//--- M30大势过滤 (新)
input group              "=== M30大势过滤 ==="
input bool               Inp_M30_Filter   = true;        // 启用M30趋势过滤
input int                Inp_M30_BB       = 30;          // M30 BB周期
input double             Inp_M30_BBDev    = 2.2;         // M30 BB偏差
input int                Inp_M30_SlopeBars = 8;          // M30斜率检测K线数
input double             Inp_M30_SlopeATR = 0.5;         // M30斜率ATR倍数

//--- 加仓 (距离驱动)
input group              "=== 加仓 (距离驱动) ==="
input int                Inp_MaxLayers    = 11;          // 最大层数
input string             Inp_LotSeq       = "0.01,0.01,0.02,0.02,0.03,0.04,0.05,0.07,0.10,0.12,0.13"; // 11层手数序列
input string             Inp_DistanceSeq  = "4,5,6,7,8,9,10,11,12,14"; // 距离序列(USD,L2-L11共10项)
input double             Inp_MaxTotalLots = 0.60;        // 最大总手数
input int                Inp_MinBars      = 3;           // 加仓最小K线间隔

//--- 流动性熔断 (新)
input group              "=== 流动性熔断 ==="
input bool               Inp_Liquidity    = true;        // 启用流动性熔断
input double             Inp_LiqRange     = 3.0;         // M1波动触发(USD)
input int                Inp_LiqPauseSec  = 180;         // 暂停秒数

//--- 出场
input group              "=== 出场 ==="
input double             Inp_TP_Basket    = 8.0;         // 篮子止盈(USD)
input double             Inp_TP_MidMin    = 1.5;         // 回中轨最低盈利(USD)

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
int            bbM30Handle, atrM30Handle;
double         peakEquity, dayStartEquity;
int            lastDay, barCount;
int            cycleDirection;     // 0=空仓, 1=多, -1=空
int            cycleLayer;
string         panelName = "BBMartin";
bool           dayLocked;
int            lastAddBar;
datetime       liquidityPausedUntil;

// 序列(解析后)
double         lotSeq[12];
int            lotSeqCount;
double         distSeq[12];
int            distSeqCount;

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

void ParseSequences()
{
   string parts[];
   int n;

   // 手数序列
   n = StringSplit(Inp_LotSeq, ',', parts);
   lotSeqCount = 0;
   for(int i = 0; i < n && i < 12; i++)
   {
      lotSeq[i] = StringToDouble(parts[i]);
      lotSeqCount++;
   }

   // 距离序列
   n = StringSplit(Inp_DistanceSeq, ',', parts);
   distSeqCount = 0;
   for(int i = 0; i < n && i < 12; i++)
   {
      distSeq[i] = StringToDouble(parts[i]);
      distSeqCount++;
   }
}

double GetLotForLayer(int layer)
{
   int idx = layer - 1;
   if(idx < 0) idx = 0;
   if(idx >= lotSeqCount) idx = lotSeqCount - 1;
   double lots = lotSeq[idx];

   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   lots = MathFloor(lots / step) * step;
   lots = MathMax(lots, minLot);
   lots = MathMin(lots, maxLot);
   return NormalizeDouble(lots, 2);
}

double GetDistanceForLayer(int layer)
{
   // L2 → distSeq[0], L3 → distSeq[1] ...
   int idx = layer - 2;
   if(idx < 0) return 0;
   if(idx >= distSeqCount) idx = distSeqCount - 1;
   return distSeq[idx];
}

int OnInit()
{
   ParseSequences();

   bbHandle = iBands(_Symbol, PERIOD_CURRENT, Inp_BB_Period, 0, Inp_BB_Dev, PRICE_CLOSE);
   if(bbHandle == INVALID_HANDLE) { Print("BB创建失败"); return INIT_FAILED; }

   rsiHandle = iRSI(_Symbol, PERIOD_CURRENT, Inp_RSI_Period, PRICE_CLOSE);
   if(rsiHandle == INVALID_HANDLE) { Print("RSI创建失败"); return INIT_FAILED; }

   atrHandle = iATR(_Symbol, PERIOD_CURRENT, 14);
   if(atrHandle == INVALID_HANDLE) { Print("ATR创建失败"); return INIT_FAILED; }

   if(Inp_M30_Filter)
   {
      bbM30Handle = iBands(_Symbol, PERIOD_M30, Inp_M30_BB, 0, Inp_M30_BBDev, PRICE_CLOSE);
      if(bbM30Handle == INVALID_HANDLE) { Print("M30 BB创建失败"); return INIT_FAILED; }

      atrM30Handle = iATR(_Symbol, PERIOD_M30, 14);
      if(atrM30Handle == INVALID_HANDLE) { Print("M30 ATR创建失败"); return INIT_FAILED; }
   }

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
   liquidityPausedUntil = 0;
   SyncCycleState();

   Print("=== 布林带马丁 M1 v4.0 (距离驱动) ===");
   Print("L1信号: BB(", Inp_BB_Period, ",", Inp_BB_Dev, ") RSI ", Inp_RSI_OS, "/", Inp_RSI_OB);
   Print("M30过滤: ", Inp_M30_Filter ? "开启" : "关闭",
         " 斜率阈值=", Inp_M30_SlopeATR, "×ATR");
   Print("加仓序列(USD): ", Inp_DistanceSeq);
   Print("手数序列: ", Inp_LotSeq);
   Print("MaxLayers=", Inp_MaxLayers, " MaxLots=", Inp_MaxTotalLots, " MinBars=", Inp_MinBars);
   Print("流动性: ", Inp_Liquidity ? "开启" : "关闭",
         " M1波动>$", Inp_LiqRange, " 暂停", Inp_LiqPauseSec, "秒");
   Print("TP_Basket=$", Inp_TP_Basket, " TP_Mid_Min=$", Inp_TP_MidMin);
   Print("DD熔断=", Inp_MaxDD_Pct, "% 日亏=", Inp_DailyLoss_Pct, "% 浮亏=", Inp_MaxFloat_Pct, "%");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(bbHandle != INVALID_HANDLE) IndicatorRelease(bbHandle);
   if(rsiHandle != INVALID_HANDLE) IndicatorRelease(rsiHandle);
   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
   if(bbM30Handle != INVALID_HANDLE) IndicatorRelease(bbM30Handle);
   if(atrM30Handle != INVALID_HANDLE) IndicatorRelease(atrM30Handle);
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
   CheckLiquidity();          // 每根新K线检查流动性

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
//| 流动性熔断                                                          |
//+------------------------------------------------------------------+
void CheckLiquidity()
{
   if(!Inp_Liquidity) return;

   double high = iHigh(_Symbol, PERIOD_M1, 1);
   double low  = iLow(_Symbol, PERIOD_M1, 1);
   double range = high - low;

   if(range >= Inp_LiqRange)
   {
      liquidityPausedUntil = TimeCurrent() + Inp_LiqPauseSec;
      Print("[流动性] M1波动$", DoubleToString(range,2), " 触发熔断,暂停至 ",
            TimeToString(liquidityPausedUntil, TIME_DATE|TIME_SECONDS));
   }
}

bool IsLiquidityPaused()
{
   if(!Inp_Liquidity) return false;
   return (TimeCurrent() < liquidityPausedUntil);
}

//+------------------------------------------------------------------+
//| 风控                                                               |
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

bool IsTradeTime()
{
   MqlDateTime dt; TimeTradeServer(dt);
   return (dt.hour >= Inp_StartHour && dt.hour < Inp_EndHour);
}

//+------------------------------------------------------------------+
//| 过滤器: M1 单边/斜率/带宽                                           |
//+------------------------------------------------------------------+
bool CheckOuterBandFilter(bool isBuy)
{
   int count = 0;
   double bb_band[];
   ArraySetAsSeries(bb_band, true);

   int bufIdx = isBuy ? 2 : 1;
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

   if(isBuy && slope < -threshold) return true;
   if(!isBuy && slope > threshold) return true;
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

   return ((bb_u[0] - bb_l[0]) > atr[0] * Inp_WidthATR);
}

//+------------------------------------------------------------------+
//| 过滤器: M30 大势                                                    |
//| 返回true表示阻止该方向开仓                                          |
//+------------------------------------------------------------------+
bool CheckM30TrendFilter(bool isBuy)
{
   if(!Inp_M30_Filter) return false;

   double bb_mid[];
   ArraySetAsSeries(bb_mid, true);
   if(CopyBuffer(bbM30Handle, 0, 1, Inp_M30_SlopeBars + 1, bb_mid) < Inp_M30_SlopeBars + 1) return false;

   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(atrM30Handle, 0, 1, 1, atr) < 1) return false;
   if(atr[0] <= 0) return false;

   double slope = bb_mid[0] - bb_mid[Inp_M30_SlopeBars];
   double threshold = atr[0] * Inp_M30_SlopeATR;

   if(isBuy && slope < -threshold) return true;   // M30下行,禁多
   if(!isBuy && slope > threshold) return true;   // M30上行,禁空
   return false;
}

double GetCurrentRSI()
{
   double rsi[];
   ArraySetAsSeries(rsi, true);
   if(CopyBuffer(rsiHandle, 0, 0, 2, rsi) < 2) return 50.0;
   return rsi[1];
}

//+------------------------------------------------------------------+
//| L1开仓                                                             |
//+------------------------------------------------------------------+
void CheckEntry()
{
   if(!IsTradeTime()) return;
   if(dayLocked) return;
   if(IsLiquidityPaused()) return;
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

   double rsi = GetCurrentRSI();
   if(touchUpper && rsi < Inp_RSI_OB) return;
   if(touchLower && rsi > Inp_RSI_OS) return;

   bool isBuy = touchLower;

   // M30大势过滤(最先检查,过不去就不浪费后续计算)
   if(CheckM30TrendFilter(isBuy))
   {
      if(Inp_Debug) Print("[过滤] M30大势 ", isBuy?"做多":"做空", " 拦截");
      return;
   }

   // M1过滤组
   if(CheckOuterBandFilter(isBuy))
   {
      if(Inp_Debug) Print("[过滤] 单边推进 ", isBuy?"多":"空", " 拦截");
      return;
   }
   if(CheckSlopeFilter(isBuy))
   {
      if(Inp_Debug) Print("[过滤] M1斜率过大 ", isBuy?"多":"空", " 拦截");
      return;
   }
   if(CheckBBWidthFilter())
   {
      if(Inp_Debug) Print("[过滤] M1带宽异常 拦截");
      return;
   }

   if(GetDrawdownPct() >= Inp_MaxDD_Pct) return;
   if(GetDailyLossPct() >= Inp_DailyLoss_Pct) return;

   // 开仓
   double lots = GetLotForLayer(1);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(isBuy)
   {
      if(Inp_Debug)
         Print(">>> 做多 Cl=", DoubleToString(close1,_Digits),
               " Lower=", DoubleToString(bb_lower[1],_Digits),
               " RSI=", DoubleToString(rsi,1));

      if(trade.Buy(lots, _Symbol, ask, 0, 0, "M1多L1"))
      {
         cycleDirection = 1;
         cycleLayer = 1;
         lastAddBar = barCount;
         exportCycleId++;
         cycleOpenTime = TimeCurrent();
         cycleEntryPrice = ask;
         Print("开多L1 @", ask, " Lots=", lots);
      }
   }
   else
   {
      if(Inp_Debug)
         Print(">>> 做空 Cl=", DoubleToString(close1,_Digits),
               " Upper=", DoubleToString(bb_upper[1],_Digits),
               " RSI=", DoubleToString(rsi,1));

      if(trade.Sell(lots, _Symbol, bid, 0, 0, "M1空L1"))
      {
         cycleDirection = -1;
         cycleLayer = 1;
         lastAddBar = barCount;
         exportCycleId++;
         cycleOpenTime = TimeCurrent();
         cycleEntryPrice = bid;
         Print("开空L1 @", bid, " Lots=", lots);
      }
   }
}

//+------------------------------------------------------------------+
//| L2-L11 加仓 (距离驱动)                                              |
//+------------------------------------------------------------------+
void CheckMartingaleAdd()
{
   // 硬限额
   if(cycleLayer >= Inp_MaxLayers) return;
   if(barCount - lastAddBar < Inp_MinBars) return;

   double nextLots = GetLotForLayer(cycleLayer + 1);
   if(GetCurrentTotalLots() + nextLots > Inp_MaxTotalLots) return;

   // 必须亏损
   if(CalcTotalProfit() >= 0) return;

   // 流动性熔断
   if(IsLiquidityPaused()) return;

   // 距离触发(核心)
   double lastPrice = GetLastOpenPrice();
   if(lastPrice == 0) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentPrice = (cycleDirection == 1) ? ask : bid;
   double distance = (cycleDirection == 1) ?
                     (lastPrice - currentPrice) :
                     (currentPrice - lastPrice);

   double requiredDist = GetDistanceForLayer(cycleLayer + 1);
   if(distance < requiredDist) return;

   // 趋势保护
   bool isBuy = (cycleDirection == 1);
   if(CheckSlopeFilter(isBuy))
   {
      if(Inp_Debug) Print("[加仓拦截] M1斜率过大 L", cycleLayer + 1);
      return;
   }
   if(CheckOuterBandFilter(isBuy))
   {
      if(Inp_Debug) Print("[加仓拦截] 单边推进 L", cycleLayer + 1);
      return;
   }

   // 执行加仓
   if(cycleDirection == 1)
   {
      string comment = StringFormat("M1多L%d", cycleLayer + 1);
      if(trade.Buy(nextLots, _Symbol, ask, 0, 0, comment))
      {
         cycleLayer++;
         lastAddBar = barCount;
         Print("+加仓 多L", cycleLayer, " @", ask,
               " Δ=$", DoubleToString(distance,2),
               " Lots=", nextLots,
               " 总=", DoubleToString(GetCurrentTotalLots(), 2));
      }
   }
   else
   {
      string comment = StringFormat("M1空L%d", cycleLayer + 1);
      if(trade.Sell(nextLots, _Symbol, bid, 0, 0, comment))
      {
         cycleLayer++;
         lastAddBar = barCount;
         Print("+加仓 空L", cycleLayer, " @", bid,
               " Δ=$", DoubleToString(distance,2),
               " Lots=", nextLots,
               " 总=", DoubleToString(GetCurrentTotalLots(), 2));
      }
   }
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
//| 出场                                                               |
//+------------------------------------------------------------------+
void CheckTakeProfit()
{
   double totalProfit = CalcTotalProfit();

   if(totalProfit >= Inp_TP_Basket)
   {
      Print("<<< 篮子止盈! 盈利=", DoubleToString(totalProfit, 2), " 层数=", cycleLayer);
      ExportTradeClose("TP_BASKET");
      CloseAllPositions();
      cycleDirection = 0;
      cycleLayer = 0;
      return;
   }

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
}

//+------------------------------------------------------------------+
//| 面板                                                               |
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

   CreateLbl(panelName+"t", 10, y, "=== BB马丁 M1 v4.0 ===", clrGold); y += lh + 4;
   CreateLbl(panelName+"d", 10, y, StringFormat("%s L:%d/%d 手数:%.2f/%.2f", dir, cycleLayer, Inp_MaxLayers, totalLots, Inp_MaxTotalLots),
             cycleDirection==1?clrLime:cycleDirection==-1?clrRed:clrGray); y += lh;

   if(cycleDirection != 0)
   {
      double nextDist = (cycleLayer < Inp_MaxLayers) ? GetDistanceForLayer(cycleLayer + 1) : 0;
      double lastP = GetLastOpenPrice();
      double curP = (cycleDirection == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double curDist = (cycleDirection == 1) ? (lastP - curP) : (curP - lastP);

      CreateLbl(panelName+"p", 10, y, StringFormat("浮盈:%.2f 篮子TP:%.1f 中轨TP:%.1f", pnl, Inp_TP_Basket, Inp_TP_MidMin),
                pnl >= 0 ? clrLime : clrRed); y += lh;
      CreateLbl(panelName+"a", 10, y, StringFormat("距下层:$%.2f / $%.0f", curDist, nextDist),
                curDist >= nextDist ? clrAqua : clrGray); y += lh;
   }
   else
   {
      CreateLbl(panelName+"p", 10, y, "", clrBlack); y += lh;
      CreateLbl(panelName+"a", 10, y, "", clrBlack); y += lh;
   }

   CreateLbl(panelName+"dd", 10, y, StringFormat("DD:%.1f%% 日亏:%.1f%% 浮亏:%.1f%%", dd, dayL, fl),
             dd > 8 ? clrRed : clrWhite); y += lh;

   string statusLine = "";
   if(dayLocked) statusLine += "当日锁定 ";
   if(IsLiquidityPaused()) statusLine += "流动性暂停 ";
   if(statusLine == "") statusLine = "运行中";
   CreateLbl(panelName+"lk", 10, y, statusLine, dayLocked || IsLiquidityPaused() ? clrRed : clrGray);

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
//| 数据导出                                                            |
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

   // M30
   double bb_m30 = 0, atr_m30 = 0, slope_m30 = 0;
   if(Inp_M30_Filter)
   {
      double bm[], am[];
      ArraySetAsSeries(bm, true); ArraySetAsSeries(am, true);
      if(CopyBuffer(bbM30Handle, 0, 1, Inp_M30_SlopeBars + 1, bm) >= Inp_M30_SlopeBars + 1)
      {
         bb_m30 = bm[0];
         slope_m30 = bm[0] - bm[Inp_M30_SlopeBars];
      }
      if(CopyBuffer(atrM30Handle, 0, 1, 1, am) >= 1) atr_m30 = am[0];
   }

   double lastP = (cycleDirection != 0) ? GetLastOpenPrice() : 0;
   double curP = (cycleDirection == 1) ? ask : (cycleDirection == -1) ? bid : 0;
   double curDist = (cycleDirection == 1) ? (lastP - curP) :
                    (cycleDirection == -1) ? (curP - lastP) : 0;
   double nextDist = (cycleDirection != 0 && cycleLayer < Inp_MaxLayers) ?
                     GetDistanceForLayer(cycleLayer + 1) : 0;

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
   json += StringFormat("\"tp_basket\":%.2f,", Inp_TP_Basket);
   json += StringFormat("\"tp_mid_min\":%.2f,", Inp_TP_MidMin);
   json += StringFormat("\"current_distance\":%.2f,", curDist);
   json += StringFormat("\"next_layer_distance\":%.2f,", nextDist);
   json += StringFormat("\"bars_since_add\":%d,", barCount - lastAddBar);
   json += StringFormat("\"liquidity_paused\":%s,", IsLiquidityPaused() ? "true" : "false");
   json += StringFormat("\"cycle_id\":%d", exportCycleId);
   json += "},\n";

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
   json += StringFormat("\"m30_bb_middle\":%s,", DoubleToString(bb_m30, _Digits));
   json += StringFormat("\"m30_atr\":%.2f,", atr_m30);
   json += StringFormat("\"m30_slope\":%.2f,", slope_m30);
   json += StringFormat("\"spread\":%d,", (int)spd);
   json += StringFormat("\"bid\":%s,", DoubleToString(bid, _Digits));
   json += StringFormat("\"ask\":%s", DoubleToString(ask, _Digits));
   json += "}\n";

   json += "}";
   FileWriteString(h, json);
   FileClose(h);
}

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
