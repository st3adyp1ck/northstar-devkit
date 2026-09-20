#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Disk Usage Report - Northstar DevKit
.DESCRIPTION
    Read-only report of the biggest immediate subfolders under a path, sorted
    by size descending. Never prompts and never deletes or modifies anything.
    By default each subfolder is measured to a depth of 2 levels (sizes are
    then an estimate of the real total); pass -Full for a complete recursive
    measure, which can take several minutes on a system drive.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Path
    Root path to scan. Defaults to the system drive root (e.g. C:\).
.PARAMETER Top
    How many of the largest subfolders to display.
.PARAMETER Depth
    How many directory levels below each immediate subfolder to measure
    (default 2). Sizes treat anything deeper as excluded, so with a small
    depth they are estimates of the real totals - fine for ranking what to
    investigate, not exact byte counts. Ignored when -Full is passed.
.PARAMETER Full
    Measure each subfolder fully recursively (the old default). This can
    take several minutes on a system drive.
.EXAMPLE
    .\Show-DiskUsageReport.ps1
    .\Show-DiskUsageReport.ps1 -Path "D:\" -Top 25
    .\Show-DiskUsageReport.ps1 -Full
#>
[CmdletBinding()]
param(
    [string]$Path = $env:SystemDrive + "\",
    [int]$Top = 15,
    [int]$Depth = 2,
    [switch]$Full
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

Write-DevKitHeader "Disk Usage Report"

if ($Top -lt 1) {
    Write-DevKitError "Top must be a positive number."
    exit 1
}

if ($Depth -lt 1) {
    Write-DevKitError "Depth must be a positive number (or pass -Full for a complete recursive scan)."
    exit 1
}

function Format-DevKitByteSize {
    param([Parameter(Mandatory = $true)][double]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Get-DevKitFolderSize {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        # Depth 1 = the folder's own files only; each extra level descends
        # one more directory. Sizes are then estimates of the real totals,
        # which is the point: ranking what to investigate must not require
        # a multi-minute full recursion of e.g. C:\Program Files.
        [Parameter(Mandatory = $true)][int]$Depth,
        [switch]$Full
    )
    $total = 0
    try {
        $gciParams = @{
            LiteralPath = $Path
            Recurse     = $true
            Force       = $true
            File        = $true
            ErrorAction = 'SilentlyContinue'
        }
        if (-not $Full) { $gciParams['Depth'] = $Depth - 1 }
        $items = Get-ChildItem @gciParams
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

    if ($Full) {
        Write-DevKitStep "Measuring $($subfolders.Count) subfolder(s) FULLY recursive (this can take a while)"
    } else {
        Write-DevKitStep "Measuring $($subfolders.Count) subfolder(s) to depth $Depth (this can take a while; pass -Full for exact recursive sizes)"
    }
    $results = @()
    foreach ($folder in $subfolders) {
        $size = Get-DevKitFolderSize -Path $folder.FullName -Depth $Depth -Full:$Full
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
    if (-not $Full) {
        Write-DevKitInfo "Sizes measured to depth $Depth - deeper content is excluded (pass -Full for exact recursive totals)."
    }

    exit 0
} catch {
    Write-DevKitError "Unexpected failure: $_"
    exit 1
}
