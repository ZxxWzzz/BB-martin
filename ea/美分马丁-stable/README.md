# 美分马丁-stable EA 功能文档

> **文件**：`美分马丁-stable.mq5` | **版本**：v1.5 | **平台**：MT5

XAU/USD 美分账户马丁格尔策略，基于 CENT22 真机数据反推的手数序列 + M15 MA20/50 双均线信号，允许多空共存。带黑天鹅、点差、新闻窗口三层保护。

---

## 1. 概述

### 定位
- **品种**：XAUUSD.ct（Decode Global 美分账户黄金合约）
- **账户类型**：**必须 Hedging 模式**（多空共存的前提），Netting 账户会 `INIT_FAILED`
- **杠杆**：500:1 计算保证金
- **合约规格**：0.01 手 = 0.01 oz，$1 价差 × 0.01 手 = 1 USC 盈亏
- **建议资金**：$300 起（对应约 30000 USC），$600+ 更安全

### 策略骨架

```
方向判断 (M15 MA20/50 交叉)
    ↓
[空仓] 首单 0.01 手
[持仓 + 反向浮亏 ≥ $2] 加下一层 (v1.4: 距最后一单价 $2 触发, 层间距恒定)
[持仓 + 顺向浮盈 ≥ $0.6/oz 均价差] 该方向 CloseAll 全平
[黑天鹅/点差/新闻] 阻断开新仓
```

---

## 2. 版本历史

| 版本 | 日期 | 主要变更 |
|---|---|---|
| **v1.5** | 2026-09-15 | **黑天鹅按层数分档**：`max(buyCnt,sellCnt) < 16` 全平+暂停 30 分钟；`≥ 16` 只冻结+手机推送。移除 `Inp_MaxCloseLossPct`，新增 `Inp_BlackSwanLayerCap` / `Inp_BlackSwanPauseMin` |
| **v1.4** | 2026-09-03 | 加仓触发从"加权均价浮亏"改为**"最新一单浮亏"**，层间距恒定 |
| **v1.3** | 2026-09-03 | 手数表分界改 `ArraySize()`；MA 取已收 bar[1]；Calendar API 缓存 60s；开单致命错误直接冻结；新增 `Inp_MinUsdProfit` 兜底参数 |
| **v1.2** | 2026-09-03 | 最大层数 12→22，`fixedLotArr` 扩到 12 位真机 CENT22 序列，开单失败冷却 |
| **v1.1** | 2026-09-02 | 黑天鹅熔断、点差保护、新闻过滤、面板 HUD、完整日志 |
| **v1.0** | 2026-09-01 | 基于 MT4 参照策略首次迁移到 MT5，`MultiAfter4=1.3` |

---

## 3. 前置要求

### 账户
- **必须 Hedging 账户**（`OnInit` 校验 `ACCOUNT_MARGIN_MODE_RETAIL_HEDGING`，非 Hedging 直接拒启动）
- USC 计价（美分账户）
- 500:1 杠杆
- 最小手数步进 0.01

### 平台
- MetaTrader 5（build 2000+，为了 Calendar API）
- 允许自动交易（`Ctrl+E` / 顶部工具栏"算法交易"按钮开启）
- Broker 需允许 `WebRequest` 到 Calendar API 服务器（可选，缺失时新闻过滤失效）

### 图表
- 品种：XAUUSD.ct
- 周期：M1（推荐，加仓 tick 敏感）；M5 也可
- 信号周期由参数 `SignalTimeFrame` 独立控制（默认 M15）

---

## 4. 参数说明

所有参数分 4 组呈现在 MT5 参数窗。

### 4.1 策略核心（`=== 策略核心 ===`）

| 参数 | 默认 | 单位 | 含义 |
|---|---|---|---|
| `SignalTimeFrame` | `PERIOD_M15` | 枚举 | MA20/50 计算周期 |
| `LossPriceGap` | `2.0` | USD/oz | 加仓触发阈值：**最新一单浮亏** ≥ 此值触发下一层 |
| `AvgProfitTarget` | `0.6` | USD/oz | 平仓触发阈值：**该方向加权均价浮盈** ≥ 此值全平 |
| `Inp_MinUsdProfit` | `0.0` | USC | 兜底：均价达标但 USD 浮盈 < 此值时**等待**（0=不启用） |
| `MaxOrderCount` | `22` | 层 | 每方向最大层数（真机曾到 L23，22 层留缓冲） |
| `MultiAfter4` | `1.3` | 倍率 | **L13+** 每层 = 上一层 × 此倍率（前 12 层查表） |
| `MagicNum` | `8866` | int | 订单 magic number，用于识别本 EA 持仓 |
| `Slippage` | `10` | points | CTrade 允许滑点（Deviation） |

> ⚠️ `LossPriceGap` 和 `AvgProfitTarget` 单位是 **USD/oz**（价格差），**不是** 美元浮亏/浮盈。用美元触发请配合 `Inp_MinUsdProfit`。

### 4.2 黑天鹅熔断（`=== 黑天鹅熔断 ===`）

| 参数 | 默认 | 单位 | 含义 |
|---|---|---|---|
| `Inp_BlackSwan` | `true` | bool | 启用黑天鹅熔断 |
| `Inp_BlackSwanRange` | `20.0` | USD | M1 前一根 K 波动 ≥ 此值触发 |
| `Inp_BlackSwanLayerCap` | `16` | 层 | **分档阈值**：`max(buyCnt,sellCnt) < 此值` 全平+暂停；`≥ 此值` 只冻结告警 |
| `Inp_BlackSwanPauseMin` | `30` | 分钟 | 浅套全平后禁开新仓的时长（暂停期结束自动恢复） |

**v1.5 逻辑（按层数分档）**：
- **浅套**（`max(buyCnt,sellCnt) < 16`）：**全平止损 + 暂停 30 分钟**（自动恢复，不冻结）
  - L16 之前累计浮亏 <$20（占 $300 账户 <7%），承受度好，主动止损
  - 暂停期过后 EA 自动恢复开仓，避免刚平完立刻在同样趋势里再套
- **深套**（`max(buyCnt,sellCnt) ≥ 16`）：**只冻结 + 手机推送**（需重启 EA 解锁）
  - L16 后深层手数快速上升（L18=1.26, L22=3.56），全平会锁定巨亏
  - 保留持仓等自然平仓或人工干预，同时推送 MetaQuotes ID 到手机告警

**每层触发瞬间浮亏参考（$300 账户）**：

| 层 | 浮亏 (USC) | 占余额 |
|---|---|---|
| L14 | ~1064 | 3.5% |
| L15 | ~1440 | 4.8% |
| **L16** | **~1932** | **6.4%** ← 分档阈值 |
| L18 | ~3450 | 11.5% |
| L20 | ~6026 | 20.1% |
| L22 | ~10132 | 33.8% |

**推送手机需要提前配置**：MT5 → 工具 → 主选项 → 通知 → 填 MetaQuotes ID + 启用推送。

### 4.3 点差保护（`=== 点差保护 ===`）

| 参数 | 默认 | 单位 | 含义 |
|---|---|---|---|
| `Inp_MaxSpread` | `60` | points | 点差阈值 |
| `Inp_SpreadBuffer` | `5` | points | 缓冲 |

**触发条件**：`SYMBOL_SPREAD > Inp_MaxSpread + Inp_SpreadBuffer`（即 > 65 pt）
**效果**：阻断新开仓（首单/加仓都禁），已有持仓的平仓不受影响。

### 4.4 新闻过滤（`=== 新闻过滤 (FOMC/CPI/PPI/NFP) ===`）

| 参数 | 默认 | 单位 | 含义 |
|---|---|---|---|
| `Inp_NewsFilter` | `true` | bool | 启用新闻过滤 |
| `Inp_NewsMinBefore` | `30` | 分钟 | 事件前 X 分钟禁开新仓 |
| `Inp_NewsMinAfter` | `30` | 分钟 | 事件后 X 分钟禁开新仓 |

**匹配的事件关键词**（硬编码）：
- FOMC / Federal Funds Rate / Fed Interest Rate
- CPI / Consumer Price Index
- PPI / Producer Price Index
- Non-Farm / Nonfarm / Non Farm

**只过滤**：美国（`country="US"`）+ `CALENDAR_IMPORTANCE_HIGH` 级别事件。
**依赖**：MT5 Calendar API（`CalendarValueHistory`），启动时探测可用性。

### 4.5 面板 & 日志（`=== 面板 & 日志 ===`）

| 参数 | 默认 | 单位 | 含义 |
|---|---|---|---|
| `Inp_ShowPanel` | `true` | bool | 图表左上角面板 HUD |
| `Inp_VerboseLog` | `true` | bool | 详细日志（加仓触发/保护进出）|
| `Inp_OpenFailCoolSec` | `2` | 秒 | 开单失败后冷却期，同错误在冷却期内只打印一次 |

---

## 5. 策略核心逻辑

### 5.1 OnTick 执行顺序

```
1. CheckBlackSwan()          — 每 tick 检查 M1 波动
2. GetPositionStat(stat)     — 统计本 magic 的持仓
3. 清理 g_buyWaitUsd/g_sellWaitUsd 标志 (C3 用)
4. 平仓判定 (buy)             — 均价浮盈达标 → CloseAllByDir(1)
5. 平仓判定 (sell)            — 均价浮盈达标 → CloseAllByDir(-1)
6. emergencyFrozen 检查       — 冻结则 return
7. **pauseOpenUntil 检查**    — 黑天鹅浅套暂停期内 return (v1.5)
8. IsSpreadOK()              — 点差超限则 return
9. IsNewsBlackout()          — 新闻窗口内则 return
10. GetSignal()              — 无信号则 return
11. totalPos==0 → 首单       — 按信号开 0.01
12. sig==+1 → 多单方向       — 判断加仓条件
13. sig==-1 → 空单方向       — 判断加仓条件
14. UpdatePanel()            — 更新面板
```

> **注意**：平仓判定在保护门之前，即使处于冻结/新闻窗口，达标时**仍会自动止盈**。

### 5.2 方向信号（`GetSignal()`）

```mql5
maFast = MA(20, PRICE_CLOSE, shift=1)   // 已收 bar
maSlow = MA(50, PRICE_CLOSE, shift=1)
if maFast > maSlow  return +1  (做多)
if maFast < maSlow  return -1  (做空)
return 0
```

**v1.3 优化**：从 `shift=0` 改为 `shift=1`，用**已收 K 线**避免未收 bar 每 tick 抖动。

### 5.3 首单开仓

条件（同时满足）：
- `totalPos == 0`（无本 magic 持仓）
- `sig != 0`（有方向信号）
- 未处于冻结 / 点差过大 / 新闻窗口

执行：`OpenTrade(sig, fixedLotArr[0]=0.01, layer=1)`

### 5.4 加仓机制（v1.4 核心改动）

**触发条件（分方向）**：

**多单加仓**（`sig==+1` 且 `buyCnt < MaxOrderCount`）：
```
lastOpen = GetLastOpenPriceByDir(+1)   // 最新一单开仓价
lastLoss = lastOpen - Bid              // 最新单浮亏 (>0 表示亏)
if lastLoss >= LossPriceGap:
    加多一单
```

**空单加仓**（`sig==-1` 且 `sellCnt < MaxOrderCount`）：
```
lastOpen = GetLastOpenPriceByDir(-1)
lastLoss = Ask - lastOpen              // 最新单浮亏 (>0 表示亏)
if lastLoss >= LossPriceGap:
    加空一单
```

**下一单手数**：
```
if 已开层数 < 12:  查 fixedLotArr[已开层数]     (L1-L12)
else:              上一单手数 × MultiAfter4    (L13+)
```

**v1.4 关键改动**：从"加权均价浮亏"改为"**最新一单浮亏**"，让每层间距恒定 = `LossPriceGap`（默认 $2）。

旧版（v1.3 及以前）问题：均价被大手数快速拉动，L5-L12 实际间距 $0.4-0.8，12 层挤在 $6 里。
新版（v1.4）：22 层展开在 $42 里（每层严格 $2），跟真机数据一致。

### 5.5 平仓机制

**触发条件（分方向独立）**：

```
buyAvgProfitPrice = Σ((bid - openPrice[i]) × lot[i]) / Σ(lot[i])   // 多单方向加权均价浮盈
if buyAvgProfitPrice >= AvgProfitTarget:
    if Inp_MinUsdProfit > 0 && USD 浮盈 < Inp_MinUsdProfit:
        等待 (记 g_buyWaitUsd, 日志节流打印一次)
    else:
        CloseAllByDir(+1)   // 一次性平掉所有多单
```

空单镜像。

**平仓不受**：`emergencyFrozen`、点差、新闻 三个保护门的阻断。
**平仓不看**：MA 信号（即使信号翻转也允许自然止盈）。

### 5.6 双向共存

- `PosStat.buyCnt` 和 `PosStat.sellCnt` **独立统计**
- 加仓条件独立判断（多单看多单浮亏，空单看空单浮亏）
- 平仓独立触发（多单达标平多，空单达标平空，互不影响）
- 最坏情况**同时持有 MaxOrderCount 多单 + MaxOrderCount 空单** = 44 层

---

## 6. 手数序列

**L1-L12（`fixedLotArr` 查表，真机 CENT22 反推）**：

| Layer | Size | 累计 |
|---|---|---|
| L1 | 0.01 | 0.01 |
| L2 | 0.01 | 0.02 |
| L3 | 0.02 | 0.04 |
| L4 | 0.03 | 0.07 |
| L5 | 0.04 | 0.11 |
| L6 | 0.05 | 0.16 |
| L7 | 0.07 | 0.23 |
| L8 | 0.09 | 0.32 |
| L9 | 0.12 | 0.44 |
| L10 | 0.16 | 0.60 |
| L11 | 0.21 | 0.81 |
| L12 | 0.27 | 1.08 |

**L13-L22（前一层 × 1.3，NormalizeLot floor 取整）**：

| Layer | Size | 累计 |
|---|---|---|
| L13 | 0.35 | 1.43 |
| L14 | 0.45 | 1.88 |
| L15 | 0.58 | 2.46 |
| L16 | 0.75 | 3.21 |
| L17 | 0.97 | 4.18 |
| L18 | 1.26 | 5.44 |
| L19 | 1.63 | 7.07 |
| L20 | 2.11 | 9.18 |
| L21 | 2.74 | 11.92 |
| L22 | 3.56 | **15.48** |

**L1-L22 满仓累计 = 15.48 手**，对应保证金约 13300 USC（@ 价格 4300）。

**`NormalizeLot`** 会做：
1. `MathFloor(lot / step) * step` — 按 broker step 向下取整
2. `[minLot, maxLot]` 夹紧
3. 至少 0.01

---

## 7. 保护机制

### 7.1 Hedging 账户校验

在 `OnInit` 首步：
```mql5
if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
    return INIT_FAILED;
```
Netting 账户直接拒运行，因为策略依赖多空共存。

### 7.2 黑天鹅熔断（v1.5 按层数分档）

每个 tick 首先执行 `CheckBlackSwan()`：

```mql5
range = iHigh(_Symbol, PERIOD_M1, 1) - iLow(_Symbol, PERIOD_M1, 1)
if range >= Inp_BlackSwanRange:
    maxLayer = max(buyCnt, sellCnt)
    if maxLayer < Inp_BlackSwanLayerCap:
        // 浅套: 全平止损 + 暂停 X 分钟 (自动恢复, 不冻结)
        CloseAllByDir(+1); CloseAllByDir(-1)
        pauseOpenUntil = TimeCurrent() + Inp_BlackSwanPauseMin * 60
        Alert(...); SendNotification(...)
    else:
        // 深套: 只冻结, 保留持仓, 手机推送告警 (需重启 EA 解锁)
        emergencyFrozen = true
        Alert(...); SendNotification(...)
```

**两种行为对比**：

| 分档 | max(buyCnt,sellCnt) | 行为 | 恢复方式 |
|---|---|---|---|
| 浅套 | < 16 | **全平 + 暂停 30 分钟** | 暂停期结束自动恢复 |
| 深套 | ≥ 16 | **只冻结 + 手机推送** | 需重启 EA |

**平仓不受暂停期影响** —— 暂停期内已有持仓的自然止盈仍能触发（`pauseOpenUntil` 检查在平仓判定之后）。

**深套告警需要手机推送提前配好**：MT5 → 工具 → 主选项 → 通知 → 填 MetaQuotes ID。

### 7.3 点差过滤

`IsSpreadOK()`：`spread > Inp_MaxSpread + Inp_SpreadBuffer` 时禁开新仓（不影响平仓）。
状态变化时打印一次日志：`⚠ 点差过大 XXX > 65 → 禁开新仓` / `✓ 点差恢复正常`。

### 7.4 新闻过滤

`IsNewsBlackout()`：
1. **缓存 60s**（`g_newsCacheTs`），避免每 tick 拉外部日历
2. 查询 `now-30min` 到 `now+30min` 内所有 US 事件
3. 筛选 `CALENDAR_IMPORTANCE_HIGH`
4. 关键词匹配 FOMC/CPI/PPI/NFP → 返回阻断

`OnInit` 首次调用探测 Calendar API 可用性，失败时打印警告（broker 服务器不共享日历时会失败）。

### 7.5 开单失败节流

`OpenTrade()` 失败后：
1. **致命错误**（`NO_MONEY`/`LIMIT_VOLUME`/`LIMIT_ORDERS`/`LIMIT_POSITIONS`）→ 立即 `emergencyFrozen=true` + Alert
2. **环境错误**（`MARKET_CLOSED`/`TRADE_DISABLED`）→ 走冷却，打印时加标签
3. 其他错误 → 走冷却

冷却期 `Inp_OpenFailCoolSec` 秒内同错误只打印 1 次。

### 7.6 冻结状态 / 暂停期（v1.5 分离）

**`emergencyFrozen = true`（深套冻结，永久性）**：
- **阻断**：新开仓（首单、加仓）
- **不阻断**：自然止盈平仓（仍可 CloseAll）
- **触发场景**：致命错误 / 黑天鹅深套（≥ `Inp_BlackSwanLayerCap`）
- 面板显示：`❗黑天鹅冻结 (需重启 EA)`
- **解锁**：重新加载 EA（拖回图表 / 重启 MT5）

**`pauseOpenUntil` 暂停期（浅套暂停，临时性）**：
- **阻断**：新开仓（首单、加仓）
- **不阻断**：自然止盈平仓
- **触发场景**：黑天鹅浅套（< `Inp_BlackSwanLayerCap`）全平后
- 面板显示：`🕒 黑天鹅暂停 剩 X 分钟`（橙色）
- **解锁**：暂停期结束（`Inp_BlackSwanPauseMin` 到点）**自动恢复**

---

## 8. 面板 HUD

图表左上角 5 行，每 tick 更新：

```
=== 美分马丁-stable v1.5 ===
多: L{N}/22  手数:{X.XX}  浮盈:{XXX.XX}     ← 有多单时绿/橙, 无则灰
空: L{N}/22  手数:{X.XX}  浮盈:{XXX.XX}     ← 有空单时青/橙, 无则灰

余额:{XXXXX.XX} USC  总浮盈:{XXX.XX}       ← 白/橙
点差:{X} pt (阈值≤65)                       ← 白, 超阈值转红

状态: {动态}
```

**状态行**（按优先级）：
1. `❗黑天鹅冻结 (需重启 EA)` — 红（深套冻结）
2. `🕒 黑天鹅暂停 剩 X 分钟` — 橙（浅套全平后的暂停期，v1.5 新增）
3. `⚠新闻窗口: {事件名} (还剩 N 分钟)` — 橙
4. `⚠ 点差过大, 禁开新仓` — 橙
5. `运行中` — 绿

对象名前缀：`StableP_`（`OnDeinit` 会清理）。

---

## 9. 日志规格

### 9.1 启动日志（`OnInit`）

```
=============================================
=== 美分马丁-stable v1.5 启动 ===
信号周期=PERIOD_M15 (取已收 bar[1])  加仓触发=最新单浮亏≥$2.0/oz (层间距恒定)  平仓价差=$0.6/oz  USD 兜底=关
L1-L12 查表: [0.01,0.01,0.02,0.03,0.04,0.05,0.07,0.09,0.12,0.16,0.21,0.27]
L13+ 倍率=1.3  最大层数=22  开单失败冷却=2秒
[保护] 黑天鹅=开 (M1>$20.0, 层<16 全平+暂停30min, 层≥16 冻结告警)
[保护] 点差过滤: >65 pt 禁开
[保护] 新闻过滤=开  前30min / 后30min
Magic=8866  账户模式=Hedging ✅
[stable] Calendar API OK, 未来 7 天美国事件数=65
=============================================
```

### 9.2 交易日志

**开仓成功**：
```
[stable] ▶ 开多 L3  Lots=0.02  Price=4300.15  总浮盈=-4.20
```

**加仓触发**（`Inp_VerboseLog=true`）：
```
[stable] 触发加空 L5: 最新单浮亏=2.150 ≥ 2.0 (lastOpen=4295.30 ask=4297.45)  下一单=0.04
```

**平仓触发**：
```
[stable] 触发平多: 均价差=0.615 ≥ 0.6  USD 浮盈=2.46  多单数=3
[stable] ◀ 平多 ×3  该方向浮盈=2.46
```

**USD 兜底等待**（`Inp_MinUsdProfit > 0`）：
```
[stable] 平多价差达标(0.612≥0.6) 但 USD 浮盈=1.20 < 3.0 → 等待
```

### 9.3 保护触发日志

**黑天鹅浅套（v1.5，全平 + 暂停）**：
```
[stable-BLACKSWAN] ✂ M1$21.50 层数=8(多0/空8) 浮亏=350.00 USC (1.17%) < L16 → 全平止损 + 暂停 30 分钟
[stable] 🕒 黑天鹅暂停中, 剩 29 分钟, 禁开新仓
[stable] ✓ 黑天鹅暂停结束, 恢复开仓
```

**黑天鹅深套（v1.5，只冻结 + 手机推送）**：
```
[stable-BLACKSWAN] 🔒 M1$25.30 层数=18(多0/空18) 浮亏=3450.00 USC (11.5%) ≥ L16 → 保留持仓 + 冻结 (需重启 EA 解锁)
```
（同时 Alert 弹窗 + SendNotification 推送到手机）

**点差 / 新闻**（进出各一次）：
```
[stable] ⚠ 点差过大 138 > 65 → 禁开新仓
[stable] ✓ 点差恢复正常
[stable] ⚠ 新闻窗口: CPI (15 分钟) → 禁开新仓
[stable] ✓ 新闻窗口结束, 恢复开仓
```

### 9.4 错误日志

**开单失败**（节流后）：
```
[stable] ❌ 开单失败 dir=-1 lots=0.01 rc=10027 auto trading disabled by client (2s 内重复失败仅记 1 次)
```

**致命错误**：
```
[stable] ⛔ 致命错误 rc=10019 no money dir=-1 lots=3.56 → 冻结 EA
```

---

## 10. 状态机 & 全局变量

| 变量 | 类型 | 用途 |
|---|---|---|
| `trade` | `CTrade` | MQL5 交易接口 |
| `maFastHandle` / `maSlowHandle` | `int` | MA20/50 句柄，`OnDeinit` 释放 |
| `emergencyFrozen` | `bool` | 深套冻结标志（黑天鹅 L≥16 / 致命错误）|
| `pauseOpenUntil` | `datetime` | v1.5: 浅套全平后禁开新仓的截止时间 |
| `lastPauseNoted` | `bool` | v1.5: 暂停期日志节流 |
| `lastNewsBlocked` | `bool` | 新闻状态去重（进出各打印一次） |
| `lastSpreadHi` | `bool` | 点差状态去重 |
| `lastOpenFailTs` | `datetime` | 开单失败节流时间戳 |
| `g_newsCacheTs` / `g_newsCacheBlock` / `g_newsCacheName` / `g_newsCacheEventTime` | | Calendar API 60s 结果缓存 |
| `g_buyWaitUsd` / `g_sellWaitUsd` | `bool` | `Inp_MinUsdProfit` 等待状态去重 |
| `fixedLotArr[12]` | `double` | L1-L12 手数表 |

---

## 11. 已知限制 & 风险

### 11.1 电脑重启 / EA 掉线
- EA 不运行时**无法处理持仓**（既不加仓也不平仓）
- 恢复后 `GetPositionStat` 能识别原有持仓，但**期间价格走势已固化**
- **根本解决**：VPS 部署 24/7 运行

### 11.2 单边趋势市
- 马丁核心假设是"深套后会反弹"
- 极端单边行情下：
  - 22 层打满后无法再加仓
  - 平仓门槛远在均价 + $0.6/oz 处，等不到
  - 账户浮亏持续放大直至强平
- **$300 账户从 L1 起能扛约 $50 反向波动**（对应 stop out 50%）
- **$600 账户能扛约 $70**

### 11.3 L1 亏损结构
- L1 胜率 66.7%（每 3 次赢 2 次）
- 但**盈亏比 1:2**（亏损单是盈利单 2 倍大）
- 因为**L1 是空单里位置最不利的一层**，深套 CloseAll 时 L1 必然是亏损单
- 这是马丁的**固有代价**，无法通过参数调整消除

### 11.4 新闻过滤依赖 Calendar API
- Broker 服务器不共享日历时 `CalendarValueHistory` 返回 <0
- `OnInit` 会打印警告，但**新闻过滤会静默失效**
- **建议**：启动后手动确认工具栏"日历"能显示未来事件

### 11.5 双向共存 = 双倍风险
- `MaxOrderCount=22` 意味着最坏 44 单持仓
- 保证金压力比单向策略大一倍

---

## 12. 部署指南

### 12.1 编译
1. `Ctrl+F4` 打开 MetaEditor
2. Navigator → `Experts\美分马丁-stable.mq5` → 双击
3. **F7** 编译，应 0 error 0 warning

### 12.2 挂图
1. MT5 → Navigator → Expert Advisors → **美分马丁-stable** 拖到 XAUUSD.ct M1 图表
2. 参数窗弹出 → 通常保持默认，点确定
3. 右下角 EA 名字旁应为 **😊 笑脸**（不是 ❌）
4. 顶部工具栏"算法交易"按钮必须**绿色**

### 12.3 首次验证
观察工具箱 → Experts 标签，应看到启动日志（第 9.1 节样例），特别关注：
- `账户模式=Hedging ✅`
- `Calendar API OK, 未来 7 天美国事件数=X`（数字 > 0）
- 如果 Calendar API 失败，新闻过滤失效，需要人工避开

### 12.4 参数调优建议

保守起步（$300 账户）：
```
LossPriceGap    = 2.0  (默认)
AvgProfitTarget = 0.6  (默认)
MaxOrderCount   = 22   (默认)
```

想拉长节奏、减少交易次数：
```
AvgProfitTarget = 1.0-1.5   (拉高平仓门槛)
```

想减小深层保证金压力：
```
MaxOrderCount = 12-15
```

想加 USD 兜底（避免深套小额盈利成本大）：
```
Inp_MinUsdProfit = 3.0-5.0   (整体浮盈 ≥ $3-5 才平)
```

---

## 13. 常见问题（FAQ）

**Q1：为什么 EA 挂上后一直报 err=10027？**
A：MT5 顶部"算法交易"按钮没开。`Ctrl+E` 或点击工具栏该按钮打开。

**Q2：为什么启动日志说"Calendar API 读取失败"？**
A：Broker 服务器不共享 MQL5 日历数据。新闻过滤不生效，需人工避开 FOMC/CPI/PPI/NFP 时段。

**Q3：为什么日志里连续开单失败刷屏？**
A：v1.2+ 已加冷却（默认 2s）。如果仍频繁，看具体错误码。

**Q4：满 22 层了怎么办？**
A：EA 停止加仓，仅等自然平仓（均价浮盈 ≥ $0.6/oz）或黑天鹅触发。此时如果账户资金不够扛后续行情，需人工判断是否砍仓。

**Q5：`Inp_MinUsdProfit` 和 `AvgProfitTarget` 什么区别？**
A：`AvgProfitTarget` 是**价格差**（USD/oz）。`Inp_MinUsdProfit` 是**账户货币浮盈**（USC）。两个都达标才平仓。默认 `Inp_MinUsdProfit=0` 即不启用兜底，只看价差。

**Q6：为什么加仓从 L12 到 L13 是 0.35 手（不是 0.351）？**
A：`NormalizeLot` 用 `MathFloor` 向下取整到 broker step。0.27 × 1.3 = 0.351 → floor 到 0.35。

**Q7：EA 重启后能接管原有持仓吗？**
A：能。`GetPositionStat` 按 `MagicNum` 识别本 EA 持仓，重启后继续按当前 sellCnt/buyCnt 判断加/平仓。但**期间价格波动无法追回**。

**Q8：能同时挂多张图跑同一个 EA 吗？**
A：**不能**。两个 EA 共用同一 `MagicNum` 会互相干扰持仓统计。想跑多品种/多方向请用不同 `MagicNum`。

---

## 参考

- **上游参照**：MT4 参照策略（`tools/2026_08_24MT4参照策略.txt` 里的 `Gold_Martin_V4.mq4`）
- **真机对齐**：Huali Wu#3 账户（30002558）实盘数据（`tools/DetailedStatement.htm` / `tools/wu_Statement.htm`）
- **1:1 复制参考**：Xiaofeng Xie#1 账户（30003556）（`tools/hu_Statement.htm`），手数直接就是 master 原生序列
- **姊妹项目**：`ea/美分马丁VV1/` — 单向循环 + M30 布林方向 + 完整风控栈的 CENT22 复刻版
