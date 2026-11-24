# ==============================================================================
# HuiGuangFanZhao EA sync to multiple MT5  (called by the .bat, or run directly)
# Pure-ASCII on purpose: avoids GBK/UTF-8 mojibake on Windows PowerShell 5.1.
# EA filenames may be Chinese - that's fine, they come from disk, not literals.
# ------------------------------------------------------------------------------
#   Dry run : powershell -ExecutionPolicy Bypass -File sync_to_mt5.ps1 -DryRun
#   Sync    : powershell -ExecutionPolicy Bypass -File sync_to_mt5.ps1 -Yes
#   -Root   search root (default = parent of this script's folder = MT5-Test)
#   -DryRun preview only, no copy
#   -Yes    skip confirm
#   -SubFolder  target subfolder under Experts (default HGFZ)
# ==============================================================================
param(
    [string]$Root = "",
    [switch]$DryRun,
    [switch]$Yes,
    [string]$SubFolder = "HGFZ"
)

try {
    $ErrorActionPreference = "Stop"
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

    # source = this script's folder (the ea folder)
    $SourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $SourceDir }
    $Root = $Root.TrimEnd('\')

    Write-Host "Source (ea) : $SourceDir"
    Write-Host "Search root : $Root"
    Write-Host "Mode        : $(if($DryRun){'DRY-RUN (no copy)'}else{'SYNC'})"
    Write-Host ""

    # files to sync: the four *-atr EAs (.mq5 + .ex5); exclude old EA, diag, sync
    $files = Get-ChildItem -Path $SourceDir -File | Where-Object {
        $_.Extension -in '.mq5','.ex5' -and
        $_.Name -like '*-atr.*' -and
        $_.Name -notlike '*sync*'
    }
    if ($files.Count -eq 0) { throw "No *-atr .mq5/.ex5 files found in $SourceDir" }

    Write-Host "Files to sync:" -ForegroundColor Cyan
    $files | ForEach-Object { Write-Host ("   " + $_.Name) }

    # find MetaTrader 5* installs
    $mt5Roots = Get-ChildItem -Path $Root -Directory -ErrorAction Stop |
        Where-Object { $_.Name -like 'MetaTrader 5*' }
    if ($mt5Roots.Count -eq 0) { throw "No 'MetaTrader 5*' folder under $Root" }

    # Build install-path -> AppData data-dir map via each GUID folder's origin.txt
    # (for non-portable MT5 whose MQL5\Experts lives under AppData\Roaming)
    $originMap = @{}
    $termBase = Join-Path $env:APPDATA "MetaQuotes\Terminal"
    if (Test-Path $termBase) {
        foreach ($g in (Get-ChildItem $termBase -Directory -ErrorAction SilentlyContinue)) {
            $of = Join-Path $g.FullName "origin.txt"
            if (Test-Path $of) {
                try {
                    $op = (Get-Content $of -Raw -ErrorAction Stop).Trim()
                    if ($op) { $originMap[$op.ToLower()] = $g.FullName }
                } catch {}
            }
        }
    }

    Write-Host "`nFound $($mt5Roots.Count) MT5, resolving Experts dir:" -ForegroundColor Cyan
    $valid = @()
    foreach ($r in $mt5Roots) {
        # 1) portable: <install>\MQL5\Experts
        $exp = Join-Path $r.FullName "MQL5\Experts"
        $how = "portable"
        if (-not (Test-Path $exp)) {
            # 2) non-portable: look up AppData data-dir by origin.txt == install path
            $key = $r.FullName.ToLower()
            if ($originMap.ContainsKey($key)) {
                $exp = Join-Path $originMap[$key] "MQL5\Experts"
                $how = "AppData"
            } else { $exp = $null }
        }
        if ($exp -and (Test-Path $exp)) {
            Write-Host ("   [OK]  {0}  ->  {1}\{2}  ({3})" -f $r.Name, $exp, $SubFolder, $how) -ForegroundColor Green
            $valid += [PSCustomObject]@{ Name=$r.Name; Experts=$exp }
        } else {
            Write-Host ("   [SKIP] {0}  ->  no Experts found (portable? AppData? never opened?)" -f $r.Name) -ForegroundColor Yellow
        }
    }
    if ($valid.Count -eq 0) { throw "No MT5 Experts dir resolved (check origin.txt / open each MT5 once)" }

    if ($DryRun) {
        Write-Host "`n[DRY-RUN done] above is what would be copied. Re-run without -DryRun to sync." -ForegroundColor Cyan
        return
    }

    if (-not $Yes) {
        $ans = Read-Host "`nSync $($files.Count) files to $($valid.Count) MT5? (y=go)"
        if ($ans -ne 'y') { Write-Host "Cancelled."; return }
    }

    $ok = 0
    foreach ($t in $valid) {
        $dest = Join-Path $t.Experts $SubFolder
        try {
            if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
            foreach ($f in $files) { Copy-Item $f.FullName -Destination $dest -Force }
            Write-Host ("   [OK]  {0}  synced {1} files" -f $t.Name, $files.Count) -ForegroundColor Green
            $ok++
        } catch {
            Write-Host ("   [FAIL] {0}  {1}" -f $t.Name, $_.Exception.Message) -ForegroundColor Red
        }
    }
    Write-Host "`nDone: $ok / $($valid.Count) MT5 synced OK" -ForegroundColor Cyan
}
catch {
    Write-Host "`n[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    exit 1
}
