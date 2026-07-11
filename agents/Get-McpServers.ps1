#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Get MCP Servers - Northstar DevKit
.DESCRIPTION
    Lists Claude Code's configured MCP servers via 'claude mcp list'. Purely
    read-only. Optionally resolves the DevKit active project (never
    prompting or mutating it) and runs the list from inside that project's
    directory so its project/local-scope servers are visible.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Scope
    Informational framing only - 'claude mcp list' has no scope flag, so
    this just labels which scope context the printed list reflects.
.PARAMETER UseActiveProject
    Resolve the DevKit active project (read-only) and list from inside it.
.EXAMPLE
    .\Get-McpServers.ps1
    .\Get-McpServers.ps1 -UseActiveProject
    .\Get-McpServers.ps1 -Scope User
#>
[CmdletBinding()]
param(
    [ValidateSet('All', 'User', 'Project')]
    [string]$Scope = 'All',
    [switch]$UseActiveProject
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

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

if ($projectPath) {
    Write-DevKitInfo "Scope context: $Scope (includes project/local-scope servers from '$projectPath')"
} else {
    Write-DevKitInfo "Scope context: $Scope (current directory - no project context resolved)"
}

Write-Host ""

$pushedLocation = $false
if ($projectPath) {
    try {
        Push-Location -LiteralPath $projectPath
        $pushedLocation = $true
    } catch {
        Write-DevKitError "Failed to enter project path '$projectPath': $_"
        exit 1
    }
}

$listFailed = $false
$listErrorMessage = $null
$listExitCode = $null
try {
    claude mcp list
    $listExitCode = $LASTEXITCODE
} catch {
    $listFailed = $true
    $listErrorMessage = $_
} finally {
    if ($pushedLocation) { Pop-Location }
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
