//+------------------------------------------------------------------+
//|                                              美分马丁-stable.mq5 |
//|                                                      Version 1.1 |
//|                                                                  |
//|  v1.1 变更 (vs v1.0):                                             |
//|    + 黑天鹅熔断: M1 波动>=$20 触发, 全平+冻结+警报                |
//|      (但浮亏率 >= 账户余额 25% 时保留持仓, 只冻结不平)            |
//|    + 点差保护: 超阈值禁开新仓, 面板实时显示                       |
//|    + 新闻过滤: FOMC / CPI / PPI / NFP 前后 30min 禁开新仓         |
//|    + 面板 HUD: 层数/浮盈/点差/新闻/冻结状态                       |
//|    + 完整日志: 开仓/加仓/平仓/保护触发全部落 Print                |
//|                                                                  |
//|  v1.0 (2026-09-01): 基于 MT4 参照策略迁移到 MT5, MultiAfter4=1.3  |
//|                                                                  |
//|  策略骨架:                                                        |
//|    - M15 MA20/MA50 双均线方向信号                                 |
//|    - 前 4 单固定 [0.01, 0.02, 0.03, 0.04]                        |
//|    - 第 5 单起 = 上一单 × MultiAfter4 (默认 1.3)                  |
//|    - 平均浮亏 >= $2/oz 触发加仓                                   |
//|    - 平均浮盈 >= $0.6/oz 平该方向全部                             |
//|    - 每方向最多 12 单                                             |
//|    - 允许多空共存 (需 Hedging 账户)                               |
//+------------------------------------------------------------------+
#property copyright "美分马丁-stable"
#property version   "1.10"
#property description "美分马丁-stable v1.1 (黑天鹅+点差+新闻+面板+日志)"
#property strict

#include <Trade\Trade.mqh>

//============ 策略参数 ============
input group "=== 策略核心 ==="
input ENUM_TIMEFRAMES SignalTimeFrame = PERIOD_M15;    // 判断方向周期
input double LossPriceGap    = 2.0;                    // 加仓浮亏阈值(美金)
input double AvgProfitTarget = 0.6;                    // 平仓浮盈阈值(美金)
input int    MaxOrderCount   = 12;                     // 每方向最大层数
input double MultiAfter4     = 1.3;                    // 第5单起加仓倍数
input int    MagicNum        = 8866;
input int    Slippage        = 10;                     // 允许滑点(points)

//============ 保护参数 ============
input group "=== 黑天鹅熔断 ==="
input bool   Inp_BlackSwan      = true;                // 启用黑天鹅熔断
input double Inp_BlackSwanRange = 20.0;                // M1 波动>=$X 触发
input double Inp_MaxCloseLossPct= 25.0;                // 浮亏率<X%才敢强平

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

//---- 全局
CTrade   trade;
int      maFastHandle = INVALID_HANDLE;
int      maSlowHandle = INVALID_HANDLE;
bool     emergencyFrozen = false;
bool     lastNewsBlocked = false;
bool     lastSpreadHi    = false;
string   panelPfx = "StableP_";

double fixedLotArr[] = {0.01, 0.02, 0.03, 0.04};

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
   // Hedging 校验 (关键: Netting 账户策略跑不了)
   long marginMode = AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(marginMode != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Print("[stable] ❌ 账户不是 Hedging 模式 (当前=", marginMode,
            "), 多空共存无法工作, EA 停止");
      return INIT_FAILED;
   }

   maFastHandle = iMA(_Symbol, SignalTimeFrame, 20, 0, MODE_SMA, PRICE_CLOSE);
   maSlowHandle = iMA(_Symbol, SignalTimeFrame, 50, 0, MODE_SMA, PRICE_CLOSE);
   if(maFastHandle == INVALID_HANDLE || maSlowHandle == INVALID_HANDLE)
   {
      Print("[stable] ❌ MA 句柄创建失败");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(MagicNum);
   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFilling(DetectFilling());

   emergencyFrozen = false;
   lastNewsBlocked = false;
   lastSpreadHi    = false;

   Print("=============================================");
   Print("=== 美分马丁-stable v1.1 启动 ===");
   Print("信号周期=", EnumToString(SignalTimeFrame),
         "  加仓浮亏=$", LossPriceGap,
         "  平仓浮盈=$", AvgProfitTarget);
   Print("首4单=[0.01,0.02,0.03,0.04]  L5+倍率=", MultiAfter4,
         "  最大层数=", MaxOrderCount);
   Print("[保护] 黑天鹅=", Inp_BlackSwan ? "开" : "关",
         "(M1>$", Inp_BlackSwanRange, ", 平仓阈值<", Inp_MaxCloseLossPct, "%)");
   Print("[保护] 点差过滤: >", Inp_MaxSpread + Inp_SpreadBuffer, " pt 禁开");
   Print("[保护] 新闻过滤=", Inp_NewsFilter ? "开" : "关",
         "  前", Inp_NewsMinBefore, "min / 后", Inp_NewsMinAfter, "min");
   Print("Magic=", MagicNum, "  账户模式=Hedging ✅");

   // 首次尝试读日历,验证 Calendar API 是否可用
   if(Inp_NewsFilter)
   {
      MqlCalendarValue tmp[];
      int n = CalendarValueHistory(tmp, TimeCurrent(), TimeCurrent() + 7*86400, "US");
      if(n < 0)
         Print("[stable] ⚠ Calendar API 读取失败 err=", GetLastError(),
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
   double fast[1], slow[1];
   if(CopyBuffer(maFastHandle, 0, 0, 1, fast) < 1) return 0;
   if(CopyBuffer(maSlowHandle, 0, 0, 1, slow) < 1) return 0;
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
      Print("[stable] ▶ 开", dir==1?"多":"空",
            " L", layer,
            "  Lots=", DoubleToString(lots,2),
            "  Price=", DoubleToString(price,2),
            "  总浮盈=", DoubleToString(CalcTotalProfit(),2));
   }
   else
   {
      Print("[stable] ❌ 开单失败 dir=", dir, " lots=", lots,
            " err=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
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
      Print("[stable] ◀ 平", dir==1?"多":"空", " ×", closed,
            "  该方向浮盈=", DoubleToString(profitBefore,2));
}

//+------------------------------------------------------------------+
//| 黑天鹅熔断: M1 波动 >= 阈值触发, 视浮亏率决定平/不平              |
//+------------------------------------------------------------------+
void CheckBlackSwan()
{
   if(!Inp_BlackSwan || emergencyFrozen) return;

   double high = iHigh(_Symbol, PERIOD_M1, 1);
   double low  = iLow(_Symbol, PERIOD_M1, 1);
   if(high <= 0 || low <= 0) return;
   double range = high - low;
   if(range < Inp_BlackSwanRange) return;

   // 触发
   emergencyFrozen = true;
   double totalProfit = CalcTotalProfit();
   double floatLoss   = (totalProfit < 0) ? -totalProfit : 0;
   double balance     = AccountInfoDouble(ACCOUNT_BALANCE);
   double lossPct     = (balance > 0) ? (floatLoss / balance * 100.0) : 0;

   string msg1 = StringFormat("[stable-BLACKSWAN] M1 波动=$%.2f ≥ $%.2f | 浮亏=%.2f USC (%.2f%% of 余额 %.2f)",
                              range, Inp_BlackSwanRange, floatLoss, lossPct, balance);
   Print(msg1);

   if(lossPct < Inp_MaxCloseLossPct)
   {
      Print("[stable-BLACKSWAN] ✂ 浮亏率 ", DoubleToString(lossPct,2),
            "% < ", Inp_MaxCloseLossPct, "% → 全平止损 + 冻结");
      Alert(StringFormat("[stable] 黑天鹅! M1=$%.2f, 全平离场 (浮亏 %.2f%% < 阈值)",
                         range, lossPct));
      CloseAllByDir(1);
      CloseAllByDir(-1);
   }
   else
   {
      Print("[stable-BLACKSWAN] 🔒 浮亏率 ", DoubleToString(lossPct,2),
            "% ≥ ", Inp_MaxCloseLossPct, "% → 保留持仓, 只冻结禁开新仓");
      Alert(StringFormat("[stable] 黑天鹅! M1=$%.2f, 但浮亏 %.2f%% 过大, 保留持仓, 禁加仓",
                         range, lossPct));
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
//| 判断当前是否处于新闻黑洞窗口                                       |
//+------------------------------------------------------------------+
bool IsNewsBlackout(string &blockingEvent, int &minutesTo)
{
   blockingEvent = "";
   minutesTo = 0;
   if(!Inp_NewsFilter) return false;

   datetime now  = TimeCurrent();
   datetime from = now - Inp_NewsMinAfter  * 60;
   datetime to   = now + Inp_NewsMinBefore * 60;

   MqlCalendarValue values[];
   int n = CalendarValueHistory(values, from, to, "US");
   if(n <= 0) return false;

   for(int i = 0; i < n; i++)
   {
      MqlCalendarEvent evt;
      if(!CalendarEventById(values[i].event_id, evt)) continue;
      if(evt.importance != CALENDAR_IMPORTANCE_HIGH) continue;
      if(!IsWatchedNewsName(evt.name)) continue;

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

   CreateLbl(panelPfx+"t", 10, y, "=== 美分马丁-stable v1.1 ===", clrGold); y += lh + 4;

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

   // 状态行
   string status = "运行中";
   color  stCol  = clrLime;

   if(emergencyFrozen)
   {
      status = "❗黑天鹅冻结 (需重启 EA)";
      stCol = clrRed;
   }
   else
   {
      string newsName; int newsMin;
      if(IsNewsBlackout(newsName, newsMin))
      {
         if(newsMin >= 0)
            status = StringFormat("⚠新闻窗口: %s (还剩 %d 分钟)", newsName, newsMin);
         else
            status = StringFormat("⚠新闻窗口: %s (已过 %d 分钟)", newsName, -newsMin);
         stCol = clrOrange;
      }
      else if(spd > spdMax)
      {
         status = "⚠ 点差过大, 禁开新仓";
         stCol = clrOrange;
      }
   }
   CreateLbl(panelPfx+"st", 10, y, "状态: " + status, stCol);

   ChartRedraw();
}

//+------------------------------------------------------------------+
void OnTick()
{
   //--- 每 tick 保护检查
   CheckBlackSwan();

   PosStat stat;
   GetPositionStat(stat);

   //--- 平仓判定 (不受冻结/新闻影响, 允许自然止盈平仓)
   if(stat.buyCnt > 0 && stat.buyAvgProfitPrice >= AvgProfitTarget)
   {
      Print("[stable] 触发平多: 均价浮盈=", DoubleToString(stat.buyAvgProfitPrice,3),
            " ≥ ", AvgProfitTarget, "  多单数=", stat.buyCnt);
      CloseAllByDir(1);
      UpdatePanel();
      return;
   }
   if(stat.sellCnt > 0 && stat.sellAvgProfitPrice >= AvgProfitTarget)
   {
      Print("[stable] 触发平空: 均价浮盈=", DoubleToString(stat.sellAvgProfitPrice,3),
            " ≥ ", AvgProfitTarget, "  空单数=", stat.sellCnt);
      CloseAllByDir(-1);
      UpdatePanel();
      return;
   }

   //--- 开新仓前的保护门 (冻结/点差/新闻)
   if(emergencyFrozen)
   {
      UpdatePanel();
      return;
   }

   // 点差
   bool spdOK = IsSpreadOK();
   if(!spdOK)
   {
      if(!lastSpreadHi && Inp_VerboseLog)
      {
         long spd = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
         Print("[stable] ⚠ 点差过大 ", spd, " > ", Inp_MaxSpread + Inp_SpreadBuffer,
               " → 禁开新仓");
         lastSpreadHi = true;
      }
      UpdatePanel();
      return;
   }
   else if(lastSpreadHi)
   {
      Print("[stable] ✓ 点差恢复正常");
      lastSpreadHi = false;
   }

   // 新闻窗口
   string newsName; int newsMin;
   bool newsBlock = IsNewsBlackout(newsName, newsMin);
   if(newsBlock)
   {
      if(!lastNewsBlocked && Inp_VerboseLog)
      {
         Print("[stable] ⚠ 新闻窗口: ", newsName, " (", newsMin, " 分钟) → 禁开新仓");
         lastNewsBlocked = true;
      }
      UpdatePanel();
      return;
   }
   else if(lastNewsBlocked)
   {
      Print("[stable] ✓ 新闻窗口结束, 恢复开仓");
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

   //--- 多单方向
   if(sig == 1 && stat.buyCnt < MaxOrderCount)
   {
      if(stat.buyCnt > 0 && stat.buyAvgProfitPrice <= -LossPriceGap)
      {
         double nextLot;
         if(stat.buyCnt < 4) nextLot = fixedLotArr[stat.buyCnt];
         else                nextLot = GetLastLotByDir(1) * MultiAfter4;
         if(Inp_VerboseLog)
            Print("[stable] 触发加多 L", stat.buyCnt+1,
                  ": 均价浮亏=", DoubleToString(stat.buyAvgProfitPrice,3),
                  " ≤ -", LossPriceGap,
                  "  下一单=", DoubleToString(NormalizeLot(nextLot),2));
         OpenTrade(1, nextLot, stat.buyCnt+1);
      }
      else if(stat.buyCnt == 0)
      {
         OpenTrade(1, fixedLotArr[0], 1);
      }
   }

   //--- 空单方向
   if(sig == -1 && stat.sellCnt < MaxOrderCount)
   {
      if(stat.sellCnt > 0 && stat.sellAvgProfitPrice <= -LossPriceGap)
      {
         double nextLot;
         if(stat.sellCnt < 4) nextLot = fixedLotArr[stat.sellCnt];
         else                 nextLot = GetLastLotByDir(-1) * MultiAfter4;
         if(Inp_VerboseLog)
            Print("[stable] 触发加空 L", stat.sellCnt+1,
                  ": 均价浮亏=", DoubleToString(stat.sellAvgProfitPrice,3),
                  " ≤ -", LossPriceGap,
                  "  下一单=", DoubleToString(NormalizeLot(nextLot),2));
         OpenTrade(-1, nextLot, stat.sellCnt+1);
      }
      else if(stat.sellCnt == 0)
      {
         OpenTrade(-1, fixedLotArr[0], 1);
      }
   }

   UpdatePanel();
}
//+------------------------------------------------------------------+
