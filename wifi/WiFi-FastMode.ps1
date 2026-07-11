#!/usr/bin/env pwsh
<#
.SYNOPSIS
    WiFi Fast Mode - Northstar DevKit
.DESCRIPTION
    Same as WiFi-Optimize but skips the 5-second speed test.
    Use this when you just want fast optimization.
    
    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.EXAMPLE
    .\WiFi-FastMode.ps1
    .\WiFi-FastMode.ps1 -KeepDNS
#>
# NOTE: deliberately no [CmdletBinding()] here (unlike the repo's usual script
# skeleton) and no -Fast parameter. This script always forces -Fast on the call
# below, but DevKit.ps1's Invoke-WiFiFast still invokes it as "& $scriptPath -Fast".
# Without CmdletBinding, a param() block binds named args loosely: an unrecognized
# -Fast simply falls through into the automatic $args array instead of throwing
# "parameter cannot be found" -- and since $args is never forwarded below, that
# redundant -Fast is silently absorbed instead of ever reaching WiFi-Optimize.ps1
# a second time.
param(
    [switch]$KeepDNS,
    [switch]$Force
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

# Admin check (WiFi-Optimize.ps1 also checks, but its "exit 1" does not propagate
# through the "&" call operator below -- this process would otherwise still exit 0
# even when elevation is missing, so WiFi-FastMode.bat would never pause on failure).
if (-not (Test-DevKitAdmin)) {
    Write-Host "`nNorthstar DevKit - WiFi FAST MODE`n" -ForegroundColor Cyan
    Write-Host "  ERROR: Administrator privileges required." -ForegroundColor Red
    Write-Host "  Right-click and select 'Run as administrator'.`n" -ForegroundColor Yellow
    exit 1
}

# Call the main script with -Fast flag, passing through remaining arguments.
# -Fast is intentionally NOT a param() here: this script always hardcodes it,
# so a caller (e.g. DevKit.ps1's Invoke-WiFiFast) can pass -Fast too without it
# landing twice on WiFi-Optimize.ps1's single [switch]$Fast parameter.
& "$PSScriptRoot\WiFi-Optimize.ps1" -Fast -KeepDNS:$KeepDNS -Force:$Force
exit $LASTEXITCODE
