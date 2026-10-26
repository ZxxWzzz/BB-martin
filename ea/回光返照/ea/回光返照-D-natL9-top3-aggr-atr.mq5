//+------------------------------------------------------------------+
//|                                回光返照-D-natL9-top3-aggr-atr.mq5 |
//|                                                      Version 4.0 |
//|                                                                  |
//|  策略: 多周期 MACD 投票 逆低周期假突破 (无RSI) + 对称复利        |
//|       + ATR 自适应止损 + 按SL反算手数                            |
//|                                                                  |
//|  === 配置 D: 进攻抢入场 (原生L9 / 顶3+余5/6 / 抢 / TRAIL8 / ATR14×2.0) ==|
//|  来源: v6 ATR池 抢入场最优(补"抢在ATR下行不行"盲区, PF最高)       |
//|    回测(2024-09~2026-09, 税后$0.1):                              |
//|    487笔 全PF1.42 train1.23 test1.65 净$+642 回撤$-137 净/撤4.7  |
//|  特点: PF全场最高(1.42); 抢入场(靠AnticipateThr脆阈值); 全原生   |
//|    [!] train1.23→test1.65 落差偏大, 抢阈值需模拟盘确认           |
//|                                                                  |
//|  共享骨架: 可变周期数L / native|geo序列 / 平铺|顶K投票           |
//|            确认|抢入场 / FIXED|TRAIL出场 / 固定|ATR止损          |
//|                                                                  |
//|  v4.0 (2026-10-26): 加ATR自适应止损+按SL反算手数                 |
//+------------------------------------------------------------------+
#property copyright "回光返照"
#property version   "4.00"
#property description "回光返照 D 进攻抢入场: 原生L9 顶3+余5/6 抢 TRAIL8 ATR14x2.0 反算手数"
#property strict

#include <Trade\Trade.mqh>

//============ 配置标识 (四个版本仅此块不同) ========================
#define VER_TAG       "D-natL9-aggr"
#define USE_SYNTH     0        // 0=原生周期(iMACD)  1=M1合成周期
#define VOTE_LEN      9        // 投票周期个数 L
#define VOTE_FLAT     0        // 1=平铺N/L  0=顶K一致+余票
#define FLAT_MIN      0        // VOTE_FLAT=1: 至少 N 票同向 (平铺 N/L)
#define TOPK          3        // VOTE_FLAT=0: 顶部 K 个必须全一致
#define REST_MIN      5        // VOTE_FLAT=0: 其余至少几票同向 (余5/6)
#define ENTRY_MODE    1        // 0=确认(真穿越)  1=抢(将穿)
#define USE_TRAIL     1        // 1=TRAIL跟踪  0=FIXED固定TP
#define TRAIL_DIST    8.0      // TRAIL 跟踪距离 (USD/oz)
#define FIXED_TP      15.0     // FIXED 止盈距离 (USD/oz, 仅 USE_TRAIL=0)
#define SL_MODE       1        // 0=固定硬止损(Inp_HardSL)  1=ATR自适应止损
#define ATR_PERIOD    14       // ATR 周期(M3 bar数, 仅 SL_MODE=1)
#define ATR_MULT      2.0      // ATR 倍数: SL距离=ATR×该值 (仅 SL_MODE=1)
#define DEF_MAGIC     7824

//============ 周期 ============
input group "=== 周期 (勿改, 对应回测配置) ==="
input ENUM_TIMEFRAMES TF_Trigger = PERIOD_M3;   // 触发周期 (EA 必须挂此周期图表)

//============ MACD ============
input group "=== MACD ==="
input int    MACD_Fast   = 12;
input int    MACD_Slow   = 26;
input int    MACD_Signal = 9;

//============ 入场(抢)参数 ============
input group "=== 入场(抢模式才用) ==="
input double Inp_AnticipateThr = 0.15;  // |MACD柱|<=该值且收敛视为将穿 (仅 ENTRY_MODE=1)

//============ 风控/出场 ============
input group "=== 出场 & 风控 ==="
input double Inp_HardSL   = 10.0;   // 硬止损 (USD/oz)
input int    Inp_Slippage = 10;     // 允许滑点(points)

//============ 对称复利 ============
input group "=== 对称复利 (equity翻倍→风险预算翻倍) ==="
input double Inp_BaseCap  = 200.0;  // 基准本金(USD)
input double Inp_BaseLot  = 0.01;   // 基础手数 (仅 SL_MODE=0 固定止损用)
input double Inp_BaseRisk = 10.0;   // 基准本金时每笔风险预算(USD) (仅 SL_MODE=1 反算手数用, 默认=0.01手×$10止损口径)
input double Inp_AtrFloor = 3.0;    // ATR止损距离地板(USD/oz), 防ATR过小手数爆炸

//============ 过滤 & 面板 ============
input group "=== 点差 & 面板 ==="
input int    Inp_MaxSpread    = 60;
input int    Inp_SpreadBuffer = 5;
input int    MagicNum         = DEF_MAGIC;
input bool   Inp_ShowPanel    = true;
input bool   Inp_VerboseLog   = true;

//---- 投票周期序列 (分钟): native=MT5原生, geo=几何×2(需合成) ----
// native L≤9: 6/12/30/60/120/240/480/720/1440
// geo    L≤9: 6/12/24/48/96/192/384/768/1440
int g_natMin[9] = {6,12,30,60,120,240,480,720,1440};
int g_geoMin[9] = {6,12,24,48,96,192,384,768,1440};
int g_voteMin[9];                       // 实际用的分钟序列(前 VOTE_LEN 个)
ENUM_TIMEFRAMES g_natTf[9] = {PERIOD_M6,PERIOD_M12,PERIOD_M30,PERIOD_H1,
                              PERIOD_H2,PERIOD_H4,PERIOD_H8,PERIOD_H12,PERIOD_D1};

//---- 全局
CTrade   trade;
int      hTrig = INVALID_HANDLE;
int      hVote[9];                      // 原生模式用 (USE_SYNTH=0)
int      hAtr = INVALID_HANDLE;         // ATR 句柄 (SL_MODE=1)
datetime lastBarTime = 0;
int      lastTrigSig = 0;
string   panelPfx = "Hgfz_" VER_TAG "_";

// 持仓跟踪
bool     g_hasPos  = false;
int      g_dir     = 0;
double   g_entry   = 0;
double   g_best    = 0;
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
   if(Period() != TF_Trigger)
   {
      Print("[回光返照-", VER_TAG, "] [X] 必须挂在 ", EnumToString(TF_Trigger), " 图表");
      Alert("[回光返照] EA 必须挂在 ", EnumToString(TF_Trigger), " 图表");
      return INIT_FAILED;
   }

   // 组装投票分钟序列 (前 VOTE_LEN 个)
   for(int i = 0; i < VOTE_LEN; i++)
      g_voteMin[i] = (USE_SYNTH==1) ? g_geoMin[i] : g_natMin[i];

   hTrig = iMACD(_Symbol, TF_Trigger, MACD_Fast, MACD_Slow, MACD_Signal, PRICE_CLOSE);
   if(hTrig == INVALID_HANDLE) { Print("[回光返照] [X] 触发MACD句柄失败"); return INIT_FAILED; }

   // ATR 止损句柄 (SL_MODE=1): 挂在触发周期 M3
   if(SL_MODE == 1)
   {
      hAtr = iATR(_Symbol, TF_Trigger, ATR_PERIOD);
      if(hAtr == INVALID_HANDLE) { Print("[回光返照] [X] ATR句柄失败"); return INIT_FAILED; }
   }

   // 原生模式: 建投票句柄 (geo 合成模式不用句柄, OnTick 现算)
   if(USE_SYNTH == 0)
   {
      for(int i = 0; i < VOTE_LEN; i++)
      {
         hVote[i] = iMACD(_Symbol, g_natTf[i], MACD_Fast, MACD_Slow, MACD_Signal, PRICE_CLOSE);
         if(hVote[i] == INVALID_HANDLE)
         { Print("[回光返照] [X] 投票句柄失败 idx=", i); return INIT_FAILED; }
      }
   }

   trade.SetExpertMagicNumber(MagicNum);
   trade.SetDeviationInPoints(Inp_Slippage);
   trade.SetTypeFilling(DetectFilling());
   lastBarTime = 0; lastTrigSig = 0;

   RebuildPositionState();

   Print("=============================================");
   Print("=== 回光返照 ", VER_TAG, " v3.0 启动 ===");
   Print("序列=", USE_SYNTH==1?"geo合成":"native原生", " L", VOTE_LEN,
         "  投票=", VOTE_FLAT==1 ? StringFormat("平铺%d/%d",FLAT_MIN,VOTE_LEN)
                                 : StringFormat("顶%d一致+余%d/%d",TOPK,REST_MIN,VOTE_LEN-TOPK),
         "  入场=", ENTRY_MODE==0?"确认":"抢",
         "  出场=", USE_TRAIL==1 ? StringFormat("TRAIL%.0f",TRAIL_DIST) : StringFormat("FIXED TP%.0f",FIXED_TP));
   string ser=""; for(int i=0;i<VOTE_LEN;i++) ser+=(string)g_voteMin[i]+(i<VOTE_LEN-1?"/":"");
   Print("投票周期(min)=", ser, "  硬止损=", DoubleToString(Inp_HardSL,1));
   Print("对称复利: 基准", DoubleToString(Inp_BaseCap,0), " 基础手", DoubleToString(Inp_BaseLot,2),
         " equity=", DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY),2),
         " → 下", DoubleToString(CalcCompoundLot(),2), "手(L", CalcCompoundLevel(), ")");
   if(USE_SYNTH==1)
      Print("[!] geo合成模式: 24/48/96/192/384/768min 从M1合成, 比原生多一层偏差风险");
   Print("Magic=", MagicNum);
   if(g_hasPos) Print("[对齐] 接管持仓 ", g_dir==1?"多":"空", " 开", DoubleToString(g_entry,2),
                      " 跟踪", g_trailOn?"已激活":"未激活");
   Print("=============================================");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hTrig != INVALID_HANDLE) IndicatorRelease(hTrig);
   if(hAtr != INVALID_HANDLE) IndicatorRelease(hAtr);
   if(USE_SYNTH==0)
      for(int i=0;i<VOTE_LEN;i++) if(hVote[i]!=INVALID_HANDLE) IndicatorRelease(hVote[i]);
   ObjectsDeleteAll(0, panelPfx);
   Print("[回光返照-", VER_TAG, "] 停止, reason=", reason);
}

//+------------------------------------------------------------------+
double CalcCompoundLot()
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq<=0 || Inp_BaseCap<=0) return NormalizeLot(Inp_BaseLot);
   double ratio = eq/Inp_BaseCap; int level=0;
   if(ratio>=1.0) level=(int)MathFloor(MathLog(ratio)/MathLog(2.0));
   if(level<0) level=0;
   if(SL_MODE==0)
      return NormalizeLot(Inp_BaseLot*MathPow(2.0,level));
   // SL_MODE=1: 按SL距离反算手数, 保证每笔风险=基准风险×2^level
   double riskBudget = Inp_BaseRisk * MathPow(2.0, level);
   double slDist = CalcAtrSL(true);   // 估算本次止损距离(用最新ATR)
   if(slDist <= 0) slDist = Inp_AtrFloor;
   double lots = riskBudget / slDist;
   return NormalizeLot(lots);
}
int CalcCompoundLevel()
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq<=0 || Inp_BaseCap<=0) return 0;
   double ratio=eq/Inp_BaseCap; if(ratio<1.0) return 0;
   int level=(int)MathFloor(MathLog(ratio)/MathLog(2.0));
   return level<0?0:level;
}

//+------------------------------------------------------------------+
double NormalizeLot(double v)
{
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double mn=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double mx=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   if(step<=0) step=0.01;
   v=MathFloor(v/step)*step; v=MathMax(v,mn); v=MathMin(v,mx);
   v=NormalizeDouble(v,2); if(v<mn) v=mn; return v;
}

//+------------------------------------------------------------------+
//| 当前止损距离(USD/oz): 固定模式=Inp_HardSL; ATR模式=ATR×倍数(带地板)|
//|  用已收 bar[1] 的 ATR (无前视); quiet=true 时失败不打印           |
//+------------------------------------------------------------------+
double CalcAtrSL(bool quiet)
{
   if(SL_MODE==0) return Inp_HardSL;
   double a[1];
   if(CopyBuffer(hAtr,0,1,1,a)<1)   // bar[1] 已收盘 ATR
   {
      if(!quiet) Print("[回光返照-",VER_TAG,"] [!] ATR读取失败, 用地板", Inp_AtrFloor);
      return Inp_AtrFloor;
   }
   double d = a[0]*ATR_MULT;
   if(d < Inp_AtrFloor) d = Inp_AtrFloor;   // 地板: 防ATR过小→手数爆炸
   return d;
}

//+------------------------------------------------------------------+
//| EMA 递推 (adjust=False, 种子=首值) — 匹配回测 pandas ewm          |
//+------------------------------------------------------------------+
double EmaLast(const double &price[], int n, int cnt)
{
   if(cnt<=0) return 0;
   double k=2.0/(n+1.0), ema=price[0];
   for(int i=1;i<cnt;i++) ema = price[i]*k + ema*(1.0-k);
   return ema;
}

//+------------------------------------------------------------------+
//| 合成 N 分钟周期收盘序列 (从 M1, 按unix整除切桶=回测同锚点)        |
//| 返回最近 need 根已收盘合成bar的 MACD柱(DIF-DEA) 到 histOut[0..1]  |
//|   histOut[0]=最新已收盘bar, [1]=前一根                           |
//+------------------------------------------------------------------+
bool SynthMacdHist(int periodMin, double &h1, double &h2)
{
   // 需要足够 M1: (slow+signal+buffer) 根合成bar × periodMin
   int needBars = MACD_Slow + MACD_Signal + 50;   // 合成bar数
   int needM1 = (needBars+2) * periodMin + periodMin;
   if(needM1 > 200000) needM1 = 200000;

   MqlRates r[];
   ArraySetAsSeries(r, false);                    // 时间升序
   int got = CopyRates(_Symbol, PERIOD_M1, 0, needM1, r);
   if(got < periodMin*(MACD_Slow+MACD_Signal+2)) return false;

   // 按 unix整除切桶: bucket = floor(time/ (periodMin*60))
   long bsec = (long)periodMin*60;
   double closes[]; ArrayResize(closes, got); int nc=0;
   long curBucket = -1; double lastClose=0;
   for(int i=0;i<got;i++)
   {
      long b = (long)r[i].time / bsec;
      if(curBucket==-1) { curBucket=b; lastClose=r[i].close; continue; }
      if(b!=curBucket)  // 进入新桶 → 上一桶收盘定稿
      {
         closes[nc++]=lastClose; curBucket=b;
      }
      lastClose=r[i].close;
   }
   // 最后一桶(lastClose)是"正在走"的桶, 不计入(只用已收盘)
   if(nc < MACD_Slow+MACD_Signal+2) return false;

   // 在 closes[0..nc-1] 上算 MACD, 取末两根已收盘
   // DIF = EMAfast - EMAslow; DEA = EMA(DIF, signal); hist=DIF-DEA
   // 逐根构建 DIF 序列, 再对 DIF 做 signal EMA
   double dif[]; ArrayResize(dif, nc);
   double kf=2.0/(MACD_Fast+1.0), ks=2.0/(MACD_Slow+1.0);
   double ef=closes[0], es=closes[0];
   dif[0]=0;
   for(int i=1;i<nc;i++){ ef=closes[i]*kf+ef*(1-kf); es=closes[i]*ks+es*(1-ks); dif[i]=ef-es; }
   double kg=2.0/(MACD_Signal+1.0), dea=dif[0];
   double histPrev=0, histCur=0;
   for(int i=1;i<nc;i++){ dea=dif[i]*kg+dea*(1-kg); histPrev=histCur; histCur=dif[i]-dea; }
   h1=histCur;    // 最新已收盘桶
   h2=histPrev;   // 前一根
   return true;
}

//+------------------------------------------------------------------+
bool MacdHistNative(int handle, int shift, double &hist)
{
   double m[1],s[1];
   if(CopyBuffer(handle,0,shift,1,m)<1) return false;
   if(CopyBuffer(handle,1,shift,1,s)<1) return false;
   hist=m[0]-s[0]; return true;
}

//+------------------------------------------------------------------+
//| 取投票周期 idx 的 MACD柱 (bar[1]已收盘): 原生用句柄, geo用合成    |
//+------------------------------------------------------------------+
bool VoteHist(int idx, double &hist)
{
   if(USE_SYNTH==0) return MacdHistNative(hVote[idx], 1, hist);
   double h1,h2;
   if(!SynthMacdHist(g_voteMin[idx], h1, h2)) return false;
   hist=h1; return true;
}

//+------------------------------------------------------------------+
//| 触发信号 (M3): +1金叉 -1死叉 0无 (取已收 bar[1])                  |
//+------------------------------------------------------------------+
int TriggerSignal()
{
   double h1,h2;
   if(!MacdHistNative(hTrig,1,h1)) return 0;
   if(!MacdHistNative(hTrig,2,h2)) return 0;
   if(ENTRY_MODE==0){
      if(h1>0 && h2<=0) return 1;
      if(h1<0 && h2>=0) return -1;
   } else {
      if(h1<0 && h1>h2 && MathAbs(h1)<=Inp_AnticipateThr) return 1;
      if(h1>0 && h1<h2 && MathAbs(h1)<=Inp_AnticipateThr) return -1;
   }
   return 0;
}

//+------------------------------------------------------------------+
//| 投票判定: wantBearish=true 问"是否满足开空的高周期条件"          |
//|  平铺: 同向票数>=FLAT_MIN                                         |
//|  顶K:  最大K个全同向 且 其余>=REST_MIN                            |
//|  detail 输出每周期状态串                                          |
//+------------------------------------------------------------------+
bool VotePass(bool wantBearish, int &sameCnt, string &detail)
{
   detail=""; sameCnt=0;
   bool topAgree=true;
   int restSame=0;
   int restStart=0, restEnd=VOTE_LEN;   // 平铺: 全部算"余"
   if(VOTE_FLAT==0){ restEnd=VOTE_LEN-TOPK; }  // 顶K在末尾(最大的K个)

   for(int i=0;i<VOTE_LEN;i++)
   {
      double h;
      if(!VoteHist(i,h)){ detail+="?"; topAgree=false; continue; }
      bool bearish=(h<0);
      bool match=(bearish==wantBearish);
      if(match) sameCnt++;
      if(VOTE_FLAT==0 && i>=VOTE_LEN-TOPK)   // 顶K区
         { if(!match) topAgree=false; detail+= match?"T":"t"; }
      else
         { if(match) restSame++; detail+= match?"R":"."; }
   }
   if(VOTE_FLAT==1) return (sameCnt>=FLAT_MIN);
   return (topAgree && restSame>=REST_MIN);
}

//+------------------------------------------------------------------+
int CurrentPosDir()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i); if(t==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=MagicNum) continue;
      return (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)?1:-1;
   }
   return 0;
}

//+------------------------------------------------------------------+
void RebuildPositionState()
{
   g_hasPos=false; g_dir=0; g_entry=0; g_best=0; g_trailOn=false;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i); if(t==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=MagicNum) continue;
      g_hasPos=true;
      g_dir=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)?1:-1;
      g_entry=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl=PositionGetDouble(POSITION_SL);
      if(g_dir==1){ if(sl>g_entry+_Point){g_trailOn=true;g_best=sl+TRAIL_DIST;} else {g_trailOn=false;g_best=g_entry;} }
      else        { if(sl>0&&sl<g_entry-_Point){g_trailOn=true;g_best=sl-TRAIL_DIST;} else {g_trailOn=false;g_best=g_entry;} }
      double posLot=PositionGetDouble(POSITION_VOLUME), tgt=CalcCompoundLot();
      if(MathAbs(posLot-tgt)>=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP))
         Print("[回光返照-",VER_TAG,"] [对齐] 持仓手", DoubleToString(posLot,2),
               " 与当前档位手", DoubleToString(tgt,2), " 不一致→保留现仓, 下单用新档");
      return;
   }
}

//+------------------------------------------------------------------+
bool IsSpreadOK()
{
   long sp=SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);
   return (sp<=Inp_MaxSpread+Inp_SpreadBuffer);
}

//+------------------------------------------------------------------+
bool OpenPos(int dir, string detail, int sameCnt)
{
   double slDist = CalcAtrSL(false);   // 本次止损距离(固定或ATR)
   double lots=CalcCompoundLot();
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK), bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double price=(dir==1)?ask:bid;
   int dg=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   double sl=(dir==1)?price-slDist:price+slDist;
   sl=NormalizeDouble(sl,dg);
   double tp=0;
   if(USE_TRAIL==0) tp=NormalizeDouble((dir==1)?price+FIXED_TP:price-FIXED_TP, dg);
   string cmt=StringFormat("hgfz_%s_%s_L%d", VER_TAG, dir==1?"B":"S", CalcCompoundLevel());
   bool ok=(dir==1)?trade.Buy(lots,_Symbol,price,sl,tp,cmt):trade.Sell(lots,_Symbol,price,sl,tp,cmt);
   if(ok){
      g_hasPos=true; g_dir=dir; g_entry=price; g_best=price; g_trailOn=false;
      Print("[回光返照-",VER_TAG,"] >> 开",dir==1?"多(假破位)":"空(回光返照)",
            " 手",DoubleToString(lots,2)," (L",CalcCompoundLevel()," eq",
            DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY),2),
            SL_MODE==1?(" 风险预算$"+DoubleToString(Inp_BaseRisk*MathPow(2.0,CalcCompoundLevel()),1)):"",")",
            " 价",DoubleToString(price,dg),
            " SL",DoubleToString(sl,dg),"(距$",DoubleToString(slDist,1),SL_MODE==1?"ATR":"固定",")",
            USE_TRAIL==0?(" TP"+DoubleToString(tp,dg)):"",
            " 投票[",detail,"] 同向",sameCnt,"/",VOTE_LEN);
   } else
      Print("[回光返照-",VER_TAG,"] [X] 开仓失败 rc=",trade.ResultRetcode()," ",trade.ResultRetcodeDescription());
   return ok;
}

//+------------------------------------------------------------------+
void ManageTrailing()
{
   if(!g_hasPos || USE_TRAIL==0) return;
   ulong ticket=0; double curSL=0;
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong t=PositionGetTicket(i); if(t==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=MagicNum) continue;
      ticket=t; curSL=PositionGetDouble(POSITION_SL); break;
   }
   if(ticket==0) return;
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID), ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   int dg=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   if(g_dir==1){
      if(bid>g_best) g_best=bid;
      if(!g_trailOn && (g_best-g_entry)>=TRAIL_DIST) g_trailOn=true;
      if(g_trailOn){ double ns=NormalizeDouble(g_best-TRAIL_DIST,dg); if(ns>curSL+_Point) trade.PositionModify(ticket,ns,0); }
   } else {
      if(g_best==0||ask<g_best) g_best=ask;
      if(!g_trailOn && (g_entry-g_best)>=TRAIL_DIST) g_trailOn=true;
      if(g_trailOn){ double ns=NormalizeDouble(g_best+TRAIL_DIST,dg); if(curSL==0||ns<curSL-_Point) trade.PositionModify(ticket,ns,0); }
   }
}

//+------------------------------------------------------------------+
void CreateLbl(string nm,int x,int y,string txt,color c)
{
   if(ObjectFind(0,nm)<0){
      ObjectCreate(0,nm,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,nm,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetString(0,nm,OBJPROP_FONT,"Consolas");
      ObjectSetInteger(0,nm,OBJPROP_FONTSIZE,10);
      ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);
   }
   ObjectSetInteger(0,nm,OBJPROP_XDISTANCE,x); ObjectSetInteger(0,nm,OBJPROP_YDISTANCE,y);
   ObjectSetString(0,nm,OBJPROP_TEXT,txt); ObjectSetInteger(0,nm,OBJPROP_COLOR,c);
}

void UpdatePanel(int trigSig, bool passBear, int cntBear, bool passBull, int cntBull)
{
   if(!Inp_ShowPanel) return;
   int y=30, lh=18;
   CreateLbl(panelPfx+"t",10,y,"=== 回光返照 "+VER_TAG+" ===",clrGold); y+=lh+4;
   string ps=(!g_hasPos)?"持仓: 无":StringFormat("持仓: %s 开%.2f %s",g_dir==1?"多":"空",g_entry,g_trailOn?"[跟踪]":"[硬SL]");
   CreateLbl(panelPfx+"p",10,y,ps,!g_hasPos?clrGray:(g_dir==1?clrLime:clrAqua)); y+=lh;
   CreateLbl(panelPfx+"c",10,y,StringFormat("复利L%d 手%.2f eq%.0f(基%.0f)",
             CalcCompoundLevel(),CalcCompoundLot(),AccountInfoDouble(ACCOUNT_EQUITY),Inp_BaseCap),clrWhite); y+=lh;
   CreateLbl(panelPfx+"tr",10,y,StringFormat("触发(%s): %s",EnumToString(TF_Trigger),
             trigSig==1?"金叉↑":(trigSig==-1?"死叉↓":"无")),
             trigSig==1?clrLime:(trigSig==-1?clrOrange:clrGray)); y+=lh;
   CreateLbl(panelPfx+"vb",10,y,StringFormat("空条件:%s 同向%d/%d",passBear?"满足":"否",cntBear,VOTE_LEN),
             passBear?clrOrange:clrGray); y+=lh;
   CreateLbl(panelPfx+"vl",10,y,StringFormat("多条件:%s 同向%d/%d",passBull?"满足":"否",cntBull,VOTE_LEN),
             passBull?clrLime:clrGray); y+=lh;
   long sp=SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);
   CreateLbl(panelPfx+"s",10,y,StringFormat("点差:%d(≤%d)",(int)sp,Inp_MaxSpread+Inp_SpreadBuffer),
             sp>Inp_MaxSpread+Inp_SpreadBuffer?clrRed:clrWhite);
   ChartRedraw();
}

//+------------------------------------------------------------------+
void OnTick()
{
   int curDir=CurrentPosDir();
   if(g_hasPos && curDir==0){
      Print("[回光返照-",VER_TAG,"] << 持仓已平(SL/跟踪/TP)");
      g_hasPos=false; g_trailOn=false; g_dir=0;
   }
   ManageTrailing();

   int trigSig=TriggerSignal();
   bool pB,pL; int cB,cL; string dB,dL;
   pB=VotePass(true,cB,dB);
   pL=VotePass(false,cL,dL);
   UpdatePanel(trigSig,pB,cB,pL,cL);

   datetime cur=iTime(_Symbol,TF_Trigger,0);
   if(cur==lastBarTime) return;
   lastBarTime=cur;

   if(g_hasPos||curDir!=0) return;
   if(trigSig==0) return;

   if(Inp_VerboseLog && trigSig!=lastTrigSig){
      Print("[回光返照-",VER_TAG,"] 触发",trigSig==1?"金叉":"死叉",
            " 空[",dB,"]同向",cB,"/",VOTE_LEN," 多[",dL,"]同向",cL,"/",VOTE_LEN);
      lastTrigSig=trigSig;
   }
   if(!IsSpreadOK()) return;

   // 金叉+高周期满足空条件→空 ; 死叉+满足多条件→多
   if(trigSig==1 && pB) OpenPos(-1,dB,cB);
   else if(trigSig==-1 && pL) OpenPos(1,dL,cL);
}
//+------------------------------------------------------------------+
