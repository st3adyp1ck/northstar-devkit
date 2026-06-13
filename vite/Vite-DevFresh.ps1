#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Vite Dev Fresh - Northstar DevKit
.DESCRIPTION
    Clear cache and start Vite dev server fresh.
    Removes .vite cache, node_modules/.cache, and optionally
    clears the browser cache before starting the server.
    
    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Path
    Path to Vite project. Defaults to current directory.
.PARAMETER Port
    Port for dev server. Uses vite.config or default 5173.
.PARAMETER Host
    Expose to network (0.0.0.0).
.PARAMETER ClearNodeModules
    Also clear node_modules before reinstall.
.PARAMETER SkipInstall
    Skip npm install (just clear caches).
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

Write-Host "`nNorthstar DevKit - Vite Dev Fresh`n" -ForegroundColor Cyan

if (-not (Test-Path $Path)) {
    Write-Host "  ERROR: Path not found: $Path`n" -ForegroundColor Red
    exit 1
}
$targetPath = (Resolve-Path $Path).Path

Write-Host "  Path: $targetPath" -ForegroundColor Gray
Write-Host ""

try {
    Push-Location $targetPath

    # Check if this is a Vite project
    if (-not (Test-Path "package.json")) {
        Write-Host "  ERROR: No package.json found. Not a Node.js project?`n" -ForegroundColor Red
        exit 1
    }

    $packageJson = Get-Content "package.json" | ConvertFrom-Json
    $hasVite = ($packageJson.devDependencies.PSObject.Properties.Name -contains "vite") -or
               ($packageJson.dependencies.PSObject.Properties.Name -contains "vite")

    if (-not $hasVite) {
        Write-Host "  WARNING: Vite not found in package.json`n" -ForegroundColor Yellow
        $continue = Read-Host "  Continue anyway? (y/n)"
        if ($continue -ne 'y') {
            Write-Host "  Cancelled.`n" -ForegroundColor Gray
            exit 0
        }
    }

    # Clear caches
    Write-Host "  Clearing caches..." -ForegroundColor Yellow

    $cachePaths = @(
        ".vite",
        "node_modules/.vite",
        "node_modules/.cache",
        "dist",
        "*.timestamp-*"
    )

    foreach ($cachePath in $cachePaths) {
        $fullPath = Join-Path $targetPath $cachePath
        if (Test-Path $fullPath) {
            try {
                Remove-Item -Path $fullPath -Recurse -Force -ErrorAction Stop
                Write-Host "    Deleted: $cachePath" -ForegroundColor Green
            } catch {
                Write-Host "    Could not delete: $cachePath" -ForegroundColor Yellow
            }
        }
    }

    Write-Host "  DONE: Caches cleared." -ForegroundColor Green

    # Clear node_modules if requested
    if ($ClearNodeModules) {
        Write-Host "`n  Clearing node_modules..." -ForegroundColor Yellow
        if (Test-Path "node_modules") {
            Remove-Item -Path "node_modules" -Recurse -Force
            Write-Host "  DONE: node_modules deleted." -ForegroundColor Green
        }
    }

    # Install dependencies
    if (-not $SkipInstall) {
        Write-Host "`n  Installing dependencies..." -ForegroundColor Yellow
        npm install
        if ($LASTEXITCODE -ne 0) {
            Write-Host "`n  ERROR: npm install failed.`n" -ForegroundColor Red
            exit 1
        }
        Write-Host "  DONE: Dependencies installed." -ForegroundColor Green
    }

    # Build dev args
    $devArgs = @()
    if ($Port -gt 0) { $devArgs += "--port"; $devArgs += $Port }
    if ($ExposeHost) { $devArgs += "--host" }

    Write-Host "`n  ===================================" -ForegroundColor Cyan
    Write-Host "  Starting Vite dev server..." -ForegroundColor Green
    Write-Host "  ===================================`n" -ForegroundColor Cyan

    if ($devArgs.Count -gt 0) {
        & npm run dev -- @devArgs
    } else {
        & npm run dev
    }
} finally {
    Pop-Location
}
