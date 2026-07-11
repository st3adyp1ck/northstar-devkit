#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Recent Event Errors - Northstar DevKit
.DESCRIPTION
    Reports Critical and Error level events from the System and Application
    Windows event logs within a recent time window. Pure read-only - never
    modifies anything.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Hours
    How many hours back to look. Defaults to 24.
.PARAMETER MaxEvents
    Maximum number of events to return. Defaults to 50.
.EXAMPLE
    .\Get-RecentEventErrors.ps1
    .\Get-RecentEventErrors.ps1 -Hours 72
    .\Get-RecentEventErrors.ps1 -Hours 6 -MaxEvents 100
#>
[CmdletBinding()]
param(
    [int]$Hours = 24,
    [int]$MaxEvents = 50
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

Write-DevKitHeader "Recent Event Errors"

if ($Hours -le 0) {
    Write-DevKitError "Hours must be a positive number."
    exit 1
}
if ($MaxEvents -le 0) {
    Write-DevKitError "MaxEvents must be a positive number."
    exit 1
}

Write-DevKitStep "Querying System/Application logs for the last $Hours hour(s)"
try {
    $events = @(Get-WinEvent -FilterHashtable @{
        LogName   = 'System', 'Application'
        Level     = 1, 2
        StartTime = (Get-Date).AddHours(-$Hours)
    } -MaxEvents $MaxEvents -ErrorAction Stop)
    Write-DevKitDone
} catch {
    # Get-WinEvent throws "No events were found" (rather than returning an
    # empty collection) when the filter matches nothing - that's a normal,
    # benign outcome here, not a script failure.
    if ($_.Exception.Message -match 'No events were found') {
        Write-DevKitDone
        Write-DevKitInfo "No Critical/Error events in the last $Hours hour(s)."
        exit 0
    }
    Write-DevKitError "Failed to query the event log: $_"
    exit 1
}

if ($events.Count -eq 0) {
    Write-DevKitInfo "No Critical/Error events in the last $Hours hour(s)."
    exit 0
}

Write-Host ""
Write-Host ("  {0,-20} {1,-12} {2,-9} {3,-25} {4}" -f "TimeCreated", "LogName", "Id", "ProviderName", "Message") -ForegroundColor Magenta
Write-Host ("  {0,-20} {1,-12} {2,-9} {3,-25} {4}" -f "-----------", "-------", "--", "------------", "-------") -ForegroundColor Magenta

foreach ($evt in $events) {
    $msg = $evt.Message
    if ($msg) {
        $msg = ($msg -replace '\s+', ' ').Trim()
        if ($msg.Length -gt 120) { $msg = $msg.Substring(0, 120) + "..." }
    } else {
        $msg = "(no message)"
    }

    $providerName = if ($evt.ProviderName) { $evt.ProviderName } else { "Unknown" }
    $timeText = $evt.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')

    Write-Host ("  {0,-20} {1,-12} {2,-9} {3,-25} " -f $timeText, $evt.LogName, $evt.Id, $providerName) -NoNewline -ForegroundColor Red
    Write-Host $msg -ForegroundColor Gray
}

Write-Host ""
Write-DevKitInfo "$($events.Count) event(s) shown (max $MaxEvents)."
exit 0
