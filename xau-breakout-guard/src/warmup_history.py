"""触发 MT5 终端从服务器下载 XAUUSD.ct 两年 M1 历史数据.

MT5 是按需下载: 只要请求对应时间段的 rates, 终端就会向服务器索取.
第一次请求可能返回空/少量, 需要等一会儿再请求.

策略:
    从最老日期开始, 每周分片请求, 若空则等 2 秒后重试, 最多重试 5 次.
    重试过程中终端会在后台悄悄下载, 逐步补齐本地缓存.

用法: python warmup_history.py
    跑完后再跑 python fetch_mt5.py 就能拿到完整数据.
"""
from __future__ import annotations

import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

import yaml

try:
    import MetaTrader5 as mt5
except ImportError:
    sys.exit("需要 MetaTrader5: pip install MetaTrader5")

HERE = Path(__file__).parent
CFG = yaml.safe_load((HERE / "config.yaml").open("r", encoding="utf-8"))

SYMBOL = CFG["symbol"]
YEARS = CFG["fetch"]["years_back"]


def main():
    if not mt5.initialize():
        sys.exit(f"MT5 init fail: {mt5.last_error()}")
    if not mt5.symbol_select(SYMBOL, True):
        sys.exit(f"symbol {SYMBOL} not selectable")

    end = datetime.now(timezone.utc)
    start = end - timedelta(days=int(365.25 * YEARS) + 5)

    print(f"[warmup] {SYMBOL} {start.date()} -> {end.date()} 按周分片, 每片最多重试 5 次")

    cur = start
    week = 0
    ok_weeks = 0
    while cur < end:
        nxt = min(cur + timedelta(days=7), end)
        week += 1
        got = 0
        for attempt in range(5):
            rates = mt5.copy_rates_range(SYMBOL, mt5.TIMEFRAME_M1, cur, nxt)
            n = 0 if rates is None else len(rates)
            if n > 100:  # 一周内至少 100 根 bar 才算真的下到了
                got = n
                break
            time.sleep(2)  # 让终端在后台下载
        status = "OK" if got > 100 else "MISS"
        if got > 100:
            ok_weeks += 1
        print(f"  W{week:03d} {cur.date()} - {nxt.date()}  [{status}] {got:>6} bars", flush=True)
        cur = nxt

    print(f"\n[warmup] 完成: {ok_weeks}/{week} 周成功下载")
    print(f"[next] 现在跑: python fetch_mt5.py")
    mt5.shutdown()


if __name__ == "__main__":
    main()
