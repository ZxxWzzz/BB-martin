"""拉取宏观事件日历 (investpy). 覆盖美/欧/中/英/日等主要经济体的高重要度事件.

依赖: pip install investpy pandas pyarrow pyyaml

注:
- investpy 是 investing.com 的非官方 wrapper, 免费但偶尔限流 / 需要翻墙.
- 拉不到时不必慌: label.py 里还有统计异常兜底 (5σ).
"""
from __future__ import annotations

from datetime import datetime, timedelta
from pathlib import Path

import pandas as pd
import yaml

try:
    import investpy
except ImportError:
    raise SystemExit("需要安装 investpy: pip install investpy")


HERE = Path(__file__).parent
CFG = yaml.safe_load((HERE / "config.yaml").open("r", encoding="utf-8"))

COUNTRIES = ["united states", "euro zone", "china", "united kingdom", "japan", "germany"]
IMPORTANCES = {1: "low", 2: "medium", 3: "high"}


def fetch(years_back: int, importance_min: int) -> pd.DataFrame:
    end = datetime.utcnow().date()
    start = end - timedelta(days=int(365.25 * years_back) + 5)
    wanted = [IMPORTANCES[k] for k in IMPORTANCES if k >= importance_min]

    frames = []
    # investpy 一次最多拉 3 个月, 分批
    cur = start
    while cur < end:
        nxt = min(cur + timedelta(days=90), end)
        print(f"[events] {cur} -> {nxt}")
        try:
            df = investpy.economic_calendar(
                from_date=cur.strftime("%d/%m/%Y"),
                to_date=nxt.strftime("%d/%m/%Y"),
                countries=COUNTRIES,
                importances=wanted,
            )
            frames.append(df)
        except Exception as e:
            print(f"  ! {e}")
        cur = nxt + timedelta(days=1)

    if not frames:
        raise SystemExit("investpy 一次都没拉到, 检查网络 / 翻墙")

    df = pd.concat(frames, ignore_index=True)
    # 拼接 UTC 时间列
    df["datetime_utc"] = pd.to_datetime(
        df["date"] + " " + df["time"].replace("All Day", "00:00"),
        format="%d/%m/%Y %H:%M",
        errors="coerce",
        utc=True,
    )
    df = df.dropna(subset=["datetime_utc"])
    df = df[["datetime_utc", "country", "event", "importance", "actual", "forecast", "previous"]]
    df = df.sort_values("datetime_utc").drop_duplicates(["datetime_utc", "event"]).reset_index(drop=True)
    return df


def main() -> None:
    df = fetch(CFG["fetch"]["years_back"], CFG["events"]["importance_min"])
    out = (HERE / CFG["events"]["cache_path"]).resolve()
    out.parent.mkdir(parents=True, exist_ok=True)
    df.to_parquet(out, index=False)
    print(f"[save] {out}  rows={len(df):,}")
    print(df["importance"].value_counts())


if __name__ == "__main__":
    main()
