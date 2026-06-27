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

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

Write-DevKitHeader "Kill All Node Processes"

$nodeProcesses = Get-Process -Name "node" -ErrorAction SilentlyContinue

if (-not $nodeProcesses) {
    Write-Host "  OK: No node processes running.`n" -ForegroundColor Green
    exit 0
}

$count = ($nodeProcesses | Measure-Object).Count
Write-Host "  Found $count node process(es):`n" -ForegroundColor Yellow

foreach ($proc in $nodeProcesses) {
    $cpu = try { $proc.CPU } catch { "N/A" }
    $startTime = try { $proc.StartTime } catch { "N/A" }
    Write-Host "    PID: $($proc.Id)" -NoNewline
    Write-Host " | CPU: $cpu" -NoNewline
    Write-Host " | Started: $startTime" -ForegroundColor Gray
}

Write-Host ""

if (-not $Force) {
    $confirm = Read-Host "Kill all $count process(es)? (y/n)"
    if ($confirm -ne 'y') {
        Write-Host "  Cancelled.`n" -ForegroundColor Gray
        exit 0
    }
}

$killed = 0
$failed = 0
foreach ($proc in $nodeProcesses) {
    try {
        Stop-Process -Id $proc.Id -Force
        $killed++
    } catch {
        Write-Host "  WARNING: Failed to kill PID $($proc.Id): $_" -ForegroundColor Yellow
        $failed++
    }
}

if ($failed -eq 0) {
    Write-Host "  DONE: All node processes killed.`n" -ForegroundColor Green
} else {
    Write-Host "  DONE: Killed $killed process(es), $failed failed.`n" -ForegroundColor Yellow
}
