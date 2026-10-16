//+------------------------------------------------------------------+
//|                                                     回光返照.mq5 |
//|                                                      Version 1.0 |
//|                                                                  |
//|  策略: 多周期 MACD 投票 + RSI 过滤 → 逆低周期假突破              |
//|                                                                  |
//|  核心思路 (sell the rip / buy the dip):                          |
//|    触发周期(M3) 出现金叉(短线想反弹), 但高周期全是死叉(大势向下) |
//|    → 判定这是"回光返照"假突破 → 在金叉处反手做空                 |
//|    对称: 触发周期死叉 + 高周期全金叉 → 假破位 → 做多             |
//|                                                                  |
//|  投票机制:                                                       |
//|    4 个高周期(M6/M12/M30/H1)各看 MACD 状态                       |
//|    做空: 统计"死叉状态(DIF<DEA)"的周期数 >= MinVoteCount        |
//|    做多: 统计"金叉状态(DIF>DEA)"的周期数 >= MinVoteCount        |
//|                                                                  |
//|  入场时机 (EntryMode):                                           |
//|    0=CONFIRM  等触发周期 bar[1] 真金叉/死叉成立 (信号少, 稳)     |
//|    1=ANTICIPATE 柱收敛将穿零轴即入场 (信号多, 抢, 可能被插针)    |
//|                                                                  |
//|  RSI 过滤 (可开关): 做空需 RSI 在 [ShortMin,ShortMax] 带内       |
//|    太低=还没反弹不该空; 太高=动能强可能真反转, 都过滤掉          |
//|                                                                  |
//|  仓位: 单笔, 带 SL/TP (USD/oz 距离), 不加仓不马丁               |
//|                                                                  |
//|  MT5 周期映射 (MT5 无 M24/M48 原生周期, 用近似并开放 input):     |
//|    3min→M3, 6min→M6, 12min→M12, 24min≈M30, 48min≈H1            |
//|    若需精确 24/48 几何序列, 后续出 M1 合成版 v1.1                |
//|                                                                  |
//|  v1.0 (2026-10-12): 初版                                         |
//+------------------------------------------------------------------+
#property copyright "回光返照"
#property version   "1.00"
#property description "回光返照 v1.0: 多周期MACD投票 逆低周期假突破 + RSI过滤"
#property strict

#include <Trade\Trade.mqh>

//============ 触发与投票周期 ============
input group "=== 触发与投票周期 ==="
input ENUM_TIMEFRAMES TF_Trigger = PERIOD_M3;   // 触发周期 (低周期信号源)
input ENUM_TIMEFRAMES TF_Vote1   = PERIOD_M6;   // 投票周期1 (原 6min)
input ENUM_TIMEFRAMES TF_Vote2   = PERIOD_M12;  // 投票周期2 (原 12min)
input ENUM_TIMEFRAMES TF_Vote3   = PERIOD_M30;  // 投票周期3 (原 24min ≈ M30)
input ENUM_TIMEFRAMES TF_Vote4   = PERIOD_H1;   // 投票周期4 (原 48min ≈ H1)
input int    MinVoteCount        = 4;           // 至少 X 个高周期同向死叉/金叉才入场 (1~4)

//============ 入场时机 ============
input group "=== 入场时机 ==="
input int    EntryMode        = 0;      // 0=CONFIRM真穿成立 1=ANTICIPATE将穿即抢
input double AnticipateThr    = 0.15;   // ANTICIPATE 模式: |MACD柱| <= 该值且收敛视为将穿 (XAU/M3 经验值, 需按品种调)

//============ MACD ============
input group "=== MACD 参数 ==="
input int    MACD_Fast   = 12;
input int    MACD_Slow   = 26;
input int    MACD_Signal = 9;

//============ RSI 过滤 ============
input group "=== RSI 过滤 (触发周期) ==="
input bool   UseRsiFilter = true;
input int    RSI_Period   = 14;
input double RSI_ShortMin = 50.0;   // 做空: RSI 下限 (低于此说明还没反弹, 不空)
input double RSI_ShortMax = 72.0;   // 做空: RSI 上限 (高于此动能太强可能真反转, 不空)
input double RSI_LongMin  = 28.0;   // 做多: RSI 下限
input double RSI_LongMax  = 50.0;   // 做多: RSI 上限

//============ 仓位与风控 ============
input group "=== 仓位与风控 ==="
input double Lots             = 0.01;   // 固定手数
input double SL_Usd           = 3.0;    // 止损距离 (USD/oz, 0=不设)
input double TP_Usd           = 5.0;    // 止盈距离 (USD/oz, 0=不设)
input bool   CloseOnOpposite  = true;   // 触发周期出现反向信号时提前平仓
input int    MagicNum         = 7799;
input int    Slippage         = 10;     // 允许滑点(points)

//============ 过滤与面板 ============
input group "=== 过滤与面板 ==="
input int    Inp_MaxSpread   = 60;      // 点差 > X 禁开新仓
input int    Inp_SpreadBuffer= 5;
input bool   Inp_ShowPanel   = true;
input bool   Inp_VerboseLog  = true;

//---- 全局
CTrade   trade;
int      hTrig   = INVALID_HANDLE;      // 触发周期 MACD 句柄
int      hVote[4];                      // 4 个投票周期 MACD 句柄
int      hRsi    = INVALID_HANDLE;      // 触发周期 RSI 句柄
datetime lastBarTime = 0;               // 触发周期 bar 去重 (每收一根只判一次)
string   panelPfx = "HgfzP_";

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
   if(MinVoteCount < 1 || MinVoteCount > 4)
   {
      Print("[回光返照] [X] MinVoteCount 必须在 1~4, 当前=", MinVoteCount);
      return INIT_FAILED;
   }

   // 触发周期 MACD + RSI
   hTrig = iMACD(_Symbol, TF_Trigger, MACD_Fast, MACD_Slow, MACD_Signal, PRICE_CLOSE);
   hRsi  = iRSI(_Symbol, TF_Trigger, RSI_Period, PRICE_CLOSE);

   // 4 投票周期 MACD
   ENUM_TIMEFRAMES voteTf[4] = {TF_Vote1, TF_Vote2, TF_Vote3, TF_Vote4};
   for(int i = 0; i < 4; i++)
      hVote[i] = iMACD(_Symbol, voteTf[i], MACD_Fast, MACD_Slow, MACD_Signal, PRICE_CLOSE);

   if(hTrig == INVALID_HANDLE || hRsi == INVALID_HANDLE)
   {
      Print("[回光返照] [X] 触发周期 MACD/RSI 句柄创建失败");
      return INIT_FAILED;
   }
   for(int i = 0; i < 4; i++)
      if(hVote[i] == INVALID_HANDLE)
      {
         Print("[回光返照] [X] 投票周期 ", i+1, " MACD 句柄创建失败");
         return INIT_FAILED;
      }

   trade.SetExpertMagicNumber(MagicNum);
   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFilling(DetectFilling());

   lastBarTime = 0;

   Print("=============================================");
   Print("=== 回光返照 v1.0 启动 ===");
   Print("触发周期=", EnumToString(TF_Trigger),
         "  投票周期=[", EnumToString(TF_Vote1), ",", EnumToString(TF_Vote2),
         ",", EnumToString(TF_Vote3), ",", EnumToString(TF_Vote4), "]",
         "  投票阈值≥", MinVoteCount, "/4");
   Print("入场模式=", EntryMode==0 ? "CONFIRM(真穿成立)" : "ANTICIPATE(将穿即抢)",
         EntryMode==1 ? StringFormat("  将穿阈值|柱|≤%.3f", AnticipateThr) : "");
   Print("MACD=", MACD_Fast, "/", MACD_Slow, "/", MACD_Signal,
         "  RSI过滤=", UseRsiFilter ? "开" : "关",
         UseRsiFilter ? StringFormat("  空带[%.0f,%.0f] 多带[%.0f,%.0f]",
                                     RSI_ShortMin, RSI_ShortMax, RSI_LongMin, RSI_LongMax) : "");
   Print("手数=", DoubleToString(Lots,2),
         "  SL=", DoubleToString(SL_Usd,2), "/oz",
         "  TP=", DoubleToString(TP_Usd,2), "/oz",
         "  反向平仓=", CloseOnOpposite ? "开" : "关");
   Print("Magic=", MagicNum, "  点差过滤>", Inp_MaxSpread + Inp_SpreadBuffer, "pt 禁开");
   Print("=============================================");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hTrig != INVALID_HANDLE) IndicatorRelease(hTrig);
   if(hRsi  != INVALID_HANDLE) IndicatorRelease(hRsi);
   for(int i = 0; i < 4; i++)
      if(hVote[i] != INVALID_HANDLE) IndicatorRelease(hVote[i]);
   ObjectsDeleteAll(0, panelPfx);
   Print("[回光返照] EA 停止, reason=", reason);
}

//+------------------------------------------------------------------+
//| 读某句柄 MACD 主线(DIF)/信号线(DEA) 指定 shift                     |
//+------------------------------------------------------------------+
bool MacdVals(int handle, int shift, double &dif, double &dea)
{
   double mainBuf[1], sigBuf[1];
   if(CopyBuffer(handle, 0, shift, 1, mainBuf) < 1) return false;
   if(CopyBuffer(handle, 1, shift, 1, sigBuf) < 1) return false;
   dif = mainBuf[0];
   dea = sigBuf[0];
   return true;
}

//+------------------------------------------------------------------+
//| 触发周期信号: 返回 +1=金叉(看多) -1=死叉(看空) 0=无               |
//|   CONFIRM:   bar[1] 真穿越 (hist 变号)                            |
//|   ANTICIPATE: hist 收敛且 |hist|<=阈值, 即将穿越                   |
//+------------------------------------------------------------------+
int TriggerSignal()
{
   double dif1, dea1, dif2, dea2;
   if(!MacdVals(hTrig, 1, dif1, dea1)) return 0;
   if(!MacdVals(hTrig, 2, dif2, dea2)) return 0;

   double hist1 = dif1 - dea1;   // 已收 bar[1] 的 MACD 柱
   double hist2 = dif2 - dea2;   // 前一根 bar[2]

   if(EntryMode == 0)
   {
      // CONFIRM: 真金叉 = 由下穿上; 真死叉 = 由上穿下
      if(hist1 > 0 && hist2 <= 0) return  1;   // 金叉
      if(hist1 < 0 && hist2 >= 0) return -1;   // 死叉
      return 0;
   }
   else
   {
      // ANTICIPATE: 尚未穿但在收敛且逼近零轴
      // 将金叉: 柱为负但在抬升且已很接近 0
      if(hist1 < 0 && hist1 > hist2 && MathAbs(hist1) <= AnticipateThr) return  1;
      // 将死叉: 柱为正但在回落且已很接近 0
      if(hist1 > 0 && hist1 < hist2 && MathAbs(hist1) <= AnticipateThr) return -1;
      return 0;
   }
}

//+------------------------------------------------------------------+
//| 投票: 统计 4 个高周期中处于指定状态(bar[1])的个数                 |
//|   wantBearish=true 统计死叉态(DIF<DEA), false 统计金叉态(DIF>DEA) |
//+------------------------------------------------------------------+
int CountVotes(bool wantBearish, string &detail)
{
   int cnt = 0;
   detail = "";
   for(int i = 0; i < 4; i++)
   {
      double dif, dea;
      if(!MacdVals(hVote[i], 1, dif, dea)) { detail += "?"; continue; }
      bool bearish = (dif < dea);
      if(bearish == wantBearish) { cnt++; detail += wantBearish ? "S" : "B"; }
      else                        detail += ".";
   }
   return cnt;
}

//+------------------------------------------------------------------+
double GetRsi()
{
   double buf[1];
   if(CopyBuffer(hRsi, 0, 1, 1, buf) < 1) return -1.0;
   return buf[0];
}

//+------------------------------------------------------------------+
bool RsiOkForShort(double rsi)
{
   if(!UseRsiFilter) return true;
   if(rsi < 0) return false;
   return (rsi >= RSI_ShortMin && rsi <= RSI_ShortMax);
}

bool RsiOkForLong(double rsi)
{
   if(!UseRsiFilter) return true;
   if(rsi < 0) return false;
   return (rsi >= RSI_LongMin && rsi <= RSI_LongMax);
}

//+------------------------------------------------------------------+
//| 本 EA 当前方向持仓: 0=无 1=多 -1=空                              |
//+------------------------------------------------------------------+
int CurrentPosDir()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNum) continue;
      long ptype = PositionGetInteger(POSITION_TYPE);
      return (ptype == POSITION_TYPE_BUY) ? 1 : -1;
   }
   return 0;
}

//+------------------------------------------------------------------+
void ClosePos()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNum) continue;
      double prof = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(trade.PositionClose(ticket))
         Print("[回光返照] << 反向信号平仓 ticket=", ticket, " 浮盈=", DoubleToString(prof,2));
      else
         Print("[回光返照] 平仓失败 ticket=", ticket, " err=", trade.ResultRetcode());
   }
}

//+------------------------------------------------------------------+
//| 开仓 dir: 1=多 -1=空, 带 SL/TP (USD/oz 距离)                      |
//+------------------------------------------------------------------+
bool OpenPos(int dir, int voteCnt, double rsi, string voteDetail)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double price = (dir == 1) ? ask : bid;

   double sl = 0, tp = 0;
   if(dir == 1)
   {
      if(SL_Usd > 0) sl = price - SL_Usd;
      if(TP_Usd > 0) tp = price + TP_Usd;
   }
   else
   {
      if(SL_Usd > 0) sl = price + SL_Usd;
      if(TP_Usd > 0) tp = price - TP_Usd;
   }

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(sl > 0) sl = NormalizeDouble(sl, digits);
   if(tp > 0) tp = NormalizeDouble(tp, digits);

   string cmt = StringFormat("hgfz_%s_v%d", dir==1?"B":"S", voteCnt);
   bool ok = (dir == 1) ? trade.Buy(Lots, _Symbol, price, sl, tp, cmt)
                        : trade.Sell(Lots, _Symbol, price, sl, tp, cmt);
   if(ok)
      Print("[回光返照] >> 开", dir==1?"多(假破位)":"空(回光返照)",
            "  价=", DoubleToString(price,digits),
            "  SL=", DoubleToString(sl,digits), "  TP=", DoubleToString(tp,digits),
            "  投票=", voteDetail, "(", voteCnt, "/4)",
            "  RSI=", DoubleToString(rsi,1));
   else
      Print("[回光返照] [X] 开仓失败 dir=", dir,
            " rc=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   return ok;
}

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

void UpdatePanel(int trigSig, int voteBear, int voteBull, double rsi)
{
   if(!Inp_ShowPanel) return;
   int y = 30, lh = 18;

   CreateLbl(panelPfx+"t", 10, y, "=== 回光返照 v1.0 ===", clrGold); y += lh + 4;

   int dir = CurrentPosDir();
   string posStr = (dir==0) ? "持仓: 无"
                            : StringFormat("持仓: %s", dir==1?"多":"空");
   CreateLbl(panelPfx+"pos", 10, y, posStr,
             dir==0 ? clrGray : (dir==1?clrLime:clrAqua)); y += lh;

   string trigStr = StringFormat("触发(%s): %s", EnumToString(TF_Trigger),
                                 trigSig==1?"金叉↑":(trigSig==-1?"死叉↓":"无"));
   CreateLbl(panelPfx+"trig", 10, y, trigStr,
             trigSig==1?clrLime:(trigSig==-1?clrOrange:clrGray)); y += lh;

   CreateLbl(panelPfx+"vote", 10, y,
             StringFormat("高周期票: 死叉%d / 金叉%d  (阈值≥%d)", voteBear, voteBull, MinVoteCount),
             clrWhite); y += lh;

   CreateLbl(panelPfx+"rsi", 10, y,
             StringFormat("RSI(%s)=%.1f  过滤=%s", EnumToString(TF_Trigger),
                          rsi, UseRsiFilter?"开":"关"),
             clrWhite); y += lh;

   long spd = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   int  spdMax = Inp_MaxSpread + Inp_SpreadBuffer;
   CreateLbl(panelPfx+"spd", 10, y,
             StringFormat("点差:%d pt (≤%d)", (int)spd, spdMax),
             spd>spdMax?clrRed:clrWhite);

   ChartRedraw();
}

//+------------------------------------------------------------------+
void OnTick()
{
   // 每根触发周期 bar 只判一次 (取已收 bar[1], 避免未收 bar 抖动)
   datetime curBar = iTime(_Symbol, TF_Trigger, 0);
   bool newBar = (curBar != lastBarTime);

   int    trigSig = TriggerSignal();
   string voteBearDetail, voteBullDetail;
   int    voteBear = CountVotes(true,  voteBearDetail);   // 死叉态数
   int    voteBull = CountVotes(false, voteBullDetail);   // 金叉态数
   double rsi      = GetRsi();

   // 面板每 tick 刷新
   UpdatePanel(trigSig, voteBear, voteBull, rsi);

   if(!newBar) return;
   lastBarTime = curBar;

   int posDir = CurrentPosDir();

   //--- 反向信号提前平仓
   if(CloseOnOpposite && posDir != 0 && trigSig != 0 && trigSig == posDir)
   {
      // 持空(posDir=-1)时出现死叉(trigSig=-1)=顺势不平; 出现金叉(+1)与空仓反向→平
      // 持多(posDir=+1)时出现金叉(+1)=顺势不平; 出现死叉(-1)与多仓反向→平
      // 注意: 本策略方向与 trigSig 相反(金叉→做空), 故 trigSig==posDir 实为反向
      ClosePos();
      posDir = 0;
   }

   //--- 已有持仓不再开新仓 (单笔策略)
   if(posDir != 0) return;

   //--- 开仓前过滤
   if(trigSig == 0) return;
   if(!IsSpreadOK())
   {
      if(Inp_VerboseLog)
         Print("[回光返照] [!] 点差过大, 跳过本次信号");
      return;
   }

   //--- 触发金叉 + 高周期多数死叉 → 假突破 → 做空
   if(trigSig == 1 && voteBear >= MinVoteCount)
   {
      if(RsiOkForShort(rsi))
         OpenPos(-1, voteBear, rsi, voteBearDetail);
      else if(Inp_VerboseLog)
         Print("[回光返照] 触发金叉+死叉票", voteBear, "/4 达标, 但 RSI=",
               DoubleToString(rsi,1), " 不在空带[", DoubleToString(RSI_ShortMin,0),
               ",", DoubleToString(RSI_ShortMax,0), "] → 放弃");
   }
   //--- 触发死叉 + 高周期多数金叉 → 假破位 → 做多
   else if(trigSig == -1 && voteBull >= MinVoteCount)
   {
      if(RsiOkForLong(rsi))
         OpenPos(1, voteBull, rsi, voteBullDetail);
      else if(Inp_VerboseLog)
         Print("[回光返照] 触发死叉+金叉票", voteBull, "/4 达标, 但 RSI=",
               DoubleToString(rsi,1), " 不在多带[", DoubleToString(RSI_LongMin,0),
               ",", DoubleToString(RSI_LongMax,0), "] → 放弃");
   }
}
//+------------------------------------------------------------------+
