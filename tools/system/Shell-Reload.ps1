#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Shell Reload - Northstar DevKit
.DESCRIPTION
    Reloads the PowerShell profile and environment variables
    without restarting the terminal session.
    
    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Full
    Also refresh all User and Machine environment variables from the registry.
.PARAMETER ProfileOnly
    Only reload the PowerShell profile scripts.
.PARAMETER ShowDiff
    Show differences in environment variables after reload.
.EXAMPLE
    .\Shell-Reload.ps1
    .\Shell-Reload.ps1 -Full
    .\Shell-Reload.ps1 -ShowDiff
#>
[CmdletBinding()]
param(
    [switch]$Full,
    [switch]$ProfileOnly,
    [switch]$ShowDiff
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

function Get-DevKitDedupedPathEntries {
    <#
        Normalizes and deduplicates a list of PATH entries.
        Normalization: trim whitespace, strip a single trailing backslash,
        and compare case-insensitively. Preserves the first-seen original
        (non-normalized) entry for each unique normalized key, in order.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Entries
    )

    $seen = @{}
    $result = @()
    foreach ($entry in $Entries) {
        if ($null -eq $entry) { continue }
        $normalized = $entry.Trim()
        if ($normalized.EndsWith('\')) {
            $normalized = $normalized.Substring(0, $normalized.Length - 1)
        }
        $key = $normalized.ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $result += $entry
        }
    }
    return $result
}

Write-DevKitHeader "Shell Reload"

# Store original values for comparison
$originalPath = $env:PATH
$originalVars = @{}
if ($ShowDiff) {
    Get-ChildItem Env: | ForEach-Object { $originalVars[$_.Name] = $_.Value }
}

# Reload profiles
if (-not $ProfileOnly) {
    Write-DevKitStep "Reloading environment variables"

    # Refresh PATH from registry
    $userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
    $machinePath = [Environment]::GetEnvironmentVariable("PATH", "Machine")
    $rawPathEntries = @($machinePath, $userPath) | Where-Object { $_ } | ForEach-Object { $_ -split ';' | Where-Object { $_ } }
    $pathEntries = Get-DevKitDedupedPathEntries -Entries $rawPathEntries
    $env:PATH = $pathEntries -join ';'

    # Refresh other common environment variables
    $varsToRefresh = @(
        "TEMP", "TMP",
        "HOME", "USERPROFILE",
        "JAVA_HOME", "NODE_PATH",
        "PYTHONPATH", "GOPATH"
    )

    foreach ($var in $varsToRefresh) {
        $userVal = [Environment]::GetEnvironmentVariable($var, "User")
        $machineVal = [Environment]::GetEnvironmentVariable($var, "Machine")
        $newVal = if ($userVal) { $userVal } elseif ($machineVal) { $machineVal } else { $null }
        if ($newVal) {
            Set-Item -Path "Env:$var" -Value $newVal
        } else {
            # Both User and Machine values are gone - don't leave a stale
            # copy behind in this process's environment.
            Remove-Item -Path "Env:$var" -ErrorAction SilentlyContinue
        }
    }

    # Full reload: merge all User and Machine variables
    if ($Full) {
        $machineVars = [Environment]::GetEnvironmentVariables("Machine")
        $userVars = [Environment]::GetEnvironmentVariables("User")

        foreach ($var in $machineVars.GetEnumerator()) {
            Set-Item -Path "Env:$($var.Key)" -Value $var.Value -ErrorAction SilentlyContinue
        }
        foreach ($var in $userVars.GetEnumerator()) {
            Set-Item -Path "Env:$($var.Key)" -Value $var.Value -ErrorAction SilentlyContinue
        }
    }

    Write-DevKitDone
}

# Reload PowerShell profiles
Write-DevKitStep "Reloading PowerShell profiles"

$profilePaths = @(
    $PROFILE.AllUsersAllHosts,
    $PROFILE.AllUsersCurrentHost,
    $PROFILE.CurrentUserAllHosts,
    $PROFILE.CurrentUserCurrentHost
) | Select-Object -Unique | Where-Object { Test-Path $_ }

$loadedCount = 0
foreach ($profilePath in $profilePaths) {
    try {
        . $profilePath
        $loadedCount++
    } catch {
        Write-Host "    WARNING: Could not load $profilePath" -ForegroundColor Yellow
    }
}

Write-DevKitDone
Write-DevKitInfo "Reloaded $loadedCount profile(s)"

# Show diff if requested
if ($ShowDiff) {
    Write-Host "`n  Environment variable changes:" -ForegroundColor Cyan
    $currentVars = @{}
    Get-ChildItem Env: | ForEach-Object { $currentVars[$_.Name] = $_.Value }

    $changed = $false
    foreach ($name in ($originalVars.Keys + $currentVars.Keys | Select-Object -Unique)) {
        $old = $originalVars[$name]
        $new = $currentVars[$name]
        if ($old -ne $new) {
            $changed = $true
            Write-Host "  $name" -ForegroundColor Yellow
            if ($old -and $new) {
                Write-Host "    Old: $old" -ForegroundColor Gray
                Write-Host "    New: $new" -ForegroundColor Gray
            } elseif ($new) {
                Write-Host "    Added: $new" -ForegroundColor Green
            } else {
                Write-Host "    Removed" -ForegroundColor Red
            }
        }
    }

    if (-not $changed) {
        Write-DevKitInfo "No changes detected."
    }
}

Write-Host ""
