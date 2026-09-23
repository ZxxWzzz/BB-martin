# BB 马丁监控 (bb-martin-monitor)

BB(Decode Global)账户上「布林带马丁 EA」的**实时监控 + 风险分析工作台**。

一边实时盯着 EA 在 MT5 里的持仓/加仓层数/浮亏,一边用历史数据研究「什么时候该让马丁停手」——避免单边行情里层层加仓爆仓。

> 账户口径:XAUUSD `500:1` USD 账户,`0.01 手 = 1oz`,价格变动 `$1 = $1` 盈亏。
> 品种真名 `XAUUSD.ct`(BB / Decode Global 标准账户)。

## 组成

```
bb-martin-monitor/
├── backend/            # FastAPI (:8877) + watchdog 文件桥
│   ├── main.py             # 服务入口 / REST + 轮询
│   ├── data_service.py     # 读 MT5 Common Files 里的 JSON/JSONL
│   ├── file_watcher.py     # 监听快照文件变动
│   └── requirements.txt
├── frontend/           # 原生 JS 仪表盘 (无框架)
│   ├── index.html
│   └── js/  css/           # gauges / charts / history
├── ea/                 # 各版本布林带马丁 EA 源码 (.mq5)
│   ├── 布林带马丁 V1~V4 / V3GPT(L)
│   ├── 美分马丁-stable     # 当前稳定版
│   └── 美分马丁 VV1
├── analysis/           # EA 策略对比 / 加仓序列推演 (md)
├── tools/              # 结算单、planner 网页、参照策略、分析报告
├── xau-breakout-guard/ # ★ 单边行情预警子项目 (见下方专节)
├── start.bat           # 一键起后端 + 开面板
└── sync-ea.ps1 / .bat  # EA 源码同步到 MT5 Experts 目录
```

## 实时监控是怎么跑起来的

EA 在 MT5 里把持仓快照写进 **MT5 Common Files**(JSON / JSONL);`backend` 用 watchdog 监听这些文件,解析后经 FastAPI(端口 `8877`)吐给 `frontend` 的原生 JS 面板,面板轮询刷新仪表盘、加仓层数、浮盈亏、历史曲线。

> 服务只在本机 `127.0.0.1:8877` 起、无鉴权;仅限本地面板读取,**不要**把该端口暴露到公网。

```bash
# 起监控 (后端 + 面板)
start.bat

# 改完 EA 源码后同步到 MT5 Experts 目录
sync-ea.bat
```

## 子项目:xau-breakout-guard(单边行情预警)

`xau-breakout-guard/` 是从 `D:\dev\martin-analysis\` **整包复制**进来的独立研究子项目,给这套马丁 EA 做「**爆仓拦截器**」的**离线数据研究**:识别 XAUUSD M1 上「单边走出大行程、期间几乎不回撤」的危险起点,单边启动时暂停开仓,规避层层加仓爆仓。

**它是研究/回测代码,不是线上服务**——与 backend 实时栈相互独立,产出的是「阈值 + 拦截规则」的结论,后续再考虑对接实盘 EA。

数据:`XAUUSD.ct` M1,2024-09-15 ~ 2026-09-18,约 83 万根。

### 一句话结论

按 (单边行程 / 反向回撤) 阈值扫两年数据,真正危险的单边极其罕见:

| 阈值(点) | 独立事件 | 月均 |
|---|---|---|
| 50/8 | 35 | 1.45 |
| 60/8 | 5 | 0.21 |
| 70/8 | 1 | 0.04 |
| 80/8 | 0 | 0 |

**≥60 点无回撤的单边,两年只有 5 次。** 事件太稀疏,纯 ML 和高频规则都不划算,当前方向是「高波动日 + 强动能」窄窗口过滤,而非全天候拦截。详见子项目 `xau-breakout-guard/README.md`。

### 走过的三条路线

1. **机器学习 (LightGBM) — 基本失败**:正样本仅 0.031%,TEST AUC≈0.55(≈瞎猜)、AP=0.0003。
2. **规则引擎 — 召回够但误报爆炸**:最优规则事件拦截率 77%,但要 EA 停摆 30.5% 时间,precision 仅 0.6%。
3. **阈值 + 日级过滤 — 当前方向**:先按日 K 高低差筛高波动日,只在这些日子跑精细扫描,压缩误报面。
