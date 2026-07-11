#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Disk Health Report - Northstar DevKit
.DESCRIPTION
    Read-only physical disk health report. Reads per-disk wear, temperature,
    and read/write error counters via Storage Reliability Counters, and
    separately reports classic SMART failure-prediction data where the
    driver stack exposes it. Never modifies anything.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.EXAMPLE
    .\Get-DiskHealthReport.ps1
#>
[CmdletBinding()]
param()

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

Write-DevKitHeader "Disk Health Report"

$WearThresholdPercent = 90
$TemperatureThresholdC = 55

try {
    Write-Host "  Storage Reliability Counters:" -ForegroundColor Magenta
    Write-Host ""

    $disks = @()
    try {
        $disks = @(Get-PhysicalDisk -ErrorAction Stop)
    } catch {
        Write-DevKitError "Get-PhysicalDisk is unavailable on this system: $_"
    }

    if ($disks.Count -eq 0) {
        Write-DevKitInfo "No physical disks were reported by Get-PhysicalDisk."
    }

    foreach ($disk in $disks) {
        $label = "Disk $($disk.DeviceId): $($disk.FriendlyName)"

        Write-DevKitStep "Reading reliability counters for $label"
        $counter = $null
        try {
            # Wrapped per-disk, not around the whole loop: some
            # controllers/drives (notably several USB and RAID passthrough
            # setups) throw here even though Get-PhysicalDisk itself
            # succeeded - one unsupported disk must not blank the rest.
            $counter = $disk | Get-StorageReliabilityCounter -ErrorAction Stop
            Write-DevKitDone
        } catch {
            Write-DevKitSkip
            Write-DevKitInfo "Reliability counters not supported for this disk: $_"
            continue
        }

        $wear = $counter.Wear
        $tempC = $counter.Temperature
        $readErrors = $counter.ReadErrorsTotal
        $writeErrors = $counter.WriteErrorsTotal

        if ($null -ne $wear) { Write-Host "    Wear:         $wear%" -ForegroundColor Gray }
        if ($null -ne $tempC) { Write-Host "    Temperature:  $tempC C" -ForegroundColor Gray }
        if ($null -ne $readErrors) { Write-Host "    Read Errors:  $readErrors" -ForegroundColor Gray }
        if ($null -ne $writeErrors) { Write-Host "    Write Errors: $writeErrors" -ForegroundColor Gray }

        $reasons = @()
        if ($null -ne $wear -and $wear -ge $WearThresholdPercent) { $reasons += "wear $wear% >= $WearThresholdPercent%" }
        if ($null -ne $tempC -and $tempC -gt $TemperatureThresholdC) { $reasons += "temperature ${tempC}C over ${TemperatureThresholdC}C" }

        if ($reasons.Count -gt 0) {
            Write-Host "    FLAGGED: $($reasons -join '; ')" -ForegroundColor Yellow
        } else {
            Write-Host "    Status: healthy" -ForegroundColor Green
        }
        Write-Host ""
    }

    Write-Host "  Classic SMART Failure Prediction:" -ForegroundColor Magenta
    Write-Host ""

    $smartAvailable = $false
    $smartStatuses = @()
    try {
        # root\wmi\MSStorageDriver_FailurePredictStatus only exists under the
        # legacy SMART driver stack and is commonly absent entirely (NVMe-only
        # systems, some controllers) - that absence is expected, not an error,
        # so it is caught here and the section is simply skipped.
        $smartStatuses = @(Get-CimInstance -Namespace 'root\wmi' -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction Stop)
        $smartAvailable = $true
    } catch {
        $smartAvailable = $false
    }

    if (-not $smartAvailable) {
        Write-DevKitInfo "Classic SMART data (root\wmi\MSStorageDriver_FailurePredictStatus) is not available on this system."
    } elseif ($smartStatuses.Count -eq 0) {
        Write-DevKitInfo "No classic SMART failure-prediction entries were reported."
    } else {
        # Not merged into the per-disk flags above: InstanceName here has no
        # field shared with Get-PhysicalDisk's identity on most systems, so
        # any attempt to correlate the two would just be a guess.
        foreach ($status in $smartStatuses) {
            Write-Host "  $($status.InstanceName)" -ForegroundColor Gray
            if ([bool]$status.PredictFailure) {
                Write-Host "    FLAGGED: PredictFailure = True (reason: $($status.Reason -join ','))" -ForegroundColor Red
            } else {
                Write-Host "    Status: healthy (PredictFailure = False)" -ForegroundColor Green
            }
            Write-Host ""
        }
    }

    exit 0
} catch {
    Write-DevKitError "Unexpected failure: $_"
    exit 1
}
