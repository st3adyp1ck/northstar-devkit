#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Docker Nuke - Northstar DevKit
.DESCRIPTION
    Nuclear option for Docker: stops all running containers,
    removes all containers, images, volumes, and networks.
    This is the 'node_modules' of Docker - use with caution!
    
    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Force
    Skip all confirmation prompts.
.PARAMETER KeepVolumes
    Keep Docker volumes (only remove containers and images).
.PARAMETER KeepImages
    Keep Docker images (only remove containers).
.PARAMETER DryRun
    Show what would be deleted without making changes.
.EXAMPLE
    .\Docker-Nuke.ps1
    .\Docker-Nuke.ps1 -Force
    .\Docker-Nuke.ps1 -KeepVolumes
    .\Docker-Nuke.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$KeepVolumes,
    [switch]$KeepImages,
    [switch]$DryRun
)

Write-Host "`nNorthstar DevKit - DOCKER NUKE`n" -ForegroundColor Cyan
Write-Host "  WARNING: This will remove ALL Docker resources!" -ForegroundColor Red
Write-Host ""

# Check if Docker is available
try {
    $dockerVersion = docker --version 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Docker not found" }
    Write-Host "  Docker: $dockerVersion" -ForegroundColor Gray
} catch {
    Write-Host "  ERROR: Docker not found in PATH.`n" -ForegroundColor Red
    Write-Host "  Please install Docker Desktop or Docker Engine.`n" -ForegroundColor Yellow
    exit 1
}

# Check Docker daemon
try {
    $null = docker info 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Docker daemon not running" }
} catch {
    Write-Host "  ERROR: Docker daemon is not running.`n" -ForegroundColor Red
    Write-Host "  Please start Docker Desktop or Docker service.`n" -ForegroundColor Yellow
    exit 1
}

# Get current state
$containers = docker ps -aq 2>$null | Where-Object { $_ }
$images = docker images -q 2>$null | Where-Object { $_ }
$volumes = docker volume ls -q 2>$null | Where-Object { $_ }
$networks = docker network ls -q 2>$null | Where-Object { $_ -notmatch 'bridge|host|none' }

$containerCount = ($containers | Measure-Object).Count
$imageCount = ($images | Measure-Object).Count
$volumeCount = ($volumes | Measure-Object).Count
$networkCount = ($networks | Measure-Object).Count

# Show what will be affected
Write-Host "  Resources to be deleted:" -ForegroundColor Yellow
Write-Host "    Containers: $containerCount" -ForegroundColor $(if($containerCount -gt 0){'Red'}else{'Green'})
Write-Host "    Images:     $imageCount" -ForegroundColor $(if($imageCount -gt 0){'Red'}else{'Green'})
if (-not $KeepVolumes) {
    Write-Host "    Volumes:    $volumeCount" -ForegroundColor $(if($volumeCount -gt 0){'Red'}else{'Green'})
} else {
    Write-Host "    Volumes:    KEPT (KeepVolumes specified)" -ForegroundColor Green
}
Write-Host "    Networks:   $networkCount (custom only)" -ForegroundColor $(if($networkCount -gt 0){'Red'}else{'Green'})
Write-Host ""

# Nothing to do
if ($containerCount -eq 0 -and $imageCount -eq 0 -and ($KeepVolumes -or $volumeCount -eq 0) -and $networkCount -eq 0) {
    Write-Host "  OK: No Docker resources found. Nothing to nuke!`n" -ForegroundColor Green
    exit 0
}

# Dry run mode
if ($DryRun) {
    Write-Host "  [DRY RUN] No changes will be made.`n" -ForegroundColor Magenta
    
    if ($containerCount -gt 0) {
        Write-Host "  Containers that would be removed:" -ForegroundColor Yellow
        docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}" 2>$null | 
            Select-Object -Skip 1 |
            ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    }
    
    if ($imageCount -gt 0 -and -not $KeepImages) {
        Write-Host "`n  Images that would be removed:" -ForegroundColor Yellow
        docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}" 2>$null | 
            Select-Object -Skip 1 |
            ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    }
    
    Write-Host ""
    exit 0
}

# Confirm
if (-not $Force) {
    Write-Host "  Type 'NUKE' to confirm destruction of all Docker resources:" -ForegroundColor Red -NoNewline
    $confirm = Read-Host
    if ($confirm -ne 'NUKE') {
        Write-Host "`n  Cancelled. Wise choice!`n" -ForegroundColor Gray
        exit 0
    }
}

# Execute the nuke
$step = 1
$totalSteps = 3 + $(if(-not $KeepImages){1}else{0}) + $(if(-not $KeepVolumes){1}else{0})

# Step 1: Stop all containers
if ($containerCount -gt 0) {
    Write-Host "`n  [$step/$totalSteps] Stopping all containers..." -ForegroundColor Yellow
    docker stop $(docker ps -aq) 2>&1 | ForEach-Object { 
        if ($_ -match 'error|Error') {
            Write-Host "    ERROR: $_" -ForegroundColor Red
        }
    }
    Write-Host "  DONE: All containers stopped." -ForegroundColor Green
    $step++
    
    # Step 2: Remove all containers
    Write-Host "`n  [$step/$totalSteps] Removing all containers..." -ForegroundColor Yellow
    docker rm $(docker ps -aq) -f 2>&1 | ForEach-Object {
        if ($_ -match '^[a-f0-9]') {
            Write-Host "    Removed: $($_.Substring(0,12))" -ForegroundColor DarkGray
        }
    }
    Write-Host "  DONE: All containers removed." -ForegroundColor Green
    $step++
} else {
    Write-Host "`n  [$step/$totalSteps] No containers to remove." -ForegroundColor Green
    $step++
}

# Step 3: Remove images (unless KeepImages)
if (-not $KeepImages -and $imageCount -gt 0) {
    Write-Host "`n  [$step/$totalSteps] Removing all images..." -ForegroundColor Yellow
    docker rmi $(docker images -q) -f 2>&1 | ForEach-Object {
        if ($_ -match 'Untagged|Deleted') {
            Write-Host "    $_" -ForegroundColor DarkGray
        }
    }
    Write-Host "  DONE: All images removed." -ForegroundColor Green
    $step++
} elseif ($KeepImages) {
    Write-Host "`n  [$step/$totalSteps] Skipping images (KeepImages specified)." -ForegroundColor Green
    $step++
} else {
    Write-Host "`n  [$step/$totalSteps] No images to remove." -ForegroundColor Green
    $step++
}

# Step 4: Remove volumes (unless KeepVolumes)
if (-not $KeepVolumes -and $volumeCount -gt 0) {
    Write-Host "`n  [$step/$totalSteps] Removing all volumes..." -ForegroundColor Yellow
    docker volume rm $(docker volume ls -q) 2>&1 | ForEach-Object {
        if ($_ -match '^[a-f0-9]') {
            Write-Host "    Removed: $($_.Substring(0,12))..." -ForegroundColor DarkGray
        }
    }
    Write-Host "  DONE: All volumes removed." -ForegroundColor Green
    $step++
} elseif ($KeepVolumes) {
    Write-Host "`n  [$step/$totalSteps] Skipping volumes (KeepVolumes specified)." -ForegroundColor Green
    $step++
} else {
    Write-Host "`n  [$step/$totalSteps] No volumes to remove." -ForegroundColor Green
    $step++
}

# Step 5: Prune networks and build cache
Write-Host "`n  [$step/$totalSteps] Pruning networks and build cache..." -ForegroundColor Yellow
docker network prune -f 2>&1 | Out-Null
docker builder prune -f 2>&1 | Out-Null
Write-Host "  DONE: Networks and build cache pruned." -ForegroundColor Green

# Final system prune to clean up everything else
Write-Host "`n  Final cleanup with system prune..." -ForegroundColor Yellow
docker system prune -f --volumes:$($KeepVolumes -eq $false) 2>&1 | Out-Null

Write-Host "`n  ===================================" -ForegroundColor Cyan
Write-Host "  DOCKER NUKE COMPLETE!" -ForegroundColor Green
Write-Host "  All Docker resources have been destroyed." -ForegroundColor Gray
Write-Host "  ===================================`n" -ForegroundColor Cyan

# Show disk space recovered
$systemDf = docker system df 2>$null
if ($systemDf) {
    Write-Host "  Current Docker disk usage:" -ForegroundColor Gray
    $systemDf | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
}
Write-Host ""
