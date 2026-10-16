#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
回光返照 策略回测
数据: xauusd_m1.parquet (M1 XAUUSD ~2年)
逻辑:
  1. 合成 M3/M6/M12/M30/H1
  2. 各周期计算 MACD
  3. M3 出现金叉/死叉 + 高周期投票票数达标 + RSI 过滤 → 开仓
  4. 使用 M1 high/low 精确模拟 SL/TP 触发
  5. 输出统计 + 明细 CSV
"""
import sys
import pandas as pd
import numpy as np

PY = r'D:\dev\martin-analysis\xau-breakout-guard\data\raw\xauusd_m1.parquet'
OUT = r'D:\dev\martin-analysis\backtest_hgfz_result.csv'

# ── 策略参数 ──────────────────────────────────────
MACD_FAST, MACD_SLOW, MACD_SIG = 12, 26, 9
RSI_PERIOD    = 14
TF_TRIG       = '3min'
TF_VOTES      = ['6min', '12min', '30min', '1h']
MIN_VOTES     = 4        # 至少 X/4 个高周期同向才入场

USE_RSI       = True
RSI_S_MIN     = 50.0    # 做空 RSI 下限
RSI_S_MAX     = 72.0    # 做空 RSI 上限
RSI_L_MIN     = 28.0    # 做多 RSI 下限
RSI_L_MAX     = 50.0    # 做多 RSI 上限

SL_USD        = 3.0     # 止损 USD/oz
TP_USD        = 5.0     # 止盈 USD/oz
# ─────────────────────────────────────────────────


def ema(s, n):
    return s.ewm(span=n, adjust=False).mean()


def calc_macd(close):
    dif = ema(close, MACD_FAST) - ema(close, MACD_SLOW)
    dea = ema(dif, MACD_SIG)
    return dif, dea, dif - dea


def calc_rsi(close, n=14):
    d = close.diff()
    g = d.clip(lower=0)
    l = (-d).clip(lower=0)
    ag = g.ewm(com=n - 1, adjust=False).mean()
    al = l.ewm(com=n - 1, adjust=False).mean()
    rs = ag / al.replace(0, np.nan)
    return 100 - 100 / (1 + rs)


def resample_tf(df, rule):
    r = df.resample(rule, closed='left', label='left').agg(
        open=('open', 'first'),
        high=('high', 'max'),
        low=('low', 'min'),
        close=('close', 'last'),
    ).dropna(subset=['close'])
    r = r[r['close'] > 0]
    r['dif'], r['dea'], r['hist'] = calc_macd(r['close'])
    r['rsi'] = calc_rsi(r['close'], RSI_PERIOD)
    return r


# ── 加载数据 ──────────────────────────────────────
print("加载 M1 数据...")
df = pd.read_parquet(PY)
df['time'] = pd.to_datetime(df['time'], utc=True)
df = df.set_index('time').sort_index()
df = df[df['close'] > 0]
print(f"  {len(df):,} bars  {df.index.min().date()} ~ {df.index.max().date()}")

# ── 合成周期 ──────────────────────────────────────
print("合成周期并计算指标...")
m3 = resample_tf(df, TF_TRIG)
vote_tfs = [resample_tf(df, tf) for tf in TF_VOTES]
print(f"  M3:{len(m3):,}  " + "  ".join(f"{tf}:{len(v):,}" for tf, v in zip(TF_VOTES, vote_tfs)))

# ── 对齐投票周期到 M3 时间轴 ─────────────────────
# merge_asof(direction='backward'): 对每个 M3 bar 时间,取最近一根已完成的投票 bar
print("对齐投票周期...")
bear_cols = np.zeros((len(m3), len(vote_tfs)), dtype=bool)
bull_cols = np.zeros((len(m3), len(vote_tfs)), dtype=bool)

trig_t = m3.index.to_frame(name='t').reset_index(drop=True)
for k, vdf in enumerate(vote_tfs):
    v_reset = vdf[['dif', 'dea']].reset_index()
    v_reset.columns = ['tv', 'dif', 'dea']
    merged = pd.merge_asof(
        trig_t, v_reset,
        left_on='t', right_on='tv',
        direction='backward'
    )
    bear_cols[:, k] = (merged['dif'] < merged['dea']).values
    bull_cols[:, k] = (merged['dif'] > merged['dea']).values

vote_bear = bear_cols.sum(axis=1)  # 每个 M3 bar 时的死叉票数
vote_bull = bull_cols.sum(axis=1)  # 金叉票数

# ── 触发信号 ──────────────────────────────────────
hist_vals = m3['hist'].values
rsi_vals  = m3['rsi'].values

# cross[i]: M3 bar[i] 是否形成金叉(1)/死叉(-1)
cross = np.zeros(len(m3), dtype=np.int8)
for i in range(1, len(m3)):
    if hist_vals[i] > 0 and hist_vals[i - 1] <= 0:
        cross[i] = 1
    elif hist_vals[i] < 0 and hist_vals[i - 1] >= 0:
        cross[i] = -1

# ── 准备 M1 high/low 索引映射 ───────────────────
# 用于在 SL/TP 检查时精确模拟 M1 bar 内的价格运动
m1_high  = df['high'].values
m1_low   = df['low'].values
m1_times_ns = df.index.astype(np.int64).values
m3_times_ns = m3.index.astype(np.int64).values

# m3_to_m1_start[i] = 第 i 根 M3 bar 对应的第一根 M1 bar 的行号
m3_to_m1_start = np.searchsorted(m1_times_ns, m3_times_ns, side='left')
# m3_to_m1_end[i]   = 第 i 根 M3 bar 对应的最后一根 M1 bar 的下一行 (即下根 M3 的起点)
m3_to_m1_end = np.empty(len(m3), dtype=np.int64)
m3_to_m1_end[:-1] = m3_to_m1_start[1:]
m3_to_m1_end[-1]  = len(df)

# ── 回测主循环 ────────────────────────────────────
print("开始回测...")
m3_opens  = m3['open'].values
m3_closes = m3['close'].values
m3_times  = m3.index

trades = []
pos = None   # {'dir':1/-1, 'entry':float, 'sl':float, 'tp':float, 'entry_time':ts, 'votes':int}

for i in range(1, len(m3)):

    # 1. 管理持仓: 用当前 M3 bar 对应的 M1 bars 检查 SL/TP
    if pos is not None:
        s, e = int(m3_to_m1_start[i]), int(m3_to_m1_end[i])
        hit_tp = False
        hit_sl = False
        exit_price = 0.0
        for mi in range(s, e):
            if pos['dir'] == 1:   # 多单
                if m1_high[mi] >= pos['tp']:
                    hit_tp = True; exit_price = pos['tp']; break
                if m1_low[mi]  <= pos['sl']:
                    hit_sl = True; exit_price = pos['sl']; break
            else:                 # 空单
                if m1_low[mi]  <= pos['tp']:
                    hit_tp = True; exit_price = pos['tp']; break
                if m1_high[mi] >= pos['sl']:
                    hit_sl = True; exit_price = pos['sl']; break

        if hit_tp or hit_sl:
            pnl = (exit_price - pos['entry']) * pos['dir']
            trades.append({
                'entry_time': pos['entry_time'],
                'exit_time' : m3_times[i],
                'dir'       : pos['dir'],
                'entry'     : round(pos['entry'], 2),
                'exit'      : round(exit_price, 2),
                'pnl'       : round(pnl, 2),
                'result'    : 'TP' if hit_tp else 'SL',
                'votes'     : pos['votes'],
            })
            pos = None

    # 2. 已有持仓则跳过开仓 (单笔策略)
    if pos is not None:
        continue

    # 3. 判断上根 M3 bar 的触发信号
    sig = int(cross[i - 1])
    if sig == 0:
        continue

    vb  = int(vote_bear[i - 1])   # 上根 M3 bar 时死叉票数
    vl  = int(vote_bull[i - 1])   # 上根 M3 bar 时金叉票数
    rsi = float(rsi_vals[i - 1])  # 上根 M3 bar 的 RSI

    entry = float(m3_opens[i])    # 当前 M3 bar 开盘价入场

    # 金叉 + 高周期多数死叉 → 假突破 → 做空
    if sig == 1 and vb >= MIN_VOTES:
        rsi_ok = (not USE_RSI) or (RSI_S_MIN <= rsi <= RSI_S_MAX)
        if rsi_ok and entry > 0:
            pos = {
                'dir'       : -1,
                'entry'     : entry,
                'sl'        : entry + SL_USD,
                'tp'        : entry - TP_USD,
                'entry_time': m3_times[i],
                'votes'     : vb,
            }

    # 死叉 + 高周期多数金叉 → 假破位 → 做多
    elif sig == -1 and vl >= MIN_VOTES:
        rsi_ok = (not USE_RSI) or (RSI_L_MIN <= rsi <= RSI_L_MAX)
        if rsi_ok and entry > 0:
            pos = {
                'dir'       : 1,
                'entry'     : entry,
                'sl'        : entry - SL_USD,
                'tp'        : entry + TP_USD,
                'entry_time': m3_times[i],
                'votes'     : vl,
            }

# 末尾持仓按 M3 最后 close 强平
if pos is not None:
    ep = float(m3_closes[-1])
    pnl = (ep - pos['entry']) * pos['dir']
    trades.append({
        'entry_time': pos['entry_time'],
        'exit_time' : m3_times[-1],
        'dir'       : pos['dir'],
        'entry'     : round(pos['entry'], 2),
        'exit'      : round(ep, 2),
        'pnl'       : round(pnl, 2),
        'result'    : 'EXPIRE',
        'votes'     : pos['votes'],
    })

# ── 统计输出 ──────────────────────────────────────
if not trades:
    print("\n无交易产生 — MinVoteCount 可能过严,或数据期内符合条件的形态极少")
    sys.exit(0)

tr = pd.DataFrame(trades).sort_values('entry_time').reset_index(drop=True)
tr['equity'] = tr['pnl'].cumsum()

wins  = tr[tr['pnl'] > 0]
losss = tr[tr['pnl'] < 0]
wr    = len(wins) / len(tr) * 100
pf    = (wins['pnl'].sum() / abs(losss['pnl'].sum())) if len(losss) > 0 else float('inf')

eq   = np.concatenate([[0], tr['equity'].values])
peak = np.maximum.accumulate(eq)
dd   = eq - peak
max_dd = float(dd.min())

print()
print("╔══════════ 回光返照 回测结果 ══════════╗")
print(f"║ 数据: {df.index.min().date()} ~ {df.index.max().date():<26}║")
print(f"║ 参数: MinVotes={MIN_VOTES}/4  SL=${SL_USD}  TP=${TP_USD}  RSI={'开' if USE_RSI else '关':<14}║")
print("╠═══════════════════════════════════════╣")
print(f"║ 总交易:    {len(tr):>4}  (多:{(tr['dir']==1).sum():>3}  空:{(tr['dir']==-1).sum():>3})        ║")
print(f"║ 胜率:      {wr:>5.1f}%  ({len(wins)}胜 / {len(losss)}负)           ║")
print(f"║ TP/SL:     {(tr['result']=='TP').sum():>3} / {(tr['result']=='SL').sum():<3}                       ║")
if len(wins) > 0 and len(losss) > 0:
    ratio = abs(wins['pnl'].mean() / losss['pnl'].mean())
    print(f"║ 单笔均值:  盈${wins['pnl'].mean():>5.2f}  亏${losss['pnl'].mean():>6.2f}  比{ratio:.2f}       ║")
print(f"║ 利润因子:  {pf:>5.2f}                             ║")
print(f"║ 净利润:    ${tr['pnl'].sum():>7.2f}                          ║")
print(f"║ 最大回撤:  ${max_dd:>7.2f}                          ║")
print("╠═══════════════════════════════════════╣")
for d, lbl in [(1, '多单'), (-1, '空单')]:
    s = tr[tr['dir'] == d]
    if len(s):
        wrd = (s['pnl'] > 0).mean() * 100
        print(f"║ {lbl}: {len(s):>3}笔  胜率{wrd:>4.0f}%  净利${s['pnl'].sum():>7.2f}          ║")
print("╠═══════════════════════════════════════╣")
by_res = tr.groupby('result')['pnl'].agg(['count', 'sum', 'mean']).round(2)
for res, row in by_res.iterrows():
    print(f"║ [{res:<8}] {int(row['count']):>3}笔  合计${row['sum']:>7.2f}  均${row['mean']:>6.2f}      ║")
print("╚═══════════════════════════════════════╝")

tr.to_csv(OUT, index=False)
print(f"\n详细交易明细: {OUT}")
