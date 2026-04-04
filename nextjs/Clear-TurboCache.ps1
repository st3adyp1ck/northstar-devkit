#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Clear Turbopack Cache - Northstar DevKit
.DESCRIPTION
    Deletes Turbopack and webpack caches from various locations.
    
    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Path
    The project directory. Defaults to current directory.
.EXAMPLE
    .\Clear-TurboCache.ps1
#>
[CmdletBinding()]
param(
    [string]$Path = "."
)

$targetPath = Resolve-Path $Path

Write-Host "`nNorthstar DevKit - Clear Turbopack Cache`n" -ForegroundColor Cyan
Write-Host "  Path: $targetPath`n" -ForegroundColor Gray

$cachePaths = @(
    (Join-Path $targetPath ".next\cache"),
    (Join-Path $targetPath ".next\webpack"),
    (Join-Path $targetPath "node_modules\.cache"),
    (Join-Path $targetPath ".turbo")
)

$found = $false
$totalSize = 0

foreach ($cachePath in $cachePaths) {
    if (Test-Path $cachePath) {
        $found = $true
        $size = (Get-ChildItem $cachePath -Recurse -ErrorAction SilentlyContinue | 
            Measure-Object -Property Length -Sum).Sum
        $sizeMB = if ($size) { [math]::Round($size / 1MB, 2) } else { 0 }
        $totalSize += $sizeMB
        
        Write-Host "  Deleting: $cachePath ($sizeMB MB)" -ForegroundColor Yellow
        Remove-Item -Path $cachePath -Recurse -Force
    }
}

if ($found) {
    Write-Host "`n  DONE: Turbopack caches cleared ($totalSize MB freed).`n" -ForegroundColor Green
} else {
    Write-Host "  WARNING: No Turbopack caches found.`n" -ForegroundColor Yellow
}
