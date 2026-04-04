@echo off
cd /d "%~dp0"
echo System Dev Info
echo.

where pwsh >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: PowerShell 7 not found!
    pause
    exit /b 1
)

pwsh -ExecutionPolicy Bypass -File "System-DevInfo.ps1" %*
echo.
pause
