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


$CommonModule = Join-Path $PSScriptRoot ".." "lib" "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }


Write-Host "`nNorthstar DevKit - Git Cleanup`n" -ForegroundColor Cyan

if (-not (Test-Path $Path)) {
    Write-Host "  ERROR: Path not found: $Path`n" -ForegroundColor Red
    exit 1
}
$targetPath = (Resolve-Path $Path).Path
$gitPath = Join-Path $targetPath ".git"

Write-Host "  Path: $targetPath" -ForegroundColor Gray

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
Write-Host "`n  Analyzing repository..." -ForegroundColor Yellow
$sizeBefore = (git count-objects -vH 2>$null | Select-String "size-pack" | ForEach-Object { $_.Line.Split(":")[1].Trim() })
if (-not $sizeBefore) { $sizeBefore = "Unknown" }
Write-Host "  Current pack size: $sizeBefore" -ForegroundColor Gray

# Fetch latest from remote (dry-run safe)
if (-not $DryRun) {
    Write-Host "`n  Fetching from remote..." -ForegroundColor Yellow
    git fetch --all --prune 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
}

# Find merged branches (excluding current, main, master, develop)
$currentBranch = git branch --show-current 2>$null
$mergedBranches = git branch --merged 2>$null | 
    Where-Object { $_ -match '^\s+' } |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -ne $currentBranch -and $_ -notin @('main', 'master', 'develop') }

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
                    git branch -d $branch 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
                    Write-Host "  Deleted: $branch" -ForegroundColor Green
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
    Write-Host "`n  Pruning remote-tracking branches..." -ForegroundColor Yellow
    git remote prune origin 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
}

# Garbage collection
if ($DryRun) {
    Write-Host "  [DRY RUN] Would run garbage collection" -ForegroundColor Magenta
} else {
    Write-Host "`n  Running garbage collection..." -ForegroundColor Yellow
    git gc --aggressive --prune=now 2>&1 | ForEach-Object { 
        if ($_ -match '^(Counting|Compressing|Writing|Total)') {
            Write-Host "    $_" -ForegroundColor DarkGray
        }
    }
}

# Clear reflog if requested
if ($ClearReflog) {
    if ($DryRun) {
        Write-Host "  [DRY RUN] Would clear reflog" -ForegroundColor Magenta
    } else {
        if ($Force -or (Read-Host "`n  Clear reflog? This is irreversible! (y/n)") -eq 'y') {
            Write-Host "  Clearing reflog..." -ForegroundColor Yellow
            git reflog expire --expire=now --all 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
            Write-Host "  Reflog cleared." -ForegroundColor Green
        }
    }
}

# Run gc again after reflog clear
if ($ClearReflog -and -not $DryRun) {
    Write-Host "  Running final garbage collection..." -ForegroundColor Yellow
    git gc --aggressive --prune=now 2>&1 | Out-Null
}

# Get final size
if (-not $DryRun) {
    Write-Host "`n  Analyzing results..." -ForegroundColor Yellow
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
