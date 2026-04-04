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

Write-Host ""
Write-Host "   NORTHSTAR DevKit - WiFi SCANNER" -ForegroundColor Cyan
Write-Host "     https://www.northstarcoding.com" -ForegroundColor Gray
Write-Host ""

# Get WiFi networks
Write-Host "  Scanning for networks..." -ForegroundColor Yellow
Write-Host ""

$networks = netsh wlan show networks mode=Bssid | Out-String

if ($networks -match "There is no wireless interface on the system") {
    Write-Host "  ERROR: No WiFi adapter found!" -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

# Parse networks
$lines = $networks -split "`r`n"
$currentNet = $null
$results = @()

foreach ($line in $lines) {
    if ($line -match "SSID\s+\d+\s+:\s+(.+)") {
        $currentNet = @{ SSID = $matches[1].Trim(); BSSIDs = @() }
    }
    elseif ($line -match "Authentication\s+:\s+(.+)") {
        if ($currentNet) { $currentNet.Auth = $matches[1].Trim() }
    }
    elseif ($line -match "BSSID\s+\d+\s+:\s+(.+)") {
        if ($currentNet) { 
            $currentNet.CurrentBSSID = @{ MAC = $matches[1].Trim(); Signal = 0; Channel = 0 }
        }
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

if ($results.Count -eq 0) {
    Write-Host "  No WiFi networks found." -ForegroundColor Yellow
    Read-Host "Press Enter to exit"
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
