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

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

try {
    $targetPath = Resolve-DevKitDirectory -Path $Path
} catch {
    Write-DevKitHeader "Open Repo"
    Write-DevKitError $_
    exit 1
}

Write-DevKitHeader "Open Repo"

Invoke-DevKitInDirectory -Path $targetPath -ScriptBlock {
    # Verify Git repo
    if (-not (Test-Path ".git")) {
        Write-DevKitError "Not a Git repository."
        exit 1
    }

    # Check git availability
    if (-not (Test-DevKitCommand git)) {
        Write-DevKitError "Git not found in PATH."
        exit 1
    }

    # Get remote URL
    $remoteUrl = git remote get-url $Remote 2>$null
    if (-not $remoteUrl) {
        Write-DevKitError "Remote '$Remote' not found."
        exit 1
    }

    Write-DevKitInfo "Remote: $remoteUrl"

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

    Write-DevKitInfo "Branch: $Branch"

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
        }
    }

    Write-DevKitInfo "Platform: $platform"
    Write-DevKitInfo "Opening: $url"

    Start-Process $url

    Write-Host ""
}
