#!/usr/bin/env pwsh
<#
.SYNOPSIS
    WiFi Fast Mode - Northstar DevKit
.DESCRIPTION
    Same as WiFi-Optimize but skips the 5-second speed test.
    Use this when you just want fast optimization.
    
    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.EXAMPLE
    .\WiFi-FastMode.ps1
    .\WiFi-FastMode.ps1 -KeepDNS
#>

# Call the main script with -Fast flag, passing through all arguments
& "$PSScriptRoot\WiFi-Optimize.ps1" -Fast @args
