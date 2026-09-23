"""基于前兆分析结论手写规则引擎, 评估每条规则的召回/精度/触发频率.

阳性窗口定义:
    每个命中事件的起点 t, 定义 [t-60min, t-5min] 为阳性窗口. 只要规则在窗口内触发一次
    就算 "成功预警" 该事件.

规则库 (每条都有可调阈值, 先给一组默认):
    R1: xau_tr > x1_tr_thr                    (XAU 波幅突增)
    R2: spx_net_ret_60 < -x2_spx_thr          (SPX 60min 明显下跌)
    R3: wti_net_ret_60 > x3_wti_thr           (WTI 60min 明显上涨)
    R4: xau_net_ret_60 < -x4_xau_thr          (XAU 60min 温和下跌)
    R5: xau_dir_cons_5 < 0.6                  (XAU 方向纠结)
    R6: R1 & R4                               (波幅突增 + XAU下跌)
    R7: R2 & R3                               (SPX跌 + WTI涨 => risk-off + 地缘)
    R8: R2 & R3 & R4                          (三重共振)
    R9: R1 | R8                               (任一触发)

评估指标 (对每条规则):
    recall   = 触发到的事件数 / 35
    fires    = 全量数据里触发的总 bar 数
    fires/日 = 平均每交易日触发几次 (=> EA 拦截频率)
    precision = fires 里在阳性窗口内的比例
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pandas as pd

HERE = Path(__file__).parent
PROC = HERE / "../data/processed"


def main():
    print("[load]")
    df = pd.read_parquet(PROC / "features.parquet").sort_values("time").reset_index(drop=True)
    hits = pd.read_csv(PROC / "hits.csv")
    hits["start_utc"] = pd.to_datetime(hits["start_utc"], utc=True)
    print(f"  features: {len(df):,} rows")
    print(f"  events:   {len(hits)} 个独立事件")

    # 构建阳性窗口 mask
    df_times = df["time"].astype("int64").values
    pos_window = np.zeros(len(df), dtype=bool)
    event_id = np.full(len(df), -1, dtype=np.int32)
    for ei, (_, h) in enumerate(hits.iterrows()):
        t = h["start_utc"]
        t_ns = t.value
        start_ns = t_ns - 60 * 60 * 1_000_000_000     # t - 60min
        end_ns = t_ns - 5 * 60 * 1_000_000_000        # t - 5min
        mask = (df_times >= start_ns) & (df_times <= end_ns)
        pos_window |= mask
        event_id[mask] = ei

    print(f"[window] 阳性窗口 bar 数: {pos_window.sum():,}")

    # === 规则定义 ===
    # 取事件前 30min 均值作参考 (analyze_multivariate 里的结果), 阈值稍严格于均值
    R1 = df["xau_tr"] > 2.5                                # 事件前 tr 均值 2.06, 用 2.5 更严
    R2 = df["spx_net_ret_60"] < -0.0006                    # 事件前 spx_net_ret_60 均值 -0.06%, 用 -0.06%
    R3 = df["wti_net_ret_60"] > 0.0020                     # 事件前 wti_net_ret_60 均值 +0.21%, 用 +0.2%
    R4 = df["xau_net_ret_60"] < -0.0010                    # 事件前 xau_net_ret_60 均值 -0.11%, 用 -0.1%
    R5 = df["xau_dir_cons_5"] < 0.6                        # 方向纠结

    R6 = R1 & R4
    R7 = R2 & R3
    R8 = R2 & R3 & R4
    R9 = R1 | R8

    rules = {
        "R1_xau_tr>2.5":        R1,
        "R2_spx_60<-0.06%":     R2,
        "R3_wti_60>+0.20%":     R3,
        "R4_xau_60<-0.10%":     R4,
        "R5_dir_cons_5<0.6":    R5,
        "R6_R1&R4":             R6,
        "R7_R2&R3":             R7,
        "R8_R2&R3&R4":          R8,
        "R9_R1|R8":             R9,
    }

    # === 评估每条规则 ===
    n_days = (df["time"].iloc[-1] - df["time"].iloc[0]).days
    n_ev = len(hits)

    rows = []
    for name, mask in rules.items():
        mask = mask.fillna(False).values
        fires = int(mask.sum())
        # 触发到的事件数 = 触发 bar 落在阳性窗口内, 覆盖的不同 event_id 数
        hit_events = np.unique(event_id[mask & pos_window])
        hit_events = hit_events[hit_events >= 0]
        n_caught = len(hit_events)
        # precision: 触发时刻在阳性窗口内的比例
        in_pos = int((mask & pos_window).sum())
        prec = in_pos / fires if fires else np.nan
        # 触发率 (每天)
        fires_per_day = fires / n_days
        rows.append({
            "rule": name,
            "recall": n_caught / n_ev,
            "caught": n_caught,
            "fires": fires,
            "in_window": in_pos,
            "precision": prec,
            "fires_per_day": fires_per_day,
        })

    res = pd.DataFrame(rows).sort_values("recall", ascending=False)
    print("\n" + "=" * 100)
    print("== 规则评估 ==")
    print("=" * 100)
    print(f"{'规则':<24} {'recall':>8} {'caught/35':>10} {'fires':>10} {'in_win':>8} {'precision':>10} {'fires/日':>10}")
    print("-" * 100)
    for _, r in res.iterrows():
        print(f"{r['rule']:<24} {r['recall']:>8.1%} {r['caught']:>7}/{n_ev} "
              f"{r['fires']:>10,} {r['in_window']:>8} {r['precision']:>10.4f} {r['fires_per_day']:>10.1f}")
    print("=" * 100)
    print("解读: recall 越高 => 拦得越多; fires/日 越低 => 干扰越少; precision 反映触发的准确性")
    print("      理想区间: recall > 50%  &  fires/日 < 20  &  precision > 5%")
    print()

    # 保存
    out_csv = PROC / "rule_scoreboard.csv"
    res.to_csv(out_csv, index=False, encoding="utf-8-sig")
    print(f"[save] {out_csv}")

    # 输出每条规则的详细触发时间点 (用于人工检查触发是否合理)
    fire_records = []
    for name, mask in rules.items():
        mask = mask.fillna(False).values
        idx = np.where(mask)[0]
        for i in idx:
            fire_records.append({
                "rule": name,
                "time": df["time"].iloc[i],
                "in_window": bool(pos_window[i]),
                "event_id": int(event_id[i]) if event_id[i] >= 0 else -1,
                "xau_tr": df["xau_tr"].iloc[i],
                "xau_ret60": df["xau_net_ret_60"].iloc[i],
                "spx_ret60": df["spx_net_ret_60"].iloc[i],
                "wti_ret60": df["wti_net_ret_60"].iloc[i],
            })
    fires_df = pd.DataFrame(fire_records)
    fires_df.to_csv(PROC / "rule_fires.csv", index=False, encoding="utf-8-sig")
    print(f"[save] {PROC / 'rule_fires.csv'}  ({len(fires_df):,} rows)")


if __name__ == "__main__":
    main()
