"""核心标注器: 对每根 M1 bar 判定其是否为「危险起点」.

规则:
    从起点 bar 的收盘价 C0 开始 (下一根 bar 起扫描),
    - 若价格向任一方向累计走出 >= threshold_move ($58), 且中途反向回撤 < threshold_pullback ($8) => 标 1 (危险)
    - 若在达标前反向回撤 >= threshold_pullback => 标 0 (安全)
    - 若扫描到 scan_max_bars 仍未达标 也未回撤 => 标 0 (安全, 无明确信号)

保守假设 (M1 内 tick 顺序未知):
    - 判断"是否先触发回撤"时, 按最坏情况处理: 一根 bar 内 high 和 low 都被"依次触及", 顺序取对当前判定最不利的一个.
    - 具体做法: 逐根扫, 维护当前方向 (由第一根 bar 的 high/low 谁先离 C0 更远决定初始方向, 若同 bar 内两侧都触发则视为回撤触发).

事件剔除:
    - investpy 事件时间 ± window 分钟 内的起点 bar 不打标签 (设为 NaN, 训练时 dropna).
    - 兜底: 分钟真实波幅 > sigma_mult * rolling_std 视为异常, 同样剔除.

输出: parquet, 列 = [time, open, high, low, close, volume, spread, label, direction, bars_to_hit, is_event]
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pandas as pd
import yaml
from numba import njit, prange

HERE = Path(__file__).parent
CFG = yaml.safe_load((HERE / "config.yaml").open("r", encoding="utf-8"))


@njit(cache=True, parallel=True)
def _label_kernel(
    close: np.ndarray,
    high: np.ndarray,
    low: np.ndarray,
    thr_move: float,
    thr_pull: float,
    max_bars: int,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """向量化核心. 返回 (label, direction, bars_to_hit).

    label: 1=命中危险, 0=安全, -1=数据不足 (末尾 max_bars 根)
    direction: +1=上涨命中, -1=下跌命中, 0=未命中
    bars_to_hit: 命中所需 bar 数, -1 未命中
    """
    n = len(close)
    label = np.full(n, -1, dtype=np.int8)
    direction = np.zeros(n, dtype=np.int8)
    bars_to_hit = np.full(n, -1, dtype=np.int32)

    for i in prange(n):
        if i + max_bars >= n:
            continue
        c0 = close[i]
        # 记录从起点开始的最大上行 / 最大下行 (未回撤前)
        max_up = 0.0       # 到目前为止的最高点相对 c0
        max_dn = 0.0       # 到目前为止的最低点相对 c0 (正数, 距离)
        # 一旦朝某方向走出 X 后又回撤 X 时的"回撤基准"
        hi_since = c0
        lo_since = c0
        hit = 0
        for j in range(i + 1, i + 1 + max_bars):
            h = high[j]
            l = low[j]
            # 更新极值
            if h > hi_since:
                hi_since = h
            if l < lo_since:
                lo_since = l
            up_run = hi_since - c0        # 上行最大行程
            dn_run = c0 - lo_since        # 下行最大行程
            # 回撤计算: 从最高点回落 / 从最低点反弹
            up_pullback = hi_since - l    # 若走高后当前 bar 的低价触发回撤
            dn_pullback = h - lo_since    # 若走低后当前 bar 的高价触发反弹

            # 先判断达标 (命中优先, 保守: 若同 bar 同时达标 + 回撤触发, 按回撤淘汰)
            # 但真正的保守方向: 若走势主要向上 (up_run > dn_run), 先看是否 up_pullback 触发, 再看是否达标
            #                否则反过来
            if up_run >= dn_run:
                # 向上方向主导
                if up_pullback >= thr_pull:
                    label[i] = 0
                    bars_to_hit[i] = j - i
                    hit = 1
                    break
                if up_run >= thr_move:
                    label[i] = 1
                    direction[i] = 1
                    bars_to_hit[i] = j - i
                    hit = 1
                    break
            else:
                if dn_pullback >= thr_pull:
                    label[i] = 0
                    bars_to_hit[i] = j - i
                    hit = 1
                    break
                if dn_run >= thr_move:
                    label[i] = 1
                    direction[i] = -1
                    bars_to_hit[i] = j - i
                    hit = 1
                    break
        if hit == 0:
            # 扫到 max_bars 都没触发任何事件, 视为安全
            label[i] = 0
            bars_to_hit[i] = max_bars

    return label, direction, bars_to_hit


def load_events() -> pd.DataFrame | None:
    p = (HERE / CFG["events"]["cache_path"]).resolve()
    if not p.exists():
        print(f"[warn] 事件文件不存在: {p}  (仅用统计异常兜底)")
        return None
    return pd.read_parquet(p)


def mark_event_bars(df: pd.DataFrame, events: pd.DataFrame | None) -> pd.Series:
    """标记事件窗口内的 bar. 返回 bool Series."""
    is_event = pd.Series(False, index=df.index)

    if events is not None and len(events) > 0:
        win_before = pd.Timedelta(minutes=CFG["events"]["window_minutes_before"])
        win_after = pd.Timedelta(minutes=CFG["events"]["window_minutes_after"])
        # 用 merge_asof 加速: 对每根 bar 找最近的事件, 判断是否在窗口内
        ev_times = events["datetime_utc"].sort_values().values
        bar_times = df["time"].values
        idx = np.searchsorted(ev_times, bar_times)
        for offset in (0, -1):  # 检查前后一个事件
            j = np.clip(idx + offset, 0, len(ev_times) - 1)
            dt = np.abs((bar_times - ev_times[j]).astype("timedelta64[s]").astype(np.int64))
            in_win = (bar_times >= ev_times[j] - win_before.to_timedelta64()) & \
                     (bar_times <= ev_times[j] + win_after.to_timedelta64())
            is_event |= pd.Series(in_win, index=df.index)

    # 统计兜底: 单根 bar 真实波幅 > sigma_mult * rolling_std
    tr = df["high"] - df["low"]
    rolling_std = tr.rolling(CFG["events"]["sigma_window"], min_periods=200).std()
    is_anom = tr > CFG["events"]["sigma_mult"] * rolling_std
    is_event |= is_anom.fillna(False)
    return is_event


def main() -> None:
    raw = (HERE / CFG["fetch"]["raw_path"]).resolve()
    if not raw.exists():
        raise SystemExit(f"raw 数据不存在: {raw}  先跑 fetch_mt5.py")

    df = pd.read_parquet(raw)
    print(f"[load] {len(df):,} bars  {df['time'].iloc[0]} ~ {df['time'].iloc[-1]}")

    thr_move = float(CFG["label"]["threshold_move"])
    thr_pull = float(CFG["label"]["threshold_pullback"])
    max_bars = int(CFG["label"]["scan_max_bars"])

    print(f"[label] threshold_move=${thr_move}  threshold_pullback=${thr_pull}  scan_max_bars={max_bars}")
    label, direction, bars_to_hit = _label_kernel(
        df["close"].to_numpy(np.float64),
        df["high"].to_numpy(np.float64),
        df["low"].to_numpy(np.float64),
        thr_move, thr_pull, max_bars,
    )
    df["label"] = label
    df["direction"] = direction
    df["bars_to_hit"] = bars_to_hit

    events = load_events()
    df["is_event"] = mark_event_bars(df, events)

    # 统计
    valid = df["label"] >= 0
    pos = df.loc[valid & ~df["is_event"], "label"].sum()
    total = int((valid & ~df["is_event"]).sum())
    ev_count = int(df["is_event"].sum())
    print(f"[stat] valid bars (post-event-filter): {total:,}")
    print(f"[stat] positive (dangerous): {pos:,}  ({pos/total*100:.2f}%)")
    print(f"[stat] event-window bars removed: {ev_count:,}  ({ev_count/len(df)*100:.2f}%)")
    print(f"[stat] direction split: up={int((df['direction']==1).sum()):,} dn={int((df['direction']==-1).sum()):,}")

    out = (HERE / CFG["label"]["processed_path"]).resolve()
    out.parent.mkdir(parents=True, exist_ok=True)
    df.to_parquet(out, index=False)
    print(f"[save] {out}  ({out.stat().st_size / 1024 / 1024:.1f} MB)")


if __name__ == "__main__":
    main()
