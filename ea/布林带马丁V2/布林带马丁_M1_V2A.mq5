//+------------------------------------------------------------------+
//|                                       布林带马丁_M1_V2A.mq5       |
//|              分层TP马丁 单引擎 (XAU M1) V2A                        |
//+------------------------------------------------------------------+
//|  V2A 核心变化 (相对 V1 v5):                                        |
//|                                                                    |
//|  ① 手数序列翻倍前段, 累计 0.70手                                   |
//|     0.02,0.02,0.04,0.04,0.05,0.06,0.08,0.10,0.12,0.09,0.08         |
//|                                                                    |
//|  ② 篮子TP 分层 (取代固定 $8)                                       |
//|     反弹目标(均价→TP): 6,4,3,2.5,2,1.5,1,0.5,0.3,0.2,0.1           |
//|     对应盈利:          12,16,24,30,34,34.5,31,20.5,15.9,12.4,7.0   |
//|                                                                    |
//|  ③ 中轨TP 移除 (V2 只保留篮子TP + 强平)                             |
//|                                                                    |
//|  ④ 距离序列 与 V1 一致 4,5,6,7,8,9,10,11,12,14 (覆盖$86)            |
//|                                                                    |
//|  ⑤ MagicNumber = 2026071701 (与V1 20260622 区分)                    |
//|                                                                    |
//|  其余保持 V1 v5: BB(30,2.2), RSI(28/72), 50%强平, $1000门槛,       |
//|                流动性熔断$10/5min, M30过滤可选(默认关闭)            |
//+------------------------------------------------------------------+
#property copyright   "布林带马丁 M1 V2A"
#property version     "6.00"
#property description "分层TP马丁 单引擎 (XAU M1) V2A - 手数前段翻倍+分层反弹"
#property strict

#include <Trade\Trade.mqh>

//--- 信号 (L1入场)
input group              "=== 信号 (L1入场) ==="
input int                Inp_BB_Period    = 30;          // BB周期(M1)
input double             Inp_BB_Dev       = 2.2;         // BB偏差(M1)
input int                Inp_RSI_Period   = 14;          // RSI周期
input double             Inp_RSI_OB       = 72.0;        // RSI做空触发(>=)
input double             Inp_RSI_OS       = 28.0;        // RSI做多触发(<=)

//--- M30大势过滤 (可选,默认关闭)
input group              "=== M30大势过滤 ==="
input bool               Inp_M30_Filter   = false;       // 启用M30趋势过滤
input int                Inp_M30_BB       = 30;          // M30 BB周期
input double             Inp_M30_BBDev    = 2.2;         // M30 BB偏差
input double             Inp_M30_NeutralRatio = 0.30;    // M30震荡判定: 距中轨<半带宽×此比例视为震荡

//--- 加仓 (距离驱动, V2手数)
input group              "=== 加仓 (距离驱动) ==="
input int                Inp_MaxLayers    = 11;          // 最大层数
input string             Inp_LotSeq       = "0.02,0.02,0.04,0.04,0.05,0.06,0.08,0.10,0.12,0.09,0.08"; // V2 手数序列
input string             Inp_DistanceSeq  = "4,5,6,7,8,9,10,11,12,14"; // 距离序列(USD,L2-L11)
input double             Inp_MaxTotalLots = 0.70;        // 最大总手数

//--- 分层TP (V2 核心)
input group              "=== 分层TP (V2) ==="
input string             Inp_BounceSeq    = "6,4,3,2.5,2,1.5,1,0.5,0.3,0.2,0.1"; // 各层反弹目标(均价→TP,USD)

//--- 流动性熔断
input group              "=== 流动性熔断 ==="
input bool               Inp_Liquidity    = true;        // 启用流动性熔断
input double             Inp_LiqRange     = 10.0;        // M1波动触发(USD)
input int                Inp_LiqPauseSec  = 300;         // 暂停秒数(5分钟)

//--- 风控
input group              "=== 风控 ==="
input double             Inp_TotalLoss_Pct = 50.0;       // 总亏损强平%
input double             Inp_MinBalance    = 1000.0;     // 最小账户余额(不足则不开新单)

//--- 交易
input group              "=== 交易 ==="
input int                Inp_MagicNumber  = 2026071701;  // V2A 魔术号
input int                Inp_MaxSpread    = 80;          // 最大点差(0=不限)
input int                Inp_Slippage     = 30;          // 滑点
input int                Inp_MondaySkipHours = 2;        // 周一开盘前N小时不交易(服务器时间0-N点)

//--- 数据导出
input group              "=== 导出 ==="
input bool               Inp_Export       = true;        // 启用导出
input int                Inp_ExportMs     = 1000;        // 导出节流(ms)

//--- 调试
input bool               Inp_Debug        = true;

//--- 全局变量
CTrade         trade;
int            bbHandle, rsiHandle, atrHandle;
int            bbM30Handle;
double         peakEquity;
int            barCount;
int            cycleDirection;
int            cycleLayer;
string         panelName = "BBMartinV2A";
int            lastAddBar;
datetime       liquidityPausedUntil;

// 序列(解析后)
double         lotSeq[12];
int            lotSeqCount;
double         distSeq[12];
int            distSeqCount;
double         bounceSeq[12];
int            bounceSeqCount;

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

   n = StringSplit(Inp_LotSeq, ',', parts);
   lotSeqCount = 0;
   for(int i = 0; i < n && i < 12; i++)
   {
      lotSeq[i] = StringToDouble(parts[i]);
      lotSeqCount++;
   }

   n = StringSplit(Inp_DistanceSeq, ',', parts);
   distSeqCount = 0;
   for(int i = 0; i < n && i < 12; i++)
   {
      distSeq[i] = StringToDouble(parts[i]);
      distSeqCount++;
   }

   n = StringSplit(Inp_BounceSeq, ',', parts);
   bounceSeqCount = 0;
   for(int i = 0; i < n && i < 12; i++)
   {
      bounceSeq[i] = StringToDouble(parts[i]);
      bounceSeqCount++;
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
   int idx = layer - 2;
   if(idx < 0) return 0;
   if(idx >= distSeqCount) idx = distSeqCount - 1;
   return distSeq[idx];
}

double GetBounceForLayer(int layer)
{
   int idx = layer - 1;
   if(idx < 0) idx = 0;
   if(idx >= bounceSeqCount) idx = bounceSeqCount - 1;
   return bounceSeq[idx];
}

// 计算当前层的篮子TP盈利(USD) = 反弹 × 累计手数 × 100
double GetBasketTPForCurrent()
{
   double bounce = GetBounceForLayer(cycleLayer);
   double totalLots = GetCurrentTotalLots();
   return bounce * totalLots * 100.0;
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
   }

   ENUM_ORDER_TYPE_FILLING ft = DetectFilling();
   trade.SetExpertMagicNumber(Inp_MagicNumber);
   trade.SetDeviationInPoints(Inp_Slippage);
   trade.SetTypeFilling(ft);

   peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   barCount = 0;
   lastAddBar = 0;
   liquidityPausedUntil = 0;
   SyncCycleState();

   Print("=== 布林带马丁 M1 V2A (分层TP单引擎) ===");
   Print("L1信号: BB(", Inp_BB_Period, ",", Inp_BB_Dev, ") RSI ", Inp_RSI_OS, "/", Inp_RSI_OB);
   Print("M30过滤: ", Inp_M30_Filter ? "开启" : "关闭",
         " 中性区比例=", Inp_M30_NeutralRatio);
   Print("距离序列: ", Inp_DistanceSeq);
   Print("手数序列: ", Inp_LotSeq);
   Print("反弹序列(V2): ", Inp_BounceSeq);
   Print("MaxLayers=", Inp_MaxLayers, " MaxLots=", Inp_MaxTotalLots);
   Print("流动性: ", Inp_Liquidity ? "开启" : "关闭",
         " M1波动>$", Inp_LiqRange, " 暂停", Inp_LiqPauseSec, "秒");
   Print("总亏强平=", Inp_TotalLoss_Pct, "% 最小余额=$", Inp_MinBalance);
   Print("MagicNumber=", Inp_MagicNumber, " (V2A)");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(bbHandle != INVALID_HANDLE) IndicatorRelease(bbHandle);
   if(rsiHandle != INVALID_HANDLE) IndicatorRelease(rsiHandle);
   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
   if(bbM30Handle != INVALID_HANDLE) IndicatorRelease(bbM30Handle);
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
   CheckLiquidity();

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
      datetime localResume = TimeLocal() + Inp_LiqPauseSec;
      Print("[流动性] M1波动$", DoubleToString(range,2), " 触发熔断,暂停",
            Inp_LiqPauseSec/60, "分钟 (本地时间至 ",
            TimeToString(localResume, TIME_DATE|TIME_SECONDS), ")");
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
double GetTotalLossPct()
{
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   if(bal <= 0) return 0;
   double loss = bal - eq;
   if(loss <= 0) return 0;
   return loss / bal * 100.0;
}

double GetDrawdownPct()
{
   if(peakEquity <= 0) return 0;
   return (peakEquity - AccountInfoDouble(ACCOUNT_EQUITY)) / peakEquity * 100.0;
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
   double totalLoss = GetTotalLossPct();
   if(totalLoss >= Inp_TotalLoss_Pct)
   {
      string reason = StringFormat("总亏强平 %.1f%%", totalLoss);
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
   // 周一开盘前N小时不做(默认0-2点服务器时间)
   if(dt.day_of_week == 1 && dt.hour < Inp_MondaySkipHours) return false;
   return true;
}

//+------------------------------------------------------------------+
//| M30 大势过滤 (位置式)                                                |
//+------------------------------------------------------------------+
bool CheckM30TrendFilter(bool isBuy)
{
   if(!Inp_M30_Filter) return false;

   double bb_mid[], bb_u[], bb_l[];
   ArraySetAsSeries(bb_mid, true);
   ArraySetAsSeries(bb_u, true);
   ArraySetAsSeries(bb_l, true);
   if(CopyBuffer(bbM30Handle, 0, 1, 1, bb_mid) < 1) return false;
   if(CopyBuffer(bbM30Handle, 1, 1, 1, bb_u) < 1) return false;
   if(CopyBuffer(bbM30Handle, 2, 1, 1, bb_l) < 1) return false;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double price = (bid + ask) * 0.5;

   double middle = bb_mid[0];
   double halfBand = (bb_u[0] - bb_l[0]) * 0.5;
   if(halfBand <= 0) return false;

   double offset = price - middle;
   double neutral = halfBand * Inp_M30_NeutralRatio;

   if(MathAbs(offset) < neutral) return false;

   if(offset > 0)
   {
      if(!isBuy) return true;
   }
   else
   {
      if(isBuy) return true;
   }
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
//| L1开仓 (与V1一致 + 诊断日志)                                        |
//+------------------------------------------------------------------+
void CheckEntry()
{
   string tag = TimeToString(TimeCurrent(), TIME_MINUTES) + " ";

   if(!IsTradeTime())
   {
      Print("[诊断] ", tag, "× 周一开盘前", Inp_MondaySkipHours, "小时禁止交易");
      return;
   }

   if(IsLiquidityPaused())
   {
      long secLeft = liquidityPausedUntil - TimeCurrent();
      Print("[诊断] ", tag, "× 流动性暂停 剩余", secLeft, "秒");
      return;
   }

   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal < Inp_MinBalance)
   {
      Print("[诊断] ", tag, "× 余额$", DoubleToString(bal,2), " < 门槛$", Inp_MinBalance);
      return;
   }

   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(Inp_MaxSpread > 0 && spread > Inp_MaxSpread)
   {
      Print("[诊断] ", tag, "× 点差", spread, " > 上限", Inp_MaxSpread);
      return;
   }

   double bb_upper[], bb_middle[], bb_lower[];
   ArraySetAsSeries(bb_upper, true);
   ArraySetAsSeries(bb_middle, true);
   ArraySetAsSeries(bb_lower, true);
   if(CopyBuffer(bbHandle, 1, 0, 3, bb_upper) < 3) { Print("[诊断] ", tag, "× BB数据未就绪"); return; }
   if(CopyBuffer(bbHandle, 0, 0, 3, bb_middle) < 3) { Print("[诊断] ", tag, "× BB数据未就绪"); return; }
   if(CopyBuffer(bbHandle, 2, 0, 3, bb_lower) < 3) { Print("[诊断] ", tag, "× BB数据未就绪"); return; }

   double close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   if(close1 == 0) { Print("[诊断] ", tag, "× close1为0"); return; }

   double rsi = GetCurrentRSI();

   bool touchUpper = (close1 >= bb_upper[1]);
   bool touchLower = (close1 <= bb_lower[1]);

   string state = StringFormat("Cl=%.2f BB上=%.2f 中=%.2f 下=%.2f RSI=%.1f",
                               close1, bb_upper[1], bb_middle[1], bb_lower[1], rsi);

   if(!touchUpper && !touchLower)
   {
      Print("[诊断] ", tag, "× 未触BB轨 ", state,
            " (距上轨", DoubleToString(bb_upper[1]-close1,2),
            ",距下轨", DoubleToString(close1-bb_lower[1],2), ")");
      return;
   }

   if(touchUpper && rsi < Inp_RSI_OB)
   {
      Print("[诊断] ", tag, "× 触上轨但RSI不够空 ", state,
            " (需RSI>=", Inp_RSI_OB, ")");
      return;
   }
   if(touchLower && rsi > Inp_RSI_OS)
   {
      Print("[诊断] ", tag, "× 触下轨但RSI不够多 ", state,
            " (需RSI<=", Inp_RSI_OS, ")");
      return;
   }

   bool isBuy = touchLower;

   if(CheckM30TrendFilter(isBuy))
   {
      Print("[诊断] ", tag, "× M30大势拦截 ", isBuy?"做多":"做空", " ", state);
      return;
   }

   Print("[诊断] ", tag, "✓ 全部通过 ", isBuy?"做多":"做空", " ", state);

   double lots = GetLotForLayer(1);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(isBuy)
   {
      if(trade.Buy(lots, _Symbol, ask, 0, 0, "V2A多L1"))
      {
         cycleDirection = 1;
         cycleLayer = 1;
         lastAddBar = barCount;
         exportCycleId++;
         cycleOpenTime = TimeCurrent();
         cycleEntryPrice = ask;
         Print("开多L1 @", ask, " Lots=", lots, " 目标篮子TP=$", DoubleToString(GetBasketTPForCurrent(),2));
      }
   }
   else
   {
      if(trade.Sell(lots, _Symbol, bid, 0, 0, "V2A空L1"))
      {
         cycleDirection = -1;
         cycleLayer = 1;
         lastAddBar = barCount;
         exportCycleId++;
         cycleOpenTime = TimeCurrent();
         cycleEntryPrice = bid;
         Print("开空L1 @", bid, " Lots=", lots, " 目标篮子TP=$", DoubleToString(GetBasketTPForCurrent(),2));
      }
   }
}

//+------------------------------------------------------------------+
//| L2-L11 加仓 (纯距离驱动)                                            |
//+------------------------------------------------------------------+
void CheckMartingaleAdd()
{
   if(cycleLayer >= Inp_MaxLayers) return;

   double nextLots = GetLotForLayer(cycleLayer + 1);
   if(GetCurrentTotalLots() + nextLots > Inp_MaxTotalLots) return;

   if(CalcTotalProfit() >= 0) return;

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

   if(cycleDirection == 1)
   {
      string comment = StringFormat("V2A多L%d", cycleLayer + 1);
      if(trade.Buy(nextLots, _Symbol, ask, 0, 0, comment))
      {
         cycleLayer++;
         lastAddBar = barCount;
         Print("+加仓 多L", cycleLayer, " @", ask,
               " Δ=$", DoubleToString(distance,2),
               " Lots=", nextLots,
               " 总=", DoubleToString(GetCurrentTotalLots(), 2),
               " 新目标TP=$", DoubleToString(GetBasketTPForCurrent(),2));
      }
   }
   else
   {
      string comment = StringFormat("V2A空L%d", cycleLayer + 1);
      if(trade.Sell(nextLots, _Symbol, bid, 0, 0, comment))
      {
         cycleLayer++;
         lastAddBar = barCount;
         Print("+加仓 空L", cycleLayer, " @", bid,
               " Δ=$", DoubleToString(distance,2),
               " Lots=", nextLots,
               " 总=", DoubleToString(GetCurrentTotalLots(), 2),
               " 新目标TP=$", DoubleToString(GetBasketTPForCurrent(),2));
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
//| 出场 (V2: 仅分层篮子TP, 无中轨TP)                                   |
//+------------------------------------------------------------------+
void CheckTakeProfit()
{
   double totalProfit = CalcTotalProfit();
   double basketTP = GetBasketTPForCurrent();

   if(totalProfit >= basketTP)
   {
      Print("<<< 分层篮子TP! 盈利=$", DoubleToString(totalProfit,2),
            " 目标=$", DoubleToString(basketTP,2),
            " 层数=", cycleLayer);
      ExportTradeClose("TP_BASKET");
      CloseAllPositions();
      cycleDirection = 0;
      cycleLayer = 0;
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
   double tl = GetTotalLossPct();
   double pnl = CalcTotalProfit();
   double totalLots = GetCurrentTotalLots();
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);

   string dir = (cycleDirection == 1) ? "做多" : (cycleDirection == -1) ? "做空" : "空仓";

   CreateLbl(panelName+"t", 10, y, "=== BB马丁 M1 V2A ===", clrGold); y += lh + 4;
   CreateLbl(panelName+"d", 10, y, StringFormat("%s L:%d/%d 手数:%.2f/%.2f", dir, cycleLayer, Inp_MaxLayers, totalLots, Inp_MaxTotalLots),
             cycleDirection==1?clrLime:cycleDirection==-1?clrRed:clrGray); y += lh;

   if(cycleDirection != 0)
   {
      double nextDist = (cycleLayer < Inp_MaxLayers) ? GetDistanceForLayer(cycleLayer + 1) : 0;
      double lastP = GetLastOpenPrice();
      double curP = (cycleDirection == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double curDist = (cycleDirection == 1) ? (lastP - curP) : (curP - lastP);
      double basketTP = GetBasketTPForCurrent();

      CreateLbl(panelName+"p", 10, y, StringFormat("浮盈:%.2f 目标TP:$%.2f", pnl, basketTP),
                pnl >= 0 ? clrLime : clrRed); y += lh;
      CreateLbl(panelName+"a", 10, y, StringFormat("距下层:$%.2f / $%.0f", curDist, nextDist),
                curDist >= nextDist ? clrAqua : clrGray); y += lh;
   }
   else
   {
      CreateLbl(panelName+"p", 10, y, "", clrBlack); y += lh;
      CreateLbl(panelName+"a", 10, y, "", clrBlack); y += lh;
   }

   CreateLbl(panelName+"tl", 10, y, StringFormat("总亏:%.1f%% 强平@%.0f%% 余额:$%.0f", tl, Inp_TotalLoss_Pct, bal),
             tl > Inp_TotalLoss_Pct * 0.7 ? clrRed : clrWhite); y += lh;

   string statusLine = "";
   if(bal < Inp_MinBalance) statusLine += StringFormat("余额低($%.0f<$%.0f) ", bal, Inp_MinBalance);
   if(IsLiquidityPaused()) statusLine += "流动性暂停 ";
   if(statusLine == "") statusLine = "运行中";
   CreateLbl(panelName+"lk", 10, y, statusLine, (bal < Inp_MinBalance || IsLiquidityPaused()) ? clrRed : clrGray);

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

   int h = FileOpen("bb_martin_v2a_state.json", FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
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

   double lastP = (cycleDirection != 0) ? GetLastOpenPrice() : 0;
   double curP = (cycleDirection == 1) ? ask : (cycleDirection == -1) ? bid : 0;
   double curDist = (cycleDirection == 1) ? (lastP - curP) :
                    (cycleDirection == -1) ? (curP - lastP) : 0;
   double nextDist = (cycleDirection != 0 && cycleLayer < Inp_MaxLayers) ?
                     GetDistanceForLayer(cycleLayer + 1) : 0;
   double basketTP = (cycleDirection != 0) ? GetBasketTPForCurrent() : 0;

   string json = "{\n";
   json += StringFormat("\"version\":\"V2A\",\n");
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
   json += StringFormat("\"basket_tp\":%.2f,", basketTP);
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
   json += StringFormat("\"total_loss_pct\":%.2f,", GetTotalLossPct());
   json += StringFormat("\"total_loss_threshold\":%.2f,", Inp_TotalLoss_Pct);
   json += StringFormat("\"min_balance\":%.2f,", Inp_MinBalance);
   json += StringFormat("\"balance_below_min\":%s,", bal < Inp_MinBalance ? "true" : "false");
   json += StringFormat("\"peak_equity\":%.2f,", peakEquity);
   json += StringFormat("\"drawdown_pct\":%.2f,", GetDrawdownPct());
   json += StringFormat("\"float_loss_pct\":%.2f", GetFloatLossPct());
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

void ExportTradeClose(string closeReason)
{
   if(!Inp_Export) return;

   int h = FileOpen("bb_martin_v2a_trades.jsonl", FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h == INVALID_HANDLE) return;
   FileSeek(h, 0, SEEK_END);

   double profit = CalcTotalProfit();
   long duration = (long)(TimeCurrent() - cycleOpenTime);

   string line = "{";
   line += StringFormat("\"version\":\"V2A\",");
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

   int h = FileOpen("bb_martin_v2a_equity.jsonl", FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
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
