#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Find Stale node_modules - Northstar DevKit
.DESCRIPTION
    Scans a folder tree for node_modules directories and reports how much
    disk space each one holds and how long it has been sitting untouched,
    so you can reclaim space across many projects at once.

    Report-only by default: after the report you'll be asked whether to
    delete the listed folders right away (or pass -Apply to go straight
    to the confirmation gate). Deletion uses the same long-path-safe
    robocopy-mirror method as Remove-NodeModules.ps1.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Path
    The root folder to scan (e.g. your dev/projects folder).
    Defaults to current directory.
.PARAMETER Depth
    How many levels below -Path to look for node_modules folders.
    Defaults to 3.
.PARAMETER Apply
    Delete the found folders instead of only reporting (still asks for
    confirmation unless -Force is passed).
.PARAMETER Force
    Skip the confirmation prompt when used with -Apply.
.EXAMPLE
    .\Find-StaleNodeModules.ps1 -Path "C:\dev"
    .\Find-StaleNodeModules.ps1 -Path "C:\dev" -Depth 4
    .\Find-StaleNodeModules.ps1 -Path "C:\dev" -Apply
#>
[CmdletBinding()]
param(
    [string]$Path = ".",
    [int]$Depth = 3,
    [switch]$Apply,
    [switch]$Force
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

try {
    $targetPath = Resolve-DevKitDirectory -Path $Path
} catch {
    Write-DevKitHeader "Find Stale node_modules"
    Write-DevKitError $_
    exit 1
}

if ($Depth -lt 0) {
    Write-DevKitHeader "Find Stale node_modules"
    Write-DevKitError "Depth must be 0 or greater."
    exit 1
}

Write-DevKitHeader "Find Stale node_modules"
Write-DevKitInfo "Scanning: $targetPath (depth $Depth)"

function Format-DevKitByteSize {
    param([Parameter(Mandatory = $true)][double]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

try {
    Write-DevKitStep "Searching for node_modules folders"
    $found = @(Get-ChildItem -LiteralPath $targetPath -Directory -Filter "node_modules" -Recurse -Depth $Depth -ErrorAction SilentlyContinue)
    Write-DevKitDone

    # Keep only the top-most hit of any nested chain (a node_modules inside
    # another node_modules is reclaimed with its parent anyway).
    $topLevel = @()
    foreach ($dir in ($found | Sort-Object { $_.FullName.Length })) {
        $nested = $false
        foreach ($kept in $topLevel) {
            if ($dir.FullName.StartsWith($kept.FullName + "\", [StringComparison]::OrdinalIgnoreCase)) {
                $nested = $true
                break
            }
        }
        if (-not $nested) { $topLevel += $dir }
    }

    if ($topLevel.Count -eq 0) {
        Write-Host "`n  No node_modules folders found under '$targetPath'.`n" -ForegroundColor Green
        exit 0
    }

    # Measure each folder with robocopy in list-only mode: ~5x faster than a
    # Get-ChildItem walk, byte-identical, junction-skipping, and long-path
    # safe (the same engine the shared delete helper uses). robocopy's
    # summary is localized, so the Bytes row is parsed by shape; if the fast
    # path yields nothing, fall back to the GCI walk (flagged as an estimate,
    # same convention as Remove-NodeModules.ps1's long-path caveat).
    $results = @()
    foreach ($dir in $topLevel) {
        Write-DevKitStep "Measuring $($dir.FullName)"
        $size = $null
        try {
            $rc = & robocopy "$($dir.FullName)" "$($dir.FullName).devkit-null" /L /E /BYTES /NFL /NDL /NJH /XJ /R:0 /W:0 2>$null
            $bytesLine = $rc | Select-String -Pattern 'Bytes\s*:' | Select-Object -First 1
            # First number only (Total column): digits plus the locale's
            # grouping separators, stopping at the multi-space column gap.
            if ($bytesLine -and ($bytesLine.Line -match 'Bytes\s*:\s*([\d\.,]+)')) {
                $size = [double]($Matches[1] -replace '\D', '')
            }
        } catch { }
        $isEstimate = $false
        if ($null -eq $size) {
            $sizeErrors = $null
            $size = (Get-ChildItem $dir.FullName -Recurse -ErrorAction SilentlyContinue -ErrorVariable sizeErrors |
                Measure-Object -Property Length -Sum).Sum
            if ($null -eq $size) { $size = 0 }
            $isEstimate = ($sizeErrors -and $sizeErrors.Count -gt 0)
        }
        Write-DevKitDone

        $results += [PSCustomObject]@{
            Path          = $dir.FullName
            SizeBytes     = [double]$size
            IsEstimate    = $isEstimate
            LastWriteTime = $dir.LastWriteTime
            AgeDays       = [int][math]::Round(((Get-Date) - $dir.LastWriteTime).TotalDays)
        }
    }

    $results = @($results | Sort-Object -Property SizeBytes -Descending)
    $totalBytes = ($results | Measure-Object -Property SizeBytes -Sum).Sum

    Write-Host ""
    Write-Host "  node_modules folders (largest first):" -ForegroundColor Magenta
    Write-Host ""
    foreach ($r in $results) {
        $sizeText = Format-DevKitByteSize $r.SizeBytes
        if ($r.IsEstimate) { $sizeText = "~$sizeText (est.)" }
        Write-Host ("    {0,-14} {1,5} days old  {2}" -f $sizeText, $r.AgeDays, $r.Path) -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host ("  TOTAL reclaimable (est.): {0} across {1} folder(s)" -f (Format-DevKitByteSize $totalBytes), $results.Count) -ForegroundColor Green

    if (-not $Apply) {
        Write-Host ""
        Write-DevKitInfo "Report only - nothing was deleted."
        if ([Console]::IsInputRedirected) {
            Write-DevKitInfo "Re-run with -Apply to delete."
            exit 0
        }
        $answer = Read-Host "  Delete all $($results.Count) listed folder(s) now? (y/N)"
        if ($answer -ne 'y') {
            Write-DevKitInfo "No changes made."
            exit 0
        }
    }

    $proceed = Confirm-DevKitDestructiveAction -Action "permanently delete $($results.Count) node_modules folder(s), reclaiming roughly $(Format-DevKitByteSize $totalBytes)" `
        -AffectedPaths ($results | ForEach-Object { $_.Path }) -Force:$Force
    if (-not $proceed) {
        Write-Host ""
        Write-DevKitInfo "Cancelled - no changes made."
        exit 0
    }

    Write-Host ""
    $deleted = 0
    foreach ($r in $results) {
        $projectDir = Split-Path -Parent $r.Path
        Write-DevKitStep "Deleting $($r.Path)"
        try {
            if (Remove-DevKitNodeModules -Path $projectDir) {
                Write-DevKitDone
                $deleted++
            } else {
                Write-DevKitSkip
            }
        } catch {
            Write-DevKitError $_
        }
    }

    Write-Host ""
    Write-Host "  Deleted $deleted of $($results.Count) folder(s)." -ForegroundColor Green
    Write-Host ""
    exit 0
} catch {
    Write-DevKitError "Unexpected failure: $_"
    exit 1
}
