#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Nuke and Reinstall - Northstar DevKit
.DESCRIPTION
    Nuclear option: delete node_modules, lock file, and reinstall.
    Deletes node_modules, package-lock.json, clears npm cache,
    and runs fresh npm install.
    
    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Path
    The project directory. Defaults to current directory.
.PARAMETER SkipCacheClear
    Skip clearing npm cache.
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

Write-Host "`nNorthstar DevKit - NUKE AND REINSTALL`n" -ForegroundColor Cyan

if (-not (Test-Path $Path)) {
    Write-Host "  ERROR: Path not found: $Path`n" -ForegroundColor Red
    exit 1
}
$targetPath = (Resolve-Path $Path).Path

Write-Host "  Path: $targetPath`n" -ForegroundColor Gray

if (-not $Force) {
    Write-Host "  WARNING: This will permanently delete:" -ForegroundColor Yellow
    Write-Host "    - node_modules" -ForegroundColor Gray
    Write-Host "    - package-lock.json (and other lock files)" -ForegroundColor Gray
    Write-Host "    - .next, dist, .vite caches" -ForegroundColor Gray
    Write-Host ""
    $confirm = Read-Host "  Type 'nuke' to confirm"
    if ($confirm -ne 'nuke') {
        Write-Host "  Cancelled.`n" -ForegroundColor Gray
        exit 0
    }
}

try {
    Push-Location $targetPath

    $steps = @(
        @{ Name = "Stop node processes"; Action = { 
            $procs = Get-Process -Name "node" -ErrorAction SilentlyContinue | 
                Where-Object { $_.Path -like "*$targetPath*" }
            if ($procs) { 
                foreach ($proc in $procs) {
                    try { $proc | Stop-Process -Force } catch {}
                }
            }
        }},
        @{ Name = "Delete .next cache"; Action = { 
            if (Test-Path ".next") { 
                Remove-Item -Path ".next" -Recurse -Force 
            }
        }},
        @{ Name = "Delete node_modules"; Action = { 
            if (Test-Path "node_modules") { 
                # Use robocopy empty-folder trick for long-path safety
                $empty = Join-Path $env:TEMP "empty_devkit_$(Get-Random)"
                New-Item -ItemType Directory -Path $empty -Force | Out-Null
                robocopy $empty (Join-Path $targetPath "node_modules") /MIR /MT:8 /NFL /NDL /NJH /NJS | Out-Null
                Remove-Item -Path "node_modules" -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item $empty -Recurse -Force -ErrorAction SilentlyContinue
            }
        }},
        @{ Name = "Delete lock files"; Action = { 
            @("package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb") | ForEach-Object {
                if (Test-Path $_) { Remove-Item -Path $_ -Force }
            }
        }}
    )

    if (-not $SkipCacheClear) {
        $steps += @{ 
            Name = "Clear npm cache"; 
            Action = { 
                npm cache clean --force | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "npm cache clean failed" }
            } 
        }
    }

    $steps += @{ 
        Name = "npm install"; 
        Action = { 
            npm install
            if ($LASTEXITCODE -ne 0) { throw "npm install failed with exit code $LASTEXITCODE" }
        } 
    }

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

    Write-Host "`n  DONE: Nuclear reset complete!`n" -ForegroundColor Green
} finally {
    Pop-Location
}
