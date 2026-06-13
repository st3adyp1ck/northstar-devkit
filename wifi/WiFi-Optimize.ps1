#!/usr/bin/env pwsh
<#
.SYNOPSIS
    WiFi Optimizer - Northstar DevKit
.DESCRIPTION
    Optimizes network connection for maximum speed at public WiFi spots.
    Flushes DNS, resets TCP/IP, sets fastest public DNS, optimizes Windows settings.
    
    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Fast
    Skip speed test
.PARAMETER KeepDNS
    Don't change DNS settings
.PARAMETER Force
    Skip confirmation prompts.
.EXAMPLE
    .\WiFi-Optimize.ps1
    .\WiFi-Optimize.ps1 -Fast
    .\WiFi-Optimize.ps1 -Force
#>

[CmdletBinding()]
param(
    [switch]$Fast,
    [switch]$KeepDNS,
    [switch]$Force
)

# Admin check
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
if (-not $isAdmin) {
    Write-Host "`nNorthstar DevKit - WiFi OPTIMIZER`n" -ForegroundColor Cyan
    Write-Host "  ERROR: Administrator privileges required." -ForegroundColor Red
    Write-Host "  Right-click and select 'Run as administrator'.`n" -ForegroundColor Yellow
    exit 1
}

$startTime = Get-Date

function Write-Header {
    param([string]$Title)
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
}

function Write-Step {
    param([string]$Message)
    Write-Host "  [>] $Message..." -ForegroundColor Yellow -NoNewline
}

function Write-Done {
    Write-Host " DONE" -ForegroundColor Green
}

function Write-Skip {
    Write-Host " SKIP" -ForegroundColor Gray
}

Write-Host ""
Write-Host "   NORTHSTAR DevKit - WiFi OPTIMIZER" -ForegroundColor Cyan
Write-Host "     https://www.northstarcoding.com" -ForegroundColor Gray
Write-Host ""
Write-Host "  Optimize your connection for max speed" -ForegroundColor DarkGray
Write-Host "  Started: $(Get-Date -Format 'HH:mm:ss')" -ForegroundColor DarkGray
Write-Host ""

# Warning and confirmation
Write-Host "  WARNING: This will:" -ForegroundColor Red
Write-Host "    - Reset your network stack (Winsock/TCP/IP)" -ForegroundColor Yellow
Write-Host "    - Temporarily disconnect your internet" -ForegroundColor Yellow
Write-Host "    - Require a system restart to fully complete" -ForegroundColor Yellow
Write-Host ""
if (-not $Force) {
    $confirm = Read-Host "  Continue? (y/n)"
    if ($confirm -ne 'y') {
        Write-Host "  Cancelled.`n" -ForegroundColor Gray
        exit 0
    }
}

# Check if connected
Write-Step "Checking connection"
$connection = Get-NetConnectionProfile -ErrorAction SilentlyContinue
if (-not $connection) {
    Write-Host " FAIL" -ForegroundColor Red
    Write-Host ""
    Write-Host "  ERROR: No active network connection!" -ForegroundColor Red
    Write-Host "  Connect to WiFi first, then run this tool." -ForegroundColor Gray
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit 1
}
Write-Done
Write-Host "  Network: $($connection.Name)" -ForegroundColor Gray

# ========== DNS CACHE ==========
Write-Header "Clearing DNS Cache"

Write-Step "Flushing DNS resolver cache"
Clear-DnsClientCache
ipconfig /flushdns | Out-Null
Write-Done

Write-Step "Re-registering DNS"
ipconfig /registerdns | Out-Null
Write-Done

# ========== TCP/IP RESET ==========
Write-Header "Resetting Network Stack"

Write-Step "Resetting Winsock"
netsh winsock reset | Out-Null
Write-Done

Write-Step "Resetting TCP/IP"
netsh int ip reset | Out-Null
Write-Done

Write-Step "Releasing and renewing IP"
ipconfig /release | Out-Null
ipconfig /renew | Out-Null
Write-Done

# ========== DNS OPTIMIZATION ==========
if (-not $KeepDNS) {
    Write-Header "Optimizing DNS"
    
    Write-Step "Testing DNS options"
    $cfPing = Test-Connection -ComputerName "1.1.1.1" -Count 2 -ErrorAction SilentlyContinue | 
        Measure-Object -Property ResponseTime -Average | Select-Object -ExpandProperty Average
    $ggPing = Test-Connection -ComputerName "8.8.8.8" -Count 2 -ErrorAction SilentlyContinue | 
        Measure-Object -Property ResponseTime -Average | Select-Object -ExpandProperty Average
    
    if ($cfPing -and $ggPing) {
        if ($cfPing -le $ggPing) {
            $dns1 = "1.1.1.1"
            $dns2 = "1.0.0.1"
            $dns1v6 = "2606:4700:4700::1111"
            $dns2v6 = "2606:4700:4700::1001"
            Write-Done
            Write-Host "  Cloudflare faster (${cfPing}ms vs ${ggPing}ms)" -ForegroundColor Gray
        } else {
            $dns1 = "8.8.8.8"
            $dns2 = "8.8.4.4"
            $dns1v6 = "2001:4860:4860::8888"
            $dns2v6 = "2001:4860:4860::8844"
            Write-Done
            Write-Host "  Google faster (${ggPing}ms vs ${cfPing}ms)" -ForegroundColor Gray
        }
    } else {
        $dns1 = "1.1.1.1"
        $dns2 = "1.0.0.1"
        $dns1v6 = "2606:4700:4700::1111"
        $dns2v6 = "2606:4700:4700::1001"
        Write-Done
        Write-Host "  Defaulting to Cloudflare" -ForegroundColor Gray
    }
    
    # Get active adapter
    $adapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.HardwareInterface -eq $true } | Select-Object -First 1
    if ($adapter) {
        Write-Step "Setting IPv4 DNS on $($adapter.Name)"
        Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ServerAddresses $dns1, $dns2 -ErrorAction SilentlyContinue
        Write-Done
        Write-Host "  Primary: $dns1" -ForegroundColor Gray
        Write-Host "  Secondary: $dns2" -ForegroundColor Gray

        Write-Step "Setting IPv6 DNS on $($adapter.Name)"
        Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ServerAddresses $dns1v6, $dns2v6 -AddressFamily IPv6 -ErrorAction SilentlyContinue
        Write-Done
        Write-Host "  Primary IPv6: $dns1v6" -ForegroundColor Gray
        Write-Host "  Secondary IPv6: $dns2v6" -ForegroundColor Gray
    }
} else {
    Write-Header "DNS Optimization"
    Write-Skip
}

# ========== WINDOWS OPTIMIZATIONS ==========
Write-Header "Optimizing System"

Write-Step "Optimizing TCP settings"
netsh int tcp set global autotuninglevel=normal | Out-Null
netsh int tcp set global rss=enabled | Out-Null
Write-Done

# ========== CONNECTION TEST ==========
Write-Header "Testing Connection"

Write-Step "Testing latency"
$latency = Test-Connection -ComputerName "1.1.1.1" -Count 4 -ErrorAction SilentlyContinue | 
    Measure-Object -Property ResponseTime -Average | Select-Object -ExpandProperty Average
if ($latency) {
    Write-Done
    Write-Host "  Average latency: $($latency)ms" -ForegroundColor $(if($latency -lt 50){"Green"}elseif($latency -lt 100){"Yellow"}else{"Red"})
} else {
    Write-Host " FAIL" -ForegroundColor Red
}

if (-not $Fast) {
    Write-Step "Testing download speed"
    try {
        $testUrl = "https://speed.cloudflare.com/__down?bytes=25000000"
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $response = Invoke-WebRequest -Uri $testUrl -TimeoutSec 10 -UseBasicParsing
        $sw.Stop()
        $bytes = $response.RawContentLength
        $mbps = [math]::Round(($bytes * 8) / $sw.Elapsed.TotalSeconds / 1000000, 1)
        Write-Done
        Write-Host "  Download speed: $mbps Mbps" -ForegroundColor $(if($mbps -gt 50){"Green"}elseif($mbps -gt 10){"Yellow"}else{"Red"})
    } catch {
        Write-Host " FAIL" -ForegroundColor Red
        Write-Host "  Could not complete speed test" -ForegroundColor Gray
    }
} else {
    Write-Skip
    Write-Host "  (Skipped - use -Fast to skip speed test)" -ForegroundColor Gray
}

# ========== SUMMARY ==========
$duration = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)

Write-Header "Optimization Complete"
Write-Host "  Duration: $duration seconds" -ForegroundColor Gray
Write-Host ""
Write-Host "  DNS: $(if($KeepDNS){'Unchanged'}else{"$dns1, $dns2"})" -ForegroundColor Gray
Write-Host "  Network stack: Reset" -ForegroundColor Gray
Write-Host ""
Write-Host "  IMPORTANT: A system restart is recommended" -ForegroundColor Red
Write-Host "  to fully complete the TCP/IP reset.`n" -ForegroundColor Yellow

Write-Host "  Tips for better speeds:" -ForegroundColor Cyan
Write-Host "    - Move closer to the router" -ForegroundColor Gray
Write-Host "    - Ask for the 5GHz network" -ForegroundColor Gray
Write-Host "    - Check if others are streaming" -ForegroundColor Gray
Write-Host ""
Write-Host "  https://www.northstarcoding.com" -ForegroundColor DarkGray
Write-Host ""

Read-Host "Press Enter to exit"
