#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Add MCP Server From Catalog - Northstar DevKit
.DESCRIPTION
    Interactive picker over Get-DevKitMcpCatalog's list of known MCP
    servers (lib/DevKit-McpCatalog.ps1): browse by name, then hand off to
    Add-DevKitMcpServerFromCatalogEntry (lib/DevKit-McpAddFlow.ps1) - the
    same per-entry add flow Scan-McpServers.ps1 reuses when offering to fix
    one specific missing catalog entry - to pick a variant (remote vs
    local) when the entry offers more than one, fill in whatever that
    variant needs (scope, project, directories, env vars, header/API-key
    placeholders), and register it via Invoke-DevKitMcpAdd - the same
    helper Add-McpServer.ps1's own local/remote parameter sets use, so
    there is exactly one place in this codebase that builds a 'claude mcp
    add' argument array and invokes it. Mutates real Claude Code MCP
    configuration - always confirms before running.

    A catalog entry with zero Variants (currently only Plaid, whose MCP
    server needs a short-lived OAuth token refresh a one-time registration
    can't sustain) just prints its Description - which already contains a
    docs pointer - and exits without attempting any registration.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Force
    Skip the confirmation prompt before registering.
.EXAMPLE
    .\Add-McpServerFromCatalog.ps1
    .\Add-McpServerFromCatalog.ps1 -Force
#>
[CmdletBinding()]
param(
    [switch]$Force
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }
$McpCatalogModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-McpCatalog.ps1"
if (Test-Path $McpCatalogModule) { . $McpCatalogModule }
$McpAddFlowModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-McpAddFlow.ps1"
if (Test-Path $McpAddFlowModule) { . $McpAddFlowModule }

Write-DevKitHeader "Add MCP Server From Catalog"

if (-not (Test-DevKitCommand 'claude')) {
    Write-DevKitError "claude CLI not found in PATH."
    exit 1
}

# ---- 1. Pick a catalog entry ----------------------------------------------

$catalog = @(Get-DevKitMcpCatalog)
if ($catalog.Count -eq 0) {
    Write-DevKitError "MCP catalog is empty."
    exit 1
}

$catalogEntries = @()
for ($i = 0; $i -lt $catalog.Count; $i++) {
    $catalogEntries += @{ Key = [string]($i + 1); Label = "$($catalog[$i].Name) - $($catalog[$i].Description)" }
}
$catalogEntries += @{ Key = '0'; Label = 'Cancel' }

$catalogChoice = (Show-DevKitInteractiveMenu -Entries $catalogEntries -PromptLabel 'Select an MCP server').Trim()
if ($catalogChoice -eq '0' -or [string]::IsNullOrWhiteSpace($catalogChoice)) {
    Write-DevKitInfo "Cancelled."
    exit 0
}
if (-not ($catalogChoice -match '^\d+$') -or [int]$catalogChoice -lt 1 -or [int]$catalogChoice -gt $catalog.Count) {
    Write-DevKitError "Invalid selection: $catalogChoice"
    exit 1
}
$entry = $catalog[[int]$catalogChoice - 1]

Write-Host ""
Write-Host "  $($entry.Name)" -ForegroundColor Cyan
Write-Host "  $($entry.Description)" -ForegroundColor Gray
Write-Host ""

# ---- 2. Zero-Variant entries (e.g. Plaid): show the docs pointer and stop -

if (-not $entry.Variants -or $entry.Variants.Count -eq 0) {
    Write-DevKitInfo "No automatable registration is available for '$($entry.Name)' - see the description above for manual setup."
    exit 0
}

# ---- 3. Variant/name/scope/project/placeholder prompts, confirm, register -
#         (Add-DevKitMcpServerFromCatalogEntry, lib/DevKit-McpAddFlow.ps1 -
#         shared with Scan-McpServers.ps1's per-entry "add this now?" flow)

$result = Add-DevKitMcpServerFromCatalogEntry -Entry $entry -Force:$Force

if ($result.Cancelled) {
    Write-DevKitInfo "Cancelled."
    exit 0
}
if (-not $result.Success) {
    Write-DevKitError $result.ErrorMessage
    exit 1
}

Write-Host "  DONE: MCP server '$($result.Name)' added (scope: $($result.Scope))." -ForegroundColor Green
exit 0
