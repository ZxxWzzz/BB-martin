"""从 Dukascopy 免费下载 XAUUSD M1 历史数据 (最长可追溯到 2003).

原理:
    Dukascopy 每日一个 .bi5 文件 (LZMA 压缩), 每条记录 24 字节 BE:
        u32 秒偏移 (自当日 00:00 UTC), u32 open, u32 close, u32 low, u32 high, float32 volume
    XAUUSD 价格 scale = 1000 (保留 3 位小数)

用法:
    python fetch_dukascopy.py                       # 用 config.yaml 里的 years_back
    python fetch_dukascopy.py --years 2
    python fetch_dukascopy.py --start 2024-09-01 --end 2026-09-20
"""
from __future__ import annotations

import argparse
import lzma
import socket
import struct
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

import numpy as np
import pandas as pd
import requests
import yaml

# ==== 绕过 DNS 污染: 强制 datafeed.dukascopy.com 解析到真实 IP ====
# 国内本地 DNS 常把它污染到 Akamai 死节点 (108.x.x.x).
# 真实 IP 来自 Google DNS: nslookup datafeed.dukascopy.com 8.8.8.8
_DNS_OVERRIDE = {
    "datafeed.dukascopy.com": "194.8.15.180",
}
_orig_getaddrinfo = socket.getaddrinfo
def _patched_getaddrinfo(host, *args, **kwargs):
    if host in _DNS_OVERRIDE:
        real_ip = _DNS_OVERRIDE[host]
        return _orig_getaddrinfo(real_ip, *args, **kwargs)
    return _orig_getaddrinfo(host, *args, **kwargs)
socket.getaddrinfo = _patched_getaddrinfo

HERE = Path(__file__).parent
CFG = yaml.safe_load((HERE / "config.yaml").open("r", encoding="utf-8"))

DUKA_URL = "https://datafeed.dukascopy.com/datafeed/{sym}/{y:04d}/{m:02d}/{d:02d}/BID_candles_min_1.bi5"
XAUUSD_SCALE = 1000.0     # XAU 价格 3 位小数, 需要 / 1000
STRUCT_FMT = ">IIIIIf"    # 24 字节: 5 * uint32 + 1 * float32
RECORD_SIZE = 24

SESSION = requests.Session()
SESSION.headers.update({"User-Agent": "Mozilla/5.0 (compatible; XauGuard/1.0)"})
# 忽略系统代理 (HTTPS_PROXY 环境变量), 因为已经用 DNS override 直连
SESSION.trust_env = False


def fetch_day(sym: str, d: date, retries: int = 3) -> pd.DataFrame:
    """拉一天的 M1 candles, 返回 DataFrame(time, open, high, low, close, volume) UTC.
    周末通常无数据, 返回空 DataFrame.
    """
    # Dukascopy 月份是 0-indexed
    url = DUKA_URL.format(sym=sym, y=d.year, m=d.month - 1, d=d.day)
    for attempt in range(retries):
        try:
            r = SESSION.get(url, timeout=30)
            if r.status_code == 404:
                return pd.DataFrame()
            r.raise_for_status()
            data = r.content
            break
        except Exception as e:
            if attempt == retries - 1:
                print(f"  ! {d} 拉取失败: {e}")
                return pd.DataFrame()
            time.sleep(1.5 * (attempt + 1))
    if not data:
        return pd.DataFrame()

    try:
        raw = lzma.decompress(data)
    except lzma.LZMAError:
        return pd.DataFrame()

    n = len(raw) // RECORD_SIZE
    if n == 0:
        return pd.DataFrame()

    # 批量 unpack
    arr = np.frombuffer(raw[: n * RECORD_SIZE], dtype=np.dtype(">u4,>u4,>u4,>u4,>u4,>f4"))
    sec = arr["f0"].astype(np.int64)
    op = arr["f1"] / XAUUSD_SCALE
    cl = arr["f2"] / XAUUSD_SCALE
    lo = arr["f3"] / XAUUSD_SCALE
    hi = arr["f4"] / XAUUSD_SCALE
    vol = arr["f5"]

    day_start = datetime(d.year, d.month, d.day, tzinfo=timezone.utc)
    times = pd.to_datetime(day_start.timestamp() + sec, unit="s", utc=True)

    df = pd.DataFrame({
        "time": times,
        "open": op,
        "high": hi,
        "low": lo,
        "close": cl,
        "volume": vol,
        "spread": 0,  # Dukascopy 不带 spread, 后续填 0 占位
    })
    return df


def daterange(start: date, end: date):
    d = start
    while d <= end:
        yield d
        d += timedelta(days=1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--years", type=float, default=None)
    ap.add_argument("--start", type=str, default=None, help="YYYY-MM-DD")
    ap.add_argument("--end", type=str, default=None)
    ap.add_argument("--symbol", type=str, default="XAUUSD")
    ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--out", type=str, default=None)
    args = ap.parse_args()

    if args.start and args.end:
        start = date.fromisoformat(args.start)
        end = date.fromisoformat(args.end)
    else:
        yrs = args.years or CFG["fetch"]["years_back"]
        end = datetime.now(timezone.utc).date()
        start = end - timedelta(days=int(365.25 * yrs) + 5)

    print(f"[duka] {args.symbol} {start} -> {end}  ({(end-start).days} days, workers={args.workers})")

    all_days = [d for d in daterange(start, end) if d.weekday() < 5 or d.weekday() == 6]
    # 周日 (weekday=6) 可能有开盘数据 (亚洲盘), 周六 (5) 一般无

    frames = []
    ok = miss = 0
    t0 = time.time()
    with ThreadPoolExecutor(max_workers=args.workers) as ex:
        futs = {ex.submit(fetch_day, args.symbol, d): d for d in all_days}
        done = 0
        for fut in as_completed(futs):
            d = futs[fut]
            df = fut.result()
            done += 1
            if len(df):
                frames.append(df)
                ok += 1
            else:
                miss += 1
            if done % 50 == 0 or done == len(all_days):
                elapsed = time.time() - t0
                rate = done / elapsed
                eta = (len(all_days) - done) / rate if rate else 0
                print(f"  progress {done}/{len(all_days)}  ok={ok} miss={miss}  {rate:.1f}/s  ETA {eta:.0f}s", flush=True)

    if not frames:
        raise SystemExit("一条数据都没拉到, 检查网络或 URL")

    df = pd.concat(frames, ignore_index=True)
    df = df.sort_values("time").drop_duplicates("time").reset_index(drop=True)
    print(f"[duka] total rows={len(df):,} first={df['time'].iloc[0]} last={df['time'].iloc[-1]}")

    out = Path(args.out) if args.out else (HERE / CFG["fetch"]["raw_path"]).resolve()
    out.parent.mkdir(parents=True, exist_ok=True)
    df.to_parquet(out, index=False)
    print(f"[save] {out}  ({out.stat().st_size / 1024 / 1024:.1f} MB)")


if __name__ == "__main__":
    main()
