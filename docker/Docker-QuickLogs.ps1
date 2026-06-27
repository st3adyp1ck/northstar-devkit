#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Docker Quick Logs - Northstar DevKit
.DESCRIPTION
    Tail logs from multiple Docker containers simultaneously
    with color-coded output for easy identification.
    
    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Container
    Specific container name(s) to tail. If not specified, shows all running containers.
.PARAMETER Lines
    Number of lines to show initially. Default: 50
.PARAMETER Follow
    Continue following logs (keep streaming). Default: true
.PARAMETER Timestamps
    Show timestamps in logs.
.EXAMPLE
    .\Docker-QuickLogs.ps1
    .\Docker-QuickLogs.ps1 -Container "my-app"
    .\Docker-QuickLogs.ps1 -Container "app1", "app2" -Lines 100
    .\Docker-QuickLogs.ps1 -Timestamps
#>[CmdletBinding()]
param(
    [string[]]$Container,
    [int]$Lines = 50,
    [switch]$Follow = $true,
    [switch]$Timestamps
)


$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }


Write-Host "`nNorthstar DevKit - Docker Quick Logs`n" -ForegroundColor Cyan

# Check Docker
$null = docker --version 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  ERROR: Docker not found in PATH.`n" -ForegroundColor Red
    exit 1
}

$null = docker info 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  ERROR: Docker daemon is not running.`n" -ForegroundColor Red
    exit 1
}

# Get containers to monitor
if ($Container) {
    $containers = $Container | ForEach-Object {
        $c = docker ps --filter "name=$_" --format "{{.Names}}" 2>$null
        if (-not $c) {
            Write-Host "  WARNING: Container '$_' not found or not running." -ForegroundColor Yellow
        }
        $c
    } | Where-Object { $_ }
} else {
    $containers = docker ps --format "{{.Names}}" 2>$null | Where-Object { $_ }
}

if (-not $containers) {
    Write-Host "  No running containers found.`n" -ForegroundColor Yellow
    Write-Host "  Start some containers or specify container names with -Container.`n" -ForegroundColor Gray
    exit 0
}

# Color palette for containers
$colors = @(
    "Cyan",
    "Green", 
    "Yellow",
    "Magenta",
    "Blue",
    "Red",
    "White"
)

# Show header
Write-Host "  Monitoring $($containers.Count) container(s):" -ForegroundColor Yellow
$containerColors = @{}
for ($i = 0; $i -lt $containers.Count; $i++) {
    $color = $colors[$i % $colors.Count]
    $containerColors[$containers[$i]] = $color
    Write-Host "    [$($i+1)] $($containers[$i])" -ForegroundColor $color
}
Write-Host ""
Write-Host "  Showing last $Lines lines..." -ForegroundColor Gray
if ($Follow) {
    Write-Host "  Press Ctrl+C to stop.`n" -ForegroundColor Gray
} else {
    Write-Host ""
}

# Build docker logs command arguments
$logArgs = @("logs", "--tail", $Lines)
if ($Follow) { $logArgs += "--follow" }
if ($Timestamps) { $logArgs += "--timestamps" }

# For multiple containers, we need to run logs in parallel jobs
if ($containers.Count -eq 1) {
    # Single container - simple approach
    $logArgs += $containers[0]
    & docker $logArgs 2>&1 | ForEach-Object {
        $prefix = "[$($containers[0])]"
        $color = $containerColors[$containers[0]]
        Write-Host "$prefix " -ForegroundColor $color -NoNewline
        Write-Host $_
    }
} else {
    # Multiple containers - run in parallel and prefix output
    $jobs = @()
    
    foreach ($container in $containers) {
        $jobArgs = @("logs", "--tail", $Lines)
        if ($Follow) { $jobArgs += "--follow" }
        if ($Timestamps) { $jobArgs += "--timestamps" }
        $jobScript = {
            param($container, $argsArray)
            & docker $argsArray $container 2>&1 | ForEach-Object {
                [PSCustomObject]@{
                    Container = $container
                    Message = $_
                }
            }
        }
        
        $job = Start-Job -ScriptBlock $jobScript -ArgumentList $container, $jobArgs
        $jobs += [PSCustomObject]@{
            Job = $job
            Container = $container
            Color = $containerColors[$container]
        }
    }
    
    # Collect output from jobs
    try {
        while ($jobs | Where-Object { $_.Job.State -eq 'Running' }) {
            foreach ($jobInfo in $jobs) {
                $output = Receive-Job -Job $jobInfo.Job -ErrorAction SilentlyContinue
                foreach ($line in $output) {
                    $prefix = "[$($line.Container)]"
                    Write-Host "$prefix " -ForegroundColor $jobInfo.Color -NoNewline
                    Write-Host $line.Message
                }
            }
            Start-Sleep -Milliseconds 100
        }
        
        # Get any remaining output
        foreach ($jobInfo in $jobs) {
            $output = Receive-Job -Job $jobInfo.Job -ErrorAction SilentlyContinue
            foreach ($line in $output) {
                $prefix = "[$($line.Container)]"
                Write-Host "$prefix " -ForegroundColor $jobInfo.Color -NoNewline
                Write-Host $line.Message
            }
        }
    } finally {
        $jobs | ForEach-Object { Stop-Job -Job $_.Job -ErrorAction SilentlyContinue; Remove-Job -Job $_.Job -ErrorAction SilentlyContinue }
    }
}

Write-Host "`n  Log streaming ended.`n" -ForegroundColor Gray
