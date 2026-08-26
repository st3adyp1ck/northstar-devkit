#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Register a Windows Terminal Profile - Northstar DevKit
.DESCRIPTION
    Adds DevKit as a launchable Windows Terminal profile using Terminal's
    documented "dynamic profile fragment" extension point - a JSON file
    dropped under %LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\.
    This never touches Windows Terminal's own settings.json directly (no
    risk of corrupting a hand-edited settings file), requires no
    administrator privileges (entirely per-user), and is fully reversible
    by running Unregister-DevKitTerminalProfile.ps1 or simply deleting the
    dropped file.

    This is an opt-in setup script - it is not run automatically by
    anything.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.EXAMPLE
    .\Register-DevKitTerminalProfile.ps1
#>
[CmdletBinding()]
param()

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

Write-DevKitHeader "Register Windows Terminal Profile"

# Two levels up: this script lives at tools\system\, the repo/install root is above tools\.
$devKitRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
# A shipped CLI would land at the install root; the target\ paths exist only in a dev checkout.
$rootExe = Join-Path $devKitRoot "devkit.exe"
$releaseExe = Join-Path $devKitRoot "target\release\devkit.exe"
$debugExe = Join-Path $devKitRoot "target\debug\devkit.exe"
$devKitExe = if (Test-Path $rootExe) { $rootExe } elseif (Test-Path $releaseExe) { $releaseExe } elseif (Test-Path $debugExe) { $debugExe } else { $null }
if (-not $devKitExe) {
    Write-DevKitError "devkit.exe not found. The DevKit CLI is not bundled with the installed app yet. In a dev checkout, build it first: cargo build --release -p devkit-cli"
    exit 1
}

$fragmentDir = Join-Path (Join-Path $env:LOCALAPPDATA "Microsoft\Windows Terminal\Fragments") "Northstar DevKit"
$fragmentFile = Join-Path $fragmentDir "devkit.json"

Write-DevKitStep "Building profile fragment"
$fragment = [ordered]@{
    profiles = @(
        [ordered]@{
            name              = "Northstar DevKit"
            commandline       = "`"$devKitExe`""
            startingDirectory = $devKitRoot
            icon              = "🧭"
        }
    )
}
Write-DevKitDone

try {
    if (-not (Test-Path $fragmentDir)) {
        New-Item -ItemType Directory -Path $fragmentDir -Force | Out-Null
    }
    Write-DevKitStep "Writing $fragmentFile"
    $fragment | ConvertTo-Json -Depth 6 | Set-Content -Path $fragmentFile -Encoding UTF8
    Write-DevKitDone
} catch {
    Write-DevKitError "Failed to write the profile fragment: $_"
    exit 1
}

Write-Host ""
Write-Host "  DONE: Northstar DevKit will appear as a Windows Terminal profile" -ForegroundColor Green
Write-Host "  the next time Windows Terminal is opened (no restart of Windows needed)." -ForegroundColor Green
Write-Host ""
Write-Host "  To remove it: .\Unregister-DevKitTerminalProfile.ps1" -ForegroundColor Gray
