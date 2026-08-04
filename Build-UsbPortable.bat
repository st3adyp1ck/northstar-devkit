@echo off
setlocal

rem Northstar DevKit - builds the portable USB/ folder. Maintainer tool,
rem same pwsh-first fallback chain as the rest of the toolkit's launchers.

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

%PSH% -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build-UsbPortable.ps1" %*
set PS_EXIT=%ERRORLEVEL%
if %PS_EXIT% NEQ 0 pause
exit /b %PS_EXIT%
