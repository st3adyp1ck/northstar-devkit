#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Add "Open Northstar DevKit Here" to the folder right-click menu - Northstar DevKit
.DESCRIPTION
    Adds a single registry key under HKCU:\Software\Classes\Directory\Background\shell,
    so right-clicking empty space inside any folder in Explorer offers
    "Open Northstar DevKit Here", launching the devkit CLI (cli/) with that
    folder as the starting directory.

    HKCU only - no administrator privileges required, and nothing outside
    the current user's own registry hive is touched. Fully reversible via
    Uninstall-ShellIntegration.ps1.

    This is an opt-in setup script - it is not run automatically by
    anything.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Force
    Skip the confirmation prompt.
.EXAMPLE
    .\Install-ShellIntegration.ps1
#>
[CmdletBinding()]
param(
    [switch]$Force
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

Write-DevKitHeader "Install Shell Integration"

# Two levels up: this script lives at tools\system\, the repo root is above tools\.
$devKitRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$releaseExe = Join-Path $devKitRoot "target\release\devkit.exe"
$debugExe = Join-Path $devKitRoot "target\debug\devkit.exe"
$devKitExe = if (Test-Path $releaseExe) { $releaseExe } elseif (Test-Path $debugExe) { $debugExe } else { $null }
if (-not $devKitExe) {
    Write-DevKitError "devkit.exe not found - build the CLI first: cargo build --release -p devkit-cli"
    exit 1
}

$pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
$shellExe = if ($pwshCmd) { $pwshCmd.Source } else { (Get-Command powershell -ErrorAction Stop).Source }

$keyPath = "HKCU:\Software\Classes\Directory\Background\shell\NorthstarDevKit"
$commandKeyPath = "$keyPath\command"
# %V expands to the background-clicked folder's path for this specific
# registry location (Directory\Background\shell), per Windows shell docs.
$commandLine = "`"$shellExe`" -NoExit -NoProfile -ExecutionPolicy Bypass -Command `"Set-Location -LiteralPath '%V'; & '$devKitExe'`""

Write-Host "  This will add ONE registry key under your own user profile:" -ForegroundColor Yellow
Write-Host "    $keyPath" -ForegroundColor Gray
Write-Host "  No administrator privileges are used or required." -ForegroundColor Yellow
Write-Host ""

if (-not (Confirm-DevKitDestructiveAction -Action "add a right-click 'Open Northstar DevKit Here' entry to the folder background context menu" -AffectedPaths @($keyPath) -Force:$Force)) {
    Write-Host "`n  Cancelled.`n" -ForegroundColor Gray
    exit 0
}

try {
    New-Item -Path $keyPath -Force | Out-Null
    Set-ItemProperty -Path $keyPath -Name "(Default)" -Value "Open Northstar DevKit Here"
    New-Item -Path $commandKeyPath -Force | Out-Null
    Set-ItemProperty -Path $commandKeyPath -Name "(Default)" -Value $commandLine
    Write-Host "  DONE: Right-click any folder's empty space and choose 'Open Northstar DevKit Here'." -ForegroundColor Green
    Write-Host "  To remove: .\Uninstall-ShellIntegration.ps1" -ForegroundColor Gray
} catch {
    Write-DevKitError "Failed to write the registry key: $_"
    exit 1
}
