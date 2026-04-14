@echo off
cd /d "%~dp0"

where pwsh >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    pwsh -ExecutionPolicy Bypass -File "DevKit.ps1"
) else (
    powershell -ExecutionPolicy Bypass -File "DevKit.ps1"
)

pause
