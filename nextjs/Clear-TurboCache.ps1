#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Clear Turbopack Cache - Northstar DevKit
.DESCRIPTION
    Deletes Turbopack and related build caches.
    
    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Path
    The project directory. Defaults to current directory.
.PARAMETER Force
    Skip confirmation prompt.
.EXAMPLE
    .\Clear-TurboCache.ps1
    .\Clear-TurboCache.ps1 -Path "C:\my-project"
    .\Clear-TurboCache.ps1 -Force
#>
[CmdletBinding()]
param(
    [string]$Path = ".",
    [switch]$Force
)

$CommonModule = Join-Path $PSScriptRoot ".." "lib" "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

try {
    $targetPath = Resolve-DevKitDirectory -Path $Path
} catch {
    Write-DevKitHeader "Clear Turbopack Cache"
    Write-DevKitError $_
    exit 1
}

Write-DevKitHeader "Clear Turbopack Cache"

$cachePaths = @(
    (Join-Path $targetPath ".next" "cache"),
    (Join-Path $targetPath "node_modules" ".cache"),
    (Join-Path $targetPath ".turbo")
)

$found = $false
foreach ($cachePath in $cachePaths) {
    if (Test-Path $cachePath) {
        if (-not $found) {
            $found = $true
            if (-not $Force) {
                $confirm = Read-Host "  Delete Turbopack caches? (y/n)"
                if ($confirm -ne 'y') {
                    Write-DevKitInfo "Cancelled."
                    exit 0
                }
            }
        }
        Write-DevKitStep "Deleting $cachePath"
        Remove-Item -Path $cachePath -Recurse -Force
        Write-DevKitDone
    }
}

if (-not $found) {
    Write-DevKitInfo "No Turbopack caches found."
}

Write-Host ""
