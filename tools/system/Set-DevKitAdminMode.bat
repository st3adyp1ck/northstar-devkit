@echo off
setlocal

echo DevKit Admin Mode - launch DevKit with administrator privileges, no per-launch UAC
echo.

REM Deliberately NOT a nested "if %ERRORLEVEL%": cmd expands %VAR% across a
REM whole parenthesised block when it PARSES the block, so a nested check in
REM an else branch still sees the errorlevel from BEFORE the block ran. That
REM made the Windows PowerShell fallback dead code - a machine with
REM powershell.exe but no pwsh 7 reported "No PowerShell found" and quit.
REM Conditional execution tests each command's own exit status at run time.
set "PSH="
where pwsh >nul 2>&1 && set "PSH=pwsh"
if not defined PSH (
    where powershell >nul 2>&1 && set "PSH=powershell"
)
if not defined PSH (
    echo ERROR: No PowerShell found!
    pause
    exit /b 1
)

%PSH% -NoProfile -ExecutionPolicy Bypass -File "%~dp0Set-DevKitAdminMode.ps1" %*
set PS_EXIT=%ERRORLEVEL%
if %PS_EXIT% NEQ 0 pause
exit /b %PS_EXIT%
