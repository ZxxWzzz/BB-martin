"""多变量前兆分析: XAU 命中事件在 DXY/WTI/SPX 上是否有前兆信号?

流程:
    1. 加载 XAU + DXY + WTI + SPX, 以 XAU 时间轴为主, 其他 forward-fill 对齐
    2. 对每个变量计算因果前兆特征 (tr / net_move / dir_consistency)
    3. 从 precursor_ab_split.csv 加载 A/B 分类
    4. 分三组: A 型事件 / B 型事件 / 对照 (随机非事件 bar)
    5. 计算每个变量在事件前 30min 均值 vs 对照, 分别对 A 组 和 B 组算 Cohen d
    6. 重点关注: B 组的外部信号 Cohen d, 找强信号

输出:
    multivariate_summary.txt   分变量分组的对比表
    multivariate_events.csv    每个事件在 DXY/WTI/SPX 上的前 30min 特征值
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pandas as pd

HERE = Path(__file__).parent
RAW = HERE / "../data/raw"
PROC = HERE / "../data/processed"

XAU_PATH = RAW / "xauusd_m1.parquet"
DXY_PATH = RAW / "usdidx_m1.parquet"
WTI_PATH = RAW / "wti_m1.parquet"
SPX_PATH = RAW / "spx_m1.parquet"

HITS_PATH = PROC / "hits.csv"
AB_PATH = PROC / "precursor_ab_split.csv"


def compute_precursor_feats(df: pd.DataFrame, prefix: str) -> pd.DataFrame:
    """给单个品种加因果特征 (只用 t 及之前的数据)"""
    d = df.copy()
    d["tr"] = d["high"] - d["low"]
    d["ret"] = d["close"].pct_change()  # 归一化收益率, 跨品种可比
    d["is_bull"] = (d["close"] > d["open"]).astype(int)

    d["tr_ma_60"] = d["tr"].rolling(60, min_periods=15).mean()
    d["tr_ratio_5v60"] = d["tr"].rolling(5, min_periods=2).mean() / (d["tr_ma_60"] + 1e-9)
    d["dir_cons_5"] = d["is_bull"].rolling(5, min_periods=2).mean().apply(lambda x: max(x, 1-x))
    d["net_ret_15"] = d["close"].pct_change(15)  # 归一化的 15min 变动
    d["net_ret_30"] = d["close"].pct_change(30)
    d["net_ret_60"] = d["close"].pct_change(60)

    keep = ["time", "tr", "tr_ratio_5v60", "dir_cons_5", "net_ret_15", "net_ret_30", "net_ret_60"]
    d = d[keep].rename(columns={c: f"{prefix}_{c}" for c in keep if c != "time"})
    return d


def cohen_d(a: np.ndarray, b: np.ndarray) -> float:
    a = np.asarray(a, dtype=float); b = np.asarray(b, dtype=float)
    a = a[np.isfinite(a)]; b = b[np.isfinite(b)]
    if len(a) < 2 or len(b) < 2:
        return np.nan
    sd = np.sqrt((a.var(ddof=1) + b.var(ddof=1)) / 2)
    if sd == 0:
        return np.nan
    return (a.mean() - b.mean()) / sd


def main():
    print("[load] XAU / DXY / WTI / SPX")
    xau = pd.read_parquet(XAU_PATH)[["time", "open", "high", "low", "close"]]
    dxy = pd.read_parquet(DXY_PATH)[["time", "open", "high", "low", "close"]]
    wti = pd.read_parquet(WTI_PATH)[["time", "open", "high", "low", "close"]]
    spx = pd.read_parquet(SPX_PATH)[["time", "open", "high", "low", "close"]]

    print(f"  XAU: {len(xau):,}  {xau['time'].iloc[0]} ~ {xau['time'].iloc[-1]}")
    print(f"  DXY: {len(dxy):,}  {dxy['time'].iloc[0]} ~ {dxy['time'].iloc[-1]}")
    print(f"  WTI: {len(wti):,}  {wti['time'].iloc[0]} ~ {wti['time'].iloc[-1]}")
    print(f"  SPX: {len(spx):,}  {spx['time'].iloc[0]} ~ {spx['time'].iloc[-1]}")

    # 计算各自的因果特征
    xau_f = compute_precursor_feats(xau, "xau")
    dxy_f = compute_precursor_feats(dxy, "dxy")
    wti_f = compute_precursor_feats(wti, "wti")
    spx_f = compute_precursor_feats(spx, "spx")

    print("\n[align] merge_asof to XAU timeline, forward-fill")
    xau_f = xau_f.sort_values("time")
    df = xau_f.copy()
    for other in (dxy_f, wti_f, spx_f):
        other = other.sort_values("time")
        df = pd.merge_asof(df, other, on="time", direction="backward", tolerance=pd.Timedelta(hours=6))

    # A/B 分类
    ab = pd.read_csv(AB_PATH)
    ab["event"] = pd.to_datetime(ab["event"], utc=True)

    hits = pd.read_csv(HITS_PATH)
    hits["start_utc"] = pd.to_datetime(hits["start_utc"], utc=True)
    hits = hits.merge(ab[["event", "type"]], left_on="start_utc", right_on="event", how="left")
    print(f"[hits] {len(hits)} total  A={sum(hits['type']=='A')} B={sum(hits['type']=='B')}")

    times_int = df["time"].astype("int64").values

    def find_idx(t):
        i = int(np.searchsorted(times_int, t.value))
        return i if i < len(times_int) and times_int[i] == t.value else -1

    # 事件前 30min 均值特征
    W = 30
    feat_cols = [c for c in df.columns if c != "time"]
    event_rows = []
    for _, h in hits.iterrows():
        i = find_idx(h["start_utc"])
        if i < 0: continue
        s = max(0, i - W)
        seg = df.iloc[s:i]  # 事件前 30 分钟 (不含起点本身)
        rec = {"event": h["start_utc"].strftime("%Y-%m-%d %H:%M"),
               "direction": h["方向"], "type": h["type"]}
        for c in feat_cols:
            rec[c] = seg[c].mean()
        event_rows.append(rec)
    ev_df = pd.DataFrame(event_rows)
    ev_df.to_csv(PROC / "multivariate_events.csv", index=False, encoding="utf-8-sig")

    # 对照: 500 个随机非事件 bar 的前 30min 均值
    print("[control] 随机采样 500 个对照")
    rng = np.random.default_rng(42)
    hit_idxs = set()
    for _, h in hits.iterrows():
        i = find_idx(h["start_utc"])
        if i < 0: continue
        for k in range(i - 240, i + 240 + 1):
            hit_idxs.add(k)
    pool = list(set(range(60, len(df) - 1)) - hit_idxs)
    picks = rng.choice(pool, size=min(500, len(pool)), replace=False)
    ctrl_rows = []
    for idx in picks:
        seg = df.iloc[max(0, idx - W):idx]
        rec = {}
        for c in feat_cols:
            rec[c] = seg[c].mean()
        ctrl_rows.append(rec)
    ctrl_df = pd.DataFrame(ctrl_rows)

    # 分组对比
    A_df = ev_df[ev_df["type"] == "A"][feat_cols]
    B_df = ev_df[ev_df["type"] == "B"][feat_cols]

    print("\n" + "=" * 100)
    print("== 事件前 30min 均值特征: A/B 组 vs 对照 (Cohen's d 效应量) ==")
    print("=" * 100)
    print(f"{'feature':<28} {'A(n=13) mean':>14} {'B(n=22) mean':>14} {'ctrl mean':>12} {'d(A)':>8} {'d(B)':>8}   note")
    print("-" * 100)

    lines = []
    for c in feat_cols:
        a_mean = A_df[c].mean(); b_mean = B_df[c].mean(); ctrl_mean = ctrl_df[c].mean()
        d_a = cohen_d(A_df[c].values, ctrl_df[c].values)
        d_b = cohen_d(B_df[c].values, ctrl_df[c].values)
        marker = ""
        if abs(d_b) > 0.8: marker = "  ***B强"
        elif abs(d_b) > 0.5: marker = "  **B中"
        elif abs(d_b) > 0.2: marker = "  *B弱"
        line = f"{c:<28} {a_mean:>14.5f} {b_mean:>14.5f} {ctrl_mean:>12.5f} {d_a:>8.3f} {d_b:>8.3f}{marker}"
        print(line); lines.append(line)

    # 保存文本汇总
    with open(PROC / "multivariate_summary.txt", "w", encoding="utf-8") as f:
        f.write("多变量前兆分析汇总\n" + "=" * 100 + "\n\n")
        f.write(f"{'feature':<28} {'A_mean':>14} {'B_mean':>14} {'ctrl_mean':>12} {'d(A)':>8} {'d(B)':>8}\n")
        f.write("-" * 100 + "\n")
        for l in lines:
            f.write(l + "\n")
        f.write("\n效应量: |d|>0.2 弱 / >0.5 中 / >0.8 强\n")
        f.write("重点: B 组是 XAU 自身无前兆的 22 个事件, d(B) 强的外部信号是关键突破口\n")

    print("\n" + "=" * 100)
    print("重点解读:")
    print(" • d(B) 是 B 型事件(XAU 自身无前兆) 相对对照的效应量, 是本次分析核心")
    print(" • d(B) 强 = 该外部信号能提前捕获 B 型突袭")
    print(" • d(A) 强而 d(B) 弱 = 只对渐进型有效")
    print(f"\n[save] {PROC / 'multivariate_events.csv'}  逐事件明细")
    print(f"[save] {PROC / 'multivariate_summary.txt'}")


if __name__ == "__main__":
    main()
