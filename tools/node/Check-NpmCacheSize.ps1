#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Check Package Manager Cache Size - Northstar DevKit
.DESCRIPTION
    Reports the local package manager cache location (and size, where
    discoverable) for the project at -Path. Auto-detects npm/yarn/pnpm/bun
    from lock files (same detection used across the rest of DevKit), since
    each package manager exposes its cache info differently:
      - npm:  npm config get cache / npm cache verify
      - pnpm: pnpm store path
      - yarn: yarn cache dir
      - bun:  no programmatic "print cache path" command; falls back to
              bun's documented, fixed per-user cache location

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Path
    The project directory whose package manager cache to inspect.
    Defaults to current directory.
.EXAMPLE
    .\Check-NpmCacheSize.ps1
    .\Check-NpmCacheSize.ps1 -Path "C:\my-project"
#>
[CmdletBinding()]
param(
    [string]$Path = "."
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

Write-DevKitHeader "Package Manager Cache Size"

try {
    $targetPath = Resolve-DevKitDirectory -Path $Path
} catch {
    Write-DevKitError $_
    exit 1
}

$manager = Get-DevKitPackageManager -Path $targetPath
Write-DevKitInfo "Package manager: $($manager.Command)"

if (-not (Test-DevKitCommand $manager.Command)) {
    Write-DevKitError "$($manager.Command) is not installed or not in PATH."
    exit 1
}

$cachePath = $null
switch ($manager.Command) {
    "npm" { $cachePath = (npm config get cache 2>$null) }
    "pnpm" { $cachePath = (pnpm store path 2>$null) }
    "yarn" { $cachePath = (yarn cache dir 2>$null) }
    "bun" {
        # bun has no programmatic "print cache path" command; its cache
        # lives under a fixed, documented per-user location on Windows.
        $cachePath = Join-Path $env:USERPROFILE ".bun\install\cache"
    }
}

if ($cachePath) {
    Write-DevKitInfo "Cache Path: $cachePath"
} else {
    Write-DevKitInfo "Cache path could not be determined for $($manager.Command)."
}
Write-Host ""

if ($manager.Command -eq "npm") {
    npm cache verify
} elseif ($cachePath -and (Test-Path $cachePath)) {
    $size = (Get-ChildItem $cachePath -Recurse -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    $sizeMB = [math]::Round($size / 1MB, 2)
    Write-DevKitInfo "Cache Size: $sizeMB MB (approximate)"
} else {
    Write-DevKitInfo "$($manager.Command) does not expose a cache verify/size command DevKit can call directly."
}

Write-Host ""
