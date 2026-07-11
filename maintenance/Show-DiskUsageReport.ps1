#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Disk Usage Report - Northstar DevKit
.DESCRIPTION
    Read-only report of the biggest immediate subfolders under a path, sorted
    by size descending. Never prompts and never deletes or modifies anything.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Path
    Root path to scan. Defaults to the system drive root (e.g. C:\).
.PARAMETER Top
    How many of the largest subfolders to display.
.EXAMPLE
    .\Show-DiskUsageReport.ps1
    .\Show-DiskUsageReport.ps1 -Path "D:\" -Top 25
#>
[CmdletBinding()]
param(
    [string]$Path = $env:SystemDrive + "\",
    [int]$Top = 15
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

Write-DevKitHeader "Disk Usage Report"

function Format-DevKitByteSize {
    param([Parameter(Mandatory = $true)][double]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Get-DevKitFolderSize {
    param([Parameter(Mandatory = $true)][string]$Path)
    $total = 0
    try {
        $items = Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue
        foreach ($item in $items) { $total += $item.Length }
    } catch {
        # A hard failure enumerating this one subfolder (e.g. access denied
        # partway through) must not abort the whole report.
    }
    return $total
}

try {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        Write-DevKitError "Path not found: $Path"
        exit 1
    }

    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path

    Write-DevKitStep "Enumerating subfolders of $resolvedPath"
    $subfolders = @()
    try {
        $subfolders = @(Get-ChildItem -LiteralPath $resolvedPath -Directory -Force -ErrorAction SilentlyContinue)
        Write-DevKitDone
    } catch {
        Write-DevKitError "Could not enumerate '$resolvedPath': $_"
        exit 1
    }

    if ($subfolders.Count -eq 0) {
        Write-DevKitInfo "No subfolders found under $resolvedPath."
        exit 0
    }

    Write-DevKitStep "Measuring $($subfolders.Count) subfolder(s) (this can take a while)"
    $results = @()
    foreach ($folder in $subfolders) {
        $size = Get-DevKitFolderSize -Path $folder.FullName
        $results += [PSCustomObject]@{ Path = $folder.FullName; Bytes = $size }
    }
    Write-DevKitDone

    $sorted = $results | Sort-Object -Property Bytes -Descending
    $topResults = $sorted | Select-Object -First $Top

    Write-Host ""
    Write-Host "  Top $Top subfolder(s) under $resolvedPath by size:" -ForegroundColor Magenta
    Write-Host ""
    foreach ($r in $topResults) {
        Write-Host ("    {0,-12} {1}" -f (Format-DevKitByteSize $r.Bytes), $r.Path)
    }

    $totalBytes = ($results | Measure-Object -Property Bytes -Sum).Sum
    if (-not $totalBytes) { $totalBytes = 0 }

    Write-Host ""
    Write-Host ("  Total across {0} subfolder(s): {1}" -f $results.Count, (Format-DevKitByteSize $totalBytes)) -ForegroundColor Green

    exit 0
} catch {
    Write-DevKitError "Unexpected failure: $_"
    exit 1
}
