#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
回光返照 参数对比回测
矩阵: EntryMode(confirm/anticipate) x RSI(on/off) x MinVotes(4/3) = 8 组
指标只算一次 (与策略参数无关), 复用到所有组合
结果写入 markdown, 规避终端编码
"""
import sys
import pandas as pd
import numpy as np

try:
    sys.stdout.reconfigure(encoding='utf-8')
except Exception:
    pass

SRC = r'D:\dev\martin-analysis\xau-breakout-guard\data\raw\xauusd_m1.parquet'
OUT_MD = r'D:\dev\martin-analysis\backtest_hgfz_tpsweep.md'

# ── 固定参数 (全组合共用) ──────────────────────
MACD_FAST, MACD_SLOW, MACD_SIG = 12, 26, 9
RSI_PERIOD = 14
TF_TRIG    = '3min'
TF_VOTES   = ['6min', '12min', '24min', '48min', '96min']   # 5 个投票周期

SL_USD     = 10.0
TP_USD     = 15.0
ANT_THR    = 0.15     # anticipate 模式: |hist| <= 该值且收敛 视为将穿 (EA 默认)

RSI_S_MIN, RSI_S_MAX = 50.0, 72.0   # 做空 RSI 带
RSI_L_MIN, RSI_L_MAX = 28.0, 50.0   # 做多 RSI 带
# ───────────────────────────────────────────────


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


# ── 加载 + 指标 (一次性) ───────────────────────
print("加载 M1 + 合成周期 + 算指标 (只做一次)...")
df = pd.read_parquet(SRC)
df['time'] = pd.to_datetime(df['time'], utc=True)
df = df.set_index('time').sort_index()
df = df[df['close'] > 0]

m3 = resample_tf(df, TF_TRIG)
vote_tfs = [resample_tf(df, tf) for tf in TF_VOTES]

# 投票周期对齐到 M3 时间轴
trig_t = m3.index.to_frame(name='t').reset_index(drop=True)
bear = np.zeros((len(m3), len(vote_tfs)), dtype=bool)
bull = np.zeros((len(m3), len(vote_tfs)), dtype=bool)
for k, vdf in enumerate(vote_tfs):
    v = vdf[['dif', 'dea']].reset_index()
    v.columns = ['tv', 'dif', 'dea']
    mg = pd.merge_asof(trig_t, v, left_on='t', right_on='tv', direction='backward')
    bear[:, k] = (mg['dif'] < mg['dea']).values
    bull[:, k] = (mg['dif'] > mg['dea']).values
vote_bear = bear.sum(axis=1)
vote_bull = bull.sum(axis=1)

hist = m3['hist'].values
rsi  = m3['rsi'].values
m3_open  = m3['open'].values
m3_close = m3['close'].values
m3_times = m3.index

# ── 两种入场信号 (向量化) ──────────────────────
N = len(m3)
# CONFIRM: 真穿越
sig_confirm = np.zeros(N, dtype=np.int8)
sig_confirm[1:] = np.where((hist[1:] > 0) & (hist[:-1] <= 0),  1,
                   np.where((hist[1:] < 0) & (hist[:-1] >= 0), -1, 0))
# ANTICIPATE: 收敛逼近零轴, 尚未穿
sig_ant = np.zeros(N, dtype=np.int8)
will_bull = (hist[1:] < 0) & (hist[1:] > hist[:-1]) & (np.abs(hist[1:]) <= ANT_THR)
will_bear = (hist[1:] > 0) & (hist[1:] < hist[:-1]) & (np.abs(hist[1:]) <= ANT_THR)
sig_ant[1:] = np.where(will_bull, 1, np.where(will_bear, -1, 0))

# ── M1 high/low 映射 (SL/TP 精确判定) ──────────
m1_high = df['high'].values
m1_low  = df['low'].values
m1_ns = df.index.astype(np.int64).values
m3_ns = m3.index.astype(np.int64).values
m3_s = np.searchsorted(m1_ns, m3_ns, side='left')
m3_e = np.empty(N, dtype=np.int64)
m3_e[:-1] = m3_s[1:]
m3_e[-1] = len(df)


def run(sig, use_rsi, min_votes, tp_usd):
    """返回统计 dict"""
    trades = []
    pos = None
    for i in range(1, N):
        # 管理持仓
        if pos is not None:
            s, e = int(m3_s[i]), int(m3_e[i])
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
        # 开仓
        s0 = int(sig[i - 1])
        if s0 == 0:
            continue
        entry = float(m3_open[i])
        if entry <= 0:
            continue
        r0 = float(rsi[i - 1])
        if s0 == 1 and int(vote_bear[i - 1]) >= min_votes:        # 金叉+死叉票→空
            if (not use_rsi) or (RSI_S_MIN <= r0 <= RSI_S_MAX):
                pos = {'dir': -1, 'entry': entry, 'sl': entry + SL_USD, 'tp': entry - tp_usd}
        elif s0 == -1 and int(vote_bull[i - 1]) >= min_votes:     # 死叉+金叉票→多
            if (not use_rsi) or (RSI_L_MIN <= r0 <= RSI_L_MAX):
                pos = {'dir': 1, 'entry': entry, 'sl': entry - SL_USD, 'tp': entry + tp_usd}
    # 末尾强平
    if pos is not None:
        trades.append((pos['dir'], (float(m3_close[-1]) - pos['entry']) * pos['dir'], 'EXPIRE'))

    if not trades:
        return dict(n=0)
    t = pd.DataFrame(trades, columns=['dir', 'pnl', 'res'])
    wins = t[t['pnl'] > 0]['pnl']
    loss = t[t['pnl'] < 0]['pnl']
    eq = np.concatenate([[0], t['pnl'].cumsum().values])
    dd = (eq - np.maximum.accumulate(eq)).min()
    pf = (wins.sum() / abs(loss.sum())) if len(loss) else float('inf')
    return dict(
        n=len(t), nlong=(t['dir'] == 1).sum(), nshort=(t['dir'] == -1).sum(),
        wr=len(wins) / len(t) * 100,
        ntp=(t['res'] == 'TP').sum(), nsl=(t['res'] == 'SL').sum(),
        pf=pf, net=t['pnl'].sum(), dd=dd,
    )


# ── TP 扫描: SL 固定, TP 从 10 到 20, 每个 TP 跑 12 组合 ──
NVOTE   = len(TF_VOTES)
TP_LIST = [float(x) for x in range(10, 21)]   # 10,11,...,20

all_rows = []   # 每条: dict(tp, mode, rsi, mv, 统计...)
for tp in TP_LIST:
    for mode_name, sig in [('确认', sig_confirm), ('抢', sig_ant)]:
        for rsi_on in [True, False]:
            for mv in [5, 4, 3]:
                print(f"  跑: TP={tp:.0f}  入场={mode_name}  RSI={'开' if rsi_on else '关'}  投票>={mv}/{NVOTE} ...")
                st = run(sig, rsi_on, mv, tp)
                st['tp']   = tp
                st['mode'] = mode_name
                st['rsi']  = '开' if rsi_on else '关'
                st['mv']   = mv
                all_rows.append(st)

# ── 写 markdown ────────────────────────────────
lines = []
lines.append("# 回光返照 TP 扫描回测 (SL 固定 10)\n")
lines.append(f"- 数据: XAUUSD M1 {df.index.min().date()} ~ {df.index.max().date()} ({len(df):,} bars)")
lines.append(f"- SL=${SL_USD} 固定; TP 从 ${TP_LIST[0]:.0f} 到 ${TP_LIST[-1]:.0f} (步长1), 手数0.01=1oz")
lines.append(f"- 触发周期={TF_TRIG}; 投票成员({NVOTE}个)={'/'.join(TF_VOTES)}")
lines.append(f"- 抢(anticipate)阈值 |hist|<={ANT_THR}")
lines.append(f"- 盈亏比=TP/SL, 随机break-even胜率=SL/(SL+TP)")
lines.append(f"- **未计点差/滑点** (纯逻辑边际对比)")
lines.append(f"- 共 {len(TP_LIST)}×12 = {len(all_rows)} 个用例\n")

valid = [c for c in all_rows if c['n'] > 0]

# 全局 TOP 榜 (先放最前, 一眼看结论)
lines.append("## 全局最优 (132 用例)\n")
top_pf  = sorted(valid, key=lambda x: (x['pf'] if np.isfinite(x['pf']) else 0), reverse=True)[:8]
top_net = sorted(valid, key=lambda x: x['net'], reverse=True)[:8]
# 风险调整: 净利/|回撤|
for c in valid:
    c['ret_dd'] = c['net'] / abs(c['dd']) if c['dd'] != 0 else float('inf')
top_rdd = sorted(valid, key=lambda x: (x['ret_dd'] if np.isfinite(x['ret_dd']) else 0), reverse=True)[:8]

def row_str(c):
    be = SL_USD / (SL_USD + c['tp']) * 100
    pf = f"{c['pf']:.2f}" if np.isfinite(c['pf']) else "inf"
    rdd = f"{c['ret_dd']:.1f}" if np.isfinite(c['ret_dd']) else "inf"
    return (f"| {c['tp']:.0f} | {c['mode']} | {c['rsi']} | {c['mv']}/{NVOTE} | {c['n']} | "
            f"{c['wr']:.1f}% | {be:.0f}% | {pf} | {c['net']:+.0f} | {c['dd']:.0f} | {rdd} |")

hdr = ("| TP | 入场 | RSI | 投票 | 交易 | 胜率 | 盈亏平衡 | 利润因子 | 净利$ | 回撤$ | 净利/回撤 |\n"
       "|----|------|-----|------|------|------|---------|---------|-------|-------|----------|")

lines.append("### 按利润因子 TOP8\n")
lines.append(hdr)
for c in top_pf:  lines.append(row_str(c))
lines.append("\n### 按净利/回撤比 TOP8 (风险调整后最优)\n")
lines.append(hdr)
for c in top_rdd: lines.append(row_str(c))
lines.append("\n### 按净利 TOP8\n")
lines.append(hdr)
for c in top_net: lines.append(row_str(c))

# 每个 TP 的完整 12 组合明细
lines.append("\n## 各 TP 完整明细\n")
for tp in TP_LIST:
    rr = tp / SL_USD
    be = SL_USD / (SL_USD + tp) * 100
    lines.append(f"### TP=${tp:.0f} (盈亏比{rr:.2f}, 平衡胜率{be:.1f}%)\n")
    lines.append("| 入场 | RSI | 投票 | 交易 | 胜率 | 利润因子 | 净利$ | 回撤$ | TP/SL |")
    lines.append("|------|-----|------|------|------|---------|-------|-------|-------|")
    for c in all_rows:
        if c['tp'] != tp:
            continue
        if c['n'] == 0:
            lines.append(f"| {c['mode']} | {c['rsi']} | {c['mv']}/{NVOTE} | 0 | - | - | - | - | - |")
            continue
        pf = f"{c['pf']:.2f}" if np.isfinite(c['pf']) else "inf"
        lines.append(
            f"| {c['mode']} | {c['rsi']} | {c['mv']}/{NVOTE} | {c['n']} | {c['wr']:.1f}% | "
            f"{pf} | {c['net']:+.0f} | {c['dd']:.0f} | {c['ntp']}/{c['nsl']} |")
    lines.append("")

with open(OUT_MD, 'w', encoding='utf-8') as f:
    f.write('\n'.join(lines) + '\n')

print(f"\n完成, {len(all_rows)} 用例, 结果写入: {OUT_MD}")
