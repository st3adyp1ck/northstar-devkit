#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Port Scanner - Northstar DevKit
.DESCRIPTION
    Scans common development ports and displays process information.
    Can also kill processes interactively.
    
    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Kill
    If specified, enables interactive process killing.
.EXAMPLE
    .\Scan-Ports.ps1
    .\Scan-Ports.ps1 -Kill
#>
[CmdletBinding()]
param(
    [switch]$Kill
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

$CommonPorts = @(3000, 3001, 3002, 3003, 5173, 5174, 8000, 8080, 8081, 9000, 4200, 5000, 5500, 1337, 5432, 3306, 6379, 27017)

Write-DevKitHeader "Port Scanner"
Write-DevKitInfo "Ports: $($CommonPorts -join ', ')"

$foundProcesses = @()

foreach ($port in $CommonPorts) {
    $procInfo = Get-DevKitProcessByPort -Port $port
    if ($procInfo) {
        $foundProcesses += $procInfo

        Write-Host "  WARNING: Port $port" -ForegroundColor Red -NoNewline
        Write-Host " -> PID: $($procInfo.PID)" -ForegroundColor Yellow -NoNewline
        Write-Host " ($($procInfo.Name))" -ForegroundColor Gray
    }
}

if ($foundProcesses.Count -eq 0) {
    Write-Host "  OK: All clear! No processes on common dev ports.`n" -ForegroundColor Green
    exit 0
}

Write-Host ""

if ($Kill) {
    Write-Host "  Kill Mode Enabled`n" -ForegroundColor Magenta

    foreach ($proc in $foundProcesses) {
        $confirm = Read-Host "  Kill PID $($proc.PID) ($($proc.Name)) on port $($proc.Port)? (y/n)"
        if ($confirm -eq 'y') {
            try {
                Stop-Process -Id $proc.PID -Force
                Write-Host "    DONE: Killed PID $($proc.PID)" -ForegroundColor Green
            } catch {
                Write-Host "    ERROR: Failed to kill PID $($proc.PID): $_" -ForegroundColor Red
            }
        } else {
            Write-Host "    Skipped PID $($proc.PID)" -ForegroundColor Gray
        }
    }
    Write-Host ""
}
