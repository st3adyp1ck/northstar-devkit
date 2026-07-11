#!/usr/bin/env pwsh
<#
.SYNOPSIS
    WiFi Optimizer - Northstar DevKit
.DESCRIPTION
    Optimizes network connection for maximum speed at public WiFi spots.
    Flushes DNS, resets TCP/IP, sets fastest public DNS, optimizes Windows settings.

    Before changing DNS, the adapter's current DNS configuration is backed up to
    a JSON file (see $DnsBackupPath below). Run this script again with -RestoreDns
    to put the backed-up DNS settings back, or run
    Set-DnsClientServerAddress -InterfaceIndex <n> -ResetServerAddresses manually.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Fast
    Skip speed test
.PARAMETER KeepDNS
    Don't change DNS settings
.PARAMETER Force
    Skip confirmation prompts.
.PARAMETER RestoreDns
    Restore the DNS configuration that was backed up before the last DNS change,
    then exit. Does not touch anything else (no TCP/IP reset, no speed test).
.EXAMPLE
    .\WiFi-Optimize.ps1
    .\WiFi-Optimize.ps1 -Fast
    .\WiFi-Optimize.ps1 -Force
    .\WiFi-Optimize.ps1 -RestoreDns
#>
[CmdletBinding()]
param(
    [switch]$Fast,
    [switch]$KeepDNS,
    [switch]$Force,
    [switch]$RestoreDns
)


$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

$DnsBackupPath = Join-Path $env:TEMP "DevKit-WiFi-DnsBackup.json"

# Admin check
if (-not (Test-DevKitAdmin)) {
    Write-Host "`nNorthstar DevKit - WiFi OPTIMIZER`n" -ForegroundColor Cyan
    Write-Host "  ERROR: Administrator privileges required." -ForegroundColor Red
    Write-Host "  Right-click and select 'Run as administrator'.`n" -ForegroundColor Yellow
    exit 1
}

function Measure-DevKitPingLatency {
    <#
    .SYNOPSIS
        Pings a target and reports average latency and packet loss.
    .DESCRIPTION
        Test-Connection reports Latency/ResponseTime = 0 on a timeout, not $null,
        so averaging every reply (success or not) silently folds packet loss into
        the average as artificially-good 0ms readings. This only averages replies
        that actually succeeded, and reports packet loss separately. Handles both
        PowerShell 7's Test-Connection (Status/Latency) and Windows PowerShell
        5.1's Win32_PingStatus-based Test-Connection (StatusCode/ResponseTime).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName,
        [int]$Count = 4
    )

    $replies = @(Test-Connection -ComputerName $ComputerName -Count $Count -ErrorAction SilentlyContinue)
    $sent = $replies.Count

    $successful = @($replies | Where-Object {
        ($_.PSObject.Properties.Match('Status').Count -gt 0 -and $_.Status -eq 'Success') -or
        ($_.PSObject.Properties.Match('StatusCode').Count -gt 0 -and $_.StatusCode -eq 0)
    })

    $avgLatency = $null
    if ($successful.Count -gt 0) {
        $latencyValues = $successful | ForEach-Object {
            if ($_.PSObject.Properties.Match('Latency').Count -gt 0) { $_.Latency } else { $_.ResponseTime }
        }
        $avgLatency = ($latencyValues | Measure-Object -Average).Average
    }

    $lossPct = 100
    if ($sent -gt 0) {
        $lossPct = [math]::Round((($sent - $successful.Count) / $sent) * 100, 0)
    }

    return [PSCustomObject]@{
        AverageLatency = $avgLatency
        PacketLossPct  = $lossPct
        Sent           = $sent
        Received       = $successful.Count
    }
}

function Write-DevKitStepResult {
    <#
    .SYNOPSIS
        Reports DONE/FAIL for a native external command based on its real exit
        code, instead of assuming success just because it didn't throw.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [System.Nullable[int]]$ExitCode,
        [string]$FailureContext = $null
    )
    if ($null -eq $ExitCode -or $ExitCode -eq 0) {
        Write-DevKitDone
    } else {
        Write-Host " FAIL" -ForegroundColor Red
        if ($FailureContext) {
            Write-DevKitInfo "$FailureContext exited with code $ExitCode"
        } else {
            Write-DevKitInfo "Command exited with code $ExitCode"
        }
    }
}

# ========== RESTORE MODE ==========
if ($RestoreDns) {
    Write-Host ""
    Write-Host "   NORTHSTAR DevKit - WiFi OPTIMIZER (DNS Restore)" -ForegroundColor Cyan
    Write-Host "     https://www.northstarcoding.com" -ForegroundColor Gray
    Write-Host ""

    if (-not (Test-Path $DnsBackupPath)) {
        Write-DevKitError "No DNS backup found at: $DnsBackupPath"
        Write-DevKitInfo "Nothing to restore automatically. To reset DNS to automatic (DHCP) manually, run:"
        Write-DevKitInfo "  Set-DnsClientServerAddress -InterfaceIndex <n> -ResetServerAddresses"
        Read-Host "`nPress Enter to exit"
        exit 1
    }

    try {
        $dnsBackup = Get-Content -Path $DnsBackupPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-DevKitError "Could not read DNS backup file: $($_.Exception.Message)"
        Read-Host "`nPress Enter to exit"
        exit 1
    }

    Write-DevKitStep "Restoring DNS on $($dnsBackup.InterfaceAlias)"
    try {
        # Reset first so any address family that was automatic/DHCP at backup time
        # goes back to automatic, then re-apply whichever families were static.
        Set-DnsClientServerAddress -InterfaceIndex $dnsBackup.InterfaceIndex -ResetServerAddresses -ErrorAction Stop
        $backupV4 = @($dnsBackup.IPv4)
        $backupV6 = @($dnsBackup.IPv6)
        if ($backupV4.Count -gt 0) {
            Set-DnsClientServerAddress -InterfaceIndex $dnsBackup.InterfaceIndex -ServerAddresses $backupV4 -ErrorAction Stop
        }
        if ($backupV6.Count -gt 0) {
            Set-DnsClientServerAddress -InterfaceIndex $dnsBackup.InterfaceIndex -ServerAddresses $backupV6 -ErrorAction Stop
        }
        Write-DevKitDone
        Write-DevKitInfo "DNS restored from backup taken $($dnsBackup.Timestamp)"
    } catch {
        Write-Host " FAIL" -ForegroundColor Red
        Write-DevKitError "Could not restore DNS: $($_.Exception.Message)"
        Read-Host "`nPress Enter to exit"
        exit 1
    }

    Read-Host "`nPress Enter to exit"
    exit 0
}

$startTime = Get-Date

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
if (-not $KeepDNS) {
    Write-Host "    - Change your DNS servers (previous settings are backed up first;" -ForegroundColor Yellow
    Write-Host "      undo anytime with: .\WiFi-Optimize.ps1 -RestoreDns)" -ForegroundColor Yellow
}
Write-Host ""
if (-not $Force) {
    $confirm = Read-Host "  Continue? (y/n)"
    if ($confirm -ne 'y') {
        Write-Host "  Cancelled.`n" -ForegroundColor Gray
        exit 0
    }
}

# Check if connected
Write-DevKitStep "Checking connection"
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
Write-DevKitDone
Write-Host "  Network: $($connection.Name)" -ForegroundColor Gray

# ========== DNS CACHE ==========
Write-DevKitHeader "Clearing DNS Cache"

Write-DevKitStep "Flushing DNS resolver cache"
Clear-DnsClientCache
ipconfig /flushdns | Out-Null
Write-DevKitStepResult -ExitCode $LASTEXITCODE -FailureContext "ipconfig /flushdns"

Write-DevKitStep "Re-registering DNS"
ipconfig /registerdns | Out-Null
Write-DevKitStepResult -ExitCode $LASTEXITCODE -FailureContext "ipconfig /registerdns"

# ========== TCP/IP RESET ==========
Write-DevKitHeader "Resetting Network Stack"

Write-DevKitStep "Resetting Winsock"
netsh winsock reset | Out-Null
Write-DevKitStepResult -ExitCode $LASTEXITCODE -FailureContext "netsh winsock reset"

Write-DevKitStep "Resetting TCP/IP"
netsh int ip reset | Out-Null
Write-DevKitStepResult -ExitCode $LASTEXITCODE -FailureContext "netsh int ip reset"

Write-DevKitStep "Releasing and renewing IP"
ipconfig /release | Out-Null
$releaseExit = $LASTEXITCODE
ipconfig /renew | Out-Null
$renewExit = $LASTEXITCODE
if ($releaseExit -eq 0 -and $renewExit -eq 0) {
    Write-DevKitDone
} else {
    Write-Host " FAIL" -ForegroundColor Red
    Write-DevKitInfo "ipconfig /release exited $releaseExit, /renew exited $renewExit"
}

# ========== DNS OPTIMIZATION ==========
$dns1 = $null
$dns2 = $null
$dns1v6 = $null
$dns2v6 = $null

if (-not $KeepDNS) {
    Write-DevKitHeader "Optimizing DNS"

    Write-DevKitStep "Testing DNS options"
    $cfResult = Measure-DevKitPingLatency -ComputerName "1.1.1.1" -Count 2
    $ggResult = Measure-DevKitPingLatency -ComputerName "8.8.8.8" -Count 2
    $cfPing = $cfResult.AverageLatency
    $ggPing = $ggResult.AverageLatency

    if ($cfPing -and $ggPing) {
        if ($cfPing -le $ggPing) {
            $dns1 = "1.1.1.1"
            $dns2 = "1.0.0.1"
            $dns1v6 = "2606:4700:4700::1111"
            $dns2v6 = "2606:4700:4700::1001"
            Write-DevKitDone
            Write-Host "  Cloudflare faster (${cfPing}ms vs ${ggPing}ms)" -ForegroundColor Gray
        } else {
            $dns1 = "8.8.8.8"
            $dns2 = "8.8.4.4"
            $dns1v6 = "2001:4860:4860::8888"
            $dns2v6 = "2001:4860:4860::8844"
            Write-DevKitDone
            Write-Host "  Google faster (${ggPing}ms vs ${cfPing}ms)" -ForegroundColor Gray
        }
    } else {
        $dns1 = "1.1.1.1"
        $dns2 = "1.0.0.1"
        $dns1v6 = "2606:4700:4700::1111"
        $dns2v6 = "2606:4700:4700::1001"
        Write-DevKitDone
        Write-Host "  Defaulting to Cloudflare" -ForegroundColor Gray
    }

    # Get active WiFi adapter. Filtering on PhysicalMediaType (not just
    # HardwareInterface) keeps this WiFi-specific tool from reconfiguring a
    # docked laptop's Ethernet adapter when both are up.
    $adapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.PhysicalMediaType -eq "Native 802.11" } | Select-Object -First 1
    if ($adapter) {
        # Back up the adapter's current DNS configuration before changing anything,
        # so -RestoreDns (or a manual Set-DnsClientServerAddress -ResetServerAddresses)
        # can undo this. Without this, DNS changes were previously a one-way door.
        try {
            $backupV4 = Get-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop
            $backupV6 = Get-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv6 -ErrorAction Stop
            $dnsBackup = [PSCustomObject]@{
                Timestamp      = (Get-Date).ToString("o")
                InterfaceIndex = $adapter.InterfaceIndex
                InterfaceAlias = $adapter.Name
                IPv4           = @($backupV4.ServerAddresses)
                IPv6           = @($backupV6.ServerAddresses)
            }
            $dnsBackup | ConvertTo-Json | Set-Content -Path $DnsBackupPath -Encoding UTF8 -ErrorAction Stop
            Write-DevKitInfo "Previous DNS backed up to: $DnsBackupPath"
        } catch {
            Write-DevKitInfo "WARNING: could not back up existing DNS settings ($($_.Exception.Message))"
        }

        Write-DevKitStep "Setting IPv4 DNS on $($adapter.Name)"
        try {
            Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ServerAddresses $dns1, $dns2 -ErrorAction Stop
            $verifyV4 = @((Get-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses)
            if ($verifyV4 -contains $dns1) {
                Write-DevKitDone
                Write-Host "  Primary: $dns1" -ForegroundColor Gray
                Write-Host "  Secondary: $dns2" -ForegroundColor Gray
            } else {
                Write-Host " FAIL" -ForegroundColor Red
                Write-DevKitInfo "DNS reported as: $($verifyV4 -join ', ') (expected $dns1, $dns2)"
                $dns1 = if ($verifyV4.Count -ge 1) { $verifyV4[0] } else { "unchanged" }
                $dns2 = if ($verifyV4.Count -ge 2) { $verifyV4[1] } else { "unchanged" }
            }
        } catch {
            Write-Host " FAIL" -ForegroundColor Red
            Write-DevKitInfo "Could not set IPv4 DNS: $($_.Exception.Message)"
            $dns1 = "unchanged"
            $dns2 = "unchanged"
        }

        Write-DevKitStep "Setting IPv6 DNS on $($adapter.Name)"
        try {
            Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ServerAddresses $dns1v6, $dns2v6 -ErrorAction Stop
            $verifyV6 = @((Get-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv6 -ErrorAction Stop).ServerAddresses)
            if ($verifyV6 -contains $dns1v6) {
                Write-DevKitDone
                Write-Host "  Primary IPv6: $dns1v6" -ForegroundColor Gray
                Write-Host "  Secondary IPv6: $dns2v6" -ForegroundColor Gray
            } else {
                Write-Host " FAIL" -ForegroundColor Red
                Write-DevKitInfo "IPv6 DNS reported as: $($verifyV6 -join ', ') (expected $dns1v6, $dns2v6)"
                $dns1v6 = if ($verifyV6.Count -ge 1) { $verifyV6[0] } else { "unchanged" }
                $dns2v6 = if ($verifyV6.Count -ge 2) { $verifyV6[1] } else { "unchanged" }
            }
        } catch {
            Write-Host " FAIL" -ForegroundColor Red
            Write-DevKitInfo "Could not set IPv6 DNS: $($_.Exception.Message)"
            $dns1v6 = "unchanged"
            $dns2v6 = "unchanged"
        }
    } else {
        Write-DevKitInfo "No active WiFi adapter found; DNS unchanged"
        # Reset back to $null: the provider-preference test above always sets
        # these, even though nothing was actually applied without an adapter --
        # the summary must reflect what really happened, not what was intended.
        $dns1 = $null
        $dns2 = $null
    }
} else {
    Write-DevKitHeader "DNS Optimization"
    Write-DevKitSkip
}

# ========== WINDOWS OPTIMIZATIONS ==========
Write-DevKitHeader "Optimizing System"

Write-DevKitStep "Optimizing TCP settings"
netsh int tcp set global autotuninglevel=normal | Out-Null
$tcpAutoTuneExit = $LASTEXITCODE
netsh int tcp set global rss=enabled | Out-Null
$tcpRssExit = $LASTEXITCODE
if ($tcpAutoTuneExit -eq 0 -and $tcpRssExit -eq 0) {
    Write-DevKitDone
} else {
    Write-Host " FAIL" -ForegroundColor Red
    Write-DevKitInfo "netsh autotuninglevel exited $tcpAutoTuneExit, rss exited $tcpRssExit"
}

# ========== CONNECTION TEST ==========
Write-DevKitHeader "Testing Connection"

Write-DevKitStep "Testing latency"
$latencyResult = Measure-DevKitPingLatency -ComputerName "1.1.1.1" -Count 4
if ($null -ne $latencyResult.AverageLatency) {
    $roundedLatency = [math]::Round($latencyResult.AverageLatency, 1)
    Write-DevKitDone
    Write-Host "  Average latency: ${roundedLatency}ms" -ForegroundColor $(if($roundedLatency -lt 50){"Green"}elseif($roundedLatency -lt 100){"Yellow"}else{"Red"})
    if ($latencyResult.PacketLossPct -gt 0) {
        Write-Host "  Packet loss: $($latencyResult.PacketLossPct)% ($($latencyResult.Received)/$($latencyResult.Sent) replies received)" -ForegroundColor $(if($latencyResult.PacketLossPct -ge 50){"Red"}else{"Yellow"})
    }
} else {
    Write-Host " FAIL" -ForegroundColor Red
    Write-DevKitInfo "No successful replies from 1.1.1.1 (100% packet loss)"
}

if (-not $Fast) {
    Write-DevKitStep "Testing download speed"
    $httpClient = $null
    $downloadStream = $null
    try {
        try {
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
        } catch { }

        # A fixed-size payload with a fixed timeout guarantees failure on exactly the
        # slow connections this tool exists to diagnose (a 25MB/10s test requires
        # ~20 Mbps just to complete). Instead, read for a fixed wall-clock window and
        # measure whatever throughput that produces -- fast connections finish early
        # with an accurate full-file time, slow connections still yield a real (low)
        # Mbps figure instead of a bare "could not complete" failure.
        $testUrl = "https://speed.cloudflare.com/__down?bytes=50000000"
        $windowSeconds = 8

        $httpClient = New-Object System.Net.Http.HttpClient
        $httpClient.Timeout = [TimeSpan]::FromSeconds($windowSeconds + 20)

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $httpResponse = $httpClient.GetAsync($testUrl, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if (-not $httpResponse.IsSuccessStatusCode) {
            throw "Speed test endpoint returned HTTP $([int]$httpResponse.StatusCode)"
        }

        $downloadStream = $httpResponse.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $buffer = New-Object byte[] 65536
        [long]$totalBytes = 0
        while ($sw.Elapsed.TotalSeconds -lt $windowSeconds) {
            $bytesRead = $downloadStream.Read($buffer, 0, $buffer.Length)
            if ($bytesRead -le 0) { break }
            $totalBytes += $bytesRead
        }
        $sw.Stop()

        $elapsedSeconds = $sw.Elapsed.TotalSeconds
        if ($totalBytes -gt 0 -and $elapsedSeconds -gt 0) {
            $mbps = [math]::Round(($totalBytes * 8) / $elapsedSeconds / 1000000, 1)
            Write-DevKitDone
            Write-Host "  Download speed: $mbps Mbps" -ForegroundColor $(if($mbps -gt 50){"Green"}elseif($mbps -gt 10){"Yellow"}else{"Red"})
        } else {
            Write-Host " FAIL" -ForegroundColor Red
            Write-DevKitInfo "No data received from speed test endpoint"
        }
    } catch {
        Write-Host " FAIL" -ForegroundColor Red
        Write-DevKitInfo "Could not complete speed test: $($_.Exception.Message)"
    } finally {
        if ($downloadStream) { $downloadStream.Dispose() }
        if ($httpClient) { $httpClient.Dispose() }
    }
} else {
    Write-DevKitSkip
    Write-Host "  (Skipped because -Fast was used)" -ForegroundColor Gray
}

# ========== SUMMARY ==========
$duration = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)

Write-DevKitHeader "Optimization Complete"
Write-Host "  Duration: $duration seconds" -ForegroundColor Gray
Write-Host ""
Write-Host "  DNS: $(if($KeepDNS){'Unchanged'}elseif($dns1){"$dns1, $dns2"}else{'Unchanged (no WiFi adapter found)'})" -ForegroundColor Gray
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
