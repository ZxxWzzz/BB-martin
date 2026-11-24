# sync-ea — 一键同步 EA 源码到 MT5

`sync-ea.bat` 双击入口，实际逻辑在 `sync-ea.ps1`。把仓库里的 `美分马丁-stable.mq5` 同步到本机 MT5 的 `MQL5\Experts\` 目录，省得每次手动复制。

## 它做什么

```
1. 检查当前目录是不是 git 仓库
2. git pull --ff-only          ← 拉取"当前分支"的最新提交
3. 按 origin.txt 定位 MT5 数据目录
4. 用 SHA256 对比仓库文件和 MT5 里的文件
5. hash 不同才复制；相同就跳过
```

复制后会打印手动步骤（编译、重新挂图）。

## 它不做什么

**只复制源码，不编译、不重新加载 EA。** 复制完还要：

1. MT5 里按 `F4` 打开 MetaEditor
2. `Navigator → Experts → 美分马丁-stable.mq5`，按 `F7` 编译（应 `0 errors, 0 warnings`）
3. 图表上右键 EA → 属性 → 确定，或删掉重新拖一次
4. 看面板标题和启动日志的版本号是否变化

## 前提

- 仓库本身是 git 仓库，`sync-ea.bat` 放在仓库根目录
- MT5 安装在 `C:\Program Files\MetaTrader 5`（路径在 `sync-ea.ps1:46` 硬编码）
- MT5 至少启动过一次，`%APPDATA%\MetaQuotes\Terminal\<32位ID>\origin.txt` 里写着上面那个安装路径

## 常见问题

**同步后还是旧版本**

最可能的原因：**改动不在当前分支上**。`git pull --ff-only` 只拉当前检出分支的上游，别的分支（包括已推送但未合并的功能分支）拉不到。

先确认：

```bash
git branch --show-current
git log --oneline -1
```

如果在 `main` 但 `main` 落后，或者改动还在功能分支里，先合并到 `main` 再同步。建议所有改动都直接在 `main` 上做。

**提示"找不到 MT5 数据目录"**

脚本按 `origin.txt` 内容精确匹配 `C:\Program Files\MetaTrader 5`。装了多个 MT5、或终端是便携版时匹配不上。脚本会列出所有 Terminal 目录及各自的 origin，对照修改 `sync-ea.ps1` 第 46 行的 `$targetMT5`。

**提示"已是最新, 无需操作"**

hash 相同，说明 MT5 里已经是仓库里这个版本。如果版本号看起来不对，检查是否拉错了分支（见上一条）。

**git pull 失败**

通常是有未提交改动，或本地分支和远程分叉。脚本用 `--ff-only`，不会产生合并提交。

## 换其他 EA

脚本只处理这一个文件（`sync-ea.ps1:83`）。要同步别的 EA，改 `$src` / `$dst` 两个变量，或者复制一份脚本改路径。
