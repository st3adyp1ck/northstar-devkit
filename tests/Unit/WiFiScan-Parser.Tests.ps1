#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Unit tests for the WiFi-Scan.ps1 netsh output parser.
.DESCRIPTION
    Dot-sources wifi/WiFi-Scan.ps1 to unit test ConvertFrom-DevKitWlanScan
    against a realistic captured-style fixture of
    `netsh wlan show networks mode=Bssid` output.

    When dot-sourced, WiFi-Scan.ps1 only defines its functions and then
    returns immediately (see the $MyInvocation.InvocationName guard near the
    top of that file) -- it never calls netsh.exe, never prompts with
    Read-Host, and needs no WiFi hardware or admin rights. That guard is what
    makes this file safe to run in any CI/dev environment.
.EXAMPLE
    Invoke-Pester -Path .\tests\Unit\WiFiScan-Parser.Tests.ps1
#>

BeforeAll {
    $script:ScanScript = (Resolve-Path (Join-Path $PSScriptRoot "..\..\wifi\WiFi-Scan.ps1")).Path
    . $script:ScanScript

    # Realistic sample matching real `netsh wlan show networks mode=Bssid` output:
    # one network with two BSSIDs (dual-band router seen on two radios), one open
    # network, and one weak neighboring network. netsh emits CRLF line endings on
    # Windows, so normalize the fixture to match regardless of how this file is saved.
    $script:SampleNetshOutput = @"
Interface name : Wi-Fi
There are 3 networks currently visible.

SSID 1 : HomeNetwork-5G
    Network type            : Infrastructure
    Authentication          : WPA2-Personal
    Encryption              : CCMP
    BSSID 1                 : a0:b1:c2:d3:e4:f5
         Signal             : 92%
         Radio type         : 802.11ac
         Channel             : 149
         Basic rates (Mbps) : 6 12 24
         Other rates (Mbps) : 9 18 36 48 54
    BSSID 2                 : a0:b1:c2:d3:e4:f6
         Signal             : 61%
         Radio type         : 802.11ac
         Channel             : 44
         Basic rates (Mbps) : 6 12 24
         Other rates (Mbps) : 9 18 36 48 54

SSID 2 : CoffeeShop_Free
    Network type            : Infrastructure
    Authentication          : Open
    Encryption              : None
    BSSID 1                 : 11:22:33:44:55:66
         Signal             : 45%
         Radio type         : 802.11n
         Channel             : 6
         Basic rates (Mbps) : 1 2 5.5 11
         Other rates (Mbps) : 6 9 12 18 24 36 48 54

SSID 3 : NeighborWifi
    Network type            : Infrastructure
    Authentication          : WPA2-Personal
    Encryption              : CCMP
    BSSID 1                 : 77:88:99:aa:bb:cc
         Signal             : 30%
         Radio type         : 802.11n
         Channel             : 1
         Basic rates (Mbps) : 1 2 5.5 11
         Other rates (Mbps) : 6 9 12 18 24 36 48 54

"@ -replace "`r?`n", "`r`n"
}

Describe "ConvertFrom-DevKitWlanScan" {

    It "extracts every SSID name from realistic netsh output (regression for the BSSID/SSID regex collision)" {
        $results = ConvertFrom-DevKitWlanScan -RawOutput $script:SampleNetshOutput
        $ssids = $results | ForEach-Object { $_.SSID }
        $ssids | Should -Contain "HomeNetwork-5G"
        $ssids | Should -Contain "CoffeeShop_Free"
        $ssids | Should -Contain "NeighborWifi"
    }

    It "does not return zero results" {
        $results = ConvertFrom-DevKitWlanScan -RawOutput $script:SampleNetshOutput
        $results.Count | Should -Be 3
    }

    It "never parses an SSID as a MAC address (BSSID lines must not be misread as SSID lines)" {
        $results = ConvertFrom-DevKitWlanScan -RawOutput $script:SampleNetshOutput
        foreach ($net in $results) {
            $net.SSID | Should -Not -Match "^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$"
        }
    }

    It "attaches both BSSIDs (access points) to the correct multi-AP network" {
        $results = ConvertFrom-DevKitWlanScan -RawOutput $script:SampleNetshOutput
        $homeNet = $results | Where-Object { $_.SSID -eq "HomeNetwork-5G" }
        $homeNet.BSSIDs.Count | Should -Be 2
        $macs = $homeNet.BSSIDs | ForEach-Object { $_.MAC }
        $macs | Should -Contain "a0:b1:c2:d3:e4:f5"
        $macs | Should -Contain "a0:b1:c2:d3:e4:f6"
    }

    It "records correct Signal and Channel values per BSSID" {
        $results = ConvertFrom-DevKitWlanScan -RawOutput $script:SampleNetshOutput
        $coffee = $results | Where-Object { $_.SSID -eq "CoffeeShop_Free" }
        $coffee.BSSIDs[0].Signal | Should -Be 45
        $coffee.BSSIDs[0].Channel | Should -Be 6
    }

    It "records Authentication / security type per network" {
        $results = ConvertFrom-DevKitWlanScan -RawOutput $script:SampleNetshOutput
        $coffee = $results | Where-Object { $_.SSID -eq "CoffeeShop_Free" }
        $coffee.Auth | Should -Be "Open"

        $homeNet = $results | Where-Object { $_.SSID -eq "HomeNetwork-5G" }
        $homeNet.Auth | Should -Be "WPA2-Personal"
    }

    It "returns an empty array (not an error) for empty input" {
        $results = ConvertFrom-DevKitWlanScan -RawOutput ""
        $results.Count | Should -Be 0
    }

    It "returns an empty array for 'no wireless interface' style output" {
        $results = ConvertFrom-DevKitWlanScan -RawOutput "There is no wireless interface on the system.`r`n"
        $results.Count | Should -Be 0
    }

    It "returns a true 1-element array (not a bare Hashtable) when exactly one network is found" {
        # Regression test: PowerShell flattens a 1-element array to a bare
        # scalar across a function-return boundary unless the function forces
        # array output (e.g. "return ,$results"). Without that, $results.Count
        # here silently reported the single network's *key* count (4) instead
        # of the real network count (1) -- confirmed live against a real
        # single-network `netsh wlan show networks` scan.
        $singleNetworkOutput = @"
Interface name : Wi-Fi
There are 1 networks currently visible.

SSID 1 : Mr.Robot
    Network type            : Infrastructure
    Authentication          : WPA2-Personal
    Encryption              : CCMP
    BSSID 1                 : cc:2d:21:b1:66:8d
         Signal             : 82%
         Radio type         : 802.11ac
         Channel             : 149
         Basic rates (Mbps) : 6 12 24
         Other rates (Mbps) : 9 18 36 48 54

"@ -replace "`r?`n", "`r`n"

        $results = ConvertFrom-DevKitWlanScan -RawOutput $singleNetworkOutput
        $results.GetType().IsArray | Should -Be $true
        $results.Count | Should -Be 1
        $results[0].SSID | Should -Be "Mr.Robot"
    }
}
