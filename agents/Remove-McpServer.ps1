#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Remove MCP Server - Northstar DevKit
.DESCRIPTION
    Removes an MCP server from Claude Code via 'claude mcp remove'. Mutates
    real Claude Code MCP configuration - always confirms before running.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Name
    Name of the MCP server to remove.
.PARAMETER ProjectPath
    Optional project directory to target its project/local-scope config.
    claude reads project/local scope from the current directory, so this
    script Push-Location's into it first.
.PARAMETER Force
    Skip the confirmation prompt.
.EXAMPLE
    .\Remove-McpServer.ps1 -Name my-server
    .\Remove-McpServer.ps1 -Name my-server -ProjectPath C:\my-project -Force
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Name,
    [string]$ProjectPath,
    [switch]$Force
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

Write-DevKitHeader "Remove MCP Server"

if (-not (Test-DevKitCommand 'claude')) {
    Write-DevKitError "claude CLI not found in PATH."
    exit 1
}

if ($ProjectPath -and -not (Test-Path -LiteralPath $ProjectPath)) {
    Write-DevKitError "Project path not found: $ProjectPath"
    exit 1
}

if (-not (Confirm-DevKitDestructiveAction -Action "remove MCP server '$Name'" -Force:$Force)) {
    Write-DevKitInfo "Cancelled."
    exit 0
}

$pushedLocation = $false
if ($ProjectPath) {
    try {
        Push-Location -LiteralPath $ProjectPath
        $pushedLocation = $true
    } catch {
        Write-DevKitError "Failed to enter project path '$ProjectPath': $_"
        exit 1
    }
}

$removeFailed = $false
$removeErrorMessage = $null
$removeExitCode = $null
$output = $null
try {
    $output = claude mcp remove $Name 2>&1
    $removeExitCode = $LASTEXITCODE
} catch {
    $removeFailed = $true
    $removeErrorMessage = $_
} finally {
    if ($pushedLocation) { Pop-Location }
}

if ($output) {
    @($output) | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
}

if ($removeFailed) {
    Write-DevKitError "Failed to run 'claude mcp remove': $removeErrorMessage"
    exit 1
}

if ($null -ne $removeExitCode -and $removeExitCode -ne 0) {
    $outputText = (@($output) | Out-String)
    # 'claude mcp remove' exits non-zero both for "server not found" and for
    # other real failures - surface its own message rather than guessing.
    if ($outputText -match 'not found|No MCP server') {
        Write-DevKitError "MCP server '$Name' was not found."
    } else {
        Write-DevKitError "'claude mcp remove' exited with code $removeExitCode."
    }
    exit 1
}

Write-Host "  DONE: MCP server '$Name' removed." -ForegroundColor Green
exit 0
