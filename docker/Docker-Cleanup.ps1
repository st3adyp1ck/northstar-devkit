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
#>[CmdletBinding()]
param(
    [switch]$DanglingOnly,
    [switch]$Volumes,
    [switch]$AllUnused,
    [switch]$Force,
    [switch]$DryRun
)


$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }


Write-Host "`nNorthstar DevKit - Docker Cleanup`n" -ForegroundColor Cyan

# Check Docker
try {
    $dockerVersion = docker --version 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Docker not found" }
} catch {
    Write-Host "  ERROR: Docker not found in PATH.`n" -ForegroundColor Red
    exit 1
}
Write-Host "  Docker: $dockerVersion" -ForegroundColor Gray

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

# When -AllUnused is set, compute a REAL "all unused images" count instead of
# reusing $danglingCount - dangling only covers untagged images, so a tagged
# image that simply isn't referenced by any container would otherwise never
# be counted, letting the early-exit gate wrongly report "nothing to clean".
$unusedImageCount = $danglingCount
if ($AllUnused) {
    $allImageIds = @(docker image ls -q 2>$null | Where-Object { $_ })
    $imageRepoTagLines = @(docker image ls --format "{{.ID}} {{.Repository}}:{{.Tag}}" 2>$null | Where-Object { $_ })

    # Map "repo:tag" -> image ID so we can resolve container image references
    # (which are usually a tag, not an ID) down to the same ID space as
    # `docker image ls -q` before diffing.
    $imageIdByRef = @{}
    foreach ($line in $imageRepoTagLines) {
        $parts = $line -split ' ', 2
        if ($parts.Count -eq 2) { $imageIdByRef[$parts[1]] = $parts[0] }
    }

    $usedImageRefs = @(docker ps -a --format "{{.Image}}" 2>$null | Where-Object { $_ })
    $usedImageIds = @()
    foreach ($ref in $usedImageRefs) {
        if ($imageIdByRef.ContainsKey($ref)) {
            $usedImageIds += $imageIdByRef[$ref]
        } else {
            # Already an ID (or digest reference) - use as-is
            $usedImageIds += $ref
        }
    }

    $unusedImageIds = @($allImageIds | Where-Object { $usedImageIds -notcontains $_ })
    $unusedImageCount = $unusedImageIds.Count
}

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
if ($AllUnused) {
    Write-Host "    All unused images:  $unusedImageCount" -ForegroundColor $(if($unusedImageCount -gt 0){'Yellow'}else{'Green'})
}
if ($Volumes -or $AllUnused) {
    Write-Host "    Unused volumes:     $volumeCount" -ForegroundColor $(if($volumeCount -gt 0){'Yellow'}else{'Green'})
}
if ($AllUnused) {
    Write-Host "    Custom networks:    $networkCount" -ForegroundColor $(if($networkCount -gt 0){'Yellow'}else{'Green'})
}
Write-Host "    Estimated reclaimable: $reclaimable" -ForegroundColor Cyan
Write-Host ""

# Check if there's anything to clean
if ($containerCount -eq 0 -and $unusedImageCount -eq 0 -and
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
$hadErrors = $false

# Step 1: Remove stopped containers
if ($containerCount -gt 0) {
    Write-Host "  [$step] Removing stopped containers..." -ForegroundColor Cyan
    $containersOutput = @(docker container prune -f 2>&1)
    foreach ($line in $containersOutput) {
        if ($line -match 'Deleted Containers') {
            Write-Host "    $line" -ForegroundColor Green
        } elseif ($line -match 'error|Error') {
            Write-Host "    ERROR: $line" -ForegroundColor Red
            $hadErrors = $true
        }
    }
    if ($LASTEXITCODE -ne 0) { $hadErrors = $true }
    $step++
}

# Step 2: Remove images (dangling, or all unused images when -AllUnused) -
# gated on the real $unusedImageCount computed above rather than the mere
# non-emptiness of `docker system df` text output.
if ($unusedImageCount -gt 0) {
    Write-Host "  [$step] Removing unused images..." -ForegroundColor Cyan
    if ($AllUnused) {
        $imagesOutput = @(docker image prune -a -f 2>&1)
    } else {
        $imagesOutput = @(docker image prune -f 2>&1)
    }
    foreach ($line in $imagesOutput) {
        if ($line -match 'Deleted Images|Total reclaimed') {
            Write-Host "    $line" -ForegroundColor Green
        } elseif ($line -match 'error|Error') {
            Write-Host "    ERROR: $line" -ForegroundColor Red
            $hadErrors = $true
        }
    }
    if ($LASTEXITCODE -ne 0) { $hadErrors = $true }
    $step++
}

# Step 3: Remove volumes if requested
if ($Volumes -and $volumeCount -gt 0) {
    Write-Host "  [$step] Removing unused volumes..." -ForegroundColor Cyan
    $volumesOutput = @(docker volume prune -f 2>&1)
    foreach ($line in $volumesOutput) {
        if ($line -match 'Deleted Volumes|Total reclaimed') {
            Write-Host "    $line" -ForegroundColor Green
        } elseif ($line -match 'error|Error') {
            Write-Host "    ERROR: $line" -ForegroundColor Red
            $hadErrors = $true
        }
    }
    if ($LASTEXITCODE -ne 0) { $hadErrors = $true }
    $step++
}

# Step 4: Remove unused custom networks (AllUnused only). The docstring/
# summary already claimed -AllUnused cleans up networks, but no step ever
# actually called `docker network prune` - this closes that gap.
if ($AllUnused -and $networkCount -gt 0) {
    Write-Host "  [$step] Removing unused networks..." -ForegroundColor Cyan
    $networksOutput = @(docker network prune -f 2>&1)
    foreach ($line in $networksOutput) {
        if ($line -match 'Deleted Networks|Total reclaimed') {
            Write-Host "    $line" -ForegroundColor Green
        } elseif ($line -match 'error|Error') {
            Write-Host "    ERROR: $line" -ForegroundColor Red
            $hadErrors = $true
        }
    }
    if ($LASTEXITCODE -ne 0) { $hadErrors = $true }
    $step++
}

# Step 5: Build cache
Write-Host "  [$step] Cleaning build cache..." -ForegroundColor Cyan
$builderOutput = @(docker builder prune -f 2>&1)
foreach ($line in $builderOutput) {
    if ($line -match 'Total reclaimed') {
        Write-Host "    $line" -ForegroundColor Green
    } elseif ($line -match 'error|Error') {
        Write-Host "    ERROR: $line" -ForegroundColor Red
        $hadErrors = $true
    }
}
if ($LASTEXITCODE -ne 0) { $hadErrors = $true }

# Final summary - only claim success if every preceding prune step actually
# came back clean.
Write-Host "`n  ===================================" -ForegroundColor Cyan
if ($hadErrors) {
    Write-Host "  Docker cleanup finished with errors - see above." -ForegroundColor Yellow
} else {
    Write-Host "  Docker cleanup complete!" -ForegroundColor Green
}
$finalDf = docker system df --format "{{.Type}}: {{.Size}}" 2>$null
if ($finalDf) {
    Write-Host "  Current usage:" -ForegroundColor Gray
    $finalDf | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
}
Write-Host "  ===================================`n" -ForegroundColor Cyan
