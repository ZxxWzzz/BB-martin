"""绘制 35 个事件的前 240 分钟时序图, 自动分类 A (渐进型) / B (突袭型).

分类逻辑:
    对每个事件的 tr (真实波幅) 前 240 分钟做线性拟合,
    - slope > tr_median * 0.001 且 late_mean > early_mean * 1.3 => A 型 (渐进)
    - 否则 => B 型 (突袭)

输出:
    data/processed/precursor_plots.png     35 子图, A 型在前, B 型在后
    data/processed/precursor_ab_split.csv  每事件的 A/B 分类 + 拟合参数
"""
from __future__ import annotations

from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

HERE = Path(__file__).parent
EVENTS = HERE / "../data/processed/precursor_events.csv"


def classify(g: pd.DataFrame) -> tuple[str, float, float, float]:
    """返回 (type, slope, early_mean, late_mean)"""
    g = g.sort_values("minutes_before", ascending=False).reset_index(drop=True)
    tr = g["tr"].values
    x = np.arange(len(tr))
    if len(tr) < 60:
        return "?", np.nan, np.nan, np.nan
    slope, _ = np.polyfit(x, tr, 1)
    early = tr[:60].mean()   # t-240 ~ t-181
    late = tr[-60:].mean()   # t-60 ~ t-1
    if slope > 0.002 and late > early * 1.3:
        return "A", slope, early, late
    return "B", slope, early, late


def main():
    detail = pd.read_csv(EVENTS)
    detail["event_start_utc"] = pd.to_datetime(detail["event_start_utc"], utc=True)

    # 分类
    class_rows = []
    for ev, g in detail.groupby("event_start_utc"):
        typ, slope, e, l = classify(g)
        direction = g["event_direction"].iloc[0]
        class_rows.append({
            "event": ev.strftime("%Y-%m-%d %H:%M"),
            "direction": direction,
            "type": typ,
            "tr_slope": slope,
            "tr_early_mean": e,
            "tr_late_mean": l,
            "late/early_ratio": l / e if e else np.nan,
        })
    clsdf = pd.DataFrame(class_rows).sort_values(["type", "event"])
    out_cls = HERE / "../data/processed/precursor_ab_split.csv"
    clsdf.to_csv(out_cls, index=False, encoding="utf-8-sig")

    a_count = (clsdf["type"] == "A").sum()
    b_count = (clsdf["type"] == "B").sum()
    print(f"[classify] A(渐进型)={a_count}  B(突袭型)={b_count}")
    print()
    print(clsdf.to_string(index=False))

    # 绘图: A 型在前, B 型在后, 每个子图纵坐标是 tr, 横坐标 minutes_before
    n = len(clsdf)
    ncols = 5
    nrows = (n + ncols - 1) // ncols
    fig, axes = plt.subplots(nrows, ncols, figsize=(ncols * 3.5, nrows * 2.2), squeeze=False)

    for k, (_, row) in enumerate(clsdf.iterrows()):
        r, c = divmod(k, ncols)
        ax = axes[r][c]
        ev_time = pd.to_datetime(row["event"], utc=True)
        g = detail[detail["event_start_utc"] == ev_time].sort_values("minutes_before", ascending=False)
        # 双 y 轴: tr 左, close 右
        ax.plot(-g["minutes_before"], g["tr"], color="tab:red", lw=0.8, label="TR")
        ax.set_ylim(0, max(6, g["tr"].max() * 1.1))
        ax2 = ax.twinx()
        ax2.plot(-g["minutes_before"], g["close"], color="tab:blue", lw=0.6, alpha=0.7)
        ax2.tick_params(axis='y', labelsize=6)
        ax.tick_params(axis='y', labelsize=6, colors="tab:red")
        ax.tick_params(axis='x', labelsize=6)
        color_bg = "#ffe4c4" if row["type"] == "A" else "#cfe2ff"
        ax.set_facecolor(color_bg)
        ax.axvline(0, color="black", lw=0.8, ls="--")
        ax.set_title(f"[{row['type']}] {row['event']} {row['direction']}  slope={row['tr_slope']:.4f}",
                     fontsize=7)

    # 隐藏多余
    for k in range(n, nrows * ncols):
        r, c = divmod(k, ncols)
        axes[r][c].axis("off")

    fig.suptitle("35 个事件的前 240 分钟前兆 (橙=A渐进型 / 蓝=B突袭型, 红线=TR真实波幅, 蓝线=收盘价)", fontsize=10)
    fig.tight_layout(rect=[0, 0, 1, 0.98])
    out_png = HERE / "../data/processed/precursor_plots.png"
    fig.savefig(out_png, dpi=110)
    print(f"\n[save] {out_png}")
    print(f"[save] {out_cls}")


if __name__ == "__main__":
    main()
