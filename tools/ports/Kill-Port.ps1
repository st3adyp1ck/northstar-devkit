#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Kill Port - Northstar DevKit
.DESCRIPTION
    Kill a process by port number or PID.
    Either provide a port number to find and kill the process,
    or provide a ProcessId directly.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Port
    The port number to kill.
.PARAMETER ProcessId
    The process ID to kill directly.
.PARAMETER Force
    Skip confirmation prompt.
.PARAMETER InfoOnly
    Look up and display the process without ever prompting to kill it.
.EXAMPLE
    .\Kill-Port.ps1 -Port 3000
    .\Kill-Port.ps1 -ProcessId 12345
    .\Kill-Port.ps1 -Port 3000 -Force
    .\Kill-Port.ps1 -Port 3000 -InfoOnly
#>
[CmdletBinding()]
param(
    [Parameter(ParameterSetName='ByPort')]
    [ValidateRange(1, 65535)]
    [int]$Port,

    [Parameter(ParameterSetName='ByPID')]
    [Alias('PID')]
    [int]$ProcessId,

    [switch]$Force,

    [switch]$InfoOnly
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) {
    . $CommonModule
} else {
    Write-Host "ERROR: Required module not found: $CommonModule" -ForegroundColor Red
    exit 1
}

Write-DevKitHeader "Kill Port"

if ($Port) {
    Write-DevKitInfo "Finding process on port $Port..."
    $procInfo = Get-DevKitProcessByPort -Port $Port

    if (-not $procInfo) {
        Write-DevKitError "No process found on port $Port"
        exit 1
    }

    $ProcessId = $procInfo.PID

    Write-Host "  Found: PID $($procInfo.PID)" -ForegroundColor Yellow
    if ($procInfo.Name -ne "Unknown") {
        Write-Host "  Name: $($procInfo.Name)" -ForegroundColor Yellow
        Write-Host "  Path: $($procInfo.Path)" -ForegroundColor Gray
    }
}

if (-not $ProcessId) {
    Write-DevKitError "No PID specified or found."
    exit 1
}

# Reject reserved / protected PIDs before ever touching Get-Process/Stop-Process.
if ($ProcessId -eq 0 -or $ProcessId -eq 4) {
    Write-DevKitError "Refusing to target PID $ProcessId (reserved system process)."
    exit 1
}
if ($ProcessId -eq $PID) {
    Write-DevKitError "Refusing to target PID $ProcessId (this is the current DevKit process)."
    exit 1
}

if ($InfoOnly) {
    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
    } catch {
        Write-DevKitError "Process $ProcessId not found."
        exit 1
    }

    $startTime = try { $process.StartTime } catch { "N/A" }
    Write-Host ""
    Write-Host "  Process: $($process.ProcessName) (PID: $ProcessId)" -ForegroundColor Yellow
    Write-Host "  Started: $startTime" -ForegroundColor Gray
    Write-Host ""
    exit 0
}

try {
    $process = Get-Process -Id $ProcessId -ErrorAction Stop
} catch {
    Write-DevKitError "Process $ProcessId not found."
    exit 1
}

Write-Host ""

if (-not $Force) {
    $confirm = Read-Host "Kill process $($process.ProcessName) (PID: $ProcessId)? (y/n)"
    if ($confirm -ne 'y') {
        Write-DevKitInfo "Cancelled."
        exit 0
    }
}

# TOCTOU guard: the confirmation prompt above can take an arbitrary amount of
# time, during which the OS could reuse this PID for a different process.
# Re-fetch the process immediately before killing and make sure it is still
# the same one we showed the user.
$initialName = $process.ProcessName
$initialStart = try { $process.StartTime } catch { $null }

$verifyProcess = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
if (-not $verifyProcess) {
    Write-DevKitError "Process $ProcessId is no longer running. Aborting kill."
    exit 1
}

$verifyStart = try { $verifyProcess.StartTime } catch { $null }
if ($verifyProcess.ProcessName -ne $initialName -or $verifyStart -ne $initialStart) {
    Write-DevKitError "Process identity changed since confirmation (PID $ProcessId is now '$($verifyProcess.ProcessName)', not '$initialName'). Aborting kill for safety."
    exit 1
}

try {
    Stop-Process -Id $ProcessId -Force
    Write-Host "  DONE: Process killed.`n" -ForegroundColor Green
} catch {
    Write-DevKitError "Failed to kill process: $_"
    exit 1
}
