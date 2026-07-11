#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Remove the Windows Terminal Profile - Northstar DevKit
.DESCRIPTION
    Removes the dynamic profile fragment dropped by
    Register-DevKitTerminalProfile.ps1. Never touches Windows Terminal's
    own settings.json.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.EXAMPLE
    .\Unregister-DevKitTerminalProfile.ps1
#>
[CmdletBinding()]
param()

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

Write-DevKitHeader "Unregister Windows Terminal Profile"

$fragmentDir = Join-Path (Join-Path $env:LOCALAPPDATA "Microsoft\Windows Terminal\Fragments") "Northstar DevKit"
$fragmentFile = Join-Path $fragmentDir "devkit.json"

if (-not (Test-Path $fragmentFile)) {
    Write-DevKitInfo "No registered profile found ($fragmentFile does not exist). Nothing to do."
    exit 0
}

try {
    Write-DevKitStep "Removing $fragmentFile"
    Remove-Item -Path $fragmentFile -Force
    if ((Get-ChildItem -Path $fragmentDir -Force -ErrorAction SilentlyContinue | Measure-Object).Count -eq 0) {
        Remove-Item -Path $fragmentDir -Force -ErrorAction SilentlyContinue
    }
    Write-DevKitDone
} catch {
    Write-DevKitError "Failed to remove the profile fragment: $_"
    exit 1
}

Write-Host ""
Write-Host "  DONE: Northstar DevKit profile removed from Windows Terminal." -ForegroundColor Green
