#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Clear Turbopack Cache - Northstar DevKit
.DESCRIPTION
    Deletes Turbopack and related build caches.
    
    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Path
    The project directory. Defaults to current directory.
.PARAMETER Force
    Skip confirmation prompt.
.EXAMPLE
    .\Clear-TurboCache.ps1
    .\Clear-TurboCache.ps1 -Path "C:\my-project"
    .\Clear-TurboCache.ps1 -Force
#>
[CmdletBinding()]
param(
    [string]$Path = ".",
    [switch]$Force
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

try {
    $targetPath = Resolve-DevKitDirectory -Path $Path
} catch {
    Write-DevKitHeader "Clear Turbopack Cache"
    Write-DevKitError $_
    exit 1
}

Write-DevKitHeader "Clear Turbopack Cache"

# Detection mirrors what Clear-DevKitNodeCaches -IncludeTurbo actually
# targets (.next, node_modules\.cache, node_modules\.vite, .turbo). This is
# used only to decide whether to prompt / report "nothing found" - the
# actual deletion below is fully delegated to the shared helper so this
# script can never diverge from what the other cache-clearing entry points
# consider "a Turbopack/Next.js cache".
$checkPaths = @(
    (Join-Path $targetPath ".next"),
    (Join-Path (Join-Path $targetPath "node_modules") ".cache"),
    (Join-Path (Join-Path $targetPath "node_modules") ".vite"),
    (Join-Path $targetPath ".turbo")
)

$found = [bool]($checkPaths | Where-Object { Test-Path $_ })

if (-not $found) {
    Write-DevKitInfo "No Turbopack caches found."
    Write-Host ""
    exit 0
}

if (-not $Force) {
    $confirm = Read-Host "  Delete Turbopack caches? (y/n)"
    if ($confirm -ne 'y') {
        Write-DevKitInfo "Cancelled."
        exit 0
    }
}

Write-DevKitStep "Deleting Turbopack caches"
try {
    Clear-DevKitNodeCaches -Path $targetPath -IncludeTurbo | Out-Null
} catch {
    # Fall through to the Test-Path verification below to decide success.
}

$remaining = $checkPaths | Where-Object { Test-Path $_ }
if (-not $remaining) {
    Write-DevKitDone
} else {
    Write-DevKitError "Could not fully clear Turbopack caches. Stop the dev server and try again."
}

Write-Host ""
