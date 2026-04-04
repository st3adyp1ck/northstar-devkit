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
.EXAMPLE
    .\Nuke-And-Reinstall.ps1
    .\Nuke-And-Reinstall.ps1 -Path "C:\my-project"
#>
[CmdletBinding()]
param(
    [string]$Path = ".",
    [switch]$SkipCacheClear
)

$targetPath = Resolve-Path $Path

Write-Host "`nNorthstar DevKit - NUKE AND REINSTALL`n" -ForegroundColor Cyan
Write-Host "  Path: $targetPath`n" -ForegroundColor Gray

Push-Location $targetPath

$steps = @(
    @{ Name = "Stop node processes"; Action = { 
        $procs = Get-Process -Name "node" -ErrorAction SilentlyContinue | 
            Where-Object { $_.Path -like "*$targetPath*" }
        if ($procs) { $procs | Stop-Process -Force }
    }},
    @{ Name = "Delete .next cache"; Action = { 
        if (Test-Path ".next") { 
            Remove-Item -Path ".next" -Recurse -Force 
        }
    }},
    @{ Name = "Delete node_modules"; Action = { 
        if (Test-Path "node_modules") { 
            Remove-Item -Path "node_modules" -Recurse -Force 
        }
    }},
    @{ Name = "Delete package-lock.json"; Action = { 
        if (Test-Path "package-lock.json") { 
            Remove-Item -Path "package-lock.json" -Force 
        }
    }}
)

if (-not $SkipCacheClear) {
    $steps += @{ 
        Name = "Clear npm cache"; 
        Action = { npm cache clean --force | Out-Null } 
    }
}

$steps += @{ Name = "npm install"; Action = { npm install } }

$stepNum = 1
foreach ($step in $steps) {
    Write-Host "  [$stepNum/$($steps.Count)] $($step.Name)..." -ForegroundColor Yellow
    try {
        & $step.Action
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0 -and $step.Name -eq "npm install") {
            throw "npm install failed with exit code $LASTEXITCODE"
        }
    } catch {
        Write-Host "  ERROR: $_`n" -ForegroundColor Red
        Pop-Location
        exit 1
    }
    $stepNum++
}

Pop-Location

Write-Host "`n  DONE: Nuclear reset complete!`n" -ForegroundColor Green
