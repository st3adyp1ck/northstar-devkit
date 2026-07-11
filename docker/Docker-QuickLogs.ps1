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
    Specific container name(s) to tail (exact name match). If not specified, shows all running containers.
.PARAMETER Lines
    Number of lines to show initially. Default: 50
.PARAMETER Follow
    Continue following logs (keep streaming). Default: false (prints the last N lines and exits).
    IMPORTANT: -Follow is a switch, so a bare "-Follow $false" does NOT bind $false to -Follow -
    PowerShell instead binds that stray token POSITIONALLY to -Container. To explicitly control
    this switch use the colon syntax: -Follow:$true or -Follow:$false. Just passing -Follow by
    itself enables continuous tailing.
.PARAMETER Timestamps
    Show timestamps in logs.
.EXAMPLE
    .\Docker-QuickLogs.ps1
    .\Docker-QuickLogs.ps1 -Container "my-app"
    .\Docker-QuickLogs.ps1 -Container "app1", "app2" -Lines 100
    .\Docker-QuickLogs.ps1 -Timestamps
    .\Docker-QuickLogs.ps1 -Follow -Container "my-app"
    .\Docker-QuickLogs.ps1 -Follow:$false -Container "my-app"
#>[CmdletBinding()]
param(
    [string[]]$Container,
    [ValidateRange(0, [int]::MaxValue)]
    [int]$Lines = 50,
    [switch]$Follow,
    [switch]$Timestamps
)


$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }


Write-Host "`nNorthstar DevKit - Docker Quick Logs`n" -ForegroundColor Cyan

# Check Docker
if (-not (Test-DevKitCommand "docker")) {
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
    # Force an array even when exactly one name is requested/found - a single
    # match from a pipeline auto-unwraps to a bare [string] otherwise, and
    # $containers[0] would then index into the STRING'S CHARACTERS.
    $containers = @($Container | ForEach-Object {
        $requested = $_
        # Anchor the docker-side filter to an exact name match (docker's
        # "name=" filter is an unanchored substring match otherwise, e.g.
        # "web" would also match "web-proxy" or "web2"), then re-verify with
        # an exact string comparison as a safety net.
        $found = @(docker ps --filter "name=^/$requested`$" --format "{{.Names}}" 2>$null | Where-Object { $_ -eq $requested })
        if (-not $found) {
            Write-Host "  WARNING: Container '$requested' not found or not running." -ForegroundColor Yellow
        }
        $found
    } | Where-Object { $_ })
} else {
    $containers = @(docker ps --format "{{.Names}}" 2>$null | Where-Object { $_ })
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
    # Multiple containers - launch each `docker logs` invocation as its own
    # native process (via Start-Process -PassThru) instead of Start-Job.
    # Stop-Job on a job that is blocked inside a native `docker logs --follow`
    # call does NOT reliably terminate that underlying docker.exe process, so
    # we track the real Process objects/PIDs here and forcibly Stop-Process
    # them in the finally block.
    $procs = @()
    $tempDir = Join-Path $env:TEMP "devkit-quicklogs-$PID"
    New-Item -ItemType Directory -Path $tempDir -Force -ErrorAction SilentlyContinue | Out-Null

    try {
        foreach ($container in $containers) {
            $jobArgs = @("logs", "--tail", $Lines)
            if ($Follow) { $jobArgs += "--follow" }
            if ($Timestamps) { $jobArgs += "--timestamps" }
            $jobArgs += $container

            $outFile = Join-Path $tempDir "$container.out.log"
            $errFile = Join-Path $tempDir "$container.err.log"

            $proc = Start-Process -FilePath "docker" -ArgumentList $jobArgs -NoNewWindow -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru

            $procs += [PSCustomObject]@{
                Process   = $proc
                Container = $container
                Color     = $containerColors[$container]
                OutFile   = $outFile
                ErrFile   = $errFile
                OutPos    = 0
                ErrPos    = 0
            }
        }

        # Prints any lines appended to a container's redirected output file
        # since the last poll, tracking a per-file read position.
        function Write-DevKitQuickLogLines {
            param($ProcInfo, [string]$Path, [string]$PositionProperty)

            $allLines = @(Get-Content -Path $Path -ErrorAction SilentlyContinue)
            $position = $ProcInfo.$PositionProperty
            if ($allLines.Count -gt $position) {
                foreach ($line in $allLines[$position..($allLines.Count - 1)]) {
                    Write-Host "[$($ProcInfo.Container)] " -ForegroundColor $ProcInfo.Color -NoNewline
                    Write-Host $line
                }
                $ProcInfo.$PositionProperty = $allLines.Count
            }
        }

        # Collect output until every docker logs process has exited
        while ($procs | Where-Object { -not $_.Process.HasExited }) {
            foreach ($procInfo in $procs) {
                Write-DevKitQuickLogLines -ProcInfo $procInfo -Path $procInfo.OutFile -PositionProperty "OutPos"
                Write-DevKitQuickLogLines -ProcInfo $procInfo -Path $procInfo.ErrFile -PositionProperty "ErrPos"
            }
            Start-Sleep -Milliseconds 100
        }

        # Get any remaining output written just before the processes exited
        foreach ($procInfo in $procs) {
            Write-DevKitQuickLogLines -ProcInfo $procInfo -Path $procInfo.OutFile -PositionProperty "OutPos"
            Write-DevKitQuickLogLines -ProcInfo $procInfo -Path $procInfo.ErrFile -PositionProperty "ErrPos"
        }
    } finally {
        foreach ($procInfo in $procs) {
            try {
                if ($procInfo.Process -and -not $procInfo.Process.HasExited) {
                    Stop-Process -Id $procInfo.Process.Id -Force -ErrorAction SilentlyContinue
                }
            } catch {
                # Process may have already exited between the check and the stop
            }
        }
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`n  Log streaming ended.`n" -ForegroundColor Gray
