#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Reset Windows Update - Northstar DevKit
.DESCRIPTION
    Classic fix for a stuck Windows Update: stops the Windows Update-related
    services, renames the SoftwareDistribution and catroot2 cache folders
    (Windows rebuilds both automatically on next use), then restarts the
    services.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER DryRun
    Show the step plan, with no execution and no admin check.
.PARAMETER Force
    Skip the confirmation prompt.
.EXAMPLE
    .\Reset-WindowsUpdate.ps1
    .\Reset-WindowsUpdate.ps1 -DryRun
    .\Reset-WindowsUpdate.ps1 -Force
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Force
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

Write-DevKitHeader "Reset Windows Update"

$Services = @('wuauserv', 'bits', 'cryptsvc', 'msiserver')
$SoftwareDistributionPath = Join-Path $env:SystemRoot "SoftwareDistribution"
$Catroot2Path = Join-Path (Join-Path $env:SystemRoot "System32") "catroot2"

if ($DryRun) {
    Write-Host "  [DRY RUN] No changes will be made.`n" -ForegroundColor Magenta
    Write-DevKitInfo "This would perform the following steps, in order:"
    Write-Host "    1. Stop services: $($Services -join ', ')" -ForegroundColor Gray
    Write-Host "    2. Rename '$SoftwareDistributionPath'" -ForegroundColor Gray
    Write-Host "       to '$SoftwareDistributionPath.bak-<yyyyMMddHHmmss>'" -ForegroundColor Gray
    Write-Host "    3. Rename '$Catroot2Path'" -ForegroundColor Gray
    Write-Host "       to '$Catroot2Path.bak-<yyyyMMddHHmmss>'" -ForegroundColor Gray
    Write-Host "    4. Start services: $($Services -join ', ')" -ForegroundColor Gray
    Write-Host ""
    exit 0
}

if (-not (Test-DevKitAdmin)) {
    Write-DevKitError "Administrator privileges required. Right-click and select 'Run as administrator'."
    exit 1
}

$actionDescription = "reset Windows Update by clearing its cache and catalog (classic fix for a stuck Windows Update)"
if (-not (Confirm-DevKitDestructiveAction -Action $actionDescription -TypedPhrase 'RESET' -Force:$Force)) {
    Write-Host "`n  Cancelled.`n" -ForegroundColor Gray
    exit 0
}

# A single timestamp shared by both renames in this run, so re-running this
# script later (e.g. after a prior partial failure) never collides with a
# backup folder this same run already created.
$timestamp = Get-Date -Format 'yyyyMMddHHmmss'
$results = @()

function Stop-DevKitUpdateService {
    param([Parameter(Mandatory = $true)][string]$Name)
    Write-DevKitStep "Stopping service: $Name"
    try {
        Stop-Service -Name $Name -Force -ErrorAction Stop
        Write-DevKitDone
        return $true
    } catch {
        Write-Host " FAIL" -ForegroundColor Red
        Write-DevKitInfo "Could not stop '$Name': $($_.Exception.Message)"
        return $false
    }
}

function Start-DevKitUpdateService {
    param([Parameter(Mandatory = $true)][string]$Name)
    Write-DevKitStep "Starting service: $Name"
    try {
        Start-Service -Name $Name -ErrorAction Stop
        Write-DevKitDone
        return $true
    } catch {
        Write-Host " FAIL" -ForegroundColor Red
        Write-DevKitInfo "Could not start '$Name': $($_.Exception.Message)"
        return $false
    }
}

function Rename-DevKitCacheFolder {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Timestamp,
        [Parameter(Mandatory = $true)][string]$Label
    )
    Write-DevKitStep "Renaming $Label folder"
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-DevKitSkip
        Write-DevKitInfo "Not found: $Path"
        return $true
    }
    $backupLeaf = "$(Split-Path -Leaf $Path).bak-$Timestamp"
    try {
        Rename-Item -LiteralPath $Path -NewName $backupLeaf -ErrorAction Stop
        Write-DevKitDone
        Write-DevKitInfo "Renamed to: $(Join-Path (Split-Path -Parent $Path) $backupLeaf)"
        return $true
    } catch {
        Write-Host " FAIL" -ForegroundColor Red
        Write-DevKitInfo "Could not rename '$Path': $($_.Exception.Message)"
        return $false
    }
}

foreach ($svc in $Services) {
    $ok = Stop-DevKitUpdateService -Name $svc
    $results += [PSCustomObject]@{ Step = "Stop service: $svc"; Success = $ok }
}

$sdOk = Rename-DevKitCacheFolder -Path $SoftwareDistributionPath -Timestamp $timestamp -Label "SoftwareDistribution"
$results += [PSCustomObject]@{ Step = "Rename SoftwareDistribution"; Success = $sdOk }

$crOk = Rename-DevKitCacheFolder -Path $Catroot2Path -Timestamp $timestamp -Label "catroot2"
$results += [PSCustomObject]@{ Step = "Rename catroot2"; Success = $crOk }

foreach ($svc in $Services) {
    $ok = Start-DevKitUpdateService -Name $svc
    $results += [PSCustomObject]@{ Step = "Start service: $svc"; Success = $ok }
}

Write-DevKitHeader "Summary"
$anyFailed = $false
foreach ($r in $results) {
    if ($r.Success) {
        Write-Host "  [OK]   $($r.Step)" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] $($r.Step)" -ForegroundColor Red
        $anyFailed = $true
    }
}
Write-Host ""

if ($anyFailed) {
    Write-DevKitInfo "One or more steps failed - see details above. A reboot can release locked"
    Write-DevKitInfo "files/services before retrying this script."
    exit 1
}

Write-Host "  Windows Update reset complete. A restart is recommended before checking for updates." -ForegroundColor Green
exit 0
