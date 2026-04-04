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
.EXAMPLE
    .\Next-FullClean.ps1
    .\Next-FullClean.ps1 -StartDev
#>
[CmdletBinding()]
param(
    [string]$Path = ".",
    [switch]$StartDev
)

$targetPath = Resolve-Path $Path

Write-Host "`nNorthstar DevKit - Next.js FULL CLEAN`n" -ForegroundColor Cyan
Write-Host "  Path: $targetPath`n" -ForegroundColor Gray

Push-Location $targetPath

$steps = @(
    @{ 
        Name = "Stop local node processes"; 
        Action = { 
            $procs = Get-Process -Name "node" -ErrorAction SilentlyContinue | 
                Where-Object { $_.Path -like "*$targetPath*" }
            if ($procs) { 
                Write-Host "    Found $($procs.Count) process(es)" -ForegroundColor Gray
                $procs | Stop-Process -Force 
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
                Remove-Item -Path "node_modules" -Recurse -Force 
            }
        }
    },
    @{ 
        Name = "Delete package-lock.json"; 
        Action = { 
            if (Test-Path "package-lock.json") { 
                Remove-Item -Path "package-lock.json" -Force 
            }
        }
    },
    @{ 
        Name = "Clear npm cache"; 
        Action = { npm cache clean --force | Out-Null } 
    },
    @{ 
        Name = "npm install"; 
        Action = { npm install } 
    }
)

$stepNum = 1
foreach ($step in $steps) {
    Write-Host "  [$stepNum/$($steps.Count)] $($step.Name)..." -ForegroundColor Yellow
    try {
        & $step.Action
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0 -and $step.Name -eq "npm install") {
            throw "npm install failed"
        }
    } catch {
        Write-Host "  ERROR: $_`n" -ForegroundColor Red
        Pop-Location
        exit 1
    }
    $stepNum++
}

Pop-Location

Write-Host "`n  DONE: Full clean complete!`n" -ForegroundColor Green

if ($StartDev) {
    Write-Host "  Starting dev server...`n" -ForegroundColor Green
    Push-Location $targetPath
    npm run dev
    Pop-Location
}
