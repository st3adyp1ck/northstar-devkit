#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Visual Effects Manager - Northstar DevKit
.DESCRIPTION
    Reports or sets the Windows "adjust for best performance/appearance"
    visual effects mode (the setting behind Advanced System Settings ->
    Performance). Reading requires no admin rights; it only touches the
    current user's own registry hive (HKCU), so setting it doesn't either.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Show
    Print the current visual effects mode. This is also the default
    behavior when no other parameter is given.
.PARAMETER SetMode
    Set the visual effects mode. One of: Performance, Appearance, Auto,
    Custom.
.PARAMETER Force
    Skip the confirmation prompt when using -SetMode.
.EXAMPLE
    .\Set-VisualEffects.ps1
    .\Set-VisualEffects.ps1 -Show
    .\Set-VisualEffects.ps1 -SetMode Performance
    .\Set-VisualEffects.ps1 -SetMode Auto -Force
#>
[CmdletBinding()]
param(
    [switch]$Show,
    [ValidateSet('Performance', 'Appearance', 'Auto', 'Custom')]
    [string]$SetMode,
    [switch]$Force
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

Write-DevKitHeader "Visual Effects Manager"

$regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects"
$valueName = "VisualFXSetting"

$modeByValue = @{ 0 = 'Auto'; 1 = 'Appearance'; 2 = 'Performance'; 3 = 'Custom' }
$valueByMode = @{ Auto = 0; Appearance = 1; Performance = 2; Custom = 3 }

function Get-DevKitVisualEffectsMode {
    $props = Get-ItemProperty -Path $regPath -Name $valueName -ErrorAction SilentlyContinue
    if (-not $props -or -not ($props.PSObject.Properties.Name -contains $valueName)) {
        return $null
    }
    return [int]$props.$valueName
}

if ($SetMode) {
    if (-not (Confirm-DevKitDestructiveAction -Action "set visual effects to '$SetMode' (may need sign-out to fully apply)" -Force:$Force)) {
        Write-DevKitInfo "Cancelled."
        exit 0
    }

    $targetValue = $valueByMode[$SetMode]

    Write-DevKitStep "Setting visual effects to '$SetMode'"
    try {
        if (-not (Test-Path $regPath)) {
            New-Item -Path $regPath -Force -ErrorAction Stop | Out-Null
        }
        $existing = Get-ItemProperty -Path $regPath -Name $valueName -ErrorAction SilentlyContinue
        if ($existing -and ($existing.PSObject.Properties.Name -contains $valueName)) {
            Set-ItemProperty -Path $regPath -Name $valueName -Value $targetValue -Type DWord -ErrorAction Stop
        } else {
            New-ItemProperty -Path $regPath -Name $valueName -Value $targetValue -PropertyType DWord -Force -ErrorAction Stop | Out-Null
        }
        Write-DevKitDone
    } catch {
        Write-DevKitDone
        Write-DevKitError "Failed to set visual effects mode: $_"
        exit 1
    }

    Write-Host ""
    Write-DevKitInfo "A sign-out (or an Explorer restart) may be needed for all effects to visibly update."
    exit 0
}

$currentValue = Get-DevKitVisualEffectsMode
if ($null -eq $currentValue) {
    Write-DevKitInfo "Current visual effects mode: Auto (default) - no explicit setting found"
} else {
    $modeName = if ($modeByValue.ContainsKey($currentValue)) { $modeByValue[$currentValue] } else { "Unknown ($currentValue)" }
    Write-DevKitInfo "Current visual effects mode: $modeName"
}

exit 0
