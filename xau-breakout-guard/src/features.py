"""生成完整特征矩阵 + 标签 用于训练.

流程:
    1. 加载 XAU / WTI / SPX 三个 M1 (DXY 舍弃因为 Dukascopy 只给假数据)
    2. 逐品种计算因果特征 (只用 t 及之前)
    3. 用 merge_asof(backward) 把 WTI/SPX 对齐到 XAU 时间轴
    4. 用 label.py 相同的 numba scan 生成 0/1 标签 (50/8 参数)
    5. 添加时间特征 (hour, weekday, sin/cos)
    6. 剔除最后 480 根 bar (标签不可靠) + 前 60 根 (滚动特征缺失)
    7. 输出 features.parquet

输出列:
    time (index)
    xau_*  (14 个)
    spx_*  (6 个)
    wti_*  (6 个)
    time_*  (4 个: hour_sin/cos, dow_sin/cos)
    label (0/1)
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pandas as pd
import yaml
from numba import njit, prange

HERE = Path(__file__).parent
RAW = HERE / "../data/raw"
PROC = HERE / "../data/processed"

CFG = yaml.safe_load((HERE / "config.yaml").open("r", encoding="utf-8"))


@njit(cache=True, parallel=True)
def _scan(close, high, low, thr_move, thr_pull, max_bars):
    n = len(close)
    label = np.full(n, -1, dtype=np.int8)
    for i in prange(n):
        if i + max_bars >= n:
            continue
        c0 = close[i]
        hi_since = c0; lo_since = c0
        for j in range(i+1, i+1+max_bars):
            h = high[j]; l = low[j]
            if h > hi_since: hi_since = h
            if l < lo_since: lo_since = l
            up_run = hi_since - c0; dn_run = c0 - lo_since
            up_pull = hi_since - l; dn_pull = h - lo_since
            if up_run >= dn_run:
                if up_pull >= thr_pull:
                    label[i] = 0; break
                if up_run >= thr_move:
                    label[i] = 1; break
            else:
                if dn_pull >= thr_pull:
                    label[i] = 0; break
                if dn_run >= thr_move:
                    label[i] = 1; break
        else:
            label[i] = 0
    return label


def compute_asset_feats(df: pd.DataFrame, prefix: str) -> pd.DataFrame:
    """给单个品种加因果特征. 所有滚动统计只用过去数据."""
    d = df[["time", "open", "high", "low", "close", "volume"]].copy().sort_values("time").reset_index(drop=True)
    d["tr"] = d["high"] - d["low"]
    d["ret"] = d["close"].pct_change()
    d["body"] = d["close"] - d["open"]
    d["is_bull"] = (d["body"] > 0).astype(np.int8)

    # 波动
    d["tr_ma_5"]  = d["tr"].rolling(5, min_periods=2).mean()
    d["tr_ma_20"] = d["tr"].rolling(20, min_periods=5).mean()
    d["tr_ma_60"] = d["tr"].rolling(60, min_periods=15).mean()
    d["tr_ratio_5v60"]  = d["tr_ma_5"] / (d["tr_ma_60"] + 1e-9)
    d["tr_ratio_20v60"] = d["tr_ma_20"] / (d["tr_ma_60"] + 1e-9)

    # 方向
    d["bull_ratio_5"]  = d["is_bull"].rolling(5,  min_periods=2).mean()
    d["bull_ratio_15"] = d["is_bull"].rolling(15, min_periods=4).mean()
    d["dir_cons_5"]  = np.maximum(d["bull_ratio_5"],  1 - d["bull_ratio_5"])
    d["dir_cons_15"] = np.maximum(d["bull_ratio_15"], 1 - d["bull_ratio_15"])

    # 累积净变动 (%)
    d["net_ret_15"] = d["close"].pct_change(15)
    d["net_ret_30"] = d["close"].pct_change(30)
    d["net_ret_60"] = d["close"].pct_change(60)

    # 距近期高低点 (归一化, 对跨品种可比)
    d["hi_60"] = d["high"].rolling(60, min_periods=15).max()
    d["lo_60"] = d["low"].rolling(60, min_periods=15).min()
    d["dist_from_hi_60_pct"] = (d["hi_60"] - d["close"]) / d["close"]
    d["dist_from_lo_60_pct"] = (d["close"] - d["lo_60"]) / d["close"]
    d["range_60_pct"] = (d["hi_60"] - d["lo_60"]) / d["close"]

    keep = ["time", "tr", "tr_ratio_5v60", "tr_ratio_20v60",
            "dir_cons_5", "dir_cons_15",
            "net_ret_15", "net_ret_30", "net_ret_60",
            "dist_from_hi_60_pct", "dist_from_lo_60_pct", "range_60_pct"]
    d = d[keep].rename(columns={c: f"{prefix}_{c}" for c in keep if c != "time"})
    return d


def main():
    print("[load]")
    xau = pd.read_parquet(RAW / "xauusd_m1.parquet")
    wti = pd.read_parquet(RAW / "wti_m1.parquet")
    spx = pd.read_parquet(RAW / "spx_m1.parquet")
    print(f"  XAU {len(xau):,}  WTI {len(wti):,}  SPX {len(spx):,}")

    print("[features] XAU + WTI + SPX")
    xau_f = compute_asset_feats(xau, "xau")
    wti_f = compute_asset_feats(wti, "wti")
    spx_f = compute_asset_feats(spx, "spx")

    print("[align] merge_asof backward tolerance=6h")
    df = xau_f.sort_values("time")
    for other in (wti_f, spx_f):
        df = pd.merge_asof(df, other.sort_values("time"), on="time",
                           direction="backward", tolerance=pd.Timedelta(hours=6))

    print("[label] 50/8 scan")
    thr_move = float(CFG["label"]["threshold_move"])
    thr_pull = float(CFG["label"]["threshold_pullback"])
    max_bars = int(CFG["label"]["scan_max_bars"])
    # 用 xau 原始 close/high/low (不是 xau_f 里的, xau_f 已经改列名/删了)
    xau_sorted = xau.sort_values("time").reset_index(drop=True)
    label = _scan(
        xau_sorted["close"].to_numpy(np.float64),
        xau_sorted["high"].to_numpy(np.float64),
        xau_sorted["low"].to_numpy(np.float64),
        thr_move, thr_pull, max_bars,
    )
    label_series = pd.Series(label, index=pd.Index(xau_sorted["time"], name="time"))
    df = df.merge(label_series.rename("label").reset_index(), on="time", how="left")

    # 时间特征
    print("[time-features]")
    h = df["time"].dt.hour
    dow = df["time"].dt.dayofweek
    df["time_hour_sin"] = np.sin(2 * np.pi * h / 24)
    df["time_hour_cos"] = np.cos(2 * np.pi * h / 24)
    df["time_dow_sin"] = np.sin(2 * np.pi * dow / 7)
    df["time_dow_cos"] = np.cos(2 * np.pi * dow / 7)

    # 过滤
    before = len(df)
    df = df[df["label"] >= 0].reset_index(drop=True)   # 剔除末尾 label=-1
    df = df.dropna(subset=[c for c in df.columns if c not in ("time", "label")]).reset_index(drop=True)
    after = len(df)
    print(f"[filter] {before:,} -> {after:,} (剔除末尾 + NaN)")

    pos = int(df["label"].sum())
    print(f"[stat] positive: {pos:,}  ({pos/after*100:.3f}%)")

    out = PROC / "features.parquet"
    df.to_parquet(out, index=False)
    print(f"[save] {out}  ({out.stat().st_size / 1024 / 1024:.1f} MB, cols={df.shape[1]})")
    print(f"columns: {list(df.columns)}")


if __name__ == "__main__":
    main()
