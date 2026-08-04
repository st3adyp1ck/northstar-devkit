@echo off
setlocal

rem Northstar DevKit - Portable Installer launcher.
rem Same pwsh-first fallback chain as DevKit.bat. Runs visibly (no hidden
rem window) since Install.ps1 prompts for confirmation along the way.

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

%PSH% -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1" %*
set PS_EXIT=%ERRORLEVEL%
echo.
pause
exit /b %PS_EXIT%
