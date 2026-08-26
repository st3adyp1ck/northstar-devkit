#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Headless core module for Northstar DevKit - loads every pure-logic
    library once and re-exports their functions as a single module.
.DESCRIPTION
    This is the contract layer the Tauri sidecar (Invoke-DevKitRpc.ps1) and
    the `devkit` CLI both sit on top of. It changes NOTHING about the
    existing libraries' logic - it only dot-sources them in the right order
    (each file already guards itself with a $global:*Loaded flag, so this
    is safe to import multiple times / from multiple runspaces in the same
    process) and re-exports every function so callers get one flat surface
    instead of having to know which file defines what.

    DevKit-WidgetCore.ps1 and DevKit-GuiCore.ps1 used to live under gui/
    alongside the WPF front-ends (DevKit-GUI.ps1, DevKit-Widget.ps1) they
    were UI-free siblings of. That WPF app was retired once this Tauri
    rebuild proved out, so the two pure-logic files moved here, next to
    their only remaining consumer.
#>

$ErrorActionPreference = 'Stop'

# Same verbatim-path ("\\?\") normalization as Invoke-DevKitRpc.ps1's header
# (see the comment there): if this module is ever imported via a verbatim
# path, $PSScriptRoot inherits the prefix and the Test-Path checks below
# reject files that exist. Strip it so the guard below only ever fails for
# files that are genuinely missing.
$script:ModuleRoot = $PSScriptRoot
if ($script:ModuleRoot.StartsWith('\\?\UNC\')) {
    $script:ModuleRoot = '\\' + $script:ModuleRoot.Substring(8)
} elseif ($script:ModuleRoot.StartsWith('\\?\')) {
    $script:ModuleRoot = $script:ModuleRoot.Substring(4)
}

$script:RepoRoot = Split-Path -Parent $script:ModuleRoot
$script:ToolsLibDir = Join-Path $script:RepoRoot 'tools\lib'

$filesToLoad = @(
    (Join-Path $script:ToolsLibDir 'DevKit-UI.ps1')
    (Join-Path $script:ToolsLibDir 'DevKit-Common.ps1')
    (Join-Path $script:ToolsLibDir 'DevKit-McpCatalog.ps1')
    (Join-Path $script:ToolsLibDir 'DevKit-McpList.ps1')
    (Join-Path $script:ToolsLibDir 'DevKit-McpAddFlow.ps1')
    (Join-Path $script:ModuleRoot 'DevKit-WidgetCore.ps1')
    (Join-Path $script:ModuleRoot 'DevKit-GuiCore.ps1')
    (Join-Path $script:ModuleRoot 'DevKit-Errors.ps1')
)

foreach ($file in $filesToLoad) {
    if (-not (Test-Path $file)) {
        throw "DevKit.Core: expected library file not found: $file"
    }
    . $file
}

Export-ModuleMember -Function * -Variable DevKitRepoRoot
$script:DevKitRepoRoot = $script:RepoRoot
$DevKitRepoRoot = $script:RepoRoot
