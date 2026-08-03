#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Show Excluded Port Ranges - Northstar DevKit
.DESCRIPTION
    Lists the TCP port ranges Windows has reserved (the Hyper-V/winnat
    "excluded port ranges") and flags which common dev ports fall inside
    one. This is the classic reason a dev server fails to bind with
    EACCES / WinError 10013 even though no process is listening on the port.

    Fully read-only: runs 'netsh interface ipv4 show excludedportrange
    protocol=tcp', a 'show' command that needs no admin rights and changes
    nothing.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Port
    Check a single port only: prints whether it is reserved and exits 0 when
    the port is free, 1 when it is reserved (useful for scripts).
.EXAMPLE
    .\Show-ExcludedPortRanges.ps1
    .\Show-ExcludedPortRanges.ps1 -Port 3000
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 65535)]
    [int]$Port
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) {
    . $CommonModule
} else {
    Write-Host "ERROR: Required module not found: $CommonModule" -ForegroundColor Red
    exit 1
}

# Same list Scan-Ports.ps1 scans.
$CommonPorts = @(3000, 3001, 3002, 3003, 5173, 5174, 8000, 8080, 8081, 9000, 4200, 5000, 5500, 1337, 5432, 3306, 6379, 27017)

Write-DevKitHeader "Excluded Port Ranges (Hyper-V/winnat)"

if (-not (Get-Command ConvertFrom-DevKitExcludedPortRanges -ErrorAction SilentlyContinue)) {
    Write-DevKitError "ConvertFrom-DevKitExcludedPortRanges is missing from lib/DevKit-Common.ps1 - update DevKit."
    exit 1
}

if (-not (Test-DevKitCommand "netsh")) {
    Write-DevKitError "netsh not found on this system."
    exit 1
}

Write-DevKitStep "Querying reserved TCP port ranges"
$raw = netsh interface ipv4 show excludedportrange protocol=tcp 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-DevKitError "netsh failed to report excluded port ranges (exit code $LASTEXITCODE)."
    exit 1
}
Write-DevKitDone

# The parser returns ,$results (a single array object) so a one-range result
# stays an array - assign directly; wrapping in @() here would nest it.
$ranges = ConvertFrom-DevKitExcludedPortRanges -Output ($raw -join "`n")

# Single-port mode: report just this port and signal the result via exit code.
if ($Port) {
    $hit = $null
    foreach ($r in $ranges) {
        if ($Port -ge $r.Start -and $Port -le $r.End) { $hit = $r; break }
    }
    if ($hit) {
        Write-Host "  Port $Port is RESERVED (inside excluded range $($hit.Start)-$($hit.End))." -ForegroundColor Yellow
        Write-DevKitInfo "Windows (Hyper-V/winnat) owns this range; binding fails with EACCES / WinError 10013."
        exit 1
    }
    Write-Host "  Port $Port is not reserved by Windows (no excluded range contains it)." -ForegroundColor Green
    exit 0
}

if ($ranges.Count -eq 0) {
    Write-Host "  OK: No excluded TCP port ranges reported - Hyper-V/winnat has nothing reserved." -ForegroundColor Green
    Write-Host ""
    exit 0
}

Write-Host "  Reserved TCP port ranges ($($ranges.Count)):" -ForegroundColor Cyan
foreach ($r in $ranges) {
    Write-Host ("    {0,6} - {1,-6}" -f $r.Start, $r.End) -ForegroundColor Gray
}
Write-Host ""

$blocked = @()
foreach ($p in $CommonPorts) {
    foreach ($r in $ranges) {
        if ($p -ge $r.Start -and $p -le $r.End) {
            $blocked += [PSCustomObject]@{ Port = $p; Start = $r.Start; End = $r.End }
            break
        }
    }
}

if ($blocked.Count -eq 0) {
    Write-Host "  OK: No common dev port falls inside a reserved range." -ForegroundColor Green
} else {
    Write-Host "  WARNING: Common dev ports blocked by a reservation:" -ForegroundColor Yellow
    foreach ($b in $blocked) {
        Write-Host "    $($b.Port)  (inside $($b.Start)-$($b.End))" -ForegroundColor Yellow
    }
    Write-DevKitInfo "Binding one of these fails with EACCES / WinError 10013. Pick a port outside the ranges above,"
    Write-DevKitInfo "or release the reservations with 'net stop winnat' followed by 'net start winnat' (admin)."
}
Write-Host ""
exit 0
