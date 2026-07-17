# BB马丁 M1 v3.0 — 纯信号驱动策略设计

## 设计哲学

> **每一层加仓 = 一次独立的市场极值事件**

不再有"机械加仓"。L1到L11，每一层都必须满足完整的信号条件。
价格网格被彻底废弃，价差只作为"参考边界"，不再是触发条件。

---

## 一、状态机

```
       ┌─────────────┐
       │   IDLE      │  无持仓，等待首单
       └──────┬──────┘
              │ 信号事件 + 五重过滤
              ▼
       ┌─────────────┐
       │  ARMED L1   │  持仓中，RSI已离开极值区
       └──────┬──────┘
              │ RSI再次进入极值区（新事件）
              ▼
       ┌─────────────┐
       │  ARMED L2   │  L2加仓完成，等待RSI重置
       └──────┬──────┘
              │ ...重复直到L11或止盈
              ▼
       ┌─────────────┐
       │   EXIT      │  回中轨/篮子达标/风控强平
       └──────┬──────┘
              │ 全平
              ▼
            IDLE
```

**两个核心状态变量：**
- `cycleLayer` — 当前层数 (0-11)
- `rsiArmed` — RSI重置标志 (true=已重置，可触发下层)

---

## 二、信号事件定义

### 2.1 单次"信号事件"必须同时满足

| 条件 | 做多事件 | 做空事件 |
|------|---------|---------|
| BB触轨 | `close[1] ≤ BB_lower[1]` | `close[1] ≥ BB_upper[1]` |
| RSI极值 | `RSI[1] ≤ 22` | `RSI[1] ≥ 78` |

只有这两个同时成立，才算**一次信号**。

### 2.2 "新事件"的判定 — RSI重置机制

```
状态变量: rsiArmed (bool)

RSI从极值区走出 (做多: RSI > 30, 做空: RSI < 70)
  → rsiArmed = true   (装弹)

rsiArmed=true 时:
  RSI再次进入极值区
  → 触发新事件
  → 加仓后 rsiArmed = false  (卸弹)

下次必须等RSI再次走出再回来才能触发
```

**例子（做多周期）：**

```
RSI: 25 → 19 → 18 → 21 → 20 → 25 → 33 → 28 → 21
           ▲              ▲                     ▲
          L1开仓        同一波              新事件→L2
                       (rsiArmed=false)     (rsi越过30又回来)
```

这是关键。否则RSI在20以下连续盘整时，会一根K线一加仓。

---

## 三、五重过滤（所有加仓都要过）

每次加仓前的检查清单：

| # | 条件 | 含义 |
|---|------|------|
| 1 | `信号事件成立` | BB触轨 + RSI极值 + RSI已重置 |
| 2 | `当前周期仍亏损` | `totalProfit < 0` |
| 3 | `距上次加仓 ≥ N根K线` | 默认N=3，避免快速加仓 |
| 4 | `中轨斜率未恶化` | 中轨没有快速逆向移动 |
| 5 | `层数与手数限额内` | `layer<11 且 totalLots+next ≤ 0.6` |

只要任一不满足，就**不加仓，继续等下一个信号**。

---

## 四、出场逻辑（不变）

```
篮子止盈:    totalProfit ≥ $5         → 全平
回中轨止盈:  价格回中轨 且 profit ≥ $1.5 → 全平
风控强平:    DD≥15% / 浮亏≥12% / 日亏≥5%  → 全平
```

---

## 五、关键参数（精简版）

```cpp
// 信号
BB(30, 2.2)
RSI(14)
RSI_OB = 72    // 做空触发(放宽: 78→72)
RSI_OS = 28    // 做多触发(放宽: 22→28)
RSI_OB_Reset = 60   // 做空重置（RSI<60即重置）
RSI_OS_Reset = 40   // 做多重置（RSI>40即重置）

// 加仓
MaxLayers = 11
MinBarsBetweenAdd = 3
LotMulti = 1.25
MaxTotalLots = 0.60

// 入场首单额外过滤(已有)
OuterBandLookback = 5, MaxClose = 2  // 单边过滤
SlopeBars = 8, SlopeATR = 0.7        // 斜率过滤
WidthATR = 5.0                        // 带宽过滤

// 出场(根据XAU M1波动调整)
TP_Basket = $5    // 浅层周期也能触发,不依赖深度反转
TP_MidMin = $1.5  // M1上更易回中轨,降低门槛

// 风控
MaxDD% = 15
DailyLoss% = 5
MaxFloat% = 12
```

**注意：**
- `Inp_GapSeq` 删除（不再需要价格间距）
- `Inp_MidMove` 删除（不再用中轨移动确认）
- `Inp_FixedGrid` 删除
- `Inp_DynGrid` 删除
- 加仓首单的"五重过滤"中，**仍保留单边/斜率过滤**作为额外保险（避免连续加仓陷入趋势）

---

## 六、`CheckMartingaleAdd()` 新版伪代码

```cpp
void CheckMartingaleAdd()
{
   // ── 硬限额 ──
   if(cycleLayer >= MaxLayers) return;
   if(barCount - lastAddBar < MinBarsBetweenAdd) return;
   if(GetCurrentTotalLots() + GetLayerLots(cycleLayer+1) > MaxTotalLots) return;

   // ── 仅在亏损时加仓 ──
   if(CalcTotalProfit() >= 0) return;

   // ── RSI重置检测(每tick更新) ──
   double rsi = GetRSI(1);
   if(cycleDirection == 1)  // 做多周期
   {
      if(rsi > RSI_OS_Reset) rsiArmed = true;     // RSI离开极值,装弹
   }
   else                      // 做空周期
   {
      if(rsi < RSI_OB_Reset) rsiArmed = true;
   }

   if(!rsiArmed) return;     // 还没重置,不能触发

   // ── 信号事件检测 ──
   double close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   bool sigBuy  = (close1 <= bb_lower[1]) && (rsi <= RSI_OS);
   bool sigSell = (close1 >= bb_upper[1]) && (rsi >= RSI_OB);

   bool trigger = false;
   if(cycleDirection == 1 && sigBuy)  trigger = true;
   if(cycleDirection == -1 && sigSell) trigger = true;
   if(!trigger) return;

   // ── 斜率过滤(中轨没在快速逆向移动) ──
   if(CheckSlopeFilter(cycleDirection == 1)) return;

   // ── 执行加仓 ──
   double lots = GetLayerLots(cycleLayer + 1);
   if(cycleDirection == 1)
      trade.Buy(lots, _Symbol, ask, ...);
   else
      trade.Sell(lots, _Symbol, bid, ...);

   cycleLayer++;
   lastAddBar = barCount;
   rsiArmed = false;     // 卸弹,等下次重置
}
```

---

## 七、与v2.0的核心差异

| 项目 | v2.0 (当前) | v3.0 (新版) |
|------|------------|-------------|
| L1开仓 | BB+RSI+三重过滤 | 同 |
| L2-L11加仓 | **价格跌Gap美元** | **新的BB+RSI事件** |
| RSI重置 | 无 | 有(RSI离开再回来) |
| 中轨确认 | 中轨移动$1 | 改用斜率过滤 |
| 价格间距 | 5,6,7,...,18 序列 | **完全废除** |
| 亏损要求 | 无 | **必须亏损才加** |
| 触发频率 | 噪音多,易快速加仓 | 显著减少 |
| 单边行情 | 风险大 | RSI重置+斜率过滤双保险 |

---

## 八、潜在风险与权衡

### 风险1: 信号稀缺导致加仓不足
单边行情中RSI可能长期不重置，导致价格已经跌深却不加仓。

**应对：** 这是**有意为之**。纯信号驱动接受"该不加就不加"的代价，由风控强平兜底。如果发现实测加仓过少，再加价格保险丝。

### 风险2: M1上RSI噪音
M1周期短，RSI可能频繁穿越30/70。

**应对：** 只有"穿越后再次回到22/78"才算事件，22/78本身门槛就高。

### 风险3: 单根K线RSI快速摆动
极端tick波动可能让RSI在一根K线内反复进出极值区。

**应对：** `MinBarsBetweenAdd=3` 强制K线间隔，避免单K内多次加仓。

### 风险4: 反转后第一笔信号还没等到就回中轨止盈
价格触底反弹直接回中轨，L1赚一点钱平掉。

**应对：** **这是好事**。这就是策略希望的最佳出场——不靠加仓也能盈利。

---

## 九、设计决策（已确认）

1. **RSI参数**：72/28 触发，60/40 重置 ✅
   - 理由：单日波动<100点应能盈利，增加触发频率提高交易次数
   - 12点的"重置-触发"间距确保RSI是真正的"波动"事件，不是噪音穿越

2. **L1开仓后立即 rsiArmed=false** ✅
   - L1开完后RSI还在极值区，必须RSI离开60/40再回到72/28才能触发L2
   - 否则L1开完瞬间就符合L2条件，等于无脑加仓

3. **MinBarsBetweenAdd = 3** ✅
   - M1上3分钟间隔，防止单波RSI抖动连续触发

4. **保留中轨斜率过滤作为加仓硬条件** ✅
   - 中轨同方向斜率超过 0.7×ATR → 趋势强，禁止加仓
   - 防止单边行情中"信号是真的但市场也是真的单边"

5. **完全删除Gap参数** ✅
   - 删除：`Inp_GapSeq`、`Inp_MidMove`、`Inp_FixedGrid`、`Inp_DynGrid`、`Inp_GridATR_Mult`
   - 加仓彻底信号驱动，不再依赖任何价格间距

---

## 十、关于"亏损要求"与开仓机制的关系

**不冲突，作用在不同函数：**

| 函数 | 触发场景 | 亏损要求 |
|------|---------|---------|
| `CheckEntry()` | L1首单（无持仓时） | 不检查（没有持仓何来盈亏） |
| `CheckMartingaleAdd()` | L2-L11加仓（有持仓时） | **必须 totalProfit < 0** |

**亏损要求的意义**：马丁的核心是"越跌越买摊低成本"。如果当前已盈利还加仓，意味着加仓价位接近L1，平均成本几乎没变，纯粹放大仓位敞口。盈利状态出新信号反而说明市场在回归，应等回中轨止盈，而不是继续堆仓位。
