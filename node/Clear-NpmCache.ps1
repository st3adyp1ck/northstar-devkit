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

Write-Host "`nNorthstar DevKit - Clear NPM Cache`n" -ForegroundColor Cyan

Write-Host "  Running: npm cache clean --force" -ForegroundColor Gray
Write-Host ""

npm cache clean --force

if ($LASTEXITCODE -ne 0) {
    Write-Host "`n  ERROR: npm cache clean failed.`n" -ForegroundColor Red
    exit 1
}

Write-Host "`n  DONE: NPM cache cleared." -ForegroundColor Green

if ($Verify) {
    Write-Host "`n  Running: npm cache verify" -ForegroundColor Gray
    Write-Host ""
    npm cache verify
}

Write-Host ""
