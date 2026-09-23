"""基于人工标注的新闻事件过滤 hits.csv, 输出:
    hits_technical.csv  剩下的纯技术性命中 (未被人工标为新闻驱动)
    hits_news.csv       被标为新闻驱动的命中
"""
from __future__ import annotations

from pathlib import Path

import pandas as pd

HERE = Path(__file__).parent
FILTER_PATH = HERE / "../data/processed/news_events_filter.csv"
HITS_PATH = HERE / "../data/processed/hits.csv"


def main():
    hits = pd.read_csv(HITS_PATH)
    hits["start_utc"] = pd.to_datetime(hits["start_utc"], utc=True)

    flt = pd.read_csv(FILTER_PATH)
    # 组合 key: date + utc_time (HH:MM)
    flt["key"] = flt["date"] + " " + flt["utc_time"]

    hits["key"] = hits["start_utc"].dt.strftime("%Y-%m-%d %H:%M")
    hits["is_news"] = hits["key"].isin(flt["key"])

    tech = hits[~hits["is_news"]].drop(columns=["key", "is_news"]).reset_index(drop=True)
    news = hits[hits["is_news"]].drop(columns=["key", "is_news"]).reset_index(drop=True)

    out_tech = HERE / "../data/processed/hits_technical.csv"
    out_news = HERE / "../data/processed/hits_news.csv"
    tech.to_csv(out_tech, index=False, encoding="utf-8-sig")
    news.to_csv(out_news, index=False, encoding="utf-8-sig")

    print(f"total hits:     {len(hits)}")
    print(f"news-driven:    {len(news)}  ({len(news)/len(hits)*100:.0f}%)")
    print(f"technical rest: {len(tech)}  ({len(tech)/len(hits)*100:.0f}%)")
    print(f"\n[save] {out_tech}")
    print(f"[save] {out_news}")

    if len(tech):
        print("\n== 未被标为新闻的命中 ==")
        show_cols = ["date", "start_utc", "utc_hour", "weekday", "方向", "触发分钟数", "最大行程($)"]
        print(tech[show_cols].to_string(index=False))


if __name__ == "__main__":
    main()
