"""日K高波动过滤 + M1精细扫描.

流程:
    1. M1数据按自然日聚合 -> 计算每日 H-L range
    2. 筛选 range > daily_range_thr 的日期 (减少无效扫描)
    3. 提取这些日期的M1棒 + 前后 buffer_hours 缓冲 (防止跨日事件被截断)
    4. 对子集跑 _scan 核 (逻辑与 analyze_hits 完全一致)
    5. dedup, 输出事件列表

用法:
    python scan_daily_filter.py
    python scan_daily_filter.py --move 50 --pull 8 --daily-range 50
    python scan_daily_filter.py --move 50 --pull 8 --daily-range 60
"""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import pandas as pd
import yaml

from analyze_hits import _scan

HERE = Path(__file__).parent
CFG = yaml.safe_load((HERE / "config.yaml").open("r", encoding="utf-8"))


def dedup(hits_all: pd.DataFrame) -> pd.DataFrame:
    """同波去重: 当前 hit 落在前一 hit 触发窗口内且同向 -> 合并."""
    if hits_all.empty:
        return hits_all.reset_index(drop=True)
    hits_all = hits_all.sort_values("time").reset_index(drop=True)
    keep = np.ones(len(hits_all), dtype=bool)
    for k in range(1, len(hits_all)):
        prev = hits_all.iloc[k - 1]
        cur = hits_all.iloc[k]
        prev_end = prev["time"] + pd.Timedelta(minutes=int(prev["bars_to_hit"]))
        if cur["time"] <= prev_end and cur["direction"] == prev["direction"]:
            keep[k] = False
    return hits_all[keep].reset_index(drop=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--move", type=float, default=50.0, help="单边阈值 ($)")
    ap.add_argument("--pull", type=float, default=8.0,  help="反弹阈值 ($)")
    ap.add_argument("--daily-range", type=float, default=50.0,
                    help="日K高低差过滤阈值 ($), 只保留波动 >= 该值的日期")
    ap.add_argument("--buffer-hours", type=int, default=4,
                    help="高波动日前后各加 N 小时缓冲 (防止跨日事件截断)")
    ap.add_argument("--max-bars", type=int, default=None)
    ap.add_argument("--out", type=str, default=None,
                    help="输出 CSV 路径 (默认 data/processed/daily_filter_events.csv)")
    args = ap.parse_args()

    max_bars = args.max_bars or int(CFG["label"]["scan_max_bars"])

    raw = (HERE / CFG["fetch"]["raw_path"]).resolve()
    print(f"[load] {raw}")
    df = pd.read_parquet(raw)
    df = df.sort_values("time").reset_index(drop=True)
    n_months = (df["time"].iloc[-1] - df["time"].iloc[0]).days / 30.44
    print(f"       {len(df):,} bars  {df['time'].iloc[0]} ~ {df['time'].iloc[-1]}"
          f"  (~{n_months:.1f} 月)")

    # ── 步骤1: 日K聚合, 计算 H-L range ────────────────────────────────────
    # 用 UTC date 作为分组键
    df["_date"] = df["time"].dt.date
    daily = df.groupby("_date").agg(
        d_high=("high", "max"),
        d_low=("low",  "min"),
    )
    daily["range"] = daily["d_high"] - daily["d_low"]
    total_days = len(daily)

    # ── 步骤2: 过滤高波动日 ───────────────────────────────────────────────
    hot_dates = set(daily.index[daily["range"] >= args.daily_range])
    print(f"\n[filter] 日K range >= ${args.daily_range:.0f}")
    print(f"         全部交易日: {total_days}  高波动日: {len(hot_dates)}"
          f"  ({len(hot_dates)/total_days*100:.1f}%)")

    # ── 步骤3: 提取子集 (带缓冲) ─────────────────────────────────────────
    buf = pd.Timedelta(hours=args.buffer_hours)
    # 对每个高波动日, 计算包含缓冲的时间窗口
    hot_dates_sorted = sorted(hot_dates)
    # 合并相邻/重叠的窗口 (防止重复 bar)
    windows: list[tuple[pd.Timestamp, pd.Timestamp]] = []
    for d in hot_dates_sorted:
        ts = pd.Timestamp(d, tz="UTC")
        w_start = ts - buf
        w_end   = ts + pd.Timedelta(days=1) + buf
        if windows and w_start <= windows[-1][1]:
            # 与上一个窗口合并
            windows[-1] = (windows[-1][0], max(windows[-1][1], w_end))
        else:
            windows.append((w_start, w_end))

    # 提取子集 bars
    mask = pd.Series(False, index=df.index)
    for ws, we in windows:
        mask |= (df["time"] >= ws) & (df["time"] <= we)
    sub = df[mask].reset_index(drop=True)
    print(f"         缓冲 ±{args.buffer_hours}h, 子集 bars: {len(sub):,}"
          f"  ({len(sub)/len(df)*100:.1f}% of total)")

    # ── 步骤4: 对子集跑 _scan ─────────────────────────────────────────────
    print(f"\n[scan]   move>=${args.move:.0f}  pull<${args.pull:.0f}  max_bars={max_bars}")
    close = sub["close"].to_numpy(np.float64)
    high  = sub["high"].to_numpy(np.float64)
    low   = sub["low"].to_numpy(np.float64)

    label, direction, bars_to_hit, max_run = _scan(
        close, high, low, float(args.move), float(args.pull), max_bars
    )

    base = sub[["time"]].copy()
    base["direction"]   = direction
    base["bars_to_hit"] = bars_to_hit
    base["max_run"]     = max_run
    base["label"]       = label

    hits_all = base[base["label"] == 1].reset_index(drop=True)
    hits     = dedup(hits_all)

    # ── 步骤5: 输出 ──────────────────────────────────────────────────────
    up   = int((hits["direction"] ==  1).sum())
    dn   = int((hits["direction"] == -1).sum())
    per_month = len(hits) / n_months
    med_run   = hits["max_run"].median()   if len(hits) else 0
    med_bars  = hits["bars_to_hit"].median() if len(hits) else 0

    print(f"\n{'指标':<20} {'值':>10}")
    print("-" * 32)
    print(f"{'日K过滤阈值':<20} ${args.daily_range:.0f}")
    print(f"{'高波动日数':<20} {len(hot_dates):>10}")
    print(f"{'子集bars':<20} {len(sub):>10,}")
    print(f"{'raw命中':<20} {len(hits_all):>10,}")
    print(f"{'独立事件(dedup)':<20} {len(hits):>10}")
    print(f"{'UP↑':<20} {up:>10}")
    print(f"{'DN↓':<20} {dn:>10}")
    print(f"{'月均':<20} {per_month:>10.1f}")
    print(f"{'中位行程$':<20} {med_run:>10.1f}")
    print(f"{'中位耗时min':<20} {med_bars:>10.0f}")

    if len(hits):
        print(f"\n== 事件列表 ==")
        print(f"{'时间(UTC)':<22} {'方向':>5} {'max_run$':>9} {'耗时min':>8}")
        print("-" * 50)
        for _, r in hits.iterrows():
            dir_str = "UP↑" if r["direction"] == 1 else "DN↓"
            print(f"{str(r['time']):<22} {dir_str:>5} {r['max_run']:>9.1f} {r['bars_to_hit']:>8.0f}")

    out_path = args.out or str((HERE / "../data/processed/daily_filter_events.csv").resolve())
    hits_out = hits.copy()
    hits_out["time_bj"] = (hits_out["time"] + pd.Timedelta(hours=8)).dt.strftime("%Y-%m-%d %H:%M")
    hits_out["direction_str"] = hits_out["direction"].map({1: "UP", -1: "DN"})
    hits_out.to_csv(out_path, index=False, encoding="utf-8-sig")
    print(f"\n[save] {out_path}")


if __name__ == "__main__":
    main()
