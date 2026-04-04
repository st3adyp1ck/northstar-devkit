#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Kill All Node - Northstar DevKit
.DESCRIPTION
    Finds and terminates all running node processes.
    Shows what will be killed before acting.
    
    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Force
    Skip confirmation prompt.
.EXAMPLE
    .\Kill-AllNode.ps1
    .\Kill-AllNode.ps1 -Force
#>
[CmdletBinding()]
param(
    [switch]$Force
)

Write-Host "`nNorthstar DevKit - Kill All Node Processes`n" -ForegroundColor Cyan

$nodeProcesses = Get-Process -Name "node" -ErrorAction SilentlyContinue

if (-not $nodeProcesses) {
    Write-Host "  OK: No node processes running.`n" -ForegroundColor Green
    exit 0
}

$count = ($nodeProcesses | Measure-Object).Count
Write-Host "  Found $count node process(es):`n" -ForegroundColor Yellow

foreach ($proc in $nodeProcesses) {
    Write-Host "    PID: $($proc.Id)" -NoNewline
    Write-Host " | CPU: $($proc.CPU)" -NoNewline
    Write-Host " | Started: $($proc.StartTime)" -ForegroundColor Gray
}

Write-Host ""

if (-not $Force) {
    $confirm = Read-Host "Kill all $count process(es)? (y/n)"
    if ($confirm -ne 'y') {
        Write-Host "  Cancelled.`n" -ForegroundColor Gray
        exit 0
    }
}

try {
    $nodeProcesses | Stop-Process -Force
    Write-Host "  DONE: All node processes killed.`n" -ForegroundColor Green
} catch {
    Write-Host "  ERROR: $_`n" -ForegroundColor Red
    exit 1
}
