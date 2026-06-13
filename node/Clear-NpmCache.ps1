#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Clear NPM Cache - Northstar DevKit
.DESCRIPTION
    Cleans the NPM cache and optionally verifies it.
    
    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Verify
    Also run cache verification after cleaning.
.EXAMPLE
    .\Clear-NpmCache.ps1
    .\Clear-NpmCache.ps1 -Verify
#>
[CmdletBinding()]
param(
    [switch]$Verify
)

$CommonModule = Join-Path $PSScriptRoot ".." "lib" "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

Write-DevKitHeader "Clear NPM Cache"

if (-not (Test-DevKitCommand npm)) {
    Write-DevKitError "npm is not installed or not in PATH."
    exit 1
}

Write-DevKitStep "Running npm cache clean --force"
npm cache clean --force | Out-Null

if ($LASTEXITCODE -ne 0) {
    Write-DevKitError "npm cache clean failed."
    exit 1
}

Write-DevKitDone

if ($Verify) {
    Write-DevKitStep "Running npm cache verify"
    npm cache verify
}

Write-Host ""
