#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Get MCP Servers - Northstar DevKit
.DESCRIPTION
    Lists Claude Code's configured MCP servers via 'claude mcp list'.
    Purely read-only.

    Without a resolved project context, this behaves exactly as before:
    'claude mcp list' is run once from the current directory and its
    output passed straight through, and -Scope is purely informational.

    With a resolved project context (-UseActiveProject), -Scope becomes
    real: 'claude mcp list' has no scope flag of its own, so this runs it
    twice - once from a neutral directory that is very unlikely to itself
    be a Claude Code project (a user/global-scope-only view), and once from
    the project directory (the merged, effective view) - then diffs the two
    plain-text outputs by server name. Entries present in both listings are
    labeled user/global scope; entries present only in the
    project-directory listing are labeled project/local scope. This is a
    pure wrapper around the documented 'claude mcp list' command - it never
    parses Claude Code's internal JSON config files directly, matching this
    module's existing philosophy (see AGENTS.md's "Agents & MCP" section).
    The diff logic itself lives in lib/DevKit-McpList.ps1 so
    Scan-McpServers.ps1 can reuse it rather than duplicating it here.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Scope
    'All' (default), 'User', or 'Project'. Only filters output once a
    project context has been resolved via -UseActiveProject - without one
    there is nothing to diff a scope split against, so the full unfiltered
    'claude mcp list' output is shown regardless of -Scope, exactly as
    before.
.PARAMETER UseActiveProject
    Resolve the DevKit active project (read-only) and diff its effective
    MCP server list against the neutral/user-scope baseline.
.EXAMPLE
    .\Get-McpServers.ps1
    .\Get-McpServers.ps1 -UseActiveProject
    .\Get-McpServers.ps1 -UseActiveProject -Scope Project
#>
[CmdletBinding()]
param(
    [ValidateSet('All', 'User', 'Project')]
    [string]$Scope = 'All',
    [switch]$UseActiveProject
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }
$McpListModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-McpList.ps1"
if (Test-Path $McpListModule) { . $McpListModule }

Write-DevKitHeader "MCP Servers"

if (-not (Test-DevKitCommand 'claude')) {
    Write-DevKitError "claude CLI not found in PATH."
    exit 1
}

$projectPath = $null
if ($UseActiveProject) {
    # Get-DevKitActiveProject is read-only and never prompts - this is a
    # report tool, so Select-DevKitProject (which can mutate the active
    # project) must never be called here.
    $activeProject = Get-DevKitActiveProject
    if (-not $activeProject) {
        Write-DevKitInfo "No active project is set. Listing without a project context."
    } elseif ($activeProject.Missing) {
        Write-DevKitInfo "Active project '$($activeProject.name)' points to a path that no longer exists ($($activeProject.path)). Listing without a project context."
    } else {
        $projectPath = $activeProject.path
    }
}

if (-not $projectPath) {
    # No project context resolved - identical to this script's original
    # behavior: a single unscoped 'claude mcp list' run from the current
    # directory. -Scope stays purely informational here, since without a
    # second listing to compare against there is nothing to diff a scope
    # split from.
    Write-DevKitInfo "Scope context: $Scope (current directory - no project context resolved)"
    Write-Host ""

    # NOT a bare `claude` call: npm installs of Claude Code ship claude.ps1 /
    # claude.cmd / an extension-less POSIX shim side by side, and a bare call
    # lets PowerShell pick the .ps1 or shim - which CreateProcess cannot
    # launch, so the fallback ShellExecute pops a real "Select an app to
    # open" Windows dialog and hangs the run (the repo's documented 3.1
    # incident). tools/lib/DevKit-McpList.ps1 (Invoke-DevKitMcpList) carries
    # the full explanatory comment; this is the same resolver pattern.
    $claudeCmd = $null
    if (Get-Command Get-DevKitWindowsExecutable -ErrorAction SilentlyContinue) {
        $claudeCmd = Get-DevKitWindowsExecutable -Name 'claude'
    }
    if (-not $claudeCmd) {
        Write-DevKitError "'claude' was not found on PATH, or only resolves to a non-Windows shim that cannot be launched directly."
        exit 1
    }

    $listFailed = $false
    $listErrorMessage = $null
    $listExitCode = $null
    try {
        if ($claudeCmd.CommandType -eq 'Application') {
            & $claudeCmd.Source mcp list
        } else {
            # A profile-defined function or alias - runnable in-process only.
            & $claudeCmd mcp list
        }
        $listExitCode = $LASTEXITCODE
    } catch {
        $listFailed = $true
        $listErrorMessage = $_
    }

    if ($listFailed) {
        Write-DevKitError "Failed to run 'claude mcp list': $listErrorMessage"
        exit 1
    }

    if ($null -ne $listExitCode -and $listExitCode -ne 0) {
        Write-DevKitError "'claude mcp list' exited with code $listExitCode."
        exit 1
    }

    exit 0
}

Write-DevKitInfo "Scope context: $Scope (includes project/local-scope servers from '$projectPath')"
Write-Host ""

$diff = Get-DevKitMcpScopeDiff -ProjectPath $projectPath
if (-not $diff.Success) {
    Write-DevKitError $diff.ErrorMessage
    exit 1
}

if ($Scope -eq 'All' -or $Scope -eq 'User') {
    Write-Host "  User / global scope (available in every project):" -ForegroundColor Magenta
    if ($diff.UserScope.Count -eq 0) {
        Write-Host "    (none)" -ForegroundColor Gray
    } else {
        foreach ($name in $diff.UserScope.Keys) { Write-Host "    $($diff.UserScope[$name])" }
    }
    Write-Host ""
}

if ($Scope -eq 'All' -or $Scope -eq 'Project') {
    Write-Host "  Project / local scope ('$projectPath' only):" -ForegroundColor Magenta
    if ($diff.ProjectScope.Count -eq 0) {
        Write-Host "    (none)" -ForegroundColor Gray
    } else {
        foreach ($name in $diff.ProjectScope.Keys) { Write-Host "    $($diff.ProjectScope[$name])" }
    }
    Write-Host ""
}

exit 0
