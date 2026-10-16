#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
回光返照 — 成本敏感度扫描
数据 spread 列全为 0, 无法取真实点差 → 用用户实盘经验建模:
  XAU 3位小数报价, 1pt=0.001; 常态滑点~35pt≈$0.035/oz(单边)
成本按"每笔来回总摩擦 cost_rt (USD/oz)"扣, 扫 6 档覆盖乐观→悲观。
把两份结果文件里的关键候选策略各自跑一遍成本扫描, 看谁扛得住真实成本。
"""
import sys
import pandas as pd
import numpy as np

try:
    sys.stdout.reconfigure(encoding='utf-8')
except Exception:
    pass

SRC    = r'D:\dev\martin-analysis\xau-breakout-guard\data\raw\xauusd_m1.parquet'
OUT_MD = r'D:\dev\martin-analysis\backtest_hgfz_cost.md'

MACD_FAST, MACD_SLOW, MACD_SIG = 12, 26, 9
RSI_PERIOD = 14
SL_USD = 10.0
ANT_THR = 0.15
RSI_S_MIN, RSI_S_MAX = 50.0, 72.0
RSI_L_MIN, RSI_L_MAX = 28.0, 50.0

COST_LEVELS = [0.00, 0.05, 0.10, 0.15, 0.20, 0.30, 0.50]   # 每笔来回 USD/oz


def ema(s, n):
    return s.ewm(span=n, adjust=False).mean()

def calc_macd(close):
    dif = ema(close, MACD_FAST) - ema(close, MACD_SLOW)
    dea = ema(dif, MACD_SIG)
    return dif, dea, dif - dea

def calc_rsi(close, n=14):
    d = close.diff()
    g = d.clip(lower=0); l = (-d).clip(lower=0)
    ag = g.ewm(com=n - 1, adjust=False).mean()
    al = l.ewm(com=n - 1, adjust=False).mean()
    rs = ag / al.replace(0, np.nan)
    return 100 - 100 / (1 + rs)

def resample_tf(df, rule):
    r = df.resample(rule, closed='left', label='left').agg(
        open=('open', 'first'), high=('high', 'max'),
        low=('low', 'min'), close=('close', 'last')).dropna(subset=['close'])
    r = r[r['close'] > 0]
    r['dif'], r['dea'], r['hist'] = calc_macd(r['close'])
    r['rsi'] = calc_rsi(r['close'], RSI_PERIOD)
    return r


print("加载 M1 ...")
df = pd.read_parquet(SRC)
df['time'] = pd.to_datetime(df['time'], utc=True)
df = df.set_index('time').sort_index()
df = df[df['close'] > 0]
m1_high = df['high'].values
m1_low  = df['low'].values
m1_ns   = df.index.astype(np.int64).values

# 缓存各触发周期的信号与 M1 映射
_trig_cache = {}
def get_trig(rule):
    if rule in _trig_cache:
        return _trig_cache[rule]
    tr = resample_tf(df, rule)
    N = len(tr)
    hist = tr['hist'].values
    sig_c = np.zeros(N, dtype=np.int8)
    sig_c[1:] = np.where((hist[1:] > 0) & (hist[:-1] <= 0), 1,
                np.where((hist[1:] < 0) & (hist[:-1] >= 0), -1, 0))
    sig_a = np.zeros(N, dtype=np.int8)
    wb = (hist[1:] < 0) & (hist[1:] > hist[:-1]) & (np.abs(hist[1:]) <= ANT_THR)
    ws = (hist[1:] > 0) & (hist[1:] < hist[:-1]) & (np.abs(hist[1:]) <= ANT_THR)
    sig_a[1:] = np.where(wb, 1, np.where(ws, -1, 0))
    ns = tr.index.astype(np.int64).values
    s = np.searchsorted(m1_ns, ns, side='left')
    e = np.empty(N, dtype=np.int64); e[:-1] = s[1:]; e[-1] = len(df)
    out = dict(tr=tr, N=N, rsi=tr['rsi'].values, t_open=tr['open'].values,
               t_close=tr['close'].values, sig_c=sig_c, sig_a=sig_a, s=s, e=e)
    _trig_cache[rule] = out
    return out

_vote_cache = {}
def get_votes(trig_rule, vote_rules):
    key = (trig_rule, tuple(vote_rules))
    if key in _vote_cache:
        return _vote_cache[key]
    T = get_trig(trig_rule)
    trig_t = T['tr'].index.to_frame(name='t').reset_index(drop=True)
    bear = np.zeros((T['N'], len(vote_rules)), dtype=bool)
    bull = np.zeros((T['N'], len(vote_rules)), dtype=bool)
    for k, rule in enumerate(vote_rules):
        vdf = resample_tf(df, rule)
        v = vdf[['dif', 'dea']].reset_index(); v.columns = ['tv', 'dif', 'dea']
        mg = pd.merge_asof(trig_t, v, left_on='t', right_on='tv', direction='backward')
        bear[:, k] = (mg['dif'] < mg['dea']).values
        bull[:, k] = (mg['dif'] > mg['dea']).values
    out = (bear.sum(axis=1), bull.sum(axis=1))
    _vote_cache[key] = out
    return out


def run(trig_rule, vote_rules, mode, use_rsi, min_votes, tp_usd):
    """返回每笔 gross pnl 列表 (未扣成本) + 方向"""
    T = get_trig(trig_rule)
    vb, vl = get_votes(trig_rule, vote_rules)
    sig = T['sig_c'] if mode == '确认' else T['sig_a']
    N, rsi = T['N'], T['rsi']
    t_open, t_close = T['t_open'], T['t_close']
    s_arr, e_arr = T['s'], T['e']
    pnls = []
    pos = None
    for i in range(1, N):
        if pos is not None:
            s, e = int(s_arr[i]), int(e_arr[i])
            done = False; ep = 0.0
            for mi in range(s, e):
                if pos['dir'] == 1:
                    if m1_high[mi] >= pos['tp']: ep, done = pos['tp'], True; break
                    if m1_low[mi]  <= pos['sl']: ep, done = pos['sl'], True; break
                else:
                    if m1_low[mi]  <= pos['tp']: ep, done = pos['tp'], True; break
                    if m1_high[mi] >= pos['sl']: ep, done = pos['sl'], True; break
            if done:
                pnls.append((ep - pos['entry']) * pos['dir'])
                pos = None
        if pos is not None:
            continue
        s0 = int(sig[i - 1])
        if s0 == 0: continue
        entry = float(t_open[i])
        if entry <= 0: continue
        r0 = float(rsi[i - 1])
        if s0 == 1 and int(vb[i - 1]) >= min_votes:
            if (not use_rsi) or (RSI_S_MIN <= r0 <= RSI_S_MAX):
                pos = {'dir': -1, 'entry': entry, 'sl': entry + SL_USD, 'tp': entry - tp_usd}
        elif s0 == -1 and int(vl[i - 1]) >= min_votes:
            if (not use_rsi) or (RSI_L_MIN <= r0 <= RSI_L_MAX):
                pos = {'dir': 1, 'entry': entry, 'sl': entry - SL_USD, 'tp': entry + tp_usd}
    if pos is not None:
        pnls.append((float(t_close[-1]) - pos['entry']) * pos['dir'])
    return np.array(pnls)


def stats_with_cost(gross, cost_rt):
    if len(gross) == 0:
        return None
    net = gross - cost_rt   # 每笔扣来回成本
    wins = net[net > 0]; loss = net[net < 0]
    eq = np.concatenate([[0], np.cumsum(net)])
    dd = (eq - np.maximum.accumulate(eq)).min()
    pf = (wins.sum() / abs(loss.sum())) if len(loss) else float('inf')
    return dict(n=len(net), wr=len(wins)/len(net)*100, pf=pf,
                net=net.sum(), dd=dd)


# ── 候选策略 (两份文件里的关键角色) ──────────────
SYN_VOTES = ['6min', '12min', '24min', '48min', '96min']   # tpsweep 合成序列
NAT4 = ['10min', '30min', '60min', '120min']               # classic A
NAT5 = ['10min', '30min', '60min', '120min', '240min']     # classic B

CANDIDATES = [
    # 标签, 触发, 投票组, 入场, RSI, 阈值, TP
    ("合成/净利王 TP17 确认 关RSI 4/5", '3min', SYN_VOTES, '确认', False, 4, 17.0),
    ("合成/稳健 TP15 确认 开RSI 5/5",   '3min', SYN_VOTES, '确认', True,  5, 15.0),
    ("原生A/稳健王 确认 开RSI 4/4",     '5min', NAT4, '确认', True,  4, 15.0),
    ("原生A/高净利 确认 关RSI 4/4",     '5min', NAT4, '确认', False, 4, 15.0),
    ("原生A/高频 确认 关RSI 3/4",       '5min', NAT4, '确认', False, 3, 15.0),
    ("原生B/高PF 确认 开RSI 5/5",       '5min', NAT5, '确认', True,  5, 15.0),
    ("原生B/高净利 确认 关RSI 4/5",     '5min', NAT5, '确认', False, 4, 15.0),
]

print("跑候选 × 成本档 ...")
results = []
for label, trig, votes, mode, rsi_on, mv, tp in CANDIDATES:
    print(f"  {label} ...")
    gross = run(trig, votes, mode, rsi_on, mv, tp)
    row = {'label': label, 'ntrade': len(gross)}
    for c in COST_LEVELS:
        st = stats_with_cost(gross, c)
        row[c] = st
    results.append(row)

# ── 写 markdown ────────────────────────────────
lines = []
lines.append("# 回光返照 — 真实成本敏感度扫描\n")
lines.append(f"- 数据: XAUUSD M1 {df.index.min().date()} ~ {df.index.max().date()} ({len(df):,} bars)")
lines.append("- **数据 spread 列全为 0, 无真实点差** → 按用户实盘经验建模")
lines.append("- XAU 3位小数, 1pt=0.001; 常态滑点~35pt≈$0.035/oz(单边); 点差~20-40pt")
lines.append("- 成本=每笔**来回**总摩擦(进场跨点差+进场滑点+止损滑点), 从每笔盈亏里扣")
lines.append("- 现实区间估计 **$0.08~0.15/笔**; 下表扫 $0.00~0.50 覆盖乐观→悲观")
lines.append("- SL=$10 固定, 手数0.01=1oz, 净利/回撤为2年累计\n")

# 净利矩阵
lines.append("## 净利$ 矩阵 (行=策略, 列=每笔来回成本)\n")
hdr = "| 策略 | 笔数 | " + " | ".join(f"${c:.2f}" for c in COST_LEVELS) + " |"
sep = "|------|------|" + "|".join("------" for _ in COST_LEVELS) + "|"
lines.append(hdr); lines.append(sep)
for r in results:
    cells = []
    for c in COST_LEVELS:
        st = r[c]
        cells.append(f"{st['net']:+.0f}" if st else "-")
    lines.append(f"| {r['label']} | {r['ntrade']} | " + " | ".join(cells) + " |")

# 胜率/PF 在现实档位 ($0.10) 的快照
lines.append("\n## 现实档位快照 (每笔来回 $0.10)\n")
lines.append("| 策略 | 笔数 | 胜率 | 利润因子 | 净利$ | 回撤$ | 净利/回撤 |")
lines.append("|------|------|------|---------|-------|-------|----------|")
for r in results:
    st = r[0.10]
    if not st:
        lines.append(f"| {r['label']} | {r['ntrade']} | - | - | - | - | - |"); continue
    pf = f"{st['pf']:.2f}" if np.isfinite(st['pf']) else "inf"
    rdd = (st['net']/abs(st['dd'])) if st['dd'] != 0 else float('inf')
    rdds = f"{rdd:.1f}" if np.isfinite(rdd) else "inf"
    lines.append(f"| {r['label']} | {st['n']} | {st['wr']:.1f}% | {pf} | "
                 f"{st['net']:+.0f} | {st['dd']:.0f} | {rdds} |")

# 盈亏翻负临界点
lines.append("\n## 成本临界点 (净利跌到 ≤0 的第一档)\n")
for r in results:
    breakpt = None
    for c in COST_LEVELS:
        st = r[c]
        if st and st['net'] <= 0:
            breakpt = c; break
    bp = f"${breakpt:.2f}" if breakpt is not None else ">$0.50 (全程为正)"
    lines.append(f"- **{r['label']}** ({r['ntrade']}笔): 翻负临界 = {bp}")

with open(OUT_MD, 'w', encoding='utf-8') as f:
    f.write('\n'.join(lines) + '\n')
print(f"\n完成, 结果写入: {OUT_MD}")
