@echo off
setlocal

rem Northstar DevKit - Desktop GUI launcher.
rem Same pwsh-first fallback chain as DevKit.bat; -Sta for WPF, and the
rem console window hides itself once the GUI process takes over.

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

%PSH% -NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File "%~dp0gui\DevKit-GUI.ps1" %*
set PS_EXIT=%ERRORLEVEL%
if %PS_EXIT% NEQ 0 pause
exit /b %PS_EXIT%
