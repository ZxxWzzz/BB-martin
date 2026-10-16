#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
修正前视偏差后的全量重跑
覆盖两份旧报告:
  tpsweep : 合成序列(3/6/12/24/48/96min) SL10 TP扫10~20 × 2入场 × 2RSI × 3投票
  classic : 原生序列 A(5/10/30/60/120) B(5/10/30/60/120/240) × 同维度

修正点:
  投票只取已完全收盘的高周期 bar (avail = bar起始时间 + 周期长度)
  进场时读 votes[i] 而非 votes[i-1]
"""
import sys
import pandas as pd
import numpy as np
try:
    sys.stdout.reconfigure(encoding='utf-8')
except Exception:
    pass

SRC = r'D:\dev\martin-analysis\xau-breakout-guard\data\raw\xauusd_m1.parquet'
OUT_TPSWEEP = r'D:\dev\martin-analysis\backtest_hgfz_tpsweep_fixed.md'
OUT_CLASSIC = r'D:\dev\martin-analysis\backtest_hgfz_classic_fixed.md'

MACD_FAST, MACD_SLOW, MACD_SIG = 12, 26, 9
RSI_PERIOD = 14
ANT_THR = 0.15
RSI_S_MIN, RSI_S_MAX = 50.0, 72.0
RSI_L_MIN, RSI_L_MAX = 28.0, 50.0


def ema(s, n): return s.ewm(span=n, adjust=False).mean()
def calc_macd(c):
    dif = ema(c, MACD_FAST) - ema(c, MACD_SLOW); dea = ema(dif, MACD_SIG)
    return dif, dea, dif - dea
def calc_rsi(c, n=14):
    d = c.diff(); g = d.clip(lower=0); l = (-d).clip(lower=0)
    ag = g.ewm(com=n-1, adjust=False).mean(); al = l.ewm(com=n-1, adjust=False).mean()
    rs = ag / al.replace(0, np.nan); return 100 - 100/(1+rs)
def resample_tf(df, rule):
    r = df.resample(rule, closed='left', label='left').agg(
        open=('open','first'), high=('high','max'), low=('low','min'), close=('close','last')
    ).dropna(subset=['close']); r = r[r['close']>0]
    r['dif'], r['dea'], r['hist'] = calc_macd(r['close'])
    r['rsi'] = calc_rsi(r['close'], RSI_PERIOD)
    return r


print("加载 M1 ...")
df = pd.read_parquet(SRC)
df['time'] = pd.to_datetime(df['time'], utc=True)
df = df.set_index('time').sort_index(); df = df[df['close'] > 0]
m1_high = df['high'].values; m1_low = df['low'].values
m1_ns = df.index.astype(np.int64).values
print(f"  {len(df):,} bars  {df.index.min().date()} ~ {df.index.max().date()}")

# ── 触发周期缓存 ────────────────────────────────
_trig_cache = {}
def get_trig(rule):
    if rule in _trig_cache: return _trig_cache[rule]
    tr = resample_tf(df, rule); N = len(tr)
    hist = tr['hist'].values
    sig_c = np.zeros(N, dtype=np.int8)
    sig_c[1:] = np.where((hist[1:]>0)&(hist[:-1]<=0), 1,
                np.where((hist[1:]<0)&(hist[:-1]>=0), -1, 0))
    sig_a = np.zeros(N, dtype=np.int8)
    wb = (hist[1:]<0)&(hist[1:]>hist[:-1])&(np.abs(hist[1:])<=ANT_THR)
    ws = (hist[1:]>0)&(hist[1:]<hist[:-1])&(np.abs(hist[1:])<=ANT_THR)
    sig_a[1:] = np.where(wb, 1, np.where(ws, -1, 0))
    ns = tr.index.astype(np.int64).values
    s = np.searchsorted(m1_ns, ns, side='left')
    e = np.empty(N, dtype=np.int64); e[:-1] = s[1:]; e[-1] = len(df)
    out = dict(tr=tr, N=N, rsi=tr['rsi'].values,
               t_open=tr['open'].values, t_close=tr['close'].values,
               sig_c=sig_c, sig_a=sig_a, s=s, e=e,
               trig_t=tr.index.to_frame(name='t').reset_index(drop=True))
    _trig_cache[rule] = out; return out

# ── 投票缓存 (FIXED: 只用已收盘 bar) ─────────────
_vote_cache = {}
def get_votes(trig_rule, vote_rules):
    key = (trig_rule, tuple(vote_rules))
    if key in _vote_cache: return _vote_cache[key]
    T = get_trig(trig_rule); trig_t = T['trig_t']
    N = T['N']
    bear = np.zeros((N, len(vote_rules)), dtype=bool)
    bull = np.zeros((N, len(vote_rules)), dtype=bool)
    for k, rule in enumerate(vote_rules):
        vdf = resample_tf(df, rule)
        v = vdf[['dif','dea']].reset_index(); v.columns = ['tv','dif','dea']
        per = pd.Timedelta(rule)
        v['avail'] = v['tv'] + per          # bar 收盘后才可用
        v = v.sort_values('avail')
        mg = pd.merge_asof(trig_t.sort_values('t'), v,
                           left_on='t', right_on='avail', direction='backward')
        bear[:,k] = (mg['dif'] < mg['dea']).values
        bull[:,k] = (mg['dif'] > mg['dea']).values
    out = (bear.sum(axis=1), bull.sum(axis=1))
    _vote_cache[key] = out; return out


def run(trig_rule, vote_rules, mode, use_rsi, min_votes, sl, tp):
    T = get_trig(trig_rule)
    vb, vl = get_votes(trig_rule, vote_rules)
    sig = T['sig_c'] if mode == '确认' else T['sig_a']
    N = T['N']; rsi = T['rsi']
    t_open = T['t_open']; t_close = T['t_close']
    s_arr = T['s']; e_arr = T['e']
    trades = []; pos = None
    for i in range(1, N):
        if pos is not None:
            s, e = int(s_arr[i]), int(e_arr[i]); done=False; ep=0.0; res=''
            for mi in range(s, e):
                if pos['dir']==1:
                    if m1_high[mi]>=pos['tp']: ep,res,done=pos['tp'],'TP',True; break
                    if m1_low[mi]<=pos['sl']: ep,res,done=pos['sl'],'SL',True; break
                else:
                    if m1_low[mi]<=pos['tp']: ep,res,done=pos['tp'],'TP',True; break
                    if m1_high[mi]>=pos['sl']: ep,res,done=pos['sl'],'SL',True; break
            if done:
                trades.append((pos['dir'], (ep-pos['entry'])*pos['dir'], res)); pos=None
        if pos is not None: continue
        s0 = int(sig[i-1]);
        if s0==0: continue
        entry = float(t_open[i])
        if entry<=0: continue
        r0 = float(rsi[i])   # FIXED: 取已进场那根的 RSI (i, 非 i-1)
        vi = i                # FIXED: 投票也取 i
        if s0==1 and int(vb[vi])>=min_votes:
            if (not use_rsi) or (RSI_S_MIN<=r0<=RSI_S_MAX):
                pos={'dir':-1,'entry':entry,'sl':entry+sl,'tp':entry-tp}
        elif s0==-1 and int(vl[vi])>=min_votes:
            if (not use_rsi) or (RSI_L_MIN<=r0<=RSI_L_MAX):
                pos={'dir':1,'entry':entry,'sl':entry-sl,'tp':entry+tp}
    if pos is not None:
        trades.append((pos['dir'],(float(t_close[-1])-pos['entry'])*pos['dir'],'EXPIRE'))
    if not trades: return dict(n=0)
    t = pd.DataFrame(trades, columns=['dir','pnl','res'])
    wins = t[t['pnl']>0]['pnl']; loss = t[t['pnl']<0]['pnl']
    eq = np.concatenate([[0], t['pnl'].cumsum().values])
    dd = (eq - np.maximum.accumulate(eq)).min()
    pf = (wins.sum()/abs(loss.sum())) if len(loss) else float('inf')
    be = sl/(sl+tp)*100
    return dict(n=len(t), wr=len(wins)/len(t)*100, pf=pf, net=t['pnl'].sum(), dd=dd,
                ntp=(t['res']=='TP').sum(), nsl=(t['res']=='SL').sum(),
                nlong=(t['dir']==1).sum(), nshort=(t['dir']==-1).sum(), be=be)


def row_str(c, nvote):
    if c['n']==0: return None
    pf = f"{c['pf']:.2f}" if np.isfinite(c['pf']) else "inf"
    rdd = c['net']/abs(c['dd']) if c['dd']!=0 else float('inf')
    rdds = f"{rdd:.1f}" if np.isfinite(rdd) else "inf"
    return (f"| {c['mode']} | {c['rsi']} | {c['mv']}/{nvote} | {c['n']} | "
            f"{c['wr']:.1f}% | {c['be']:.0f}% | {pf} | {c['net']:+.0f} | "
            f"{c['dd']:.0f} | {rdds} | {c['ntp']}/{c['nsl']} |")


# ════════════════════════════════════════════════
# 1. tpsweep: 合成序列, SL=10, TP 10~20
# ════════════════════════════════════════════════
print("\n=== tpsweep (合成序列 TP扫描) ===")
TRIG_SYN = '3min'
VOTES_SYN = ['6min','12min','24min','48min','96min']
SL_SYN = 10.0
TP_LIST = [float(x) for x in range(10, 21)]
NVOTE_SYN = len(VOTES_SYN)

rows_sweep = []
for tp in TP_LIST:
    for mode in ['确认','抢']:
        for rsi_on in [True, False]:
            for mv in [5, 4, 3]:
                print(f"  TP={tp:.0f} {mode} RSI={'开' if rsi_on else '关'} {mv}/{NVOTE_SYN} ...", end='', flush=True)
                sig = '确认' if mode=='确认' else '抢'
                st = run(TRIG_SYN, VOTES_SYN, sig, rsi_on, mv, SL_SYN, tp)
                st.update(tp=tp, mode=mode, rsi='开' if rsi_on else '关', mv=mv)
                rows_sweep.append(st)
                print(f" {st['n']}笔 {st['wr']:.1f}% PF{st.get('pf',0):.2f} 净${st.get('net',0):+.0f}")

valid_s = [c for c in rows_sweep if c['n']>0]
for c in valid_s:
    c['rdd'] = c['net']/abs(c['dd']) if c['dd']!=0 else float('inf')
top_pf  = sorted(valid_s, key=lambda x: x['pf'] if np.isfinite(x['pf']) else 0, reverse=True)[:8]
top_rdd = sorted(valid_s, key=lambda x: x['rdd'] if np.isfinite(x['rdd']) else 0, reverse=True)[:8]
top_net = sorted(valid_s, key=lambda x: x['net'], reverse=True)[:8]

HDR = ("| 入场 | RSI | 投票 | 交易 | 胜率 | 平衡胜率 | PF | 净利$ | 回撤$ | 净利/回撤 | TP/SL |\n"
       "|------|-----|------|------|------|---------|-----|-------|-------|----------|-------|")

lines_sw = []
lines_sw.append("# 回光返照 tpsweep (FIXED 前视偏差修正版)\n")
lines_sw.append(f"- 数据: {df.index.min().date()} ~ {df.index.max().date()}")
lines_sw.append(f"- 合成序列: 触发{TRIG_SYN} / 投票{'/'.join(VOTES_SYN)}")
lines_sw.append(f"- SL={SL_SYN:.0f} 固定, TP 10~20 步长1, 手数0.01=1oz")
lines_sw.append(f"- **修正: 投票只取已收盘 bar; 未计点差/滑点**\n")

def top_tbl(rows, nvote):
    out = [HDR]
    for c in rows:
        r = row_str(c, nvote)
        if r: out.append(f"| TP={c['tp']:.0f} {r[1:]}")
    return out

lines_sw.append("## TOP8 — 利润因子\n"); lines_sw += top_tbl(top_pf, NVOTE_SYN)
lines_sw.append("\n## TOP8 — 净利/回撤比\n"); lines_sw += top_tbl(top_rdd, NVOTE_SYN)
lines_sw.append("\n## TOP8 — 净利\n"); lines_sw += top_tbl(top_net, NVOTE_SYN)

lines_sw.append("\n## 各 TP 完整明细\n")
for tp in TP_LIST:
    rr = tp/SL_SYN; be = SL_SYN/(SL_SYN+tp)*100
    lines_sw.append(f"### TP={tp:.0f} (盈亏比{rr:.2f}, 平衡胜率{be:.1f}%)\n")
    lines_sw.append("| 入场 | RSI | 投票 | 交易 | 胜率 | 平衡胜率 | PF | 净利$ | 回撤$ | 净利/回撤 | TP/SL |")
    lines_sw.append("|------|-----|------|------|------|---------|-----|-------|-------|----------|-------|")
    for c in rows_sweep:
        if c['tp']!=tp: continue
        r = row_str(c, NVOTE_SYN)
        if r: lines_sw.append(r)
        else: lines_sw.append(f"| {c['mode']} | {c['rsi']} | {c['mv']}/{NVOTE_SYN} | 0 | - | - | - | - | - | - | - |")
    lines_sw.append("")

with open(OUT_TPSWEEP, 'w', encoding='utf-8') as f:
    f.write('\n'.join(lines_sw) + '\n')
print(f"\ntpsweep 写入: {OUT_TPSWEEP}")


# ════════════════════════════════════════════════
# 2. classic: 原生序列 A & B, SL=10 TP=15
# ════════════════════════════════════════════════
print("\n=== classic (原生序列) ===")
SL_CL, TP_CL = 10.0, 15.0
SERIES = [
    ('A', '5min', ['10min','30min','60min','120min'],           [4,3]),
    ('B', '5min', ['10min','30min','60min','120min','240min'],  [5,4,3]),
]

lines_cl = []
lines_cl.append("# 回光返照 classic (FIXED 前视偏差修正版)\n")
lines_cl.append(f"- 数据: {df.index.min().date()} ~ {df.index.max().date()}")
lines_cl.append(f"- 固定: SL={SL_CL:.0f} / TP={TP_CL:.0f} (盈亏比{TP_CL/SL_CL:.2f}, 平衡胜率{SL_CL/(SL_CL+TP_CL)*100:.1f}%)")
lines_cl.append(f"- **修正: 投票只取已收盘 bar; 未计点差/滑点**\n")

all_cl = []
for name, trig, votes, thrs in SERIES:
    nv = len(votes)
    lines_cl.append(f"## {name}组: 触发{trig} + 投票{nv}个 ({'/'.join(votes)})\n")
    lines_cl.append("| 入场 | RSI | 投票 | 交易 | 胜率 | 平衡胜率 | PF | 净利$ | 回撤$ | 净利/回撤 | 多/空 |")
    lines_cl.append("|------|-----|------|------|------|---------|-----|-------|-------|----------|-------|")
    for mode in ['确认','抢']:
        for rsi_on in [True, False]:
            for mv in thrs:
                print(f"  {name}组 {mode} RSI={'开' if rsi_on else '关'} {mv}/{nv} ...", end='', flush=True)
                st = run(trig, votes, mode, rsi_on, mv, SL_CL, TP_CL)
                st.update(series=name, nv=nv, mode=mode, rsi='开' if rsi_on else '关', mv=mv)
                all_cl.append(st)
                if st['n']==0:
                    lines_cl.append(f"| {mode} | {'开' if rsi_on else '关'} | {mv}/{nv} | 0 | - | - | - | - | - | - | - |")
                    print(" 0笔"); continue
                pf = f"{st['pf']:.2f}" if np.isfinite(st['pf']) else "inf"
                be = SL_CL/(SL_CL+TP_CL)*100
                rdd = st['net']/abs(st['dd']) if st['dd']!=0 else float('inf')
                rdds = f"{rdd:.1f}" if np.isfinite(rdd) else "inf"
                lines_cl.append(
                    f"| {mode} | {'开' if rsi_on else '关'} | {mv}/{nv} | {st['n']} | {st['wr']:.1f}% | "
                    f"{be:.0f}% | {pf} | {st['net']:+.0f} | {st['dd']:.0f} | {rdds} | {st['nlong']}/{st['nshort']} |")
                print(f" {st['n']}笔 {st['wr']:.1f}% PF{st['pf']:.2f} 净${st['net']:+.0f}")
    lines_cl.append("")

valid_cl = [c for c in all_cl if c['n']>0]
for c in valid_cl:
    c['rdd'] = c['net']/abs(c['dd']) if c['dd']!=0 else float('inf')
if valid_cl:
    bp = max(valid_cl, key=lambda x: x['pf'] if np.isfinite(x['pf']) else 0)
    br = max(valid_cl, key=lambda x: x['rdd'] if np.isfinite(x['rdd']) else 0)
    lines_cl.append("## 结论\n")
    lines_cl.append(f"- **PF 最高**: {bp['series']}组 {bp['mode']}/RSI{bp['rsi']}/{bp['mv']}/{bp['nv']} "
                    f"→ PF={bp['pf']:.2f}, 胜率{bp['wr']:.1f}%, 净${bp['net']:+.0f}, 回撤${bp['dd']:.0f}, {bp['n']}笔")
    lines_cl.append(f"- **净利/回撤最高**: {br['series']}组 {br['mode']}/RSI{br['rsi']}/{br['mv']}/{br['nv']} "
                    f"→ 比{br['rdd']:.1f}, PF={br['pf']:.2f}, 净${br['net']:+.0f}, 回撤${br['dd']:.0f}, {br['n']}笔")

with open(OUT_CL := OUT_CLASSIC, 'w', encoding='utf-8') as f:
    f.write('\n'.join(lines_cl) + '\n')
print(f"\nclassic 写入: {OUT_CLASSIC}")
print("\n全部完成。")
