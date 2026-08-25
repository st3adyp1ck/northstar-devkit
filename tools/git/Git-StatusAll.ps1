#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Git Status All - Northstar DevKit
.DESCRIPTION
    Show git status for multiple repositories in a directory.
    Recursively scans for Git repos and displays their status
    in a compact, color-coded format.
    
    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Path
    Root directory to scan. Defaults to current directory.
.PARAMETER Depth
    Maximum recursion depth. Default: 2
.PARAMETER ShowClean
    Show clean repositories (hidden by default).
.PARAMETER Fetch
    Fetch from remote before checking status (slower).
.EXAMPLE
    .\Git-StatusAll.ps1
    .\Git-StatusAll.ps1 -Path "C:\Projects" -Depth 3
    .\Git-StatusAll.ps1 -ShowClean
    .\Git-StatusAll.ps1 -Fetch
#>[CmdletBinding()]
param(
    [string]$Path = ".",
    [int]$Depth = 2,
    [switch]$ShowClean,
    [switch]$Fetch
)


$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }


try {
    $targetPath = Resolve-DevKitDirectory -Path $Path
} catch {
    Write-DevKitHeader "Git Status All"
    Write-DevKitError $_
    exit 1
}

Write-DevKitHeader "Git Status All"
Write-Host "  Scanning: $targetPath" -ForegroundColor Gray
Write-Host "  Depth: $Depth levels" -ForegroundColor Gray
Write-Host "  Fetch: $(if($Fetch){'Yes'}else{'No'})" -ForegroundColor Gray
if (-not $ShowClean) {
    Write-Host "  (Clean repos hidden - use -ShowClean to show all)" -ForegroundColor DarkGray
}
Write-Host ""

# Check if git is available
try {
    $null = git --version 2>$null
} catch {
    Write-Host "  ERROR: Git not found in PATH.`n" -ForegroundColor Red
    exit 1
}

# Find Git repositories
Write-Host "  Scanning for repositories..." -ForegroundColor Cyan

$excludedDirNames = @('node_modules', 'dist', '.next', '.turbo', 'bin', 'obj')

$gitRepos = @()
if (Test-Path (Join-Path $targetPath ".git")) {
    $gitRepos += Get-Item -Path $targetPath
}
# Note: Get-ChildItem's own -Exclude only filters the matched directory name
# out of the *output*, it does not stop recursion from descending into it, so
# we additionally filter out anything nested inside an excluded directory
# (relative to the scan root) to avoid noise trees like node_modules.
$gitRepos += Get-ChildItem -Path $targetPath -Directory -Recurse -Depth $Depth -Exclude $excludedDirNames -ErrorAction SilentlyContinue |
    Where-Object {
        $relative = $_.FullName.Substring($targetPath.Length).TrimStart('\', '/')
        $segments = $relative -split '[\\/]'
        -not ($segments | Where-Object { $excludedDirNames -contains $_ })
    } |
    Where-Object { Test-Path (Join-Path $_.FullName ".git") }

if (-not $gitRepos) {
    Write-Host "  No Git repositories found.`n" -ForegroundColor Yellow
    exit 0
}

Write-Host "  Found $($gitRepos.Count) repository(ies)`n" -ForegroundColor Green

# Track summary
$summary = @{
    Clean = 0
    Modified = 0
    Ahead = 0
    Behind = 0
    Error = 0
}

# Process each repo
foreach ($repo in $gitRepos) {
    $repoPath = $repo.FullName
    $relPath = $repoPath.Substring($targetPath.Length).TrimStart('\', '/')

    try {
        Push-Location $repoPath -ErrorAction Stop
    } catch {
        Write-Host "  $relPath" -ForegroundColor Red -NoNewline
        Write-Host " [ERROR: could not enter directory: $_]" -ForegroundColor DarkGray
        $summary.Error++
        continue
    }

    try {
        # Fetch if requested
        if ($Fetch) {
            git fetch --all --quiet 2>$null
        }
        
        # Get current branch
        $branch = git branch --show-current 2>$null
        if (-not $branch) { $branch = "(detached HEAD)" }
        
        # Get status
        $status = git status --porcelain 2>$null
        $untracked = git status --porcelain --untracked-files=all 2>$null | 
            Where-Object { $_ -match '^\?\?' }
        $modified = git status --porcelain 2>$null | 
            Where-Object { $_ -notmatch '^\?\?' }
        
        # Check ahead/behind (only meaningful when an upstream is configured;
        # verify @{u} resolves first instead of letting a missing upstream
        # silently masquerade as 0 ahead / 0 behind)
        $null = git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null
        $hasUpstream = ($LASTEXITCODE -eq 0)
        $noUpstream = -not $hasUpstream
        $ahead = 0
        $behind = 0
        if ($hasUpstream) {
            $aheadBehind = git rev-list --left-right --count 'HEAD...@{u}' 2>$null
            if ($LASTEXITCODE -eq 0 -and $aheadBehind -match '(\d+)\s+(\d+)') {
                $ahead = [int]$matches[1]
                $behind = [int]$matches[2]
            }
        }

        # Determine status - a repo with no upstream is never silently treated
        # as clean, since it may hold unpushed commits we have no way to count.
        $isClean = -not $status -and $ahead -eq 0 -and $behind -eq 0 -and -not $noUpstream
        
        if ($isClean -and -not $ShowClean) {
            $summary.Clean++
            Pop-Location
            continue
        }
        
        # Display repo status
        if ($isClean) {
            Write-Host "  $relPath" -ForegroundColor Green -NoNewline
            Write-Host " [$branch]" -ForegroundColor Gray
            $summary.Clean++
        } else {
            Write-Host "  $relPath" -ForegroundColor Cyan -NoNewline
            Write-Host " [$branch]" -ForegroundColor Gray -NoNewline
            
            # Status indicators
            $indicators = @()
            if ($noUpstream) {
                $indicators += "no-upstream"
            }
            if ($modified) {
                $indicators += "M:$($modified.Count)"
            }
            if ($untracked) {
                $indicators += "U:$($untracked.Count)"
            }
            if ($modified -or $untracked) {
                $summary.Modified++
            }
            if ($ahead -gt 0) {
                $indicators += "A:$ahead"
                $summary.Ahead++
            }
            if ($behind -gt 0) {
                $indicators += "B:$behind"
                $summary.Behind++
            }

            Write-Host " $($indicators -join ' ')" -ForegroundColor Yellow
            
            # Show specific files if there are changes
            if ($modified.Count -le 5 -and $modified.Count -gt 0) {
                $modified | ForEach-Object {
                    $file = $_.Substring(3)
                    $statusCode = $_.Substring(0, 2).Trim()
                    $color = switch ($statusCode) {
                        'M' { 'Yellow' }
                        'A' { 'Green' }
                        'D' { 'Red' }
                        'R' { 'Magenta' }
                        default { 'Gray' }
                    }
                    Write-Host "    $statusCode $file" -ForegroundColor $color
                }
            }
        }
    } catch {
        Write-Host "  $relPath" -ForegroundColor Red -NoNewline
        Write-Host " [ERROR: $_]" -ForegroundColor DarkGray
        $summary.Error++
    } finally {
        Pop-Location -ErrorAction SilentlyContinue
    }
}

# Summary
Write-Host "`n  ===================================" -ForegroundColor Cyan
Write-Host "  Summary:" -ForegroundColor Cyan
Write-Host "    Clean:     $($summary.Clean)" -ForegroundColor Green
Write-Host "    Modified:  $($summary.Modified)" -ForegroundColor Yellow
Write-Host "    Ahead:     $($summary.Ahead)" -ForegroundColor Magenta
Write-Host "    Behind:    $($summary.Behind)" -ForegroundColor Magenta
if ($summary.Error -gt 0) {
    Write-Host "    Errors:    $($summary.Error)" -ForegroundColor Red
}
Write-Host "  ===================================`n" -ForegroundColor Cyan
