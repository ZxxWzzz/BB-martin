## 事件记录

- **2026-10-09 06:00 市场维护误冻结事件**
  - 日志：`failed market sell 0.01 XAUUSD.ct, close #125192370 [Market closed]` → `[FATAL] 平仓失败10次 ticket=125192370 rc=10018 → 冻结 EA`
  - 根因：Decode Global 每日约 06:00 服务器时间例行维护窗口，市场暂时关闭（rc=10018）。CloseAllByDir 10次重试全部失败，EA 按设计触发 `emergencyFrozen=true`，属于误判非真实故障。
  - 处置：等市场重开（约 06:00–06:05），重载 EA 清除冻结状态，持仓 #125192370（0.01 手 buy @ 4134.18）保持开仓未受影响。
  - 后续增强点（见 Bugs 节）：CloseAllByDir 区分 rc=10018 市场关闭，改为等待而非计入失败次数，避免维护窗口误冻。

---

## Bugs

- [ ] **[BUG] 单向轮换 CloseAllByDir 失败后当前 tick 仍可能开新仓**
  - 位置：`OnTick` 单向轮换块（约 line 941/948）
  - 根因：`CloseAllByDir(-1)` / `CloseAllByDir(1)` 失败时会置 `emergencyFrozen=true`，但此时当前 tick 的 `emergencyFrozen` 检查（line ~868）已经过了，后续开仓逻辑仍会执行
  - 修复方案：在每个 `CloseAllByDir` 调用后立即检查 `emergencyFrozen`，若已置则 `UpdatePanel(); return;`
  ```mql5
  if(sig == 1 && stat.sellCnt > 0)
  {
      CloseAllByDir(-1);
      if(emergencyFrozen) { UpdatePanel(); return; }  // ← 新增
      GetPositionStat(stat);
  }
  else if(sig == -1 && stat.buyCnt > 0)
  {
      CloseAllByDir(1);
      if(emergencyFrozen) { UpdatePanel(); return; }  // ← 新增
      GetPositionStat(stat);
  }
  ```
