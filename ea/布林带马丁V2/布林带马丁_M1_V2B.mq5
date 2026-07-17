//+------------------------------------------------------------------+
//|                                       布林带马丁_M1_V2B.mq5       |
//|              分层TP马丁 双引擎 (XAU M1) V2B                        |
//+------------------------------------------------------------------+
//|  V2B = V2A + 引擎B                                                 |
//|                                                                    |
//|  引擎A (反转, 与V2A完全一致):                                       |
//|    触发: BB 外轨 + RSI 极值 (28/72)                                 |
//|    方向: 逆势 (触上轨做空, 触下轨做多)                              |
//|    手数: 0.02,0.02,0.04,0.04,0.05,0.06,0.08,0.10,0.12,0.09,0.08   |
//|    距离: 4,5,6,7,8,9,10,11,12,14                                   |
//|    反弹: 6,4,3,2.5,2,1.5,1,0.5,0.3,0.2,0.1                         |
//|                                                                    |
//|  引擎B (顺势中轨回归, 新增):                                        |
//|    触发条件(方案Z):                                                 |
//|      过去 N=20 根M1 至少1根触过 BB 外轨                             |
//|      AND 当前价接近中轨(|中轨-当前价| < 0.3×ATR)                    |
//|      AND M30方向明确 (非中性区)                                     |
//|      → 顺M30方向开仓                                                |
//|    手数: 0.01,0.01,0.02,0.02,0.03,0.03,0.04,0.05,0.06,0.05,0.04   |
//|    距离: 2,3,4,5,6,7,8,9,10,12                                     |
//|    反弹: 3,2,1.5,1.25,1,0.75,0.5,0.25,0.15,0.1,0.05                |
//|                                                                    |
//|  互斥: A/B 完全互斥, 无仓时才检查触发, 先A后B                       |
//|  MagicNumber: 2026071702                                            |
//+------------------------------------------------------------------+
#property copyright   "布林带马丁 M1 V2B"
#property version     "6.10"
#property description "分层TP马丁 双引擎 (XAU M1) V2B - A反转+B顺势"
#property strict

#include <Trade\Trade.mqh>

//--- 信号 (L1入场,引擎A)
input group              "=== 引擎A: 信号 ==="
input int                Inp_BB_Period    = 30;
input double             Inp_BB_Dev       = 2.2;
input int                Inp_RSI_Period   = 14;
input double             Inp_RSI_OB       = 72.0;
input double             Inp_RSI_OS       = 28.0;

//--- M30大势过滤 (V2B 必须启用, 引擎B依赖它判定方向)
input group              "=== M30大势过滤 (V2B必启用) ==="
input bool               Inp_M30_Filter   = false;       // 是否作用于引擎A(可关)
input int                Inp_M30_BB       = 30;
input double             Inp_M30_BBDev    = 2.2;
input double             Inp_M30_NeutralRatio = 0.30;

//--- 引擎A 加仓参数
input group              "=== 引擎A: 加仓 ==="
input int                Inp_A_MaxLayers    = 11;
input string             Inp_A_LotSeq       = "0.02,0.02,0.04,0.04,0.05,0.06,0.08,0.10,0.12,0.09,0.08";
input string             Inp_A_DistanceSeq  = "4,5,6,7,8,9,10,11,12,14";
input double             Inp_A_MaxTotalLots = 0.70;
input string             Inp_A_BounceSeq    = "6,4,3,2.5,2,1.5,1,0.5,0.3,0.2,0.1";

//--- 引擎B 参数
input group              "=== 引擎B: 顺势中轨回归 ==="
input bool               Inp_B_Enable       = true;      // 启用引擎B
input int                Inp_B_Lookback     = 20;        // 过去N根M1检查外轨触及
input double             Inp_B_NeutralRatio = 0.30;      // 中轨附近判定 (0.3×ATR)
input int                Inp_B_MaxLayers    = 11;
input string             Inp_B_LotSeq       = "0.01,0.01,0.02,0.02,0.03,0.03,0.04,0.05,0.06,0.05,0.04";
input string             Inp_B_DistanceSeq  = "2,3,4,5,6,7,8,9,10,12";
input double             Inp_B_MaxTotalLots = 0.36;
input string             Inp_B_BounceSeq    = "3,2,1.5,1.25,1,0.75,0.5,0.25,0.15,0.1,0.05";

//--- 流动性熔断
input group              "=== 流动性熔断 ==="
input bool               Inp_Liquidity    = true;
input double             Inp_LiqRange     = 10.0;
input int                Inp_LiqPauseSec  = 300;

//--- 风控
input group              "=== 风控 ==="
input double             Inp_TotalLoss_Pct = 50.0;
input double             Inp_MinBalance    = 1000.0;

//--- 交易
input group              "=== 交易 ==="
input int                Inp_MagicNumber  = 2026071702;  // V2B 魔术号
input int                Inp_MaxSpread    = 80;
input int                Inp_Slippage     = 30;
input int                Inp_StartHour    = 3;
input int                Inp_EndHour      = 22;

//--- 数据导出
input group              "=== 导出 ==="
input bool               Inp_Export       = true;
input int                Inp_ExportMs     = 1000;

input bool               Inp_Debug        = true;

//--- 全局变量
CTrade         trade;
int            bbHandle, rsiHandle, atrHandle;
int            bbM30Handle;
double         peakEquity;
int            barCount;
int            cycleDirection;     // 0=空仓, 1=多, -1=空
int            cycleLayer;
int            activeEngine;       // 0=空, 1=引擎A, 2=引擎B  (V2B新增)
string         panelName = "BBMartinV2B";
int            lastAddBar;
datetime       liquidityPausedUntil;

// 序列(解析后)
double         A_lotSeq[12], A_distSeq[12], A_bounceSeq[12];
int            A_lotN, A_distN, A_bounceN;
double         B_lotSeq[12], B_distSeq[12], B_bounceSeq[12];
int            B_lotN, B_distN, B_bounceN;

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

void ParseSeq(string s, double &arr[], int &cnt)
{
   string parts[];
   int n = StringSplit(s, ',', parts);
   cnt = 0;
   for(int i = 0; i < n && i < 12; i++)
   {
      arr[i] = StringToDouble(parts[i]);
      cnt++;
   }
}

void ParseAllSequences()
{
   ParseSeq(Inp_A_LotSeq,       A_lotSeq,    A_lotN);
   ParseSeq(Inp_A_DistanceSeq,  A_distSeq,   A_distN);
   ParseSeq(Inp_A_BounceSeq,    A_bounceSeq, A_bounceN);
   ParseSeq(Inp_B_LotSeq,       B_lotSeq,    B_lotN);
   ParseSeq(Inp_B_DistanceSeq,  B_distSeq,   B_distN);
   ParseSeq(Inp_B_BounceSeq,    B_bounceSeq, B_bounceN);
}

// 按当前 activeEngine 取对应序列
double GetLotForLayer(int layer)
{
   double arr[12]; int cnt;
   int max_lay;
   if(activeEngine == 2) {
      ArrayCopy(arr, B_lotSeq); cnt = B_lotN; max_lay = Inp_B_MaxLayers;
   } else {
      ArrayCopy(arr, A_lotSeq); cnt = A_lotN; max_lay = Inp_A_MaxLayers;
   }
   int idx = layer - 1;
   if(idx < 0) idx = 0;
   if(idx >= cnt) idx = cnt - 1;
   double lots = arr[idx];

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
   double arr[12]; int cnt;
   if(activeEngine == 2) { ArrayCopy(arr, B_distSeq); cnt = B_distN; }
   else                  { ArrayCopy(arr, A_distSeq); cnt = A_distN; }
   int idx = layer - 2;
   if(idx < 0) return 0;
   if(idx >= cnt) idx = cnt - 1;
   return arr[idx];
}

double GetBounceForLayer(int layer)
{
   double arr[12]; int cnt;
   if(activeEngine == 2) { ArrayCopy(arr, B_bounceSeq); cnt = B_bounceN; }
   else                  { ArrayCopy(arr, A_bounceSeq); cnt = A_bounceN; }
   int idx = layer - 1;
   if(idx < 0) idx = 0;
   if(idx >= cnt) idx = cnt - 1;
   return arr[idx];
}

int GetMaxLayers()
{
   return (activeEngine == 2) ? Inp_B_MaxLayers : Inp_A_MaxLayers;
}

double GetMaxTotalLots()
{
   return (activeEngine == 2) ? Inp_B_MaxTotalLots : Inp_A_MaxTotalLots;
}

double GetBasketTPForCurrent()
{
   double bounce = GetBounceForLayer(cycleLayer);
   double totalLots = GetCurrentTotalLots();
   return bounce * totalLots * 100.0;
}

int OnInit()
{
   ParseAllSequences();

   bbHandle = iBands(_Symbol, PERIOD_CURRENT, Inp_BB_Period, 0, Inp_BB_Dev, PRICE_CLOSE);
   if(bbHandle == INVALID_HANDLE) { Print("BB创建失败"); return INIT_FAILED; }

   rsiHandle = iRSI(_Symbol, PERIOD_CURRENT, Inp_RSI_Period, PRICE_CLOSE);
   if(rsiHandle == INVALID_HANDLE) { Print("RSI创建失败"); return INIT_FAILED; }

   atrHandle = iATR(_Symbol, PERIOD_CURRENT, 14);
   if(atrHandle == INVALID_HANDLE) { Print("ATR创建失败"); return INIT_FAILED; }

   // V2B 必须加载 M30 (即使 Inp_M30_Filter=false, 引擎B也要判定M30方向)
   bbM30Handle = iBands(_Symbol, PERIOD_M30, Inp_M30_BB, 0, Inp_M30_BBDev, PRICE_CLOSE);
   if(bbM30Handle == INVALID_HANDLE) { Print("M30 BB创建失败"); return INIT_FAILED; }

   ENUM_ORDER_TYPE_FILLING ft = DetectFilling();
   trade.SetExpertMagicNumber(Inp_MagicNumber);
   trade.SetDeviationInPoints(Inp_Slippage);
   trade.SetTypeFilling(ft);

   peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   barCount = 0;
   lastAddBar = 0;
   liquidityPausedUntil = 0;
   activeEngine = 0;
   SyncCycleState();

   Print("=== 布林带马丁 M1 V2B (双引擎) ===");
   Print("引擎A: BB(", Inp_BB_Period, ",", Inp_BB_Dev, ") RSI ", Inp_RSI_OS, "/", Inp_RSI_OB);
   Print("引擎A 手数:", Inp_A_LotSeq);
   Print("引擎A 距离:", Inp_A_DistanceSeq);
   Print("引擎A 反弹:", Inp_A_BounceSeq);
   Print("引擎B: ", Inp_B_Enable ? "启用" : "禁用",
         " 回中轨检测=", Inp_B_Lookback, "根", " 中性区=", Inp_B_NeutralRatio, "×ATR");
   Print("引擎B 手数:", Inp_B_LotSeq);
   Print("引擎B 距离:", Inp_B_DistanceSeq);
   Print("引擎B 反弹:", Inp_B_BounceSeq);
   Print("流动性: ", Inp_Liquidity ? "开启" : "关闭",
         " M1波动>$", Inp_LiqRange, " 暂停", Inp_LiqPauseSec, "秒");
   Print("总亏强平=", Inp_TotalLoss_Pct, "% 最小余额=$", Inp_MinBalance);
   Print("MagicNumber=", Inp_MagicNumber, " (V2B)");
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

   // A/B 互斥: 无仓时才检查, 先A后B
   if(cycleDirection == 0)
   {
      if(!CheckEntryA())        // 引擎A 未开仓
      {
         if(Inp_B_Enable)
            CheckEntryB();       // 尝试引擎B
      }
   }

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
      activeEngine = 0;
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
//| M30 大势判断: 返回 +1(偏多) / -1(偏空) / 0(中性)                    |
//+------------------------------------------------------------------+
int GetM30Direction()
{
   double bb_mid[], bb_u[], bb_l[];
   ArraySetAsSeries(bb_mid, true);
   ArraySetAsSeries(bb_u, true);
   ArraySetAsSeries(bb_l, true);
   if(CopyBuffer(bbM30Handle, 0, 1, 1, bb_mid) < 1) return 0;
   if(CopyBuffer(bbM30Handle, 1, 1, 1, bb_u) < 1) return 0;
   if(CopyBuffer(bbM30Handle, 2, 1, 1, bb_l) < 1) return 0;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double price = (bid + ask) * 0.5;

   double middle = bb_mid[0];
   double halfBand = (bb_u[0] - bb_l[0]) * 0.5;
   if(halfBand <= 0) return 0;

   double offset = price - middle;
   double neutral = halfBand * Inp_M30_NeutralRatio;

   if(MathAbs(offset) < neutral) return 0;
   return (offset > 0) ? 1 : -1;
}

// 引擎A 的M30过滤 (仅当 Inp_M30_Filter=true 时生效)
bool CheckM30TrendFilter(bool isBuy)
{
   if(!Inp_M30_Filter) return false;
   int m30_dir = GetM30Direction();
   if(m30_dir == 0) return false; // 中性区,双向允许
   if(isBuy && m30_dir < 0) return true;   // M30偏空,禁多
   if(!isBuy && m30_dir > 0) return true;  // M30偏多,禁空
   return false;
}

double GetCurrentRSI()
{
   double rsi[];
   ArraySetAsSeries(rsi, true);
   if(CopyBuffer(rsiHandle, 0, 0, 2, rsi) < 2) return 50.0;
   return rsi[1];
}

double GetCurrentATR()
{
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(atrHandle, 0, 0, 2, atr) < 2) return 1.0;
   return atr[1];
}

//+------------------------------------------------------------------+
//| 引擎A: L1开仓                                                       |
//| 返回true表示成功开仓                                                 |
//+------------------------------------------------------------------+
bool CheckEntryA()
{
   string tag = TimeToString(TimeCurrent(), TIME_MINUTES) + " ";

   if(!IsTradeTime())
   {
      Print("[诊断A] ", tag, "× 非交易时段");
      return false;
   }

   if(IsLiquidityPaused())
   {
      long secLeft = liquidityPausedUntil - TimeCurrent();
      Print("[诊断A] ", tag, "× 流动性暂停 剩余", secLeft, "秒");
      return false;
   }

   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal < Inp_MinBalance)
   {
      Print("[诊断A] ", tag, "× 余额$", DoubleToString(bal,2), " < 门槛$", Inp_MinBalance);
      return false;
   }

   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(Inp_MaxSpread > 0 && spread > Inp_MaxSpread)
   {
      Print("[诊断A] ", tag, "× 点差", spread, " > 上限");
      return false;
   }

   double bb_upper[], bb_middle[], bb_lower[];
   ArraySetAsSeries(bb_upper, true);
   ArraySetAsSeries(bb_middle, true);
   ArraySetAsSeries(bb_lower, true);
   if(CopyBuffer(bbHandle, 1, 0, 3, bb_upper) < 3) return false;
   if(CopyBuffer(bbHandle, 0, 0, 3, bb_middle) < 3) return false;
   if(CopyBuffer(bbHandle, 2, 0, 3, bb_lower) < 3) return false;

   double close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   if(close1 == 0) return false;

   double rsi = GetCurrentRSI();
   bool touchUpper = (close1 >= bb_upper[1]);
   bool touchLower = (close1 <= bb_lower[1]);

   string state = StringFormat("Cl=%.2f BB上=%.2f 中=%.2f 下=%.2f RSI=%.1f",
                               close1, bb_upper[1], bb_middle[1], bb_lower[1], rsi);

   if(!touchUpper && !touchLower)
   {
      Print("[诊断A] ", tag, "× 未触BB轨 ", state);
      return false;
   }

   if(touchUpper && rsi < Inp_RSI_OB)
   {
      Print("[诊断A] ", tag, "× 触上轨但RSI<", Inp_RSI_OB, " ", state);
      return false;
   }
   if(touchLower && rsi > Inp_RSI_OS)
   {
      Print("[诊断A] ", tag, "× 触下轨但RSI>", Inp_RSI_OS, " ", state);
      return false;
   }

   bool isBuy = touchLower;

   if(CheckM30TrendFilter(isBuy))
   {
      Print("[诊断A] ", tag, "× M30大势拦截 ", isBuy?"做多":"做空");
      return false;
   }

   Print("[诊断A] ", tag, "✓ 通过 ", isBuy?"做多":"做空", " ", state);

   activeEngine = 1;  // 标记引擎A
   double lots = GetLotForLayer(1);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(isBuy)
   {
      if(trade.Buy(lots, _Symbol, ask, 0, 0, "V2B_A多L1"))
      {
         cycleDirection = 1;
         cycleLayer = 1;
         lastAddBar = barCount;
         exportCycleId++;
         cycleOpenTime = TimeCurrent();
         cycleEntryPrice = ask;
         Print("[引擎A] 开多L1 @", ask, " Lots=", lots, " 目标TP=$", DoubleToString(GetBasketTPForCurrent(),2));
         return true;
      }
   }
   else
   {
      if(trade.Sell(lots, _Symbol, bid, 0, 0, "V2B_A空L1"))
      {
         cycleDirection = -1;
         cycleLayer = 1;
         lastAddBar = barCount;
         exportCycleId++;
         cycleOpenTime = TimeCurrent();
         cycleEntryPrice = bid;
         Print("[引擎A] 开空L1 @", bid, " Lots=", lots, " 目标TP=$", DoubleToString(GetBasketTPForCurrent(),2));
         return true;
      }
   }
   activeEngine = 0; // 未成功回滚
   return false;
}

//+------------------------------------------------------------------+
//| 引擎B: 顺势中轨回归入场                                              |
//| 触发条件(方案Z):                                                    |
//|   过去N根M1至少1根触过外轨 (证明有过一次极端偏离)                    |
//|   AND 当前价接近中轨 (|中轨-当前价| < NeutralRatio × ATR)            |
//|   AND M30方向明确, 顺M30方向入场                                    |
//+------------------------------------------------------------------+
bool CheckEntryB()
{
   string tag = TimeToString(TimeCurrent(), TIME_MINUTES) + " ";

   if(!IsTradeTime()) return false;
   if(IsLiquidityPaused()) return false;

   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal < Inp_MinBalance) return false;

   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(Inp_MaxSpread > 0 && spread > Inp_MaxSpread) return false;

   // 1. M30方向
   int m30_dir = GetM30Direction();
   if(m30_dir == 0)
   {
      Print("[诊断B] ", tag, "× M30中性区");
      return false;
   }

   // 2. 当前价与中轨距离
   double bb_middle[];
   ArraySetAsSeries(bb_middle, true);
   if(CopyBuffer(bbHandle, 0, 0, 1, bb_middle) < 1) return false;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double midPrice = (bid + ask) * 0.5;
   double middle = bb_middle[0];
   double atr = GetCurrentATR();
   double threshold = atr * Inp_B_NeutralRatio;

   double distToMid = MathAbs(midPrice - middle);
   if(distToMid >= threshold)
   {
      // 只在有信号触发时输出诊断
      return false;
   }

   // 3. 过去N根K线至少1根触过外轨 (方向相关)
   //   做多方向: 需要过去N根有过 触下轨(证明是"下轨→中轨"路径)
   //   做空方向: 需要过去N根有过 触上轨(证明是"上轨→中轨"路径)
   double bb_u_hist[], bb_l_hist[];
   ArraySetAsSeries(bb_u_hist, true);
   ArraySetAsSeries(bb_l_hist, true);
   if(CopyBuffer(bbHandle, 1, 1, Inp_B_Lookback, bb_u_hist) < Inp_B_Lookback) return false;
   if(CopyBuffer(bbHandle, 2, 1, Inp_B_Lookback, bb_l_hist) < Inp_B_Lookback) return false;

   bool isBuy = (m30_dir > 0);
   int touchCount = 0;
   for(int i = 0; i < Inp_B_Lookback; i++)
   {
      double cl = iClose(_Symbol, PERIOD_CURRENT, i + 1);
      if(isBuy && cl <= bb_l_hist[i]) touchCount++;
      if(!isBuy && cl >= bb_u_hist[i]) touchCount++;
   }

   if(touchCount == 0)
   {
      Print("[诊断B] ", tag, "× 过去", Inp_B_Lookback, "根未触",
            isBuy ? "下" : "上", "轨,不属于回归路径");
      return false;
   }

   // 4. 位置验证: 当前价必须在中轨相对M30顺势的一侧接近中轨
   //   做多(M30向上): 当前价应该 <= 中轨(从下方接近)
   //   做空(M30向下): 当前价应该 >= 中轨(从上方接近)
   if(isBuy && midPrice > middle)
   {
      Print("[诊断B] ", tag, "× M30向上但价已在中轨之上,失去入场时机");
      return false;
   }
   if(!isBuy && midPrice < middle)
   {
      Print("[诊断B] ", tag, "× M30向下但价已在中轨之下,失去入场时机");
      return false;
   }

   Print("[诊断B] ", tag, "✓ 通过 ",
         isBuy ? "顺M30做多" : "顺M30做空",
         " 距中轨=", DoubleToString(distToMid,2),
         " 阈值=", DoubleToString(threshold,2),
         " 外轨触及=", touchCount, "次");

   activeEngine = 2;  // 标记引擎B
   double lots = GetLotForLayer(1);

   if(isBuy)
   {
      if(trade.Buy(lots, _Symbol, ask, 0, 0, "V2B_B多L1"))
      {
         cycleDirection = 1;
         cycleLayer = 1;
         lastAddBar = barCount;
         exportCycleId++;
         cycleOpenTime = TimeCurrent();
         cycleEntryPrice = ask;
         Print("[引擎B] 开多L1 @", ask, " Lots=", lots, " 目标TP=$", DoubleToString(GetBasketTPForCurrent(),2));
         return true;
      }
   }
   else
   {
      if(trade.Sell(lots, _Symbol, bid, 0, 0, "V2B_B空L1"))
      {
         cycleDirection = -1;
         cycleLayer = 1;
         lastAddBar = barCount;
         exportCycleId++;
         cycleOpenTime = TimeCurrent();
         cycleEntryPrice = bid;
         Print("[引擎B] 开空L1 @", bid, " Lots=", lots, " 目标TP=$", DoubleToString(GetBasketTPForCurrent(),2));
         return true;
      }
   }
   activeEngine = 0;
   return false;
}

//+------------------------------------------------------------------+
//| 加仓 (根据 activeEngine 使用不同的手数/距离序列)                     |
//+------------------------------------------------------------------+
void CheckMartingaleAdd()
{
   int maxLayers = GetMaxLayers();
   double maxTotalLots = GetMaxTotalLots();

   if(cycleLayer >= maxLayers) return;

   double nextLots = GetLotForLayer(cycleLayer + 1);
   if(GetCurrentTotalLots() + nextLots > maxTotalLots) return;

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

   string engineTag = (activeEngine == 2) ? "V2B_B" : "V2B_A";

   if(cycleDirection == 1)
   {
      string comment = StringFormat("%s多L%d", engineTag, cycleLayer + 1);
      if(trade.Buy(nextLots, _Symbol, ask, 0, 0, comment))
      {
         cycleLayer++;
         lastAddBar = barCount;
         Print("[引擎", activeEngine, "] +多L", cycleLayer, " @", ask,
               " Δ=$", DoubleToString(distance,2),
               " Lots=", nextLots,
               " 总=", DoubleToString(GetCurrentTotalLots(), 2),
               " 新TP=$", DoubleToString(GetBasketTPForCurrent(),2));
      }
   }
   else
   {
      string comment = StringFormat("%s空L%d", engineTag, cycleLayer + 1);
      if(trade.Sell(nextLots, _Symbol, bid, 0, 0, comment))
      {
         cycleLayer++;
         lastAddBar = barCount;
         Print("[引擎", activeEngine, "] +空L", cycleLayer, " @", bid,
               " Δ=$", DoubleToString(distance,2),
               " Lots=", nextLots,
               " 总=", DoubleToString(GetCurrentTotalLots(), 2),
               " 新TP=$", DoubleToString(GetBasketTPForCurrent(),2));
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
//| 出场 (分层篮子TP)                                                   |
//+------------------------------------------------------------------+
void CheckTakeProfit()
{
   double totalProfit = CalcTotalProfit();
   double basketTP = GetBasketTPForCurrent();

   if(totalProfit >= basketTP)
   {
      Print("<<< [引擎", activeEngine, "] 分层TP! 盈利=$", DoubleToString(totalProfit,2),
            " 目标=$", DoubleToString(basketTP,2), " 层数=", cycleLayer);
      ExportTradeClose("TP_BASKET");
      CloseAllPositions();
      cycleDirection = 0;
      cycleLayer = 0;
      activeEngine = 0;
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
   if(cycleLayer == 0) { cycleDirection = 0; activeEngine = 0; }
   else if(activeEngine == 0) activeEngine = 1;  // 重启时若有仓位,默认视为引擎A
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
   string eng = (activeEngine == 1) ? "[A反转]" : (activeEngine == 2) ? "[B顺势]" : "";

   CreateLbl(panelName+"t", 10, y, "=== BB马丁 M1 V2B ===", clrGold); y += lh + 4;
   CreateLbl(panelName+"d", 10, y, StringFormat("%s%s L:%d/%d 手数:%.2f/%.2f", dir, eng, cycleLayer, GetMaxLayers(), totalLots, GetMaxTotalLots()),
             cycleDirection==1?clrLime:cycleDirection==-1?clrRed:clrGray); y += lh;

   if(cycleDirection != 0)
   {
      double nextDist = (cycleLayer < GetMaxLayers()) ? GetDistanceForLayer(cycleLayer + 1) : 0;
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
      // 显示M30方向
      int m30 = GetM30Direction();
      string m30s = (m30 > 0) ? "上半区 (B可做多)" : (m30 < 0) ? "下半区 (B可做空)" : "中性区 (B禁触发)";
      CreateLbl(panelName+"p", 10, y, "M30: " + m30s, m30==0?clrGray:clrAqua); y += lh;
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

   int h = FileOpen("bb_martin_v2b_state.json", FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
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

   double atrVal = GetCurrentATR();

   int m30_dir = GetM30Direction();
   double bb_m30_mid = 0, bb_m30_u = 0, bb_m30_l = 0;
   double bm[], bu[], bl[];
   ArraySetAsSeries(bm, true); ArraySetAsSeries(bu, true); ArraySetAsSeries(bl, true);
   if(CopyBuffer(bbM30Handle, 0, 1, 1, bm) >= 1) bb_m30_mid = bm[0];
   if(CopyBuffer(bbM30Handle, 1, 1, 1, bu) >= 1) bb_m30_u = bu[0];
   if(CopyBuffer(bbM30Handle, 2, 1, 1, bl) >= 1) bb_m30_l = bl[0];

   double lastP = (cycleDirection != 0) ? GetLastOpenPrice() : 0;
   double curP = (cycleDirection == 1) ? ask : (cycleDirection == -1) ? bid : 0;
   double curDist = (cycleDirection == 1) ? (lastP - curP) :
                    (cycleDirection == -1) ? (curP - lastP) : 0;
   double nextDist = (cycleDirection != 0 && cycleLayer < GetMaxLayers()) ?
                     GetDistanceForLayer(cycleLayer + 1) : 0;
   double basketTP = (cycleDirection != 0) ? GetBasketTPForCurrent() : 0;

   string json = "{\n";
   json += StringFormat("\"version\":\"V2B\",\n");
   json += StringFormat("\"timestamp\":\"%s\",\n", TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS));
   json += "\"account\":{";
   json += StringFormat("\"balance\":%.2f,\"equity\":%.2f,\"margin\":%.2f,\"free_margin\":%.2f,\"margin_level\":%.1f", bal, eq, mg, fm, ml);
   json += "},\n";

   json += "\"cycle\":{";
   json += StringFormat("\"active\":%s,", cycleDirection != 0 ? "true" : "false");
   json += StringFormat("\"direction\":%d,", cycleDirection);
   json += StringFormat("\"direction_label\":\"%s\",", cycleDirection==1?"BUY":cycleDirection==-1?"SELL":"IDLE");
   json += StringFormat("\"engine\":%d,", activeEngine);
   json += StringFormat("\"engine_label\":\"%s\",", activeEngine==1?"A_REVERSAL":activeEngine==2?"B_TREND":"IDLE");
   json += StringFormat("\"layer_count\":%d,", cycleLayer);
   json += StringFormat("\"max_layers\":%d,", GetMaxLayers());
   json += StringFormat("\"total_lots\":%.2f,", GetCurrentTotalLots());
   json += StringFormat("\"max_total_lots\":%.2f,", GetMaxTotalLots());
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
   json += StringFormat("\"m30_bb_middle\":%s,", DoubleToString(bb_m30_mid, _Digits));
   json += StringFormat("\"m30_bb_upper\":%s,", DoubleToString(bb_m30_u, _Digits));
   json += StringFormat("\"m30_bb_lower\":%s,", DoubleToString(bb_m30_l, _Digits));
   json += StringFormat("\"m30_direction\":%d,", m30_dir);
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

   int h = FileOpen("bb_martin_v2b_trades.jsonl", FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h == INVALID_HANDLE) return;
   FileSeek(h, 0, SEEK_END);

   double profit = CalcTotalProfit();
   long duration = (long)(TimeCurrent() - cycleOpenTime);

   string line = "{";
   line += StringFormat("\"version\":\"V2B\",");
   line += StringFormat("\"cycle_id\":%d,", exportCycleId);
   line += StringFormat("\"engine\":%d,", activeEngine);
   line += StringFormat("\"engine_label\":\"%s\",", activeEngine==1?"A_REVERSAL":activeEngine==2?"B_TREND":"UNKNOWN");
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

   int h = FileOpen("bb_martin_v2b_equity.jsonl", FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h == INVALID_HANDLE) return;
   FileSeek(h, 0, SEEK_END);

   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double fl  = CalcTotalProfit();

   string line = StringFormat("{\"t\":\"%s\",\"eq\":%.2f,\"bal\":%.2f,\"fl\":%.2f,\"engine\":%d}\n",
                              TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), eq, bal, fl, activeEngine);
   FileWriteString(h, line);
   FileClose(h);
}
