@echo off
cd /d "%~dp0"
echo Git Status All Repositories
echo.

where pwsh >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: PowerShell 7 not found!
    pause
    exit /b 1
)

pwsh -ExecutionPolicy Bypass -File "Git-StatusAll.ps1" %*
echo.
pause
