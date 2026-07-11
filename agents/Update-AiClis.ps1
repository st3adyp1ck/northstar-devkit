#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Update AI CLIs - Northstar DevKit
.DESCRIPTION
    Updates AI coding-agent CLIs that are installed AND known to be
    distributed via npm. Anything installed through another channel (a Go
    binary, pip, a shell installer, etc.) is reported as "update manually"
    instead of guessing a package name for it.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Only
    Restrict to these tool command name(s), e.g. -Only claude,gemini.
.PARAMETER DryRun
    Show current/latest versions and what would update. No changes made.
.PARAMETER Force
    Skip the confirmation prompt before updating.
.EXAMPLE
    .\Update-AiClis.ps1
    .\Update-AiClis.ps1 -DryRun
    .\Update-AiClis.ps1 -Only claude -Force
#>
[CmdletBinding()]
param(
    [string[]]$Only,
    [switch]$DryRun,
    [switch]$Force
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

Write-DevKitHeader "Update AI CLIs"

# Small, best-effort map of command name -> npm package name. Only tools
# actually distributed through npm belong here - gh (Go binary), aider
# (pip/pipx), and cursor-agent (shell installer) are deliberately left out
# so this script never guesses a package name for them.
$npmPackageMap = @{
    'claude' = '@anthropic-ai/claude-code'
    'codex'  = '@openai/codex'
    'gemini' = '@google/gemini-cli'
}

$knownTools = @('claude', 'gh', 'codex', 'gemini', 'cursor-agent', 'aider')

$candidateNames = $knownTools
if ($Only -and $Only.Count -gt 0) {
    $candidateNames = @($knownTools | Where-Object { $Only -contains $_ })
    if ($candidateNames.Count -eq 0) {
        Write-DevKitError "None of the names in -Only match a known tool ($($knownTools -join ', '))."
        exit 1
    }
}

function Get-AiCliLocalVersion {
    param([string]$CommandPath)
    try {
        $output = & $CommandPath --version 2>&1
        $exitCode = $LASTEXITCODE
    } catch {
        return $null
    }
    if ($null -ne $exitCode -and $exitCode -ne 0) { return $null }
    $firstLine = [string](@($output) | Select-Object -First 1)
    if ($firstLine -match '(\d+\.\d+(\.\d+)?(-[A-Za-z0-9.]+)?)') { return $matches[1] }
    return $null
}

function Get-NpmLatestVersion {
    param([string]$Package)
    try {
        $output = npm view $Package version 2>&1
        $exitCode = $LASTEXITCODE
    } catch {
        return $null
    }
    if ($exitCode -ne 0) { return $null }
    $line = [string](@($output) | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($line)) { return $null }
    return $line.Trim()
}

$mappable = @()
foreach ($name in $candidateNames) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if (-not $cmd) {
        Write-Host "  $name -- not installed, skipping" -ForegroundColor Gray
        continue
    }

    if ($npmPackageMap.ContainsKey($name)) {
        $mappable += [PSCustomObject]@{ Name = $name; Package = $npmPackageMap[$name]; CommandPath = $cmd.Source }
    } else {
        Write-Host "  $name -- no known npm update path - update manually" -ForegroundColor Gray
    }
}

if ($mappable.Count -eq 0) {
    Write-DevKitInfo "No installed, npm-mappable AI CLIs found to update."
    exit 0
}

Write-Host ""
$updatable = @()
foreach ($tool in $mappable) {
    $current = Get-AiCliLocalVersion -CommandPath $tool.CommandPath
    $latest = Get-NpmLatestVersion -Package $tool.Package

    $currentDisplay = if ($current) { $current } else { 'unknown' }
    $latestDisplay = if ($latest) { $latest } else { 'unavailable (network?)' }
    $updateAvailable = ($current -and $latest -and $current -ne $latest)

    $line = "  $($tool.Name) ($($tool.Package)): current=$currentDisplay latest=$latestDisplay"
    if ($updateAvailable) {
        Write-Host "$line -- update available" -ForegroundColor Yellow
        $updatable += $tool
    } else {
        Write-Host $line -ForegroundColor Gray
    }
}

if ($DryRun) {
    Write-Host ""
    Write-DevKitInfo "[DRY RUN] No changes made."
    exit 0
}

if ($updatable.Count -eq 0) {
    Write-Host ""
    Write-Host "  Everything is already up to date." -ForegroundColor Green
    exit 0
}

Write-Host ""
if (-not (Confirm-DevKitDestructiveAction -Action "update $($updatable.Count) AI CLI tool(s) via npm" -Force:$Force)) {
    Write-DevKitInfo "Cancelled."
    exit 0
}

Write-Host ""
$failures = 0
foreach ($tool in $updatable) {
    Write-DevKitStep "Updating $($tool.Name) ($($tool.Package))"
    try {
        $installOutput = npm install -g "$($tool.Package)@latest" 2>&1
        $installExit = $LASTEXITCODE
        if ($installExit -eq 0) {
            Write-DevKitDone
        } else {
            Write-Host " FAILED (exit code $installExit)" -ForegroundColor Red
            @($installOutput) | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
            $failures++
        }
    } catch {
        Write-Host " FAILED: $_" -ForegroundColor Red
        $failures++
    }
}

Write-Host ""
if ($failures -gt 0) {
    Write-DevKitError "$failures of $($updatable.Count) update(s) failed."
    exit 1
}

Write-Host "  DONE: All $($updatable.Count) AI CLI tool(s) updated." -ForegroundColor Green
exit 0
