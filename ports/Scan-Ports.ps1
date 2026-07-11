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
if (Test-Path $CommonModule) {
    . $CommonModule
} else {
    Write-Host "ERROR: Required module not found: $CommonModule" -ForegroundColor Red
    exit 1
}

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

    # The same PID can appear more than once (e.g. a dev server whose HMR /
    # websocket port is also in the common-ports list above). Dedupe by PID
    # so we don't prompt to kill the same process twice.
    $seenPids = @{}
    $uniqueProcesses = @()
    foreach ($p in $foundProcesses) {
        if (-not $seenPids.ContainsKey($p.PID)) {
            $seenPids[$p.PID] = $true
            $uniqueProcesses += $p
        }
    }

    $failed = 0
    foreach ($proc in $uniqueProcesses) {
        $confirm = Read-Host "  Kill PID $($proc.PID) ($($proc.Name)) on port $($proc.Port)? (y/n)"
        if ($confirm -eq 'y') {
            # TOCTOU guard: the confirmation prompt can take an arbitrary
            # amount of time, during which the OS could reuse this PID for a
            # different process. Re-fetch immediately before killing and
            # confirm identity (and that it hasn't already exited).
            $verify = Get-Process -Id $proc.PID -ErrorAction SilentlyContinue
            if (-not $verify) {
                Write-Host "    SKIP: PID $($proc.PID) is no longer running." -ForegroundColor Gray
                continue
            }
            if ($verify.ProcessName -ne $proc.Name) {
                Write-Host "    WARNING: PID $($proc.PID) identity changed since scan (now '$($verify.ProcessName)', was '$($proc.Name)'). Skipping for safety." -ForegroundColor Yellow
                $failed++
                continue
            }

            try {
                Stop-Process -Id $proc.PID -Force
                Write-Host "    DONE: Killed PID $($proc.PID)" -ForegroundColor Green
            } catch {
                Write-Host "    ERROR: Failed to kill PID $($proc.PID): $_" -ForegroundColor Red
                $failed++
            }
        } else {
            Write-Host "    Skipped PID $($proc.PID)" -ForegroundColor Gray
        }
    }
    Write-Host ""

    if ($failed -gt 0) {
        exit 1
    }
}
