#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Repair System Files - Northstar DevKit
.DESCRIPTION
    Runs Windows's System File Checker (sfc /scannow) followed by DISM's
    component-store repair (DISM /Online /Cleanup-Image /RestoreHealth) to
    find and fix corrupted system files. Both tools stream their own output
    live as they run. This can take 10-30+ minutes depending on the machine.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER DryRun
    Show the commands that would run, with no execution and no admin check.
.PARAMETER Force
    Skip the confirmation prompt.
.EXAMPLE
    .\Repair-SystemFiles.ps1
    .\Repair-SystemFiles.ps1 -DryRun
    .\Repair-SystemFiles.ps1 -Force
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Force
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

Write-DevKitHeader "Repair System Files"

if ($DryRun) {
    Write-Host "  [DRY RUN] No changes will be made.`n" -ForegroundColor Magenta
    Write-DevKitInfo "This would run the following commands, in order:"
    Write-Host "    1. sfc /scannow" -ForegroundColor Gray
    Write-Host "    2. DISM /Online /Cleanup-Image /RestoreHealth" -ForegroundColor Gray
    Write-Host ""
    Write-DevKitInfo "Both tools scan and repair protected Windows system files / the component"
    Write-DevKitInfo "store. This can take 10-30+ minutes to complete, depending on the machine."
    exit 0
}

if (-not (Test-DevKitAdmin)) {
    Write-DevKitError "Administrator privileges required. Right-click and select 'Run as administrator'."
    exit 1
}

if (-not (Confirm-DevKitDestructiveAction -Action "run SFC and DISM system file repair (can take 10-30+ minutes)" -Force:$Force)) {
    Write-Host "`n  Cancelled.`n" -ForegroundColor Gray
    exit 0
}

if (-not (Test-DevKitCommand "sfc")) {
    Write-DevKitError "sfc.exe not found in PATH."
    exit 1
}
if (-not (Test-DevKitCommand "DISM")) {
    Write-DevKitError "DISM.exe not found in PATH."
    exit 1
}

Write-DevKitHeader "Running SFC (System File Checker)"
$sfcExitCode = $null
$sfcLines = @()
try {
    # Capture each line for the phrase-based result summary below while
    # still streaming it live via Write-Host as the caller sees it.
    $sfcLines = @(sfc /scannow 2>&1 | ForEach-Object {
        Write-Host $_
        $_
    })
    $sfcExitCode = $LASTEXITCODE
} catch {
    Write-DevKitError "sfc /scannow failed to run: $($_.Exception.Message)"
    $sfcExitCode = -1
}

Write-DevKitHeader "Running DISM (Component Store Repair)"
$dismExitCode = $null
try {
    @(DISM /Online /Cleanup-Image /RestoreHealth 2>&1 | ForEach-Object {
        Write-Host $_
    }) | Out-Null
    $dismExitCode = $LASTEXITCODE
} catch {
    Write-DevKitError "DISM /Online /Cleanup-Image /RestoreHealth failed to run: $($_.Exception.Message)"
    $dismExitCode = -1
}

Write-DevKitHeader "Summary"

# sfc's own exit code does not distinguish "found and fixed" from "found and
# could not fix" - only the human-readable result text does, so that is what
# must be parsed here rather than relying on $LASTEXITCODE alone.
$sfcOutputText = $sfcLines -join "`n"
$sfcResult = 'Unknown'
if ($sfcOutputText -match 'did not find any integrity violations') {
    $sfcResult = 'Clean'
} elseif ($sfcOutputText -match 'was unable to fix') {
    $sfcResult = 'Unfixed'
} elseif ($sfcOutputText -match 'successfully repaired') {
    $sfcResult = 'Repaired'
}

switch ($sfcResult) {
    'Clean'    { Write-Host "  SFC:  No integrity violations found." -ForegroundColor Green }
    'Repaired' { Write-Host "  SFC:  Corrupt files were found and repaired." -ForegroundColor Yellow }
    'Unfixed'  { Write-Host "  SFC:  Corrupt files were found - some could not be fixed." -ForegroundColor Red }
    default    { Write-Host "  SFC:  Result could not be determined from its output (exit code $sfcExitCode)." -ForegroundColor Yellow }
}

if ($dismExitCode -eq 0) {
    Write-Host "  DISM: Completed successfully." -ForegroundColor Green
} elseif ($dismExitCode -eq 3010) {
    Write-Host "  DISM: Completed successfully - a restart is required." -ForegroundColor Yellow
} else {
    Write-Host "  DISM: Failed (exit code $dismExitCode)." -ForegroundColor Red
}
Write-Host ""

$hadFailure = ($sfcResult -eq 'Unfixed') -or
    ($null -ne $sfcExitCode -and $sfcExitCode -ne 0) -or
    ($null -ne $dismExitCode -and $dismExitCode -ne 0 -and $dismExitCode -ne 3010)

if ($hadFailure) {
    exit 1
}
exit 0
