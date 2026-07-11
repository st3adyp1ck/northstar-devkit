#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Manage Services - Northstar DevKit
.DESCRIPTION
    Reports the current startup type and status for a curated list of
    commonly-tuned, non-critical Windows services, and can change one
    service's startup type. Reporting requires no admin rights; changing a
    startup type does. The report is informational only - it does not
    recommend disabling anything.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER SetStartType
    Name of the service whose startup type to change. Must be used together
    with -StartTypeValue. Not limited to the curated list below.
.PARAMETER StartTypeValue
    The startup type to apply: Automatic, Manual, or Disabled. Must be used
    together with -SetStartType.
.PARAMETER Force
    Skip the confirmation prompt when changing a startup type.
.EXAMPLE
    .\Manage-Services.ps1
    .\Manage-Services.ps1 -SetStartType SysMain -StartTypeValue Disabled
    .\Manage-Services.ps1 -SetStartType WSearch -StartTypeValue Automatic -Force
#>
[CmdletBinding()]
param(
    [string]$SetStartType,
    [ValidateSet('Automatic', 'Manual', 'Disabled')]
    [string]$StartTypeValue,
    [switch]$Force
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

Write-DevKitHeader "Manage Services"

$curatedServices = @(
    @{ Name = 'DiagTrack'; Label = 'Connected User Experiences and Telemetry' },
    @{ Name = 'Fax'; Label = 'Fax' },
    @{ Name = 'WMPNetworkSvc'; Label = 'Windows Media Player Network Sharing' },
    @{ Name = 'RemoteRegistry'; Label = 'Remote Registry' },
    @{ Name = 'MapsBroker'; Label = 'Downloaded Maps Manager' },
    @{ Name = 'WSearch'; Label = 'Windows Search' },
    @{ Name = 'SysMain'; Label = 'Superfetch / Prefetch (SysMain)' }
)

if ($SetStartType -and $StartTypeValue) {
    if (-not (Test-DevKitAdmin)) {
        Write-DevKitError "Changing a service's startup type requires an elevated (Administrator) session."
        exit 1
    }

    $service = $null
    try {
        $service = Get-Service -Name $SetStartType -ErrorAction Stop
    } catch {
        Write-DevKitError "Service '$SetStartType' was not found on this machine."
        exit 1
    }

    Write-DevKitInfo "Current: $($service.Name)  StartType=$($service.StartType)  Status=$($service.Status)"

    if (-not (Confirm-DevKitDestructiveAction -Action "set service '$SetStartType' startup type to $StartTypeValue" -Force:$Force)) {
        Write-DevKitInfo "Cancelled."
        exit 0
    }

    Write-DevKitStep "Setting '$SetStartType' startup type to $StartTypeValue"
    try {
        Set-Service -Name $SetStartType -StartupType $StartTypeValue -ErrorAction Stop
        Write-DevKitDone
    } catch {
        Write-DevKitDone
        Write-DevKitError "Failed to set startup type for '$SetStartType': $_"
        exit 1
    }

    exit 0
} elseif ($SetStartType -or $StartTypeValue) {
    Write-DevKitError "-SetStartType and -StartTypeValue must be used together."
    exit 1
}

Write-Host "  Informational only. Some of these services (e.g. Windows Search, SysMain)" -ForegroundColor Yellow
Write-Host "  are genuinely useful for many users - whether to disable any of them is a" -ForegroundColor Yellow
Write-Host "  personal call based on your own usage, not a blanket recommendation." -ForegroundColor Yellow
Write-Host ""

Write-Host ("  {0,-16} {1,-42} {2,-11} {3}" -f "ServiceName", "Description", "StartType", "Status") -ForegroundColor Magenta
Write-Host ("  {0,-16} {1,-42} {2,-11} {3}" -f "-----------", "-----------", "---------", "------") -ForegroundColor Magenta

$listed = 0
foreach ($svc in $curatedServices) {
    $service = $null
    try {
        $service = Get-Service -Name $svc.Name -ErrorAction Stop
    } catch {
        continue
    }
    $listed++
    Write-Host ("  {0,-16} {1,-42} {2,-11} {3}" -f $service.Name, $svc.Label, $service.StartType, $service.Status) -ForegroundColor Gray
}

Write-Host ""
if ($listed -eq 0) {
    Write-DevKitInfo "None of the curated services exist on this machine."
} else {
    Write-DevKitInfo "$listed of $($curatedServices.Count) curated service(s) found. Use -SetStartType <Name> -StartTypeValue <Automatic|Manual|Disabled> to change one."
}

exit 0
