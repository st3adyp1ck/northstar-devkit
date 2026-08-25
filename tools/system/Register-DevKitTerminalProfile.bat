@echo off
setlocal

echo Register Windows Terminal Profile
echo.

where pwsh >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    set PSH=pwsh
) else (
    where powershell >nul 2>&1
    if %ERRORLEVEL% EQU 0 (
        set PSH=powershell
    ) else (
        echo ERROR: No PowerShell found!
        pause
        exit /b 1
    )
)

%PSH% -NoProfile -ExecutionPolicy Bypass -File "%~dp0Register-DevKitTerminalProfile.ps1" %*
set PS_EXIT=%ERRORLEVEL%
pause
exit /b %PS_EXIT%
