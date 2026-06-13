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

$CommonModule = Join-Path $PSScriptRoot ".." "lib" "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

try {
    $targetPath = Resolve-DevKitDirectory -Path $Path
} catch {
    Write-DevKitHeader "Delete node_modules"
    Write-DevKitError $_
    exit 1
}

Write-DevKitHeader "Delete node_modules"
Write-DevKitInfo "Path: $targetPath"

$nmPath = Join-Path $targetPath "node_modules"
if (-not (Test-Path $nmPath)) {
    Write-DevKitError "node_modules not found."
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
        Write-DevKitInfo "Cancelled."
        exit 0
    }
}

Write-DevKitStep "Deleting node_modules"
try {
    if (Remove-DevKitNodeModules -Path $targetPath) {
        Write-DevKitDone
    } else {
        Write-DevKitSkip
    }
} catch {
    Write-DevKitError $_
    exit 1
}

if ($Reinstall) {
    Write-Host "`n  Reinstalling dependencies..." -ForegroundColor Yellow
    try {
        Invoke-DevKitInDirectory -Path $targetPath -ScriptBlock {
            Invoke-DevKitPackageInstall -Path .
        }
        Write-Host "`n  DONE: Reinstall complete." -ForegroundColor Green
    } catch {
        Write-DevKitError $_
        exit 1
    }
}

Write-Host ""
