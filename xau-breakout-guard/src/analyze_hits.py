"""扫描全量 M1, 找出「单边>=58点且中途反向<8点」的起点 bar, 输出明细表.

用法:
    python analyze_hits.py              # 用 config 里的默认 58/8
    python analyze_hits.py --move 60 --pull 10
    python analyze_hits.py --top 500    # 只导出前 500 条

输出:
    data/processed/hits.csv         明细表 (给你人工反推用)
    data/processed/hits_summary.txt 汇总统计
"""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import pandas as pd
import yaml
from numba import njit, prange

HERE = Path(__file__).parent
CFG = yaml.safe_load((HERE / "config.yaml").open("r", encoding="utf-8"))


@njit(cache=True, parallel=True)
def _scan(close, high, low, thr_move, thr_pull, max_bars):
    """对每根 bar 判定. 返回 label / direction / bars_to_hit / max_run.

    label: 1=命中危险, 0=安全被回撤, -1=扫到 max_bars 无事件
    direction: +1 上涨命中, -1 下跌命中, 0 未命中
    bars_to_hit: 命中/淘汰所用 bar 数
    max_run: 命中方向上从 c0 走出的最大行程 ($)
    """
    n = len(close)
    label = np.full(n, -1, dtype=np.int8)
    direction = np.zeros(n, dtype=np.int8)
    bars_to_hit = np.full(n, -1, dtype=np.int32)
    max_run = np.zeros(n, dtype=np.float64)

    for i in prange(n):
        if i + max_bars >= n:
            continue
        c0 = close[i]
        hi_since = c0
        lo_since = c0
        for j in range(i + 1, i + 1 + max_bars):
            h = high[j]
            l = low[j]
            if h > hi_since:
                hi_since = h
            if l < lo_since:
                lo_since = l
            up_run = hi_since - c0
            dn_run = c0 - lo_since
            up_pull = hi_since - l
            dn_pull = h - lo_since

            if up_run >= dn_run:
                if up_pull >= thr_pull:
                    label[i] = 0
                    bars_to_hit[i] = j - i
                    break
                if up_run >= thr_move:
                    label[i] = 1
                    direction[i] = 1
                    bars_to_hit[i] = j - i
                    max_run[i] = up_run
                    break
            else:
                if dn_pull >= thr_pull:
                    label[i] = 0
                    bars_to_hit[i] = j - i
                    break
                if dn_run >= thr_move:
                    label[i] = 1
                    direction[i] = -1
                    bars_to_hit[i] = j - i
                    max_run[i] = dn_run
                    break
    return label, direction, bars_to_hit, max_run


def summarize(hits: pd.DataFrame) -> str:
    lines = []
    lines.append(f"命中总数: {len(hits):,}")
    lines.append(f"上涨命中: {(hits['direction']==1).sum():,}  下跌命中: {(hits['direction']==-1).sum():,}")
    lines.append("")
    lines.append("== 触发速度 (bars_to_hit 分位) ==")
    for q in (0.05, 0.25, 0.5, 0.75, 0.95):
        lines.append(f"  P{int(q*100):02d}: {hits['bars_to_hit'].quantile(q):.0f} 分钟")
    lines.append("")
    lines.append("== 最大行程 ($) 分位 ==")
    for q in (0.05, 0.25, 0.5, 0.75, 0.95, 0.99):
        lines.append(f"  P{int(q*100):02d}: ${hits['max_run'].quantile(q):.1f}")
    lines.append("")
    lines.append("== 按 UTC 小时分布 ==")
    by_hour = hits.groupby(hits["time"].dt.hour).size()
    for h, c in by_hour.items():
        bar = "#" * int(c / by_hour.max() * 40)
        lines.append(f"  {h:02d}:00  {c:>5}  {bar}")
    lines.append("")
    lines.append("== 按星期分布 (0=Mon) ==")
    by_dow = hits.groupby(hits["time"].dt.dayofweek).size()
    dow_name = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    for d, c in by_dow.items():
        bar = "#" * int(c / by_dow.max() * 40)
        lines.append(f"  {dow_name[d]}  {c:>5}  {bar}")
    lines.append("")
    lines.append("== 按月份分布 ==")
    by_month = hits.groupby(hits["time"].dt.to_period("M")).size()
    for m, c in by_month.items():
        bar = "#" * int(c / by_month.max() * 40)
        lines.append(f"  {m}  {c:>5}  {bar}")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--move", type=float, default=None, help="单边阈值 ($), 默认从 config")
    ap.add_argument("--pull", type=float, default=None, help="回撤阈值 ($), 默认从 config")
    ap.add_argument("--max-bars", type=int, default=None)
    ap.add_argument("--top", type=int, default=None, help="只输出前 N 条")
    args = ap.parse_args()

    thr_move = args.move or float(CFG["label"]["threshold_move"])
    thr_pull = args.pull or float(CFG["label"]["threshold_pullback"])
    max_bars = args.max_bars or int(CFG["label"]["scan_max_bars"])

    raw = (HERE / CFG["fetch"]["raw_path"]).resolve()
    if not raw.exists():
        raise SystemExit(f"raw 数据不存在: {raw}  先跑 fetch_mt5.py")
    df = pd.read_parquet(raw)
    print(f"[load] {len(df):,} bars  {df['time'].iloc[0]} ~ {df['time'].iloc[-1]}")
    print(f"[scan] move>={thr_move}  pull<{thr_pull}  max_bars={max_bars}")

    label, direction, bars_to_hit, max_run = _scan(
        df["close"].to_numpy(np.float64),
        df["high"].to_numpy(np.float64),
        df["low"].to_numpy(np.float64),
        thr_move, thr_pull, max_bars,
    )

    df["label"] = label
    df["direction"] = direction
    df["bars_to_hit"] = bars_to_hit
    df["max_run"] = max_run

    hits_all = df[df["label"] == 1].copy().reset_index(drop=True)
    print(f"[hits] raw {len(hits_all):,} 条 (含同波行情多次触发)")

    # 去重: 相邻 bar 且方向相同且时间窗口重叠 -> 视为同一事件, 保留第一个
    # 判定规则: hit[i].time <= hit[i-1].time + hit[i-1].bars_to_hit 分钟, 且 direction 相同
    hits_all = hits_all.sort_values("time").reset_index(drop=True)
    keep = [True] * len(hits_all)
    for k in range(1, len(hits_all)):
        prev = hits_all.iloc[k-1]
        cur = hits_all.iloc[k]
        # 如果当前 hit 落在前一个 hit 的"触发窗口"内, 且方向相同, 认为是同一波行情
        prev_end = prev["time"] + pd.Timedelta(minutes=int(prev["bars_to_hit"]))
        if cur["time"] <= prev_end and cur["direction"] == prev["direction"]:
            keep[k] = False
    hits = hits_all[keep].reset_index(drop=True)
    print(f"[hits] dedup {len(hits):,} 个独立事件 (合并同波行情)")

    # 附加人工反推友好的列
    # 前 N 根 bar 的上下文 (方便你查看是不是新闻/开盘/收盘)
    hits["utc_hour"] = hits["time"].dt.hour
    hits["utc_minute"] = hits["time"].dt.minute
    hits["weekday"] = hits["time"].dt.day_name().str[:3]
    hits["date"] = hits["time"].dt.date

    # 起点 bar 本身的形态特征 (人眼可读)
    hits["bar_range"] = (hits["high"] - hits["low"]).round(2)
    hits["bar_body"] = (hits["close"] - hits["open"]).round(2)
    hits["bar_dir"] = np.where(hits["bar_body"] > 0, "🟢", np.where(hits["bar_body"] < 0, "🔴", "-"))

    hits["direction_str"] = hits["direction"].map({1: "UP↑", -1: "DN↓"})

    # 导出列排序
    cols = ["date", "time", "utc_hour", "weekday", "direction_str",
            "open", "high", "low", "close", "bar_range", "bar_body", "bar_dir",
            "volume", "spread", "bars_to_hit", "max_run"]
    hits_out = hits[cols].copy()
    hits_out = hits_out.rename(columns={
        "time": "start_utc",
        "direction_str": "方向",
        "bars_to_hit": "触发分钟数",
        "max_run": "最大行程($)",
    })

    if args.top:
        hits_out = hits_out.head(args.top)

    out_csv = (HERE / "../data/processed/hits.csv").resolve()
    out_csv.parent.mkdir(parents=True, exist_ok=True)
    hits_out.to_csv(out_csv, index=False, encoding="utf-8-sig")
    print(f"[save] {out_csv}  ({len(hits_out):,} 行)")

    summary = summarize(hits)
    print("\n" + summary)
    (out_csv.parent / "hits_summary.txt").write_text(summary, encoding="utf-8")
    print(f"[save] {out_csv.parent / 'hits_summary.txt'}")


if __name__ == "__main__":
    main()
