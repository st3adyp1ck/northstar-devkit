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
    Perform a full reload including PATH refresh.
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

Write-Host "`nNorthstar DevKit - Shell Reload`n" -ForegroundColor Cyan

# Store original values for comparison
$originalPath = $env:PATH
$originalVars = @{}
if ($ShowDiff) {
    Get-ChildItem Env: | ForEach-Object { $originalVars[$_.Name] = $_.Value }
}

# Reload profiles
if (-not $ProfileOnly) {
    Write-Host "  Reloading environment variables..." -ForegroundColor Yellow
    
    # Refresh PATH from registry
    $userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
    $machinePath = [Environment]::GetEnvironmentVariable("PATH", "Machine")
    $env:PATH = "$machinePath;$userPath"
    
    # Refresh other common environment variables
    $varsToRefresh = @(
        "TEMP", "TMP",
        "HOME", "USERPROFILE",
        "JAVA_HOME", "NODE_PATH",
        "PYTHONPATH", " GOPATH"
    )
    
    foreach ($var in $varsToRefresh) {
        $userVal = [Environment]::GetEnvironmentVariable($var, "User")
        $machineVal = [Environment]::GetEnvironmentVariable($var, "Machine")
        $newVal = if ($userVal) { $userVal } elseif ($machineVal) { $machineVal } else { $null }
        if ($newVal) {
            Set-Item -Path "Env:$var" -Value $newVal
        }
    }
    
    Write-Host "  DONE: Environment variables refreshed." -ForegroundColor Green
}

# Reload PowerShell profiles
Write-Host "  Reloading PowerShell profiles..." -ForegroundColor Yellow

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
        Write-Host "    Loaded: $profilePath" -ForegroundColor DarkGray
        $loadedCount++
    } catch {
        Write-Host "    ERROR loading ${profilePath}: $_" -ForegroundColor Red
    }
}

if ($loadedCount -eq 0) {
    Write-Host "    No profiles found to reload." -ForegroundColor Gray
} else {
    Write-Host "  DONE: Reloaded $loadedCount profile(s)." -ForegroundColor Green
}

# Show differences if requested
if ($ShowDiff) {
    Write-Host "`n  Environment Variable Changes:" -ForegroundColor Yellow
    
    $currentVars = @{}
    Get-ChildItem Env: | ForEach-Object { $currentVars[$_.Name] = $_.Value }
    
    # Find new and modified variables
    $changesFound = $false
    foreach ($var in $currentVars.GetEnumerator()) {
        if (-not $originalVars.ContainsKey($var.Key)) {
            Write-Host "    + $($var.Key) = $(if($var.Value.Length -gt 50){$var.Value.Substring(0,50)+'...'}else{$var.Value})" -ForegroundColor Green
            $changesFound = $true
        } elseif ($originalVars[$var.Key] -ne $var.Value) {
            Write-Host "    ~ $($var.Key) (modified)" -ForegroundColor Yellow
            $changesFound = $true
        }
    }
    
    # Find removed variables
    foreach ($var in $originalVars.GetEnumerator()) {
        if (-not $currentVars.ContainsKey($var.Key)) {
            Write-Host "    - $($var.Key)" -ForegroundColor Red
            $changesFound = $true
        }
    }
    
    if (-not $changesFound) {
        Write-Host "    No changes detected." -ForegroundColor Gray
    }
    
    # PATH comparison
    if ($originalPath -ne $env:PATH) {
        Write-Host "`n  PATH has been updated:" -ForegroundColor Yellow
        $originalEntries = $originalPath -split ';' | Where-Object { $_ }
        $newEntries = $env:PATH -split ';' | Where-Object { $_ }
        
        $added = $newEntries | Where-Object { $originalEntries -notcontains $_ }
        $removed = $originalEntries | Where-Object { $newEntries -notcontains $_ }
        
        if ($added) {
            Write-Host "    Added entries:" -ForegroundColor Green
            $added | ForEach-Object { Write-Host "      + $_" -ForegroundColor Green }
        }
        if ($removed) {
            Write-Host "    Removed entries:" -ForegroundColor Red
            $removed | ForEach-Object { Write-Host "      - $_" -ForegroundColor Red }
        }
    }
}

# Summary
Write-Host "`n  ===================================" -ForegroundColor Cyan
Write-Host "  Shell reload complete!" -ForegroundColor Green
Write-Host "  PATH entries: $(($env:PATH -split ';' | Where-Object { $_ }).Count)" -ForegroundColor Gray
Write-Host "  ===================================`n" -ForegroundColor Cyan
