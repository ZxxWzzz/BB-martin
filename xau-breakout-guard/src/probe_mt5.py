"""连通性探针: 确认 MT5 python 能连到 BB 终端且 XAUUSD 可拉。"""
import MetaTrader5 as mt5

if not mt5.initialize():
    print("初始化失败:", mt5.last_error())
    raise SystemExit

acc = mt5.account_info()
term = mt5.terminal_info()
print(f"terminal: {term.name}  path={term.path}")
print(f"account:  {acc.login} broker={acc.company} server={acc.server}")

# 列出所有含 XAU / GOLD 的品种，帮助确认真实名字
symbols = [s.name for s in mt5.symbols_get() if "XAU" in s.name.upper() or "GOLD" in s.name.upper()]
print(f"gold-like symbols: {symbols}")

# 拉 5 根 M1 验证
for name in symbols[:3]:
    mt5.symbol_select(name, True)
    rates = mt5.copy_rates_from_pos(name, mt5.TIMEFRAME_M1, 0, 5)
    print(f"  {name}: got {0 if rates is None else len(rates)} bars")

mt5.shutdown()
