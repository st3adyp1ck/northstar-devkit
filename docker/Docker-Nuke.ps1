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
#>[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$KeepVolumes,
    [switch]$KeepImages,
    [switch]$DryRun
)


$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }


Write-Host "`nNorthstar DevKit - DOCKER NUKE`n" -ForegroundColor Cyan
Write-Host "  WARNING: This will remove ALL Docker resources!" -ForegroundColor Yellow
Write-Host ""

# Check if Docker is available
if (-not (Test-DevKitCommand "docker")) {
    Write-Host "  ERROR: Docker not found in PATH.`n" -ForegroundColor Red
    Write-Host "  Please install Docker Desktop or Docker Engine.`n" -ForegroundColor Yellow
    exit 1
}
$dockerVersion = docker --version 2>$null
Write-Host "  Docker: $dockerVersion" -ForegroundColor Gray

# Check Docker daemon
$null = docker info 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  ERROR: Docker daemon is not running.`n" -ForegroundColor Red
    Write-Host "  Please start Docker Desktop or Docker service.`n" -ForegroundColor Yellow
    exit 1
}

# Get current state
$containers = docker ps -aq 2>$null | Where-Object { $_ }
$images = docker images -q 2>$null | Where-Object { $_ }
$volumes = docker volume ls -q 2>$null | Where-Object { $_ }
$networks = docker network ls --format "{{.Name}}" 2>$null | Where-Object { $_ -notmatch '^(bridge|host|none)$' }

$containerCount = ($containers | Measure-Object).Count
$imageCount = ($images | Measure-Object).Count
$volumeCount = ($volumes | Measure-Object).Count
$networkCount = ($networks | Measure-Object).Count

# Show what will be affected
Write-Host "  Resources to be deleted:" -ForegroundColor Yellow
Write-Host "    Containers: $containerCount" -ForegroundColor $(if($containerCount -gt 0){'Red'}else{'Green'})
if (-not $KeepImages) {
    Write-Host "    Images:     $imageCount" -ForegroundColor $(if($imageCount -gt 0){'Red'}else{'Green'})
} else {
    Write-Host "    Images:     KEPT (KeepImages specified)" -ForegroundColor Green
}
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

# Confirm - uses the shared gate (lib/DevKit-Common.ps1) so the typed-phrase
# comparison is guaranteed case-sensitive and this respects the user's
# confirmDestructive setting consistently with every other destructive tool.
if (-not (Confirm-DevKitDestructiveAction -Action "destroy ALL Docker containers, images, volumes, and networks" -TypedPhrase 'NUKE' -Force:$Force)) {
    Write-Host "`n  Cancelled. Wise choice!`n" -ForegroundColor Gray
    exit 0
}

# Execute the nuke
$step = 1

# Build the total step count from the same conditions the steps below
# actually branch on, so the displayed "[n/total]" progress cannot drift
# out of sync with the number of increments that really happen.
$containerSteps = if ($containerCount -gt 0) { 2 } else { 1 }
$imageSteps = 1
$volumeSteps = 1
$networkSteps = 1
$totalSteps = $containerSteps + $imageSteps + $volumeSteps + $networkSteps

# Step 1: Stop all containers
if ($containerCount -gt 0) {
    Write-Host "`n  [$step/$totalSteps] Stopping all containers..." -ForegroundColor Yellow
    $stopHadErrors = $false
    $stopOutput = @(docker stop $(docker ps -aq) 2>&1)
    foreach ($line in $stopOutput) {
        if ($line -match 'error|Error') {
            Write-Host "    ERROR: $line" -ForegroundColor Red
            $stopHadErrors = $true
        }
    }
    if ($stopHadErrors -or $LASTEXITCODE -ne 0) {
        Write-Host "  WARNING: Some containers may not have stopped cleanly." -ForegroundColor Yellow
    } else {
        Write-Host "  DONE: All containers stopped." -ForegroundColor Green
    }
    $step++

    # Step 2: Remove all containers
    Write-Host "`n  [$step/$totalSteps] Removing all containers..." -ForegroundColor Yellow
    $removeHadErrors = $false
    $removeOutput = @(docker rm -f $(docker ps -aq) 2>&1)
    foreach ($line in $removeOutput) {
        if ($line -match '^[a-f0-9]') {
            Write-Host "    Removed: $($line.Substring(0,12))" -ForegroundColor DarkGray
        } elseif ($line -match 'error|Error') {
            Write-Host "    ERROR: $line" -ForegroundColor Red
            $removeHadErrors = $true
        }
    }
    if ($removeHadErrors -or $LASTEXITCODE -ne 0) {
        Write-Host "  WARNING: Some containers may not have been removed cleanly." -ForegroundColor Yellow
    } else {
        Write-Host "  DONE: All containers removed." -ForegroundColor Green
    }
    $step++
} else {
    Write-Host "`n  [$step/$totalSteps] No containers to remove." -ForegroundColor Green
    $step++
}

# Step 3: Remove images (unless KeepImages)
if (-not $KeepImages -and $imageCount -gt 0) {
    Write-Host "`n  [$step/$totalSteps] Removing all images..." -ForegroundColor Yellow
    $imagesHadErrors = $false
    $imagesOutput = @(docker rmi -f $(docker images -q) 2>&1)
    foreach ($line in $imagesOutput) {
        if ($line -match 'Untagged|Deleted') {
            Write-Host "    $line" -ForegroundColor DarkGray
        } elseif ($line -match 'error|Error') {
            Write-Host "    ERROR: $line" -ForegroundColor Red
            $imagesHadErrors = $true
        }
    }
    if ($imagesHadErrors -or $LASTEXITCODE -ne 0) {
        Write-Host "  WARNING: Some images may not have been removed cleanly." -ForegroundColor Yellow
    } else {
        Write-Host "  DONE: All images removed." -ForegroundColor Green
    }
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
    $volumesHadErrors = $false
    $volumesOutput = @(docker volume rm $(docker volume ls -q) 2>&1)
    foreach ($line in $volumesOutput) {
        if ($line -match '^[a-f0-9]') {
            Write-Host "    Removed: $($line.Substring(0,12))..." -ForegroundColor DarkGray
        } elseif ($line -match 'error|Error') {
            Write-Host "    ERROR: $line" -ForegroundColor Red
            $volumesHadErrors = $true
        }
    }
    if ($volumesHadErrors -or $LASTEXITCODE -ne 0) {
        Write-Host "  WARNING: Some volumes may not have been removed cleanly." -ForegroundColor Yellow
    } else {
        Write-Host "  DONE: All volumes removed." -ForegroundColor Green
    }
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

# Final system prune to clean up everything else. NOTE: `docker system prune -f`
# (without -a) still removes DANGLING images even though -a was not passed, so
# when -KeepImages is set we must skip this step's image-cleaning side effect
# entirely rather than running the unscoped prune.
if ($KeepImages) {
    Write-Host "`n  Skipping final system prune (KeepImages specified - system prune still removes dangling images)." -ForegroundColor Green
    if (-not $KeepVolumes) {
        Write-Host "  Pruning remaining anonymous volumes..." -ForegroundColor Yellow
        docker volume prune -f 2>&1 | Out-Null
    }
} else {
    Write-Host "`n  Final cleanup with system prune..." -ForegroundColor Yellow
    $pruneArgs = @("system", "prune", "-f")
    if (-not $KeepVolumes) { $pruneArgs += "--volumes" }
    docker @pruneArgs 2>&1 | Out-Null
}

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
