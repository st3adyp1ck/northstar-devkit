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
.EXAMPLE
    .\Kill-Port.ps1 -Port 3000
    .\Kill-Port.ps1 -ProcessId 12345
    .\Kill-Port.ps1 -Port 3000 -Force
#>
[CmdletBinding()]
param(
    [Parameter(ParameterSetName='ByPort')]
    [ValidateRange(1, 65535)]
    [int]$Port,

    [Parameter(ParameterSetName='ByPID')]
    [Alias('PID')]
    [int]$ProcessId,

    [switch]$Force
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

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

try {
    Stop-Process -Id $ProcessId -Force
    Write-Host "  DONE: Process killed.`n" -ForegroundColor Green
} catch {
    Write-DevKitError "Failed to kill process: $_"
    exit 1
}
