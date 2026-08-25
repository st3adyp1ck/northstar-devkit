#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Northstar DevKit - MCP Catalog Add Flow
.DESCRIPTION
    The interactive "register one specific MCP catalog entry" flow: pick a
    variant (remote vs local) when the entry offers more than one, ask for
    a name/scope/project, resolve whatever placeholders/directories/env
    vars that variant needs, confirm, then register it via
    Invoke-DevKitMcpAdd (lib/DevKit-McpCatalog.ps1). Extracted out of
    Add-McpServerFromCatalog.ps1 so that script's own top-level
    whole-catalog picker and Scan-McpServers.ps1's "add this one specific
    missing entry now?" prompt share exactly one implementation, instead of
    Scan-McpServers.ps1 re-implementing the picker or re-running
    Add-McpServerFromCatalog.ps1's own top-level catalog menu. Mutates real
    Claude Code MCP configuration - always confirms before running (unless
    -Force).

    This file is dot-sourced by scripts; it does not produce output when
    loaded. It defensively dot-sources DevKit-Common.ps1 and
    DevKit-McpCatalog.ps1 itself (guarded by their own scope-aware load
    guards) in case a caller dot-sources this file without loading those
    first.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
#>

# Prevent double-loading. Scope-aware on purpose: a $global: bool would
# incorrectly skip loading for a sibling script invoked via `&` in the same
# process (a distinct child scope that never inherits functions defined by
# another sibling's dot-source), leaving it with the flag set but none of
# the functions actually defined. Checking for the function itself detects
# "already loaded in a scope this one can see" instead.
if (Get-Command Add-DevKitMcpServerFromCatalogEntry -ErrorAction SilentlyContinue) { return }
$global:DevKitMcpAddFlowLoaded = $true

if (-not (Get-Command Write-DevKitHeader -ErrorAction SilentlyContinue)) {
    $commonPath = Join-Path $PSScriptRoot "DevKit-Common.ps1"
    if (Test-Path $commonPath) { . $commonPath }
}
# Same scope-aware function detection as the guard above: a $global: flag
# here could be a stale survivor of an already-destroyed sibling scope,
# which is exactly the crash this defensive load exists to prevent.
if (-not (Get-Command Get-DevKitMcpCatalog -ErrorAction SilentlyContinue)) {
    $catalogPath = Join-Path $PSScriptRoot "DevKit-McpCatalog.ps1"
    if (Test-Path $catalogPath) { . $catalogPath }
}

function ConvertTo-DevKitMcpSlug {
    <#
    .SYNOPSIS
        Turns a catalog display name (e.g. 'Jira / Atlassian') into a sane
        default 'claude mcp add' server name (e.g. 'jira-atlassian').
    #>
    param([Parameter(Mandatory = $true)][string]$Text)
    $slug = ($Text.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($slug)) { return 'mcp-server' }
    return $slug
}

function Add-DevKitMcpServerFromCatalogEntry {
    <#
    .SYNOPSIS
        Interactively walks through registering one specific MCP catalog
        entry (variant/name/scope/project/placeholders), then calls
        Invoke-DevKitMcpAdd.
    .PARAMETER Entry
        One catalog entry object as returned by Get-DevKitMcpCatalog. Must
        have at least one Variant - callers should handle zero-Variant
        entries (currently only Plaid) themselves before calling this.
    .PARAMETER Force
        Skip the confirmation prompt before registering.
    .OUTPUTS
        PSCustomObject:
          Cancelled    [bool] - user backed out at some prompt.
          Success      [bool] - only meaningful when Cancelled is $false.
          Name         [string or $null] - the name registered under.
          Scope        [string or $null] - the scope registered at.
          ErrorMessage [string or $null] - set when Success is $false.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [switch]$Force
    )

    function New-DevKitMcpAddFlowResult {
        param($Cancelled = $false, $Success = $true, $Name = $null, $Scope = $null, $ErrorMessage = $null)
        return [PSCustomObject]@{
            Cancelled    = $Cancelled
            Success      = $Success
            Name         = $Name
            Scope        = $Scope
            ErrorMessage = $ErrorMessage
        }
    }

    # ---- Pick a variant (remote vs local) if there's more than one --------

    $variant = $null
    if ($Entry.Variants.Count -eq 1) {
        $variant = $Entry.Variants[0]
    } else {
        $variantEntries = @()
        for ($i = 0; $i -lt $Entry.Variants.Count; $i++) {
            $variantEntries += @{ Key = [string]($i + 1); Label = $Entry.Variants[$i].Kind }
        }
        $variantEntries += @{ Key = '0'; Label = 'Cancel' }
        $variantChoice = (Show-DevKitInteractiveMenu -Entries $variantEntries -PromptLabel 'Select a variant').Trim()
        if ($variantChoice -eq '0' -or [string]::IsNullOrWhiteSpace($variantChoice)) {
            return New-DevKitMcpAddFlowResult -Cancelled $true
        }
        if (-not ($variantChoice -match '^\d+$') -or [int]$variantChoice -lt 1 -or [int]$variantChoice -gt $Entry.Variants.Count) {
            return New-DevKitMcpAddFlowResult -Success $false -ErrorMessage "Invalid selection: $variantChoice"
        }
        $variant = $Entry.Variants[[int]$variantChoice - 1]
    }

    # ---- Name to register under --------------------------------------------

    $defaultName = ConvertTo-DevKitMcpSlug -Text $Entry.Name
    $typedName = Read-Host "  Name to register as [$defaultName]"
    $name = if ([string]::IsNullOrWhiteSpace($typedName)) { $defaultName } else { $typedName.Trim() }

    # ---- Scope ---------------------------------------------------------------

    $scopeEntries = @(
        @{ Key = '1'; Label = 'local   - this machine + project only (default)' },
        @{ Key = '2'; Label = 'project - shared with the team via .mcp.json' },
        @{ Key = '3'; Label = 'user    - global, available in every project' },
        @{ Key = '0'; Label = 'Cancel' }
    )
    $scope = $null
    while (-not $scope) {
        $scopeChoice = (Show-DevKitInteractiveMenu -Entries $scopeEntries -PromptLabel 'Select scope').Trim().ToLowerInvariant()
        switch ($scopeChoice) {
            { $_ -in @('1', 'local', '') } { $scope = 'local' }
            { $_ -in @('2', 'project') } { $scope = 'project' }
            { $_ -in @('3', 'user') } { $scope = 'user' }
            # Escape also surfaces as '0' (Show-DevKitInteractiveMenu maps it),
            # so this is the picker's only way out besides Ctrl+C.
            '0' { return New-DevKitMcpAddFlowResult -Cancelled $true }
            default { Write-Host "  Invalid choice." -ForegroundColor Red }
        }
    }

    # ---- Project path (scope local/project only) ----------------------------

    $projectPath = $null
    if ($scope -eq 'local' -or $scope -eq 'project') {
        $projectPath = Select-DevKitProject -Prompt "Target project for MCP server '$name'"
        if (-not $projectPath) {
            return New-DevKitMcpAddFlowResult -Cancelled $true
        }
    }

    # ---- Variant-specific prompts (headers / args / directories / env) -----

    $addParams = @{
        Name        = $name
        Scope       = $scope
        ProjectPath = $projectPath
    }

    if ($variant.Transport -eq 'http') {
        $addParams.Url = $variant.Url

        $headers = @()
        if ($variant.HeaderTemplate) {
            $resolvedHeader = Resolve-DevKitMcpCatalogPlaceholder -Template $variant.HeaderTemplate -AllowBlank:([bool]$variant.HeaderOptional)
            if ($resolvedHeader) { $headers += $resolvedHeader }
        }
        $addParams.Headers = $headers
    } else {
        $addParams.Command = $variant.Command

        $resolvedArgs = @()
        foreach ($a in $variant.Args) {
            $resolvedArgs += (Resolve-DevKitMcpCatalogPlaceholder -Template $a)
        }

        if ($variant.RequiresDirectoryArg) {
            $directories = @()
            $keepAdding = $true
            while ($keepAdding) {
                $dir = Show-DevKitFolderBrowser -Description "Select a directory for '$name' to access"
                if (-not $dir) {
                    $dir = Read-Host "  Enter a directory path (browser unavailable or cancelled)"
                }
                if ($dir -and (Test-Path -LiteralPath $dir -PathType Container)) {
                    $directories += (Resolve-Path -LiteralPath $dir).Path
                } elseif ($dir) {
                    Write-Host "  Directory not found: $dir" -ForegroundColor Red
                }

                if ($directories.Count -eq 0) {
                    $again = Read-Host "  No directory added yet - try again? (Y/n)"
                    $keepAdding = ($again -ne 'n')
                } else {
                    $again = Read-Host "  Add another directory? (y/N)"
                    $keepAdding = ($again -eq 'y')
                }
            }
            if ($directories.Count -eq 0) {
                return New-DevKitMcpAddFlowResult -Success $false -ErrorMessage "At least one directory is required for '$($Entry.Name)'."
            }
            $resolvedArgs += $directories
        }
        $addParams.CommandArgs = $resolvedArgs

        $envVars = @()
        foreach ($envName in $variant.EnvVarPrompts) {
            $value = Read-Host "  Enter value for $envName"
            if ([string]::IsNullOrWhiteSpace($value)) {
                return New-DevKitMcpAddFlowResult -Success $false -ErrorMessage "$envName is required for this variant."
            }
            $envVars += "$envName=$value"
        }
        $addParams.EnvVars = $envVars
    }

    # ---- Confirm and register ------------------------------------------------

    if (-not (Confirm-DevKitDestructiveAction -Action "add MCP server '$name' (scope: $scope)" -Force:$Force)) {
        return New-DevKitMcpAddFlowResult -Cancelled $true
    }

    $addResult = Invoke-DevKitMcpAdd @addParams

    if (-not $addResult.Success) {
        return New-DevKitMcpAddFlowResult -Success $false -Name $name -Scope $scope -ErrorMessage $addResult.ErrorMessage
    }

    return New-DevKitMcpAddFlowResult -Success $true -Name $name -Scope $scope
}
