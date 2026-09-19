#!/usr/bin/env pwsh
<#
.SYNOPSIS
    SessionStart hook - Northstar DevKit
.DESCRIPTION
    Read-only git sync check that runs at the start of every Claude Code
    session in this repo. Fetches refs (no pull/merge) and reports whether
    the current checkout is ahead/behind its upstream, so a session never
    silently starts work on a stale checkout - the exact problem that lost
    a machine's worth of local restructuring work before it was caught by
    hand on 2026-09-19.

    Outputs SessionStart hook JSON: a systemMessage (shown to the user) only
    when the branch is actually ahead/behind, plus additionalContext (fed to
    Claude) with the full `git status -sb` output every time. Never blocks
    the session - a missing git repo, missing git binary, or fetch failure
    (offline, no remote) all degrade to silence rather than an error.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
#>

$ErrorActionPreference = 'SilentlyContinue'

function Write-DevKitHookResult {
    param([hashtable]$Result)
    $Result | ConvertTo-Json -Depth 5 -Compress
    exit 0
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-DevKitHookResult @{}
}

git rev-parse --is-inside-work-tree 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    # Not a git repo - nothing to check.
    Write-DevKitHookResult @{}
}

# Fetch only - never pull/merge. A network failure (offline, VPN down) must
# not block the session; git status still runs against whatever refs are
# already known locally.
git fetch --quiet 2>$null | Out-Null

$statusLines = @(git status -sb 2>$null)
if (-not $statusLines -or $statusLines.Count -eq 0) {
    Write-DevKitHookResult @{}
}

$branchLine = $statusLines[0]
$dirtyCount = [Math]::Max(0, $statusLines.Count - 1)

$aheadBy = $null
$behindBy = $null
if ($branchLine -match 'ahead (\d+)') { $aheadBy = [int]$Matches[1] }
if ($branchLine -match 'behind (\d+)') { $behindBy = [int]$Matches[1] }

$summary = $branchLine.TrimStart('#', ' ')
if ($dirtyCount -gt 0) {
    $summary += " - $dirtyCount uncommitted change$(if ($dirtyCount -ne 1) { 's' })"
}

$context = "git status -sb (SessionStart sync check):`n$($statusLines -join "`n")"

$result = @{
    hookSpecificOutput = @{
        hookEventName     = 'SessionStart'
        additionalContext = $context
    }
}

if ($aheadBy -or $behindBy) {
    $parts = @()
    if ($behindBy) { $parts += "$behindBy commit$(if ($behindBy -ne 1) { 's' }) behind" }
    if ($aheadBy) { $parts += "$aheadBy commit$(if ($aheadBy -ne 1) { 's' }) ahead" }
    $result.systemMessage = "Git sync check: $summary ($($parts -join ', ')). Reconcile before starting work if this is unexpected - see AGENTS.md/CLAUDE.md for this repo's two-machine workflow."
}

Write-DevKitHookResult $result
