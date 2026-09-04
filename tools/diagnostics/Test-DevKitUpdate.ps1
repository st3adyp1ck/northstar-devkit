#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Check for Updates - Northstar DevKit
.DESCRIPTION
    Compares the locally installed version (read from the repo-root VERSION
    file) against the latest GitHub Release tag for this project. Makes a
    single read-only HTTPS request to the GitHub API - this is the only
    network call in DevKit that isn't explicitly about networking itself
    (unlike the WiFi tools' speed test), so it is opt-in and rate-limited:
    it will not check more than once per day unless -Force is passed, and
    respects settings.json's preferences.updateCheckEnabled.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Force
    Check now regardless of settings.json's updateCheckEnabled flag or how
    recently the last check ran.
.EXAMPLE
    .\Test-DevKitUpdate.ps1
    .\Test-DevKitUpdate.ps1 -Force
#>
[CmdletBinding()]
param(
    [switch]$Force
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

Write-DevKitHeader "Check for Updates"

$settings = Get-DevKitSettings
if (-not $Force -and -not $settings.preferences.updateCheckEnabled) {
    Write-DevKitInfo "Update checks are disabled (settings.json: preferences.updateCheckEnabled = false)."
    Write-DevKitInfo "Run with -Force to check anyway."
    exit 0
}

if (-not $Force -and $settings.preferences.lastUpdateCheckUtc) {
    try {
        $lastChecked = [DateTime]::Parse($settings.preferences.lastUpdateCheckUtc).ToUniversalTime()
        $hoursSince = ([DateTime]::UtcNow - $lastChecked).TotalHours
        if ($hoursSince -lt 24) {
            Write-DevKitInfo "Checked within the last 24 hours (use -Force to check again)."
            exit 0
        }
    } catch {
        # Malformed timestamp in settings - fall through and check anyway.
    }
}

# Two levels up: this script lives at tools\diagnostics\, the repo/install root is above tools\.
$versionFile = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "VERSION"
if (-not (Test-Path $versionFile)) {
    Write-DevKitError "VERSION file not found - cannot determine the installed version."
    exit 1
}
$localVersion = (Get-Content $versionFile -Raw).Trim()
Write-DevKitInfo "Installed version: $localVersion"

Write-DevKitStep "Checking github.com for the latest release"

# Stamp the ATTEMPT, not the success. This write used to sit below the try/catch,
# so any failure path - a 403 rate-limit, a timeout, an offline run - exited
# before it and left lastUpdateCheckUtc untouched, meaning the very next
# invocation re-hit api.github.com with no delay at all. GitHub is explicit that
# continuing to call while rate-limited can get an integration banned, so the
# throttle has to survive failures, not just successes.
$settings.preferences.lastUpdateCheckUtc = [DateTime]::UtcNow.ToString("o")
Set-DevKitSettings -Settings $settings

try {
    # User-Agent is mandatory (GitHub rejects requests without one) and is built
    # from VERSION so it stays accurate. Accept and X-GitHub-Api-Version are the
    # documented "should" headers - pinning the API version means a future
    # breaking default doesn't silently reshape this response.
    $headers = @{
        'User-Agent'           = "NorthstarDevKit/$localVersion (+https://github.com/st3adyp1ck/northstar-devkit)"
        'Accept'               = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/st3adyp1ck/northstar-devkit/releases/latest" -Headers $headers -TimeoutSec 8 -ErrorAction Stop
    Write-DevKitDone
} catch {
    Write-DevKitSkip
    Write-DevKitInfo "Could not reach GitHub (offline, rate-limited, or no releases published yet) - not treated as an error."
    exit 0
}

$remoteVersion = ($release.tag_name -replace '^v', '').Trim()
if ([string]::IsNullOrWhiteSpace($remoteVersion)) {
    Write-DevKitInfo "Latest release has no usable version tag."
    exit 0
}

Write-DevKitInfo "Latest release:    $remoteVersion"

try {
    $localParsed = [version]$localVersion
    $remoteParsed = [version]$remoteVersion
} catch {
    Write-DevKitInfo "Could not compare versions numerically ('$localVersion' vs '$remoteVersion')."
    exit 0
}

if ($remoteParsed -gt $localParsed) {
    Write-Host ""
    Write-Host "  Update available: v$remoteVersion ($($release.html_url))" -ForegroundColor Yellow
} else {
    Write-Host ""
    Write-Host "  You're up to date." -ForegroundColor Green
}
