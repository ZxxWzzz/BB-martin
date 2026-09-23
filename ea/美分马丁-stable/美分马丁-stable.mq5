//+------------------------------------------------------------------+
//|                                              美分马丁-stable.mq5 |
//|                                                      Version 1.6 |
//|                                                                  |
//|  v1.6 变更 (vs v1.5): 最大层数强平 + M1 图表校验                    |
//|    * 新参数 Inp_MaxLayerClose (默认 true)                          |
//|      - 达到 MaxOrderCount 那一刻立即 CloseAllByDir + 暂停开仓      |
//|      - 主动认亏 (~$101, L22 触发瞬间) 换掉被动爆仓 (~$290)          |
//|      - 09-16 爆仓根因就是"L22 后价格继续走 $11 stop-out 强平"      |
//|    * OnInit 首步校验 Period()=PERIOD_M1, 非 M1 直接 INIT_FAILED    |
//|      理由: 加仓 tick 敏感, 且防止误挂多图表造成同 magic 双实例冲突 |
//|                                                                  |
//|  v1.5 变更 (vs v1.4): 黑天鹅按层数分档 + 30 分钟暂停                |
//|    * 新参数 Inp_BlackSwanLayerCap (默认 16)                        |
//|      - 触发时 max(buyCnt,sellCnt) < 16: 全平止损 + 暂停 30 分钟    |
//|      - 触发时 max(buyCnt,sellCnt) >= 16: 只冻结 + 手机推送告警     |
//|    * 新参数 Inp_BlackSwanPauseMin (默认 30) 全平后禁开新仓时长      |
//|    * 移除 Inp_MaxCloseLossPct (用途被 LayerCap 替代)               |
//|    * 全平分支后 emergencyFrozen 保持 false, 让暂停期过后自动恢复    |
//|    * 深套分支通过 SendNotification 推送手机(需先配 MetaQuotes ID)  |
//|    * OnTick 加暂停期检查 + 面板 HUD 显示暂停剩余时间               |
//|                                                                  |
//|  v1.4 变更 (vs v1.3): **加仓触发逻辑改动** (对齐真机数据)          |
//|    * 加仓判断: '累计手数加权均价浮亏' → '最新一单浮亏'             |
//|      - 原策略每层间距递减 ($2→$1→$0.86→...→$0.46)                 |
//|      - 新策略每层间距恒定 = LossPriceGap 参数值                    |
//|      - 与真机 DetailedStatement.htm 反推 (每层 ~$2.5) 一致        |
//|    * 新增 GetLastOpenPriceByDir() 取该方向最新一单开仓价           |
//|    * LossPriceGap 默认值 = 2.5 (对齐实盘/真机反推每层~$2.5)        |
//|    * 平仓逻辑保持不变 (仍用累计均价浮盈 >= AvgProfitTarget)        |
//|                                                                  |
//|  v1.3 变更 (vs v1.2):                                             |
//|    * [C1] fixedLotArr 分界由硬编码 12 改为 ArraySize()             |
//|    * [C3] LossPriceGap/AvgProfitTarget 注释修正:单位=USD/oz       |
//|           新增 Inp_MinUsdProfit 美元浮盈兜底 (默认0=不启用)         |
//|    * [H1] MA 信号取已收盘 bar[1], 避免未收 bar[0] 每 tick 抖动     |
//|    * [H2] CalendarValueHistory 缓存 60s, 避免每 tick 拉外部数据    |
//|    * [M2] 开单失败区分致命错误 (NO_MONEY/LIMIT_VOLUME 等直接冻结)  |
//|                                                                  |
//|  v1.2 变更 (vs v1.1): 手数序列对齐真机 CENT22                     |
//|    * MaxOrderCount 12 → 22 (真机数据里曾到 L23, 22 层留一层缓冲)  |
//|    * fixedLotArr 扩到 12 层, 直接用真机反推的手数序列              |
//|      [0.01, 0.01, 0.02, 0.03, 0.04, 0.05, 0.07, 0.09,             |
//|       0.12, 0.16, 0.21, 0.27]                                     |
//|    * L13+ 仍用 MultiAfter4=1.3 累乘                                |
//|    * 触发查表分界: sellCnt/buyCnt < 4 → < 12                       |
//|    * 开单失败冷却 (默认 2 秒, 避免 auto trading disabled 刷屏)     |
//|                                                                  |
//|  v1.1 (2026-09-02): 黑天鹅+点差+新闻+面板 HUD+完整日志            |
//|  v1.0 (2026-09-01): 基于 MT4 参照策略迁移到 MT5, MultiAfter4=1.3  |
//|                                                                  |
//|  策略骨架:                                                        |
//|    - M15 MA20/MA50 双均线方向信号                                 |
//|    - 前 4 单固定 [0.01, 0.02, 0.03, 0.04]                        |
//|    - 第 5 单起 = 上一单 × MultiAfter4 (默认 1.3)                  |
//|    - 最新一单浮亏 >= $2.5/oz 触发加仓                             |
//|    - 平均浮盈 >= $0.6/oz 平该方向全部                             |
//|    - 每方向最多 12 单                                             |
//|    - 允许多空共存 (需 Hedging 账户)                               |
//+------------------------------------------------------------------+
#property copyright "美分马丁-stable"
#property version   "1.60"
#property description "美分马丁-stable v1.6 (L22 强平 + M1 校验; 黑天鹅按层分档保留)"
#property strict

#include <Trade\Trade.mqh>

//============ 策略参数 ============
input group "=== 策略核心 ==="
input ENUM_TIMEFRAMES SignalTimeFrame = PERIOD_M15;    // 判断方向周期
input double LossPriceGap     = 2.5;                   // 加仓阈值: 最新一单浮亏价差(USD/oz), 非美元浮亏
input double AvgProfitTarget  = 0.6;                   // 平仓阈值: 手数加权平均价差(USD/oz), 非美元浮盈
input double Inp_MinUsdProfit = 0.0;                   // 平仓兜底: 净美元浮盈 ≥ 该值才平, 0=不启用
input int    MaxOrderCount    = 22;                    // 每方向最大层数 (v1.2: 12→22 对齐真机)
input bool   Inp_MaxLayerClose= true;                  // v1.6: 达到 MaxOrderCount 立即 CloseAll + 暂停 (主动认亏防爆仓)
input double MultiAfter4      = 1.3;                   // L13+ 加仓倍数 (前 12 层用 fixedLotArr 查表)
input int    MagicNum         = 8866;
input int    Slippage         = 10;                    // 允许滑点(points)

//============ 保护参数 ============
input group "=== 黑天鹅熔断 ==="
input bool   Inp_BlackSwan          = true;            // 启用黑天鹅熔断
input double Inp_BlackSwanRange     = 20.0;            // M1 波动>=$X 触发
input int    Inp_BlackSwanLayerCap  = 16;              // 触发时该方向层数 >= X → 只冻结告警, < X → 全平+暂停
input int    Inp_BlackSwanPauseMin  = 30;              // 全平后禁开新仓 X 分钟

input group "=== 点差保护 ==="
input int    Inp_MaxSpread      = 60;                  // 点差>X 禁开新仓
input int    Inp_SpreadBuffer   = 5;

input group "=== 新闻过滤 (FOMC/CPI/PPI/NFP) ==="
input bool   Inp_NewsFilter     = true;
input int    Inp_NewsMinBefore  = 30;                  // 事件前 X 分钟
input int    Inp_NewsMinAfter   = 30;                  // 事件后 X 分钟

input group "=== 面板 & 日志 ==="
input bool   Inp_ShowPanel      = true;
input bool   Inp_VerboseLog     = true;
input int    Inp_OpenFailCoolSec = 2;                  // 开单失败后冷却 X 秒 (避免刷屏)

//---- 全局
CTrade   trade;
int      maFastHandle = INVALID_HANDLE;
int      maSlowHandle = INVALID_HANDLE;
bool     emergencyFrozen = false;
bool     lastNewsBlocked = false;
bool     lastSpreadHi    = false;
datetime lastOpenFailTs  = 0;
datetime pauseOpenUntil  = 0;                          // v1.5: 黑天鹅浅套后禁开新仓的截止时间
bool     lastPauseNoted  = false;                      // v1.5: 暂停日志节流
string   panelPfx = "StableP_";

// H2: CalendarValueHistory 结果缓存 60s (避免每 tick 拉外部日历)
datetime g_newsCacheTs        = 0;
bool     g_newsCacheBlock     = false;
string   g_newsCacheName      = "";
datetime g_newsCacheEventTime = 0;

// C3: 价差达标但 USD 未达标, 等待中 (用于日志节流, 状态变化才 Print)
bool     g_buyWaitUsd  = false;
bool     g_sellWaitUsd = false;

// v1.2: L1-L12 直接用真机 CENT22 反推的手数序列 (L2 复用 L1)
double fixedLotArr[] = {0.01, 0.01, 0.02, 0.03, 0.04, 0.05, 0.07, 0.09, 0.12, 0.16, 0.21, 0.27};

struct PosStat
{
   int    buyCnt;
   int    sellCnt;
   double buyAvgProfitPrice;
   double sellAvgProfitPrice;
   double buyTotalLot;
   double sellTotalLot;
};

//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING DetectFilling()
{
   long fm = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fm & SYMBOL_FILLING_FOK) != 0) return ORDER_FILLING_FOK;
   if((fm & SYMBOL_FILLING_IOC) != 0) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

//+------------------------------------------------------------------+
int OnInit()
{
   // 图表周期保险 (必须 M1, 防止误挂多图表引起同 magic 双实例)
   if(Period() != PERIOD_M1)
   {
      Print("[stable] [X] 当前图表周期=", EnumToString((ENUM_TIMEFRAMES)Period()),
            ", EA 只允许挂在 M1 图表, EA 停止");
      Alert("[stable] EA 必须挂在 M1 图表, 当前周期不对, EA 已停止");
      return INIT_FAILED;
   }

   // Hedging 校验 (关键: Netting 账户策略跑不了)
   long marginMode = AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(marginMode != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Print("[stable] [X] 账户不是 Hedging 模式 (当前=", marginMode,
            "), 多空共存无法工作, EA 停止");
      return INIT_FAILED;
   }

   maFastHandle = iMA(_Symbol, SignalTimeFrame, 20, 0, MODE_SMA, PRICE_CLOSE);
   maSlowHandle = iMA(_Symbol, SignalTimeFrame, 50, 0, MODE_SMA, PRICE_CLOSE);
   if(maFastHandle == INVALID_HANDLE || maSlowHandle == INVALID_HANDLE)
   {
      Print("[stable] [X] MA 句柄创建失败");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(MagicNum);
   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFilling(DetectFilling());

   emergencyFrozen = false;
   lastNewsBlocked = false;
   lastSpreadHi    = false;
   pauseOpenUntil  = 0;
   lastPauseNoted  = false;
   lastOpenFailTs  = 0;

   Print("=============================================");
   Print("=== 美分马丁-stable v1.6 启动 ===");
   Print("[保护] 图表周期校验: 只允许 M1 (当前=", EnumToString((ENUM_TIMEFRAMES)Period()), " [OK])");
   Print("[保护] 最大层数强平=", Inp_MaxLayerClose ? "开" : "关",
         " (达 L", MaxOrderCount, " 立即 CloseAll + 暂停 ", Inp_BlackSwanPauseMin, " min)");
   Print("信号周期=", EnumToString(SignalTimeFrame),
         " (取已收 bar[1])",
         "  加仓触发=最新单浮亏≥$", LossPriceGap, "/oz (层间距恒定)",
         "  平仓价差=$", AvgProfitTarget, "/oz",
         "  USD 兜底=", (Inp_MinUsdProfit>0 ? DoubleToString(Inp_MinUsdProfit,2) : "关"));
   Print("L1-L", ArraySize(fixedLotArr),
         " 查表: [0.01,0.01,0.02,0.03,0.04,0.05,0.07,0.09,0.12,0.16,0.21,0.27]");
   Print("L", ArraySize(fixedLotArr)+1, "+ 倍率=", MultiAfter4,
         "  最大层数=", MaxOrderCount,
         "  开单失败冷却=", Inp_OpenFailCoolSec, "秒");
   Print("[保护] 黑天鹅=", Inp_BlackSwan ? "开" : "关",
         " (M1>$", Inp_BlackSwanRange,
         ", 层<", Inp_BlackSwanLayerCap, " 全平+暂停", Inp_BlackSwanPauseMin,
         "min, 层≥", Inp_BlackSwanLayerCap, " 冻结告警)");
   Print("[保护] 点差过滤: >", Inp_MaxSpread + Inp_SpreadBuffer, " pt 禁开");
   Print("[保护] 新闻过滤=", Inp_NewsFilter ? "开" : "关",
         "  前", Inp_NewsMinBefore, "min / 后", Inp_NewsMinAfter, "min");
   Print("Magic=", MagicNum, "  账户模式=Hedging [OK]");

   // 首次尝试读日历,验证 Calendar API 是否可用
   if(Inp_NewsFilter)
   {
      MqlCalendarValue tmp[];
      int n = CalendarValueHistory(tmp, TimeCurrent(), TimeCurrent() + 7*86400, "US");
      if(n < 0)
         Print("[stable] [!] Calendar API 读取失败 err=", GetLastError(),
               ", 新闻过滤将不生效 (可能是 broker 服务器不共享日历)");
      else
         Print("[stable] Calendar API OK, 未来 7 天美国事件数=", n);
   }
   Print("=============================================");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(maFastHandle != INVALID_HANDLE) IndicatorRelease(maFastHandle);
   if(maSlowHandle != INVALID_HANDLE) IndicatorRelease(maSlowHandle);
   ObjectsDeleteAll(0, panelPfx);
   Print("[stable] EA 停止, reason=", reason);
}

//+------------------------------------------------------------------+
int GetSignal()
{
   // H1: 取已收 M15 bar (shift=1), 避免使用未收 bar[0] 的 MA 每 tick 抖动
   double fast[1], slow[1];
   if(CopyBuffer(maFastHandle, 0, 1, 1, fast) < 1) return 0;
   if(CopyBuffer(maSlowHandle, 0, 1, 1, slow) < 1) return 0;
   if(fast[0] > slow[0]) return 1;
   if(fast[0] < slow[0]) return -1;
   return 0;
}

//+------------------------------------------------------------------+
bool GetPositionStat(PosStat &stat)
{
   stat.buyCnt = 0; stat.sellCnt = 0;
   stat.buyAvgProfitPrice = 0; stat.sellAvgProfitPrice = 0;
   stat.buyTotalLot = 0; stat.sellTotalLot = 0;

   double sumBuyLot = 0, sumSellLot = 0;
   double sumBuyProMulLot = 0, sumSellProMulLot = 0;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNum) continue;

      double lot       = PositionGetDouble(POSITION_VOLUME);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      long   ptype     = PositionGetInteger(POSITION_TYPE);
      double proPrice;

      if(ptype == POSITION_TYPE_BUY)
      {
         stat.buyCnt++;
         proPrice = bid - openPrice;
         sumBuyLot       += lot;
         sumBuyProMulLot += proPrice * lot;
      }
      else if(ptype == POSITION_TYPE_SELL)
      {
         stat.sellCnt++;
         proPrice = openPrice - ask;
         sumSellLot       += lot;
         sumSellProMulLot += proPrice * lot;
      }
   }
   if(sumBuyLot  > 0) stat.buyAvgProfitPrice  = sumBuyProMulLot  / sumBuyLot;
   if(sumSellLot > 0) stat.sellAvgProfitPrice = sumSellProMulLot / sumSellLot;
   stat.buyTotalLot  = sumBuyLot;
   stat.sellTotalLot = sumSellLot;
   return (stat.buyCnt + stat.sellCnt) > 0;
}

//+------------------------------------------------------------------+
double CalcTotalProfit()
{
   double tot = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNum) continue;
      tot += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   return tot;
}

double CalcProfitByDir(int dir)
{
   double tot = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNum) continue;
      long ptype = PositionGetInteger(POSITION_TYPE);
      if(dir ==  1 && ptype != POSITION_TYPE_BUY)  continue;
      if(dir == -1 && ptype != POSITION_TYPE_SELL) continue;
      tot += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   return tot;
}

//+------------------------------------------------------------------+
double GetLastLotByDir(int dir)
{
   double   lastLot  = 0;
   datetime lastTime = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNum) continue;
      long ptype = PositionGetInteger(POSITION_TYPE);
      if(dir ==  1 && ptype != POSITION_TYPE_BUY)  continue;
      if(dir == -1 && ptype != POSITION_TYPE_SELL) continue;

      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      if(openTime > lastTime)
      {
         lastTime = openTime;
         lastLot  = PositionGetDouble(POSITION_VOLUME);
      }
   }
   return lastLot;
}

//+------------------------------------------------------------------+
// v1.4: 获取该方向"最新一单"的开仓价 (用于'距上一单浮亏'触发加仓, 保证层间距恒定)
double GetLastOpenPriceByDir(int dir)
{
   double   lastPrice = 0;
   datetime lastTime  = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNum) continue;
      long ptype = PositionGetInteger(POSITION_TYPE);
      if(dir ==  1 && ptype != POSITION_TYPE_BUY)  continue;
      if(dir == -1 && ptype != POSITION_TYPE_SELL) continue;

      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      if(openTime > lastTime)
      {
         lastTime  = openTime;
         lastPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      }
   }
   return lastPrice;
}

//+------------------------------------------------------------------+
double NormalizeLot(double lotVal)
{
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0) step = 0.01;

   lotVal = MathFloor(lotVal / step) * step;
   lotVal = MathMax(lotVal, minLot);
   lotVal = MathMin(lotVal, maxLot);
   lotVal = NormalizeDouble(lotVal, 2);
   if(lotVal < 0.01) lotVal = 0.01;
   return lotVal;
}

//+------------------------------------------------------------------+
bool OpenTrade(int dir, double lots, int layer)
{
   lots = NormalizeLot(lots);
   double price = (dir == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                             : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   string cmt = StringFormat("stable_%s_L%d", dir==1?"B":"S", layer);
   bool ok = (dir == 1) ? trade.Buy(lots, _Symbol, price, 0, 0, cmt)
                        : trade.Sell(lots, _Symbol, price, 0, 0, cmt);
   if(ok)
   {
      Print("[stable] >> 开", dir==1?"多":"空",
            " L", layer,
            "  Lots=", DoubleToString(lots,2),
            "  Price=", DoubleToString(price,2),
            "  总浮盈=", DoubleToString(CalcTotalProfit(),2));
      lastOpenFailTs = 0;   // 成功后清失败节流

      // v1.6: 达到 MaxOrderCount 立即全平止损 (主动认亏防爆仓)
      // 逻辑理由: 满层后价格继续单边走时, 每 $1 追加浮亏 = cumLot × 100 USC
      // L22 满仓 (15.48 手) 每走 $1 亏 1548 USC ≈ $15, 走 $8 就到 stop-out
      // 主动在 L22 触发瞬间平仓 (~$101) 好过被动被强平 (~$290+)
      if(Inp_MaxLayerClose && layer >= MaxOrderCount)
      {
         double curLoss = CalcTotalProfit();
         Print("[stable] [MAX-LAYER] 达到最大层数 L", MaxOrderCount,
               " → 立即全平止损, 触发时总浮盈=", DoubleToString(curLoss,2), " USC");
         Alert(StringFormat("[stable] L%d 满层触发全平止损 浮盈=%.2f USC",
                            MaxOrderCount, curLoss));
         SendNotification(StringFormat("[stable] L%d 满层强平 浮盈=%.2f USC",
                                        MaxOrderCount, curLoss));
         CloseAllByDir(dir);
         pauseOpenUntil = TimeCurrent() + Inp_BlackSwanPauseMin * 60;
         lastPauseNoted = false;
      }
   }
   else
   {
      // M2: 错误码分级
      uint   rc     = trade.ResultRetcode();
      string rcDesc = trade.ResultRetcodeDescription();

      // 致命错误 → 立即冻结, 不再刷单 (保证金不足 / 持仓/挂单/成交量到顶)
      if(rc == TRADE_RETCODE_NO_MONEY ||
         rc == TRADE_RETCODE_LIMIT_VOLUME ||
         rc == TRADE_RETCODE_LIMIT_ORDERS ||
         rc == TRADE_RETCODE_LIMIT_POSITIONS)
      {
         Print("[stable] [FATAL] 致命错误 rc=", rc, " ", rcDesc,
               " dir=", dir, " lots=", DoubleToString(lots,2), " → 冻结 EA");
         Alert(StringFormat("[stable] 致命错误 rc=%u %s, EA 已冻结, 请检查账户", rc, rcDesc));
         emergencyFrozen = true;
         return false;
      }

      // 环境错误 → 走节流, 打印带标签
      bool envErr = (rc == TRADE_RETCODE_MARKET_CLOSED ||
                     rc == TRADE_RETCODE_TRADE_DISABLED);

      // 失败限流: 冷却期内同类错误只打印一次, 避免刷屏
      if(TimeCurrent() - lastOpenFailTs >= Inp_OpenFailCoolSec)
      {
         Print("[stable] [X] 开单失败 dir=", dir, " lots=", DoubleToString(lots,2),
               " rc=", rc, " ", rcDesc,
               envErr ? " (环境问题, 等 broker/终端恢复)" : "",
               " (", Inp_OpenFailCoolSec, "s 内重复失败仅记 1 次)");
         lastOpenFailTs = TimeCurrent();
      }
   }
   return ok;
}

//+------------------------------------------------------------------+
void CloseAllByDir(int dir)
{
   int closed = 0;
   double profitBefore = CalcProfitByDir(dir);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNum) continue;
      long ptype = PositionGetInteger(POSITION_TYPE);
      if(dir ==  1 && ptype != POSITION_TYPE_BUY)  continue;
      if(dir == -1 && ptype != POSITION_TYPE_SELL) continue;

      if(trade.PositionClose(ticket)) closed++;
      else Print("[stable] 平仓失败 ticket=", ticket,
                 " err=", trade.ResultRetcode());
   }
   if(closed > 0)
      Print("[stable] << 平", dir==1?"多":"空", " ×", closed,
            "  该方向浮盈=", DoubleToString(profitBefore,2));
}

//+------------------------------------------------------------------+
//| 黑天鹅熔断 (v1.5): M1 波动>=阈值触发, 按层数分档                  |
//|   max(buyCnt,sellCnt) < LayerCap: 全平止损 + 暂停开新仓 X 分钟   |
//|   max(buyCnt,sellCnt) >= LayerCap: 只冻结 + 手机推送告警        |
//+------------------------------------------------------------------+
void CheckBlackSwan()
{
   if(!Inp_BlackSwan || emergencyFrozen) return;
   // 已处于暂停期时不重复触发 (避免暂停期内再撞一次)
   if(TimeCurrent() < pauseOpenUntil) return;

   double high = iHigh(_Symbol, PERIOD_M1, 1);
   double low  = iLow(_Symbol, PERIOD_M1, 1);
   if(high <= 0 || low <= 0) return;
   double range = high - low;
   if(range < Inp_BlackSwanRange) return;

   PosStat stat;
   GetPositionStat(stat);
   int maxLayer = MathMax(stat.buyCnt, stat.sellCnt);

   double totalProfit = CalcTotalProfit();
   double floatLoss   = (totalProfit < 0) ? -totalProfit : 0;
   double balance     = AccountInfoDouble(ACCOUNT_BALANCE);
   double lossPct     = (balance > 0 && floatLoss > 0) ? (floatLoss / balance * 100.0) : 0;

   string common = StringFormat("M1$%.2f 层数=%d(多%d/空%d) 浮亏=%.2f USC (%.2f%%)",
                                range, maxLayer, stat.buyCnt, stat.sellCnt, floatLoss, lossPct);

   if(maxLayer >= Inp_BlackSwanLayerCap)
   {
      // 深套: 保留持仓 + 冻结 + 手机推送
      emergencyFrozen = true;
      Print("[stable-BLACKSWAN] [LOCK] ", common, " ≥ L", Inp_BlackSwanLayerCap,
            " → 保留持仓 + 冻结 (需重启 EA 解锁)");
      Alert(StringFormat("[stable] [LOCK]黑天鹅深套 L%d 保留仓+冻结 %s", maxLayer, common));
      SendNotification(StringFormat("[stable] [LOCK]黑天鹅深套 L%d 需人工干预 %s",
                                     maxLayer, common));
   }
   else
   {
      // 浅套: 全平止损 + 暂停 X 分钟, 暂停期后自动恢复 (不冻结)
      Print("[stable-BLACKSWAN] [CUT] ", common, " < L", Inp_BlackSwanLayerCap,
            " → 全平止损 + 暂停 ", Inp_BlackSwanPauseMin, " 分钟");
      Alert(StringFormat("[stable] [CUT]黑天鹅止损 L%d 全平+暂停%dmin %s",
                         maxLayer, Inp_BlackSwanPauseMin, common));
      SendNotification(StringFormat("[stable] [CUT]黑天鹅止损 L%d 全平+暂停%dmin %s",
                                     maxLayer, Inp_BlackSwanPauseMin, common));
      CloseAllByDir(1);
      CloseAllByDir(-1);
      pauseOpenUntil = TimeCurrent() + Inp_BlackSwanPauseMin * 60;
      lastPauseNoted = false;   // 让 OnTick 里能打印进入暂停的一次日志
   }
}

//+------------------------------------------------------------------+
//| 新闻名匹配 FOMC / CPI / PPI / NFP                                 |
//+------------------------------------------------------------------+
bool IsWatchedNewsName(string name)
{
   string up = name;
   StringToUpper(up);
   if(StringFind(up, "FOMC") >= 0) return true;
   if(StringFind(up, "FEDERAL FUNDS RATE") >= 0) return true;
   if(StringFind(up, "FED INTEREST RATE") >= 0) return true;
   if(StringFind(up, "CPI") >= 0) return true;
   if(StringFind(up, "CONSUMER PRICE INDEX") >= 0) return true;
   if(StringFind(up, "PPI") >= 0) return true;
   if(StringFind(up, "PRODUCER PRICE INDEX") >= 0) return true;
   if(StringFind(up, "NON-FARM") >= 0) return true;
   if(StringFind(up, "NONFARM") >= 0) return true;
   if(StringFind(up, "NON FARM") >= 0) return true;
   return false;
}

//+------------------------------------------------------------------+
//| 判断当前是否处于新闻黑洞窗口 (H2: 结果缓存 60s)                    |
//+------------------------------------------------------------------+
bool IsNewsBlackout(string &blockingEvent, int &minutesTo)
{
   blockingEvent = "";
   minutesTo = 0;
   if(!Inp_NewsFilter) return false;

   datetime now = TimeCurrent();

   // H2: 缓存命中 (60s 内直接返回上次结果, minutesTo 按当前时间重算)
   if(g_newsCacheTs > 0 && (now - g_newsCacheTs) < 60)
   {
      if(g_newsCacheBlock)
      {
         blockingEvent = g_newsCacheName;
         minutesTo = (int)((g_newsCacheEventTime - now) / 60);
      }
      return g_newsCacheBlock;
   }

   datetime from = now - Inp_NewsMinAfter  * 60;
   datetime to   = now + Inp_NewsMinBefore * 60;

   MqlCalendarValue values[];
   int n = CalendarValueHistory(values, from, to, "US");

   // 无论有无命中都刷新缓存时间戳
   g_newsCacheTs        = now;
   g_newsCacheBlock     = false;
   g_newsCacheName      = "";
   g_newsCacheEventTime = 0;

   if(n <= 0) return false;

   for(int i = 0; i < n; i++)
   {
      MqlCalendarEvent evt;
      if(!CalendarEventById(values[i].event_id, evt)) continue;
      if(evt.importance != CALENDAR_IMPORTANCE_HIGH) continue;
      if(!IsWatchedNewsName(evt.name)) continue;

      g_newsCacheBlock     = true;
      g_newsCacheName      = evt.name;
      g_newsCacheEventTime = values[i].time;

      blockingEvent = evt.name;
      minutesTo = (int)((values[i].time - now) / 60);
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| 点差检查                                                          |
//+------------------------------------------------------------------+
bool IsSpreadOK()
{
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return (spread <= Inp_MaxSpread + Inp_SpreadBuffer);
}

//+------------------------------------------------------------------+
//| 面板                                                              |
//+------------------------------------------------------------------+
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

void UpdatePanel()
{
   if(!Inp_ShowPanel) return;
   int y = 30, lh = 18;

   PosStat stat; GetPositionStat(stat);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double totalP  = CalcTotalProfit();
   double buyP    = CalcProfitByDir(1);
   double sellP   = CalcProfitByDir(-1);
   long   spd     = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   int    spdMax  = Inp_MaxSpread + Inp_SpreadBuffer;

   CreateLbl(panelPfx+"t", 10, y, "=== 美分马丁-stable v1.6 ===", clrGold); y += lh + 4;

   string buyStr = StringFormat("多: L%d/%d  手数:%.2f  浮盈:%.2f",
                                stat.buyCnt, MaxOrderCount, stat.buyTotalLot, buyP);
   CreateLbl(panelPfx+"b", 10, y, buyStr,
             stat.buyCnt==0 ? clrGray : (buyP>=0?clrLime:clrOrange)); y += lh;

   string sellStr = StringFormat("空: L%d/%d  手数:%.2f  浮盈:%.2f",
                                 stat.sellCnt, MaxOrderCount, stat.sellTotalLot, sellP);
   CreateLbl(panelPfx+"s", 10, y, sellStr,
             stat.sellCnt==0 ? clrGray : (sellP>=0?clrAqua:clrOrange)); y += lh;

   y += 4;
   CreateLbl(panelPfx+"bal", 10, y,
             StringFormat("余额:%.2f USC  总浮盈:%.2f", balance, totalP),
             totalP>=0?clrWhite:clrOrange); y += lh;

   CreateLbl(panelPfx+"spd", 10, y,
             StringFormat("点差:%d pt (阈值≤%d)", (int)spd, spdMax),
             spd>spdMax ? clrRed : clrWhite); y += lh;

   // 状态行 (优先级: 冻结 > 暂停 > 新闻 > 点差 > 正常)
   string status = "运行中";
   color  stCol  = clrLime;

   if(emergencyFrozen)
   {
      status = "[!]黑天鹅冻结 (需重启 EA)";
      stCol = clrRed;
   }
   else if(pauseOpenUntil > 0 && TimeCurrent() < pauseOpenUntil)
   {
      int remainMin = (int)((pauseOpenUntil - TimeCurrent()) / 60) + 1;
      status = StringFormat("[PAUSE] 黑天鹅暂停 剩 %d 分钟", remainMin);
      stCol = clrOrange;
   }
   else
   {
      string newsName; int newsMin;
      if(IsNewsBlackout(newsName, newsMin))
      {
         if(newsMin >= 0)
            status = StringFormat("[!]新闻窗口: %s (还剩 %d 分钟)", newsName, newsMin);
         else
            status = StringFormat("[!]新闻窗口: %s (已过 %d 分钟)", newsName, -newsMin);
         stCol = clrOrange;
      }
      else if(spd > spdMax)
      {
         status = "[!] 点差过大, 禁开新仓";
         stCol = clrOrange;
      }
   }
   CreateLbl(panelPfx+"st", 10, y, "状态: " + status, stCol);

   ChartRedraw();
}

//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
void OnTick()
{
   //--- 每 tick 保护检查
   CheckBlackSwan();

   PosStat stat;
   GetPositionStat(stat);

   // C3: 价差回落或已无持仓 → 清除 USD 等待标志
   if(stat.buyCnt  == 0 || stat.buyAvgProfitPrice  < AvgProfitTarget) g_buyWaitUsd  = false;
   if(stat.sellCnt == 0 || stat.sellAvgProfitPrice < AvgProfitTarget) g_sellWaitUsd = false;

   //--- 平仓判定 (不受冻结/新闻影响, 允许自然止盈平仓)
   if(stat.buyCnt > 0 && stat.buyAvgProfitPrice >= AvgProfitTarget)
   {
      double buyUsdProfit = CalcProfitByDir(1);
      // C3: 兜底 - Inp_MinUsdProfit > 0 时, 美元浮盈也必须达标
      if(Inp_MinUsdProfit > 0.0 && buyUsdProfit < Inp_MinUsdProfit)
      {
         if(!g_buyWaitUsd)
         {
            Print("[stable] 平多价差达标(", DoubleToString(stat.buyAvgProfitPrice,3),
                  "≥", AvgProfitTarget, ") 但 USD 浮盈=", DoubleToString(buyUsdProfit,2),
                  " < ", Inp_MinUsdProfit, " → 等待");
            g_buyWaitUsd = true;
         }
      }
      else
      {
         Print("[stable] 触发平多: 均价差=", DoubleToString(stat.buyAvgProfitPrice,3),
               " ≥ ", AvgProfitTarget, "  USD 浮盈=", DoubleToString(buyUsdProfit,2),
               "  多单数=", stat.buyCnt);
         CloseAllByDir(1);
         g_buyWaitUsd = false;
         UpdatePanel();
         return;
      }
   }
   if(stat.sellCnt > 0 && stat.sellAvgProfitPrice >= AvgProfitTarget)
   {
      double sellUsdProfit = CalcProfitByDir(-1);
      if(Inp_MinUsdProfit > 0.0 && sellUsdProfit < Inp_MinUsdProfit)
      {
         if(!g_sellWaitUsd)
         {
            Print("[stable] 平空价差达标(", DoubleToString(stat.sellAvgProfitPrice,3),
                  "≥", AvgProfitTarget, ") 但 USD 浮盈=", DoubleToString(sellUsdProfit,2),
                  " < ", Inp_MinUsdProfit, " → 等待");
            g_sellWaitUsd = true;
         }
      }
      else
      {
         Print("[stable] 触发平空: 均价差=", DoubleToString(stat.sellAvgProfitPrice,3),
               " ≥ ", AvgProfitTarget, "  USD 浮盈=", DoubleToString(sellUsdProfit,2),
               "  空单数=", stat.sellCnt);
         CloseAllByDir(-1);
         g_sellWaitUsd = false;
         UpdatePanel();
         return;
      }
   }

   //--- 开新仓前的保护门 (冻结/暂停/点差/新闻)
   if(emergencyFrozen)
   {
      UpdatePanel();
      return;
   }

   // v1.5: 黑天鹅浅套后暂停期, 期间禁开新仓 (自然止盈平仓仍生效)
   if(pauseOpenUntil > 0 && TimeCurrent() < pauseOpenUntil)
   {
      if(!lastPauseNoted && Inp_VerboseLog)
      {
         int remainMin = (int)((pauseOpenUntil - TimeCurrent()) / 60);
         Print("[stable] [PAUSE] 黑天鹅暂停中, 剩 ", remainMin, " 分钟, 禁开新仓");
         lastPauseNoted = true;
      }
      UpdatePanel();
      return;
   }
   else if(pauseOpenUntil > 0 && TimeCurrent() >= pauseOpenUntil)
   {
      Print("[stable] [OK] 黑天鹅暂停结束, 恢复开仓");
      pauseOpenUntil = 0;
      lastPauseNoted = false;
   }

   // 点差
   bool spdOK = IsSpreadOK();
   if(!spdOK)
   {
      if(!lastSpreadHi && Inp_VerboseLog)
      {
         long spd = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
         Print("[stable] [!] 点差过大 ", spd, " > ", Inp_MaxSpread + Inp_SpreadBuffer,
               " → 禁开新仓");
         lastSpreadHi = true;
      }
      UpdatePanel();
      return;
   }
   else if(lastSpreadHi)
   {
      Print("[stable] [OK] 点差恢复正常");
      lastSpreadHi = false;
   }

   // 新闻窗口
   string newsName; int newsMin;
   bool newsBlock = IsNewsBlackout(newsName, newsMin);
   if(newsBlock)
   {
      if(!lastNewsBlocked && Inp_VerboseLog)
      {
         Print("[stable] [!] 新闻窗口: ", newsName, " (", newsMin, " 分钟) → 禁开新仓");
         lastNewsBlocked = true;
      }
      UpdatePanel();
      return;
   }
   else if(lastNewsBlocked)
   {
      Print("[stable] [OK] 新闻窗口结束, 恢复开仓");
      lastNewsBlocked = false;
   }

   //--- 信号
   int sig = GetSignal();
   if(sig == 0) { UpdatePanel(); return; }

   int totalPos = stat.buyCnt + stat.sellCnt;

   //--- 首单
   if(totalPos == 0)
   {
      OpenTrade(sig, fixedLotArr[0], 1);
      UpdatePanel();
      return;
   }

   // C1: 手数表长度 (替代硬编码 12, 后续扩数组不用改分界)
   int lotArrSz = ArraySize(fixedLotArr);

   //--- 多单方向 (v1.4: 加仓触发改为"最新单浮亏 >= LossPriceGap", 保证层间距恒定)
   if(sig == 1 && stat.buyCnt < MaxOrderCount)
   {
      if(stat.buyCnt > 0)
      {
         double lastOpen  = GetLastOpenPriceByDir(1);
         double curBid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double lastLoss  = lastOpen - curBid;   // buy: 最新单浮亏 (>0 表示亏)
         if(lastOpen > 0 && lastLoss >= LossPriceGap)
         {
            double nextLot;
            if(stat.buyCnt < lotArrSz) nextLot = fixedLotArr[stat.buyCnt];
            else                       nextLot = GetLastLotByDir(1) * MultiAfter4;
            if(Inp_VerboseLog)
               Print("[stable] 触发加多 L", stat.buyCnt+1,
                     ": 最新单浮亏=", DoubleToString(lastLoss,3),
                     " ≥ ", LossPriceGap,
                     " (lastOpen=", DoubleToString(lastOpen,2),
                     " bid=", DoubleToString(curBid,2),
                     ")  下一单=", DoubleToString(NormalizeLot(nextLot),2));
            OpenTrade(1, nextLot, stat.buyCnt+1);
         }
      }
      else if(stat.buyCnt == 0)
      {
         OpenTrade(1, fixedLotArr[0], 1);
      }
   }

   //--- 空单方向 (v1.4: 加仓触发改为"最新单浮亏 >= LossPriceGap", 保证层间距恒定)
   if(sig == -1 && stat.sellCnt < MaxOrderCount)
   {
      if(stat.sellCnt > 0)
      {
         double lastOpen  = GetLastOpenPriceByDir(-1);
         double curAsk    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double lastLoss  = curAsk - lastOpen;   // sell: 最新单浮亏 (>0 表示亏)
         if(lastOpen > 0 && lastLoss >= LossPriceGap)
         {
            double nextLot;
            if(stat.sellCnt < lotArrSz) nextLot = fixedLotArr[stat.sellCnt];
            else                        nextLot = GetLastLotByDir(-1) * MultiAfter4;
            if(Inp_VerboseLog)
               Print("[stable] 触发加空 L", stat.sellCnt+1,
                     ": 最新单浮亏=", DoubleToString(lastLoss,3),
                     " ≥ ", LossPriceGap,
                     " (lastOpen=", DoubleToString(lastOpen,2),
                     " ask=", DoubleToString(curAsk,2),
                     ")  下一单=", DoubleToString(NormalizeLot(nextLot),2));
            OpenTrade(-1, nextLot, stat.sellCnt+1);
         }
      }
      else if(stat.sellCnt == 0)
      {
         OpenTrade(-1, fixedLotArr[0], 1);
      }
   }

   UpdatePanel();
}
//+------------------------------------------------------------------+
