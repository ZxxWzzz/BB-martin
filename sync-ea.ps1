# 美分马丁-stable EA 一键同步脚本
# 从 git 仓库 pull -> 对比 hash -> 有差异才替换到 MT5 数据目录
# 目标 MT5: C:\Program Files\MetaTrader 5

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Line($color, $text) { Write-Host $text -ForegroundColor $color }

Line Cyan "=========================================="
Line Cyan "  美分马丁-stable EA 一键同步"
Line Cyan "=========================================="
Write-Host ""

# ---- 1. 定位仓库根 ----
$repoRoot = $PSScriptRoot
Line White "[1/5] 仓库路径: $repoRoot"
if(-not (Test-Path (Join-Path $repoRoot ".git"))) {
    Line Red "  X 不是 git 仓库, 脚本必须放在仓库根目录"
    Read-Host "按回车退出"; exit 1
}

# ---- 2. Git pull ----
Write-Host ""
Line White "[2/5] git pull ..."
Set-Location $repoRoot
$before = (git rev-parse HEAD).Trim()
git pull --ff-only 2>&1 | Out-Host
if($LASTEXITCODE -ne 0) {
    Line Red "  X git pull 失败, 检查网络或分支状态"
    Read-Host "按回车退出"; exit 1
}
$after = (git rev-parse HEAD).Trim()
if($before -eq $after) {
    Line Yellow "  = 已是最新版本 ($($before.Substring(0,7)))"
} else {
    Line Green ("  OK 拉取 {0} -> {1}" -f $before.Substring(0,7), $after.Substring(0,7))
    Write-Host ""
    Line White "  更新的 commit:"
    (git log --oneline "$before..$after") | ForEach-Object { Write-Host "    $_" }
}

# ---- 3. 找 MT5 数据目录 (通过 origin.txt 匹配) ----
Write-Host ""
Line White "[3/5] 定位 MT5 数据目录..."
$targetMT5 = "C:\Program Files\MetaTrader 5"
$terminalRoot = Join-Path $env:APPDATA "MetaQuotes\Terminal"
if(-not (Test-Path $terminalRoot)) {
    Line Red "  X 找不到 $terminalRoot (MT5 从没启动过?)"
    Read-Host "按回车退出"; exit 1
}

$foundHash = $null
foreach($dir in (Get-ChildItem $terminalRoot -Directory -ErrorAction SilentlyContinue)) {
    if($dir.Name -notmatch "^[A-F0-9]{32}$") { continue }
    $originFile = Join-Path $dir.FullName "origin.txt"
    if(-not (Test-Path $originFile)) { continue }
    $content = (Get-Content $originFile -First 1 -ErrorAction SilentlyContinue)
    if($null -ne $content -and $content.Trim() -eq $targetMT5) {
        $foundHash = $dir.Name
        break
    }
}

if(-not $foundHash) {
    Line Red "  X 找不到 origin=$targetMT5 的 MT5 数据目录"
    Line Yellow "  下列 Terminal 目录都不匹配:"
    Get-ChildItem $terminalRoot -Directory | ForEach-Object {
        $of = Join-Path $_.FullName "origin.txt"
        $origin = if(Test-Path $of) { (Get-Content $of -First 1).Trim() } else { "(无 origin.txt)" }
        Write-Host ("    {0}  origin={1}" -f $_.Name.Substring(0, [Math]::Min(16,$_.Name.Length)), $origin)
    }
    Read-Host "按回车退出"; exit 1
}

$mt5Experts = Join-Path $terminalRoot "$foundHash\MQL5\Experts"
Line Green ("  OK Terminal ID: {0}..." -f $foundHash.Substring(0,10))
Line White  "     Experts:   $mt5Experts"

# ---- 4. 对比 hash ----
Write-Host ""
Line White "[4/5] 对比 EA 文件 hash..."
$src = Join-Path $repoRoot "ea\美分马丁-stable\美分马丁-stable.mq5"
$dst = Join-Path $mt5Experts "美分马丁-stable.mq5"

if(-not (Test-Path $src)) {
    Line Red "  X 仓库里找不到 $src"
    Read-Host "按回车退出"; exit 1
}

$srcHash = (Get-FileHash $src -Algorithm SHA256).Hash
$srcTime = (Get-Item $src).LastWriteTime
$needCopy = $true; $reason = ""

if(-not (Test-Path $dst)) {
    $reason = "首次部署 (MT5 里还没这个 EA)"
    Line Yellow "  ! $reason"
} else {
    $dstHash = (Get-FileHash $dst -Algorithm SHA256).Hash
    $dstTime = (Get-Item $dst).LastWriteTime
    Line White ("  仓库: {0} ({1})" -f $srcHash.Substring(0,16), $srcTime)
    Line White ("  MT5 : {0} ({1})" -f $dstHash.Substring(0,16), $dstTime)
    if($srcHash -eq $dstHash) {
        $needCopy = $false
    } else {
        $reason = "hash 不同, 需要更新"
    }
}

# ---- 5. 复制 or 跳过 ----
Write-Host ""
Line White "[5/5] 同步操作..."
if($needCopy) {
    Copy-Item $src $dst -Force
    Line Green ("  OK 已复制到 MT5 ({0})" -f $reason)
    Write-Host ""
    Line Yellow "  下一步 (手动在 MT5 里做):"
    Line White  "    1. 打开 MetaEditor (F4)"
    Line White  "    2. Navigator -> Experts -> 双击 美分马丁-stable.mq5"
    Line White  "    3. F7 重新编译 (应 0 error 0 warning)"
    Line White  "    4. 图表上: 右键 EA -> 属性 -> 确定 (或先删除再拖回图表)"
    Line White  "    5. 面板 title 应显示新版本号"
} else {
    Line Yellow "  = 已是最新, 无需操作"
}

Write-Host ""
Line Cyan "=========================================="
Read-Host "按回车退出"
