#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Page File Configuration Report - Northstar DevKit
.DESCRIPTION
    Reports current page file usage, whether Windows is managing the page
    file automatically, and total physical RAM, then gives a plain-language
    read of whether the current setup looks reasonable. This tool is
    intentionally report-only: resizing page files programmatically is
    finicky and reboot-dependent, so it only reports and recommends rather
    than changing anything.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.EXAMPLE
    .\Test-PageFileConfig.ps1
#>
[CmdletBinding()]
param()

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

Write-DevKitHeader "Page File Configuration Report"

try {
    $computerSystem = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
} catch {
    Write-DevKitError "Could not query Win32_ComputerSystem: $_"
    exit 1
}

$totalRamGB = [math]::Round($computerSystem.TotalPhysicalMemory / 1GB, 1)
$autoManaged = [bool]$computerSystem.AutomaticManagedPagefile

$pageFileQueryFailed = $false
$pageFiles = @()
try {
    $pageFiles = @(Get-CimInstance Win32_PageFileUsage -ErrorAction Stop)
} catch {
    $pageFileQueryFailed = $true
    Write-DevKitError "Could not query Win32_PageFileUsage: $_"
}

Write-Host "  Physical RAM:     $totalRamGB GB" -ForegroundColor Gray
Write-Host "  System-managed:   $(if ($autoManaged) { 'Yes' } else { 'No' })" -ForegroundColor Gray
Write-Host ""

if ($pageFileQueryFailed) {
    Write-Host "  Page files:       Could not be determined" -ForegroundColor Gray
} elseif ($pageFiles.Count -eq 0) {
    Write-Host "  Page files:       None found" -ForegroundColor Gray
} else {
    Write-Host "  Page files:" -ForegroundColor Gray
    foreach ($pf in $pageFiles) {
        $allocatedMB = [int]$pf.AllocatedBaseSize
        $currentMB = [int]$pf.CurrentUsage
        Write-Host ("    {0}  allocated {1} MB, current usage {2} MB" -f $pf.Name, $allocatedMB, $currentMB) -ForegroundColor Gray
    }
}

Write-Host ""
Write-Host "  Assessment:" -ForegroundColor Magenta

$hasPageFile = $pageFiles.Count -gt 0

if ($pageFileQueryFailed) {
    Write-Host "  Page file presence could not be confirmed, so no recommendation is given." -ForegroundColor Gray
} elseif (-not $hasPageFile -and $totalRamGB -lt 16) {
    Write-Host "  No page file was found, and physical RAM is under 16 GB." -ForegroundColor Yellow
    Write-Host "  This setup is at real risk of out-of-memory failures under load." -ForegroundColor Yellow
    Write-Host "  Recommendation: turn on a system-managed page file." -ForegroundColor Yellow
} elseif (-not $hasPageFile -and $totalRamGB -ge 16) {
    Write-Host "  No page file was found, but physical RAM is $totalRamGB GB." -ForegroundColor Gray
    Write-Host "  That can be fine on a high-RAM machine, though a small page file is still" -ForegroundColor Gray
    Write-Host "  usually worthwhile for crash-dump support and rare memory spikes." -ForegroundColor Gray
} elseif ($autoManaged -and $totalRamGB -ge 16) {
    Write-Host "  System-managed page file with $totalRamGB GB of RAM is a reasonable," -ForegroundColor Green
    Write-Host "  low-maintenance setup. No change recommended." -ForegroundColor Green
} elseif ($autoManaged -and $totalRamGB -lt 16) {
    Write-Host "  System-managed page file is fine on $totalRamGB GB of RAM, though it's worth" -ForegroundColor Gray
    Write-Host "  keeping an eye on usage under heavy workloads (large builds, VMs, big datasets)." -ForegroundColor Gray
} else {
    Write-Host "  Manually-managed page file detected. That's fine if the size was chosen" -ForegroundColor Gray
    Write-Host "  deliberately; otherwise system-managed is simpler and usually just as effective." -ForegroundColor Gray
}

Write-Host ""
exit 0
