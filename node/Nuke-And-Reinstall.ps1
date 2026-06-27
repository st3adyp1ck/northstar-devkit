#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Nuke and Reinstall - Northstar DevKit
.DESCRIPTION
    Nuclear option: delete node_modules, lock files, caches, and reinstall.
    Auto-detects package manager (npm/yarn/pnpm/bun) from lock files.
    
    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Path
    The project directory. Defaults to current directory.
.PARAMETER SkipCacheClear
    Skip clearing package manager cache.
.PARAMETER Force
    Skip confirmation prompt.
.EXAMPLE
    .\Nuke-And-Reinstall.ps1
    .\Nuke-And-Reinstall.ps1 -Path "C:\my-project"
    .\Nuke-And-Reinstall.ps1 -Force
#>
[CmdletBinding()]
param(
    [string]$Path = ".",
    [switch]$SkipCacheClear,
    [switch]$Force
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

try {
    $targetPath = Resolve-DevKitDirectory -Path $Path
} catch {
    Write-DevKitHeader "NUKE AND REINSTALL"
    Write-DevKitError $_
    exit 1
}

Write-DevKitHeader "NUKE AND REINSTALL"
Write-DevKitInfo "Path: $targetPath"

$manager = Get-DevKitPackageManager -Path $targetPath
Write-DevKitInfo "Package manager: $($manager.Command)"

if (-not $Force) {
    Write-Host "  WARNING: This will permanently delete:" -ForegroundColor Yellow
    Write-Host "    - node_modules" -ForegroundColor Gray
    Write-Host "    - package-lock.json, yarn.lock, pnpm-lock.yaml, bun.lockb" -ForegroundColor Gray
    Write-Host "    - .next, dist, .vite caches" -ForegroundColor Gray
    Write-Host ""
    $confirm = Read-Host "  Type 'nuke' to confirm"
    if ($confirm -ne 'nuke') {
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
            Write-DevKitInfo "Stopped $killed process(es)"
        }
    }

    $steps += @{
        Name = "Clear Node caches"
        Action = {
            Clear-DevKitNodeCaches -Path . -IncludeTurbo | Out-Null
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

    if (-not $SkipCacheClear) {
        $steps += @{
            Name = "Clear package manager cache"
            Action = { Invoke-DevKitPackageCacheClean -Path . }
        }
    }

    $steps += @{
        Name = "Install dependencies"
        Action = { Invoke-DevKitPackageInstall -Path . }
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
}

Write-Host "`n  DONE: Nuclear reset complete!`n" -ForegroundColor Green
