# XAU 单边行情预警 (Breakout Guard)

**目标**：识别 XAUUSD M1 上「单边走出大行程、期间几乎不回撤」的危险起点 bar，给 BB马丁 EA 做**爆仓拦截器**——单边启动时暂停开仓，规避层层加仓爆仓。

> 点值口径：**1 点 = $1**（BB 账户 0.01 手 = 1oz，价格变动 $1 = 盈亏 $1）。
> 品种：`XAUUSD.ct`（BB / Decode Global 标准账户），数据 2024-09-15 ~ 2026-09-18，约 83 万根 M1。

## 核心结论（这是全项目最重要的产出）

按 (单边行程 / 反向回撤) 阈值扫描两年数据后，真正危险的单边极其罕见：

| 阈值(点) | 独立事件 | 月均 |
|---|---|---|
| 50/8 | 35 | 1.45 |
| 60/8 | 5 | 0.21 |
| 70/8 | 1 | 0.04 |
| 80/8 | 0 | 0 |

**≥60 点无回撤的单边，两年只有 5 次。** 事件太稀疏，导致纯 ML 和高频规则都不划算（见下）。当前方向是「高波动日 + 强动能」窄窗口过滤，而非全天候拦截。

## 走过的三条路线

1. **机器学习 (LightGBM) — 基本失败**：正样本占比仅 0.031%，TEST AUC=0.55（≈瞎猜）、AP=0.0003。极端类别不平衡下拟合的是噪声。见 `data/processed/train_report.txt`。
2. **规则引擎 — 召回够但误报爆炸**：最优规则 `xau_tr>2.5 AND xau_net_ret_60<-0.05%` + 60min 冷却，事件拦截率 77%，但要让 EA **30.5% 的时间停摆**，precision 仅 0.6%。见 `cooldown_summary.txt`。
3. **阈值 + 日级过滤 — 当前方向**：先按日 K 高低差筛高波动日，只在这些日子跑精细扫描，大幅压缩误报面。见 `scan_daily_filter.py` / `daily_filter_events.csv`。

## 目录

```
xau-breakout-guard/
├── data/
│   ├── raw/          # M1 parquet: xauusd/spx/usdidx/wti (跨品种特征用)
│   ├── events/       # 宏观事件日历 (当前为空, 走 investpy 缓存)
│   └── processed/    # 特征/标签/模型/各类分析结果 CSV
├── src/              # 见下方脚本清单
├── notebooks/        # 探索 (空)
└── README.md
```

## 脚本清单 (`src/`)

| 脚本 | 职责 |
|---|---|
| `config.yaml` | 全部参数（阈值、事件窗口、LGBM、成本模型） |
| `fetch_mt5.py` / `fetch_dukascopy.py` | 拉 M1（MT5 主源，Dukascopy 备用） |
| `probe_mt5.py` / `probe_duka_symbols.py` | 探测可用品种名 |
| `fetch_events.py` / `filter_news.py` | 宏观事件日历拉取 + 过滤 |
| `warmup_history.py` | MT5 历史预热 |
| `label.py` | 58/8 标注器（numba `_scan` 核，保守 tick 假设） |
| `features.py` | 因果特征工程（含跨品种 SPX/USD/WTI） |
| `train.py` | LightGBM baseline |
| `analyze_hits.py` | 命中分析 + 同波去重（`_scan` 被多处复用） |
| `analyze_precursors.py` / `plot_precursors.py` | 前兆分析 + 作图 |
| `analyze_multivariate.py` | 多因子/跨品种分析 |
| `rule_engine.py` | 规则引擎 |
| `backtest.py` / `backtest_grid.py` | 成本敏感回测 + 参数网格 |
| `export_cooldown_log.py` | 冷却拦截日志导出 |
| `scan_thresholds.py` | 多档 (行程/回撤) 阈值扫描 |
| `scan_daily_filter.py` | 日 K 高波动过滤 + M1 精细扫描（最新） |

## 关键参数（`src/config.yaml`）

| 参数 | 默认 | 说明 |
|---|---|---|
| `label.threshold_move` | 58 | 单边行程达标点数（扫描时常用 50/60） |
| `label.threshold_pullback` | 8 | 反向回撤淘汰阈值 |
| `label.scan_max_bars` | 480 | 最大扫描窗口（8 小时防无限跟踪） |
| `fetch.years_back` | 2 | 数据回溯年数 |
| `events.importance_min` | 2 | investpy 重要度过滤下限 |
| `events.sigma_mult` | 5.0 | 统计异常兜底阈值 |
| `backtest.cost_per_block` | 5.0 | 一次误拦截错过的均值收益 ($) |
| `backtest.gain_per_avoid` | 500.0 | 一次成功规避爆仓的均值收益 ($) |

## 典型流程

```bash
cd D:\dev\martin-analysis\xau-breakout-guard\src
pip install MetaTrader5 pandas pyarrow pyyaml investpy lightgbm scikit-learn numba

python fetch_mt5.py          # ① 拉数据 (需 BB 终端已登录)
python label.py              # ② 标注 + 事件剔除
python features.py           # ③ 特征
python train.py              # ④ 训练 (baseline, 效果有限)
python analyze_hits.py       # ⑤ 命中分析
python scan_thresholds.py    # ⑥ 阈值扫描 (看事件到底多稀疏)
python scan_daily_filter.py  # ⑦ 日级过滤 (当前主力)
```

## 进度

- [x] 项目骨架 + config、数据拉取（XAU + SPX/USD/WTI 跨品种）
- [x] 58/8 标注器 + 事件剔除
- [x] 特征工程、LightGBM baseline（结论：ML 路线效果有限）
- [x] 命中/前兆/多因子分析
- [x] 规则引擎 + 成本敏感回测 + 冷却拦截日志
- [x] 阈值扫描 + 日级高波动过滤
- [ ] 高波动日窄窗口策略定稿
- [ ] 与实盘 EA 对接（导出 ONNX / 走 socket / 文件桥接）
