#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Docker Cleanup - Northstar DevKit
.DESCRIPTION
    Selective cleanup of Docker resources. Removes dangling images,
    unused volumes, stopped containers, and optionally untagged images.
    Safer than Docker-Nuke - targets only unused resources.
    
    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER DanglingOnly
    Only remove dangling (untagged) images.
.PARAMETER Volumes
    Also remove unused volumes.
.PARAMETER AllUnused
    Remove all unused containers, networks, images (not just dangling).
.PARAMETER Force
    Skip confirmation prompts.
.PARAMETER DryRun
    Show what would be removed without making changes.
.EXAMPLE
    .\Docker-Cleanup.ps1
    .\Docker-Cleanup.ps1 -DanglingOnly
    .\Docker-Cleanup.ps1 -Volumes -Force
    .\Docker-Cleanup.ps1 -AllUnused -DryRun
#>
[CmdletBinding()]
param(
    [switch]$DanglingOnly,
    [switch]$Volumes,
    [switch]$AllUnused,
    [switch]$Force,
    [switch]$DryRun
)

Write-Host "`nNorthstar DevKit - Docker Cleanup`n" -ForegroundColor Cyan

# Check Docker
try {
    $dockerVersion = docker --version 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Docker not found" }
} catch {
    Write-Host "  ERROR: Docker not found in PATH.`n" -ForegroundColor Red
    exit 1
}

try {
    $null = docker info 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Docker daemon not running" }
} catch {
    Write-Host "  ERROR: Docker daemon is not running.`n" -ForegroundColor Red
    exit 1
}

# Get current state
$exitedContainers = docker ps -aq -f "status=exited" 2>$null | Where-Object { $_ }
$danglingImages = docker images -q -f "dangling=true" 2>$null | Where-Object { $_ }
$unusedVolumes = docker volume ls -q -f "dangling=true" 2>$null | Where-Object { $_ }
$unusedNetworks = docker network ls -q -f "type=custom" 2>$null | Where-Object { $_ }

$containerCount = ($exitedContainers | Measure-Object).Count
$danglingCount = ($danglingImages | Measure-Object).Count
$volumeCount = ($unusedVolumes | Measure-Object).Count
$networkCount = ($unusedNetworks | Measure-Object).Count

# Calculate reclaimable space
$df = docker system df 2>$null
$reclaimable = "Unknown"
if ($df) {
    $imagesLine = $df | Select-String "Images"
    if ($imagesLine -match '(\d+\.?\d*\s*(B|KB|MB|GB))\s+\((\d+)%\s+reclaimable\)') {
        $reclaimable = $matches[1]
    }
}

# Show status
Write-Host "  Resources available for cleanup:" -ForegroundColor Yellow
Write-Host "    Stopped containers: $containerCount" -ForegroundColor $(if($containerCount -gt 0){'Yellow'}else{'Green'})
Write-Host "    Dangling images:    $danglingCount" -ForegroundColor $(if($danglingCount -gt 0){'Yellow'}else{'Green'})
if ($Volumes -or $AllUnused) {
    Write-Host "    Unused volumes:     $volumeCount" -ForegroundColor $(if($volumeCount -gt 0){'Yellow'}else{'Green'})
}
if ($AllUnused) {
    Write-Host "    Custom networks:    $networkCount" -ForegroundColor $(if($networkCount -gt 0){'Yellow'}else{'Green'})
}
Write-Host "    Estimated reclaimable: $reclaimable" -ForegroundColor Cyan
Write-Host ""

# Check if there's anything to clean
if ($containerCount -eq 0 -and $danglingCount -eq 0 -and 
    (-not $Volumes -or $volumeCount -eq 0) -and 
    (-not $AllUnused -or $networkCount -eq 0)) {
    Write-Host "  OK: Nothing to clean up!`n" -ForegroundColor Green
    exit 0
}

# Dry run - show details
if ($DryRun) {
    Write-Host "  [DRY RUN] No changes will be made.`n" -ForegroundColor Magenta
    
    if ($containerCount -gt 0) {
        Write-Host "  Stopped containers:" -ForegroundColor Yellow
        docker ps -a -f "status=exited" --format "table {{.Names}}\t{{.Image}}\t{{.Status}}" 2>$null |
            Select-Object -Skip 1 |
            ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    }
    
    if ($danglingCount -gt 0) {
        Write-Host "`n  Dangling images:" -ForegroundColor Yellow
        docker images -f "dangling=true" --format "table {{.ID}}\t{{.Size}}\t{{.CreatedAt}}" 2>$null |
            Select-Object -Skip 1 |
            ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    }
    
    Write-Host ""
    exit 0
}

# Confirm
if (-not $Force) {
    $confirm = Read-Host "  Proceed with cleanup? (y/n)"
    if ($confirm -ne 'y') {
        Write-Host "`n  Cancelled.`n" -ForegroundColor Gray
        exit 0
    }
}

# Execute cleanup
Write-Host ""
$step = 1

# Step 1: Remove stopped containers
if ($containerCount -gt 0) {
    Write-Host "  [$step] Removing stopped containers..." -ForegroundColor Yellow
    docker container prune -f 2>&1 | ForEach-Object {
        if ($_ -match 'Deleted Containers') {
            Write-Host "    $_" -ForegroundColor Green
        }
    }
    $step++
}

# Step 2: Remove images (dangling or all unused)
if ($danglingCount -gt 0 -or ($AllUnused -and $df)) {
    Write-Host "  [$step] Removing unused images..." -ForegroundColor Yellow
    if ($AllUnused) {
        docker image prune -a -f 2>&1 | ForEach-Object {
            if ($_ -match 'Deleted Images|Total reclaimed') {
                Write-Host "    $_" -ForegroundColor Green
            }
        }
    } else {
        docker image prune -f 2>&1 | ForEach-Object {
            if ($_ -match 'Deleted Images|Total reclaimed') {
                Write-Host "    $_" -ForegroundColor Green
            }
        }
    }
    $step++
}

# Step 3: Remove volumes if requested
if ($Volumes -and $volumeCount -gt 0) {
    Write-Host "  [$step] Removing unused volumes..." -ForegroundColor Yellow
    docker volume prune -f 2>&1 | ForEach-Object {
        if ($_ -match 'Deleted Volumes|Total reclaimed') {
            Write-Host "    $_" -ForegroundColor Green
        }
    }
    $step++
}

# Step 4: Build cache
Write-Host "  [$step] Cleaning build cache..." -ForegroundColor Yellow
docker builder prune -f 2>&1 | ForEach-Object {
    if ($_ -match 'Total reclaimed') {
        Write-Host "    $_" -ForegroundColor Green
    }
}

# Final summary
Write-Host "`n  ===================================" -ForegroundColor Cyan
Write-Host "  Docker cleanup complete!" -ForegroundColor Green
$finalDf = docker system df --format "{{.Type}}: {{.Size}}" 2>$null
if ($finalDf) {
    Write-Host "  Current usage:" -ForegroundColor Gray
    $finalDf | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
}
Write-Host "  ===================================`n" -ForegroundColor Cyan
