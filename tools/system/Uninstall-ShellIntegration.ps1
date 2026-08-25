#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Remove "Open Northstar DevKit Here" from the folder right-click menu - Northstar DevKit
.DESCRIPTION
    Removes the registry key added by Install-ShellIntegration.ps1.
    HKCU only - no administrator privileges required.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.EXAMPLE
    .\Uninstall-ShellIntegration.ps1
#>
[CmdletBinding()]
param()

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

Write-DevKitHeader "Uninstall Shell Integration"

$keyPath = "HKCU:\Software\Classes\Directory\Background\shell\NorthstarDevKit"

if (-not (Test-Path $keyPath)) {
    Write-DevKitInfo "No shell integration found ($keyPath does not exist). Nothing to do."
    exit 0
}

try {
    Write-DevKitStep "Removing $keyPath"
    Remove-Item -Path $keyPath -Recurse -Force
    Write-DevKitDone
} catch {
    Write-DevKitError "Failed to remove the registry key: $_"
    exit 1
}

Write-Host ""
Write-Host "  DONE: 'Open Northstar DevKit Here' removed from the right-click menu." -ForegroundColor Green
