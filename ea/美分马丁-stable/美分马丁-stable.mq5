//+------------------------------------------------------------------+
//|                                              美分马丁-stable.mq5 |
//|                                                      Version 1.9 |
//|                                                                  |
//|  v1.9 变更 (vs v1.8): 间距 3.25 / 24 层 + 满层等待 + 深层持续加仓  |
//|    * LossPriceGap 2.5 -> 3.25, MaxOrderCount 22 -> 24              |
//|      - 实际成交间距 = gap - 点差 (点差 0.32 时约 2.93)             |
//|      - 600u: L24 开在约 67.4 点, 50% 强平约 76 点, TP 回撤约 10.6  |
//|    * [E] 满层等待: L24 开出后不立即强平, 等 Inp_MaxLayerWaitMin    |
//|      分钟 (默认 30), 期间到 TP 照常止盈, 到点不论盈亏全平+暂停     |
//|      - 计时取最后一单开仓时间, EA 重启后可接上                     |
//|      - 只计交易时间 (按 M1 K 线根数), 每日停盘/周末不计入          |
//|      - 到点平仓不受冻结/暂停/新闻/点差影响                         |
//|      - 可选硬止损 Inp_MaxLayerHardML (默认 0=关)                   |
//|    * [F] 深层篮子 (>= Inp_NoRotateLayer, 默认 16):                 |
//|      - 信号翻转不平仓, 不开反向单                                  |
//|      - 加仓不看信号, 按间距继续加到满层                            |
//|      - 16 层以下行为与 v1.8 完全相同                               |
//|    * [G] 黑天鹅改为按 tick 实时检测: 最近 60 秒内波动 >= $20 即触发 |
//|      - 不再等 M1 收盘 (v1.8 最多晚 1 分钟), 跨分钟的急涨急跌也能抓到 |
//|      - 深套 (>= LayerCap) 不再冻结, 只推送; 触发后清空缓存防重复    |
//|    * [H] 平仓重试分级: 市场关闭/算法交易关闭/瞬时错误不计失败不冻结 |
//|      - 持仓已不存在 (券商同时强平等) 按已平计, 不再误判 FATAL       |
//|      - 有单没平完时记为待平, 下个 tick 优先继续平, 平完才做别的     |
//|      - OnInit 清理平仓失败/待平状态 (改参数时全局变量不会重置)      |
//|    * [I] 周一开盘后 Inp_MonOpenBlockMin 分钟不开仓 (默认 180)      |
//|    * [J] 余额 < Inp_MinBalanceUSC 时面板红字提示 (不影响交易)      |
//|                                                                  |
//|  v1.8 变更 (vs v1.7): 单向轮换 + 平仓重试 + 面板升级               |
//|    * [A] 信号翻转时先 CloseAllByDir 对向仓位 (单向轮换防双向失控)   |
//|    * [B] MaxLayerClose 触发后兜底检查并清对向残仓                   |
//|    * [C] CloseAllByDir 每单重试最多 10 次, 全失败冻结+推送+面板显示  |
//|    * [D] 面板改为单行: 当前方向层数/手数/浮盈/目标价/预期收益        |
//|                                                                  |
//|  v1.7 变更 (vs v1.6): LossPriceGap 默认值 2.0 -> 2.5 对齐实盘      |
//|    * LossPriceGap 默认值从 $2.0 调为 $2.5, 与真机反推层间距一致    |
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
//|  策略骨架 (v1.9):                                                 |
//|    - M15 MA20/MA50 双均线方向信号, 单向轮换                       |
//|    - L1-L12 查表 fixedLotArr, L13+ = 上一单 × MultiAfter4 (1.3)   |
//|    - 最新一单浮亏 >= $3.25/oz 触发加仓 (实际成交间距 = gap-点差)  |
//|    - 手数加权均价浮盈 >= $0.6/oz 平该方向全部                     |
//|    - 每方向最多 24 层, 满层后等待 30 分钟再全平                   |
//|    - >= 16 层: 加仓不看信号, 信号翻转不平仓                       |
//|    - 需 Hedging 账户                                              |
//+------------------------------------------------------------------+
#property copyright "美分马丁-stable"
#property version   "1.90"
#property description "美分马丁-stable v1.9 (间距3.25/24层+满层等待+深层持续加仓+黑天鹅深套不冻结)"
#property strict

#include <Trade\Trade.mqh>

//============ 策略参数 ============
input group "=== 策略核心 ==="
input ENUM_TIMEFRAMES SignalTimeFrame = PERIOD_M15;    // 判断方向周期
input double LossPriceGap     = 3.25;                  // 加仓阈值: 最新一单浮亏价差(USD/oz) (v1.9: 2.5→3.25; 实际成交间距=gap-点差)
input double AvgProfitTarget  = 0.6;                   // 平仓阈值: 手数加权平均价差(USD/oz), 非美元浮盈
input double Inp_MinUsdProfit = 0.0;                   // 平仓兜底: 净美元浮盈 ≥ 该值才平, 0=不启用
input int    MaxOrderCount    = 24;                    // 每方向最大层数 (v1.9: 22→24, 按 600u 本金设计)
input bool   Inp_MaxLayerClose= true;                  // v1.6: 满层处理开关 (v1.9: 配合 Inp_MaxLayerWaitMin 延迟平仓)
input int    Inp_MaxLayerWaitMin = 30;                 // v1.9: 满层后等待 X 分钟, 期间到 TP 照常止盈, 到点不论盈亏全平; 0=开出满层立即全平(v1.8 行为)
// v1.9: 满层等待期间的硬止损 (保证金比例 %), 低于该值立即全平, 不等到点.
//   0 = 关闭, 等待期间只靠 TP / 到点平仓 / 券商强平.
//   参考 (600u, gap 3.25, 24 层, 点差 0.32, 价格 4300):
//     L24 开出时约 149%, 若立即平约亏 $261
//     设 100 → 约在 L24 后再走 4.3 点触发, 约亏 $372
//     设 80  → 约在 L24 后再走 6.0 点触发, 约亏 $417
//     不设   → 券商 50% 强平约在 L24 后再走 8.6 点, 约亏 $486 + 滑点
//   注意: 必须高于券商强平线 (Decode 约 50%), 否则不会先于强平触发.
input double Inp_MaxLayerHardML  = 0;                  // v1.9: 满层等待期硬止损 (保证金比例%), 0=关闭, 须 > 券商强平线
input int    Inp_NoRotateLayer   = 16;                 // v1.9: 篮子 ≥ X 层时: 信号翻转不平仓/不开反向单, 加仓不看信号; 0=关闭(v1.8 行为)
input double MultiAfter4      = 1.3;                   // L13+ 加仓倍数 (前 12 层用 fixedLotArr 查表)
input int    MagicNum         = 8866;
input int    Slippage         = 10;                    // 允许滑点(points)

//============ 保护参数 ============
input group "=== 黑天鹅熔断 ==="
input bool   Inp_BlackSwan          = true;            // 启用黑天鹅熔断
input double Inp_BlackSwanRange     = 20.0;            // 最近 Inp_BlackSwanWindowSec 秒内 tick 最高-最低 >= $X 触发
input int    Inp_BlackSwanWindowSec = 60;              // v1.9: 黑天鹅实时检测窗口(秒), 按 tick 滚动计算, 不等 K 线收盘
input int    Inp_BlackSwanLayerCap  = 16;              // 触发时层数 >= X → 只推送, 逻辑照常 (v1.9 不再冻结); < X → 全平+暂停
input int    Inp_BlackSwanPauseMin  = 30;              // 全平后禁开新仓 X 分钟

input group "=== 点差保护 ==="
input int    Inp_MaxSpread      = 60;                  // 点差>X 禁开新仓
input int    Inp_SpreadBuffer   = 5;

input group "=== 周一开盘保护 ==="
input int    Inp_MonOpenBlockMin = 180;                // v1.9: 周一服务器时间 01:00 起 X 分钟内不开仓不加仓 (TP/满层到点照常); 0=关闭

input group "=== 新闻过滤 (FOMC/CPI/PPI/NFP) ==="
input bool   Inp_NewsFilter     = true;
input int    Inp_NewsMinBefore  = 30;                  // 事件前 X 分钟
input int    Inp_NewsMinAfter   = 30;                  // 事件后 X 分钟

input group "=== 面板 & 日志 ==="
input bool   Inp_ShowPanel      = true;
input bool   Inp_VerboseLog     = true;
input int    Inp_OpenFailCoolSec = 2;                  // 开单失败后冷却 X 秒 (避免刷屏)
input double Inp_MinBalanceUSC   = 60000;              // v1.9: 余额低于 X USC 时面板红字提示 (只提示, 不影响交易); 0=关闭

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

// v1.8 [C]: 平仓失败重试计数 (每单独立)
string   g_closeFailMsg = "";   // 面板显示用

// v1.9 [G]: 黑天鹅实时检测 - 最近 Inp_BlackSwanWindowSec 秒的 tick 环形缓存 (bid)
#define BS_BUF_MAX 8192
long     g_bsTimeMsc[BS_BUF_MAX];
double   g_bsPrice[BS_BUF_MAX];
int      g_bsHead  = 0;    // 最旧一条的下标
int      g_bsCount = 0;    // 缓存条数
// v1.9 [I]: 周一开盘保护日志节流
bool     lastMonBlocked  = false;
// v1.9 [H]: 平仓暂缓日志节流 (60s 一次)
datetime g_closeDeferLogTs = 0;
// v1.9 [H]: 未平完的方向 (有单暂缓), 下个 tick 优先继续平, 防止残仓被当成新篮子继续加仓
bool     g_pendingBuy  = false;
bool     g_pendingSell = false;
// v1.9 [E]: 满层平仓未平完时, 平完后再推送 + 暂停
bool     g_pendingMaxLayer       = false;
string   g_pendingMaxLayerReason = "";
double   g_pendingMaxLayerPnl    = 0;

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
   double buyAvgOpenPrice;   // v1.8 [D]: 多仓手数加权平均开仓价
   double sellAvgOpenPrice;  // v1.8 [D]: 空仓手数加权平均开仓价
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

   // v1.9: 改参数点确定时 MT5 只调 OnDeinit+OnInit, 不重新加载 EA, 全局变量会保留旧值.
   //   这里与 emergencyFrozen 一起清掉, 否则面板显示"运行中"但满层出口/待平处理被
   //   残留的 g_closeFailMsg 静默关闭. 效果与重启 EA 一致.
   g_closeFailMsg          = "";
   g_pendingBuy            = false;
   g_pendingSell           = false;
   g_pendingMaxLayer       = false;
   g_pendingMaxLayerReason = "";
   g_pendingMaxLayerPnl    = 0;
   g_closeDeferLogTs       = 0;

   Print("=============================================");
   Print("=== 美分马丁-stable v1.9 启动 ===");
   lastMonBlocked  = false;
   g_bsHead = 0; g_bsCount = 0;   // v1.9 [G]: 清空黑天鹅 tick 缓存
   Print("[保护] 图表周期校验: 只允许 M1 (当前=", EnumToString((ENUM_TIMEFRAMES)Period()), " [OK])");
   if(Inp_MaxLayerWaitMin > 0)
      Print("[保护] 满层处理=", Inp_MaxLayerClose ? "开" : "关",
            " (达 L", MaxOrderCount, " 后等待 ", Inp_MaxLayerWaitMin,
            " min, 期间到 TP 止盈, 到点全平 + 暂停 ", Inp_BlackSwanPauseMin, " min",
            ", 硬止损=", (Inp_MaxLayerHardML > 0 ? DoubleToString(Inp_MaxLayerHardML,0) + "%" : "关"), ")");
   else
      Print("[保护] 满层处理=", Inp_MaxLayerClose ? "开" : "关",
            " (达 L", MaxOrderCount, " 立即 CloseAll + 暂停 ", Inp_BlackSwanPauseMin, " min)");
   Print("[深层] 篮子 ≥ L", Inp_NoRotateLayer, ": 信号翻转不平仓/不开反向单, 加仓不看信号",
         (Inp_NoRotateLayer > 0 ? "" : " (已关闭, 同 v1.8)"));
   Print("[保护] 周一开盘保护=", (Inp_MonOpenBlockMin > 0 ? "开" : "关"),
         " (服务器时间周一 01:00 起 ", Inp_MonOpenBlockMin, " min 不开仓)");
   double balInit = AccountInfoDouble(ACCOUNT_BALANCE);
   if(Inp_MinBalanceUSC > 0 && balInit < Inp_MinBalanceUSC)
      Print("[!] 余额 ", DoubleToString(balInit,2), " USC < 建议 ", DoubleToString(Inp_MinBalanceUSC,0),
            " USC, 当前参数按 600u 设计, 余额不足可能在满层前被券商强平");
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
         " (", Inp_BlackSwanWindowSec, "秒内波动>$", Inp_BlackSwanRange, " 按tick实时",
         ", 层<", Inp_BlackSwanLayerCap, " 全平+暂停", Inp_BlackSwanPauseMin,
         "min, 层≥", Inp_BlackSwanLayerCap, " 只推送不冻结)");
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
   stat.buyAvgOpenPrice = 0; stat.sellAvgOpenPrice = 0;  // v1.8 [D]

   double sumBuyLot = 0, sumSellLot = 0;
   double sumBuyProMulLot = 0, sumSellProMulLot = 0;
   double sumBuyOpenMulLot = 0, sumSellOpenMulLot = 0;  // v1.8 [D]
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
         sumBuyLot           += lot;
         sumBuyProMulLot     += proPrice * lot;
         sumBuyOpenMulLot    += openPrice * lot;   // v1.8 [D]
      }
      else if(ptype == POSITION_TYPE_SELL)
      {
         stat.sellCnt++;
         proPrice = openPrice - ask;
         sumSellLot          += lot;
         sumSellProMulLot    += proPrice * lot;
         sumSellOpenMulLot   += openPrice * lot;   // v1.8 [D]
      }
   }
   if(sumBuyLot  > 0) { stat.buyAvgProfitPrice  = sumBuyProMulLot  / sumBuyLot;  stat.buyAvgOpenPrice  = sumBuyOpenMulLot  / sumBuyLot; }
   if(sumSellLot > 0) { stat.sellAvgProfitPrice = sumSellProMulLot / sumSellLot; stat.sellAvgOpenPrice = sumSellOpenMulLot / sumSellLot; }
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
// v1.9 [E]: 该方向最新一单的开仓时间 (满层等待计时起点, EA 重启后仍可接上)
datetime GetLastOpenTimeByDir(int dir)
{
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
      if(openTime > lastTime) lastTime = openTime;
   }
   return lastTime;
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

      // v1.6: 满层处理 (主动认亏防爆仓)
      // 逻辑理由: 满层后价格继续单边走时, 每 $1 追加浮亏 = 满仓手数 × 100 USC
      // v1.9: L24 满仓 26.10 手, 每走 $1 约亏 $26; 600u gap3.25 时 L24 开在约 67.4 点,
      //       此刻全平约亏 $261, 再走约 8.6 点到券商 50% 强平 (约亏 $486)
      // v1.9 [E]: Inp_MaxLayerWaitMin > 0 时不立即平, 进入等待;
      //           到点平仓 / 硬止损在 OnTick 的 CheckMaxLayerWait() 里执行
      if(Inp_MaxLayerClose && layer >= MaxOrderCount)
      {
         if(Inp_MaxLayerWaitMin > 0)
         {
            double curPnl = CalcProfitByDir(dir);
            Print("[stable] [MAX-LAYER] 达到最大层数 L", MaxOrderCount,
                  " → 等待 ", Inp_MaxLayerWaitMin, " 分钟 (期间到 TP 止盈, 到点全平), 当前浮盈=",
                  DoubleToString(curPnl,2), " USC");
            Alert(StringFormat("[stable] L%d 满层, 等待 %d 分钟 浮盈=%.2f USC",
                               MaxOrderCount, Inp_MaxLayerWaitMin, curPnl));
            SendNotification(StringFormat("[stable] L%d 满层, 等待 %d 分钟 浮盈=%.2f USC",
                                          MaxOrderCount, Inp_MaxLayerWaitMin, curPnl));
         }
         else
         {
            DoMaxLayerClose(dir, "满层立即全平");
         }
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
// v1.9 [H]: 环境错误 → 不计失败, 不冻结, 下个 tick 再试
//   市场关闭 / 交易禁用 / 服务器禁用自动交易(10026) / 终端关闭了"算法交易"按钮(10027)
//   (开仓路径对这些错误也只走冷却, 平仓路径保持一致)
bool IsMarketClosedRc(uint rc)
{
   return (rc == TRADE_RETCODE_MARKET_CLOSED ||
           rc == TRADE_RETCODE_TRADE_DISABLED ||
           rc == TRADE_RETCODE_SERVER_DISABLES_AT ||
           rc == TRADE_RETCODE_CLIENT_DISABLES_AT);
}

// v1.9 [H]: 瞬时错误 (重新报价/价格变动/无报价/连接/超时) → 间隔 200ms 重试, 本轮失败也不冻结
bool IsTransientRc(uint rc)
{
   return (rc == TRADE_RETCODE_REQUOTE ||
           rc == TRADE_RETCODE_PRICE_CHANGED ||
           rc == TRADE_RETCODE_PRICE_OFF ||
           rc == TRADE_RETCODE_CONNECTION ||
           rc == TRADE_RETCODE_TIMEOUT ||
           rc == TRADE_RETCODE_TOO_MANY_REQUESTS);
}

// 返回 true = 该方向持仓已全部平掉; false = 有单留待下个 tick 重试, 或已冻结
bool CloseAllByDir(int dir)
{
   int closed = 0, deferred = 0;
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

      // v1.8 [C]: 每单最多重试 10 次
      // v1.9 [H]: 按错误类型分级, 只有"其他错误"10 次全失败才冻结 EA
      bool ok = false;
      bool marketClosed = false;
      uint lastRc = 0;
      for(int attempt = 1; attempt <= 10; attempt++)
      {
         // v1.9 [H]: 持仓已不存在 (券商同时强平 / 上次超时但已成交) → 按已平计.
         //   CTrade::PositionClose 找不到持仓时直接返回 false, 且不清 m_result,
         //   ResultRetcode() 是上一次交易的旧返回码, 不能用来判断.
         if(!PositionSelectByTicket(ticket)) { ok = true; break; }
         ok = trade.PositionClose(ticket);
         lastRc = trade.ResultRetcode();
         if(ok) break;
         if(IsMarketClosedRc(lastRc)) { marketClosed = true; break; }
         Print("[stable] 平仓重试 ", attempt, "/10  ticket=", ticket,
               " rc=", lastRc, " ", trade.ResultRetcodeDescription());
         if(IsTransientRc(lastRc)) Sleep(200);
      }

      if(ok)
      {
         closed++;
      }
      else if(marketClosed || IsTransientRc(lastRc))
      {
         deferred++;
         if(TimeCurrent() - g_closeDeferLogTs >= 60)
         {
            Print("[stable] [WAIT] 平仓暂缓 ticket=", ticket, " rc=", lastRc, " ",
                  trade.ResultRetcodeDescription(), " → 下个 tick 重试 (不计失败, 不冻结)");
            g_closeDeferLogTs = TimeCurrent();
         }
      }
      else
      {
         g_closeFailMsg = StringFormat("平仓失败10次 ticket=%llu rc=%u", ticket, lastRc);
         Print("[stable] [FATAL] ", g_closeFailMsg, " → 冻结 EA");
         Alert(StringFormat("[stable] 平仓失败10次 ticket=%llu rc=%u, EA 已冻结, 请人工干预",
                             ticket, lastRc));
         SendNotification(StringFormat("[stable] 平仓失败10次 ticket=%llu rc=%u 需人工干预",
                                        ticket, lastRc));
         emergencyFrozen = true;
         UpdatePanel();
         return false;
      }
   }
   if(closed > 0)
      Print("[stable] << 平", dir==1?"多":"空", " ×", closed,
            "  该方向浮盈=", DoubleToString(profitBefore,2),
            (deferred > 0 ? StringFormat("  (另有 %d 单暂缓)", deferred) : ""));

   // v1.9 [H]: 有单暂缓 → 记为待平, 下个 tick 由 ProcessPendingClose() 优先继续平
   if(dir == 1) g_pendingBuy  = (deferred > 0);
   else         g_pendingSell = (deferred > 0);
   return (deferred == 0);
}

//+------------------------------------------------------------------+
//| v1.9 [E]: 满层平仓完成后的收尾 (推送 + 暂停)                       |
//+------------------------------------------------------------------+
void FinishMaxLayerClose(string reason, double pnl)
{
   Print("[stable] [MAX-LAYER] ", reason, " L", MaxOrderCount,
         " → 已全平, 触发时浮盈=", DoubleToString(pnl,2), " USC, 暂停 ", Inp_BlackSwanPauseMin, " 分钟");
   Alert(StringFormat("[stable] L%d %s 已全平 触发时浮盈=%.2f USC", MaxOrderCount, reason, pnl));
   SendNotification(StringFormat("[stable] L%d %s 已全平 触发时浮盈=%.2f USC", MaxOrderCount, reason, pnl));
   pauseOpenUntil = TimeCurrent() + Inp_BlackSwanPauseMin * 60;
   lastPauseNoted = false;
}

//+------------------------------------------------------------------+
//| v1.9 [H]: 继续平上次没平完的方向 (OnTick 最先执行, 在 TP 之前)     |
//|   返回 true = 本 tick 处理了待平仓位 (OnTick 应 return)            |
//+------------------------------------------------------------------+
bool ProcessPendingClose(PosStat &stat)
{
   if(!g_pendingBuy && !g_pendingSell && !g_pendingMaxLayer) return false;
   if(g_closeFailMsg != "") return false;   // 平仓失败冻结: 需人工处理

   bool acted = false;
   if(g_pendingBuy)
   {
      if(stat.buyCnt > 0) { CloseAllByDir(1); acted = true; }
      else g_pendingBuy = false;
   }
   if(g_pendingSell)
   {
      if(stat.sellCnt > 0) { CloseAllByDir(-1); acted = true; }
      else g_pendingSell = false;
   }

   if(g_pendingMaxLayer && !g_pendingBuy && !g_pendingSell)
   {
      FinishMaxLayerClose(g_pendingMaxLayerReason, g_pendingMaxLayerPnl);
      g_pendingMaxLayer = false;
      acted = true;
   }
   return acted;
}

//+------------------------------------------------------------------+
//| v1.9 [E]: 满层全平 (立即模式 / 等待到点 / 硬止损 共用)             |
//|   返回 true = 已全部平掉 (已推送 + 暂停)                           |
//|   false = 有单暂缓 → 记为待平, 由 ProcessPendingClose() 平完后收尾  |
//|           或平仓失败冻结 → 需人工处理                              |
//+------------------------------------------------------------------+
bool DoMaxLayerClose(int dir, string reason)
{
   double pnl = CalcProfitByDir(dir);
   bool allClosed = CloseAllByDir(dir);

   // v1.8 [B]: 兜底——正常情况改动A已清对向，此处防御性扫描残仓
   if(g_closeFailMsg == "")
   {
      PosStat ms; GetPositionStat(ms);
      int oppDir = (dir == 1) ? -1 : 1;
      int oppCnt = (oppDir == 1) ? ms.buyCnt : ms.sellCnt;
      if(oppCnt > 0)
      {
         Print("[stable] [MAX-LAYER] 发现对向残仓 L", oppCnt, " → 一并平掉");
         if(!CloseAllByDir(oppDir)) allClosed = false;
      }
   }

   if(!allClosed)
   {
      if(g_closeFailMsg == "")
      {
         // 暂缓: 平完后再推送 + 暂停
         g_pendingMaxLayer       = true;
         g_pendingMaxLayerReason = reason;
         g_pendingMaxLayerPnl    = pnl;
      }
      return false;
   }

   FinishMaxLayerClose(reason, pnl);
   return true;
}

//+------------------------------------------------------------------+
//| v1.9 [E]: 满层已等待的"交易分钟数"                                 |
//|   按 lastT 之后生成的 M1 K 线根数计: 休市 (每日停盘/周末/节假日)    |
//|   不产生 K 线, 自动不计入. 直接读 K 线历史, EA 重启后仍可接上.      |
//|   交易时段内个别无成交的分钟也不计, 实际等待会略长于设定值.         |
//|   K 线历史取不到时退回服务器时间差 (保证出口不失效).                |
//+------------------------------------------------------------------+
int MaxLayerWaitedMin(datetime lastT)
{
   int shift = iBarShift(_Symbol, PERIOD_M1, lastT, false);
   if(shift >= 0) return shift;
   return (int)((TimeCurrent() - lastT) / 60);
}

//+------------------------------------------------------------------+
//| v1.9 [E]: 满层等待检查 (OnTick 每 tick, 在保护门之前执行)          |
//|   该方向层数 >= MaxOrderCount 且最后一单后满 X 分钟交易时间 → 全平  |
//|   硬止损 (Inp_MaxLayerHardML > 0): 保证金比例 <= 阈值 → 立即全平   |
//|   返回 true = 本 tick 执行了平仓动作 (OnTick 应 return)            |
//+------------------------------------------------------------------+
bool CheckMaxLayerWait(PosStat &stat)
{
   if(!Inp_MaxLayerClose || Inp_MaxLayerWaitMin <= 0) return false;
   if(g_closeFailMsg != "") return false;   // 平仓失败冻结: 需人工处理, 不自动重复平仓

   for(int k = 0; k < 2; k++)
   {
      int dir = (k == 0) ? 1 : -1;
      int cnt = (dir == 1) ? stat.buyCnt : stat.sellCnt;
      if(cnt < MaxOrderCount) continue;

      if(Inp_MaxLayerHardML > 0)
      {
         // 注意: ACCOUNT_MARGIN_LEVEL 是全账户口径, 同账户有手动单/其他 EA 时触发点会偏离预估
         double ml = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
         if(ml > 0 && ml <= Inp_MaxLayerHardML)
         {
            DoMaxLayerClose(dir, StringFormat("等待期硬止损 (保证金比例 %.0f%% ≤ %.0f%%)",
                                              ml, Inp_MaxLayerHardML));
            return true;
         }
      }

      datetime lastT = GetLastOpenTimeByDir(dir);
      if(lastT > 0 && MaxLayerWaitedMin(lastT) >= Inp_MaxLayerWaitMin)
      {
         DoMaxLayerClose(dir, StringFormat("满层等待 %d 分钟(交易时间)到点", Inp_MaxLayerWaitMin));
         return true;
      }
   }
   return false;
}

// v1.9 [E]: 面板用, 返回满层等待剩余分钟 (无等待返回 -1)
int MaxLayerWaitRemainMin(PosStat &stat)
{
   if(!Inp_MaxLayerClose || Inp_MaxLayerWaitMin <= 0) return -1;
   for(int k = 0; k < 2; k++)
   {
      int dir = (k == 0) ? 1 : -1;
      int cnt = (dir == 1) ? stat.buyCnt : stat.sellCnt;
      if(cnt < MaxOrderCount) continue;
      datetime lastT = GetLastOpenTimeByDir(dir);
      if(lastT <= 0) continue;
      int remain = Inp_MaxLayerWaitMin - MaxLayerWaitedMin(lastT);
      return (remain < 0) ? 0 : remain;
   }
   return -1;
}

//+------------------------------------------------------------------+
//| v1.9 [I]: 周一开盘保护 (服务器时间周一 01:00 起 X 分钟)            |
//+------------------------------------------------------------------+
bool IsMonOpenBlock()
{
   if(Inp_MonOpenBlockMin <= 0) return false;
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   if(t.day_of_week != 1) return false;
   int mod = t.hour * 60 + t.min;
   return (mod >= 60 && mod < 60 + Inp_MonOpenBlockMin);
}

//+------------------------------------------------------------------+
//| v1.9 [F]: 深层篮子加仓 (不看信号, 只看最新单浮亏 >= LossPriceGap)  |
//|   逻辑与信号加仓分支一致, 单独成函数以免改动 v1.8 原有代码          |
//+------------------------------------------------------------------+
void TryAddDeepLayer(int dir, int cnt)
{
   if(cnt <= 0 || cnt >= MaxOrderCount) return;
   double lastOpen = GetLastOpenPriceByDir(dir);
   if(lastOpen <= 0) return;
   double lastLoss = (dir == 1) ? (lastOpen - SymbolInfoDouble(_Symbol, SYMBOL_BID))
                                : (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - lastOpen);
   if(lastLoss < LossPriceGap) return;

   int lotArrSz = ArraySize(fixedLotArr);
   double nextLot = (cnt < lotArrSz) ? fixedLotArr[cnt] : GetLastLotByDir(dir) * MultiAfter4;
   if(Inp_VerboseLog)
      Print("[stable] [深层] 触发加", dir==1?"多":"空", " L", cnt+1,
            ": 最新单浮亏=", DoubleToString(lastLoss,3), " ≥ ", LossPriceGap,
            " (不看信号)  下一单=", DoubleToString(NormalizeLot(nextLot),2));
   OpenTrade(dir, nextLot, cnt+1);
}

//+------------------------------------------------------------------+
//| v1.9 [G]: 黑天鹅 tick 缓存                                        |
//|   每 tick 记录 bid, 只保留最近 Inp_BlackSwanWindowSec 秒.          |
//|   休市/周末前的 tick 早已超出窗口, 开盘跳空不会被算成黑天鹅.       |
//|   EA 重启或改参数后缓存为空, 头 X 秒的灵敏度会低一些.             |
//+------------------------------------------------------------------+
void BsPushTick()
{
   MqlTick tk;
   if(!SymbolInfoTick(_Symbol, tk)) return;
   if(tk.bid <= 0) return;
   long nowMsc = (long)tk.time_msc;
   if(nowMsc <= 0) nowMsc = (long)tk.time * 1000;

   int idx;
   if(g_bsCount < BS_BUF_MAX)
   {
      idx = (g_bsHead + g_bsCount) % BS_BUF_MAX;
      g_bsCount++;
   }
   else
   {
      idx = g_bsHead;                         // 缓存满: 覆盖最旧一条
      g_bsHead = (g_bsHead + 1) % BS_BUF_MAX;
   }
   g_bsTimeMsc[idx] = nowMsc;
   g_bsPrice[idx]   = tk.bid;

   // 丢弃窗口外的旧 tick
   long cutoff = nowMsc - (long)Inp_BlackSwanWindowSec * 1000;
   while(g_bsCount > 0 && g_bsTimeMsc[g_bsHead] < cutoff)
   {
      g_bsHead = (g_bsHead + 1) % BS_BUF_MAX;
      g_bsCount--;
   }
}

// 窗口内最高价 - 最低价 (不足 2 个 tick 返回 0)
double BsRange()
{
   if(g_bsCount < 2) return 0;
   double hi = -DBL_MAX, lo = DBL_MAX;
   for(int i = 0; i < g_bsCount; i++)
   {
      double p = g_bsPrice[(g_bsHead + i) % BS_BUF_MAX];
      if(p > hi) hi = p;
      if(p < lo) lo = p;
   }
   return hi - lo;
}

//+------------------------------------------------------------------+
//| 黑天鹅熔断 (v1.5 按层数分档, v1.9 改为按 tick 实时检测)            |
//|   触发: 最近 Inp_BlackSwanWindowSec 秒内 tick 最高-最低 >= 阈值    |
//|         (v1.8 及以前看已收盘的 M1, 最多晚 1 分钟)                 |
//|   max(buyCnt,sellCnt) < LayerCap: 全平止损 + 暂停开新仓 X 分钟   |
//|   max(buyCnt,sellCnt) >= LayerCap: v1.9 只推送, 不冻结, 逻辑照常 |
//|     (v1.8 及以前会冻结 EA 需重启, 导致深层篮子停加、到不了满层)  |
//+------------------------------------------------------------------+
void CheckBlackSwan()
{
   BsPushTick();   // 先记录, 冻结/暂停期间也保持缓存最新
   if(!Inp_BlackSwan || emergencyFrozen) return;
   // 已处于暂停期时不重复触发 (避免暂停期内再撞一次)
   if(TimeCurrent() < pauseOpenUntil) return;

   double range = BsRange();
   if(range < Inp_BlackSwanRange) return;

   // 触发后清空缓存: 需要在新窗口内再走满阈值才会再次触发, 防止每 tick 重复推送
   g_bsHead = 0; g_bsCount = 0;

   PosStat stat;
   GetPositionStat(stat);
   int maxLayer = MathMax(stat.buyCnt, stat.sellCnt);

   double totalProfit = CalcTotalProfit();
   double floatLoss   = (totalProfit < 0) ? -totalProfit : 0;
   double balance     = AccountInfoDouble(ACCOUNT_BALANCE);
   double lossPct     = (balance > 0 && floatLoss > 0) ? (floatLoss / balance * 100.0) : 0;

   string common = StringFormat("%ds内波动$%.2f 层数=%d(多%d/空%d) 浮亏=%.2f USC (%.2f%%)",
                                Inp_BlackSwanWindowSec, range, maxLayer, stat.buyCnt, stat.sellCnt,
                                floatLoss, lossPct);

   if(maxLayer >= Inp_BlackSwanLayerCap)
   {
      // 深套: 保留持仓 + 手机推送, v1.9 不再冻结, 加仓/满层等待逻辑照常运行
      Print("[stable-BLACKSWAN] [ALERT] ", common, " ≥ L", Inp_BlackSwanLayerCap,
            " → 保留持仓, 不冻结, 逻辑照常");
      Alert(StringFormat("[stable] [ALERT]黑天鹅深套 L%d 保留仓, 逻辑照常 %s", maxLayer, common));
      SendNotification(StringFormat("[stable] [ALERT]黑天鹅深套 L%d 保留仓, 逻辑照常 %s",
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
   long   spd     = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   int    spdMax  = Inp_MaxSpread + Inp_SpreadBuffer;

   // v1.8 [D]: tick 价值 (用于计算预期收益 USC)
   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double perOz    = (tickSize > 0) ? (tickVal / tickSize) : 0;   // USD/oz per $1 move

   CreateLbl(panelPfx+"t", 10, y, "=== 美分马丁-stable v1.9 ===", clrGold); y += lh + 4;

   // v1.8 [D]: 当前持仓方向单行显示
   {
      string dirStr;
      color  dirCol;
      bool   hasBuy  = stat.buyCnt  > 0;
      bool   hasSell = stat.sellCnt > 0;

      if(!hasBuy && !hasSell)
      {
         dirStr = "持仓: 空仓";
         dirCol = clrGray;
      }
      else
      {
         // 有持仓时取持仓方向 (单向轮换后通常只有一个方向)
         int    cnt      = hasBuy ? stat.buyCnt  : stat.sellCnt;
         double totalLot = hasBuy ? stat.buyTotalLot  : stat.sellTotalLot;
         double dirProfit= hasBuy ? CalcProfitByDir(1) : CalcProfitByDir(-1);
         double avgOpen  = hasBuy ? stat.buyAvgOpenPrice  : stat.sellAvgOpenPrice;
         string dirLabel = hasBuy ? "多" : "空";

         // 目标价: 多=avgOpen+AvgProfitTarget, 空=avgOpen-AvgProfitTarget
         double targetPrice = hasBuy ? (avgOpen + AvgProfitTarget)
                                     : (avgOpen - AvgProfitTarget);
         // 预期收益 = AvgProfitTarget × totalLot × perOz (USC)
         double expectedProfit = (perOz > 0) ? (AvgProfitTarget * totalLot * perOz) : 0;

         dirStr = StringFormat("%s: L%d/%d  手:%.2f  浮盈:%.2f  →目标:%.2f  预期:+%.2f",
                               dirLabel, cnt, MaxOrderCount, totalLot, dirProfit,
                               targetPrice, expectedProfit);
         dirCol = (dirProfit >= 0) ? clrLime : clrOrange;
      }
      CreateLbl(panelPfx+"d", 10, y, dirStr, dirCol); y += lh;
   }

   y += 4;
   CreateLbl(panelPfx+"bal", 10, y,
             StringFormat("余额:%.2f USC  总浮盈:%.2f", balance, totalP),
             totalP>=0?clrWhite:clrOrange); y += lh;

   // v1.9 [J]: 余额不足提示 (只提示, 不影响交易)
   if(Inp_MinBalanceUSC > 0 && balance < Inp_MinBalanceUSC)
   {
      CreateLbl(panelPfx+"balw", 10, y,
                StringFormat("[!] 余额 < %.0f USC, 参数按 600u 设计, 满层前可能被强平", Inp_MinBalanceUSC),
                clrRed);
      y += lh;
   }
   else if(ObjectFind(0, panelPfx+"balw") >= 0)
      ObjectDelete(0, panelPfx+"balw");

   CreateLbl(panelPfx+"spd", 10, y,
             StringFormat("点差:%d pt (阈值≤%d)", (int)spd, spdMax),
             spd>spdMax ? clrRed : clrWhite); y += lh;

   // 状态行 (优先级: 平仓失败/致命错误冻结 > 满层等待 > 周一开盘 > 暂停 > 新闻 > 点差 > 正常)
   string status = "运行中";
   color  stCol  = clrLime;
   int    waitRemain = MaxLayerWaitRemainMin(stat);   // v1.9 [E]

   if(emergencyFrozen)
   {
      if(g_closeFailMsg != "")
         status = "[FATAL] " + g_closeFailMsg + " 请人工干预";
      else
         status = "[!]致命错误冻结 (需重启 EA)";   // v1.9: 黑天鹅不再冻结, 只剩开仓致命错误
      stCol = clrRed;
   }
   else if(g_pendingBuy || g_pendingSell)
   {
      status = "[WAIT] 平仓暂缓 (市场关闭/算法交易关闭/报价问题), 每 tick 继续平";   // v1.9 [H]
      stCol = clrOrange;
   }
   else if(waitRemain >= 0)
   {
      status = StringFormat("[WAIT] 满层等待 剩 %d 分钟 (到 TP 止盈, 到点全平)", waitRemain);
      stCol = clrOrange;
   }
   else if(IsMonOpenBlock())
   {
      status = "[!] 周一开盘保护, 禁开新仓";
      stCol = clrOrange;
   }
   else if(pauseOpenUntil > 0 && TimeCurrent() < pauseOpenUntil)
   {
      int remainMin = (int)((pauseOpenUntil - TimeCurrent()) / 60) + 1;
      status = StringFormat("[PAUSE] 暂停开仓 剩 %d 分钟 (黑天鹅/满层平仓后)", remainMin);
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

   // v1.9 [H]: 上次有单暂缓没平完 → 优先继续平, 本 tick 不做其他事
   if(ProcessPendingClose(stat))
   {
      UpdatePanel();
      return;
   }

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

   //--- v1.9 [E]: 满层等待到点 / 硬止损 (与 TP 一样在保护门之前, 不受冻结/暂停/新闻/点差影响)
   if(CheckMaxLayerWait(stat))
   {
      UpdatePanel();
      return;
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

   // v1.9 [I]: 周一开盘保护 (不开仓不加仓, TP/满层到点已在上面处理)
   if(IsMonOpenBlock())
   {
      if(!lastMonBlocked && Inp_VerboseLog)
      {
         Print("[stable] [!] 周一开盘保护 (01:00 起 ", Inp_MonOpenBlockMin, " 分钟) → 禁开新仓");
         lastMonBlocked = true;
      }
      UpdatePanel();
      return;
   }
   else if(lastMonBlocked)
   {
      Print("[stable] [OK] 周一开盘保护结束, 恢复开仓");
      lastMonBlocked = false;
   }

   // v1.9 [F]: 深层篮子 (>= Inp_NoRotateLayer): 加仓不看信号, 不轮换, 不开反向单
   //   放在信号判断之前, 信号读取失败(sig==0)也不影响深层加仓
   //   有深层篮子时直接 return, 不进入下方 v1.8 原有的信号/轮换/加仓逻辑
   //   Inp_NoRotateLayer=0 时整段跳过, 行为与 v1.8 完全相同
   if(Inp_NoRotateLayer > 0)
   {
      bool deepBuy  = (stat.buyCnt  >= Inp_NoRotateLayer);
      bool deepSell = (stat.sellCnt >= Inp_NoRotateLayer);
      if(deepBuy || deepSell)
      {
         if(deepBuy)  TryAddDeepLayer( 1, stat.buyCnt);
         if(deepSell) TryAddDeepLayer(-1, stat.sellCnt);
         UpdatePanel();
         return;
      }
   }

   //--- 信号
   int sig = GetSignal();
   if(sig == 0) { UpdatePanel(); return; }

   // v1.8 [A]: 单向轮换——信号翻转时先平掉对向仓位
   if(sig == 1 && stat.sellCnt > 0)
   {
      Print("[stable] 信号翻多 → 先清空仓 L", stat.sellCnt,
            " 浮盈=", DoubleToString(CalcProfitByDir(-1), 2));
      CloseAllByDir(-1);
      GetPositionStat(stat);   // 刷新 stat
   }
   else if(sig == -1 && stat.buyCnt > 0)
   {
      Print("[stable] 信号翻空 → 先清多仓 L", stat.buyCnt,
            " 浮盈=", DoubleToString(CalcProfitByDir(1), 2));
      CloseAllByDir(1);
      GetPositionStat(stat);   // 刷新 stat
   }

   // v1.9 [H]: 对向仓位因暂缓/冻结没平掉时, 本 tick 不开新方向, 避免多空同时持仓
   if((sig == 1 && stat.sellCnt > 0) || (sig == -1 && stat.buyCnt > 0))
   {
      UpdatePanel();
      return;
   }

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
