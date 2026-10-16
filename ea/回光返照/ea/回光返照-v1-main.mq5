//+------------------------------------------------------------------+
//|                                            回光返照-v1-main.mq5 |
//|                                                      Version 2.0 |
//|                                                                  |
//|  策略: 多周期 MACD 投票 逆低周期假突破 (无RSI) + 对称复利        |
//|                                                                  |
//|  === 版本 #1 主力 (confirm + TRAIL10) ===                        |
//|  来源: v3_full 全维度网格样本外最均衡配置                        |
//|    native L9 / 顶3一致+余5/6 / 确认入场 / TRAIL10 / 硬SL10        |
//|    回测(2024-09~2026-09, 税后$0.1): 565笔 train PF1.21 test1.40  |
//|                                                                  |
//|  逻辑:                                                           |
//|    触发 M3 bar[1] 金叉, 且 9 高周期多数死叉 → 假突破 → 做空      |
//|    对称: M3 死叉 + 高周期多数金叉 → 假破位 → 做多                |
//|    投票结构: 顶3(H8/H12/D1)必须全同向 + 余6(M6/M12/M30/H1/H2/H4) |
//|              至少 5/6 同向                                        |
//|    出场: 硬止损 $10 + 盈利后跟踪止损(距 TRAIL_DIST), 无固定TP    |
//|    仓位: 对称复利, equity 每翻倍手数翻倍 (从实时equity现算)      |
//|                                                                  |
//|  v2.0 (2026-10-16): 按 v3 研究结论重写 (投票结构/TRAIL/复利)     |
//|  v1.0 (2026-10-12): 初版(4近似周期+RSI, 已废弃)                  |
//+------------------------------------------------------------------+
#property copyright "回光返照"
#property version   "2.00"
#property description "回光返照 v2.0 #1主力: M3触发 9周期投票(顶3一致) 确认入场 TRAIL10 对称复利"
#property strict

#include <Trade\Trade.mqh>

//============ 版本标识 (三个版本仅此块不同, 不作为运行时参数) ======
#define VER_TAG       "v1-main"
#define ENTRY_MODE    0        // 0=确认(真穿越)  1=抢(将穿)
#define TRAIL_DIST    10.0     // 跟踪止损距离 (USD/oz)
#define DEF_MAGIC     7801

//============ 触发/投票周期 ============
input group "=== 周期 (勿改, 对应回测配置) ==="
input ENUM_TIMEFRAMES TF_Trigger = PERIOD_M3;   // 触发周期 (EA 必须挂此周期图表)

//============ MACD ============
input group "=== MACD ==="
input int    MACD_Fast   = 12;
input int    MACD_Slow   = 26;
input int    MACD_Signal = 9;

//============ 投票结构 ============
input group "=== 投票 (顶3一致 + 余6门槛) ==="
input int    Inp_RestMinVotes = 5;    // 余6周期至少几票同向 (回测=5)

//============ 入场(抢)参数 ============
input group "=== 入场(抢模式才用) ==="
input double Inp_AnticipateThr = 0.15;  // |MACD柱|<=该值且收敛视为将穿 (仅 ENTRY_MODE=1 生效)

//============ 风控/出场 ============
input group "=== 出场 & 风控 ==="
input double Inp_HardSL   = 10.0;   // 硬止损 (USD/oz)
input int    Inp_Slippage = 10;     // 允许滑点(points)

//============ 对称复利 ============
input group "=== 对称复利 (equity翻倍→手数翻倍) ==="
input double Inp_BaseCap  = 200.0;  // 基准本金(USD): equity每到其 2^n 倍, 手数=BaseLot×2^n
input double Inp_BaseLot  = 0.01;   // 基础手数 (equity=BaseCap 时的手数)

//============ 过滤 & 面板 ============
input group "=== 点差 & 面板 ==="
input int    Inp_MaxSpread    = 60;   // 点差 > X+buffer 禁开新仓
input int    Inp_SpreadBuffer = 5;
input int    MagicNum         = DEF_MAGIC;
input bool   Inp_ShowPanel    = true;
input bool   Inp_VerboseLog   = true;

//---- 投票周期: 固定 9 个 MT5 原生周期 (index 0..5=余6, 6..8=顶3) ----
ENUM_TIMEFRAMES g_voteTf[9] = {PERIOD_M6, PERIOD_M12, PERIOD_M30,
                               PERIOD_H1, PERIOD_H2, PERIOD_H4,
                               PERIOD_H8, PERIOD_H12, PERIOD_D1};
string g_voteName[9]        = {"M6","M12","M30","H1","H2","H4","H8","H12","D1"};
#define TOP_START 6     // 顶3 = index 6,7,8

//---- 全局
CTrade   trade;
int      hTrig = INVALID_HANDLE;
int      hVote[9];
datetime lastBarTime = 0;
int      lastTrigSig = 0;      // 上次打印的触发信号(节流用)
string   panelPfx = "HgfzV1_";

// 持仓跟踪状态 (跟踪止损用)
bool     g_hasPos  = false;
int      g_dir     = 0;        // 1=多 -1=空
double   g_entry   = 0;
double   g_best    = 0;        // 持仓期间最优价(多:最高 空:最低)
bool     g_trailOn = false;

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
   // 挂图周期校验: 必须等于配置的触发周期 (按配置, 不写死)
   if(Period() != TF_Trigger)
   {
      Print("[回光返照-", VER_TAG, "] [X] 当前图表周期=", EnumToString((ENUM_TIMEFRAMES)Period()),
            ", 必须挂在 ", EnumToString(TF_Trigger), " 图表, EA 停止");
      Alert("[回光返照] EA 必须挂在 ", EnumToString(TF_Trigger), " 图表");
      return INIT_FAILED;
   }

   if(Inp_RestMinVotes < 0 || Inp_RestMinVotes > 6)
   {
      Print("[回光返照-", VER_TAG, "] [X] Inp_RestMinVotes 须在 0~6, 当前=", Inp_RestMinVotes);
      return INIT_FAILED;
   }

   hTrig = iMACD(_Symbol, TF_Trigger, MACD_Fast, MACD_Slow, MACD_Signal, PRICE_CLOSE);
   if(hTrig == INVALID_HANDLE) { Print("[回光返照] [X] 触发MACD句柄失败"); return INIT_FAILED; }
   for(int i = 0; i < 9; i++)
   {
      hVote[i] = iMACD(_Symbol, g_voteTf[i], MACD_Fast, MACD_Slow, MACD_Signal, PRICE_CLOSE);
      if(hVote[i] == INVALID_HANDLE)
      { Print("[回光返照] [X] 投票MACD句柄失败 ", g_voteName[i]); return INIT_FAILED; }
   }

   trade.SetExpertMagicNumber(MagicNum);
   trade.SetDeviationInPoints(Inp_Slippage);
   trade.SetTypeFilling(DetectFilling());

   lastBarTime  = 0;
   lastTrigSig  = 0;

   // 账户模式 (仅告知, 本策略单仓, Netting/Hedging 均可)
   long mm = AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   string mmStr = (mm==ACCOUNT_MARGIN_MODE_RETAIL_HEDGING) ? "Hedging"
                : (mm==ACCOUNT_MARGIN_MODE_RETAIL_NETTING) ? "Netting" : "Exchange";

   // 启动状态对齐: 若已有本magic持仓, 接管并重建跟踪状态
   RebuildPositionState();

   Print("=============================================");
   Print("=== 回光返照 ", VER_TAG, " v2.0 启动 ===");
   Print("入场=", ENTRY_MODE==0 ? "确认(真穿越)" : "抢(将穿)",
         "  跟踪止损距=", DoubleToString(TRAIL_DIST,1),
         "  硬止损=", DoubleToString(Inp_HardSL,1));
   Print("触发=", EnumToString(TF_Trigger),
         "  投票9周期: 顶3[H8/H12/D1]全一致 + 余6至少", Inp_RestMinVotes, "票");
   Print("对称复利: 基准本金=", DoubleToString(Inp_BaseCap,0), "USD  基础手数=",
         DoubleToString(Inp_BaseLot,2), "  当前equity=",
         DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY),2),
         " → 本次应下 ", DoubleToString(CalcCompoundLot(),2), " 手");
   Print("Magic=", MagicNum, "  账户模式=", mmStr, " (单仓策略, 该模式均可)",
         "  点差上限=", Inp_MaxSpread+Inp_SpreadBuffer, "pt");
   if(g_hasPos)
      Print("[对齐] 接管已有持仓: ", g_dir==1?"多":"空",
            " 开仓价=", DoubleToString(g_entry,2),
            " 跟踪=", g_trailOn?"已激活":"未激活");
   Print("=============================================");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hTrig != INVALID_HANDLE) IndicatorRelease(hTrig);
   for(int i = 0; i < 9; i++)
      if(hVote[i] != INVALID_HANDLE) IndicatorRelease(hVote[i]);
   ObjectsDeleteAll(0, panelPfx);
   Print("[回光返照-", VER_TAG, "] EA 停止, reason=", reason);
}

//+------------------------------------------------------------------+
//| 对称复利手数: equity 每翻倍手数翻倍, 从实时 equity 现算          |
//+------------------------------------------------------------------+
double CalcCompoundLot()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity <= 0 || Inp_BaseCap <= 0) return NormalizeLot(Inp_BaseLot);
   double ratio = equity / Inp_BaseCap;
   int level = 0;
   if(ratio >= 1.0) level = (int)MathFloor(MathLog(ratio) / MathLog(2.0));
   if(level < 0) level = 0;
   double lot = Inp_BaseLot * MathPow(2.0, level);
   return NormalizeLot(lot);
}

int CalcCompoundLevel()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity <= 0 || Inp_BaseCap <= 0) return 0;
   double ratio = equity / Inp_BaseCap;
   if(ratio < 1.0) return 0;
   int level = (int)MathFloor(MathLog(ratio) / MathLog(2.0));
   return (level < 0) ? 0 : level;
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
   lotVal = MathMin(lotVal, maxLot);   // 天然封顶: broker 手数上限
   lotVal = NormalizeDouble(lotVal, 2);
   if(lotVal < minLot) lotVal = minLot;
   return lotVal;
}

//+------------------------------------------------------------------+
//| 读句柄 MACD 柱(DIF-DEA) 指定 shift                               |
//+------------------------------------------------------------------+
bool MacdHist(int handle, int shift, double &hist)
{
   double m[1], s[1];
   if(CopyBuffer(handle, 0, shift, 1, m) < 1) return false;
   if(CopyBuffer(handle, 1, shift, 1, s) < 1) return false;
   hist = m[0] - s[0];
   return true;
}

//+------------------------------------------------------------------+
//| 触发信号: +1=金叉(看多) -1=死叉(看空) 0=无 (取已收 bar[1])        |
//+------------------------------------------------------------------+
int TriggerSignal()
{
   double h1, h2;
   if(!MacdHist(hTrig, 1, h1)) return 0;
   if(!MacdHist(hTrig, 2, h2)) return 0;
   // ENTRY_MODE 是 #define 常量, 用运行时 if (编译器常量折叠); MQL5 不支持 #if 表达式
   if(ENTRY_MODE == 0)
   {
      if(h1 > 0 && h2 <= 0) return  1;   // 真金叉
      if(h1 < 0 && h2 >= 0) return -1;   // 真死叉
   }
   else
   {
      if(h1 < 0 && h1 > h2 && MathAbs(h1) <= Inp_AnticipateThr) return  1;  // 将金叉
      if(h1 > 0 && h1 < h2 && MathAbs(h1) <= Inp_AnticipateThr) return -1;  // 将死叉
   }
   return 0;
}

//+------------------------------------------------------------------+
//| 投票: 统计 9 周期中处于指定状态(bar[1])的 (顶3是否全一致, 余6票数)|
//|  wantBearish=true 统计死叉态(DIF<DEA)                            |
//+------------------------------------------------------------------+
bool CountVotes(bool wantBearish, bool &topAgree, int &restCnt, string &detail)
{
   topAgree = true; restCnt = 0; detail = "";
   for(int i = 0; i < 9; i++)
   {
      double h;
      if(!MacdHist(hVote[i], 1, h)) { detail += "?"; topAgree = false; continue; }
      bool bearish = (h < 0);
      bool match = (bearish == wantBearish);
      if(i >= TOP_START)   // 顶3
      {
         if(!match) topAgree = false;
         detail += match ? "T" : "t";
      }
      else                 // 余6
      {
         if(match) restCnt++;
         detail += match ? "R" : ".";
      }
   }
   return topAgree;
}

//+------------------------------------------------------------------+
int CurrentPosDir()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNum) continue;
      return (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY) ? 1 : -1;
   }
   return 0;
}

//+------------------------------------------------------------------+
//| 启动对齐: 若有本magic持仓, 重建跟踪状态(从持仓SL反推)            |
//+------------------------------------------------------------------+
void RebuildPositionState()
{
   g_hasPos = false; g_dir = 0; g_entry = 0; g_best = 0; g_trailOn = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNum) continue;

      g_hasPos = true;
      g_dir    = (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY) ? 1 : -1;
      g_entry  = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL = PositionGetDouble(POSITION_SL);

      // 反推跟踪状态: 多单跟踪SL在开仓价上方; 空单在下方
      if(g_dir == 1)
      {
         if(curSL > g_entry + _Point) { g_trailOn = true; g_best = curSL + TRAIL_DIST; }
         else                         { g_trailOn = false; g_best = g_entry; }
      }
      else
      {
         if(curSL > 0 && curSL < g_entry - _Point) { g_trailOn = true; g_best = curSL - TRAIL_DIST; }
         else                                      { g_trailOn = false; g_best = g_entry; }
      }

      // 手数档位连续性检查 (开开停停): 只告警, 不强平
      double posLot = PositionGetDouble(POSITION_VOLUME);
      double tgtLot = CalcCompoundLot();
      if(MathAbs(posLot - tgtLot) >= SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP))
         Print("[回光返照-", VER_TAG, "] [对齐] 持仓手数=", DoubleToString(posLot,2),
               " 与当前equity档位手数=", DoubleToString(tgtLot,2),
               " 不一致 → 保留当前仓跑完, 下一单用新档位");
      return;
   }
}

//+------------------------------------------------------------------+
bool IsSpreadOK()
{
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return (spread <= Inp_MaxSpread + Inp_SpreadBuffer);
}

//+------------------------------------------------------------------+
//| 开仓 (对称复利手数, 设硬止损; TRAIL 模式不设固定TP)              |
//+------------------------------------------------------------------+
bool OpenPos(int dir, string voteDetail, int restCnt)
{
   double lots = CalcCompoundLot();
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double price = (dir == 1) ? ask : bid;
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   double sl = (dir == 1) ? price - Inp_HardSL : price + Inp_HardSL;
   sl = NormalizeDouble(sl, digits);

   string cmt = StringFormat("hgfz_%s_%s_L%d", VER_TAG, dir==1?"B":"S", CalcCompoundLevel());
   bool ok = (dir == 1) ? trade.Buy(lots, _Symbol, price, sl, 0, cmt)
                        : trade.Sell(lots, _Symbol, price, sl, 0, cmt);
   if(ok)
   {
      g_hasPos = true; g_dir = dir; g_entry = price;
      g_best = price; g_trailOn = false;
      Print("[回光返照-", VER_TAG, "] >> 开", dir==1?"多(假破位)":"空(回光返照)",
            "  手数=", DoubleToString(lots,2),
            " (复利L", CalcCompoundLevel(), " equity=",
            DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY),2), ")",
            "  价=", DoubleToString(price,digits),
            "  硬SL=", DoubleToString(sl,digits),
            "  投票[", voteDetail, "] 余6=", restCnt, "/6");
   }
   else
      Print("[回光返照-", VER_TAG, "] [X] 开仓失败 dir=", dir,
            " rc=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   return ok;
}

//+------------------------------------------------------------------+
//| 跟踪止损管理 (每 tick): 更新最优价, 达激活阈值后只收紧 SL        |
//+------------------------------------------------------------------+
void ManageTrailing()
{
   if(!g_hasPos) return;
   // 找持仓 ticket + 当前 SL
   ulong ticket = 0; double curSL = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNum) continue;
      ticket = tk; curSL = PositionGetDouble(POSITION_SL); break;
   }
   if(ticket == 0) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   if(g_dir == 1)   // 多: 最优=最高, 用 bid 衡量盈利
   {
      if(bid > g_best) g_best = bid;
      if(!g_trailOn && (g_best - g_entry) >= TRAIL_DIST) g_trailOn = true;
      if(g_trailOn)
      {
         double newSL = NormalizeDouble(g_best - TRAIL_DIST, digits);
         if(newSL > curSL + _Point)   // 只上移(收紧)
            trade.PositionModify(ticket, newSL, 0);
      }
   }
   else             // 空: 最优=最低, 用 ask 衡量盈利
   {
      if(g_best == 0 || ask < g_best) g_best = ask;
      if(!g_trailOn && (g_entry - g_best) >= TRAIL_DIST) g_trailOn = true;
      if(g_trailOn)
      {
         double newSL = NormalizeDouble(g_best + TRAIL_DIST, digits);
         if(curSL == 0 || newSL < curSL - _Point)   // 只下移(收紧)
            trade.PositionModify(ticket, newSL, 0);
      }
   }
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

void UpdatePanel(int trigSig, bool topBear, int restBear, bool topBull, int restBull)
{
   if(!Inp_ShowPanel) return;
   int y = 30, lh = 18;
   CreateLbl(panelPfx+"t", 10, y, "=== 回光返照 "+VER_TAG+" v2.0 ===", clrGold); y += lh+4;

   string posStr = (!g_hasPos) ? "持仓: 无"
                 : StringFormat("持仓: %s 开%.2f %s", g_dir==1?"多":"空", g_entry,
                                g_trailOn?"[跟踪中]":"[硬SL]");
   CreateLbl(panelPfx+"pos", 10, y, posStr,
             !g_hasPos?clrGray:(g_dir==1?clrLime:clrAqua)); y += lh;

   CreateLbl(panelPfx+"cl", 10, y,
             StringFormat("复利: L%d  手数%.2f  equity %.0f (基准%.0f)",
                          CalcCompoundLevel(), CalcCompoundLot(),
                          AccountInfoDouble(ACCOUNT_EQUITY), Inp_BaseCap), clrWhite); y += lh;

   CreateLbl(panelPfx+"trig", 10, y,
             StringFormat("触发(%s): %s", EnumToString(TF_Trigger),
                          trigSig==1?"金叉↑":(trigSig==-1?"死叉↓":"无")),
             trigSig==1?clrLime:(trigSig==-1?clrOrange:clrGray)); y += lh;

   CreateLbl(panelPfx+"v1", 10, y,
             StringFormat("空票: 顶3%s 余6=%d/6", topBear?"全一致":"不齐", restBear),
             (topBear&&restBear>=Inp_RestMinVotes)?clrOrange:clrGray); y += lh;
   CreateLbl(panelPfx+"v2", 10, y,
             StringFormat("多票: 顶3%s 余6=%d/6", topBull?"全一致":"不齐", restBull),
             (topBull&&restBull>=Inp_RestMinVotes)?clrLime:clrGray); y += lh;

   long spd = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   CreateLbl(panelPfx+"spd", 10, y,
             StringFormat("点差:%d pt (≤%d)", (int)spd, Inp_MaxSpread+Inp_SpreadBuffer),
             spd>Inp_MaxSpread+Inp_SpreadBuffer?clrRed:clrWhite);
   ChartRedraw();
}

//+------------------------------------------------------------------+
void OnTick()
{
   // 1. 同步持仓(可能被 SL 平掉)
   int curDir = CurrentPosDir();
   if(g_hasPos && curDir == 0)
   {
      Print("[回光返照-", VER_TAG, "] << 持仓已平(SL/跟踪止损触发)");
      g_hasPos = false; g_trailOn = false; g_dir = 0;
   }

   // 2. 跟踪止损管理 (每 tick)
   ManageTrailing();

   // 3. 读信号/投票 (用于面板, 每 tick 刷新)
   int trigSig = TriggerSignal();
   bool topBear, topBull; int restBear, restBull; string dB, dL;
   CountVotes(true,  topBear, restBear, dB);
   CountVotes(false, topBull, restBull, dL);
   UpdatePanel(trigSig, topBear, restBear, topBull, restBull);

   // 4. 只在新 M3 bar 评估开仓
   datetime curBar = iTime(_Symbol, TF_Trigger, 0);
   if(curBar == lastBarTime) return;
   lastBarTime = curBar;

   // 已有持仓: 单仓策略, 不开新仓
   if(g_hasPos || curDir != 0) return;
   if(trigSig == 0) return;

   // 信号出现时打印完整投票态 (便于和回测核对)
   if(Inp_VerboseLog && trigSig != lastTrigSig)
   {
      Print("[回光返照-", VER_TAG, "] 触发", trigSig==1?"金叉":"死叉",
            " | 空[顶3", topBear?"√":"×", " 余", restBear, "/6]",
            " 多[顶3", topBull?"√":"×", " 余", restBull, "/6]  (格式 T/t=顶3中/不中 R/.=余6中/不中)");
      lastTrigSig = trigSig;
   }

   if(!IsSpreadOK()) return;

   // 5. 决策: 金叉+高周期死叉→空 ; 死叉+高周期金叉→多
   if(trigSig == 1 && topBear && restBear >= Inp_RestMinVotes)
      OpenPos(-1, dB, restBear);
   else if(trigSig == -1 && topBull && restBull >= Inp_RestMinVotes)
      OpenPos(1, dL, restBull);
}
//+------------------------------------------------------------------+
