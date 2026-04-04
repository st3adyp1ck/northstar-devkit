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
.EXAMPLE
    .\Remove-NodeModules.ps1
    .\Remove-NodeModules.ps1 -Path "C:\my-project"
    .\Remove-NodeModules.ps1 -Path "C:\my-project" -Reinstall
#>
[CmdletBinding()]
param(
    [string]$Path = ".",
    [switch]$Reinstall
)

$targetPath = Resolve-Path $Path
$nmPath = Join-Path $targetPath "node_modules"

Write-Host "`nNorthstar DevKit - Delete node_modules`n" -ForegroundColor Cyan
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
Write-Host "  Deleting..." -ForegroundColor Yellow

try {
    Remove-Item -Path $nmPath -Recurse -Force
    Write-Host "  DONE: node_modules deleted." -ForegroundColor Green
} catch {
    Write-Host "  ERROR: $_`n" -ForegroundColor Red
    exit 1
}

if ($Reinstall) {
    Write-Host "`n  Reinstalling dependencies...`n" -ForegroundColor Yellow
    Push-Location $targetPath
    npm install
    Pop-Location
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "`n  DONE: Reinstall complete." -ForegroundColor Green
    } else {
        Write-Host "`n  ERROR: npm install failed." -ForegroundColor Red
    }
}

Write-Host ""
