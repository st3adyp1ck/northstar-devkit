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

$CommonPorts = @(3000, 3001, 5173, 8000, 8080, 9000, 4200, 5000, 5500)

Write-Host "`nNorthstar DevKit - Port Scanner`" -ForegroundColor Cyan
Write-Host "Ports: $($CommonPorts -join ', ')`n" -ForegroundColor Gray

$foundProcesses = @()

foreach ($port in $CommonPorts) {
    $connection = Get-NetTCPConnection -LocalPort $port -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($connection) {
        $process = Get-Process -Id $connection.OwningProcess -ErrorAction SilentlyContinue
        $foundProcesses += [PSCustomObject]@{
            Port = $port
            PID = $connection.OwningProcess
            Name = $process.ProcessName
            Path = $process.Path
        }
        
        Write-Host "  WARNING: Port $port" -ForegroundColor Red -NoNewline
        Write-Host " -> PID: $($connection.OwningProcess)" -ForegroundColor Yellow -NoNewline
        if ($process) {
            Write-Host " ($($process.ProcessName))" -ForegroundColor Gray
        } else {
            Write-Host ""
        }
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
