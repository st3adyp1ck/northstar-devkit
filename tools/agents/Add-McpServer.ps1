#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Add MCP Server - Northstar DevKit
.DESCRIPTION
    Registers an MCP server with Claude Code via 'claude mcp add', at the
    requested scope (local/project/user). Supports two parameter sets: a
    local (stdio) command, or a remote http-transport server. Mutates real
    Claude Code MCP configuration - always confirms before running.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Name
    Name to register the MCP server under.
.PARAMETER Command
    (Local parameter set) the command to run for this (stdio) MCP server.
.PARAMETER CommandArgs
    (Local parameter set) arguments passed through to Command, in order.
.PARAMETER EnvVars
    (Local parameter set) zero or more KEY=VALUE entries passed as
    '-e KEY=VALUE' to claude.
.PARAMETER Transport
    (Remote parameter set) transport for a remote MCP server. Only 'http'
    is currently supported.
.PARAMETER Url
    (Remote parameter set) the http MCP endpoint URL.
.PARAMETER Headers
    (Remote parameter set) zero or more 'Key: Value' entries passed as
    '-H "Key: Value"' to claude, e.g. 'Authorization: Bearer <token>'.
.PARAMETER Scope
    'local' (this machine+project only, default), 'project' (shared via
    .mcp.json), or 'user' (global, all projects).
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
    .\Add-McpServer.ps1 -Name github -Transport http -Url https://api.githubcopilot.com/mcp -Headers 'Authorization: Bearer ghp_xxx'
#>
[CmdletBinding(DefaultParameterSetName = 'Local')]
param(
    [Parameter(Mandatory = $true)][string]$Name,

    [Parameter(Mandatory = $true, ParameterSetName = 'Local')][string]$Command,
    [Parameter(ParameterSetName = 'Local')][string[]]$CommandArgs,
    [Parameter(ParameterSetName = 'Local')][string[]]$EnvVars,

    [Parameter(Mandatory = $true, ParameterSetName = 'Remote')]
    [ValidateSet('http')]
    [string]$Transport,
    [Parameter(Mandatory = $true, ParameterSetName = 'Remote')][string]$Url,
    [Parameter(ParameterSetName = 'Remote')][string[]]$Headers,

    [ValidateSet('local', 'project', 'user')]
    [string]$Scope = 'local',
    [string]$ProjectPath,
    [switch]$Force
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }
$McpCatalogModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-McpCatalog.ps1"
if (Test-Path $McpCatalogModule) { . $McpCatalogModule }

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

foreach ($h in $Headers) {
    if ($h -notmatch '^[^:\s]+:.*$') {
        Write-DevKitError "Invalid -Headers entry '$h' - expected 'Key: Value'."
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

$effectiveProjectPath = if ($useProjectPath) { $ProjectPath } else { $null }

if ($PSCmdlet.ParameterSetName -eq 'Remote') {
    $result = Invoke-DevKitMcpAdd -Name $Name -Scope $Scope -ProjectPath $effectiveProjectPath -Url $Url -Headers $Headers
} else {
    $result = Invoke-DevKitMcpAdd -Name $Name -Scope $Scope -ProjectPath $effectiveProjectPath -Command $Command -CommandArgs $CommandArgs -EnvVars $EnvVars
}

if (-not $result.Success) {
    Write-DevKitError $result.ErrorMessage
    exit 1
}

Write-Host "  DONE: MCP server '$Name' added (scope: $Scope)." -ForegroundColor Green
exit 0
