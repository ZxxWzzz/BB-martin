import json
from pathlib import Path


class DataService:
    def __init__(self, mql5_files_dir: Path):
        self.state_file = mql5_files_dir / "bb_martin_state.json"
        self.trades_file = mql5_files_dir / "bb_martin_trades.jsonl"
        self.equity_file = mql5_files_dir / "bb_martin_equity.jsonl"

    def get_current_state(self) -> dict | None:
        try:
            text = self.state_file.read_text(encoding="utf-8")
            return json.loads(text)
        except (OSError, json.JSONDecodeError):
            return None

    def get_trades(self) -> list[dict]:
        trades = []
        try:
            with open(self.trades_file, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if line:
                        try:
                            trades.append(json.loads(line))
                        except json.JSONDecodeError:
                            continue
        except OSError:
            pass
        return trades

    def get_equity(self) -> list[dict]:
        points = []
        try:
            with open(self.equity_file, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if line:
                        try:
                            points.append(json.loads(line))
                        except json.JSONDecodeError:
                            continue
        except OSError:
            pass
        return points

    def get_stats(self) -> dict:
        trades = self.get_trades()
        if not trades:
            return {
                "total_cycles": 0, "win_rate": 0, "profit_factor": 0,
                "total_profit": 0, "avg_profit": 0, "max_drawdown": 0,
                "avg_layers": 0, "avg_duration_sec": 0,
                "best_trade": 0, "worst_trade": 0,
                "win_streak": 0, "loss_streak": 0
            }

        total = len(trades)
        wins = [t for t in trades if t.get("profit", 0) > 0]
        losses = [t for t in trades if t.get("profit", 0) <= 0]

        total_profit = sum(t.get("profit", 0) for t in trades)
        gross_profit = sum(t["profit"] for t in wins) if wins else 0
        gross_loss = abs(sum(t["profit"] for t in losses)) if losses else 0

        profit_factor = gross_profit / gross_loss if gross_loss > 0 else float("inf")
        avg_profit = total_profit / total if total > 0 else 0
        avg_layers = sum(t.get("layers_used", 1) for t in trades) / total
        avg_duration = sum(t.get("duration_sec", 0) for t in trades) / total

        best = max(t.get("profit", 0) for t in trades)
        worst = min(t.get("profit", 0) for t in trades)

        # streaks
        win_streak = loss_streak = cur_win = cur_loss = 0
        for t in trades:
            if t.get("profit", 0) > 0:
                cur_win += 1
                cur_loss = 0
                win_streak = max(win_streak, cur_win)
            else:
                cur_loss += 1
                cur_win = 0
                loss_streak = max(loss_streak, cur_loss)

        # max drawdown from equity curve
        equity_points = self.get_equity()
        max_dd = 0
        peak = 0
        for p in equity_points:
            eq = p.get("eq", 0)
            if eq > peak:
                peak = eq
            dd = (peak - eq) / peak * 100 if peak > 0 else 0
            max_dd = max(max_dd, dd)

        return {
            "total_cycles": total,
            "wins": len(wins),
            "losses": len(losses),
            "win_rate": len(wins) / total * 100 if total > 0 else 0,
            "profit_factor": round(profit_factor, 2),
            "total_profit": round(total_profit, 2),
            "avg_profit": round(avg_profit, 2),
            "max_drawdown": round(max_dd, 2),
            "avg_layers": round(avg_layers, 1),
            "avg_duration_sec": int(avg_duration),
            "best_trade": round(best, 2),
            "worst_trade": round(worst, 2),
            "win_streak": win_streak,
            "loss_streak": loss_streak
        }
