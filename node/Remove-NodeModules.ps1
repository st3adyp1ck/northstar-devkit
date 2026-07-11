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

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
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
    if ($Reinstall) {
        # Nothing to delete (e.g. a fresh clone), but the caller explicitly
        # asked to reinstall - skip the delete step and fall through instead
        # of hard-exiting on them.
        Write-DevKitInfo "node_modules not found - nothing to delete."
        Write-DevKitStep "Deleting node_modules"
        Write-DevKitSkip
    } else {
        Write-DevKitError "node_modules not found."
        exit 1
    }
} else {
    # Calculate size before deletion. Get-ChildItem is not long-path safe and
    # silently swallows PathTooLongException via -ErrorAction, which can
    # understate the reported size - flag the number as an estimate when
    # that happens rather than reporting it as exact.
    $sizeErrors = $null
    $size = (Get-ChildItem $nmPath -Recurse -ErrorAction SilentlyContinue -ErrorVariable sizeErrors |
        Measure-Object -Property Length -Sum).Sum
    $sizeMB = [math]::Round($size / 1MB, 2)

    if ($sizeErrors -and $sizeErrors.Count -gt 0) {
        Write-Host "  Size: ~$sizeMB MB (estimate - some paths could not be read, e.g. long paths)" -ForegroundColor Yellow
    } else {
        Write-Host "  Size: $sizeMB MB" -ForegroundColor Yellow
    }

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
