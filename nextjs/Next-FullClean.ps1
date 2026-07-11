#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Next.js Full Clean - Northstar DevKit
.DESCRIPTION
    Full Next.js project clean.
    Stops dev server, clears all caches (Next.js + Turbopack),
    deletes node_modules and lock files, reinstalls dependencies.
    Auto-detects package manager.
    
    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Path
    The project directory. Defaults to current directory.
.PARAMETER StartDev
    Start dev server after cleaning.
.PARAMETER Force
    Skip confirmation prompt.
.EXAMPLE
    .\Next-FullClean.ps1
    .\Next-FullClean.ps1 -StartDev
    .\Next-FullClean.ps1 -Force
#>
[CmdletBinding()]
param(
    [string]$Path = ".",
    [switch]$StartDev,
    [switch]$Force
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

try {
    $targetPath = Resolve-DevKitDirectory -Path $Path
} catch {
    Write-DevKitHeader "Next.js FULL CLEAN"
    Write-DevKitError $_
    exit 1
}

Write-DevKitHeader "Next.js FULL CLEAN"
Write-DevKitInfo "Path: $targetPath"

$manager = Get-DevKitPackageManager -Path $targetPath
Write-DevKitInfo "Package manager: $($manager.Command)"

if (-not $Force) {
    Write-Host "  WARNING: This will permanently delete:" -ForegroundColor Yellow
    Write-Host "    - .next, .turbo, node_modules/.cache, node_modules/.vite" -ForegroundColor Gray
    Write-Host "    - dist, .vite (build output)" -ForegroundColor Gray
    Write-Host "    - node_modules" -ForegroundColor Gray
    Write-Host "    - package-lock.json, yarn.lock, pnpm-lock.yaml, bun.lockb" -ForegroundColor Gray
    Write-Host ""
    $confirm = Read-Host "  Continue? (y/n)"
    if ($confirm -ne 'y') {
        Write-DevKitInfo "Cancelled."
        exit 0
    }
}

Invoke-DevKitInDirectory -Path $targetPath -ScriptBlock {
    $steps = @()

    $steps += @{
        Name = "Stop local node processes"
        Action = {
            $killed = Stop-DevKitNodeProcesses -Path .
            # Always emit output (and a newline) here regardless of $killed -
            # this step is excluded from the loop's generic Write-DevKitDone
            # call below, so without this the next step's step-header would
            # print on the same line when 0 processes were killed.
            Write-DevKitDone
            if ($killed -gt 0) {
                Write-DevKitInfo "Stopped $killed process(es)"
            }
        }
    }

    $steps += @{
        Name = "Clear Next.js and Turbopack caches"
        Action = {
            Clear-DevKitNodeCaches -Path . -IncludeTurbo -IncludeBuildOutput | Out-Null
        }
    }

    $steps += @{
        Name = "Delete node_modules"
        Action = {
            if (Remove-DevKitNodeModules -Path .) {
                Write-DevKitDone
            } else {
                Write-DevKitSkip
            }
        }
    }

    $steps += @{
        Name = "Delete lock files"
        Action = {
            @("package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb") | ForEach-Object {
                if (Test-Path $_) { Remove-Item -Path $_ -Force }
            }
        }
    }

    $steps += @{
        Name = "Clear package manager cache"
        Action = { Invoke-DevKitPackageCacheClean -Path . -Manager $manager }
    }

    $steps += @{
        Name = "Install dependencies"
        Action = { Invoke-DevKitPackageInstall -Path . -Manager $manager }
    }

    $stepNum = 1
    foreach ($step in $steps) {
        Write-DevKitStep "[$stepNum/$($steps.Count)] $($step.Name)"
        try {
            & $step.Action
            if ($step.Name -notin @("Delete node_modules", "Stop local node processes")) {
                Write-DevKitDone
            }
        } catch {
            Write-DevKitError $_
            exit 1
        }
        $stepNum++
    }

    Write-Host "`n  DONE: Full clean complete!`n" -ForegroundColor Green

    if ($StartDev) {
        Write-Host "  Starting dev server...`n" -ForegroundColor Green
        try {
            if (-not (Test-DevKitCommand $manager.Command)) {
                throw "$($manager.Command) is not installed or not in PATH."
            }
            $env:NEXT_TELEMETRY_DISABLED = "1"
            & $manager.Command @("run", "dev")
        } catch {
            Write-DevKitError $_
        }
    }
}
