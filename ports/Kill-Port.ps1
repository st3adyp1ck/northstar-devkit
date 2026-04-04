#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Kill Port - Northstar DevKit
.DESCRIPTION
    Kill a process by port number or PID.
    Either provide a port number to find and kill the process,
    or provide a PID directly.
    
    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Port
    The port number to kill.
.PARAMETER PID
    The process ID to kill directly.
.PARAMETER Force
    Skip confirmation prompt.
.EXAMPLE
    .\Kill-Port.ps1 -Port 3000
    .\Kill-Port.ps1 -PID 12345
    .\Kill-Port.ps1 -Port 3000 -Force
#>
[CmdletBinding()]
param(
    [Parameter(ParameterSetName='ByPort')]
    [int]$Port,
    
    [Parameter(ParameterSetName='ByPID')]
    [int]$PID,
    
    [switch]$Force
)

Write-Host "`nNorthstar DevKit - Kill Port`n" -ForegroundColor Cyan

if ($Port) {
    Write-Host "Finding process on port $Port..." -ForegroundColor Yellow
    $connection = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1
    
    if (-not $connection) {
        Write-Host "  ERROR: No process found on port $Port`n" -ForegroundColor Red
        exit 1
    }
    
    $PID = $connection.OwningProcess
    $process = Get-Process -Id $PID -ErrorAction SilentlyContinue
    
    Write-Host "  Found: PID $PID" -ForegroundColor Yellow
    if ($process) {
        Write-Host "  Name: $($process.ProcessName)" -ForegroundColor Yellow
        Write-Host "  Path: $($process.Path)" -ForegroundColor Gray
    }
}

if (-not $PID) {
    Write-Host "`nERROR: No PID specified or found.`n" -ForegroundColor Red
    exit 1
}

try {
    $process = Get-Process -Id $PID -ErrorAction Stop
} catch {
    Write-Host "`nERROR: Process $PID not found.`n" -ForegroundColor Red
    exit 1
}

Write-Host ""

if (-not $Force) {
    $confirm = Read-Host "Kill process $($process.ProcessName) (PID: $PID)? (y/n)"
    if ($confirm -ne 'y') {
        Write-Host "  Cancelled.`n" -ForegroundColor Gray
        exit 0
    }
}

try {
    Stop-Process -Id $PID -Force
    Write-Host "  DONE: Process killed.`n" -ForegroundColor Green
} catch {
    Write-Host "  ERROR: Failed to kill process: $_`n" -ForegroundColor Red
    exit 1
}
