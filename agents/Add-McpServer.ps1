#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Add MCP Server - Northstar DevKit
.DESCRIPTION
    Registers an MCP server with Claude Code via 'claude mcp add', at the
    requested scope (local/project/user). Mutates real Claude Code MCP
    configuration - always confirms before running.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Name
    Name to register the MCP server under.
.PARAMETER Command
    The command to run for this (stdio) MCP server.
.PARAMETER CommandArgs
    Arguments passed through to Command, in order.
.PARAMETER Scope
    'local' (this machine+project only, default), 'project' (shared via
    .mcp.json), or 'user' (global, all projects).
.PARAMETER EnvVars
    Zero or more KEY=VALUE entries passed as '-e KEY=VALUE' to claude.
.PARAMETER ProjectPath
    For scope local/project: the project directory whose .mcp.json /
    local config this should target. claude reads project/local scope from
    the current directory, so this script Push-Location's into it first.
.PARAMETER Force
    Skip the confirmation prompt.
.EXAMPLE
    .\Add-McpServer.ps1 -Name my-server -Command npx -CommandArgs '-y','my-mcp-server'
    .\Add-McpServer.ps1 -Name my-server -Command npx -CommandArgs '-y','my-mcp-server' -Scope user
    .\Add-McpServer.ps1 -Name my-server -Command node -CommandArgs 'server.js' -Scope project -ProjectPath C:\my-project
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Command,
    [string[]]$CommandArgs,
    [ValidateSet('local', 'project', 'user')]
    [string]$Scope = 'local',
    [string[]]$EnvVars,
    [string]$ProjectPath,
    [switch]$Force
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

Write-DevKitHeader "Add MCP Server"

if (-not (Test-DevKitCommand 'claude')) {
    Write-DevKitError "claude CLI not found in PATH."
    exit 1
}

foreach ($kv in $EnvVars) {
    if ($kv -notmatch '^[^=\s]+=.*$') {
        Write-DevKitError "Invalid -EnvVars entry '$kv' - expected KEY=VALUE."
        exit 1
    }
}

$useProjectPath = ($Scope -eq 'local' -or $Scope -eq 'project') -and $ProjectPath
if ($ProjectPath -and $Scope -eq 'user') {
    Write-DevKitInfo "-ProjectPath is ignored for --scope user (a global scope isn't tied to a directory)."
}
if ($useProjectPath -and -not (Test-Path -LiteralPath $ProjectPath)) {
    Write-DevKitError "Project path not found: $ProjectPath"
    exit 1
}

if (-not (Confirm-DevKitDestructiveAction -Action "add MCP server '$Name' (scope: $Scope)" -Force:$Force)) {
    Write-DevKitInfo "Cancelled."
    exit 0
}

$argsArray = @('mcp', 'add', '--scope', $Scope)
foreach ($kv in $EnvVars) {
    $argsArray += '-e'
    $argsArray += $kv
}
$argsArray += $Name
$argsArray += '--'
$argsArray += $Command
foreach ($a in $CommandArgs) {
    $argsArray += $a
}

$pushedLocation = $false
if ($useProjectPath) {
    try {
        Push-Location -LiteralPath $ProjectPath
        $pushedLocation = $true
    } catch {
        Write-DevKitError "Failed to enter project path '$ProjectPath': $_"
        exit 1
    }
}

$addFailed = $false
$addErrorMessage = $null
$addExitCode = $null
try {
    & claude @argsArray
    $addExitCode = $LASTEXITCODE
} catch {
    $addFailed = $true
    $addErrorMessage = $_
} finally {
    if ($pushedLocation) { Pop-Location }
}

if ($addFailed) {
    Write-DevKitError "Failed to run 'claude mcp add': $addErrorMessage"
    exit 1
}

if ($null -ne $addExitCode -and $addExitCode -ne 0) {
    Write-DevKitError "'claude mcp add' exited with code $addExitCode."
    exit 1
}

Write-Host "  DONE: MCP server '$Name' added (scope: $Scope)." -ForegroundColor Green
exit 0
