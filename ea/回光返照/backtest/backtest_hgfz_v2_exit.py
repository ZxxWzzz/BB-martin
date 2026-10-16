#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
回光返照 v2 — 删RSI + 时间序列延到1D + 出场优化 + 样本外检验
修正口径: 投票只取已收盘高周期bar (无前视); 触发用已收M3 bar[1]。
无 RSI。入场=确认(真穿越)。

时间序列(几何×2延到1D):
  触发 3min; 投票 6/12/24/48/96/192/384/768/1440(=1D) 共9个
  投票阈值扫 9/8/7/6/5

出场对比:
  FIXED   : SL10 / TP15 (基准)
  TRAIL_a : 硬SL10 + 盈利≥a后, 跟踪止损距最优价 a (无固定TP, 让利润跑)
            a ∈ {5,8,10}
样本外: 前60%时间=train, 后40%=test; 对全样本TOP配置看train/test是否仍成立。
"""
import sys
import pandas as pd
import numpy as np
try:
    sys.stdout.reconfigure(encoding='utf-8')
except Exception:
    pass

SRC = r'D:\dev\martin-analysis\xau-breakout-guard\data\raw\xauusd_m1.parquet'
OUT_MD = r'D:\dev\martin-analysis\backtest_hgfz_v2_exit.md'

MACD_FAST, MACD_SLOW, MACD_SIG = 12, 26, 9
TRIG = '3min'
VOTES = ['6min','12min','24min','48min','96min','192min','384min','768min','1440min']
NVOTE = len(VOTES)
THRESHOLDS = [9, 8, 7, 6, 5]
HARD_SL = 10.0
FIXED_TP = 15.0
TRAIL_SET = [5.0, 8.0, 10.0]   # 跟踪距离=激活阈值


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
print(f"  {len(df):,} bars  {df.index.min().date()} ~ {df.index.max().date()}")

# 触发周期 (确认信号)
trig = resample_tf(df, TRIG); N = len(trig)
hist = trig['hist'].values
t_open = trig['open'].values; t_close = trig['close'].values
t_times = trig.index
t_ns = trig.index.astype(np.int64).values
t_s = np.searchsorted(m1_ns, t_ns, side='left')
t_e = np.empty(N, dtype=np.int64); t_e[:-1] = t_s[1:]; t_e[-1] = len(df)
sig = np.zeros(N, dtype=np.int8)
sig[1:] = np.where((hist[1:]>0)&(hist[:-1]<=0), 1, np.where((hist[1:]<0)&(hist[:-1]>=0), -1, 0))

# 投票 (FIXED: 已收盘bar)
print("合成投票周期(到1D) ...")
trig_t = trig.index.to_frame(name='t').reset_index(drop=True)
bear = np.zeros((N, NVOTE), dtype=bool); bull = np.zeros((N, NVOTE), dtype=bool)
for k, rule in enumerate(VOTES):
    vdf = resample_tf(df, rule)
    v = vdf[['dif','dea']].reset_index(); v.columns=['tv','dif','dea']
    v['avail'] = v['tv'] + pd.Timedelta(rule)
    v = v.sort_values('avail')
    mg = pd.merge_asof(trig_t.sort_values('t'), v, left_on='t', right_on='avail', direction='backward')
    bear[:,k] = (mg['dif']<mg['dea']).values
    bull[:,k] = (mg['dif']>mg['dea']).values
vote_bear = bear.sum(axis=1); vote_bull = bull.sum(axis=1)
print(f"  投票成员 {NVOTE} 个; 平均死叉票 {vote_bear.mean():.1f}, 金叉票 {vote_bull.mean():.1f}")


def simulate(min_votes, exit_mode, trail=0.0, i0=1, i1=None):
    """exit_mode: 'FIXED' 或 'TRAIL'. 返回每笔pnl数组+方向."""
    if i1 is None: i1 = N
    pnls = []; dirs = []
    pos = None
    for i in range(i0, i1):
        if pos is not None:
            s, e = int(t_s[i]), int(t_e[i]); done=False; ep=0.0
            for mi in range(s, e):
                hi = m1_high[mi]; lo = m1_low[mi]
                if pos['dir'] == -1:   # 空: 高价不利, 低价有利
                    # 1) 硬止损(悲观: 先假设不利极值)
                    if hi >= pos['hardsl']: ep,done=pos['hardsl'],True; break
                    if exit_mode=='FIXED':
                        if lo <= pos['tp']: ep,done=pos['tp'],True; break
                    else:  # TRAIL
                        if pos['trail_on'] and hi >= pos['tstop']: ep,done=pos['tstop'],True; break
                        # 更新最优(用本bar低点), 再定trail (不在同bar回测触发)
                        if lo < pos['best']:
                            pos['best'] = lo
                            if (pos['entry'] - pos['best']) >= trail:
                                pos['trail_on'] = True
                            if pos['trail_on']:
                                pos['tstop'] = pos['best'] + trail
                else:                  # 多: 低价不利, 高价有利
                    if lo <= pos['hardsl']: ep,done=pos['hardsl'],True; break
                    if exit_mode=='FIXED':
                        if hi >= pos['tp']: ep,done=pos['tp'],True; break
                    else:
                        if pos['trail_on'] and lo <= pos['tstop']: ep,done=pos['tstop'],True; break
                        if hi > pos['best']:
                            pos['best'] = hi
                            if (pos['best'] - pos['entry']) >= trail:
                                pos['trail_on'] = True
                            if pos['trail_on']:
                                pos['tstop'] = pos['best'] - trail
            if done:
                pnls.append((ep-pos['entry'])*pos['dir']); dirs.append(pos['dir']); pos=None
        if pos is not None: continue
        s0 = int(sig[i-1])
        if s0==0: continue
        entry = float(t_open[i])
        if entry<=0: continue
        if s0==1 and int(vote_bear[i-1])>=min_votes:   # 金叉+高周期死叉→空(用已收bar[i-1])
            pos = dict(dir=-1, entry=entry, hardsl=entry+HARD_SL,
                       tp=entry-FIXED_TP, best=entry, trail_on=False, tstop=0.0)
        elif s0==-1 and int(vote_bull[i-1])>=min_votes: # 死叉+高周期金叉→多
            pos = dict(dir=1, entry=entry, hardsl=entry-HARD_SL,
                       tp=entry+FIXED_TP, best=entry, trail_on=False, tstop=0.0)
    if pos is not None:
        pnls.append((float(t_close[i1-1])-pos['entry'])*pos['dir']); dirs.append(pos['dir'])
    return np.array(pnls), np.array(dirs)


def stat(pnls, dirs, cost=0.0):
    if len(pnls)==0: return dict(n=0)
    net = pnls - cost
    wins = net[net>0]; loss = net[net<0]
    eq = np.concatenate([[0], np.cumsum(net)])
    dd = (eq - np.maximum.accumulate(eq)).min()
    pf = (wins.sum()/abs(loss.sum())) if len(loss) else float('inf')
    return dict(n=len(net), wr=len(wins)/len(net)*100, pf=pf, net=net.sum(), dd=dd,
                nshort=int((dirs==-1).sum()), nlong=int((dirs==1).sum()),
                avgw=wins.mean() if len(wins) else 0, avgl=loss.mean() if len(loss) else 0)


# 配置集合
CONFIGS = []
for mv in THRESHOLDS:
    CONFIGS.append((mv, 'FIXED', 0.0, f'FIXED SL10/TP15'))
    for tr in TRAIL_SET:
        CONFIGS.append((mv, 'TRAIL', tr, f'TRAIL{tr:.0f} (硬SL10)'))

print(f"跑 {len(CONFIGS)} 配置(全样本) ...")
rows = []
for mv, em, tr, label in CONFIGS:
    pn, dr = simulate(mv, em, tr)
    st = stat(pn, dr)
    st.update(mv=mv, exit=label, _pn=pn, _dr=dr, _em=em, _tr=tr)
    rows.append(st)
    pf = st.get('pf', 0)
    print(f"  {mv}/{NVOTE} {label}: {st['n']}笔 胜{st.get('wr',0):.1f}% PF{pf if np.isfinite(pf) else 9:.2f} 净${st.get('net',0):+.0f}")

# 样本外: 前60% train, 后40% test (按触发bar序号切)
isplit = int(1 + 0.6 * (N - 1))
split_date = t_times[isplit].date()

valid = [r for r in rows if r['n'] > 0]
for r in valid:
    r['rdd'] = r['net']/abs(r['dd']) if r['dd']!=0 else float('inf')
top = sorted(valid, key=lambda x: x['pf'] if np.isfinite(x['pf']) else 0, reverse=True)[:5]

print(f"\n样本外检验 (split @ {split_date}) ...")
oos = []
for r in top:
    pn_tr, dr_tr = simulate(r['mv'], r['_em'], r['_tr'], i0=1, i1=isplit)
    pn_te, dr_te = simulate(r['mv'], r['_em'], r['_tr'], i0=isplit, i1=N)
    oos.append((r, stat(pn_tr, dr_tr), stat(pn_te, dr_te)))


# ── 输出 ───────────────────────────────────────
def pfs(x):
    v=x.get('pf',0); return f"{v:.2f}" if np.isfinite(v) else "inf"

L = []
L.append("# 回光返照 v2 — 删RSI + 时间序列延到1D + 出场优化\n")
L.append(f"- 数据: {df.index.min().date()} ~ {df.index.max().date()}")
L.append(f"- 触发{TRIG}; 投票{NVOTE}个(几何×2到1D): {'/'.join(VOTES)}")
L.append(f"- 入场=确认; **无RSI**; 投票只取已收盘bar(无前视)")
L.append(f"- 硬止损${HARD_SL:.0f}; FIXED另有TP${FIXED_TP:.0f}; TRAIL为盈利后跟踪, 无固定TP")
L.append(f"- 平衡胜率(FIXED)= {HARD_SL/(HARD_SL+FIXED_TP)*100:.0f}%; **未计点差/滑点**")
L.append(f"- 平均每触发bar: 死叉票{vote_bear.mean():.1f}/金叉票{vote_bull.mean():.1f} (共{NVOTE})\n")

L.append("## 全样本结果 (按投票阈值×出场)\n")
L.append("| 投票 | 出场 | 交易 | 胜率 | PF | 净利$ | 回撤$ | 净利/回撤 | 空/多 | 均盈/均亏 |")
L.append("|------|------|------|------|-----|-------|-------|----------|-------|----------|")
for r in rows:
    if r['n']==0:
        L.append(f"| {r['mv']}/{NVOTE} | {r['exit']} | 0 | - | - | - | - | - | - | - |"); continue
    rdd = r['net']/abs(r['dd']) if r['dd']!=0 else float('inf')
    L.append(f"| {r['mv']}/{NVOTE} | {r['exit']} | {r['n']} | {r['wr']:.1f}% | {pfs(r)} | "
             f"{r['net']:+.0f} | {r['dd']:.0f} | {rdd:.1f} | {r['nshort']}/{r['nlong']} | "
             f"{r['avgw']:.1f}/{r['avgl']:.1f} |")

L.append(f"\n## 样本外检验 (前60%调→后40%验, split @ {split_date})\n")
L.append("**这是判断上面结果是真边际还是过拟合的关键。test 若崩，说明全样本最优是碰运气。**\n")
L.append("| 配置 | 全样本PF | 全样本净$ | train PF | train净$ | test PF | test净$ | 结论 |")
L.append("|------|---------|----------|---------|---------|---------|---------|------|")
for r, tr, te in oos:
    trpf = tr.get('pf',0); tepf = te.get('pf',0)
    trpfs = f"{trpf:.2f}" if np.isfinite(trpf) else "inf"
    tepfs = f"{tepf:.2f}" if np.isfinite(tepf) else "inf"
    verdict = "test仍>1 可继续" if (te.get('n',0)>0 and np.isfinite(tepf) and tepf>1.0) else "test崩→过拟合/失效"
    L.append(f"| {r['mv']}/{NVOTE} {r['exit']} | {pfs(r)} | {r['net']:+.0f} | "
             f"{trpfs} | {tr.get('net',0):+.0f} | {tepfs} | {te.get('net',0):+.0f} | {verdict} |")

L.append("\n## 要点")
# 自动判断延到1D的影响
L.append(f"- 投票成员已延到1D共{NVOTE}个; 平均金叉票({vote_bull.mean():.1f})远多于死叉票({vote_bear.mean():.1f}) "
         f"→ 牛市下高周期多数看多, 全票看空(开空)机会稀少, 投票天然偏向开多(fade跌)。")
best = max(valid, key=lambda x: x['pf'] if np.isfinite(x['pf']) else 0)
L.append(f"- 全样本PF最高: {best['mv']}/{NVOTE} {best['exit']} → PF={pfs(best)}, 净${best['net']:+.0f}, {best['n']}笔")
L.append(f"- 以上**未计点差/滑点**, 真实只会更低; 且192/384/768min非MT5原生周期, EA需M1合成。")

with open(OUT_MD, 'w', encoding='utf-8') as f:
    f.write('\n'.join(L) + '\n')
print(f"\n完成, 写入: {OUT_MD}")
