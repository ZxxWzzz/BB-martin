//+------------------------------------------------------------------+
//|                                              回光返照_诊断.mq5   |
//|  一次性诊断脚本: 读 broker 规格 + 服务器时区, 定位"不下单"根因    |
//|  用法: 编译后拖到 XAUUSD.ct 任意图表运行一次, 看"专家"日志        |
//+------------------------------------------------------------------+
#property copyright "回光返照诊断"
#property version   "1.00"

void OnStart()
{
   string s = _Symbol;
   Print("========== 回光返照 诊断 @ ", s, " ==========");

   //--- 1. 最小止损距离 (头号嫌疑: 若 > 止损点数, 所有单被拒 rc=10016)
   long stopsLevel  = SymbolInfoInteger(s, SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLevel = SymbolInfoInteger(s, SYMBOL_TRADE_FREEZE_LEVEL);
   double point     = SymbolInfoDouble(s, SYMBOL_POINT);
   int    digits    = (int)SymbolInfoInteger(s, SYMBOL_DIGITS);
   Print("[1] STOPS_LEVEL = ", stopsLevel, " points = $",
         DoubleToString(stopsLevel*point, digits),
         "   (止损距离必须 >= 这个值, 否则下单被拒 rc=10016)");
   Print("    FREEZE_LEVEL = ", freezeLevel, " points");
   Print("    Point = ", DoubleToString(point, digits), "  Digits = ", digits);
   double atrFloorDist = 3.0;   // EA 的 Inp_AtrFloor 默认
   Print("    >> EA 最小止损距离(地板)=$3.0 = ", (int)(atrFloorDist/point),
         " points; ", (atrFloorDist/point >= stopsLevel ? "[OK] 大于STOPS_LEVEL, 不会因此拒单"
                                                        : "[X] 小于STOPS_LEVEL! 这就是不下单根因!"));

   //--- 2. 手数/保证金规格 (核对反算手数 + 最小手)
   double volMin  = SymbolInfoDouble(s, SYMBOL_VOLUME_MIN);
   double volStep = SymbolInfoDouble(s, SYMBOL_VOLUME_STEP);
   double volMax  = SymbolInfoDouble(s, SYMBOL_VOLUME_MAX);
   double tickVal = SymbolInfoDouble(s, SYMBOL_TRADE_TICK_VALUE);
   double tickSz  = SymbolInfoDouble(s, SYMBOL_TRADE_TICK_SIZE);
   Print("[2] VolMin=", volMin, " Step=", volStep, " Max=", volMax);
   Print("    TickValue=", tickVal, " TickSize=", tickSz,
         "  每手每$1波动盈亏 = ", DoubleToString(tickSz>0?tickVal/tickSz:0, 2), " USD",
         "  (XAU 应约=100)");
   double marginMin = 0;
   if(OrderCalcMargin(ORDER_TYPE_BUY, s, volMin, SymbolInfoDouble(s,SYMBOL_ASK), marginMin))
      Print("    最小手(", volMin, ")保证金 ≈ $", DoubleToString(marginMin,2),
            "  账户Equity=$", DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY),2));

   //--- 3. 服务器时区 (F4: 决定高周期 H4/H8/H12/D1 投票是否和回测对齐)
   datetime srvNow = TimeCurrent();
   datetime gmtNow = TimeGMT();
   long diffSec = (long)srvNow - (long)gmtNow;
   Print("[3] 服务器时间 = ", TimeToString(srvNow, TIME_DATE|TIME_SECONDS));
   Print("    GMT  时间 = ", TimeToString(gmtNow, TIME_DATE|TIME_SECONDS));
   Print("    服务器时区 = GMT", (diffSec>=0?"+":""), DoubleToString(diffSec/3600.0,1),
         "   (回测按UTC切H4/D1; 若parquet非此时区, H4+高周期投票会偏)");

   //--- 4. 交易时段 (确认是否在停盘窗口)
   datetime from, to;
   MqlDateTime mdt; TimeToStruct(srvNow, mdt);
   for(int i=0;i<10;i++)
   {
      if(!SymbolInfoSessionTrade(s, (ENUM_DAY_OF_WEEK)mdt.day_of_week, i, from, to)) break;
      Print("    今日交易时段#", i, ": ", TimeToString(from,TIME_MINUTES), " - ", TimeToString(to,TIME_MINUTES));
   }

   //--- 5. 当前点差
   long spread = SymbolInfoInteger(s, SYMBOL_SPREAD);
   Print("[5] 当前点差 = ", spread, " points (EA阈值 60+5=65, 超过则禁开新仓)");

   //--- 6. ATR 现值 (估算实际止损距离, 看会不会触地板)
   int h = iATR(s, PERIOD_M3, 14);
   if(h != INVALID_HANDLE)
   {
      double a[1];
      if(CopyBuffer(h, 0, 1, 1, a) == 1)
         Print("[6] ATR(M3,14) bar[1] = $", DoubleToString(a[0],digits),
               "  ×2.0(D配置) = $", DoubleToString(a[0]*2.0,digits),
               (a[0]*2.0 < 3.0 ? "  < $3地板, 会被抬到$3" : "  > $3地板, 用实际值"));
      IndicatorRelease(h);
   }
   Print("========== 诊断结束, 把以上全部截图发给我 ==========");
}
//+------------------------------------------------------------------+
