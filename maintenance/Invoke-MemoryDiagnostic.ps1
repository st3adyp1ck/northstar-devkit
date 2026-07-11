#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Memory Diagnostic - Northstar DevKit
.DESCRIPTION
    Launches the built-in Windows Memory Diagnostic tool (mdsched.exe),
    which prompts to restart the PC now or at the next boot to run a memory
    test. Gated behind a typed-phrase confirmation since it can interrupt
    the user's session with a restart - never launched without it.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER DryRun
    Explain what this script would do without launching anything.
.PARAMETER Force
    Skip the confirmation prompt.
.EXAMPLE
    .\Invoke-MemoryDiagnostic.ps1 -DryRun
    .\Invoke-MemoryDiagnostic.ps1
    .\Invoke-MemoryDiagnostic.ps1 -Force
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Force
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

Write-DevKitHeader "Memory Diagnostic"

try {
    if ($DryRun) {
        Write-Host "  [DRY RUN] No changes will be made." -ForegroundColor Magenta
        Write-Host ""
        Write-Host "  This would launch the built-in Windows Memory Diagnostic tool" -ForegroundColor Gray
        Write-Host "  (mdsched.exe). Windows will then prompt you to restart the PC" -ForegroundColor Gray
        Write-Host "  now or at the next boot to run the memory test." -ForegroundColor Gray
        Write-Host ""
        exit 0
    }

    if (-not (Test-DevKitCommand "mdsched.exe")) {
        Write-DevKitError "mdsched.exe was not found on this system."
        exit 1
    }

    if (-not (Confirm-DevKitDestructiveAction -Action "launch Windows Memory Diagnostic (mdsched.exe) - it will ask to restart your PC" -TypedPhrase 'RESTART' -Force:$Force)) {
        Write-DevKitInfo "Cancelled."
        exit 0
    }

    Write-DevKitStep "Launching Windows Memory Diagnostic"
    try {
        Start-Process "mdsched.exe" -ErrorAction Stop
        Write-DevKitDone
    } catch {
        Write-DevKitSkip
        Write-DevKitError "Failed to launch mdsched.exe: $_"
        exit 1
    }

    Write-Host ""
    Write-Host "  Follow its prompts to restart now or at next boot." -ForegroundColor Green

    exit 0
} catch {
    Write-DevKitError "Unexpected failure: $_"
    exit 1
}
