# 美分马丁 VV1 · 策略逻辑详解

**文件**：`美分马丁_M1_VV1.mq5` (876 行)
**参考**：`tools/美分马丁策略完整分析报告.md` + `tools/参照马丁.txt`
**MagicNumber**：`2026081801`

---

## 一、策略血统

VV1 = 复刻 Huali Wu#3 (Decode Global · Cent 账户) 的 **CENT22 马丁策略**,并加入三层现代化风控。

```
┌──────────────────────────────────────────────────────────────┐
│  原策略 (Huali Wu#3 主力信号源) 通过 MQL5 Signal Service 跟单   │
│  ↓                                                              │
│  参照马丁.txt (仿写 EA · 手数 L5/L6/L7 有猜错)                  │
│  ↓                                                              │
│  9244 笔真实订单交叉验证 → 校正为真正的 CENT22 序列              │
│  ↓                                                              │
│  VV1 = 校正后的 CENT22 + M30 方向 + V4 风控框架                  │
└──────────────────────────────────────────────────────────────┘
```

---

## 二、核心参数一览

### 手数序列 (L1-L12,L13+ 累乘)

```
L1  L2  L3  L4  L5  L6  L7  L8  L9  L10 L11 L12   L13    L14    L15    ...  L22
0.01 0.01 0.02 0.03 0.04 0.05 0.07 0.09 0.12 0.16 0.21 0.27 | 0.351  0.4563 0.5932 ... 3.7225
                                                            └── ×1.3 累乘 ──┘
```

**关键系数**:
- `Inp_LotSeq_L1_L12` = "0.01,0.01,0.02,0.03,0.04,0.05,0.07,0.09,0.12,0.16,0.21,0.27"
- `Inp_LaterMult` = 1.3 (L13 起用前一层 × 1.3)
- `Inp_MaxLayers` = 22 (硬顶)
- `Inp_BaseMultiplier` = 1.0 (整体等比缩放,详见 § 六)

### 加仓间距

- `Inp_GapDollars` = **2.0** (美元/加仓距离,等价原策略 200 points)
- `Inp_FloatLossTrigger` = 100.0 (浮亏超此值时切换 gap)
- `Inp_GapAfterFloat` = 2.0 (默认与前一致)

### 平仓阈值 (账户货币金额)

- `Inp_SingleTakeProfit` = **6.0 USD** (单向聚合利润触发平该方向)
- `Inp_TotalTakeProfit` = **6.0 USD** (总利润触发全平)
- `Inp_StopLossAmount` = **0.0** (无止损裸单 · 原策略默认)

### 方向指标

- 用 **M30 布林带中轨方向** 替代原策略未知的 `小艺2` 指标
- `Inp_M30_BB_Period` = 30, `Inp_M30_BB_Dev` = 2.2
- `Inp_M30_NeutralRatio` = 0.30 (中性区宽度 = 半带宽 × 0.3)
- `Inp_FlipCloseAll` = true (方向翻转即 CloseAll)

### 风控 (三层)

- `Inp_Liquidity` = true, `Inp_LiqRange` = **$10** → M1 单K波动 ≥$10 暂停 5min
- `Inp_BlackSwan` = true, `Inp_BlackSwanRange` = **$20** → M1 单K波动 ≥$20 **全平+永久冻结**
- `Inp_MinBalance` = **$1000** → 余额低于此值禁止开新仓
- `Inp_UseTotalLossFC` = false → 50% 总亏强平 (默认关闭,保留原味)

---

## 三、每 tick 处理流程

```
OnTick()
  │
  ├─ UpdatePeakEquity()  ← 记录权益峰值
  │
  ├─ 有持仓? ──────────────── YES ──┐
  │                                    │
  │  ┌─ CheckForceClose()  50%总亏强平(可选)
  │  ├─ CheckDirectionFlip()  M30翻转→CloseAll  【平仓通道①】
  │  ├─ CheckTakeProfit()  SingleTP/TotalTP/SL 【平仓通道②③】
  │  └─ CheckMartingaleAdd()  逆价$2→加下一层
  │                                    │
  │                                   ←┘
  │
  ├─ 新K线? ─── NO ──→ 只更新面板/导出
  │                    │
  │                   YES
  │                    ↓
  ├─ CheckLiquidity()  ← M1波动>$10 暂停
  ├─ CheckBlackSwan()  ← M1波动>$20 全平+冻结
  │
  ├─ 空仓 & 未冻结 ─→ CheckEntry()  ← 尝试L1开仓
  │
  └─ UpdatePanel() + ExportState() + ExportEquitySnapshot()
```

---

## 四、六个关键子系统

### 4.1 方向判断 `GetM30Direction()`

```
M30 布林带 (30, 2.2)
    ↓
计算当前价与中轨的偏移: offset = price - middle
计算中性区宽度:         neutral = 半带宽 × 0.30
    ↓
|offset| < neutral  →  返回 0  (中性,不动作)
offset > 0          →  返回 +1 (多头)
offset < 0          →  返回 -1 (空头)
```

**为什么这样设计**:
- 原策略 `小艺2` 指标源码不公开,但从行为看是"当前价相对某均线的位置"
- M30 BB 中轨 = 20-30 根 M30 K 线均值,起同样的"参考中枢"作用
- 中性区避免了在价格贴中轨时反复翻转开仓

### 4.2 开仓 `CheckEntry()`

前置检查全部通过后:
```
1. IsTradeTime()           ← 周一开盘前 2h 不开
2. IsLiquidityPaused()     ← 流动性熔断未解除?不开
3. bal >= Inp_MinBalance   ← 余额 <$1000?不开+Alert
4. spread <= 60+5          ← 点差 >65?不开
5. GetM30Direction() != 0  ← 中性区?不开
    ↓
根据 M30 方向 (+1/-1) 决定 buy/sell
    ↓
下 L1 = 0.01 × BaseMultiplier 手
    ↓
记录: cycleDirection, cycleLayer=1, cycleOpenTime, cycleEntryPrice
```

### 4.3 加仓 `CheckMartingaleAdd()`

```
cycleLayer < 22?
  ↓ yes
计算逆向距离: distance = |最近开仓价 - 当前价|
  ↓
distance >= GetCurrentGap()?  ← 默认 $2, 浮亏>$100 后可切换
  ↓ yes
点差检查通过?
  ↓ yes
下 GetLotForLayer(cycleLayer+1) 手, cycleLayer++
```

**加仓后总仓位增长(BaseMultiplier=1 时,累计手数)**:
| L | 单层 | 累计 | 平均成本距离(逆)  |
|---|---|---|---|
| L1 | 0.01 | 0.01 | 0 |
| L5 | 0.04 | 0.11 | ~$3 |
| L10 | 0.16 | 0.75 | ~$8 |
| L15 | 0.593 | 3.31 | ~$14 |
| L22 | 3.722 | 16.06 | ~$25 |

### 4.4 平仓 `CheckTakeProfit()` (三通道)

```
计算 profitLong / profitShort / total (含 swap)
    ↓
① SingleTakeProfit 多头触发: cycleDirection=1 且 profitLong >= $6
② SingleTakeProfit 空头触发: cycleDirection=-1 且 profitShort >= $6
③ TotalTakeProfit    触发: total >= $6
④ StopLoss           触发: total <= -Inp_StopLossAmount (默认关闭)
    ↓
CloseAllPositions() + 状态清零 + ExportTradeClose(reason)
```

**加上方向翻转 (`CheckDirectionFlip()`) 就是完整四通道**:
- ① 单向 TP
- ② 整体 TP
- ③ 方向翻转 (M30 反向)  ← **原策略最主要的平仓通道**
- ④ 止损金额 (默认关闭)

### 4.5 流动性熔断 `CheckLiquidity()`

```
每新 K 线取上一根 M1: range = high - low
    ↓
range >= $10?
    ↓ yes
liquidityPausedUntil = 现在 + 300 秒
后续 CheckEntry() 里 IsLiquidityPaused() 返回 true 时拒绝开仓
```

**这是"临时暂停",不影响已有仓位加仓/平仓**

### 4.6 黑天鹅熔断 `CheckBlackSwan()` — TODO §2 落地

```
range >= $20?
    ↓ yes
emergencyFrozen = true (永久)
    ↓
if 有仓位:
    ExportTradeClose("BLACK_SWAN")
    CloseAllPositions()
    cycleDirection = 0
    ↓
Alert 弹窗 + 面板红色显示"❗黑天鹅冻结"
    ↓
需要人工重启 EA 才能解锁 (`emergencyFrozen` 是运行时变量)
```

**为什么"永久冻结"**:
- 单 K $20 波动 = 非农/CPI/闪崩级别,后续可能仍有余震
- 让 EA 自动重启 = 冒着"刚平完仓又开反向仓被反打"的风险
- 强制人工评估 → 更稳

---

## 五、状态导出格式

三个文件写到 MT5 Common Files (`C:\Users\...\Terminal\Common\Files\`):

### `bb_martin_vv1_state.json` (每秒刷新)

```json
{
  "version": "VV1",
  "timestamp": "2026.08.18 14:23:45",
  "account": { "balance": 8437.00, "equity": 8420.15, "margin": 173.5, ... },
  "cycle": {
    "active": true, "direction": 1, "direction_label": "BUY",
    "layer_count": 3, "max_layers": 22,
    "total_lots": 0.05, "floating_pnl": -12.30,
    "current_distance": 1.85, "next_layer_distance": 2.00,
    "emergency_frozen": false, ...
  },
  "positions": [...],
  "risk": { "drawdown_pct": 2.15, "peak_equity": 8500.20, ... },
  "indicators": { "m30_direction": 1, "m30_bb_middle": 4380.5, "spread": 12, ... }
}
```

### `bb_martin_vv1_trades.jsonl` (每次平仓 append 一行)

```json
{"version":"VV1","cycle_id":42,"direction":"BUY","open_time":"...","close_time":"...","layers_used":4,"total_lots":0.14,"profit":6.32,"close_reason":"TP_TOTAL","duration_sec":2340,"entry_price":"4380.15"}
```

`close_reason` 值:`TP_SINGLE_LONG` / `TP_SINGLE_SHORT` / `TP_TOTAL` / `DIR_FLIP` / `SL_AMOUNT` / `BLACK_SWAN` / `总亏强平 X.X%`

### `bb_martin_vv1_equity.jsonl` (每秒 append)

```json
{"t":"2026.08.18 14:23:45","eq":8420.15,"bal":8437.00,"fl":-16.85,"dir":1,"L":3}
```

---

## 六、BaseMultiplier 的作用

**核心**: 整个手数序列的等比缩放系数,一个数决定策略敞口。

```
实际下单手数 = 原始CENT22序列[L] × BaseMultiplier
```

| BaseMultiplier | L1 手数 | 满扛 L22 累计手数 | 保证金 (500:1) | 场景 |
|---|---|---|---|---|
| 1 | 0.01 | 16 手 | ~$240 | 极小试跑 (推荐 demo 起步) |
| 5 | 0.05 | 80 手 | ~$1,200 | 小仓位 |
| 10 | 0.10 | 160 手 | ~$2,400 | 中仓位 |
| **13** | 0.13 | 208 手 | ~$3,077 | **复刻 Huali Wu#3 源A** |
| 42 (=13+14+15) | 0.42 | 675 手 | ~$9,941 | 三源同扛最坏 |

**为什么用一个乘数,而不是让用户直接改 L1 手数**:
- 保证 L1:L2:...:L22 = 1:1:2:...:372 的黄金比例始终对
- 所有 CENT22 数学分析 (浮亏峰值、翻盘弹药量) 直接乘上去就是真实值
- 一处改动 = 22 层同步缩放,不需要重算

---

## 七、与原策略 (参照马丁.txt) 的差异对照

| 机制 | 参照马丁.txt EA 源码 | Huali Wu#3 订单实测 | VV1 实现 |
|---|---|---|---|
| L1-L4 手数 | 0.01/0.01/0.02/0.03 | 1×/1×/2×/3× | ✅ 一致 |
| **L5-L7 手数** | **0.06/0.10/`0.1.3`** (错) | **4×/5×/7×** (对) | ✅ **用订单校正值** |
| L8-L12 | 0.09/0.21/0.16/0.21/0.27 | 9×/12×/16×/21×/27× | ✅ 用订单校正值 |
| L13+ 累乘 | ×1.3 | ×1.3 | ✅ 一致 |
| 加仓间距 | 200 points | 200 points ($2) | ✅ Inp_GapDollars=2 |
| 方向指标 | `小艺2` (私有,未知) | 明显有 M30 方向切换 | ⚠️ **替代为 M30 BB 中轨方向** |
| 无止损 | StopLossAmount=0 | SL=0 全部 | ✅ Inp_StopLossAmount=0 |
| 流动性风控 | `LiquidityRisk=0/0` (关闭) | 未启用 | 🆕 **VV1 开启 (10/300)** |
| 黑天鹅熔断 | 无 | 无 | 🆕 **VV1 新增 ($20 冻结)** |
| 最小余额门槛 | 无 | 无 | 🆕 **VV1 新增 ($1000)** |
| 50% 强平 | 无 | 无 | 🆕 **VV1 可选 (默认关)** |

---

## 八、启动检查表

**部署前**:
- [ ] MT5 图表: XAU/USD (或 xauusd.ct), 周期 M1
- [ ] MetaEditor 编译 (F7), 无 warning
- [ ] AutoTrading 按钮已开
- [ ] 允许 DLL / WebRequest? VV1 不需要,不用开
- [ ] MagicNumber 无冲突 (VV1 用 2026081801, 与 V4/V3GPT 独立)

**参数确认**:
- [ ] `Inp_BaseMultiplier` = **1.0** (第一次跑必须小于 5!)
- [ ] `Inp_MinBalance` >= 你能承受的最低余额
- [ ] `Inp_BlackSwan` = true (强烈建议开)
- [ ] `Inp_MondaySkipHours` >= 2

**观察指标**:
- [ ] 面板显示 "M30: 多/空/中性" — 说明方向指标正常
- [ ] 首笔 L1 开仓后,看 log 里 "开多 L1 @xxxx Lots=0.01 M30 方向=+1"
- [ ] 第一次逆价 $2 后加仓 → log "+多 L2 @xxx Δ=$2.xx"
- [ ] TP 触发 → log "TotalTP 盈利 $6.xx ≥ $6" + CSV 追加一行

---

## 九、常见调整场景

### 想更激进 (更容易触发加仓 + 更小 TP)

```
Inp_GapDollars       = 1.5   (加仓间距从 $2 → $1.5)
Inp_SingleTakeProfit = 4.0   (TP 从 $6 → $4)
Inp_TotalTakeProfit  = 4.0
```

**代价**: 加仓频率↑ 深扛概率↑ 单簇利润↓

### 想更保守 (少开仓 + 早止盈)

```
Inp_M30_NeutralRatio = 0.5   (中性区加宽,更多时段不开仓)
Inp_TotalTakeProfit  = 3.0   (小赢就跑)
Inp_MaxLayers        = 15    (提前放弃深扛)
Inp_UseTotalLossFC   = true  (启用 50% 强平做兜底)
```

### 想跑 Huali Wu#3 的三源合成效果

```
方案: 挂载三个 VV1 实例, 分别设:
  实例A: BaseMultiplier=13, MagicNumber=2026081801
  实例B: BaseMultiplier=14, MagicNumber=2026081802
  实例C: BaseMultiplier=15, MagicNumber=2026081803

(三个魔术号独立,互不干扰,累计敞口 = base=42 场景)
```

需要修改代码里的 `MagicNumber` 常量为 input 变量,或复制三份 .mq5 文件独立编译。

---

## 十、已知限制与后续 TODO

1. **M30 BB 中轨方向 ≠ 原策略"小艺2"**
   - VV1 用 M30 BB 中轨的偏移方向,是最简替代
   - 若能拿到 `小艺2` 源码或行为规律,应替换 `GetM30Direction()`

2. **SingleTakeProfit / TotalTakeProfit 具体值待验证**
   - 报告里从 L1 独立止盈 Top5 反推:最大 +150 USC ≈ $1.5
   - 但 SingleTakeProfit 是聚合利润,不是单笔,实际值可能在 $6-$20 之间
   - 建议在 demo 上跑 3 天,统计 CloseAllPositions 的实际盈利分布再调

3. **周期敏感**
   - EA 挂载到 M1 图表运行 (`PERIOD_CURRENT`)
   - M30 指标只用于方向,不受挂图周期影响

4. **不支持多品种**
   - 通过 `_Symbol` 过滤,一个 EA 实例只交易挂载的那个品种

5. **黑天鹅冻结解除机制**
   - 目前需要人工重启 EA
   - TODO: 未来可加 "冻结后 N 小时自动解除" 选项

---

## 十一、文件位置

- **EA 源码**: `ea/美分马丁VV1/美分马丁_M1_VV1.mq5`
- **本说明**: `ea/美分马丁VV1/VV1_策略逻辑详解.md`
- **参考报告**: `tools/美分马丁策略完整分析报告.md`
- **参考 EA (原始 MQL4 仿写)**: `tools/参照马丁.txt`
- **CENT22 参数可视化**: `tools/tp_planner.html` (点 CENT22 按钮)

- **运行时数据文件** (MT5 Common Files):
  - `bb_martin_vv1_state.json`
  - `bb_martin_vv1_trades.jsonl`
  - `bb_martin_vv1_equity.jsonl`
