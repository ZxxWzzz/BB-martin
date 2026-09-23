"""网格扫描: 找 (recall, 冷却时长占比) 的 Pareto 前沿."""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pandas as pd

HERE = Path(__file__).parent
PROC = HERE / "../data/processed"


def simulate(trigger, times_int, ev_times_int, cooldown_min: int, ev_times_idx):
    n = len(trigger)
    cooldown = np.zeros(n, dtype=bool)
    cooldown_until = np.datetime64("2000-01-01T00:00:00", "ns").view("int64")
    cd_starts = 0
    cd_min_ns = cooldown_min * 60 * 1_000_000_000
    for i in range(n):
        t = times_int[i]
        if t < cooldown_until:
            cooldown[i] = True
        elif trigger[i]:
            cooldown[i] = True
            cd_starts += 1
            cooldown_until = t + cd_min_ns

    caught = 0
    for j, i in enumerate(ev_times_idx):
        if i < 0: continue
        i0 = max(0, i - 60)
        if cooldown[i0:i+1].any():
            caught += 1
    cd_pct = cooldown.mean() * 100
    return caught, cd_starts, cd_pct


def main():
    print("[load]")
    df = pd.read_parquet(PROC / "features.parquet").sort_values("time").reset_index(drop=True)
    hits = pd.read_csv(PROC / "hits.csv")
    hits["start_utc"] = pd.to_datetime(hits["start_utc"], utc=True)

    times_int = df["time"].values.view("int64")
    ev_times_int = np.array([h.value for h in hits["start_utc"]])
    ev_idx = []
    for t_ns in ev_times_int:
        i = int(np.searchsorted(times_int, t_ns))
        ev_idx.append(i if i < len(times_int) and times_int[i] == t_ns else -1)
    ev_idx = np.array(ev_idx)
    n_ev = int((ev_idx >= 0).sum())
    print(f"  matched events: {n_ev}/{len(hits)}")

    xau_tr = df["xau_tr"].fillna(0).values
    xau_r60 = df["xau_net_ret_60"].fillna(0).values
    spx_r60 = df["spx_net_ret_60"].fillna(0).values
    wti_r60 = df["wti_net_ret_60"].fillna(0).values
    tr_ratio = df["xau_tr_ratio_5v60"].fillna(0).values
    hour = df["time"].dt.hour.values

    # 事件高发时段: UTC 01-04, 13-16 (从 analyze_hits 结果)
    hot_hour_mask = np.isin(hour, [1, 2, 3, 4, 13, 14, 15, 16])

    scenarios = []

    # 1) R1: 单纯 tr 阈值扫描
    for thr in [2.5, 3.0, 3.5, 4.0, 4.5, 5.0, 6.0, 7.0]:
        trig = xau_tr > thr
        c, s, p = simulate(trig, times_int, ev_times_int, 60, ev_idx)
        scenarios.append({"rule": f"R1 tr>{thr}", "caught": c, "cds": s, "cd_pct": p, "recall": c/n_ev})

    # 2) 相对倍率
    for thr in [2.0, 2.5, 3.0, 4.0, 5.0]:
        trig = tr_ratio > thr
        c, s, p = simulate(trig, times_int, ev_times_int, 60, ev_idx)
        scenarios.append({"rule": f"Rratio 5v60>{thr}x", "caught": c, "cds": s, "cd_pct": p, "recall": c/n_ev})

    # 3) R6: tr + xau_60 跌
    for tr_thr in [2.5, 3.0, 3.5, 4.0, 5.0]:
        for ret_thr in [-0.0005, -0.001, -0.002]:
            trig = (xau_tr > tr_thr) & (xau_r60 < ret_thr)
            c, s, p = simulate(trig, times_int, ev_times_int, 60, ev_idx)
            scenarios.append({"rule": f"R6 tr>{tr_thr} & xau60<{ret_thr*100:+.2f}%",
                              "caught": c, "cds": s, "cd_pct": p, "recall": c/n_ev})

    # 4) R1 + hot hours only
    for thr in [2.5, 3.0, 3.5, 4.0, 5.0]:
        trig = (xau_tr > thr) & hot_hour_mask
        c, s, p = simulate(trig, times_int, ev_times_int, 60, ev_idx)
        scenarios.append({"rule": f"R1_hot tr>{thr} in hot_hours", "caught": c, "cds": s, "cd_pct": p, "recall": c/n_ev})

    # 5) 三重共振
    for xau_thr in [-0.001, -0.002]:
        for spx_thr in [-0.0004, -0.0006, -0.001]:
            for wti_thr in [0.001, 0.002, 0.003]:
                trig = (xau_r60 < xau_thr) & (spx_r60 < spx_thr) & (wti_r60 > wti_thr)
                c, s, p = simulate(trig, times_int, ev_times_int, 60, ev_idx)
                scenarios.append({"rule": f"R8 xau<{xau_thr*100:+.1f}% spx<{spx_thr*100:+.2f}% wti>{wti_thr*100:+.1f}%",
                                  "caught": c, "cds": s, "cd_pct": p, "recall": c/n_ev})

    res = pd.DataFrame(scenarios)
    # 找 Pareto 前沿: 对每个 recall 水平, 找 cd_pct 最低的
    res = res.sort_values(["recall", "cd_pct"], ascending=[False, True])
    print("\n" + "=" * 100)
    print("== 阈值扫描 (按 recall 降序) ==")
    print("=" * 100)
    print(f"{'rule':<55} {'caught':>7} {'recall':>7} {'cd_pct':>7} {'cds':>7}")
    print("-" * 100)
    for _, r in res.iterrows():
        marker = ""
        # 标记有价值的组合: recall>60% & cd<20%, 或 recall>80% & cd<30%
        if r["recall"] >= 0.60 and r["cd_pct"] < 20: marker = "  ⭐"
        if r["recall"] >= 0.80 and r["cd_pct"] < 30: marker = "  ⭐⭐"
        if r["recall"] >= 0.90 and r["cd_pct"] < 20: marker = "  ⭐⭐⭐"
        print(f"{r['rule']:<55} {r['caught']:>3}/{n_ev} {r['recall']:>7.1%} {r['cd_pct']:>6.2f}% {r['cds']:>7,}{marker}")

    res.to_csv(PROC / "backtest_grid.csv", index=False, encoding="utf-8-sig")
    print(f"\n[save] {PROC / 'backtest_grid.csv'}")

    # 找出 Pareto 前沿 (对每个 recall 分位, cd_pct 最低)
    print("\n== 分档 Pareto ==")
    for rec_min in [0.9, 0.8, 0.7, 0.6, 0.5]:
        sub = res[res["recall"] >= rec_min]
        if len(sub):
            best = sub.nsmallest(1, "cd_pct").iloc[0]
            print(f"  recall≥{rec_min:.0%}:  best cd_pct={best['cd_pct']:.2f}%  rule={best['rule']}")


if __name__ == "__main__":
    main()
