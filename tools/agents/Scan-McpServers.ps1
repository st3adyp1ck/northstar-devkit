#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Scan MCP Setup - Northstar DevKit
.DESCRIPTION
    Checks that MCP servers from the built-in catalog
    (lib/DevKit-McpCatalog.ps1) are actually configured, both
    globally/user-scope and (when a project context is resolved) at
    project/local scope, by reusing the same neutral-vs-project
    'claude mcp list' diff logic as Get-McpServers.ps1
    (lib/DevKit-McpList.ps1) - so there is exactly one implementation of
    that diff. The scan itself is read-only.

    Configured server names are cross-referenced against each catalog
    entry's default slug (ConvertTo-DevKitMcpSlug, in
    lib/DevKit-McpAddFlow.ps1) - a name-based heuristic, since this module
    never reads Claude Code's internal JSON config directly. If you
    registered a catalog server under a different name than its default,
    it will show here as still missing.

    For each missing catalog entry that has an automatable registration
    (Plaid is skipped - it has zero Variants and nothing to auto-register;
    it's just noted informationally), this interactively asks whether to
    add it now. A 'yes' reuses Add-McpServerFromCatalog.ps1's own per-entry
    add flow (Add-DevKitMcpServerFromCatalogEntry, in
    lib/DevKit-McpAddFlow.ps1) rather than re-implementing the catalog
    picker, so there is exactly one implementation of "walk through prompts
    and register one catalog entry". That flow always confirms before
    mutating real Claude Code MCP configuration (unless -Force).

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Force
    Skip the confirmation prompt when adding a missing server.
.EXAMPLE
    .\Scan-McpServers.ps1
    .\Scan-McpServers.ps1 -Force
#>
[CmdletBinding()]
param(
    [switch]$Force
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }
$McpCatalogModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-McpCatalog.ps1"
if (Test-Path $McpCatalogModule) { . $McpCatalogModule }
$McpListModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-McpList.ps1"
if (Test-Path $McpListModule) { . $McpListModule }
$McpAddFlowModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-McpAddFlow.ps1"
if (Test-Path $McpAddFlowModule) { . $McpAddFlowModule }

Write-DevKitHeader "Scan MCP Setup"

if (-not (Test-DevKitCommand 'claude')) {
    Write-DevKitError "claude CLI not found in PATH."
    exit 1
}

# ---- 1. Resolve project context (read-only; never prompts/mutates) --------
# Get-DevKitActiveProject is read-only and never prompts - this is a report
# tool (until a user explicitly opts into adding something in step 4), so
# Select-DevKitProject (which can mutate the active project) must never be
# called here.

$activeProject = Get-DevKitActiveProject
$projectPath = $null
if (-not $activeProject) {
    Write-DevKitInfo "No active project is set. Scanning global/user scope only."
} elseif ($activeProject.Missing) {
    Write-DevKitInfo "Active project '$($activeProject.name)' points to a path that no longer exists ($($activeProject.path)). Scanning global/user scope only."
} else {
    $projectPath = $activeProject.path
}

# ---- 2. Gather configured server names, per scope --------------------------

$globalNames = @()
$projectNames = @()

if ($projectPath) {
    Write-DevKitInfo "Scanning global/user scope and project scope ('$projectPath')..."
    Write-Host ""
    $diff = Get-DevKitMcpScopeDiff -ProjectPath $projectPath
    if (-not $diff.Success) {
        Write-DevKitError $diff.ErrorMessage
        exit 1
    }
    $globalNames = @($diff.UserScope.Keys)
    $projectNames = @($diff.ProjectScope.Keys)
} else {
    Write-DevKitInfo "Scanning global/user scope..."
    Write-Host ""
    $neutralResult = Invoke-DevKitMcpList -Path $env:TEMP
    if (-not $neutralResult.Success) {
        Write-DevKitError $neutralResult.ErrorMessage
        exit 1
    }
    $globalNames = @((ConvertTo-DevKitMcpEntryMap -Output $neutralResult.Output).Keys)
}

# ---- 3. Cross-reference against the catalog ---------------------------------

$catalog = @(Get-DevKitMcpCatalog)
if ($catalog.Count -eq 0) {
    Write-DevKitError "MCP catalog is empty."
    exit 1
}

function Get-DevKitMcpScanRows {
    param([string[]]$ConfiguredNames)
    $rows = @()
    foreach ($catEntry in $catalog) {
        $slug = ConvertTo-DevKitMcpSlug -Text $catEntry.Name
        $isConfigured = [bool]($ConfiguredNames | Where-Object { $_.ToLowerInvariant() -eq $slug })
        $rows += [PSCustomObject]@{
            Entry      = $catEntry
            Slug       = $slug
            Configured = $isConfigured
        }
    }
    return $rows
}

function Write-DevKitMcpScanReport {
    param([string]$Title, [array]$Rows)
    Write-Host "  $Title" -ForegroundColor Magenta
    foreach ($row in $Rows) {
        if ($row.Configured) {
            Write-Host ("    [x] {0}" -f $row.Entry.Name) -ForegroundColor Green
        } elseif ($row.Entry.Variants.Count -eq 0) {
            Write-Host ("    [ ] {0}  (no automatable registration - informational only)" -f $row.Entry.Name) -ForegroundColor Gray
        } else {
            Write-Host ("    [ ] {0}  MISSING" -f $row.Entry.Name) -ForegroundColor DarkYellow
        }
    }
    Write-Host ""
}

$globalRows = Get-DevKitMcpScanRows -ConfiguredNames $globalNames
Write-DevKitMcpScanReport -Title "Global / user scope:" -Rows $globalRows

$projectRows = @()
if ($projectPath) {
    $projectRows = Get-DevKitMcpScanRows -ConfiguredNames $projectNames
    Write-DevKitMcpScanReport -Title "Project / local scope ('$projectPath'):" -Rows $projectRows
}

# ---- 4. Offer to add missing entries, one at a time -------------------------

$missingRows = @($globalRows | Where-Object { -not $_.Configured -and $_.Entry.Variants.Count -gt 0 })
$missingRows += @($projectRows | Where-Object { -not $_.Configured -and $_.Entry.Variants.Count -gt 0 })

# De-dupe by catalog entry Name in case the same entry is missing at both
# scopes - only ask about each catalog entry once per run.
$askedNames = @{}
$toOffer = @()
foreach ($row in $missingRows) {
    if (-not $askedNames.ContainsKey($row.Entry.Name)) {
        $askedNames[$row.Entry.Name] = $true
        $toOffer += $row.Entry
    }
}

if ($toOffer.Count -eq 0) {
    Write-DevKitInfo "Nothing to add - every catalog entry with an automatable registration is already configured."
    exit 0
}

Write-Host "  Missing catalog entries with an automatable registration:" -ForegroundColor Cyan
Write-Host ""

foreach ($entry in $toOffer) {
    $answer = Read-Host "  Add '$($entry.Name)' now? (y/N)"
    if ($answer -ne 'y') { continue }

    $result = Add-DevKitMcpServerFromCatalogEntry -Entry $entry -Force:$Force
    if ($result.Cancelled) {
        Write-DevKitInfo "Cancelled '$($entry.Name)'."
        continue
    }
    if (-not $result.Success) {
        Write-DevKitError $result.ErrorMessage
        continue
    }
    Write-Host "  DONE: MCP server '$($result.Name)' added (scope: $($result.Scope))." -ForegroundColor Green
}

exit 0
