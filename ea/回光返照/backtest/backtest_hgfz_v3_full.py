#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
回光返照 v3 — 全维度网格 + 真实成本 + 样本外排名
维度:
  1 序列: native(原生, 到D1) vs geo(几何×2, 到D1); 长度 4..9
  2a 票数: 每长度 L 从 L 扫到 ceil(L/2)
  2b 结构: 顶部3周期全一致 + 其余>=R (检验"大周期越该一致")
  3 出场: FIXED(SL10/TP15), TRAIL8, TRAIL10
  4 入场: 确认 / 抢
闸: 每组合算 税前$0 / 税后$0.10; 排名按样本外 test 段 PF; 多空分开.
无 RSI. 投票只取已收盘bar(无前视). 触发固定 3min.
"""
import sys, math, csv
import pandas as pd
import numpy as np
try:
    sys.stdout.reconfigure(encoding='utf-8')
except Exception:
    pass

SRC = r'D:\dev\martin-analysis\xau-breakout-guard\data\raw\xauusd_m1.parquet'
OUT_MD = r'D:\dev\martin-analysis\backtest_hgfz_v3_full.md'
OUT_CSV = r'D:\dev\martin-analysis\backtest_hgfz_v3_full.csv'

MACD_FAST, MACD_SLOW, MACD_SIG = 12, 26, 9
TRIG = '3min'
HARD_SL = 10.0
FIXED_TP = 15.0
COST = 0.10
OOS_FRAC = 0.60   # 前60% train, 后40% test

NATIVE = ['6min','12min','30min','60min','120min','240min','480min','720min','1440min']
GEO    = ['6min','12min','24min','48min','96min','192min','384min','768min','1440min']
EXITS  = [('FIXED',0.0),('TRAIL8',8.0),('TRAIL10',10.0)]
ENTRIES = ['确认','抢']
ANT_THR = 0.15


def ema(s,n): return s.ewm(span=n,adjust=False).mean()
def macd(c):
    dif=ema(c,MACD_FAST)-ema(c,MACD_SLOW); dea=ema(dif,MACD_SIG); return dif,dea
def rtf(df,rule):
    r=df.resample(rule,closed='left',label='left').agg(
        open=('open','first'),high=('high','max'),low=('low','min'),close=('close','last')
    ).dropna(subset=['close']); r=r[r['close']>0]
    d,e=macd(r['close']); r['dif']=d; r['dea']=e; return r


print("加载 M1 ...", flush=True)
df=pd.read_parquet(SRC)
df['time']=pd.to_datetime(df['time'],utc=True)
df=df.set_index('time').sort_index(); df=df[df['close']>0]
m1_high=df['high'].values; m1_low=df['low'].values
m1_ns=df.index.astype(np.int64).values
print(f"  {len(df):,} bars  {df.index.min().date()} ~ {df.index.max().date()}", flush=True)

trig=rtf(df,TRIG); N=len(trig)
hist=(trig['dif']-trig['dea']).values
t_open=trig['open'].values; t_close=trig['close'].values
t_ns=trig.index.astype(np.int64).values
t_s=np.searchsorted(m1_ns,t_ns,side='left')
t_e=np.empty(N,dtype=np.int64); t_e[:-1]=t_s[1:]; t_e[-1]=len(df)
sig_c=np.zeros(N,dtype=np.int8)
sig_c[1:]=np.where((hist[1:]>0)&(hist[:-1]<=0),1,np.where((hist[1:]<0)&(hist[:-1]>=0),-1,0))
sig_a=np.zeros(N,dtype=np.int8)
wb=(hist[1:]<0)&(hist[1:]>hist[:-1])&(np.abs(hist[1:])<=ANT_THR)
ws=(hist[1:]>0)&(hist[1:]<hist[:-1])&(np.abs(hist[1:])<=ANT_THR)
sig_a[1:]=np.where(wb,1,np.where(ws,-1,0))
isplit=int(1+OOS_FRAC*(N-1))
split_date=trig.index[isplit].date()

# 预算所有用到的投票周期 (已收盘对齐)
print("预算投票周期 ...", flush=True)
trig_t=trig.index.to_frame(name='t').reset_index(drop=True)
VOTE_BEAR={}; VOTE_BULL={}
for rule in sorted(set(NATIVE+GEO), key=lambda r:int(r.replace('min',''))):
    vdf=rtf(df,rule); v=vdf[['dif','dea']].reset_index(); v.columns=['tv','dif','dea']
    v['avail']=v['tv']+pd.Timedelta(rule); v=v.sort_values('avail')
    mg=pd.merge_asof(trig_t.sort_values('t'),v,left_on='t',right_on='avail',direction='backward')
    VOTE_BEAR[rule]=(mg['dif']<mg['dea']).values
    VOTE_BULL[rule]=(mg['dif']>mg['dea']).values


def simulate(short_ok, long_ok, entry_sig, exit_mode, trail):
    """返回 list[(entry_i, dir, pnl)]"""
    trades=[]; pos=None
    for i in range(1,N):
        if pos is not None:
            s,e=int(t_s[i]),int(t_e[i]); done=False; ep=0.0
            for mi in range(s,e):
                hi=m1_high[mi]; lo=m1_low[mi]
                if pos['dir']==-1:
                    if hi>=pos['hardsl']: ep,done=pos['hardsl'],True; break
                    if exit_mode=='FIXED':
                        if lo<=pos['tp']: ep,done=pos['tp'],True; break
                    else:
                        if pos['ton'] and hi>=pos['ts']: ep,done=pos['ts'],True; break
                        if lo<pos['best']:
                            pos['best']=lo
                            if (pos['entry']-pos['best'])>=trail: pos['ton']=True
                            if pos['ton']: pos['ts']=pos['best']+trail
                else:
                    if lo<=pos['hardsl']: ep,done=pos['hardsl'],True; break
                    if exit_mode=='FIXED':
                        if hi>=pos['tp']: ep,done=pos['tp'],True; break
                    else:
                        if pos['ton'] and lo<=pos['ts']: ep,done=pos['ts'],True; break
                        if hi>pos['best']:
                            pos['best']=hi
                            if (pos['best']-pos['entry'])>=trail: pos['ton']=True
                            if pos['ton']: pos['ts']=pos['best']-trail
            if done:
                trades.append((pos['i'],pos['dir'],(ep-pos['entry'])*pos['dir'])); pos=None
        if pos is not None: continue
        s0=int(entry_sig[i-1])
        if s0==0: continue
        entry=float(t_open[i])
        if entry<=0: continue
        if s0==1 and short_ok[i-1]:
            pos=dict(i=i,dir=-1,entry=entry,hardsl=entry+HARD_SL,tp=entry-FIXED_TP,best=entry,ton=False,ts=0.0)
        elif s0==-1 and long_ok[i-1]:
            pos=dict(i=i,dir=1,entry=entry,hardsl=entry-HARD_SL,tp=entry+FIXED_TP,best=entry,ton=False,ts=0.0)
    if pos is not None:
        trades.append((pos['i'],pos['dir'],(float(t_close[-1])-pos['entry'])*pos['dir']))
    return trades


def stat(trades, cost, lo=None, hi=None):
    if lo is not None:
        trades=[t for t in trades if lo<=t[0]<hi]
    if not trades: return dict(n=0)
    pnl=np.array([t[2] for t in trades])-cost
    dirs=np.array([t[1] for t in trades])
    w=pnl[pnl>0]; l=pnl[pnl<0]
    eq=np.concatenate([[0],np.cumsum(pnl)])
    dd=(eq-np.maximum.accumulate(eq)).min()
    pf=(w.sum()/abs(l.sum())) if len(l) else float('inf')
    return dict(n=len(pnl),wr=len(w)/len(pnl)*100,pf=pf,net=pnl.sum(),dd=dd,
                nshort=int((dirs==-1).sum()),nlong=int((dirs==1).sum()))


# 枚举投票配置
def flat_configs(members):
    L=len(members); out=[]
    bear=np.column_stack([VOTE_BEAR[m] for m in members])
    bull=np.column_stack([VOTE_BULL[m] for m in members])
    bc=bear.sum(1); lc=bull.sum(1)
    for thr in range(L, math.ceil(L/2)-1, -1):
        out.append((f'平铺{thr}/{L}', bc>=thr, lc>=thr))
    return out

def struct_configs(members):
    L=len(members)
    if L<6: return []
    out=[]
    bear=np.column_stack([VOTE_BEAR[m] for m in members])
    bull=np.column_stack([VOTE_BULL[m] for m in members])
    topidx=list(range(L-3,L))      # 最大的3个
    restidx=list(range(0,L-3))
    tb=bear[:,topidx].all(1); tl=bull[:,topidx].all(1)
    rb=bear[:,restidx].sum(1); rl=bull[:,restidx].sum(1)
    nr=len(restidx)
    for R in [nr, nr-1]:
        if R<0: continue
        out.append((f'顶3一致+余{R}/{nr}', tb&(rb>=R), tl&(rl>=R)))
    return out


print("开始跑网格 ...", flush=True)
results=[]
cnt=0
for sname, series in [('native',NATIVE),('geo',GEO)]:
    for L in range(4,10):
        members=series[:L]
        vote_cfgs=flat_configs(members)+struct_configs(members)
        for vlabel, s_ok, l_ok in vote_cfgs:
            for entry in ENTRIES:
                esig = sig_c if entry=='确认' else sig_a
                for exlabel, trail in EXITS:
                    trades=simulate(s_ok,l_ok,esig,exlabel,trail)
                    full0=stat(trades,0.0); full=stat(trades,COST)
                    tr=stat(trades,COST,1,isplit); te=stat(trades,COST,isplit,N)
                    cnt+=1
                    if full['n']==0: continue
                    results.append(dict(
                        series=sname,L=L,vote=vlabel,entry=entry,exit=exlabel,
                        n=full['n'],
                        pf0=full0.get('pf',0),net0=full0.get('net',0),
                        pf=full.get('pf',0),net=full.get('net',0),wr=full.get('wr',0),
                        dd=full.get('dd',0),nshort=full.get('nshort',0),nlong=full.get('nlong',0),
                        tr_pf=tr.get('pf',0),tr_net=tr.get('net',0),tr_n=tr.get('n',0),
                        te_pf=te.get('pf',0),te_net=te.get('net',0),te_n=te.get('n',0),
                    ))
                    if cnt%40==0: print(f"  ...{cnt} 组", flush=True)

print(f"共 {cnt} 组合, {len(results)} 有效", flush=True)

def finite(x): return x if (x is not None and np.isfinite(x)) else 0.0
# 排名: 按样本外 test PF (税后), 要求 test 有足够笔数
ranked=[r for r in results if r['te_n']>=30]
ranked.sort(key=lambda r:(finite(r['te_pf']), r['te_net']), reverse=True)

def pf(x):
    v=x; return f"{v:.2f}" if (v and np.isfinite(v)) else ("inf" if v==float('inf') else "-")

# CSV 全量
with open(OUT_CSV,'w',newline='',encoding='utf-8-sig') as f:
    w=csv.DictWriter(f,fieldnames=list(results[0].keys())); w.writeheader()
    for r in sorted(results,key=lambda r:finite(r['te_pf']),reverse=True): w.writerow(r)

L=[]
L.append("# 回光返照 v3 — 全维度网格 (真实成本 + 样本外排名)\n")
L.append(f"- 数据: {df.index.min().date()} ~ {df.index.max().date()}; 触发{TRIG}; 无RSI; 投票取已收盘bar")
L.append(f"- 硬止损${HARD_SL:.0f}; FIXED止盈${FIXED_TP:.0f}; 成本税后=${COST}/笔; 平衡胜率(FIXED)=40%")
L.append(f"- 样本外: 前{OOS_FRAC*100:.0f}%train / 后{100-OOS_FRAC*100:.0f}%test, split@{split_date}")
L.append(f"- 共跑 {cnt} 组合; **排名按样本外test段税后PF** (test≥30笔)")
L.append(f"- 多重比较警告: 组合越多, 靠运气蹦出的高PF越多; 只认全/train/test一致的\n")

L.append("## TOP20 — 按样本外 test 段税后 PF 排名\n")
L.append("| 序列 | 长度 | 投票 | 入场 | 出场 | 总笔 | 全样本PF | 全净$ | train PF | test PF | test净$ | 空/多 |")
L.append("|------|------|------|------|------|------|---------|-------|---------|---------|---------|-------|")
for r in ranked[:20]:
    L.append(f"| {r['series']} | {r['L']} | {r['vote']} | {r['entry']} | {r['exit']} | {r['n']} | "
             f"{pf(r['pf'])} | {r['net']:+.0f} | {pf(r['tr_pf'])} | {pf(r['te_pf'])} | {r['te_net']:+.0f} | "
             f"{r['nshort']}/{r['nlong']} |")

# 结构 vs 平铺 (同序列/长度/入场/出场下, 看结构化是否更优)
L.append("\n## 你的假设检验: 顶部一致(结构) vs 平铺(票数)\n")
L.append("取两者各自样本外test-PF最优代表对比:\n")
struct_best=[r for r in ranked if '顶3' in r['vote']]
flat_best=[r for r in ranked if '平铺' in r['vote']]
L.append("| 类型 | 代表配置 | 全样本PF | test PF | test净$ | 笔数 |")
L.append("|------|---------|---------|---------|---------|------|")
if struct_best:
    r=struct_best[0]; L.append(f"| 结构(顶部一致) | {r['series']} L{r['L']} {r['vote']} {r['entry']} {r['exit']} | {pf(r['pf'])} | {pf(r['te_pf'])} | {r['te_net']:+.0f} | {r['n']} |")
if flat_best:
    r=flat_best[0]; L.append(f"| 平铺(票数) | {r['series']} L{r['L']} {r['vote']} {r['entry']} {r['exit']} | {pf(r['pf'])} | {pf(r['te_pf'])} | {r['te_net']:+.0f} | {r['n']} |")

# native vs geo
L.append("\n## native(原生) vs geo(几何) — 各自test-PF最优\n")
L.append("| 序列 | 代表配置 | 全样本PF | test PF | test净$ | 笔数 |")
L.append("|------|---------|---------|---------|---------|------|")
for sn in ['native','geo']:
    cand=[r for r in ranked if r['series']==sn]
    if cand:
        r=cand[0]; L.append(f"| {sn} | L{r['L']} {r['vote']} {r['entry']} {r['exit']} | {pf(r['pf'])} | {pf(r['te_pf'])} | {r['te_net']:+.0f} | {r['n']} |")

# 过拟合体检: 全样本TOP5 在 test 的表现
L.append("\n## 过拟合体检: 全样本PF-TOP5 在样本外是否仍成立\n")
byfull=sorted([r for r in results if r['n']>=50], key=lambda r:finite(r['pf']), reverse=True)[:5]
L.append("| 配置 | 全样本PF | train PF | test PF | 判定 |")
L.append("|------|---------|---------|---------|------|")
for r in byfull:
    verdict="真(test仍>1)" if finite(r['te_pf'])>1.0 else "疑似过拟合(test崩)"
    L.append(f"| {r['series']} L{r['L']} {r['vote']} {r['entry']} {r['exit']} | {pf(r['pf'])} | {pf(r['tr_pf'])} | {pf(r['te_pf'])} | {verdict} |")

L.append(f"\n## 要点")
if ranked:
    b=ranked[0]
    L.append(f"- 样本外最优: {b['series']} L{b['L']} {b['vote']} {b['entry']} {b['exit']} → "
             f"test PF {pf(b['te_pf'])}(税后), 全样本PF {pf(b['pf'])}, {b['n']}笔")
L.append(f"- 以上税后已扣$0.10/笔, 但**未含止损滑穿(尾部)**; 真实再低一档")
L.append(f"- geo 序列的 24/48/96/192/384/768min 非MT5原生, EA需M1合成; native 可直接iMACD")
L.append(f"- 全量明细见 CSV: {OUT_CSV}")

with open(OUT_MD,'w',encoding='utf-8') as f:
    f.write('\n'.join(L)+'\n')
print(f"完成, 写入: {OUT_MD}", flush=True)
print(f"CSV: {OUT_CSV}", flush=True)
