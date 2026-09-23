"""探测 Dukascopy datafeed 上 DXY/US10Y/WTI 品种的正确 URL 名."""
from __future__ import annotations

import socket
import requests

# Same DNS bypass as fetch_dukascopy
_DNS_OVERRIDE = {"datafeed.dukascopy.com": "194.8.15.180"}
_orig = socket.getaddrinfo
def _patched(host, *args, **kwargs):
    if host in _DNS_OVERRIDE:
        return _orig(_DNS_OVERRIDE[host], *args, **kwargs)
    return _orig(host, *args, **kwargs)
socket.getaddrinfo = _patched

URL_FMT = "https://datafeed.dukascopy.com/datafeed/{sym}/2025/00/15/BID_candles_min_1.bi5"

# 尝试各种可能的名字 (Dukascopy 官方 CFD 列表常见格式)
CANDIDATES = {
    "DXY / 美元指数": [
        "USDIDX",
        "USDX",
        "DXY",
        "USDINDEX",
        "USA30IDX",  # 美股指数, 顺便测
    ],
    "WTI 原油": [
        "USOIL",
        "LIGHTCMDUSD",
        "LIGHT.CMD_USD",
        "LIGHT.CMDUSD",
        "OILUSD",
        "WTIUSD",
        "USOilCash",
    ],
    "US 10 年国债收益": [
        "US10Y",
        "US10YR",
        "US10YUSD",
        "USTBOND",
        "US10YR.TR_USD",
        "US10Y.TR_USD",
    ],
    "EUR/USD (DXY 备胎)": ["EURUSD"],
    "美股 SPX (可选)": ["USA500IDX", "USA500IDXUSD", "SPXUSD", "SPX500"],
    "US 短债 (US2Y)": ["US2Y", "US2YR", "US2Y.TR_USD"],
    "布伦特原油": ["BRENTCMDUSD", "UKOIL", "BRENT.CMD_USD"],
}

sess = requests.Session()
sess.trust_env = False
sess.headers["User-Agent"] = "Mozilla/5.0"

for cat, names in CANDIDATES.items():
    print(f"\n== {cat} ==")
    for n in names:
        try:
            r = sess.get(URL_FMT.format(sym=n), timeout=15)
            print(f"  {n:<30} HTTP {r.status_code}  {len(r.content):>7} bytes")
        except Exception as e:
            print(f"  {n:<30} FAIL {type(e).__name__}: {str(e)[:60]}")
