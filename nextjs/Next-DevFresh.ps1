#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Next.js Dev Fresh Start - Northstar DevKit
.DESCRIPTION
    Clears .next cache and starts the dev server.
    Optionally clears Turbopack cache too.
    
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

$targetPath = Resolve-Path $Path

Write-Host "`nNorthstar DevKit - Next.js Dev Server (Fresh)`n" -ForegroundColor Cyan
Write-Host "  Path: $targetPath`n" -ForegroundColor Gray

Push-Location $targetPath

# Clear .next cache
if (Test-Path ".next") {
    Write-Host "  Clearing .next cache..." -ForegroundColor Yellow
    Remove-Item -Path ".next" -Recurse -Force
    Write-Host "  DONE" -ForegroundColor Green
}

# Clear Turbopack cache if requested
if ($Turbo) {
    $turboPaths = @(
        (Join-Path ".next" "cache"),
        (Join-Path "node_modules" ".cache"),
        ".turbo"
    )
    foreach ($tp in $turboPaths) {
        if (Test-Path $tp) {
            Write-Host "  Clearing $tp..." -ForegroundColor Yellow
            Remove-Item -Path $tp -Recurse -Force
        }
    }
    Write-Host "  DONE: Turbopack cache cleared" -ForegroundColor Green
}

Write-Host "`n  Starting dev server...`n" -ForegroundColor Green

$env:NEXT_TELEMETRY_DISABLED = "1"

if ($Port -gt 0) {
    npm run dev -- --port $Port
} else {
    npm run dev
}

Pop-Location
