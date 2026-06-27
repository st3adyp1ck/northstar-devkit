#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Next.js Dev Fresh Start - Northstar DevKit
.DESCRIPTION
    Clears .next cache and starts the dev server.
    Optionally clears Turbopack cache too.
    Auto-detects package manager.
    
    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Path
    The project directory. Defaults to current directory.
.PARAMETER Turbo
    Also clear Turbopack cache.
.PARAMETER Port
    Specify dev server port.
.EXAMPLE
    .\Next-DevFresh.ps1
    .\Next-DevFresh.ps1 -Turbo
    .\Next-DevFresh.ps1 -Port 3001
#>
[CmdletBinding()]
param(
    [string]$Path = ".",
    [switch]$Turbo,
    [int]$Port = 0
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

try {
    $targetPath = Resolve-DevKitDirectory -Path $Path
} catch {
    Write-DevKitHeader "Next.js Dev Server (Fresh)"
    Write-DevKitError $_
    exit 1
}

Write-DevKitHeader "Next.js Dev Server (Fresh)"
Write-DevKitInfo "Path: $targetPath"

$manager = Get-DevKitPackageManager -Path $targetPath
Write-DevKitInfo "Package manager: $($manager.Command)"

Invoke-DevKitInDirectory -Path $targetPath -ScriptBlock {
    if ($Turbo) {
        Write-DevKitStep "Clearing Turbopack cache"
        Clear-DevKitNodeCaches -Path . -IncludeTurbo | Out-Null
        Write-DevKitDone
    }

    $nextPath = Join-Path . ".next"
    if (Test-Path $nextPath) {
        Write-DevKitStep "Clearing .next cache"
        Remove-Item -Path $nextPath -Recurse -Force
        Write-DevKitDone
    }

    Write-Host "`n  Starting dev server...`n" -ForegroundColor Green

    $env:NEXT_TELEMETRY_DISABLED = "1"

    $devArgs = @("run", "dev")
    if ($Port -gt 0) { $devArgs += @("--", "--port", $Port) }

    & $manager.Command @devArgs
}
