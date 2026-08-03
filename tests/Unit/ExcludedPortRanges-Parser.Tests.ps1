#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Unit tests for ConvertFrom-DevKitExcludedPortRanges (lib/DevKit-Common.ps1)
.DESCRIPTION
    Exercises the `netsh interface ipv4 show excludedportrange protocol=tcp`
    parser against a realistic captured-style fixture - multi-row output with
    a single-port exclusion and a "*"-marked administered range - plus empty,
    header-only, and localized-header input. This is pure text parsing: no
    netsh invocation, no admin rights, safe to run in any CI/dev environment.
.EXAMPLE
    Invoke-Pester -Path .\tests\Unit\ExcludedPortRanges-Parser.Tests.ps1
#>

BeforeAll {
    $script:CommonModule = Join-Path (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "lib") "DevKit-Common.ps1"
    # lib/DevKit-Common.ps1 guards itself against double-loading (see the
    # function-detection guard at its top) and still sets the
    # $global:DevKitCommonLoaded flag. Reset the flag so this file always
    # gets a real, fresh load in THIS file's scope regardless of what an
    # earlier test file in the same Pester process already loaded (same
    # pattern as Get-DevKitPackageManager.Tests.ps1).
    $global:DevKitCommonLoaded = $false
    . $script:CommonModule

    # Realistic sample matching real `netsh interface ipv4 show excludedportrange
    # protocol=tcp` output: a title line, blank line, header row, dashed
    # separator, one multi-port range, one single-port exclusion (Start -eq
    # End), and one administered range carrying the trailing "*" marker column,
    # then the footnote that explains the marker. netsh emits CRLF line endings
    # on Windows, so normalize the fixture to match regardless of how this file
    # is saved.
    $script:SampleNetshOutput = @"
Protocol tcp Port Exclusion Ranges

Start Port    End Port
----------    --------
      1025        1325
      5357        5357
     49760       49859
     50000       50059     *

* - Administered port exclusions.
"@ -replace "`r?`n", "`r`n"
}

Describe "ConvertFrom-DevKitExcludedPortRanges" {

    It "parses every data row from realistic netsh output (headers, dashes, and footnote skipped)" {
        $results = ConvertFrom-DevKitExcludedPortRanges -Output $script:SampleNetshOutput
        $results.Count | Should -Be 4
    }

    It "returns the correct Start/End value for each parsed range, in row order" {
        $results = ConvertFrom-DevKitExcludedPortRanges -Output $script:SampleNetshOutput
        $results[0].Start | Should -Be 1025
        $results[0].End | Should -Be 1325
        $results[1].Start | Should -Be 5357
        $results[1].End | Should -Be 5357
        $results[2].Start | Should -Be 49760
        $results[2].End | Should -Be 49859
        $results[3].Start | Should -Be 50000
        $results[3].End | Should -Be 50059
    }

    It "parses a bare two-column row like '  5357  5357' as a single-port range" {
        $results = ConvertFrom-DevKitExcludedPortRanges -Output "  5357  5357`r`n"
        $results.Count | Should -Be 1
        $results[0].Start | Should -Be 5357
        $results[0].End | Should -Be 5357
    }

    It "never matches literal header words, so a localized header is skipped too" {
        $localizedOutput = "Protokoll tcp Portausschlussbereiche`r`n`r`nStartport    Endport`r`n---------    --------`r`n      8080        8080`r`n"
        $results = ConvertFrom-DevKitExcludedPortRanges -Output $localizedOutput
        $results.Count | Should -Be 1
        $results[0].Start | Should -Be 8080
        $results[0].End | Should -Be 8080
    }

    It "returns an empty array (not an error) for empty input" {
        $results = ConvertFrom-DevKitExcludedPortRanges -Output ""
        $results.Count | Should -Be 0
    }

    It "returns an empty array for header-only output with no data rows" {
        $headerOnlyOutput = "Protocol tcp Port Exclusion Ranges`r`n`r`nStart Port    End Port`r`n----------    --------`r`n"
        $results = ConvertFrom-DevKitExcludedPortRanges -Output $headerOnlyOutput
        $results.Count | Should -Be 0
    }

    It "returns a true 1-element array (not a bare Hashtable) when exactly one range is found" {
        # Regression guard for the "return ,`$results" contract: PowerShell
        # flattens a 1-element array to a bare scalar across a function-return
        # boundary unless the function forces array output - without it,
        # $results.Count here would silently report the hashtable's key count
        # (2) instead of the real range count (1).
        $results = ConvertFrom-DevKitExcludedPortRanges -Output "  5357  5357`r`n"
        $results.GetType().IsArray | Should -Be $true
        $results.Count | Should -Be 1
    }
}
