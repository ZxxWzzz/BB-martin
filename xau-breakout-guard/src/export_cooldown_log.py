"""导出选定规则的完整拦截日志, 供人工验证.

规则: R6 = xau_tr > 2.5 AND xau_net_ret_60 < -0.0005 (-0.05%)
冷却: 60 分钟 (触发后 60min 内不再重新计时)

输出:
    cooldown_log.csv             每次独立冷却触发的详细信息 (给你看的主表)
    cooldown_by_event.csv        35 个事件视角: 每个事件是否被冷却覆盖, 由哪次冷却拦下
    cooldown_summary.txt         人类可读的汇总
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pandas as pd

HERE = Path(__file__).parent
PROC = HERE / "../data/processed"

# === 规则参数 ===
TR_THR = 2.5
RET60_THR = -0.0005    # -0.05%
COOLDOWN_MIN = 60
NEAR_EVENT_WINDOW_MIN = 60  # 冷却触发后 [0, 60min] 内有事件 = TP


def main():
    print("[load]")
    df = pd.read_parquet(PROC / "features.parquet").sort_values("time").reset_index(drop=True)
    hits = pd.read_csv(PROC / "hits.csv")
    hits["start_utc"] = pd.to_datetime(hits["start_utc"], utc=True)
    ab = pd.read_csv(PROC / "precursor_ab_split.csv")
    ab["event"] = pd.to_datetime(ab["event"], utc=True)
    print(f"  {len(df):,} bars, {len(hits)} events")

    times_int = df["time"].values.view("int64")
    ev_times_int = np.array([h.value for h in hits["start_utc"]])

    # 触发 mask
    trigger = ((df["xau_tr"] > TR_THR) & (df["xau_net_ret_60"] < RET60_THR)).fillna(False).values
    print(f"[rule] xau_tr > {TR_THR}  &  xau_net_ret_60 < {RET60_THR*100:+.2f}%")

    # 模拟 60min 冷却期
    n = len(df)
    cd_min_ns = COOLDOWN_MIN * 60 * 1_000_000_000
    cooldown = np.zeros(n, dtype=bool)
    cooldown_until_ns = 0
    cd_starts = []
    for i in range(n):
        t = times_int[i]
        if t < cooldown_until_ns:
            cooldown[i] = True
        elif trigger[i]:
            cooldown[i] = True
            cd_starts.append(i)
            cooldown_until_ns = t + cd_min_ns

    print(f"[sim] 独立冷却触发次数: {len(cd_starts):,}")
    print(f"[sim] 总冷却时长: {cooldown.sum() / 60:.0f} 小时  ({cooldown.mean()*100:.2f}%)")

    # === 每次冷却的详细信息 ===
    cd_rows = []
    ev_by_time = {h["start_utc"].value: (h["start_utc"], h["方向"]) for _, h in hits.iterrows()}
    ab_map = dict(zip(ab["event"].apply(lambda t: t.value), ab["type"]))

    for cd_i in cd_starts:
        t = df["time"].iloc[cd_i]
        t_ns = t.value

        # 查找触发后 60min 内是否有事件
        end_ns = t_ns + NEAR_EVENT_WINDOW_MIN * 60 * 1_000_000_000
        # 也考虑触发前 30min 内 (事件已经在启动, 冷却期覆盖 t 时刻)
        prev_ns = t_ns - 30 * 60 * 1_000_000_000

        matched_events = []
        for ev_ns, (ev_t, ev_dir) in ev_by_time.items():
            if prev_ns <= ev_ns <= end_ns:
                gap_min = (ev_ns - t_ns) / 60_000_000_000
                ab_type = ab_map.get(ev_ns, "?")
                matched_events.append((ev_t, ev_dir, gap_min, ab_type))

        # 分类
        if matched_events:
            classification = "TP"
            event_desc = "; ".join(
                f"{et.strftime('%Y-%m-%d %H:%M')} {ed}({at}) gap={gm:+.0f}min"
                for et, ed, gm, at in matched_events
            )
        else:
            classification = "FP"
            event_desc = ""

        cd_rows.append({
            "cd_utc": t.strftime("%Y-%m-%d %H:%M"),
            "cd_bj": (t + pd.Timedelta(hours=8)).strftime("%Y-%m-%d %H:%M"),
            "weekday": t.day_name()[:3],
            "utc_hour": t.hour,
            "class": classification,
            "matched_events": event_desc,
            "xau_tr": round(df["xau_tr"].iloc[cd_i], 2),
            "xau_ret60_pct": round(df["xau_net_ret_60"].iloc[cd_i] * 100, 3),
            "xau_close": round(df["xau_tr"].iloc[cd_i], 2),
            "spx_ret60_pct": round(df["spx_net_ret_60"].iloc[cd_i] * 100, 3) if pd.notna(df["spx_net_ret_60"].iloc[cd_i]) else None,
            "wti_ret60_pct": round(df["wti_net_ret_60"].iloc[cd_i] * 100, 3) if pd.notna(df["wti_net_ret_60"].iloc[cd_i]) else None,
        })

    cd_df = pd.DataFrame(cd_rows)
    tp = int((cd_df["class"] == "TP").sum())
    fp = int((cd_df["class"] == "FP").sum())
    print(f"[classify] TP(拦到事件)={tp}  FP(纯误报)={fp}  precision={tp/(tp+fp)*100:.1f}%")

    out_log = PROC / "cooldown_log.csv"
    cd_df.to_csv(out_log, index=False, encoding="utf-8-sig")
    print(f"[save] {out_log}")

    # === 事件视角: 每个事件被哪次冷却拦下 ===
    ev_rows = []
    for _, h in hits.iterrows():
        t = h["start_utc"]; t_ns = t.value
        i = int(np.searchsorted(times_int, t_ns))
        if i >= n or times_int[i] != t_ns:
            ev_rows.append({"event": t.strftime("%Y-%m-%d %H:%M"), "direction": h["方向"], "caught": "NO_DATA"})
            continue
        # 检查 event 前 60min 到 event 时刻, 是否有 cooldown
        i0 = max(0, i - 60)
        cd_active = cooldown[i0:i+1].any()
        # 找是哪次冷却拦下的
        cd_by = None
        for cd_i in cd_starts:
            cd_t = times_int[cd_i]
            if cd_t <= t_ns and cd_t + cd_min_ns >= t_ns:
                cd_by = df["time"].iloc[cd_i]
                break
        ab_type = ab_map.get(t_ns, "?")
        ev_rows.append({
            "event": t.strftime("%Y-%m-%d %H:%M"),
            "event_bj": (t + pd.Timedelta(hours=8)).strftime("%Y-%m-%d %H:%M"),
            "direction": h["方向"],
            "type": ab_type,
            "caught": "YES" if cd_active else "NO",
            "cooldown_by": cd_by.strftime("%Y-%m-%d %H:%M") if cd_by else "",
            "lead_time_min": int((t - cd_by).total_seconds() / 60) if cd_by else None,
        })
    ev_df = pd.DataFrame(ev_rows)
    caught_n = int((ev_df["caught"] == "YES").sum())
    print(f"\n[event] 拦到 {caught_n}/{len(hits)}")
    out_ev = PROC / "cooldown_by_event.csv"
    ev_df.to_csv(out_ev, index=False, encoding="utf-8-sig")
    print(f"[save] {out_ev}")

    # 打印事件视角表 (只有 35 行, 直接看)
    print("\n== 事件视角: 每个事件是否被拦 ==")
    print(ev_df.to_string(index=False))

    # === 汇总 ===
    with open(PROC / "cooldown_summary.txt", "w", encoding="utf-8") as f:
        f.write(f"XAU 单边行情预警 - 拦截日志汇总\n")
        f.write("=" * 60 + "\n\n")
        f.write(f"规则: xau_tr > ${TR_THR}  AND  xau_net_ret_60 < {RET60_THR*100:+.2f}%\n")
        f.write(f"冷却期: {COOLDOWN_MIN} 分钟\n\n")
        f.write(f"数据范围: {df['time'].iloc[0]} ~ {df['time'].iloc[-1]}\n")
        f.write(f"总 M1 数: {len(df):,}\n\n")
        f.write(f"独立冷却触发次数: {len(cd_starts):,}\n")
        f.write(f"  - TP (触发后 60min 内有事件): {tp}\n")
        f.write(f"  - FP (纯误报): {fp}\n")
        f.write(f"  - Precision: {tp/(tp+fp)*100:.1f}%\n\n")
        f.write(f"总冷却时长: {cooldown.sum() / 60:.0f} 小时  ({cooldown.mean()*100:.2f}% of time)\n\n")
        f.write(f"事件拦截: {caught_n}/{len(hits)} = {caught_n/len(hits)*100:.1f}%\n\n")
        f.write("== 未拦到的事件 ==\n")
        for _, r in ev_df[ev_df["caught"] != "YES"].iterrows():
            f.write(f"  {r['event']}  {r['direction']} {r.get('type','')}  ({r['caught']})\n")

    print(f"[save] {PROC / 'cooldown_summary.txt'}")


if __name__ == "__main__":
    main()
