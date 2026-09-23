"""回测: R1 (xau_tr > $2.5) 规则 + 60min 冷却期 的实际拦截表现.

模拟逻辑:
    - 逐 bar 扫描, 若规则触发 => 设置 cooldown_until = t + 60min (若已在冷却期, 顺延)
    - 事件在 [event_start, event_start] 时刻发生 => 若此时 cooldown 有效, 视为"成功拦截"
    - 事件前 [event_start - 60min, event_start] 期间若冷却已激活, 也算拦截 (提前进入保护)

输出指标:
    caught_events / n_events      拦截率 (recall)
    total_cooldown_hours          总冷却时长 (EA 被禁止开仓的小时数)
    cooldown_pct_of_time          冷却时长占总时间的百分比
    false_cooldowns               既不覆盖事件也不与事件相邻的冷却次数
    true_cooldowns                覆盖到事件的冷却次数
    events_missed                 完全没被冷却期覆盖的事件

用法:
    python backtest.py                    # 默认 R1 tr>2.5, 冷却 60min
    python backtest.py --tr-thr 3.0 --cooldown 90
"""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import pandas as pd

HERE = Path(__file__).parent
PROC = HERE / "../data/processed"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tr-thr", type=float, default=2.5, help="R1 XAU tr 阈值 ($)")
    ap.add_argument("--cooldown", type=int, default=60, help="冷却期 (分钟)")
    ap.add_argument("--rule", type=str, default="R1", choices=["R1", "R6", "R8"],
                    help="规则: R1=只看 tr, R6=tr+XAU跌, R8=SPX跌+WTI涨+XAU跌")
    args = ap.parse_args()

    print("[load]")
    df = pd.read_parquet(PROC / "features.parquet").sort_values("time").reset_index(drop=True)
    hits = pd.read_csv(PROC / "hits.csv")
    hits["start_utc"] = pd.to_datetime(hits["start_utc"], utc=True)
    print(f"  features {len(df):,} bars, {len(hits)} events")

    # 构建触发 mask
    if args.rule == "R1":
        trigger = (df["xau_tr"] > args.tr_thr).fillna(False).values
        rule_desc = f"R1: xau_tr > {args.tr_thr}"
    elif args.rule == "R6":
        r1 = df["xau_tr"] > args.tr_thr
        r4 = df["xau_net_ret_60"] < -0.001
        trigger = (r1 & r4).fillna(False).values
        rule_desc = f"R6: xau_tr>{args.tr_thr} & xau_60<-0.10%"
    else:  # R8
        r2 = df["spx_net_ret_60"] < -0.0006
        r3 = df["wti_net_ret_60"] > 0.002
        r4 = df["xau_net_ret_60"] < -0.001
        trigger = (r2 & r3 & r4).fillna(False).values
        rule_desc = f"R8: spx<-0.06% & wti>+0.20% & xau<-0.10%"

    print(f"[rule] {rule_desc}, cooldown={args.cooldown}min")

    # 逐 bar 模拟冷却状态
    df_times = df["time"].values  # numpy datetime64
    cooldown = np.zeros(len(df), dtype=bool)     # 该 bar 是否在冷却期内
    cooldown_start_idx = -1
    cooldown_until = np.datetime64("2000-01-01T00:00:00", "ns")
    cd_starts = []                                # 每次冷却开始 idx
    for i in range(len(df)):
        t = df_times[i]
        if t < cooldown_until:
            cooldown[i] = True
        else:
            if trigger[i]:
                cooldown[i] = True
                cd_starts.append(i)
                cooldown_until = t + np.timedelta64(args.cooldown, "m")

    print(f"[sim] 独立冷却次数: {len(cd_starts):,}")
    print(f"[sim] 冷却总 bar 数: {cooldown.sum():,}  ({cooldown.mean()*100:.2f}% of time)")
    total_hours = cooldown.sum() / 60
    print(f"[sim] 冷却总时长: {total_hours:.1f} 小时")

    # 事件是否被冷却覆盖
    times_int = df_times.view("int64")
    caught = []
    missed = []
    for _, h in hits.iterrows():
        t = h["start_utc"]
        t_ns = t.value
        i = int(np.searchsorted(times_int, t_ns))
        if i >= len(df) or times_int[i] != t_ns:
            continue
        # 检查 event 前 60min 到 event 时刻, 有没有 cooldown 覆盖
        i0 = max(0, i - 60)
        if cooldown[i0:i+1].any():
            caught.append((t, h["方向"]))
        else:
            missed.append((t, h["方向"]))
    n_caught = len(caught); n_missed = len(missed); n_ev = len(hits)
    print(f"\n[result] 拦截 {n_caught}/{n_ev} ({n_caught/n_ev*100:.1f}%)  漏 {n_missed}")

    # 分类冷却次数: 覆盖到事件的 vs 完全无关的
    ev_times_int = np.array([h["start_utc"].value for _, h in hits.iterrows()])
    tp_cds = 0; fp_cds = 0
    for cd_i in cd_starts:
        cd_start_ns = times_int[cd_i]
        cd_end_ns = cd_start_ns + args.cooldown * 60 * 1_000_000_000
        # 冷却期内是否有事件 起点或前 60min 覆盖
        in_range = ((ev_times_int >= cd_start_ns) & (ev_times_int <= cd_end_ns + 60*60*1_000_000_000)) | \
                   ((ev_times_int >= cd_start_ns - 60*60*1_000_000_000) & (ev_times_int <= cd_end_ns))
        if in_range.any():
            tp_cds += 1
        else:
            fp_cds += 1
    print(f"[quality] 冷却次数分类: 覆盖事件={tp_cds}  纯误报={fp_cds}  precision={tp_cds/(tp_cds+fp_cds)*100:.1f}%")

    # 按月看拦截时长分布
    df["cooldown"] = cooldown
    df["month"] = df["time"].dt.to_period("M").astype(str)
    monthly = df.groupby("month")["cooldown"].agg(["sum", "count"])
    monthly["cd_hours"] = monthly["sum"] / 60
    monthly["cd_pct"] = monthly["sum"] / monthly["count"] * 100
    print("\n== 按月冷却时长 ==")
    print(f"{'month':<10} {'cd_hours':>10} {'cd_pct':>8}")
    for m, row in monthly.iterrows():
        print(f"{m:<10} {row['cd_hours']:>10.1f} {row['cd_pct']:>7.1f}%")

    # 漏掉的事件
    if missed:
        print(f"\n== 漏掉的 {n_missed} 个事件 ==")
        for t, d in missed:
            print(f"  {t}  {d}")

    # 保存结果
    out = PROC / f"backtest_{args.rule}_tr{args.tr_thr}_cd{args.cooldown}.csv"
    df[["time", "xau_tr", "xau_net_ret_60", "cooldown"]].to_csv(out, index=False)
    print(f"\n[save] {out}")


if __name__ == "__main__":
    main()
