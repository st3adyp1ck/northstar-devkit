#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Power Plan Manager - Northstar DevKit
.DESCRIPTION
    Lists Windows power plans (via powercfg /list) with the active plan
    clearly marked, switches the active plan by name, and can unlock the
    hidden "Ultimate Performance" plan. Listing requires no admin rights;
    unlocking Ultimate Performance does. After the list, an interactive run
    offers to switch plans right away (by number or name); -SetPlan does the
    same non-interactively.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER List
    List all power plans with the active one marked. This is also the
    default behavior when no other parameter is given.
.PARAMETER SetPlan
    Name (or partial, case-insensitive name) of the power plan to make
    active. Must resolve to exactly one plan.
.PARAMETER UnlockUltimate
    Duplicate the hidden "Ultimate Performance" power plan into the visible
    plan list. Requires an elevated (Administrator) session.
.PARAMETER Force
    Skip the confirmation prompt for -SetPlan / -UnlockUltimate.
.EXAMPLE
    .\Set-PowerPlan.ps1
    .\Set-PowerPlan.ps1 -List
    .\Set-PowerPlan.ps1 -SetPlan "balanced"
    .\Set-PowerPlan.ps1 -SetPlan "High performance" -Force
    .\Set-PowerPlan.ps1 -UnlockUltimate
#>
[CmdletBinding()]
param(
    [switch]$List,
    [string]$SetPlan,
    [switch]$UnlockUltimate,
    [switch]$Force
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

Write-DevKitHeader "Power Plan Manager"

function Get-DevKitPowerPlanList {
    $output = powercfg /list 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "powercfg /list failed (exit code $LASTEXITCODE): $($output -join ' ')"
    }

    $plans = @()
    foreach ($line in $output) {
        # Match the line SHAPE (guid + parenthesized name + optional active
        # marker), not the label: powercfg /list is localized, so an anchor
        # on the English "Power Scheme GUID:" kills the whole tool on
        # non-English Windows.
        if ($line -match '([0-9a-fA-F-]{36})\s*\((.*?)\)\s*(\*)?\s*$') {
            $plans += [PSCustomObject]@{
                Guid   = $matches[1]
                Name   = $matches[2]
                Active = [bool]$matches[3]
            }
        }
    }
    return $plans
}

function Show-DevKitPowerPlanTable {
    param([array]$Plans)

    if ($Plans.Count -eq 0) {
        Write-DevKitInfo "No power plans were returned by powercfg."
        return
    }

    Write-Host ""
    for ($i = 0; $i -lt $Plans.Count; $i++) {
        $p = $Plans[$i]
        if ($p.Active) {
            Write-Host ("  [{0}] {1}  (ACTIVE)" -f ($i + 1), $p.Name) -ForegroundColor Green
        } else {
            Write-Host ("  [{0}] {1}" -f ($i + 1), $p.Name) -ForegroundColor Gray
        }
        Write-Host "        GUID: $($p.Guid)" -ForegroundColor DarkGray
    }
    Write-Host ""
}

if ($UnlockUltimate) {
    if (-not (Test-DevKitAdmin)) {
        Write-DevKitError "Unlocking Ultimate Performance requires an elevated (Administrator) session."
        exit 1
    }

    if (-not (Confirm-DevKitDestructiveAction -Action "unlock the Ultimate Performance power plan" -Force:$Force)) {
        Write-DevKitInfo "Cancelled."
        exit 0
    }

    Write-DevKitStep "Unlocking Ultimate Performance"
    try {
        $result = powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "powercfg -duplicatescheme failed (exit code $LASTEXITCODE): $($result -join ' ')"
        }
        Write-DevKitDone
    } catch {
        Write-DevKitDone
        Write-DevKitError "$_"
        exit 1
    }

    Write-Host ""
    foreach ($line in $result) { Write-Host "  $line" -ForegroundColor Gray }
    Write-Host ""
    Write-DevKitInfo "Run with -List to see the newly-unlocked plan and switch to it with -SetPlan."
    exit 0
}

# Set only when the interactive pick below is a number: the pick already
# uniquely identifies a plan, so its GUID is carried through and the -SetPlan
# block never re-matches by name (a -like on the name can hit "matches more
# than one" when duplicate-similar plan names exist).
$setPlanGuid = $null
if (-not $SetPlan) {
    try {
        $plans = Get-DevKitPowerPlanList
    } catch {
        Write-DevKitError "$_"
        exit 1
    }

    Show-DevKitPowerPlanTable -Plans $plans

    if ([Console]::IsInputRedirected) {
        Write-DevKitInfo "Use -SetPlan <name> to switch the active plan."
        exit 0
    }
    if ($plans.Count -eq 0) { exit 0 }
    $choice = Read-Host "  Plan to switch to (number or name, Enter to exit)"
    if (-not $choice) {
        Write-DevKitInfo "No changes made."
        exit 0
    }
    if ($choice -match '^\d+$') {
        $index = [int]$choice
        if ($index -lt 1 -or $index -gt $plans.Count) {
            Write-DevKitError "No plan number $choice - pick a number from 1 to $($plans.Count)."
            exit 1
        }
        $setPlanGuid = $plans[$index - 1].Guid
        $SetPlan = $plans[$index - 1].Name
    } else {
        $SetPlan = $choice
    }
}

if ($SetPlan) {
    try {
        $plans = Get-DevKitPowerPlanList
    } catch {
        Write-DevKitError "$_"
        exit 1
    }

    if ($setPlanGuid) {
        # Picked by number interactively - match the exact GUID, never the name.
        $matched = @($plans | Where-Object { $_.Guid -eq $setPlanGuid })
    } else {
        $matched = @($plans | Where-Object { $_.Name -like "*$SetPlan*" })
    }

    if ($matched.Count -eq 0) {
        Write-DevKitError "No power plan matches '$SetPlan'."
        Show-DevKitPowerPlanTable -Plans $plans
        exit 1
    }
    if ($matched.Count -gt 1) {
        Write-DevKitError "'$SetPlan' matches more than one power plan - be more specific:"
        foreach ($m in $matched) { Write-Host "    - $($m.Name)" -ForegroundColor Gray }
        exit 1
    }

    $target = $matched[0]

    if (-not (Confirm-DevKitDestructiveAction -Action "switch the active power plan to '$($target.Name)'" -Force:$Force)) {
        Write-DevKitInfo "Cancelled."
        exit 0
    }

    Write-DevKitStep "Switching to '$($target.Name)'"
    try {
        $result = powercfg /setactive $target.Guid 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "powercfg /setactive failed (exit code $LASTEXITCODE): $($result -join ' ')"
        }
        Write-DevKitDone
    } catch {
        Write-DevKitDone
        Write-DevKitError "$_"
        exit 1
    }

    exit 0
}

exit 0
