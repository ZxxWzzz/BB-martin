"""LightGBM baseline: 训练二分类模型预测"下一根 bar 是否为危险起点".

时序切分: 前 70% 训练 / 15% 验证 / 15% 测试.
类别极度不平衡 (~0.2%), 用 scale_pos_weight 补偿.

输出:
    model_lgbm.txt        模型文件
    feature_importance.csv
    test_predictions.csv  测试集每条预测
    train_report.txt      指标汇总
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pandas as pd
import yaml
from sklearn.metrics import (average_precision_score, precision_recall_curve,
                              roc_auc_score, precision_score, recall_score, f1_score)

try:
    import lightgbm as lgb
except ImportError:
    raise SystemExit("需要 lightgbm: pip install lightgbm")

HERE = Path(__file__).parent
PROC = HERE / "../data/processed"
CFG = yaml.safe_load((HERE / "config.yaml").open("r", encoding="utf-8"))


def main():
    print("[load] features.parquet")
    df = pd.read_parquet(PROC / "features.parquet").sort_values("time").reset_index(drop=True)
    print(f"  {len(df):,} rows  {df['time'].iloc[0]} ~ {df['time'].iloc[-1]}")

    feat_cols = [c for c in df.columns if c not in ("time", "label")]
    print(f"  features: {len(feat_cols)}")

    y = df["label"].astype(int).values
    X = df[feat_cols].values

    # 时序切分 70/15/15
    n = len(df)
    i_tr = int(n * 0.70)
    i_va = int(n * 0.85)
    X_tr, y_tr = X[:i_tr], y[:i_tr]
    X_va, y_va = X[i_tr:i_va], y[i_tr:i_va]
    X_te, y_te = X[i_va:], y[i_va:]
    t_te = df["time"].iloc[i_va:].values

    print(f"[split] train={len(y_tr):,} (+{y_tr.sum()}) "
          f"valid={len(y_va):,} (+{y_va.sum()}) "
          f"test={len(y_te):,} (+{y_te.sum()})")

    # scale_pos_weight = neg/pos
    spw = (y_tr == 0).sum() / max(y_tr.sum(), 1)
    print(f"[weight] scale_pos_weight={spw:.1f}")

    lgb_train = lgb.Dataset(X_tr, y_tr, feature_name=feat_cols)
    lgb_valid = lgb.Dataset(X_va, y_va, feature_name=feat_cols, reference=lgb_train)

    params = {
        "objective": "binary",
        "metric": ["binary_logloss", "auc", "average_precision"],
        "learning_rate": 0.03,
        "num_leaves": 63,
        "min_data_in_leaf": 200,
        "feature_fraction": 0.8,
        "bagging_fraction": 0.8,
        "bagging_freq": 5,
        "scale_pos_weight": spw,
        "verbose": -1,
    }

    print("[train] LightGBM")
    model = lgb.train(
        params, lgb_train, num_boost_round=2000,
        valid_sets=[lgb_train, lgb_valid], valid_names=["train", "valid"],
        callbacks=[lgb.early_stopping(100), lgb.log_evaluation(100)],
    )

    # 预测
    prob_va = model.predict(X_va, num_iteration=model.best_iteration)
    prob_te = model.predict(X_te, num_iteration=model.best_iteration)

    # 评估
    def report(name, y_true, prob):
        auc = roc_auc_score(y_true, prob) if y_true.sum() else np.nan
        ap = average_precision_score(y_true, prob) if y_true.sum() else np.nan
        print(f"\n=== {name} ===")
        print(f"  AUC:   {auc:.4f}")
        print(f"  AP :   {ap:.4f}  (baseline={y_true.mean():.4f})")
        # 阈值扫描
        for thr in [0.3, 0.5, 0.7, 0.8, 0.9]:
            pred = (prob >= thr).astype(int)
            if pred.sum() == 0:
                continue
            prec = precision_score(y_true, pred, zero_division=0)
            rec = recall_score(y_true, pred)
            f1 = f1_score(y_true, pred, zero_division=0)
            print(f"  @thr={thr:.1f}  pred_pos={pred.sum():>6}  "
                  f"precision={prec:.3f}  recall={rec:.3f}  F1={f1:.3f}")
        return auc, ap

    auc_va, ap_va = report("VALID", y_va, prob_va)
    auc_te, ap_te = report("TEST",  y_te, prob_te)

    # 特征重要性
    imp = pd.DataFrame({
        "feature": feat_cols,
        "gain": model.feature_importance(importance_type="gain"),
        "split": model.feature_importance(importance_type="split"),
    }).sort_values("gain", ascending=False)
    print("\n== Top 15 特征 (按 gain) ==")
    print(imp.head(15).to_string(index=False))
    imp.to_csv(PROC / "feature_importance.csv", index=False, encoding="utf-8-sig")

    # 测试集预测明细
    te_pred = pd.DataFrame({
        "time": t_te,
        "label": y_te,
        "prob": prob_te,
    })
    te_pred.to_csv(PROC / "test_predictions.csv", index=False, encoding="utf-8-sig")

    # 模型
    model.save_model(str(PROC / "model_lgbm.txt"))

    # 报告
    with open(PROC / "train_report.txt", "w", encoding="utf-8") as f:
        f.write(f"XAU 单边行情预警 - LightGBM baseline\n")
        f.write("=" * 60 + "\n\n")
        f.write(f"数据总量: {n:,} 行\n")
        f.write(f"时间范围: {df['time'].iloc[0]} ~ {df['time'].iloc[-1]}\n")
        f.write(f"特征数: {len(feat_cols)}\n")
        f.write(f"正样本比例: {y.mean()*100:.3f}%\n\n")
        f.write(f"切分: train={len(y_tr):,}/+{y_tr.sum()}  valid={len(y_va):,}/+{y_va.sum()}  test={len(y_te):,}/+{y_te.sum()}\n\n")
        f.write(f"VALID: AUC={auc_va:.4f}  AP={ap_va:.4f}\n")
        f.write(f"TEST:  AUC={auc_te:.4f}  AP={ap_te:.4f}\n\n")
        f.write(f"Top 15 特征:\n{imp.head(15).to_string(index=False)}\n")

    print(f"\n[save] {PROC / 'model_lgbm.txt'}")
    print(f"[save] {PROC / 'feature_importance.csv'}")
    print(f"[save] {PROC / 'test_predictions.csv'}")
    print(f"[save] {PROC / 'train_report.txt'}")


if __name__ == "__main__":
    main()
