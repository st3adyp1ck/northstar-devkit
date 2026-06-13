#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Git Sync Fork - Northstar DevKit
.DESCRIPTION
    Sync a forked repository with its upstream remote.
    Fetches upstream, merges or rebases changes, and pushes to origin.
    
    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Path
    Path to the forked repository. Defaults to current directory.
.PARAMETER UpstreamRemote
    Name of the upstream remote. Default: 'upstream'
.PARAMETER OriginRemote
    Name of the origin remote. Default: 'origin'
.PARAMETER Branch
    Branch to sync. Default: current branch or 'main'
.PARAMETER Rebase
    Use rebase instead of merge for syncing.
.PARAMETER Force
    Skip confirmation prompts.
.EXAMPLE
    .\Git-SyncFork.ps1
    .\Git-SyncFork.ps1 -Path "C:\my-fork"
    .\Git-SyncFork.ps1 -UpstreamRemote "upstream" -Rebase
    .\Git-SyncFork.ps1 -Branch "develop"
#>
[CmdletBinding()]
param(
    [string]$Path = ".",
    [string]$UpstreamRemote = "upstream",
    [string]$OriginRemote = "origin",
    [string]$Branch = "",
    [switch]$Rebase,
    [switch]$Force
)

Write-Host "`nNorthstar DevKit - Git Sync Fork`n" -ForegroundColor Cyan

if (-not (Test-Path $Path)) {
    Write-Host "  ERROR: Path not found: $Path`n" -ForegroundColor Red
    exit 1
}
$targetPath = (Resolve-Path $Path).Path

Write-Host "  Path: $targetPath" -ForegroundColor Gray

try {
    Push-Location $targetPath

    # Verify Git repo
    if (-not (Test-Path ".git")) {
        Write-Host "`n  ERROR: Not a Git repository.`n" -ForegroundColor Red
        exit 1
    }

    # Check git availability
    $null = git --version 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "`n  ERROR: Git not found in PATH.`n" -ForegroundColor Red
        exit 1
    }

    # Determine branch
    if (-not $Branch) {
        $Branch = git branch --show-current 2>$null
        if (-not $Branch) {
            git show-ref --verify --quiet refs/heads/main 2>$null
            if ($LASTEXITCODE -eq 0) {
                $Branch = "main"
            } else {
                git show-ref --verify --quiet refs/heads/master 2>$null
                if ($LASTEXITCODE -eq 0) {
                    $Branch = "master"
                } else {
                    Write-Host "`n  ERROR: Could not determine branch. Please specify with -Branch.`n" -ForegroundColor Red
                    exit 1
                }
            }
        }
    }

    Write-Host "  Branch: $Branch" -ForegroundColor Gray
    Write-Host "  Strategy: $(if($Rebase){'Rebase'}else{'Merge'})" -ForegroundColor Gray
    Write-Host ""

    # Check for uncommitted changes
    $status = git status --porcelain 2>$null
    if ($status) {
        Write-Host "  WARNING: You have uncommitted changes!" -ForegroundColor Red
        Write-Host "  Please commit or stash them before syncing." -ForegroundColor Yellow
        Write-Host "`n  Uncommitted files:" -ForegroundColor Gray
        $status | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        Write-Host ""
        exit 1
    }

    # Verify remotes exist
    $remotes = git remote 2>$null
    Write-Host "  Remotes found: $($remotes -join ', ')" -ForegroundColor Gray

    if ($remotes -notcontains $UpstreamRemote) {
        Write-Host "`n  ERROR: Upstream remote '$UpstreamRemote' not found!" -ForegroundColor Red
        Write-Host "  Add it with: git remote add $UpstreamRemote <upstream-url>" -ForegroundColor Yellow
        exit 1
    }

    if ($remotes -notcontains $OriginRemote) {
        Write-Host "`n  ERROR: Origin remote '$OriginRemote' not found!" -ForegroundColor Red
        exit 1
    }

    # Show remote URLs
    $upstreamUrl = git remote get-url $UpstreamRemote 2>$null
    $originUrl = git remote get-url $OriginRemote 2>$null
    Write-Host "  Upstream: $upstreamUrl" -ForegroundColor DarkGray
    Write-Host "  Origin:   $originUrl" -ForegroundColor DarkGray
    Write-Host ""

    # Confirm
    if (-not $Force) {
        $confirm = Read-Host "  Sync $Branch with $UpstreamRemote/$Branch? (y/n)"
        if ($confirm -ne 'y') {
            Write-Host "`n  Cancelled.`n" -ForegroundColor Gray
            exit 0
        }
    }

    # Step 1: Fetch from upstream
    Write-Host "`n  [1/4] Fetching from $UpstreamRemote..." -ForegroundColor Yellow
    $fetchOutput = git fetch $UpstreamRemote 2>&1
    $fetchExit = $LASTEXITCODE
    $fetchOutput | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    if ($fetchExit -ne 0) {
        Write-Host "`n  ERROR: Failed to fetch from upstream.`n" -ForegroundColor Red
        exit 1
    }
    Write-Host "  DONE: Fetched from upstream." -ForegroundColor Green

    # Step 2: Checkout target branch
    Write-Host "`n  [2/4] Checking out $Branch..." -ForegroundColor Yellow
    $checkoutOutput = git checkout "$Branch" 2>&1
    $checkoutExit = $LASTEXITCODE
    $checkoutOutput | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    if ($checkoutExit -ne 0) {
        Write-Host "`n  ERROR: Failed to checkout branch.`n" -ForegroundColor Red
        exit 1
    }
    Write-Host "  DONE: On branch $Branch." -ForegroundColor Green

    # Step 3: Merge or Rebase
    Write-Host "`n  [3/4] Syncing with $UpstreamRemote/$Branch..." -ForegroundColor Yellow
    if ($Rebase) {
        $syncOutput = git rebase "$UpstreamRemote/$Branch" 2>&1
    } else {
        $syncOutput = git merge "$UpstreamRemote/$Branch" --no-edit 2>&1
    }
    $syncExit = $LASTEXITCODE
    $syncOutput | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    if ($syncExit -ne 0) {
        Write-Host "`n  ERROR: Sync failed." -ForegroundColor Red
        Write-Host "  You may need to resolve conflicts manually." -ForegroundColor Yellow
        if ($Rebase) {
            Write-Host "  To abort: git rebase --abort" -ForegroundColor Yellow
        } else {
            Write-Host "  To abort: git merge --abort" -ForegroundColor Yellow
        }
        exit 1
    }
    if ($Rebase) {
        Write-Host "  DONE: Rebased onto $UpstreamRemote/$Branch." -ForegroundColor Green
    } else {
        Write-Host "  DONE: Merged $UpstreamRemote/$Branch." -ForegroundColor Green
    }

    # Step 4: Push to origin
    Write-Host "`n  [4/4] Pushing to $OriginRemote..." -ForegroundColor Yellow
    if ($Rebase) {
        Write-Host "  WARNING: Force-pushing rebased branch!" -ForegroundColor Yellow
        $pushOutput = git push "$OriginRemote" "$Branch" -f 2>&1
    } else {
        $pushOutput = git push "$OriginRemote" "$Branch" 2>&1
    }
    $pushExit = $LASTEXITCODE
    $pushOutput | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    if ($pushExit -ne 0) {
        Write-Host "`n  ERROR: Failed to push.`n" -ForegroundColor Red
        exit 1
    }
    Write-Host "  DONE: Pushed to $OriginRemote." -ForegroundColor Green

    Write-Host "`n  ===================================" -ForegroundColor Cyan
    Write-Host "  Fork sync complete!" -ForegroundColor Green
    Write-Host "  Branch: $Branch" -ForegroundColor Gray
    Write-Host "  Up-to-date with: $UpstreamRemote/$Branch" -ForegroundColor Gray
    Write-Host "  ===================================`n" -ForegroundColor Cyan
} finally {
    Pop-Location
}
