#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Git Standup - Northstar DevKit
.DESCRIPTION
    Collects YOUR recent commits across git repositories - a quick answer to
    "what did I do recently?" before a standup. The author is resolved per
    repository from that repo's own 'git config user.email' (falling back to
    user.name), so repos with a different local identity (e.g. work vs.
    personal email) are still matched correctly; the ambient identity is
    used only as a fallback for repos with no local override.

    With the default -Path '.', every linked project from the DevKit project
    registry is scanned; with any other -Path, the directory is scanned for
    git repositories the same way Git-StatusAll does (depth 2, skipping
    dependency/build trees). Fully read-only: never fetches, never mutates.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Path
    '.' (default) scans all linked projects; any other directory is scanned
    recursively for git repositories.
.PARAMETER Hours
    How far back to look, in hours. Default: 24. Range: 1-720.
.EXAMPLE
    .\Get-GitStandup.ps1
    .\Get-GitStandup.ps1 -Hours 72
    .\Get-GitStandup.ps1 -Path "C:\Projects" -Hours 8
#>
[CmdletBinding()]
param(
    [string]$Path = ".",
    [ValidateRange(1, 720)]
    [int]$Hours = 24
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) {
    . $CommonModule
} else {
    Write-Host "ERROR: Required module not found: $CommonModule" -ForegroundColor Red
    exit 1
}

Write-DevKitHeader "Git Standup"

# Check if git is available (Get-Command alone would ShellExecute-shim
# ambiguous matches; this is the toolkit's safe resolver).
$gitExe = Get-DevKitWindowsExecutable -Name 'git'
if (-not $gitExe) {
    Write-DevKitError "Git not found in PATH."
    exit 1
}

# Resolve a fallback identity, used only for repos that have no repo-local
# git config of their own: email first (most precise), name as fallback -
# matching 'git log --author' against either. Each repo scanned below
# re-resolves its own identity from its local config first (see the main
# loop), since developers commonly configure a different identity per repo
# (e.g. separate work vs. personal email).
$author = [string](git config user.email 2>$null)
if ([string]::IsNullOrWhiteSpace($author)) {
    $author = [string](git config user.name 2>$null)
}
if ([string]::IsNullOrWhiteSpace($author)) {
    Write-DevKitError "Could not determine your git identity - set 'git config --global user.email' (or user.name) first."
    exit 1
}
$author = $author.Trim()

Write-DevKitInfo "Author (fallback): $author"
Write-DevKitInfo "Window: last $Hours hour(s)"

# Discover repositories to scan.
$repos = @()

if ($Path -eq '.') {
    $linked = @(Get-DevKitLinkedProjects | Where-Object { -not $_.Missing })
    $seen = @{}
    foreach ($p in $linked) {
        if (-not (Test-Path (Join-Path $p.path ".git"))) { continue }
        $key = $p.path.TrimEnd('\').ToLower()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $repos += [PSCustomObject]@{ Name = $p.name; Path = $p.path }
    }
    if ($repos.Count -eq 0) {
        Write-Host "  No git repositories among your linked projects." -ForegroundColor Yellow
        Write-DevKitInfo "Link projects via the Projects menu first, or run with -Path <folder> to scan a directory."
        Write-Host ""
        exit 0
    }
    Write-DevKitInfo "Source: linked projects ($($repos.Count) git repo(s))"
} else {
    try {
        $targetPath = Resolve-DevKitDirectory -Path $Path
    } catch {
        Write-DevKitError $_
        exit 1
    }

    # Same scan shape as Git-StatusAll: the root itself plus recursion
    # (default depth 2), skipping dependency/build trees like node_modules.
    $scanDepth = 2
    $excludedDirNames = @('node_modules', 'dist', '.next', '.turbo', 'bin', 'obj')
    $gitRepos = @()
    if (Test-Path (Join-Path $targetPath ".git")) {
        $gitRepos += Get-Item -Path $targetPath
    }
    $gitRepos += Get-ChildItem -Path $targetPath -Directory -Recurse -Depth $scanDepth -Exclude $excludedDirNames -ErrorAction SilentlyContinue |
        Where-Object {
            $relative = $_.FullName.Substring($targetPath.Length).TrimStart('\', '/')
            $segments = $relative -split '[\\/]'
            -not ($segments | Where-Object { $excludedDirNames -contains $_ })
        } |
        Where-Object { Test-Path (Join-Path $_.FullName ".git") }

    foreach ($r in $gitRepos) {
        $relPath = $r.FullName.Substring($targetPath.Length).TrimStart('\', '/')
        $name = if ([string]::IsNullOrEmpty($relPath)) { Split-Path -Leaf $r.FullName } else { $relPath }
        $repos += [PSCustomObject]@{ Name = $name; Path = $r.FullName }
    }

    if ($repos.Count -eq 0) {
        Write-Host "  No git repositories found under $targetPath." -ForegroundColor Yellow
        Write-Host ""
        exit 0
    }
    Write-DevKitInfo "Source: $targetPath ($($repos.Count) git repo(s))"
}
Write-Host ""

# Collect commits per repo. Never fetches; local history only.
$totalCommits = 0
$sinceArg = "$Hours hours ago"

foreach ($repo in $repos) {
    # Repo-local identity first (falls back to the ambient identity resolved
    # above if this repo has no local override) so repos configured with a
    # different git identity (work vs. personal email, etc.) are matched
    # correctly instead of silently excluded.
    $repoAuthor = [string](git -C $repo.Path config user.email 2>$null)
    if ([string]::IsNullOrWhiteSpace($repoAuthor)) {
        $repoAuthor = [string](git -C $repo.Path config user.name 2>$null)
    }
    if ([string]::IsNullOrWhiteSpace($repoAuthor)) {
        $repoAuthor = $author
    }
    $repoAuthor = $repoAuthor.Trim()

    $lines = @(git -C $repo.Path log --all "--since=$sinceArg" "--author=$repoAuthor" "--pretty=format:%h %s (%cr)" 2>$null)
    if ($LASTEXITCODE -ne 0) {
        # A repo with no commits at all (unborn HEAD) makes git log exit
        # non-zero - that is an honest "no commits", not an error.
        $null = git -C $repo.Path rev-parse --verify HEAD 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  $($repo.Name)" -ForegroundColor Red -NoNewline
            Write-Host " [ERROR: git log failed]" -ForegroundColor DarkGray
        }
        continue
    }
    $lines = @($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -eq 0) { continue }

    Write-Host "  $($repo.Name)" -ForegroundColor Cyan -NoNewline
    Write-Host " ($($lines.Count) commit(s))" -ForegroundColor Gray
    foreach ($line in $lines) {
        Write-Host "    $line" -ForegroundColor Gray
    }
    $totalCommits += $lines.Count
}

Write-Host ""
if ($totalCommits -eq 0) {
    Write-Host "  No commits by your git identity in the last $Hours hour(s) across $($repos.Count) repo(s)." -ForegroundColor Yellow
    Write-DevKitInfo "Try a wider window, e.g. -Hours 72."
} else {
    Write-Host "  $totalCommits commit(s) in the last $Hours hour(s) across $($repos.Count) repo(s)." -ForegroundColor Green
}
Write-Host ""
exit 0
