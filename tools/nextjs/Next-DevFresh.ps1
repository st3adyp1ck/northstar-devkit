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
    [ValidateScript({ $_ -eq 0 -or ($_ -ge 1 -and $_ -le 65535) })]
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
        try {
            Remove-Item -Path $nextPath -Recurse -Force -ErrorAction Stop
        } catch {
            # Fall through to the Test-Path check below to decide success.
        }

        if (-not (Test-Path $nextPath)) {
            Write-DevKitDone
        } else {
            Write-DevKitError "Could not fully clear .next cache. Stop the dev server and try again."
        }
    }

    Write-Host "`n  Starting dev server...`n" -ForegroundColor Green

    try {
        if (-not (Test-DevKitCommand $manager.Command)) {
            throw "$($manager.Command) is not installed or not in PATH."
        }

        $env:NEXT_TELEMETRY_DISABLED = "1"

        $devArgs = @("run", "dev")
        if ($Port -gt 0) { $devArgs += @("--", "--port", $Port) }

        & $manager.Command @devArgs
    } catch {
        Write-DevKitError $_
    }
}
