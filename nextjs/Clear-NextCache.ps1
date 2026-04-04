#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Clear Next.js Cache - Northstar DevKit
.DESCRIPTION
    Deletes the .next build directory to force a fresh build.
    
    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Path
    The project directory. Defaults to current directory.
.PARAMETER StartDev
    Start dev server after clearing cache.
.EXAMPLE
    .\Clear-NextCache.ps1
    .\Clear-NextCache.ps1 -StartDev
#>
[CmdletBinding()]
param(
    [string]$Path = ".",
    [switch]$StartDev
)

$targetPath = Resolve-Path $Path
$nextPath = Join-Path $targetPath ".next"

Write-Host "`nNorthstar DevKit - Clear Next.js Cache`n" -ForegroundColor Cyan
Write-Host "  Path: $targetPath`n" -ForegroundColor Gray

if (-not (Test-Path $nextPath)) {
    Write-Host "  WARNING: .next folder not found.`n" -ForegroundColor Yellow
} else {
    # Calculate size
    $size = (Get-ChildItem $nextPath -Recurse -ErrorAction SilentlyContinue | 
        Measure-Object -Property Length -Sum).Sum
    $sizeMB = if ($size) { [math]::Round($size / 1MB, 2) } else { 0 }
    
    Write-Host "  Cache size: $sizeMB MB" -ForegroundColor Gray
    Write-Host "  Deleting..." -ForegroundColor Yellow
    
    try {
        Remove-Item -Path $nextPath -Recurse -Force
        Write-Host "  DONE: .next cache cleared.`n" -ForegroundColor Green
    } catch {
        Write-Host "  ERROR: $_`n" -ForegroundColor Red
        exit 1
    }
}

if ($StartDev) {
    Write-Host "  Starting dev server...`n" -ForegroundColor Green
    Push-Location $targetPath
    npm run dev
    Pop-Location
}
