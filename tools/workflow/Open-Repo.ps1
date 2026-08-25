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

function ConvertTo-DevKitBrowsableUrl {
    <#
    .SYNOPSIS
        Convert a Git remote URL into a browsable HTTPS URL.
    .DESCRIPTION
        Handles plain https/http remotes, git@ scp-style SSH shorthand,
        Azure DevOps SSH remotes (both the current ssh.dev.azure.com/v3
        form and the legacy vs-ssh.visualstudio.com form), and ssh://
        URI-style remotes (custom ports, self-hosted GitLab/Bitbucket
        Server, SSH config host aliases).

        Returns $null when the input cannot be confidently converted to
        a well-formed http(s) URL - callers MUST treat a null result as
        "refuse to open", never pass the raw input through unchanged.
    .PARAMETER RemoteUrl
        The raw remote URL as returned by `git remote get-url`.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RemoteUrl
    )

    $url = $RemoteUrl.Trim()

    # Azure DevOps SSH (current): git@ssh.dev.azure.com:v3/org/project/repo
    if ($url -match '^git@ssh\.dev\.azure\.com:v3/([^/]+)/([^/]+)/(.+?)(?:\.git)?$') {
        $org = $matches[1]
        $project = $matches[2]
        $repo = $matches[3]
        return "https://dev.azure.com/$org/$project/_git/$repo"
    }

    # Azure DevOps SSH (legacy): git@vs-ssh.visualstudio.com:v3/org/project/repo
    if ($url -match '^git@vs-ssh\.visualstudio\.com:v3/([^/]+)/([^/]+)/(.+?)(?:\.git)?$') {
        $org = $matches[1]
        $project = $matches[2]
        $repo = $matches[3]
        return "https://dev.azure.com/$org/$project/_git/$repo"
    }

    # ssh:// URI style: ssh://git@github.com:22/user/repo.git
    #                   ssh://git@gitlab.mycompany.com:2222/group/repo.git
    if ($url -match '^ssh://(?:[^@/]+@)?([^:/]+)(?::\d+)?/(.+?)(?:\.git)?$') {
        $hostName = $matches[1]
        $path = $matches[2]
        return "https://$hostName/$path"
    }

    # Generic scp-style SSH shorthand: git@host:path[.git]
    if ($url -match '^git@([^:]+):(.+?)(?:\.git)?$') {
        $hostName = $matches[1]
        $path = $matches[2]
        return "https://$hostName/$path"
    }

    # Already http(s) - just strip a trailing .git
    if ($url -match '^https?://') {
        return ($url -replace '\.git$', '')
    }

    # Anything else (bare command names, unknown schemes, garbage) is
    # not something we can safely turn into a URL.
    return $null
}

# When this file is dot-sourced (e.g. by Pester tests that only need
# ConvertTo-DevKitBrowsableUrl), stop here - do not run the interactive
# script body, touch the current repo, or launch a browser.
if ($MyInvocation.InvocationName -eq '.') {
    return
}

try {
    $targetPath = Resolve-DevKitDirectory -Path $Path
} catch {
    Write-DevKitHeader "Open Repo"
    Write-DevKitError $_
    exit 1
}

Write-DevKitHeader "Open Repo"

Invoke-DevKitInDirectory -Path $targetPath -ScriptBlock {
    # Check git availability
    if (-not (Test-DevKitCommand git)) {
        Write-DevKitError "Git not found in PATH."
        exit 1
    }

    # Verify we're inside a Git work tree. `git rev-parse` walks UP the
    # directory tree to find an enclosing .git, same as the remote/branch
    # commands below - a manual Test-Path ".git" check does not, and
    # incorrectly rejects valid monorepo subdirectories.
    $insideWorkTree = git rev-parse --is-inside-work-tree 2>$null
    if ($insideWorkTree -ne "true") {
        Write-DevKitError "Not a Git repository."
        exit 1
    }

    # Get remote URL
    $remoteUrl = git remote get-url $Remote 2>$null
    if (-not $remoteUrl) {
        Write-DevKitError "Remote '$Remote' not found."
        exit 1
    }

    Write-DevKitInfo "Remote: $remoteUrl"

    # Convert SSH/ssh:// remote to a browsable HTTPS URL. The remote URL
    # is attacker-influenceable (malicious clone, tampered .git/config),
    # so a failed/ambiguous conversion must refuse to continue rather
    # than fall back to the raw value.
    $convertedUrl = ConvertTo-DevKitBrowsableUrl -RemoteUrl $remoteUrl
    if (-not $convertedUrl) {
        Write-DevKitError "Could not convert remote to a valid http(s) URL: $remoteUrl"
        exit 1
    }
    $remoteUrl = $convertedUrl

    # Get current branch if not specified
    if (-not $Branch) {
        $Branch = git branch --show-current 2>$null
        if (-not $Branch) {
            # Detached HEAD (or otherwise branchless): resolve the repo's
            # ACTUAL default branch instead of guessing "main". Try the
            # local remote-tracking symbolic ref first (fast, no network),
            # then fall back to asking the remote directly.
            $Branch = $null

            $symbolicRef = git symbolic-ref --short "refs/remotes/$Remote/HEAD" 2>$null
            if ($symbolicRef) {
                $Branch = $symbolicRef -replace "^$([regex]::Escape($Remote))/", ''
            }

            if (-not $Branch) {
                $remoteShow = git remote show $Remote 2>$null
                if ($remoteShow) {
                    $headLine = $remoteShow | Select-String 'HEAD branch:\s*(\S+)'
                    if ($headLine -and $headLine.Matches.Count -gt 0) {
                        $candidate = $headLine.Matches[0].Groups[1].Value
                        if ($candidate -and $candidate -ne '(unknown)') {
                            $Branch = $candidate
                        }
                    }
                }
            }
        }
    }

    $hasBranch = -not [string]::IsNullOrWhiteSpace($Branch)

    if ($hasBranch) {
        Write-DevKitInfo "Branch: $Branch"
    } else {
        Write-DevKitInfo "Branch: (could not be resolved - opening repo root)"
    }

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
        } elseif ($hasBranch) {
            $url = "$remoteUrl/tree/$Branch"
        } else {
            $url = $remoteUrl
        }
    } elseif ($remoteUrl -match 'gitlab\.com') {
        $platform = "GitLab"
        if ($PullRequest) {
            $url = "$remoteUrl/-/merge_requests"
        } elseif ($Issues) {
            $url = "$remoteUrl/-/issues"
        } elseif ($Actions) {
            $url = "$remoteUrl/-/pipelines"
        } elseif ($hasBranch) {
            $url = "$remoteUrl/-/tree/$Branch"
        } else {
            $url = $remoteUrl
        }
    } elseif ($remoteUrl -match 'bitbucket\.org') {
        $platform = "Bitbucket"
        if ($PullRequest) {
            $url = "$remoteUrl/pull-requests"
        } elseif ($Issues) {
            $url = "$remoteUrl/issues"
        } elseif ($hasBranch) {
            $url = "$remoteUrl/src/$Branch"
        } else {
            $url = $remoteUrl
        }
    } elseif ($remoteUrl -match 'dev\.azure\.com|visualstudio\.com') {
        $platform = "Azure DevOps"
        if ($PullRequest) {
            $url = "$remoteUrl/pullrequests"
        } elseif ($Issues) {
            $url = "$remoteUrl/_workitems"
        } elseif ($Actions) {
            $url = "$remoteUrl/_build"
        } elseif ($hasBranch) {
            $url = "$remoteUrl?version=GB$Branch"
        } else {
            $url = $remoteUrl
        }
    }

    Write-DevKitInfo "Platform: $platform"

    # Final safety gate: never launch anything that isn't a well-formed
    # http(s) URL to a real host. This is the last line of defense
    # against a malicious/garbage remote (e.g. a bare command name like
    # "calc.exe") reaching Start-Process.
    if ($url -notmatch '^https?://[A-Za-z0-9.-]+/') {
        Write-DevKitError "Refusing to open '$url' - not a valid http(s) URL."
        exit 1
    }

    Write-DevKitInfo "Opening: $url"

    Start-Process $url

    Write-Host ""
}
