#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Git Cleanup - Northstar DevKit
.DESCRIPTION
    Cleans up a Git repository by pruning merged branches, running garbage
    collection, and optionally clearing the reflog. Shows before/after size.
    
    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Path
    Path to the Git repository. Defaults to current directory.
.PARAMETER ClearReflog
    Clear the reflog (use with caution - irreversible).
.PARAMETER Force
    Skip confirmation prompts.
.PARAMETER DryRun
    Show what would be done without making changes.
.EXAMPLE
    .\Git-Cleanup.ps1
    .\Git-Cleanup.ps1 -Path "C:\my-project"
    .\Git-Cleanup.ps1 -ClearReflog -Force
    .\Git-Cleanup.ps1 -DryRun
#>[CmdletBinding()]
param(
    [string]$Path = ".",
    [switch]$ClearReflog,
    [switch]$Force,
    [switch]$DryRun
)


$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }


try {
    $targetPath = Resolve-DevKitDirectory -Path $Path
} catch {
    Write-DevKitHeader "Git Cleanup"
    Write-DevKitError $_
    exit 1
}

Write-DevKitHeader "Git Cleanup"
Write-DevKitInfo "Path: $targetPath"

$gitPath = Join-Path $targetPath ".git"

# Verify Git repo
if (-not (Test-Path $gitPath)) {
    Write-Host "`n  ERROR: Not a Git repository.`n" -ForegroundColor Red
    exit 1
}

try {
    Push-Location $targetPath

# Check if git command available
try {
    $null = git rev-parse --git-dir 2>$null
} catch {
    Write-Host "`n  ERROR: Git not found in PATH.`n" -ForegroundColor Red
    Pop-Location
    exit 1
}

# Get initial size
Write-Host "`n  Analyzing repository..." -ForegroundColor Cyan
$sizeBefore = (git count-objects -vH 2>$null | Select-String "size-pack" | ForEach-Object { $_.Line.Split(":")[1].Trim() })
if (-not $sizeBefore) { $sizeBefore = "Unknown" }
Write-Host "  Current pack size: $sizeBefore" -ForegroundColor Gray

# Fetch latest from remote (dry-run safe)
if (-not $DryRun) {
    Write-Host "`n  Fetching from remote..." -ForegroundColor Cyan
    git fetch --all --prune 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ERROR: git fetch --all --prune failed (exit code $LASTEXITCODE)." -ForegroundColor Red
    }
}

# Determine the actual default/integration branch so "merged" is measured
# against it instead of whatever happens to be checked out (HEAD).
$currentBranch = git branch --show-current 2>$null
$defaultBranch = $null

$symbolicRef = git symbolic-ref refs/remotes/origin/HEAD 2>$null
if ($LASTEXITCODE -eq 0 -and $symbolicRef) {
    $defaultBranch = ($symbolicRef -replace '^refs/remotes/origin/', '').Trim()
}

if (-not $defaultBranch) {
    $remoteShow = git remote show origin 2>$null
    if ($LASTEXITCODE -eq 0) {
        foreach ($line in $remoteShow) {
            if ($line -match 'HEAD branch:\s*(\S+)') {
                if ($matches[1] -and $matches[1] -ne '(unknown)') {
                    $defaultBranch = $matches[1]
                }
                break
            }
        }
    }
}

if (-not $defaultBranch) {
    foreach ($candidate in @('main', 'master', 'develop')) {
        git show-ref --verify --quiet "refs/heads/$candidate" 2>$null
        if ($LASTEXITCODE -eq 0) {
            $defaultBranch = $candidate
            break
        }
    }
}

# Find merged branches (excluding current, the default branch, main, master, develop)
$mergedBranches = @()
if ($defaultBranch) {
    Write-Host "  Default branch: $defaultBranch" -ForegroundColor Gray
    $mergedBranches = git branch --merged $defaultBranch 2>$null |
        Where-Object { $_ -match '^\s+' } |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne $currentBranch -and $_ -ne $defaultBranch -and $_ -notin @('main', 'master', 'develop') }
} else {
    Write-Host "  WARNING: Could not determine the default branch; skipping merged-branch detection." -ForegroundColor Yellow
}

if ($mergedBranches) {
    Write-Host "`n  Found merged branches:" -ForegroundColor Yellow
    $mergedBranches | ForEach-Object { Write-Host "    - $_" -ForegroundColor Gray }
    
    if ($DryRun) {
        Write-Host "  [DRY RUN] Would delete these branches" -ForegroundColor Magenta
    } else {
        $deleteBranches = $Force -or ((Read-Host "`n  Delete these merged branches? (y/n)") -eq 'y')
        if ($deleteBranches) {
            foreach ($branch in $mergedBranches) {
                try {
                    $deleteOutput = git branch -d $branch 2>&1
                    $deleteExit = $LASTEXITCODE
                    $deleteOutput | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
                    if ($deleteExit -eq 0) {
                        Write-Host "  Deleted: $branch" -ForegroundColor Green
                    } else {
                        Write-Host "  ERROR deleting $branch`: $deleteOutput" -ForegroundColor Red
                    }
                } catch {
                    Write-Host "  ERROR deleting $branch`: $_" -ForegroundColor Red
                }
            }
        }
    }
} else {
    Write-Host "`n  No merged branches to clean up." -ForegroundColor Green
}

# Prune remote-tracking branches
if ($DryRun) {
    Write-Host "`n  [DRY RUN] Would prune remote-tracking branches" -ForegroundColor Magenta
} else {
    Write-Host "`n  Pruning remote-tracking branches..." -ForegroundColor Cyan
    git remote prune origin 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ERROR: git remote prune origin failed (exit code $LASTEXITCODE)." -ForegroundColor Red
    }
}

# Runs `git gc --aggressive --prune=now`. Local helper so the confirmation +
# exit-code handling isn't duplicated between the standalone pass below and
# the post-reflog-clear pass.
function Invoke-DevKitGitGc {
    Write-Host "  Running garbage collection..." -ForegroundColor Cyan
    git gc --aggressive --prune=now 2>&1 | ForEach-Object {
        if ($_ -match '^(Counting|Compressing|Writing|Total)') {
            Write-Host "    $_" -ForegroundColor DarkGray
        }
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ERROR: git gc --aggressive --prune=now failed (exit code $LASTEXITCODE)." -ForegroundColor Red
    }
}

# Garbage collection. When -ClearReflog is also set, skip this pre-clear pass
# entirely: the post-reflog-clear pass below is the only one that matters,
# since it fully supersedes anything gc'd here.
if ($DryRun) {
    Write-Host "  [DRY RUN] Would run garbage collection" -ForegroundColor Magenta
} elseif ($ClearReflog) {
    Write-Host "`n  Skipping pre-reflog garbage collection (will run once after reflog clear)." -ForegroundColor Gray
} else {
    $runGc = $Force -or ((Read-Host "`n  Run garbage collection? --prune=now is irreversible (y/n)") -eq 'y')
    if ($runGc) {
        Write-Host ""
        Invoke-DevKitGitGc
    } else {
        Write-Host "  Skipped garbage collection." -ForegroundColor Yellow
    }
}

# Clear reflog if requested
if ($ClearReflog) {
    if ($DryRun) {
        Write-Host "  [DRY RUN] Would clear reflog" -ForegroundColor Magenta
    } else {
        if ($Force -or (Read-Host "`n  Clear reflog? This is irreversible! (y/n)") -eq 'y') {
            Write-Host "  Clearing reflog..." -ForegroundColor Cyan
            git reflog expire --expire=now --all 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  ERROR: git reflog expire failed (exit code $LASTEXITCODE)." -ForegroundColor Red
            } else {
                Write-Host "  Reflog cleared." -ForegroundColor Green
            }
        } else {
            Write-Host "  Skipped reflog clear." -ForegroundColor Yellow
        }

        # This is the only gc pass when -ClearReflog is set (the pre-clear pass
        # above is skipped), so it runs here regardless of the reflog answer
        # above - otherwise declining the reflog prompt would mean gc never
        # runs at all for this invocation.
        if ($Force -or ((Read-Host "`n  Run garbage collection? --prune=now is irreversible (y/n)") -eq 'y')) {
            Invoke-DevKitGitGc
        } else {
            Write-Host "  Skipped garbage collection." -ForegroundColor Yellow
        }
    }
}

# Get final size
if (-not $DryRun) {
    Write-Host "`n  Analyzing results..." -ForegroundColor Cyan
    $sizeAfter = (git count-objects -vH 2>$null | Select-String "size-pack" | ForEach-Object { $_.Line.Split(":")[1].Trim() })
    if (-not $sizeAfter) { $sizeAfter = "Unknown" }
    
    Write-Host "`n  ===================================" -ForegroundColor Cyan
    Write-Host "  Size Before: $sizeBefore" -ForegroundColor Gray
    Write-Host "  Size After:  $sizeAfter" -ForegroundColor Gray
    Write-Host "  ===================================" -ForegroundColor Cyan
    Write-Host "`n  DONE: Git repository cleaned!`n" -ForegroundColor Green
} else {
    Write-Host "`n  [DRY RUN] No changes made.`n" -ForegroundColor Magenta
}
} finally {
    Pop-Location
}
