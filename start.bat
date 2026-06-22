@echo off
chcp 65001 >nul
echo ============================
echo  BB Martin M1 Monitor
echo ============================
echo.

cd /d "%~dp0backend"
echo [INFO] Working dir: %CD%
echo.

where python >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Python not found
    goto :fail
)
echo [OK] Python found:
python --version
echo.

if not exist ".venv\Scripts\python.exe" (
    echo [1/3] Creating venv...
    python -m venv .venv
    if errorlevel 1 (
        echo [ERROR] venv creation failed
        goto :fail
    )
    echo [2/3] Installing deps...
    .venv\Scripts\pip install -r requirements.txt -q
    if errorlevel 1 (
        echo [ERROR] pip install failed
        goto :fail
    )
) else (
    echo [OK] venv ready
)

echo.
echo [3/3] Starting server http://localhost:8877
echo.
echo Press Ctrl+C to stop
echo ----------------------------------------

start "" cmd /c "timeout /t 2 /nobreak >nul && start http://localhost:8877"

.venv\Scripts\python -m uvicorn main:app --host 0.0.0.0 --port 8877
if errorlevel 1 (
    echo.
    echo [ERROR] Server exited abnormally
    goto :fail
)
goto :end

:fail
echo.
echo ========================================
echo  ERROR - Check log above
echo ========================================
echo.
pause
exit /b 1

:end
pause
