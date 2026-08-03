@echo off
setlocal

echo Git Standup - Your recent commits across repos
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

%PSH% -NoProfile -ExecutionPolicy Bypass -File "%~dp0Get-GitStandup.ps1" %*
set PS_EXIT=%ERRORLEVEL%
echo.
pause
exit /b %PS_EXIT%
