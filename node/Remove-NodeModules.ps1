#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Remove Node Modules - Northstar DevKit
.DESCRIPTION
    Recursively deletes node_modules from the specified path.
    
    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Path
    The project directory containing node_modules.
    Defaults to current directory.
.PARAMETER Reinstall
    Reinstall dependencies after deletion.
.PARAMETER Force
    Skip confirmation prompt.
.EXAMPLE
    .\Remove-NodeModules.ps1
    .\Remove-NodeModules.ps1 -Path "C:\my-project"
    .\Remove-NodeModules.ps1 -Reinstall -Force
#>
[CmdletBinding()]
param(
    [string]$Path = ".",
    [switch]$Reinstall,
    [switch]$Force
)

Write-Host "`nNorthstar DevKit - Delete node_modules`n" -ForegroundColor Cyan

if (-not (Test-Path $Path)) {
    Write-Host "  ERROR: Path not found: $Path`n" -ForegroundColor Red
    exit 1
}
$targetPath = (Resolve-Path $Path).Path
$nmPath = Join-Path $targetPath "node_modules"

Write-Host "  Path: $targetPath`n" -ForegroundColor Gray

if (-not (Test-Path $nmPath)) {
    Write-Host "  ERROR: node_modules not found.`n" -ForegroundColor Red
    exit 1
}

# Calculate size before deletion
$size = (Get-ChildItem $nmPath -Recurse -ErrorAction SilentlyContinue | 
    Measure-Object -Property Length -Sum).Sum
$sizeMB = [math]::Round($size / 1MB, 2)

Write-Host "  Size: $sizeMB MB" -ForegroundColor Yellow

if (-not $Force) {
    $confirm = Read-Host "  Delete node_modules? (y/n)"
    if ($confirm -ne 'y') {
        Write-Host "  Cancelled.`n" -ForegroundColor Gray
        exit 0
    }
}

Write-Host "  Deleting..." -ForegroundColor Yellow

try {
    # Use robocopy empty-folder trick for long-path safety
    $empty = Join-Path $env:TEMP "empty_devkit_$(Get-Random)"
    New-Item -ItemType Directory -Path $empty -Force | Out-Null
    robocopy $empty $nmPath /MIR /MT:8 /NFL /NDL /NJH /NJS | Out-Null
    Remove-Item -Path $nmPath -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $empty -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "  DONE: node_modules deleted." -ForegroundColor Green
} catch {
    Write-Host "  ERROR: $_`n" -ForegroundColor Red
    exit 1
}

if ($Reinstall) {
    Write-Host "`n  Reinstalling dependencies...`n" -ForegroundColor Yellow
    try {
        Push-Location $targetPath
        npm install
        if ($LASTEXITCODE -ne 0) {
            Write-Host "`n  ERROR: npm install failed.`n" -ForegroundColor Red
            exit 1
        }
        Write-Host "`n  DONE: Reinstall complete." -ForegroundColor Green
    } finally {
        Pop-Location
    }
}

Write-Host ""
