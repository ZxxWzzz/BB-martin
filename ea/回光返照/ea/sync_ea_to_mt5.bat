@echo off
chcp 65001 >nul
REM ============================================================
REM  HuiGuangFanZhao EA - one-click sync to multiple MT5
REM  Put this .bat in the MT5-Test root (next to 'ea' and the
REM  'MetaTrader 5*' folders), then double-click it.
REM  Real logic lives in  ea\sync_to_mt5.ps1
REM ============================================================
cd /d "%~dp0"

echo ===================================================================
echo  HuiGuangFanZhao EA sync
echo  root: %~dp0
echo ===================================================================
echo.

set "PS1=%~dp0ea\sync_to_mt5.ps1"
if not exist "%PS1%" (
    echo [X] sync script not found: %PS1%
    echo     This .bat must sit next to the 'ea' folder ^(MT5-Test root^).
    echo.
    pause
    exit /b 1
)

REM strip trailing backslash from %~dp0 to avoid \" escaping the quote
set "ROOTDIR=%~dp0"
if "%ROOTDIR:~-1%"=="\" set "ROOTDIR=%ROOTDIR:~0,-1%"

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Root "%ROOTDIR%" -Yes

echo.
echo ===================================================================
echo  Tip: in MT5, right-click Navigator -^> Refresh to see updates;
echo       if an EA is already on a chart, remove and re-drop it.
echo ===================================================================
echo.
pause
