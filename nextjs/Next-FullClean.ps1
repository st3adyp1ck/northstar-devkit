#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Next.js Full Clean - Northstar DevKit
.DESCRIPTION
    Full Next.js project clean.
    Stops dev server, clears all caches (Next.js + Turbopack),
    deletes node_modules and lock file, reinstalls dependencies.
    
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

Write-Host "`nNorthstar DevKit - Next.js FULL CLEAN`n" -ForegroundColor Cyan

if (-not (Test-Path $Path)) {
    Write-Host "  ERROR: Path not found: $Path`n" -ForegroundColor Red
    exit 1
}
$targetPath = (Resolve-Path $Path).Path

Write-Host "  Path: $targetPath`n" -ForegroundColor Gray

if (-not $Force) {
    Write-Host "  WARNING: This will permanently delete:" -ForegroundColor Yellow
    Write-Host "    - .next, .turbo, node_modules/.cache" -ForegroundColor Gray
    Write-Host "    - node_modules" -ForegroundColor Gray
    Write-Host "    - package-lock.json, yarn.lock, pnpm-lock.yaml, bun.lockb" -ForegroundColor Gray
    Write-Host ""
    $confirm = Read-Host "  Continue? (y/n)"
    if ($confirm -ne 'y') {
        Write-Host "  Cancelled.`n" -ForegroundColor Gray
        exit 0
    }
}

try {
    Push-Location $targetPath

    $steps = @(
        @{ 
            Name = "Stop local node processes"; 
            Action = { 
                $procs = Get-Process -Name "node" -ErrorAction SilentlyContinue | 
                    Where-Object { $_.Path -eq (Join-Path $targetPath "node_modules") -or $_.Path -like "*$targetPath\*" }
                if ($procs) { 
                    Write-Host "    Found $($procs.Count) process(es)" -ForegroundColor Gray
                    foreach ($proc in $procs) {
                        try { $proc | Stop-Process -Force } catch {}
                    }
                } else {
                    Write-Host "    None found" -ForegroundColor Gray
                }
            }
        },
        @{ 
            Name = "Clear .next cache"; 
            Action = { 
                if (Test-Path ".next") { 
                    Remove-Item -Path ".next" -Recurse -Force 
                }
            }
        },
        @{ 
            Name = "Clear Turbopack cache"; 
            Action = { 
                @(".turbo", (Join-Path "node_modules" ".cache")) | ForEach-Object {
                    if (Test-Path $_) { Remove-Item -Path $_ -Recurse -Force }
                }
            }
        },
        @{ 
            Name = "Delete node_modules"; 
            Action = { 
                if (Test-Path "node_modules") { 
                    $empty = Join-Path $env:TEMP "empty_devkit_$(Get-Random)"
                    New-Item -ItemType Directory -Path $empty -Force | Out-Null
                    robocopy $empty (Join-Path $targetPath "node_modules") /MIR /MT:8 /NFL /NDL /NJH /NJS | Out-Null
                    Remove-Item -Path "node_modules" -Recurse -Force -ErrorAction SilentlyContinue
                    Remove-Item $empty -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        },
        @{ 
            Name = "Delete lock files"; 
            Action = { 
                @("package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb") | ForEach-Object {
                    if (Test-Path $_) { Remove-Item -Path $_ -Force }
                }
            }
        },
        @{ 
            Name = "Clear npm cache"; 
            Action = { 
                npm cache clean --force | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "npm cache clean failed" }
            } 
        },
        @{ 
            Name = "npm install"; 
            Action = { 
                npm install
                if ($LASTEXITCODE -ne 0) { throw "npm install failed" }
            } 
        }
    )

    $stepNum = 1
    foreach ($step in $steps) {
        Write-Host "  [$stepNum/$($steps.Count)] $($step.Name)..." -ForegroundColor Yellow
        try {
            & $step.Action
        } catch {
            Write-Host "  ERROR: $_`n" -ForegroundColor Red
            exit 1
        }
        $stepNum++
    }

    Write-Host "`n  DONE: Full clean complete!`n" -ForegroundColor Green

    if ($StartDev) {
        Write-Host "  Starting dev server...`n" -ForegroundColor Green
        $env:NEXT_TELEMETRY_DISABLED = "1"
        & npm run dev
    }
} finally {
    Pop-Location
}
