#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Clear Disk Junk - Northstar DevKit
.DESCRIPTION
    Scans common Windows junk locations (user/system temp folders, the
    Windows Update download cache, and the Recycle Bin) and reports how much
    space each is holding. Nothing is deleted by default - after the report
    you'll be asked whether to clean up right away (or pass -Apply to clean
    without the report-first prompt, after a typed confirmation).

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Apply
    Actually delete the junk instead of only reporting sizes.
.PARAMETER IncludeWinSxS
    Also run the WinSxS component store cleanup via Dism.exe. Requires an
    elevated (Administrator) session; skipped with a notice otherwise.
.PARAMETER Force
    Skip the confirmation prompt when used with -Apply.
.EXAMPLE
    .\Clear-DiskJunk.ps1
    .\Clear-DiskJunk.ps1 -Apply
    .\Clear-DiskJunk.ps1 -Apply -IncludeWinSxS -Force
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$IncludeWinSxS,
    [switch]$Force
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

Write-DevKitHeader "Clear Disk Junk"

function Format-DevKitByteSize {
    param([Parameter(Mandatory = $true)][double]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Get-DevKitJunkPathSize {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $total = 0
    try {
        $items = Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue
        foreach ($item in $items) { $total += $item.Length }
    } catch {
        # Enumerating the root itself failed (e.g. a broken reparse point) -
        # treat as 0 rather than aborting the whole scan.
    }
    return $total
}

function Get-DevKitRecycleBinSize {
    $shell = $null
    try {
        $shell = New-Object -ComObject Shell.Application
        $recycleBin = $shell.Namespace(10)
        if (-not $recycleBin) { return 0 }
        $total = 0
        foreach ($item in $recycleBin.Items()) { $total += $item.Size }
        return $total
    } catch {
        Write-DevKitInfo "Could not read Recycle Bin size (COM error): $_"
        return 0
    } finally {
        if ($shell) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
    }
}

function Get-DevKitJunkScan {
    param(
        [Parameter(Mandatory = $true)][string[]]$TempPaths,
        [Parameter(Mandatory = $true)][string]$WuCachePath
    )
    $tempBytes = 0
    foreach ($p in $TempPaths) { $tempBytes += Get-DevKitJunkPathSize -Path $p }
    $wuBytes = Get-DevKitJunkPathSize -Path $WuCachePath
    $recycleBytes = Get-DevKitRecycleBinSize
    return [PSCustomObject]@{
        TempBytes    = $tempBytes
        WuBytes      = $wuBytes
        RecycleBytes = $recycleBytes
        TotalBytes   = $tempBytes + $wuBytes + $recycleBytes
    }
}

try {
    $tempPaths = @($env:TEMP, (Join-Path $env:SystemRoot "Temp")) | Select-Object -Unique
    $wuCachePath = Join-Path (Join-Path $env:SystemRoot "SoftwareDistribution") "Download"

    Write-DevKitStep "Scanning junk locations"
    $scan = Get-DevKitJunkScan -TempPaths $tempPaths -WuCachePath $wuCachePath
    Write-DevKitDone

    Write-Host ""
    Write-Host "  Candidate junk locations:" -ForegroundColor Magenta
    Write-Host ("    {0,-38} {1}" -f "Temp folders (user + Windows)", (Format-DevKitByteSize $scan.TempBytes))
    Write-Host ("    {0,-38} {1}" -f "Windows Update cache", (Format-DevKitByteSize $scan.WuBytes))
    Write-Host ("    {0,-38} {1}" -f "Recycle Bin", (Format-DevKitByteSize $scan.RecycleBytes))
    Write-Host ""
    Write-Host ("    {0,-38} {1}" -f "TOTAL reclaimable (est.)", (Format-DevKitByteSize $scan.TotalBytes)) -ForegroundColor Green

    if (-not $Apply) {
        Write-Host ""
        Write-DevKitInfo "Report only - nothing was deleted."
        if ([Console]::IsInputRedirected) {
            Write-DevKitInfo "Re-run with -Apply to clean."
            exit 0
        }
        $answer = Read-Host "  Clean up now? (y/N)"
        if ($answer -ne 'y') {
            Write-DevKitInfo "No changes made."
            exit 0
        }
    }

    $proceed = Confirm-DevKitDestructiveAction -Action "delete temp files, the Windows Update cache, and empty the Recycle Bin" `
        -TypedPhrase 'CLEAN' -Force:$Force
    if (-not $proceed) {
        Write-Host ""
        Write-DevKitInfo "Cancelled - no changes made."
        exit 0
    }

    Write-Host ""
    $isAdmin = Test-DevKitAdmin
    foreach ($p in $tempPaths) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        # Windows\Temp deletes silently no-op without elevation (every failure
        # is swallowed by -ErrorAction SilentlyContinue) while printing DONE.
        if ($p -like "$($env:SystemRoot)*" -and -not $isAdmin) {
            Write-Host "  SKIP: $p (requires an elevated session)" -ForegroundColor Yellow
            continue
        }
        Write-DevKitStep "Cleaning $p"
        try {
            Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue | ForEach-Object {
                Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
            Write-DevKitDone
        } catch {
            Write-DevKitError "Failed cleaning '$p': $_"
        }
    }

    # Stopping WU services and clearing the Windows Update cache require
    # elevation - without it these steps silently no-op (every failure is
    # swallowed by -ErrorAction SilentlyContinue) while still printing DONE.
    if (Test-DevKitAdmin) {
        Write-DevKitStep "Stopping Windows Update services"
        try {
            Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
            Stop-Service -Name bits -Force -ErrorAction SilentlyContinue
            Write-DevKitDone
        } catch {
            Write-DevKitError "Could not stop Windows Update services: $_"
        }

        Write-DevKitStep "Clearing Windows Update cache"
        try {
            if (Test-Path -LiteralPath $wuCachePath) {
                Get-ChildItem -LiteralPath $wuCachePath -Force -ErrorAction SilentlyContinue | ForEach-Object {
                    Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
            Write-DevKitDone
        } catch {
            Write-DevKitError "Could not clear Windows Update cache: $_"
        }

        Write-DevKitStep "Restarting Windows Update services"
        try {
            # bits started before wuauserv: wuauserv can depend on bits being up.
            Start-Service -Name bits -ErrorAction SilentlyContinue
            Start-Service -Name wuauserv -ErrorAction SilentlyContinue
            Write-DevKitDone
        } catch {
            Write-DevKitError "Could not restart Windows Update services: $_"
        }
    } else {
        Write-Host "  SKIP: Clearing the Windows Update cache requires an elevated (Administrator) session. Re-run as Administrator to clean it." -ForegroundColor Yellow
    }

    Write-DevKitStep "Emptying Recycle Bin"
    try {
        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
        Write-DevKitDone
    } catch {
        Write-DevKitError "Could not empty Recycle Bin: $_"
    }

    if ($IncludeWinSxS) {
        Write-Host ""
        if (Test-DevKitAdmin) {
            Write-Host "  Running DISM component cleanup (streaming output below)..." -ForegroundColor Cyan
            try {
                & Dism.exe /Online /Cleanup-Image /StartComponentCleanup
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "  DISM component cleanup completed." -ForegroundColor Green
                } else {
                    Write-DevKitError "Dism.exe exited with code $LASTEXITCODE"
                }
            } catch {
                Write-DevKitError "Dism.exe failed: $_"
            }
        } else {
            Write-Host "  SKIP: WinSxS cleanup requires an elevated (Administrator) session. Re-run as Administrator with -IncludeWinSxS." -ForegroundColor Yellow
        }
    }

    Write-Host ""
    Write-DevKitStep "Re-scanning to measure freed space"
    $after = Get-DevKitJunkScan -TempPaths $tempPaths -WuCachePath $wuCachePath
    Write-DevKitDone

    $freed = $scan.TotalBytes - $after.TotalBytes
    if ($freed -lt 0) { $freed = 0 }

    Write-Host ""
    Write-Host "  Freed approximately $(Format-DevKitByteSize $freed)" -ForegroundColor Green

    exit 0
} catch {
    Write-DevKitError "Unexpected failure: $_"
    exit 1
}
