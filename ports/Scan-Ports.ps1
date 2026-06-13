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

$CommonPorts = @(3000, 3001, 3002, 3003, 5173, 5174, 8000, 8080, 8081, 9000, 4200, 5000, 5500, 1337, 5432, 3306, 6379, 27017)

Write-Host "`nNorthstar DevKit - Port Scanner" -ForegroundColor Cyan
Write-Host "Ports: $($CommonPorts -join ', ')`n" -ForegroundColor Gray

$foundProcesses = @()

foreach ($port in $CommonPorts) {
    $connection = Get-NetTCPConnection -LocalPort $port -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($connection) {
        $process = Get-Process -Id $connection.OwningProcess -ErrorAction SilentlyContinue
        $procName = if ($process) { $process.ProcessName } else { "Unknown" }
        $foundProcesses += [PSCustomObject]@{
            Port = $port
            PID = $connection.OwningProcess
            Name = $procName
            Path = if ($process) { $process.Path } else { $null }
        }
        
        Write-Host "  WARNING: Port $port" -ForegroundColor Red -NoNewline
        Write-Host " -> PID: $($connection.OwningProcess)" -ForegroundColor Yellow -NoNewline
        Write-Host " ($procName)" -ForegroundColor Gray
    }
}

if ($foundProcesses.Count -eq 0) {
    Write-Host "  OK: All clear! No processes on common dev ports.`n" -ForegroundColor Green
    exit 0
}

Write-Host ""

if ($Kill) {
    Write-Host "Kill Mode Enabled`n" -ForegroundColor Magenta
    
    foreach ($proc in $foundProcesses) {
        $confirm = Read-Host "  Kill PID $($proc.PID) ($($proc.Name)) on port $($proc.Port)? (y/n)"
        if ($confirm -eq 'y') {
            try {
                Stop-Process -Id $proc.PID -Force
                Write-Host "    KILLED`n" -ForegroundColor Green
            } catch {
                Write-Host "    FAILED: $_`n" -ForegroundColor Red
            }
        } else {
            Write-Host "    Skipped`n" -ForegroundColor Gray
        }
    }
}

Write-Host ""
