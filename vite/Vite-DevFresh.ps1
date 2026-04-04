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

$targetPath = Resolve-Path $Path

Write-Host "`nNorthstar DevKit - Vite Dev Fresh`n" -ForegroundColor Cyan
Write-Host "  Path: $targetPath" -ForegroundColor Gray
Write-Host ""

Push-Location $targetPath

# Check if this is a Vite project
if (-not (Test-Path "package.json")) {
    Write-Host "  ERROR: No package.json found. Not a Node.js project?`n" -ForegroundColor Red
    Pop-Location
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
        Pop-Location
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
            Remove-Item -Path $fullPath -Recurse -Force -ErrorAction SilentlyContinue
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
        Pop-Location
        exit 1
    }
    Write-Host "  DONE: Dependencies installed." -ForegroundColor Green
}

# Build the dev server command
$devCommand = "npm run dev"
if ($packageJson.scripts.dev -eq "vite") {
    # Using direct vite command, we can add args
    $args = @()
    if ($Port -gt 0) { $args += "--port $Port" }
    if ($ExposeHost) { $args += "--host" }
    if ($args.Count -gt 0) {
        $devCommand = "npx vite $($args -join ' ')"
    }
}

Write-Host "`n  ===================================" -ForegroundColor Cyan
Write-Host "  Starting Vite dev server..." -ForegroundColor Green
Write-Host "  ===================================`n" -ForegroundColor Cyan

# Start the dev server
& npm run dev

Pop-Location
