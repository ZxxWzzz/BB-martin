//+------------------------------------------------------------------+
//|                                             美分马丁_M1_VV1.mq5   |
//|                                                                    |
//|  VV1 = 复刻 Huali Wu#3 跟单账户 (Decode Global) 的 CENT22 马丁策略  |
//|                                                                    |
//|  参考: tools/美分马丁策略完整分析报告.md                             |
//|        (2026-07 分析 9244 笔真实订单, PF 1.43, MDD 9.43%)           |
//|                                                                    |
//|  核心机制:                                                          |
//|    1. M30 方向决定 (原策略用 "小艺2" 私有指标, 这里改用 BB 中轨方向) │
//|    2. 逆向 200 points ($2.0) 加仓                                    │
//|    3. 手数序列 CENT22 (校正后):                                      │
//|         L1-L12: 0.01×1,1,2,3,4,5,7,9,12,16,21,27                    │
//|         L13-L22: 前一层 × 1.3 累乘                                   │
//|    4. 平仓三通道:                                                    │
//|         ① 方向翻转 → CloseAll                                        │
//|         ② SingleTakeProfit 金额触发 → 平该方向                        │
//|         ③ TotalTakeProfit 金额触发 → CloseAll                        │
//|    5. 无止损裸单 (原策略) + 现代化风控加固:                          │
//|         - 流动性熔断 (M1 波动 > $10 暂停 5min)                       │
//|         - 黑天鹅熔断 (M1 波动 > $20 全平 + 冻结, TODO §2)            │
//|         - 最小余额门槛 (< $1000 禁止开新仓)                           │
//|         - 可选 50% 总亏强平 (默认关闭, 原策略无此)                   │
//|                                                                    |
//|  与 Huali Wu#3 差异:                                                 │
//|    - 原策略是 MT5 Signal Service 订阅, 这里是本地 EA 独立跑           │
//|    - 原策略用未知的 M30 "小艺2" 指标, 这里替换为 M30 BB 方向          │
//|    - 加了 3 层风控 (原策略仅点差保护)                                 │
//|                                                                    |
//|  MagicNumber: 2026081801                                            |
//+------------------------------------------------------------------+
#property copyright   "美分马丁 M1 VV1"
#property version     "1.00"
#property description "美分账户 CENT22 复刻马丁 (M1 · 22层 · L13+×1.3累乘)"
#property strict

#include <Trade\Trade.mqh>

//--- 手数序列 (CENT22 校正后, L1-L12; L13+ 用 LaterMult 累乘)
input group              "=== 手数配置 ==="
input double             Inp_BaseMultiplier = 1.0;                                    // 基础缩放倍数 (base=0.01×N)
input string             Inp_LotSeq_L1_L12  = "0.01,0.01,0.02,0.03,0.04,0.05,0.07,0.09,0.12,0.16,0.21,0.27";
input double             Inp_LaterMult      = 1.3;                                    // L13+ 累乘倍率
input int                Inp_MaxLayers      = 22;                                     // 最大层数
input double             Inp_MaxTotalLots   = 250.0;                                  // 总手数上限保护 (0=不限制)

//--- 加仓间距
input group              "=== 加仓间距 ==="
input double             Inp_GapDollars     = 2.0;                                    // 加仓间距(美元/点)
input double             Inp_FloatLossTrigger = 100.0;                                // 浮亏阈值(触发切换gap)
input double             Inp_GapAfterFloat  = 2.0;                                    // 浮亏后间距(可与前保持一致)

//--- 平仓 (金额触发)
input group              "=== 平仓阈值 ==="
input double             Inp_SingleTakeProfit = 6.0;                                  // 单向止盈金额(美元)
input double             Inp_TotalTakeProfit  = 6.0;                                  // 整体止盈金额(美元)
input double             Inp_StopLossAmount   = 0.0;                                  // 止损金额(0=不启用, 原策略配置)

//--- 方向指标 (M30 BB 中轨方向, 替代原策略未知的"小艺2")
input group              "=== 方向指标 (M30 BB) ==="
input int                Inp_M30_BB_Period  = 30;
input double             Inp_M30_BB_Dev     = 2.2;
input double             Inp_M30_NeutralRatio = 0.30;                                 // 中性区宽度 (0.3×半带宽)
input bool               Inp_FlipCloseAll   = true;                                   // 方向翻转全平 (原策略默认)

//--- 风控 (原策略 + TODO 加固)
input group              "=== 风控 ==="
input bool               Inp_Liquidity      = true;
input double             Inp_LiqRange       = 10.0;                                   // M1 波动 > $10 → 暂停
input int                Inp_LiqPauseSec    = 300;                                    // 暂停时长
input bool               Inp_BlackSwan      = true;                                   // 黑天鹅熔断 (单K异常波动全平+冻结)
input double             Inp_BlackSwanRange = 20.0;                                   // M1 波动 > $20 → 全平+永久冻结
input double             Inp_MinBalance     = 1000.0;                                 // 最低余额门槛
input bool               Inp_UseTotalLossFC = false;                                  // 启用 50% 总亏强平 (原策略无此)
input double             Inp_TotalLoss_Pct  = 50.0;

//--- 交易
input group              "=== 交易 ==="
input int                Inp_MagicNumber    = 2026081801;
input int                Inp_MaxSpread      = 60;                                     // 最大点差(点)
input int                Inp_SpreadBuffer   = 5;
input int                Inp_Slippage       = 30;
input int                Inp_MondaySkipHours = 2;                                     // 周一前N小时禁交易

//--- 导出
input group              "=== 数据导出 ==="
input bool               Inp_Export         = true;
input int                Inp_ExportMs       = 1000;
input bool               Inp_Debug          = true;

//--- 全局
CTrade         trade;
int            bbM30Handle;
double         peakEquity;
int            cycleDirection;               // 0=空仓, 1=多, -1=空
int            cycleLayer;
datetime       liquidityPausedUntil;
bool           emergencyFrozen;              // 黑天鹅永久冻结
double         lotArrayBase[12];             // L1-L12 基础手数(未缩放)
int            lotArrayN;
int            prevM30Direction;             // 上一tick 的 M30 方向 (用于检测翻转)
string         panelName = "MartinVV1";

// 导出用
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

void ParseLotSeq()
{
   string parts[];
   int n = StringSplit(Inp_LotSeq_L1_L12, ',', parts);
   lotArrayN = 0;
   for(int i = 0; i < n && i < 12; i++)
   {
      lotArrayBase[i] = StringToDouble(parts[i]);
      lotArrayN++;
   }
}

//+------------------------------------------------------------------+
//| 根据层号取原始手数 (未含 BaseMultiplier)                            |
//| L1-L12: 从序列取                                                    |
//| L13+ : L12 手数 × LaterMult^(layer-12)                              |
//+------------------------------------------------------------------+
double GetRawLotForLayer(int layer)
{
   if(layer <= 0) layer = 1;
   if(layer <= lotArrayN) return lotArrayBase[layer - 1];

   double lot = lotArrayBase[lotArrayN - 1];
   for(int i = lotArrayN; i < layer; i++)
      lot *= Inp_LaterMult;
   return lot;
}

//+------------------------------------------------------------------+
//| 层号 → 实际下单手数 (含 BaseMultiplier + broker 合规化)             |
//+------------------------------------------------------------------+
double GetLotForLayer(int layer)
{
   double lot = GetRawLotForLayer(layer) * Inp_BaseMultiplier;

   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0) step = 0.01;

   lot = MathFloor(lot / step) * step;
   lot = MathMax(lot, minLot);
   lot = MathMin(lot, maxLot);
   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
int OnInit()
{
   ParseLotSeq();

   bbM30Handle = iBands(_Symbol, PERIOD_M30, Inp_M30_BB_Period, 0, Inp_M30_BB_Dev, PRICE_CLOSE);
   if(bbM30Handle == INVALID_HANDLE) { Print("[VV1] M30 BB 创建失败"); return INIT_FAILED; }

   ENUM_ORDER_TYPE_FILLING ft = DetectFilling();
   trade.SetExpertMagicNumber(Inp_MagicNumber);
   trade.SetDeviationInPoints(Inp_Slippage);
   trade.SetTypeFilling(ft);

   peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   liquidityPausedUntil = 0;
   emergencyFrozen = false;
   prevM30Direction = 0;
   SyncCycleState();

   Print("=== 美分马丁 M1 VV1 ===");
   Print("手数 L1-L12: ", Inp_LotSeq_L1_L12, "  × BaseMultiplier=", Inp_BaseMultiplier);
   Print("L13+ 累乘倍率=", Inp_LaterMult, "  最大层=", Inp_MaxLayers, "  L22 手数≈", DoubleToString(GetLotForLayer(22), 2));
   Print("加仓间距=$", Inp_GapDollars, "  篮筐TP=$", Inp_TotalTakeProfit, "  单向TP=$", Inp_SingleTakeProfit);
   Print("方向指标: M30 BB(", Inp_M30_BB_Period, ",", Inp_M30_BB_Dev, ") 中性区=", Inp_M30_NeutralRatio, "×半带宽");
   Print("方向翻转全平: ", Inp_FlipCloseAll ? "是" : "否");
   Print("风控: 流动性=", Inp_Liquidity ? "开" : "关",
         " 黑天鹅=", Inp_BlackSwan ? "开" : "关",
         " 最小余额=$", Inp_MinBalance,
         " 50%强平=", Inp_UseTotalLossFC ? "开" : "关");
   Print("MagicNumber=", Inp_MagicNumber);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(bbM30Handle != INVALID_HANDLE) IndicatorRelease(bbM30Handle);
   ObjectsDeleteAll(0, panelName);
}

//+------------------------------------------------------------------+
void OnTick()
{
   UpdatePeakEquity();

   // 每 tick 检查熔断/平仓
   if(cycleDirection != 0)
   {
      if(Inp_UseTotalLossFC && CheckForceClose()) return;
      CheckDirectionFlip();
      if(cycleDirection == 0) return;
      CheckTakeProfit();
      if(cycleDirection == 0) return;
      CheckMartingaleAdd();
   }

   // 新 K 检查一次流动性/黑天鹅/入场
   if(!IsNewBar()) { UpdatePanel(); ExportState(); ExportEquitySnapshot(); return; }
   CheckLiquidity();
   CheckBlackSwan();

   if(cycleDirection == 0 && !emergencyFrozen)
      CheckEntry();

   UpdatePanel();
   ExportState();
   ExportEquitySnapshot();
}

//+------------------------------------------------------------------+
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
   if(cycleDirection == 0) peakEquity = eq;
   else if(eq > peakEquity) peakEquity = eq;
}

double GetTotalLossPct()
{
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   if(bal <= 0) return 0;
   double loss = bal - eq;
   return (loss <= 0) ? 0 : (loss / bal * 100.0);
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
   return (fl >= 0) ? 0 : (MathAbs(fl) / bal * 100.0);
}

bool CheckForceClose()
{
   double totalLoss = GetTotalLossPct();
   if(totalLoss >= Inp_TotalLoss_Pct)
   {
      string reason = StringFormat("总亏强平 %.1f%%", totalLoss);
      Print("[VV1 风控] ", reason, " 强制平仓!");
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
   if(dt.day_of_week == 1 && dt.hour < Inp_MondaySkipHours) return false;
   return true;
}

//+------------------------------------------------------------------+
//| 流动性熔断 (临时暂停 5min)                                          |
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
      Print("[VV1 流动性] M1 波动 $", DoubleToString(range,2),
            " ≥ $", Inp_LiqRange, " → 暂停 ", Inp_LiqPauseSec/60, " 分钟");
   }
}

bool IsLiquidityPaused()
{
   return Inp_Liquidity && (TimeCurrent() < liquidityPausedUntil);
}

//+------------------------------------------------------------------+
//| 黑天鹅熔断 (TODO §2: 单K极端波动 → 全平 + 永久冻结)                 |
//+------------------------------------------------------------------+
void CheckBlackSwan()
{
   if(!Inp_BlackSwan || emergencyFrozen) return;
   double high = iHigh(_Symbol, PERIOD_M1, 1);
   double low  = iLow(_Symbol, PERIOD_M1, 1);
   double range = high - low;
   if(range >= Inp_BlackSwanRange)
   {
      emergencyFrozen = true;
      string reason = StringFormat("黑天鹅熔断 M1$%.2f≥$%.2f", range, Inp_BlackSwanRange);
      Print("[VV1 ❗黑天鹅] ", reason, " → 全平 + 永久冻结 (需手动重启 EA 解锁)");
      Alert("VV1 黑天鹅熔断触发! M1 波动 $", DoubleToString(range,2), " 已全平并冻结!");
      if(cycleDirection != 0)
      {
         ExportTradeClose("BLACK_SWAN");
         CloseAllPositions();
         cycleDirection = 0;
         cycleLayer = 0;
      }
   }
}

//+------------------------------------------------------------------+
//| M30 方向判断: 中轨相对当前价的偏移 (替代原策略"小艺2")               |
//|   >0 → 多头方向  <0 → 空头方向  =0 → 中性                          |
//+------------------------------------------------------------------+
int GetM30Direction()
{
   double bb_mid[], bb_u[], bb_l[];
   ArraySetAsSeries(bb_mid, true);
   ArraySetAsSeries(bb_u, true);
   ArraySetAsSeries(bb_l, true);
   if(CopyBuffer(bbM30Handle, 0, 1, 1, bb_mid) < 1) return 0;
   if(CopyBuffer(bbM30Handle, 1, 1, 1, bb_u)   < 1) return 0;
   if(CopyBuffer(bbM30Handle, 2, 1, 1, bb_l)   < 1) return 0;

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

//+------------------------------------------------------------------+
//| 方向翻转检测 (原策略 CloseAllOrders 触发通道①)                      |
//+------------------------------------------------------------------+
void CheckDirectionFlip()
{
   if(!Inp_FlipCloseAll) return;
   int m30 = GetM30Direction();
   if(m30 == 0) return;                             // 中性区不动作
   if(cycleDirection == 1 && m30 == -1)
   {
      Print("[VV1 方向翻转] BUY→SELL 信号, CloseAll");
      ExportTradeClose("DIR_FLIP");
      CloseAllPositions();
      cycleDirection = 0;
      cycleLayer = 0;
   }
   else if(cycleDirection == -1 && m30 == 1)
   {
      Print("[VV1 方向翻转] SELL→BUY 信号, CloseAll");
      ExportTradeClose("DIR_FLIP");
      CloseAllPositions();
      cycleDirection = 0;
      cycleLayer = 0;
   }
}

//+------------------------------------------------------------------+
//| L1 开仓                                                            |
//+------------------------------------------------------------------+
void CheckEntry()
{
   string tag = TimeToString(TimeCurrent(), TIME_MINUTES) + " ";

   if(!IsTradeTime())         { if(Inp_Debug) Print("[VV1] ", tag, "× 周一开盘前"); return; }
   if(IsLiquidityPaused())    { if(Inp_Debug) Print("[VV1] ", tag, "× 流动性暂停"); return; }

   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal < Inp_MinBalance)
   {
      Print("[VV1 风控] ", tag, "× 余额 $", DoubleToString(bal,2), " < $", Inp_MinBalance, " 禁止开仓");
      Alert("VV1: 余额低于 $", Inp_MinBalance, " 禁止开仓");
      return;
   }

   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > Inp_MaxSpread + Inp_SpreadBuffer)
   {
      if(Inp_Debug) Print("[VV1] ", tag, "× 点差 ", spread, " > ", Inp_MaxSpread + Inp_SpreadBuffer);
      return;
   }

   int m30 = GetM30Direction();
   if(m30 == 0)
   {
      if(Inp_Debug) Print("[VV1] ", tag, "× M30 中性区无信号");
      return;
   }

   bool isBuy = (m30 > 0);
   double lots = GetLotForLayer(1);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(isBuy)
   {
      if(trade.Buy(lots, _Symbol, ask, 0, 0, "VV1_多L1"))
      {
         cycleDirection = 1;
         cycleLayer = 1;
         exportCycleId++;
         cycleOpenTime = TimeCurrent();
         cycleEntryPrice = ask;
         prevM30Direction = m30;
         Print("[VV1] 开多 L1 @", ask, "  Lots=", lots, "  M30 方向=+1");
      }
   }
   else
   {
      if(trade.Sell(lots, _Symbol, bid, 0, 0, "VV1_空L1"))
      {
         cycleDirection = -1;
         cycleLayer = 1;
         exportCycleId++;
         cycleOpenTime = TimeCurrent();
         cycleEntryPrice = bid;
         prevM30Direction = m30;
         Print("[VV1] 开空 L1 @", bid, "  Lots=", lots, "  M30 方向=-1");
      }
   }
}

//+------------------------------------------------------------------+
//| 加仓 (逆向 gap 触发)                                                |
//+------------------------------------------------------------------+
void CheckMartingaleAdd()
{
   if(cycleLayer >= Inp_MaxLayers) return;

   double nextLots = GetLotForLayer(cycleLayer + 1);
   if(Inp_MaxTotalLots > 0 && GetCurrentTotalLots() + nextLots > Inp_MaxTotalLots) return;

   double lastPrice = GetLastOpenPrice();
   if(lastPrice == 0) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentPrice = (cycleDirection == 1) ? ask : bid;
   double distance = (cycleDirection == 1) ?
                     (lastPrice - currentPrice) :
                     (currentPrice - lastPrice);

   double requiredGap = GetCurrentGap();
   if(distance < requiredGap) return;

   // 点差保护
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > Inp_MaxSpread + Inp_SpreadBuffer) return;

   if(cycleDirection == 1)
   {
      if(trade.Buy(nextLots, _Symbol, ask, 0, 0, StringFormat("VV1_多L%d", cycleLayer+1)))
      {
         cycleLayer++;
         Print("[VV1] +多 L", cycleLayer, " @", ask,
               "  Δ=$", DoubleToString(distance,2),
               "  Lots=", nextLots,
               "  总=", DoubleToString(GetCurrentTotalLots(),2));
      }
   }
   else
   {
      if(trade.Sell(nextLots, _Symbol, bid, 0, 0, StringFormat("VV1_空L%d", cycleLayer+1)))
      {
         cycleLayer++;
         Print("[VV1] +空 L", cycleLayer, " @", bid,
               "  Δ=$", DoubleToString(distance,2),
               "  Lots=", nextLots,
               "  总=", DoubleToString(GetCurrentTotalLots(),2));
      }
   }
}

//+------------------------------------------------------------------+
//| 当前应使用的 gap: 浮亏超阈值切换 (原策略 GetCurrentGap)             |
//+------------------------------------------------------------------+
double GetCurrentGap()
{
   double loss = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i); if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != Inp_MagicNumber) continue;
      double p = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(p < 0) loss += (-p);
   }
   return (loss >= Inp_FloatLossTrigger) ? Inp_GapAfterFloat : Inp_GapDollars;
}

//+------------------------------------------------------------------+
//| 平仓 (SingleTakeProfit / TotalTakeProfit / StopLoss)               |
//+------------------------------------------------------------------+
void CheckTakeProfit()
{
   double profitLong = 0, profitShort = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i); if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != Inp_MagicNumber) continue;
      double p = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) profitLong += p;
      else profitShort += p;
   }
   double total = profitLong + profitShort;

   if(Inp_SingleTakeProfit > 0 && cycleDirection == 1 && profitLong >= Inp_SingleTakeProfit)
   {
      Print("[VV1 SingleTP-多] 盈利 $", DoubleToString(profitLong,2), " ≥ $", Inp_SingleTakeProfit);
      ExportTradeClose("TP_SINGLE_LONG");
      CloseAllPositions();
      cycleDirection = 0; cycleLayer = 0;
      return;
   }
   if(Inp_SingleTakeProfit > 0 && cycleDirection == -1 && profitShort >= Inp_SingleTakeProfit)
   {
      Print("[VV1 SingleTP-空] 盈利 $", DoubleToString(profitShort,2), " ≥ $", Inp_SingleTakeProfit);
      ExportTradeClose("TP_SINGLE_SHORT");
      CloseAllPositions();
      cycleDirection = 0; cycleLayer = 0;
      return;
   }
   if(Inp_TotalTakeProfit > 0 && total >= Inp_TotalTakeProfit)
   {
      Print("[VV1 TotalTP] 盈利 $", DoubleToString(total,2), " ≥ $", Inp_TotalTakeProfit);
      ExportTradeClose("TP_TOTAL");
      CloseAllPositions();
      cycleDirection = 0; cycleLayer = 0;
      return;
   }
   if(Inp_StopLossAmount > 0 && total <= -Inp_StopLossAmount)
   {
      Print("[VV1 StopLoss] 亏损 $", DoubleToString(total,2), " ≤ -$", Inp_StopLossAmount);
      ExportTradeClose("SL_AMOUNT");
      CloseAllPositions();
      cycleDirection = 0; cycleLayer = 0;
   }
}

//+------------------------------------------------------------------+
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
         Print("[VV1] 平仓失败 ticket=", t, " err=", trade.ResultRetcode());
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
      cycleDirection = (pt == POSITION_TYPE_BUY) ? 1 : -1;
   }
}

//+------------------------------------------------------------------+
//| 面板                                                               |
//+------------------------------------------------------------------+
void UpdatePanel()
{
   int y = 30, lh = 18;
   double pnl = CalcTotalProfit();
   double totalLots = GetCurrentTotalLots();
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   int m30 = GetM30Direction();

   string dir = (cycleDirection == 1) ? "做多" : (cycleDirection == -1) ? "做空" : "空仓";
   color dirColor = cycleDirection == 1 ? clrLime : cycleDirection == -1 ? clrRed : clrGray;

   CreateLbl(panelName+"t", 10, y, "=== 美分马丁 M1 VV1 ===", clrGold); y += lh + 4;
   CreateLbl(panelName+"d", 10, y,
             StringFormat("%s L:%d/%d 手数:%.2f", dir, cycleLayer, Inp_MaxLayers, totalLots),
             dirColor); y += lh;

   if(cycleDirection != 0)
   {
      double lastP = GetLastOpenPrice();
      double curP = (cycleDirection == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double curDist = (cycleDirection == 1) ? (lastP - curP) : (curP - lastP);
      double gap = GetCurrentGap();
      CreateLbl(panelName+"p", 10, y,
                StringFormat("浮盈:$%.2f  单向TP:$%.1f  整TP:$%.1f", pnl, Inp_SingleTakeProfit, Inp_TotalTakeProfit),
                pnl >= 0 ? clrLime : clrRed); y += lh;
      CreateLbl(panelName+"a", 10, y,
                StringFormat("距下层:$%.2f / $%.1f", curDist, gap),
                curDist >= gap ? clrAqua : clrGray); y += lh;
   }
   else
   {
      string mstr = (m30 > 0) ? "M30 多头 (可开多)" : (m30 < 0) ? "M30 空头 (可开空)" : "M30 中性 (待信号)";
      CreateLbl(panelName+"p", 10, y, mstr, m30==0?clrGray:clrAqua); y += lh;
      CreateLbl(panelName+"a", 10, y, "", clrBlack); y += lh;
   }

   CreateLbl(panelName+"b", 10, y, StringFormat("余额:$%.2f  回撤:%.2f%%", bal, GetDrawdownPct()),
             bal < Inp_MinBalance ? clrRed : clrWhite); y += lh;

   string statusLine = "";
   if(emergencyFrozen) statusLine += "❗黑天鹅冻结 ";
   if(bal < Inp_MinBalance) statusLine += "余额低 ";
   if(IsLiquidityPaused()) statusLine += "流动性暂停 ";
   if(statusLine == "") statusLine = "运行中";
   CreateLbl(panelName+"lk", 10, y, statusLine,
             (emergencyFrozen || bal < Inp_MinBalance || IsLiquidityPaused()) ? clrRed : clrGray);

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
//| 数据导出 (与 V4 命名风格一致, 便于 dashboard 复用)                   |
//+------------------------------------------------------------------+
void ExportState()
{
   if(!Inp_Export) return;
   uint now = GetTickCount();
   if(now - lastExportTick < (uint)Inp_ExportMs) return;
   lastExportTick = now;

   int h = FileOpen("bb_martin_vv1_state.json", FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h == INVALID_HANDLE) return;

   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   double mg  = AccountInfoDouble(ACCOUNT_MARGIN);
   double fm  = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double ml  = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   long   spd = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);

   int m30_dir = GetM30Direction();
   double bb_m30_mid=0, bb_m30_u=0, bb_m30_l=0;
   double bm[], bu[], bl[];
   ArraySetAsSeries(bm, true); ArraySetAsSeries(bu, true); ArraySetAsSeries(bl, true);
   if(CopyBuffer(bbM30Handle, 0, 1, 1, bm) >= 1) bb_m30_mid = bm[0];
   if(CopyBuffer(bbM30Handle, 1, 1, 1, bu) >= 1) bb_m30_u   = bu[0];
   if(CopyBuffer(bbM30Handle, 2, 1, 1, bl) >= 1) bb_m30_l   = bl[0];

   double lastP = (cycleDirection != 0) ? GetLastOpenPrice() : 0;
   double curP  = (cycleDirection == 1) ? ask : (cycleDirection == -1) ? bid : 0;
   double curDist = (cycleDirection == 1) ? (lastP - curP) :
                    (cycleDirection == -1) ? (curP - lastP) : 0;

   string json = "{\n";
   json += "\"version\":\"VV1\",\n";
   json += StringFormat("\"timestamp\":\"%s\",\n", TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS));
   json += "\"account\":{";
   json += StringFormat("\"balance\":%.2f,\"equity\":%.2f,\"margin\":%.2f,\"free_margin\":%.2f,\"margin_level\":%.1f",
                        bal, eq, mg, fm, ml);
   json += "},\n";

   json += "\"cycle\":{";
   json += StringFormat("\"active\":%s,", cycleDirection != 0 ? "true" : "false");
   json += StringFormat("\"direction\":%d,", cycleDirection);
   json += StringFormat("\"direction_label\":\"%s\",",
                        cycleDirection==1?"BUY":cycleDirection==-1?"SELL":"IDLE");
   json += StringFormat("\"layer_count\":%d,", cycleLayer);
   json += StringFormat("\"max_layers\":%d,", Inp_MaxLayers);
   json += StringFormat("\"total_lots\":%.2f,", GetCurrentTotalLots());
   json += StringFormat("\"max_total_lots\":%.2f,", Inp_MaxTotalLots);
   json += StringFormat("\"floating_pnl\":%.2f,", CalcTotalProfit());
   json += StringFormat("\"current_distance\":%.2f,", curDist);
   json += StringFormat("\"next_layer_distance\":%.2f,", GetCurrentGap());
   json += StringFormat("\"liquidity_paused\":%s,", IsLiquidityPaused() ? "true" : "false");
   json += StringFormat("\"emergency_frozen\":%s,", emergencyFrozen ? "true" : "false");
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
      json += StringFormat("\"type\":\"%s\",",
                            PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY?"BUY":"SELL");
      json += StringFormat("\"lots\":%.2f,", PositionGetDouble(POSITION_VOLUME));
      json += StringFormat("\"open_price\":%s,", DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), _Digits));
      json += StringFormat("\"open_time\":\"%s\",",
                            TimeToString((datetime)PositionGetInteger(POSITION_TIME), TIME_DATE|TIME_SECONDS));
      json += StringFormat("\"profit\":%.2f,", PositionGetDouble(POSITION_PROFIT));
      json += StringFormat("\"swap\":%.2f", PositionGetDouble(POSITION_SWAP));
      json += "}";
   }
   json += "],\n";

   json += "\"risk\":{";
   json += StringFormat("\"total_loss_pct\":%.2f,", GetTotalLossPct());
   json += StringFormat("\"total_loss_threshold\":%.2f,", Inp_TotalLoss_Pct);
   json += StringFormat("\"total_loss_fc_enabled\":%s,", Inp_UseTotalLossFC ? "true" : "false");
   json += StringFormat("\"min_balance\":%.2f,", Inp_MinBalance);
   json += StringFormat("\"balance_below_min\":%s,", bal < Inp_MinBalance ? "true" : "false");
   json += StringFormat("\"peak_equity\":%.2f,", peakEquity);
   json += StringFormat("\"drawdown_pct\":%.2f,", GetDrawdownPct());
   json += StringFormat("\"float_loss_pct\":%.2f", GetFloatLossPct());
   json += "},\n";

   json += "\"indicators\":{";
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
   int h = FileOpen("bb_martin_vv1_trades.jsonl", FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h == INVALID_HANDLE) return;
   FileSeek(h, 0, SEEK_END);

   double profit = CalcTotalProfit();
   long duration = (long)(TimeCurrent() - cycleOpenTime);

   string line = "{";
   line += "\"version\":\"VV1\",";
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
   int h = FileOpen("bb_martin_vv1_equity.jsonl", FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h == INVALID_HANDLE) return;
   FileSeek(h, 0, SEEK_END);

   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double fl  = CalcTotalProfit();

   string line = StringFormat("{\"t\":\"%s\",\"eq\":%.2f,\"bal\":%.2f,\"fl\":%.2f,\"dir\":%d,\"L\":%d}\n",
                              TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
                              eq, bal, fl, cycleDirection, cycleLayer);
   FileWriteString(h, line);
   FileClose(h);
}
