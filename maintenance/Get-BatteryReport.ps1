#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Battery Report - Northstar DevKit
.DESCRIPTION
    Generates a Windows battery health report (powercfg /batteryreport) for
    laptop/tablet systems. A desktop with no battery is reported as a benign
    no-op, not an error. Non-destructive - only ever writes the report file.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER OutputPath
    Where to write the HTML report. Defaults to a devkit-battery-report.html
    file under $env:TEMP.
.PARAMETER Open
    Open the generated report with its default handler when done.
.EXAMPLE
    .\Get-BatteryReport.ps1
    .\Get-BatteryReport.ps1 -OutputPath "C:\Reports\battery.html" -Open
#>
[CmdletBinding()]
param(
    [string]$OutputPath,
    [switch]$Open
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

Write-DevKitHeader "Battery Report"

try {
    $batteries = @()
    try {
        $batteries = @(Get-CimInstance Win32_Battery -ErrorAction Stop)
    } catch {
        Write-DevKitError "Could not query battery information: $_"
        exit 1
    }

    if ($batteries.Count -eq 0) {
        Write-DevKitInfo "No battery detected (this looks like a desktop system)."
        exit 0
    }

    foreach ($battery in $batteries) {
        Write-Host "  Battery: $($battery.Name)" -ForegroundColor Gray
        if ($null -ne $battery.EstimatedChargeRemaining) {
            Write-Host "    Charge remaining: $($battery.EstimatedChargeRemaining)%" -ForegroundColor Gray
        }
    }
    Write-Host ""

    if (-not $OutputPath) {
        $OutputPath = Join-Path $env:TEMP "devkit-battery-report.html"
    }

    $outputDir = Split-Path -Parent $OutputPath
    if ($outputDir -and -not (Test-Path -LiteralPath $outputDir)) {
        try {
            New-Item -ItemType Directory -Path $outputDir -Force -ErrorAction Stop | Out-Null
        } catch {
            Write-DevKitError "Could not create output directory '$outputDir': $_"
            exit 1
        }
    }

    if (-not (Test-DevKitCommand "powercfg")) {
        Write-DevKitError "powercfg.exe was not found in PATH."
        exit 1
    }

    Write-DevKitStep "Generating battery report"
    try {
        $powercfgOutput = & powercfg /batteryreport /output "$OutputPath" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-DevKitSkip
            Write-DevKitError "powercfg exited with code ${LASTEXITCODE}: $($powercfgOutput -join ' ')"
            exit 1
        }
        Write-DevKitDone
    } catch {
        Write-DevKitSkip
        Write-DevKitError "Failed to run powercfg: $_"
        exit 1
    }

    Write-Host ""
    Write-Host "  Report saved to: $OutputPath" -ForegroundColor Green

    if ($Open) {
        try {
            Invoke-Item -Path $OutputPath -ErrorAction Stop
        } catch {
            Write-DevKitError "Could not open the report: $_"
            exit 1
        }
    }

    exit 0
} catch {
    Write-DevKitError "Unexpected failure: $_"
    exit 1
}
