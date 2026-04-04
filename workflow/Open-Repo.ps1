#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Open Repo - Northstar DevKit
.DESCRIPTION
    Open the current Git repository in your default browser
    (GitHub, GitLab, Bitbucket, Azure DevOps, etc.).
    
    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Path
    Path to Git repository. Default: current directory.
.PARAMETER Remote
    Which remote to open. Default: 'origin'
.PARAMETER Branch
    Open specific branch. Default: current branch.
.PARAMETER PullRequest
    Open the pull request page (if available).
.PARAMETER Issues
    Open the issues page.
.PARAMETER Actions
    Open the actions/pipelines page.
.EXAMPLE
    .\Open-Repo.ps1
    .\Open-Repo.ps1 -Branch "feature/new-thing"
    .\Open-Repo.ps1 -PullRequest
    .\Open-Repo.ps1 -Issues
#>
[CmdletBinding()]
param(
    [string]$Path = ".",
    [string]$Remote = "origin",
    [string]$Branch = "",
    [switch]$PullRequest,
    [switch]$Issues,
    [switch]$Actions
)

Write-Host "`nNorthstar DevKit - Open Repo`n" -ForegroundColor Cyan

Push-Location $Path

# Verify Git repo
if (-not (Test-Path ".git")) {
    Write-Host "  ERROR: Not a Git repository.`n" -ForegroundColor Red
    Pop-Location
    exit 1
}

# Check git availability
try {
    $null = git --version 2>$null
} catch {
    Write-Host "  ERROR: Git not found in PATH.`n" -ForegroundColor Red
    Pop-Location
    exit 1
}

# Get remote URL
$remoteUrl = git remote get-url $Remote 2>$null
if (-not $remoteUrl) {
    Write-Host "  ERROR: Remote '$Remote' not found.`n" -ForegroundColor Red
    Pop-Location
    exit 1
}

Write-Host "  Remote: $remoteUrl" -ForegroundColor Gray

# Convert SSH URL to HTTPS
if ($remoteUrl -match '^git@([^:]+):(.+)\.git$') {
    $hostName = $matches[1]
    $path = $matches[2]
    $remoteUrl = "https://$hostName/$path"
} elseif ($remoteUrl -match '^git@([^:]+):(.+)$') {
    $hostName = $matches[1]
    $path = $matches[2]
    $remoteUrl = "https://$hostName/$path"
} elseif ($remoteUrl -match '\.git$') {
    $remoteUrl = $remoteUrl -replace '\.git$',''
}

# Get current branch if not specified
if (-not $Branch) {
    $Branch = git branch --show-current 2>$null
    if (-not $Branch) {
        $Branch = "main"
    }
}

Write-Host "  Branch: $Branch" -ForegroundColor Gray

# Determine platform and build URL
$platform = "unknown"
$url = $remoteUrl

if ($remoteUrl -match 'github\.com') {
    $platform = "GitHub"
    if ($PullRequest) {
        $url = "$remoteUrl/pulls"
    } elseif ($Issues) {
        $url = "$remoteUrl/issues"
    } elseif ($Actions) {
        $url = "$remoteUrl/actions"
    } else {
        $url = "$remoteUrl/tree/$Branch"
    }
} elseif ($remoteUrl -match 'gitlab\.com') {
    $platform = "GitLab"
    if ($PullRequest) {
        $url = "$remoteUrl/-/merge_requests"
    } elseif ($Issues) {
        $url = "$remoteUrl/-/issues"
    } elseif ($Actions) {
        $url = "$remoteUrl/-/pipelines"
    } else {
        $url = "$remoteUrl/-/tree/$Branch"
    }
} elseif ($remoteUrl -match 'bitbucket\.org') {
    $platform = "Bitbucket"
    if ($PullRequest) {
        $url = "$remoteUrl/pull-requests"
    } elseif ($Issues) {
        $url = "$remoteUrl/issues"
    } else {
        $url = "$remoteUrl/src/$Branch"
    }
} elseif ($remoteUrl -match 'dev\.azure\.com|visualstudio\.com') {
    $platform = "Azure DevOps"
    if ($PullRequest) {
        $url = "$remoteUrl/pullrequests"
    } elseif ($Issues) {
        $url = "$remoteUrl/_workitems"
    } elseif ($Actions) {
        $url = "$remoteUrl/_build"
    } else {
        # Azure DevOps doesn't have a simple branch URL pattern
        $url = $remoteUrl
    }
}

Write-Host "  Platform: $platform" -ForegroundColor Gray
Write-Host ""

# Open browser
Write-Host "  Opening browser..." -ForegroundColor Yellow
Write-Host "  $url" -ForegroundColor Cyan
Write-Host ""

Start-Process $url

Write-Host "  DONE: Browser launched.`n" -ForegroundColor Green

Pop-Location
