"""从本地 MT5 终端拉取 XAUUSD M1 历史数据。

用法:
    python fetch_mt5.py                     # 使用 config.yaml 默认参数
    python fetch_mt5.py --years 3           # 覆盖回溯年数
    python fetch_mt5.py --terminal "C:\\...\\terminal64.exe"  # 指定终端

依赖: MetaTrader5, pandas, pyarrow, pyyaml
    pip install MetaTrader5 pandas pyarrow pyyaml
"""
from __future__ import annotations

import argparse
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pandas as pd
import yaml

try:
    import MetaTrader5 as mt5
except ImportError:
    sys.exit("需要安装 MetaTrader5: pip install MetaTrader5")


HERE = Path(__file__).parent
CFG_PATH = HERE / "config.yaml"


def load_cfg() -> dict:
    with CFG_PATH.open("r", encoding="utf-8") as f:
        return yaml.safe_load(f)


def init_mt5(terminal_path: str | None) -> None:
    kwargs = {}
    if terminal_path:
        kwargs["path"] = terminal_path
    if not mt5.initialize(**kwargs):
        code, msg = mt5.last_error()
        sys.exit(f"MT5 初始化失败 [{code}] {msg} — 请确认 BB 终端已登录并允许 API 访问")
    info = mt5.terminal_info()
    acc = mt5.account_info()
    print(f"[MT5] terminal: {info.name} @ {info.company}")
    if acc:
        print(f"[MT5] account: {acc.login} broker={acc.company} server={acc.server}")


def fetch_m1(symbol: str, years_back: int) -> pd.DataFrame:
    if not mt5.symbol_select(symbol, True):
        sys.exit(f"品种 {symbol} 不可用")

    end = datetime.now(timezone.utc)
    start = end - timedelta(days=int(365.25 * years_back) + 5)

    print(f"[fetch] {symbol} M1 {start.date()} -> {end.date()}  (按 30 天分片)")

    frames = []
    chunk_days = 30
    cur = start
    while cur < end:
        nxt = min(cur + timedelta(days=chunk_days), end)
        rates = mt5.copy_rates_range(symbol, mt5.TIMEFRAME_M1, cur, nxt)
        if rates is None:
            code, msg = mt5.last_error()
            print(f"  [{cur.date()} - {nxt.date()}] 跳过 [{code}] {msg}")
        elif len(rates) == 0:
            print(f"  [{cur.date()} - {nxt.date()}] 空")
        else:
            frames.append(pd.DataFrame(rates))
            print(f"  [{cur.date()} - {nxt.date()}] {len(rates):,} bars")
        cur = nxt

    if not frames:
        sys.exit("所有分片都拉失败, 检查终端历史数据设置 (工具→选项→图表→图表中最大柱数)")

    df = pd.concat(frames, ignore_index=True)
    df["time"] = pd.to_datetime(df["time"], unit="s", utc=True)
    df = df.rename(columns={"tick_volume": "volume"})
    df = df[["time", "open", "high", "low", "close", "volume", "spread"]]
    df = df.sort_values("time").drop_duplicates("time").reset_index(drop=True)
    print(f"[fetch] total rows={len(df):,} first={df['time'].iloc[0]} last={df['time'].iloc[-1]}")
    return df


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--years", type=int, default=None)
    ap.add_argument("--terminal", type=str, default=None, help="MT5 terminal64.exe 路径")
    ap.add_argument("--symbol", type=str, default=None)
    args = ap.parse_args()

    cfg = load_cfg()
    symbol = args.symbol or cfg["symbol"]
    years = args.years or cfg["fetch"]["years_back"]

    init_mt5(args.terminal)
    try:
        df = fetch_m1(symbol, years)
    finally:
        mt5.shutdown()

    out = (HERE / cfg["fetch"]["raw_path"]).resolve()
    out.parent.mkdir(parents=True, exist_ok=True)
    df.to_parquet(out, index=False)
    print(f"[save] {out}  ({out.stat().st_size / 1024 / 1024:.1f} MB)")


if __name__ == "__main__":
    main()
