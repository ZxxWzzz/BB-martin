#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
回光返照 — 阶梯复利模拟 (本金翻倍→手数翻倍)
策略: 净利王 合成 — 触发3min, 投票6/12/24/48/96, 确认, RSI关, 4/5票, SL10/TP17
规则: 起始 0.01 手; equity 相对起始本金每翻一倍, 手数翻一倍 (0.01→0.02→0.04...)
两种阶梯:
  ratchet (只涨不跌, 用户原话): 手数只随新高往上加, 回撤时不降
  symmetric (对称): equity 掉回下一级也把手数降回去 (自动刹车)
扫不同起始本金, 看终值 / 最大回撤% / 爆仓与否
成本: 每笔来回 $0.10/0.01手 (随手数线性放大)
"""
import sys
import pandas as pd
import numpy as np

try:
    sys.stdout.reconfigure(encoding='utf-8')
except Exception:
    pass

SRC    = r'D:\dev\martin-analysis\xau-breakout-guard\data\raw\xauusd_m1.parquet'
OUT_MD = r'D:\dev\martin-analysis\backtest_hgfz_compound.md'

MACD_FAST, MACD_SLOW, MACD_SIG = 12, 26, 9
RSI_PERIOD = 14
SL_USD, TP_USD = 10.0, 17.0
MIN_VOTES = 4
VOTES = ['6min', '12min', '24min', '48min', '96min']
TRIG = '3min'
COST_RT = 0.10          # 每笔来回成本 USD / 0.01手
USE_RSI = False
RSI_S_MIN, RSI_S_MAX = 50.0, 72.0
RSI_L_MIN, RSI_L_MAX = 28.0, 50.0

START_CAPS = [200, 300, 500, 1000, 2000, 3000, 5000]


def ema(s, n): return s.ewm(span=n, adjust=False).mean()
def calc_macd(c):
    dif = ema(c, MACD_FAST) - ema(c, MACD_SLOW); dea = ema(dif, MACD_SIG)
    return dif, dea, dif - dea
def calc_rsi(c, n=14):
    d = c.diff(); g = d.clip(lower=0); l = (-d).clip(lower=0)
    ag = g.ewm(com=n-1, adjust=False).mean(); al = l.ewm(com=n-1, adjust=False).mean()
    rs = ag/al.replace(0, np.nan); return 100 - 100/(1+rs)
def resample_tf(df, rule):
    r = df.resample(rule, closed='left', label='left').agg(
        open=('open','first'), high=('high','max'), low=('low','min'), close=('close','last')
    ).dropna(subset=['close']); r = r[r['close']>0]
    r['dif'], r['dea'], r['hist'] = calc_macd(r['close']); r['rsi'] = calc_rsi(r['close'], RSI_PERIOD)
    return r


print("加载 M1 + 生成成交序列 ...")
df = pd.read_parquet(SRC)
df['time'] = pd.to_datetime(df['time'], utc=True)
df = df.set_index('time').sort_index(); df = df[df['close']>0]
m1_high = df['high'].values; m1_low = df['low'].values
m1_ns = df.index.astype(np.int64).values

trig = resample_tf(df, TRIG); N = len(trig)
hist = trig['hist'].values; rsi = trig['rsi'].values
t_open = trig['open'].values; t_close = trig['close'].values
t_ns = trig.index.astype(np.int64).values
t_s = np.searchsorted(m1_ns, t_ns, side='left')
t_e = np.empty(N, dtype=np.int64); t_e[:-1] = t_s[1:]; t_e[-1] = len(df)

sig = np.zeros(N, dtype=np.int8)
sig[1:] = np.where((hist[1:]>0)&(hist[:-1]<=0), 1, np.where((hist[1:]<0)&(hist[:-1]>=0), -1, 0))

# 投票
trig_t = trig.index.to_frame(name='t').reset_index(drop=True)
bear = np.zeros((N, len(VOTES)), dtype=bool); bull = np.zeros((N, len(VOTES)), dtype=bool)
for k, rule in enumerate(VOTES):
    vdf = resample_tf(df, rule); v = vdf[['dif','dea']].reset_index(); v.columns=['tv','dif','dea']
    mg = pd.merge_asof(trig_t, v, left_on='t', right_on='tv', direction='backward')
    bear[:,k] = (mg['dif']<mg['dea']).values; bull[:,k] = (mg['dif']>mg['dea']).values
vb = bear.sum(axis=1); vl = bull.sum(axis=1)

# 生成每笔 gross pnl (per 0.01手) + 平仓时间
pnls = []
times = []     # 每笔平仓时间 (ISO字符串), 用于曲线 x 轴
t_index = trig.index
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
            pnls.append((ep-pos['entry'])*pos['dir'])
            times.append(t_index[i].strftime('%Y-%m-%d'))
            pos=None
    if pos is not None: continue
    s0 = int(sig[i-1])
    if s0==0: continue
    entry = float(t_open[i])
    if entry<=0: continue
    r0 = float(rsi[i-1])
    if s0==1 and int(vb[i-1])>=MIN_VOTES:
        if (not USE_RSI) or (RSI_S_MIN<=r0<=RSI_S_MAX):
            pos={'dir':-1,'entry':entry,'sl':entry+SL_USD,'tp':entry-TP_USD}
    elif s0==-1 and int(vl[i-1])>=MIN_VOTES:
        if (not USE_RSI) or (RSI_L_MIN<=r0<=RSI_L_MAX):
            pos={'dir':1,'entry':entry,'sl':entry-SL_USD,'tp':entry+TP_USD}
if pos is not None:
    pnls.append((float(t_close[-1])-pos['entry'])*pos['dir'])
    times.append(t_index[-1].strftime('%Y-%m-%d'))
pnls = np.array(pnls)
print(f"  {len(pnls)} 笔; 0.01手固定净利(扣${COST_RT})= ${(pnls-COST_RT).sum():+.0f}")


def simulate(start_cap, mode):
    """mode: 'ratchet' 只涨不跌 / 'symmetric' 对称
    返回统计 + 逐笔资金曲线 (equity) 和回撤曲线 (dd%)"""
    equity = float(start_cap)
    units = 1          # 0.01手为单位
    level = 0          # 当前已达的翻倍级 (ratchet 用)
    peak = equity; maxdd = 0.0; ruined = False
    curve = [round(equity, 2)]      # 含起点
    ddcurve = [0.0]
    for pu in pnls:
        pnl = pu * units - COST_RT * units
        equity += pnl
        if equity <= 0:
            ruined = True; equity = 0
            curve.append(0.0); ddcurve.append(100.0)
            break
        peak = max(peak, equity)
        dd = (peak - equity) / peak
        maxdd = max(maxdd, dd)
        curve.append(round(equity, 2))
        ddcurve.append(round(dd * 100, 2))
        tgt = int(np.floor(np.log2(equity / start_cap))) if equity > start_cap else 0
        tgt = max(tgt, 0)
        if mode == 'ratchet':
            if tgt > level: level = tgt
            use_level = level
        else:
            use_level = tgt
        units = 2 ** use_level
    return dict(mode=mode, start=start_cap, final=equity, ret=equity/start_cap,
                maxdd=maxdd*100, ruined=ruined, end_units=units,
                curve=curve, ddcurve=ddcurve)


print("跑复利模拟 ...")
rows = []
for mode in ['ratchet', 'symmetric']:
    for c in START_CAPS:
        rows.append(simulate(c, mode))

# ── 输出 ───────────────────────────────────────
lines = []
lines.append("# 回光返照 — 阶梯复利模拟 (本金翻倍→手数翻倍)\n")
lines.append(f"- 策略: 净利王合成 触发{TRIG}/投票{'/'.join(VOTES)}/确认/RSI关/{MIN_VOTES}/5票/SL{SL_USD:.0f}TP{TP_USD:.0f}")
lines.append(f"- 数据: {df.index.min().date()}~{df.index.max().date()} (单一黄金牛市 regime)")
lines.append(f"- {len(pnls)}笔, 胜率{(pnls>0).mean()*100:.1f}%, 每笔来回成本${COST_RT}/0.01手(随手数放大)")
lines.append(f"- 起始0.01手; equity每翻倍手数翻倍 (0.01→0.02→0.04→...)")
lines.append(f"- **单一regime+无尾部滑点, 真实回撤只会更深; 下为乐观地板**\n")

for mode, title in [('ratchet','## 只涨不跌 (你的原规则 — 回撤时不降手数)'),
                    ('symmetric','## 对称阶梯 (跌破一级自动降手数 = 自动刹车)')]:
    lines.append(title + "\n")
    lines.append("| 起始本金$ | 2年终值$ | 倍数 | 最大回撤% | 末端手数 | 结局 |")
    lines.append("|-----------|----------|------|----------|---------|------|")
    for r in rows:
        if r['mode'] != mode: continue
        lot = r['end_units'] * 0.01
        res = "**爆仓**" if r['ruined'] else "存活"
        lines.append(f"| {r['start']} | {r['final']:,.0f} | {r['ret']:.1f}× | "
                     f"{r['maxdd']:.1f}% | {lot:.2f} | {res} |")
    lines.append("")

with open(OUT_MD, 'w', encoding='utf-8') as f:
    f.write('\n'.join(lines) + '\n')
print(f"完成, 写入: {OUT_MD}")

# ── 导出 JSON 给网页 ───────────────────────────
import json
OUT_JSON = r'D:\dev\martin-analysis\hgfz_compound_data.json'
# x 轴: 起点日期 + 每笔平仓日期
x_labels = [times[0] if times else ''] + times
payload = {
    'meta': {
        'strategy': f'净利王合成 触发{TRIG}/投票{"/".join(VOTES)}/确认/RSI关/{MIN_VOTES}票5/SL{SL_USD:.0f}TP{TP_USD:.0f}',
        'period': f'{df.index.min().date()} ~ {df.index.max().date()}',
        'ntrade': len(pnls),
        'winrate': round((pnls > 0).mean() * 100, 1),
        'cost_rt': COST_RT,
        'regime': '单一黄金牛市 (金价 2577→4376)',
    },
    'x': x_labels,
    'series': [],
}
for r in rows:
    payload['series'].append({
        'mode': r['mode'],
        'start': r['start'],
        'final': round(r['final'], 2),
        'ret': round(r['ret'], 2),
        'maxdd': round(r['maxdd'], 1),
        'ruined': r['ruined'],
        'end_lot': round(r['end_units'] * 0.01, 2),
        'curve': r['curve'],
        'ddcurve': r['ddcurve'],
    })
with open(OUT_JSON, 'w', encoding='utf-8') as f:
    json.dump(payload, f, ensure_ascii=False)
print(f"JSON 写入: {OUT_JSON}  ({len(x_labels)} 点 × {len(rows)} 曲线)")
