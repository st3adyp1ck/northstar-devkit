@echo off
setlocal

echo Adding DevKit to PATH...

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

%PSH% -ExecutionPolicy Bypass -Command "& { $dir='%~dp0'.TrimEnd('\'); $userPath=[Environment]::GetEnvironmentVariable('PATH','User'); $entries=$userPath -split ';' | Where-Object { $_ }; if($entries -contains $dir){ Write-Host 'DevKit is already in PATH.' -ForegroundColor Yellow } else { [Environment]::SetEnvironmentVariable('PATH', ($entries + $dir) -join ';', 'User'); Write-Host 'Done! Restart your terminal to use devkit from anywhere.' -ForegroundColor Green } }"
set PS_EXIT=%ERRORLEVEL%
if %PS_EXIT% NEQ 0 (
    echo ERROR: Failed to update PATH.
    pause
)
exit /b %PS_EXIT%
