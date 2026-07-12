@echo off
setlocal

echo Add MCP Server From Catalog - Northstar DevKit
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

%PSH% -NoProfile -ExecutionPolicy Bypass -File "%~dp0Add-McpServerFromCatalog.ps1" %*
set PS_EXIT=%ERRORLEVEL%
if %PS_EXIT% NEQ 0 pause
exit /b %PS_EXIT%