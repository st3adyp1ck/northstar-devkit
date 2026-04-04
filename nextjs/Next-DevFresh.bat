@echo off
cd /d "%~dp0"
echo Starting fresh Next.js dev server...
echo.

where pwsh >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: PowerShell 7 not found!
    pause
    exit /b 1
)

pwsh -ExecutionPolicy Bypass -File "Next-DevFresh.ps1"

REM Dev server keeps window open, so we don't pause here
echo.
pause
