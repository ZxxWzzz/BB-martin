"""扫描多档 (单边阈值 / 反弹阈值) 组合, 统计独立事件数.

用法:
    python scan_thresholds.py
    python scan_thresholds.py --pull 8 --moves 50 60 70 80

复用 analyze_hits 的 numba 扫描核 + 同波去重逻辑, 对每档输出:
    raw     命中总数 (含同波多次触发)
    dedup   合并同波后的独立事件数
    UP/DN   多空拆分
    月均     独立事件 / 月
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
    ap.add_argument("--pull", type=float, default=8.0, help="反弹阈值 ($)")
    ap.add_argument("--moves", type=float, nargs="+", default=[50, 60, 70, 80, 100],
                    help="单边阈值列表 ($)")
    ap.add_argument("--max-bars", type=int, default=None)
    args = ap.parse_args()

    max_bars = args.max_bars or int(CFG["label"]["scan_max_bars"])

    raw = (HERE / CFG["fetch"]["raw_path"]).resolve()
    df = pd.read_parquet(raw)
    n_months = (df["time"].iloc[-1] - df["time"].iloc[0]).days / 30.44
    print(f"[load] {len(df):,} bars  {df['time'].iloc[0]} ~ {df['time'].iloc[-1]}  (~{n_months:.1f} 月)")
    print(f"[scan] pull<{args.pull}  max_bars={max_bars}\n")

    close = df["close"].to_numpy(np.float64)
    high = df["high"].to_numpy(np.float64)
    low = df["low"].to_numpy(np.float64)

    print(f"{'规则':<12} {'raw命中':>10} {'独立事件':>10} {'UP↑':>6} {'DN↓':>6} {'月均':>8} {'中位行程$':>10} {'中位耗时min':>12}")
    print("-" * 84)

    rows = []
    for mv in args.moves:
        label, direction, bars_to_hit, max_run = _scan(close, high, low, float(mv), args.pull, max_bars)
        base = df[["time"]].copy()
        base["direction"] = direction
        base["bars_to_hit"] = bars_to_hit
        base["max_run"] = max_run
        base["label"] = label
        hits_all = base[base["label"] == 1].reset_index(drop=True)
        hits = dedup(hits_all)

        up = int((hits["direction"] == 1).sum())
        dn = int((hits["direction"] == -1).sum())
        med_run = hits["max_run"].median() if len(hits) else 0
        med_bars = hits["bars_to_hit"].median() if len(hits) else 0
        per_month = len(hits) / n_months

        tag = f"{int(mv)}/{int(args.pull)}"
        print(f"{tag:<12} {len(hits_all):>10,} {len(hits):>10} {up:>6} {dn:>6} "
              f"{per_month:>8.1f} {med_run:>10.1f} {med_bars:>12.0f}")
        rows.append({
            "rule": tag, "move": mv, "pull": args.pull,
            "raw_hits": len(hits_all), "events": len(hits),
            "up": up, "dn": dn, "per_month": round(per_month, 2),
            "median_run": round(float(med_run), 1), "median_bars": int(med_bars),
        })

    out = (HERE / "../data/processed/threshold_scan.csv").resolve()
    pd.DataFrame(rows).to_csv(out, index=False, encoding="utf-8-sig")
    print(f"\n[save] {out}")


if __name__ == "__main__":
    main()
