#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Northstar DevKit - Common Helpers
.DESCRIPTION
    Shared functions used by DevKit scripts. This file is dot-sourced by
    standalone scripts; it does not produce output when loaded.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.VERSION
    2.1.0
#>

# Prevent double-loading
if ($global:DevKitCommonLoaded) { return }
$global:DevKitCommonLoaded = $true

# ==================== OUTPUT HELPERS ====================

function Write-DevKitHeader {
    param([string]$Title)
    Write-Host "`nNorthstar DevKit - $Title`n" -ForegroundColor Cyan
}

function Write-DevKitStep {
    param([string]$Message)
    Write-Host "  $Message..." -ForegroundColor Yellow -NoNewline
}

function Write-DevKitDone {
    Write-Host " DONE" -ForegroundColor Green
}

function Write-DevKitSkip {
    Write-Host " SKIP" -ForegroundColor Gray
}

function Write-DevKitError {
    param([string]$Message)
    Write-Host " ERROR: $Message" -ForegroundColor Red
}

function Write-DevKitInfo {
    param([string]$Message)
    Write-Host "  $Message" -ForegroundColor Gray
}

# ==================== ENVIRONMENT / PRIVILEGE ====================

function Test-DevKitAdmin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-DevKitCommand {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

# ==================== PATH HELPERS ====================

function Resolve-DevKitDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        throw "Path not found: $Path"
    }

    $resolved = (Resolve-Path $Path).Path
    if (-not (Test-Path $resolved -PathType Container)) {
        throw "Path is not a directory: $resolved"
    }

    return $resolved
}

function Invoke-DevKitInDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock
    )

    $resolved = Resolve-DevKitDirectory -Path $Path
    Push-Location $resolved
    try {
        & $ScriptBlock
    } finally {
        Pop-Location
    }
}

# ==================== FILE / CACHE HELPERS ====================

function Remove-DevKitNodeModules {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $resolved = Resolve-DevKitDirectory -Path $Path
    $nmPath = Join-Path $resolved "node_modules"

    if (-not (Test-Path $nmPath)) {
        return $false
    }

    # Long-path-safe deletion: mirror an empty folder, then remove
    $empty = Join-Path $env:TEMP "empty_devkit_$(Get-Random)"
    try {
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        robocopy $empty $nmPath /MIR /MT:8 /NFL /NDL /NJH /NJS | Out-Null
        Remove-Item -Path $nmPath -Recurse -Force -ErrorAction SilentlyContinue
    } finally {
        if (Test-Path $empty) {
            Remove-Item $empty -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    return $true
}

function Clear-DevKitNodeCaches {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [switch]$IncludeTurbo
    )

    $resolved = Resolve-DevKitDirectory -Path $Path
    $cachePaths = @(
        (Join-Path $resolved ".next"),
        (Join-Path $resolved ".vite"),
        (Join-Path $resolved "dist"),
        (Join-Path (Join-Path $resolved "node_modules") ".cache"),
        (Join-Path (Join-Path $resolved "node_modules") ".vite")
    )

    if ($IncludeTurbo) {
        $cachePaths += @(
            (Join-Path $resolved ".turbo"),
            (Join-Path (Join-Path $resolved ".next") "cache"),
            (Join-Path (Join-Path $resolved "node_modules") ".cache")
        ) | Select-Object -Unique
    }

    $found = $false
    foreach ($cachePath in $cachePaths) {
        if (Test-Path $cachePath) {
            Remove-Item -Path $cachePath -Recurse -Force -ErrorAction SilentlyContinue
            $found = $true
        }
    }

    return $found
}

# ==================== PACKAGE MANAGER HELPERS ====================

function Get-DevKitPackageManager {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $resolved = Resolve-DevKitDirectory -Path $Path

    $managers = @(
        @{ Lock = "bun.lockb"; Command = "bun"; Install = @("install") },
        @{ Lock = "pnpm-lock.yaml"; Command = "pnpm"; Install = @("install") },
        @{ Lock = "yarn.lock"; Command = "yarn"; Install = @("install") },
        @{ Lock = "package-lock.json"; Command = "npm"; Install = @("install") }
    )

    foreach ($manager in $managers) {
        if (Test-Path (Join-Path $resolved $manager.Lock)) {
            return $manager
        }
    }

    # Default to npm
    return @{ Lock = $null; Command = "npm"; Install = @("install") }
}

function Invoke-DevKitPackageInstall {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $manager = Get-DevKitPackageManager -Path $Path

    if (-not (Test-DevKitCommand $manager.Command)) {
        throw "$($manager.Command) is not installed or not in PATH."
    }

    & $manager.Command @($manager.Install)
    if ($LASTEXITCODE -ne 0) {
        throw "Package install failed with exit code $LASTEXITCODE"
    }
}

function Invoke-DevKitPackageCacheClean {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $manager = Get-DevKitPackageManager -Path $Path

    if ($manager.Command -eq "npm") {
        if (-not (Test-DevKitCommand "npm")) { throw "npm is not installed or not in PATH." }
        npm cache clean --force | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "npm cache clean failed" }
    }
    elseif ($manager.Command -eq "pnpm") {
        if (-not (Test-DevKitCommand "pnpm")) { throw "pnpm is not installed or not in PATH." }
        pnpm store prune | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "pnpm store prune failed" }
    }
    elseif ($manager.Command -eq "yarn") {
        if (-not (Test-DevKitCommand "yarn")) { throw "yarn is not installed or not in PATH." }
        yarn cache clean --all | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "yarn cache clean failed" }
    }
    elseif ($manager.Command -eq "bun") {
        if (-not (Test-DevKitCommand "bun")) { throw "bun is not installed or not in PATH." }
        bun pm cache rm | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "bun cache clean failed" }
    }
}

# ==================== PORT / PROCESS HELPERS ====================

function Get-DevKitProcessByPort {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 65535)]
        [int]$Port
    )

    $connection = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $connection) {
        return $null
    }

    $process = Get-Process -Id $connection.OwningProcess -ErrorAction SilentlyContinue
    return [PSCustomObject]@{
        Port    = $Port
        PID     = $connection.OwningProcess
        Name    = if ($process) { $process.ProcessName } else { "Unknown" }
        Path    = if ($process) { $process.Path } else { $null }
    }
}

function Stop-DevKitNodeProcesses {
    <#
    .SYNOPSIS
        Stop Node processes that appear to belong to the given project path.
    .DESCRIPTION
        Uses the process command line to detect Node processes running code
        under the target directory. This is a heuristic; it will not catch
        every scenario, but it avoids the substring false positives of the
        previous implementation.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $resolved = Resolve-DevKitDirectory -Path $Path
    $pattern = "$resolved\"

    $procs = Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -and
            ($_.CommandLine -like "*`"$pattern*`"*" -or
             $_.CommandLine -like "*$pattern*")
        }

    $killed = 0
    foreach ($proc in $procs) {
        try {
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
            $killed++
        } catch {
            # Ignore access-denied or already-exited processes
        }
    }

    return $killed
}
