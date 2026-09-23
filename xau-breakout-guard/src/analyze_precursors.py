"""前兆分析: 事件启动前 N 分钟是否有可观察到的异常?

方法:
    1. 对每个命中(35 个)提取事件前 240 分钟的 M1 数据.
    2. 计算多组指标(volume/volatility/direction/price_position)在事件前的时间序列.
    3. 用同时段(±30min UTC 小时窗)非事件日的随机 bar 作对照, 消除时段基线偏差.
    4. 输出:
        precursor_events.csv    每个事件在 t-240 ~ t-1 分钟的详细指标
        precursor_summary.txt   事件前 vs 对照 分布对比 (Cohen's d, p-value)
        precursor_snapshots.csv 事件前关键时点快照 (t-60/t-30/t-15/t-5/t-1) 逐事件对比

用法:
    python analyze_precursors.py
    python analyze_precursors.py --window 480
"""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import pandas as pd

HERE = Path(__file__).parent
RAW = HERE / "../data/raw/xauusd_m1.parquet"
HITS = HERE / "../data/processed/hits.csv"


def compute_features(df: pd.DataFrame) -> pd.DataFrame:
    """给完整 M1 df 添加因果特征列 (只用 t 及之前的数据)."""
    d = df.copy()
    # 真实波幅 TR (per bar)
    d["tr"] = d["high"] - d["low"]
    # 蜡烛实体
    d["body"] = (d["close"] - d["open"]).abs()
    d["is_bull"] = (d["close"] > d["open"]).astype(int)
    d["is_bear"] = (d["close"] < d["open"]).astype(int)

    # 滚动统计 (因果, min_periods 允许早期用较少数据)
    d["tr_ma_20"] = d["tr"].rolling(20, min_periods=5).mean()
    d["tr_ma_60"] = d["tr"].rolling(60, min_periods=15).mean()
    d["vol_ma_20"] = d["volume"].rolling(20, min_periods=5).mean()
    d["vol_ma_60"] = d["volume"].rolling(60, min_periods=15).mean()

    # 指标 1: 波动突增比 (当前 5min tr 均值 / 前 60min tr 均值)
    d["tr_ratio_5v60"] = d["tr"].rolling(5, min_periods=2).mean() / (d["tr_ma_60"] + 1e-9)

    # 指标 2: 成交量突增比 (5min 均值 / 前 60min 均值)
    d["vol_ratio_5v60"] = d["volume"].rolling(5, min_periods=2).mean() / (d["vol_ma_60"] + 1e-9)

    # 指标 3: 方向一致性 (最近 5 根 bar 同色比例)
    d["bull_ratio_5"] = d["is_bull"].rolling(5, min_periods=2).mean()
    d["bear_ratio_5"] = d["is_bear"].rolling(5, min_periods=2).mean()
    d["dir_consistency_5"] = np.maximum(d["bull_ratio_5"], d["bear_ratio_5"])

    # 指标 4: 累积净变动 (最近 15 根 close 变化)
    d["net_move_15"] = d["close"] - d["close"].shift(15)
    d["net_move_15_abs"] = d["net_move_15"].abs()

    # 指标 5: 距近期高低点的距离 (突破边缘)
    d["hi_60"] = d["high"].rolling(60, min_periods=15).max()
    d["lo_60"] = d["low"].rolling(60, min_periods=15).min()
    d["dist_from_hi_60"] = d["hi_60"] - d["close"]  # 距60分钟高点向下距离
    d["dist_from_lo_60"] = d["close"] - d["lo_60"]  # 距60分钟低点向上距离
    d["range_60"] = d["hi_60"] - d["lo_60"]
    d["near_hi_60"] = (d["close"] >= d["hi_60"] - 1.0).astype(int)  # 在1美元内接近高点
    d["near_lo_60"] = (d["close"] <= d["lo_60"] + 1.0).astype(int)

    return d


def cohen_d(a: np.ndarray, b: np.ndarray) -> float:
    """Cohen's d 效应量 (>0.2 小 / >0.5 中 / >0.8 大)"""
    a = np.asarray(a, dtype=float); b = np.asarray(b, dtype=float)
    a = a[np.isfinite(a)]; b = b[np.isfinite(b)]
    if len(a) < 2 or len(b) < 2:
        return np.nan
    sd = np.sqrt((a.var(ddof=1) + b.var(ddof=1)) / 2)
    if sd == 0:
        return np.nan
    return (a.mean() - b.mean()) / sd


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--window", type=int, default=240, help="事件前分钟数")
    ap.add_argument("--n-control", type=int, default=500, help="对照样本数(每小时约 n/24)")
    args = ap.parse_args()

    print("[load] 加载数据 + 计算因果特征")
    df = pd.read_parquet(RAW)
    df = compute_features(df).reset_index(drop=True)
    df["idx"] = df.index
    # 用 tz-naive 时间戳做 searchsorted (df["time"] 是 tz-aware, 但内部存储为 UTC)
    times_int = df["time"].astype("int64").values  # ns since epoch

    def find_idx(t: pd.Timestamp) -> int:
        t_ns = t.value  # ns since epoch (UTC)
        i = int(np.searchsorted(times_int, t_ns))
        if i < len(times_int) and times_int[i] == t_ns:
            return i
        return -1

    hits = pd.read_csv(HITS)
    hits["start_utc"] = pd.to_datetime(hits["start_utc"], utc=True)
    print(f"[hits] {len(hits)} 个命中事件")

    # === 1) 提取每个事件前 W 分钟的详细序列 ===
    W = args.window
    rows = []
    missing = 0
    for _, h in hits.iterrows():
        t = h["start_utc"]
        i = find_idx(t)
        if i < 0:
            missing += 1
            continue
        s = max(0, i - W)
        seg = df.iloc[s:i+1].copy()
        seg["event_start_utc"] = t
        seg["event_direction"] = h["方向"]
        seg["minutes_before"] = (t - seg["time"]).dt.total_seconds() / 60
        rows.append(seg)
    print(f"[match] 匹配到 {len(rows)}/{len(hits)} 个事件 (missing={missing})")
    if not rows:
        raise SystemExit("没有事件能在 raw 数据中定位, 检查时间戳格式")
    detail = pd.concat(rows, ignore_index=True)
    out_events = HERE / "../data/processed/precursor_events.csv"
    keep_cols = ["event_start_utc", "event_direction", "time", "minutes_before",
                 "open", "high", "low", "close", "volume", "tr", "body",
                 "tr_ratio_5v60", "vol_ratio_5v60", "dir_consistency_5",
                 "net_move_15", "dist_from_hi_60", "dist_from_lo_60", "range_60",
                 "near_hi_60", "near_lo_60"]
    detail[keep_cols].to_csv(out_events, index=False, encoding="utf-8-sig")
    print(f"[save] {out_events}  ({len(detail):,} rows)")

    # === 2) 关键时点快照 ===
    snap_offsets = [1, 5, 15, 30, 60, 120]
    snap_rows = []
    for _, h in hits.iterrows():
        t = h["start_utc"]
        i = find_idx(t)
        if i < 0:
            continue
        rec = {"event": t.strftime("%Y-%m-%d %H:%M"), "direction": h["方向"]}
        for off in snap_offsets:
            j = i - off
            if j < 0:
                continue
            r = df.iloc[j]
            rec[f"tr_ratio@-{off}"] = r["tr_ratio_5v60"]
            rec[f"vol_ratio@-{off}"] = r["vol_ratio_5v60"]
            rec[f"dir_cons@-{off}"] = r["dir_consistency_5"]
            rec[f"net_move15@-{off}"] = r["net_move_15"]
            rec[f"near_hi@-{off}"] = int(r["near_hi_60"])
            rec[f"near_lo@-{off}"] = int(r["near_lo_60"])
        snap_rows.append(rec)
    snap = pd.DataFrame(snap_rows)
    out_snap = HERE / "../data/processed/precursor_snapshots.csv"
    snap.to_csv(out_snap, index=False, encoding="utf-8-sig")
    print(f"[save] {out_snap}")

    # === 3) 对照样本 (随机 bar, 相同小时分布, 非事件±240min 内) ===
    print(f"[control] 采样 {args.n_control} 个对照 bar")
    rng = np.random.default_rng(42)
    hit_idxs = set()
    for _, h in hits.iterrows():
        t = h["start_utc"]
        i = find_idx(t)
        if i < 0:
            continue
        # 事件 ±240min 的 bar 都算 "事件区域", 不做对照
        for k in range(i - W, i + W + 1):
            hit_idxs.add(k)

    all_idxs = set(range(W, len(df) - 1))
    ctrl_pool = list(all_idxs - hit_idxs)
    ctrl_pick = rng.choice(ctrl_pool, size=min(args.n_control, len(ctrl_pool)), replace=False)
    ctrl = df.iloc[ctrl_pick].copy()

    # === 4) 事件前 t-30 ~ t-1 均值 vs 对照 均值 ===
    print("\n" + "=" * 72)
    print("== 事件前 30 分钟均值 vs 对照 (Cohen's d 效应量) ==")
    print("=" * 72)
    metrics = ["tr", "volume", "tr_ratio_5v60", "vol_ratio_5v60",
               "dir_consistency_5", "net_move_15_abs", "dist_from_hi_60", "dist_from_lo_60"]

    # 事件前 30min 平均值 (每个事件一个值)
    event_pre = detail[detail["minutes_before"].between(1, 30)].groupby("event_start_utc")[metrics].mean()
    ctrl_vals = ctrl[metrics]

    print(f"{'metric':<25} {'event_mean':>12} {'ctrl_mean':>12} {'Cohen d':>10}")
    print("-" * 72)
    for m in metrics:
        a = event_pre[m].values
        b = ctrl_vals[m].values
        d = cohen_d(a, b)
        emean = np.nanmean(a); cmean = np.nanmean(b)
        marker = "  ***" if abs(d) > 0.8 else ("  **" if abs(d) > 0.5 else ("  *" if abs(d) > 0.2 else ""))
        print(f"{m:<25} {emean:>12.4f} {cmean:>12.4f} {d:>10.3f}{marker}")

    print("\n效应量: |d|>0.2 小* / >0.5 中** / >0.8 大***")
    print(f"\n[save] {out_events}  逐分钟明细")
    print(f"[save] {out_snap}  关键时点快照")


if __name__ == "__main__":
    main()
