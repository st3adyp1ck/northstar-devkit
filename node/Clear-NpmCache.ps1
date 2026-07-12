#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Clear NPM Cache - Northstar DevKit
.DESCRIPTION
    Cleans the local package manager cache for the project at -Path.
    Auto-detects npm/yarn/pnpm/bun from lock files (same detection used
    across the rest of DevKit) and dispatches to the matching cache-clean
    command, so this works on non-npm projects too.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Path
    The project directory whose package manager cache to clean.
    Defaults to current directory.
.PARAMETER Verify
    Also run cache verification after cleaning (npm only - other package
    managers do not expose an equivalent verify command).
.EXAMPLE
    .\Clear-NpmCache.ps1
    .\Clear-NpmCache.ps1 -Path "C:\my-project"
    .\Clear-NpmCache.ps1 -Verify
#>
[CmdletBinding()]
param(
    [string]$Path = ".",
    [switch]$Verify
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

Write-DevKitHeader "Clear Package Manager Cache"

try {
    $targetPath = Resolve-DevKitDirectory -Path $Path
} catch {
    Write-DevKitError $_
    exit 1
}

$manager = Get-DevKitPackageManager -Path $targetPath
Write-DevKitInfo "Package manager: $($manager.Command)"

Write-DevKitStep "Cleaning $($manager.Command) cache"
try {
    Invoke-DevKitPackageCacheClean -Path $targetPath -Manager $manager
    Write-DevKitDone
} catch {
    Write-DevKitError $_
    exit 1
}

if ($Verify) {
    if ($manager.Command -eq "npm") {
        Write-DevKitStep "Running npm cache verify"
        npm cache verify
    } else {
        Write-DevKitInfo "-Verify is only supported for npm; $($manager.Command) has no equivalent command."
    }
}

Write-Host ""
