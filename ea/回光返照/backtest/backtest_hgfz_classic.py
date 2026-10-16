#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
回光返照 — 经典原生周期回测
对比两组全 MT5 原生周期的时间序列 (可直接 iMACD, 无需 M1 合成):
  A 组: 触发 M5, 投票 M10/M30/M60/M120   (4 票; 阈值 4,3)
  B 组: 触发 M5, 投票 M10/M30/M60/M120/M240 (5 票; 阈值 5,4,3)
每组 × 入场(确认/抢) × RSI(开/关)
固定 SL=10 / TP=15 (冠军风控), 隔离"换周期"单一变量
"""
import sys
import pandas as pd
import numpy as np

try:
    sys.stdout.reconfigure(encoding='utf-8')
except Exception:
    pass

SRC    = r'D:\dev\martin-analysis\xau-breakout-guard\data\raw\xauusd_m1.parquet'
OUT_MD = r'D:\dev\martin-analysis\backtest_hgfz_classic.md'

MACD_FAST, MACD_SLOW, MACD_SIG = 12, 26, 9
RSI_PERIOD = 14
SL_USD, TP_USD = 10.0, 15.0
ANT_THR = 0.15
RSI_S_MIN, RSI_S_MAX = 50.0, 72.0
RSI_L_MIN, RSI_L_MAX = 28.0, 50.0

TRIG_TF = '5min'   # 两组共用的触发周期


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
        open=('open', 'first'), high=('high', 'max'),
        low=('low', 'min'), close=('close', 'last'),
    ).dropna(subset=['close'])
    r = r[r['close'] > 0]
    r['dif'], r['dea'], r['hist'] = calc_macd(r['close'])
    r['rsi'] = calc_rsi(r['close'], RSI_PERIOD)
    return r


print("加载 M1 ...")
df = pd.read_parquet(SRC)
df['time'] = pd.to_datetime(df['time'], utc=True)
df = df.set_index('time').sort_index()
df = df[df['close'] > 0]
print(f"  {len(df):,} bars  {df.index.min().date()} ~ {df.index.max().date()}")

m1_high = df['high'].values
m1_low  = df['low'].values
m1_ns   = df.index.astype(np.int64).values

# 触发周期 (两组共用)
trig = resample_tf(df, TRIG_TF)
N = len(trig)
hist = trig['hist'].values
rsi  = trig['rsi'].values
t_open  = trig['open'].values
t_close = trig['close'].values
t_times = trig.index
t_ns = trig.index.astype(np.int64).values
t_s = np.searchsorted(m1_ns, t_ns, side='left')
t_e = np.empty(N, dtype=np.int64)
t_e[:-1] = t_s[1:]
t_e[-1]  = len(df)

# 两种入场信号
sig_confirm = np.zeros(N, dtype=np.int8)
sig_confirm[1:] = np.where((hist[1:] > 0) & (hist[:-1] <= 0),  1,
                   np.where((hist[1:] < 0) & (hist[:-1] >= 0), -1, 0))
sig_ant = np.zeros(N, dtype=np.int8)
wb = (hist[1:] < 0) & (hist[1:] > hist[:-1]) & (np.abs(hist[1:]) <= ANT_THR)
ws = (hist[1:] > 0) & (hist[1:] < hist[:-1]) & (np.abs(hist[1:]) <= ANT_THR)
sig_ant[1:] = np.where(wb, 1, np.where(ws, -1, 0))


def build_votes(vote_rules):
    """把一组投票周期对齐到触发周期时间轴, 返回 (死叉票数, 金叉票数)"""
    trig_t = trig.index.to_frame(name='t').reset_index(drop=True)
    bear = np.zeros((N, len(vote_rules)), dtype=bool)
    bull = np.zeros((N, len(vote_rules)), dtype=bool)
    for k, rule in enumerate(vote_rules):
        vdf = resample_tf(df, rule)
        v = vdf[['dif', 'dea']].reset_index()
        v.columns = ['tv', 'dif', 'dea']
        mg = pd.merge_asof(trig_t, v, left_on='t', right_on='tv', direction='backward')
        bear[:, k] = (mg['dif'] < mg['dea']).values
        bull[:, k] = (mg['dif'] > mg['dea']).values
    return bear.sum(axis=1), bull.sum(axis=1)


def run(sig, use_rsi, min_votes, vote_bear, vote_bull):
    trades = []
    pos = None
    for i in range(1, N):
        if pos is not None:
            s, e = int(t_s[i]), int(t_e[i])
            done = False; ep = 0.0; res = ''
            for mi in range(s, e):
                if pos['dir'] == 1:
                    if m1_high[mi] >= pos['tp']: ep, res, done = pos['tp'], 'TP', True; break
                    if m1_low[mi]  <= pos['sl']: ep, res, done = pos['sl'], 'SL', True; break
                else:
                    if m1_low[mi]  <= pos['tp']: ep, res, done = pos['tp'], 'TP', True; break
                    if m1_high[mi] >= pos['sl']: ep, res, done = pos['sl'], 'SL', True; break
            if done:
                trades.append((pos['dir'], (ep - pos['entry']) * pos['dir'], res))
                pos = None
        if pos is not None:
            continue
        s0 = int(sig[i - 1])
        if s0 == 0:
            continue
        entry = float(t_open[i])
        if entry <= 0:
            continue
        r0 = float(rsi[i - 1])
        if s0 == 1 and int(vote_bear[i - 1]) >= min_votes:
            if (not use_rsi) or (RSI_S_MIN <= r0 <= RSI_S_MAX):
                pos = {'dir': -1, 'entry': entry, 'sl': entry + SL_USD, 'tp': entry - TP_USD}
        elif s0 == -1 and int(vote_bull[i - 1]) >= min_votes:
            if (not use_rsi) or (RSI_L_MIN <= r0 <= RSI_L_MAX):
                pos = {'dir': 1, 'entry': entry, 'sl': entry - SL_USD, 'tp': entry + TP_USD}
    if pos is not None:
        trades.append((pos['dir'], (float(t_close[-1]) - pos['entry']) * pos['dir'], 'EXPIRE'))
    if not trades:
        return dict(n=0)
    t = pd.DataFrame(trades, columns=['dir', 'pnl', 'res'])
    wins = t[t['pnl'] > 0]['pnl']
    loss = t[t['pnl'] < 0]['pnl']
    eq = np.concatenate([[0], t['pnl'].cumsum().values])
    dd = (eq - np.maximum.accumulate(eq)).min()
    pf = (wins.sum() / abs(loss.sum())) if len(loss) else float('inf')
    return dict(n=len(t), nlong=(t['dir'] == 1).sum(), nshort=(t['dir'] == -1).sum(),
                wr=len(wins) / len(t) * 100,
                ntp=(t['res'] == 'TP').sum(), nsl=(t['res'] == 'SL').sum(),
                pf=pf, net=t['pnl'].sum(), dd=dd)


SERIES = [
    ('A', ['10min', '30min', '60min', '120min'],          [4, 3]),
    ('B', ['10min', '30min', '60min', '120min', '240min'], [5, 4, 3]),
]

lines = []
lines.append("# 回光返照 — 经典原生周期回测\n")
lines.append(f"- 数据: XAUUSD M1 {df.index.min().date()} ~ {df.index.max().date()} ({len(df):,} bars)")
lines.append(f"- 固定: SL=${SL_USD:.0f} / TP=${TP_USD:.0f} (盈亏比1.5, 平衡胜率40%), 手数0.01=1oz")
lines.append(f"- 触发周期={TRIG_TF}; 全部 MT5 原生周期 → EA 可直接 iMACD")
lines.append(f"- 抢(anticipate)阈值 |hist|<={ANT_THR}")
lines.append(f"- **未计点差/滑点**; M120/M240 在 live 服务器时区下切桶边界可能与此 UTC 回测略偏 (待 live 对齐验证)\n")

all_rows = []
for name, votes, thrs in SERIES:
    nv = len(votes)
    vb, vl = build_votes(votes)
    lines.append(f"## {name} 组: 触发{TRIG_TF} + 投票{nv}个 ({'/'.join(votes)})\n")
    lines.append("| 入场 | RSI | 投票 | 交易 | 胜率 | 利润因子 | 净利$ | 回撤$ | 净利/回撤 | 多/空 |")
    lines.append("|------|-----|------|------|------|---------|-------|-------|----------|-------|")
    for mode_name, sig in [('确认', sig_confirm), ('抢', sig_ant)]:
        for rsi_on in [True, False]:
            for mv in thrs:
                print(f"  {name}组: 入场={mode_name} RSI={'开' if rsi_on else '关'} 投票>={mv}/{nv} ...")
                st = run(sig, rsi_on, mv, vb, vl)
                st.update(series=name, nv=nv, mode=mode_name,
                          rsi='开' if rsi_on else '关', mv=mv)
                all_rows.append(st)
                if st['n'] == 0:
                    lines.append(f"| {mode_name} | {st['rsi']} | {mv}/{nv} | 0 | - | - | - | - | - | - |")
                    continue
                pf  = f"{st['pf']:.2f}" if np.isfinite(st['pf']) else "inf"
                rdd = (st['net'] / abs(st['dd'])) if st['dd'] != 0 else float('inf')
                rdds = f"{rdd:.1f}" if np.isfinite(rdd) else "inf"
                lines.append(
                    f"| {mode_name} | {st['rsi']} | {mv}/{nv} | {st['n']} | {st['wr']:.1f}% | "
                    f"{pf} | {st['net']:+.0f} | {st['dd']:.0f} | {rdds} | {st['nlong']}/{st['nshort']} |")
    lines.append("")

# 全局最优
valid = [c for c in all_rows if c['n'] > 0]
for c in valid:
    c['rdd'] = c['net'] / abs(c['dd']) if c['dd'] != 0 else float('inf')
best_pf  = max(valid, key=lambda x: x['pf'] if np.isfinite(x['pf']) else 0)
best_rdd = max(valid, key=lambda x: x['rdd'] if np.isfinite(x['rdd']) else 0)
lines.append("## 结论\n")
lines.append(f"- **利润因子最高**: {best_pf['series']}组 {best_pf['mode']}/RSI{best_pf['rsi']}/{best_pf['mv']}/{best_pf['nv']} "
             f"→ PF={best_pf['pf']:.2f}, 胜率{best_pf['wr']:.1f}%, 净${best_pf['net']:+.0f}, 回撤${best_pf['dd']:.0f}, {best_pf['n']}笔")
lines.append(f"- **净利/回撤比最高**: {best_rdd['series']}组 {best_rdd['mode']}/RSI{best_rdd['rsi']}/{best_rdd['mv']}/{best_rdd['nv']} "
             f"→ 比{best_rdd['rdd']:.1f}, PF={best_rdd['pf']:.2f}, 净${best_rdd['net']:+.0f}, 回撤${best_rdd['dd']:.0f}, {best_rdd['n']}笔")

with open(OUT_MD, 'w', encoding='utf-8') as f:
    f.write('\n'.join(lines) + '\n')
print(f"\n完成, {len(all_rows)} 用例, 结果写入: {OUT_MD}")
