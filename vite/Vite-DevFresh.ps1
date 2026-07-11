#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Vite Dev Fresh - Northstar DevKit
.DESCRIPTION
    Clear cache and start Vite dev server fresh.
    Removes .vite cache, node_modules/.cache, and optionally
    clears node_modules before starting the server. Never touches the
    production build output (dist), even with -ClearNodeModules.
    Auto-detects package manager.
    
    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Path
    Path to Vite project. Defaults to current directory.
.PARAMETER Port
    Port for dev server. Uses vite.config or default 5173.
.PARAMETER ExposeHost
    Expose to network (0.0.0.0).
.PARAMETER ClearNodeModules
    Also clear node_modules before reinstall.
.PARAMETER SkipInstall
    Skip package install (just clear caches).
.EXAMPLE
    .\Vite-DevFresh.ps1
    .\Vite-DevFresh.ps1 -Port 3000
    .\Vite-DevFresh.ps1 -ClearNodeModules
    .\Vite-DevFresh.ps1 -ExposeHost
#>
[CmdletBinding()]
param(
    [string]$Path = ".",
    [int]$Port = 0,
    [switch]$ExposeHost,
    [switch]$ClearNodeModules,
    [switch]$SkipInstall
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

try {
    $targetPath = Resolve-DevKitDirectory -Path $Path
} catch {
    Write-DevKitHeader "Vite Dev Fresh"
    Write-DevKitError $_
    exit 1
}

Write-DevKitHeader "Vite Dev Fresh"
Write-DevKitInfo "Path: $targetPath"

$manager = Get-DevKitPackageManager -Path $targetPath
Write-DevKitInfo "Package manager: $($manager.Command)"

try {
    Invoke-DevKitInDirectory -Path $targetPath -ScriptBlock {
        # Check if this is a Vite project
        if (-not (Test-Path "package.json")) {
            Write-DevKitError "No package.json found. Not a Node.js project?"
            exit 1
        }

        $packageJson = Get-Content "package.json" | ConvertFrom-Json
        $hasVite = ($packageJson.devDependencies.PSObject.Properties.Name -contains "vite") -or
                   ($packageJson.dependencies.PSObject.Properties.Name -contains "vite")

        if (-not $hasVite) {
            Write-Host "  WARNING: Vite not found in package.json" -ForegroundColor Yellow
            $continue = Read-Host "  Continue anyway? (y/n)"
            if ($continue -ne 'y') {
                Write-DevKitInfo "Cancelled."
                exit 0
            }
        }

        # Clear caches (build output such as dist/.vite is intentionally left
        # alone here - a "dev fresh start" should never touch a production build)
        Write-DevKitStep "Clearing caches"
        if (Clear-DevKitNodeCaches -Path $targetPath) {
            Write-DevKitDone
        } else {
            Write-DevKitSkip
        }

        # Clear node_modules if requested
        if ($ClearNodeModules) {
            Write-DevKitStep "Clearing node_modules"
            if (Remove-DevKitNodeModules -Path .) {
                Write-DevKitDone
            } else {
                Write-DevKitSkip
            }
        }

        # Install dependencies
        if (-not $SkipInstall) {
            Write-DevKitStep "Installing dependencies"
            Invoke-DevKitPackageInstall -Path .
            Write-DevKitDone
        }

        # Build dev args
        $devArgs = @("run", "dev")
        $viteArgs = @()
        if ($Port -gt 0) { $viteArgs += @("--port", $Port) }
        if ($ExposeHost) { $viteArgs += "--host" }
        if ($viteArgs.Count -gt 0) { $devArgs += @("--") + $viteArgs }

        # Warn (but do not block) if the target port is already occupied -
        # Vite will fall back to the next free port on its own.
        $checkPort = if ($Port -gt 0) { $Port } else { 5173 }
        $portOwner = Get-DevKitProcessByPort -Port $checkPort
        if ($portOwner) {
            Write-Host "  WARNING: Port $checkPort is already in use by $($portOwner.Name) (PID $($portOwner.PID)). Vite will try the next available port." -ForegroundColor Yellow
        }

        Write-Host "`n  ===================================" -ForegroundColor Cyan
        Write-Host "  Starting Vite dev server..." -ForegroundColor Green
        Write-Host "  ===================================`n" -ForegroundColor Cyan

        & $manager.Command @devArgs
    }
} catch {
    Write-DevKitError $_
    exit 1
}
