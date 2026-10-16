#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
前视偏差核查 — 净利王合成策略
对齐方式对比:
  OLD   : 投票取"包含当前触发时刻的高周期 bar"(其收盘在未来 → lookahead)
  FIXED : 投票只取"在触发时刻已完全收盘的高周期 bar"(live 可复现)
策略固定: 触发3min, 投票6/12/24/48/96, 确认, RSI关, 4/5票, SL10/TP17
"""
import sys
import pandas as pd
import numpy as np

try:
    sys.stdout.reconfigure(encoding='utf-8')
except Exception:
    pass

SRC    = r'D:\dev\martin-analysis\xau-breakout-guard\data\raw\xauusd_m1.parquet'
OUT_MD = r'D:\dev\martin-analysis\backtest_hgfz_lookahead_check.md'

MACD_FAST, MACD_SLOW, MACD_SIG = 12, 26, 9
SL_USD, TP_USD = 10.0, 17.0
MIN_VOTES = 4
VOTES = ['6min', '12min', '24min', '48min', '96min']
TRIG  = '3min'


def ema(s, n): return s.ewm(span=n, adjust=False).mean()
def calc_macd(c):
    dif = ema(c, MACD_FAST) - ema(c, MACD_SLOW); dea = ema(dif, MACD_SIG)
    return dif, dea, dif - dea
def resample_tf(df, rule):
    r = df.resample(rule, closed='left', label='left').agg(
        open=('open','first'), high=('high','max'), low=('low','min'), close=('close','last')
    ).dropna(subset=['close']); r = r[r['close']>0]
    r['dif'], r['dea'], r['hist'] = calc_macd(r['close'])
    return r


print("加载 M1 ...")
df = pd.read_parquet(SRC)
df['time'] = pd.to_datetime(df['time'], utc=True)
df = df.set_index('time').sort_index(); df = df[df['close']>0]
m1_high = df['high'].values; m1_low = df['low'].values
m1_ns = df.index.astype(np.int64).values

trig = resample_tf(df, TRIG); N = len(trig)
hist = trig['hist'].values
t_open = trig['open'].values; t_close = trig['close'].values
t_ns = trig.index.astype(np.int64).values
t_s = np.searchsorted(m1_ns, t_ns, side='left')
t_e = np.empty(N, dtype=np.int64); t_e[:-1] = t_s[1:]; t_e[-1] = len(df)

# 触发信号 (确认: hist 变号) — 两版共用, 无 lookahead
sig = np.zeros(N, dtype=np.int8)
sig[1:] = np.where((hist[1:]>0)&(hist[:-1]<=0), 1, np.where((hist[1:]<0)&(hist[:-1]>=0), -1, 0))

trig_t = trig.index.to_frame(name='t').reset_index(drop=True)

def build_votes(align):
    """align='containing'(OLD/lookahead) 或 'closed'(FIXED)"""
    bear = np.zeros((N, len(VOTES)), dtype=bool)
    bull = np.zeros((N, len(VOTES)), dtype=bool)
    for k, rule in enumerate(VOTES):
        vdf = resample_tf(df, rule)
        v = vdf[['dif','dea']].reset_index(); v.columns = ['tv','dif','dea']
        if align == 'containing':
            key = 'tv'                      # 起始时间, backward → 包含当前时刻那根(未收完)
            vv = v
        else:
            per = pd.Timedelta(rule)
            vv = v.copy(); vv['avail'] = vv['tv'] + per   # 收盘后才可用
            vv = vv.sort_values('avail'); key = 'avail'
        mg = pd.merge_asof(trig_t.sort_values('t'), vv, left_on='t', right_on=key, direction='backward')
        bear[:,k] = (mg['dif'] < mg['dea']).values
        bull[:,k] = (mg['dif'] > mg['dea']).values
    return bear.sum(axis=1), bull.sum(axis=1)


def run(vote_bear, vote_bull, use_idx_shift):
    """use_idx_shift: OLD 用 votes[i-1] (对齐 T_{i-1}); FIXED 用 votes[i] (对齐进场 T_i)"""
    trades = []
    pos = None
    for i in range(1, N):
        if pos is not None:
            s, e = int(t_s[i]), int(t_e[i]); done=False; ep=0.0
            for mi in range(s, e):
                if pos['dir']==1:
                    if m1_high[mi]>=pos['tp']: ep,done=pos['tp'],True; break
                    if m1_low[mi]<=pos['sl']: ep,done=pos['sl'],True; break
                else:
                    if m1_low[mi]<=pos['tp']: ep,done=pos['tp'],True; break
                    if m1_high[mi]>=pos['sl']: ep,done=pos['sl'],True; break
            if done:
                trades.append((pos['dir'], (ep-pos['entry'])*pos['dir'])); pos=None
        if pos is not None: continue
        s0 = int(sig[i-1])
        if s0==0: continue
        entry = float(t_open[i])
        if entry<=0: continue
        vi = (i-1) if use_idx_shift else i
        if s0==1 and int(vote_bear[vi])>=MIN_VOTES:
            pos={'dir':-1,'entry':entry,'sl':entry+SL_USD,'tp':entry-TP_USD}
        elif s0==-1 and int(vote_bull[vi])>=MIN_VOTES:
            pos={'dir':1,'entry':entry,'sl':entry-SL_USD,'tp':entry+TP_USD}
    if pos is not None:
        trades.append((pos['dir'], (float(t_close[-1])-pos['entry'])*pos['dir']))
    if not trades: return dict(n=0)
    t = pd.DataFrame(trades, columns=['dir','pnl'])
    wins = t[t['pnl']>0]['pnl']; loss = t[t['pnl']<0]['pnl']
    eq = np.concatenate([[0], t['pnl'].cumsum().values])
    dd = (eq - np.maximum.accumulate(eq)).min()
    pf = (wins.sum()/abs(loss.sum())) if len(loss) else float('inf')
    return dict(n=len(t), wr=len(wins)/len(t)*100, pf=pf, net=t['pnl'].sum(), dd=dd,
                nlong=(t['dir']==1).sum(), nshort=(t['dir']==-1).sum())


print("OLD (lookahead) ...")
ob, ol = build_votes('containing')
old = run(ob, ol, use_idx_shift=True)
print("FIXED (closed-only) ...")
fb, fl = build_votes('closed')
fix = run(fb, fl, use_idx_shift=False)

def fmt(r):
    pf = f"{r['pf']:.2f}" if np.isfinite(r['pf']) else "inf"
    return (f"{r['n']}笔 | 胜率{r['wr']:.1f}% | PF {pf} | 净${r['net']:+.0f} | "
            f"回撤${r['dd']:.0f} | 多{r['nlong']}/空{r['nshort']}")

lines = []
lines.append("# 前视偏差核查 — 净利王合成策略\n")
lines.append(f"- 数据: XAUUSD M1 {df.index.min().date()}~{df.index.max().date()}")
lines.append(f"- 策略: 触发{TRIG}/投票{'/'.join(VOTES)}/确认/RSI关/{MIN_VOTES}票5/SL{SL_USD:.0f}TP{TP_USD:.0f}")
lines.append("- **未计点差/滑点**\n")
lines.append("| 版本 | 对齐方式 | 笔数 | 胜率 | 利润因子 | 净利$ | 回撤$ |")
lines.append("|------|---------|------|------|---------|-------|-------|")
pfo = f"{old['pf']:.2f}" if np.isfinite(old['pf']) else "inf"
pff = f"{fix['pf']:.2f}" if np.isfinite(fix['pf']) else "inf"
lines.append(f"| OLD (有前视) | 投票取当前未收完的高周期bar | {old['n']} | {old['wr']:.1f}% | {pfo} | {old['net']:+.0f} | {old['dd']:.0f} |")
lines.append(f"| FIXED (正确) | 投票只取已收盘高周期bar | {fix['n']} | {fix['wr']:.1f}% | {pff} | {fix['net']:+.0f} | {fix['dd']:.0f} |")
lines.append("")
dwr = fix['wr'] - old['wr']
dnet = fix['net'] - old['net']
lines.append(f"**差异**: 胜率 {dwr:+.1f} 点, 净利 {dnet:+.0f}, 利润因子 {old['pf']:.2f}→{fix['pf']:.2f}")
lines.append("")
lines.append("FIXED 版才是 EA 在实盘能复现的真实表现 (live 无法偷看未收完的高周期bar)。")

with open(OUT_MD, 'w', encoding='utf-8') as f:
    f.write('\n'.join(lines) + '\n')

print("\n=== OLD   :", fmt(old))
print("=== FIXED :", fmt(fix))
print("写入:", OUT_MD)
