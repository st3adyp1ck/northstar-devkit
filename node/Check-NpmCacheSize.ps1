#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Check NPM Cache Size - Northstar DevKit
.DESCRIPTION
    Runs npm cache verify and shows the cache path and size info.
    
    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.EXAMPLE
    .\Check-NpmCacheSize.ps1
#>
[CmdletBinding()]
param()

$CommonModule = Join-Path $PSScriptRoot ".." "lib" "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

Write-DevKitHeader "NPM Cache Size"

if (-not (Test-DevKitCommand npm)) {
    Write-DevKitError "npm is not installed or not in PATH."
    exit 1
}

$cachePath = npm config get cache 2>$null
Write-DevKitInfo "Cache Path: $cachePath"
Write-Host ""

npm cache verify

Write-Host ""
