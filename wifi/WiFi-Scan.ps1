#!/usr/bin/env pwsh
<#
.SYNOPSIS
    WiFi Scanner - Northstar DevKit
.DESCRIPTION
    Shows nearby WiFi networks with signal strength and channel info.
    Helps you pick the best network or ask for the right password.
    
    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.EXAMPLE
    .\WiFi-Scan.ps1
#>

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

function ConvertFrom-DevKitWlanScan {
    <#
    .SYNOPSIS
        Parses "netsh wlan show networks mode=Bssid" text output into network objects.
    .DESCRIPTION
        Line-classification parser for netsh WLAN scan output, extracted into its own
        function so it can be unit tested against fixture text without real WiFi
        hardware or netsh.exe.

        The BSSID line check runs BEFORE the SSID line check on purpose: the SSID
        pattern ("SSID\s+\d+\s+:\s+(.+)") is unanchored, so it also matches inside
        "    BSSID 1  : aa:bb:cc:dd:ee:ff" lines (the substring "SSID" starts at
        position 1 of "BSSID"). If SSID were tested first, every BSSID line would be
        misclassified as the start of a brand-new network named after a MAC address,
        and no network would ever get its BSSID/Signal/Channel data recorded.
    .PARAMETER RawOutput
        The raw text captured from `netsh wlan show networks mode=Bssid`.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$RawOutput
    )

    $lines = $RawOutput -split "`r`n"
    $currentNet = $null
    $results = @()

    foreach ($line in $lines) {
        if ($line -match "BSSID\s+\d+\s+:\s+(.+)") {
            if ($currentNet) {
                $currentNet.CurrentBSSID = @{ MAC = $matches[1].Trim(); Signal = 0; Channel = 0 }
            }
        }
        elseif ($line -match "SSID\s+\d+\s+:\s+(.+)") {
            $currentNet = @{ SSID = $matches[1].Trim(); BSSIDs = @() }
        }
        elseif ($line -match "Authentication\s+:\s+(.+)") {
            if ($currentNet) { $currentNet.Auth = $matches[1].Trim() }
        }
        elseif ($line -match "Signal\s+:\s+(\d+)") {
            if ($currentNet -and $currentNet.CurrentBSSID) {
                $currentNet.CurrentBSSID.Signal = [int]$matches[1]
            }
        }
        elseif ($line -match "Channel\s+:\s+(\d+)") {
            if ($currentNet -and $currentNet.CurrentBSSID) {
                $currentNet.CurrentBSSID.Channel = [int]$matches[1]
                $currentNet.BSSIDs += $currentNet.CurrentBSSID
            }
        }
        elseif ($line -match "^$" -and $currentNet -and $currentNet.BSSIDs.Count -gt 0) {
            $results += $currentNet
            $currentNet = $null
        }
    }

    if ($currentNet -and $currentNet.BSSIDs.Count -gt 0) {
        $results += $currentNet
    }

    return $results
}

# Skip the interactive scan when this script is dot-sourced (e.g. by
# tests/Unit/WiFiScan-Parser.Tests.ps1, which dot-sources this file purely to
# unit test ConvertFrom-DevKitWlanScan) so tests never need real WiFi hardware,
# netsh.exe, or hit the Read-Host prompt below.
if ($MyInvocation.InvocationName -eq '.') {
    return
}

Write-Host ""
Write-Host "   NORTHSTAR DevKit - WiFi SCANNER" -ForegroundColor Cyan
Write-Host "     https://www.northstarcoding.com" -ForegroundColor Gray
Write-Host ""

# Get WiFi networks
Write-DevKitStep "Scanning for networks"

$networks = netsh wlan show networks mode=Bssid | Out-String

if ($networks -match "There is no wireless interface on the system") {
    Write-DevKitError "No WiFi adapter found!"
    Read-Host "Press Enter to exit"
    exit 1
}

Write-DevKitDone

# Parse networks
$results = ConvertFrom-DevKitWlanScan -RawOutput $networks

if ($results.Count -eq 0) {
    Write-Host "  No WiFi networks parsed." -ForegroundColor Yellow
    Write-Host "  This may be due to a non-English Windows locale or empty scan results." -ForegroundColor Gray
    Write-Host "`n  Raw output:" -ForegroundColor Cyan
    Write-Host $networks -ForegroundColor Gray
    Read-Host "`nPress Enter to exit"
    exit 0
}

# Sort by best signal
$sorted = $results | Sort-Object { ($_.BSSIDs | Measure-Object -Property Signal -Maximum).Maximum } -Descending

# Display results
Write-Host "  Found $($sorted.Count) network(s):" -ForegroundColor Green
Write-Host ""
Write-Host "  SIGNAL  SSID                           SECURITY           CHANNEL" -ForegroundColor DarkGray
Write-Host "  ------  ----                           --------           -------"

foreach ($net in $sorted) {
    $bestSignal = ($net.BSSIDs | Measure-Object -Property Signal -Maximum).Maximum
    $channels = ($net.BSSIDs | Select-Object -ExpandProperty Channel | Sort-Object -Unique) -join ","
    
    # Color code signal strength
    $sigColor = if ($bestSignal -ge 80) { "Green" } elseif ($bestSignal -ge 50) { "Yellow" } else { "Red" }
    
    # Truncate long SSIDs
    $ssid = $net.SSID
    if ($ssid.Length -gt 28) { $ssid = $ssid.Substring(0, 25) + "..." }
    
    # Pad for alignment
    $signalStr = "$bestSignal%".PadRight(6)
    $ssidStr = $ssid.PadRight(28)
    $authStr = $net.Auth.PadRight(18)
    $chanStr = $channels
    
    Write-Host "  $signalStr" -ForegroundColor $sigColor -NoNewline
    Write-Host "$ssidStr $authStr $chanStr"
}

Write-Host ""

# Show recommendations
$openNets = $sorted | Where-Object { $_.Auth -eq "Open" -and ($_.BSSIDs | Measure-Object -Property Signal -Maximum).Maximum -ge 40 }
$bestNet = $sorted | Select-Object -First 1

Write-Host "  RECOMMENDATIONS:" -ForegroundColor Cyan

if ($openNets) {
    $bestOpen = $openNets | Sort-Object { ($_.BSSIDs | Measure-Object -Property Signal -Maximum).Maximum } -Descending | Select-Object -First 1
    $openSignal = ($bestOpen.BSSIDs | Measure-Object -Property Signal -Maximum).Maximum
    Write-Host "  - Best open network: $($bestOpen.SSID) ($openSignal% signal)" -ForegroundColor Green
}

Write-Host "  - Best secured network: $($bestNet.SSID) ($($bestNet.Auth))" -ForegroundColor $(if($bestNet.Auth -eq "Open"){"Green"}else{"Yellow"})

# Channel recommendation
$channels = @{}
foreach ($net in $sorted) {
    foreach ($bssid in $net.BSSIDs) {
        $ch = $bssid.Channel
        if (-not $channels.ContainsKey($ch)) { $channels[$ch] = 0 }
        $channels[$ch]++
    }
}
$busyChannel = $channels.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1
if ($busyChannel.Value -gt 3) {
    Write-Host "  - Channel $($busyChannel.Key) is congested ($($busyChannel.Value) networks)." -ForegroundColor Yellow
    Write-Host "    Ask for a network on a different channel if slow." -ForegroundColor Gray
}

Write-Host ""
Write-Host "  https://www.northstarcoding.com" -ForegroundColor DarkGray
Write-Host ""
Read-Host "Press Enter to exit"
