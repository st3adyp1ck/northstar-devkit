#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Clear Next.js Cache - Northstar DevKit
.DESCRIPTION
    Deletes the .next build cache directory.
    
    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Path
    The project directory. Defaults to current directory.
.PARAMETER Force
    Skip confirmation prompt.
.EXAMPLE
    .\Clear-NextCache.ps1
    .\Clear-NextCache.ps1 -Path "C:\my-project"
    .\Clear-NextCache.ps1 -Force
#>
[CmdletBinding()]
param(
    [string]$Path = ".",
    [switch]$Force
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

try {
    $targetPath = Resolve-DevKitDirectory -Path $Path
} catch {
    Write-DevKitHeader "Clear Next.js Cache"
    Write-DevKitError $_
    exit 1
}

Write-DevKitHeader "Clear Next.js Cache"

$nextPath = Join-Path $targetPath ".next"
if (-not (Test-Path $nextPath)) {
    Write-DevKitInfo ".next folder not found."
    exit 0
}

if (-not $Force) {
    $confirm = Read-Host "  Delete .next folder? (y/n)"
    if ($confirm -ne 'y') {
        Write-DevKitInfo "Cancelled."
        exit 0
    }
}

Write-DevKitStep "Deleting .next folder"
try {
    Remove-Item -Path $nextPath -Recurse -Force -ErrorAction Stop
} catch {
    # Fall through to the Test-Path check below to decide success.
}

if (-not (Test-Path $nextPath)) {
    Write-DevKitDone
} else {
    Write-DevKitError "Could not fully delete .next folder. Stop the dev server and try again."
}

Write-Host ""
