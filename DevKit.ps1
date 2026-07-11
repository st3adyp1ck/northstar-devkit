#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Northstar DevKit - Developer Toolkit
.DESCRIPTION
    A comprehensive PowerShell toolkit for developers working with Node.js,
    Next.js, Vite, Git, Docker, and more. Features port management,
    cache clearing, network optimization, and system diagnostics.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com

.VERSION
    3.1.0
.NOTES
    Requires PowerShell 5.1 or PowerShell 7+
    Run as Administrator for full network optimization features

    Ten tool-category submenus (Port/Node/Next.js/Vite/Git/Docker/System/
    Workflow/Diagnostics/WiFi Tools) are driven generically by
    Start-DevKitModuleTools (lib/DevKit-Common.ps1) reading each category's
    "_module.psd1" manifest - see e.g. ports/_module.psd1. The Main Menu and
    Projects menu below are deliberately hand-written rather than manifest-
    driven; see the note above Start-DevKitModuleTools in lib/DevKit-Common.ps1
    for why.
.LINK
    https://www.northstarcoding.com
.EXAMPLE
    .\DevKit.ps1
#>

$ScriptDir = $PSScriptRoot
. (Join-Path $ScriptDir "lib\DevKit-Common.ps1")

# Cache of the active project for this session, so Show-Header doesn't hit
# disk on every menu redraw. Invalidated by Set-/Clear-DevKitActiveProject.
$global:DevKitActiveProjectCache = $null

function Show-Header {
    param([string]$Title)
    Clear-Host
    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host "       Northstar DevKit v3.1.0             " -ForegroundColor Cyan
    Write-Host "    Developer Toolkit by northstarcoding.com" -ForegroundColor Cyan
    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host "  Menu: $Title" -ForegroundColor Cyan

    if ($null -eq $global:DevKitActiveProjectCache) {
        $global:DevKitActiveProjectCache = Get-DevKitActiveProject
    }
    $activeProject = $global:DevKitActiveProjectCache
    if ($activeProject -and -not $activeProject.Missing) {
        Write-Host "  Active Project: $($activeProject.name)  ($($activeProject.path))" -ForegroundColor Green
    } elseif ($activeProject -and $activeProject.Missing) {
        Write-Host "  Active Project: $($activeProject.name)  -- PATH MISSING (will prompt to relink)" -ForegroundColor DarkYellow
    } else {
        Write-Host "  Active Project: <none linked yet - use option [10] or any tool that needs a project>" -ForegroundColor DarkGray
    }
    Write-Host ""
}

function Show-MainMenu {
    Show-Header "Main Menu"
}

# Drives both the arrow-navigable Main Menu render and Get-DevKitSearchableCategories'
# key labels; IsHeader entries are section labels only (skipped by arrow nav).
function Get-DevKitMainMenuEntries {
    return @(
        @{ IsHeader = $true; Label = 'Development Tools:' }
        @{ Key = '1'; Label = 'Port Tools     - Scan and Kill' }
        @{ Key = '2'; Label = 'Node.js Tools  - Cache & Modules' }
        @{ Key = '3'; Label = 'Next.js Tools  - Build Cache' }
        @{ Key = '4'; Label = 'Vite Tools     - Dev Server' }
        @{ IsHeader = $true; Label = '' }
        @{ IsHeader = $true; Label = 'Version Control & Containers:' }
        @{ Key = '5'; Label = 'Git Tools      - Repo Management' }
        @{ Key = '6'; Label = 'Docker Tools   - Container Cleanup' }
        @{ IsHeader = $true; Label = '' }
        @{ IsHeader = $true; Label = 'System & Workflow:' }
        @{ Key = '7'; Label = 'System Tools   - PATH & Environment' }
        @{ Key = '8'; Label = 'Workflow       - IDE & Utils' }
        @{ Key = '9'; Label = 'Diagnostics    - Health Check' }
        @{ IsHeader = $true; Label = '' }
        @{ IsHeader = $true; Label = 'Maintenance & Agents:' }
        @{ Key = '12'; Label = 'Maintenance    - Cleanup, Repair, Tuning' }
        @{ Key = '13'; Label = 'Agents & MCP   - AI CLI & MCP Servers' }
        @{ IsHeader = $true; Label = '' }
        @{ IsHeader = $true; Label = 'Projects & Network:' }
        @{ Key = '10'; Label = 'Projects       - Link, Switch, Manage' }
        @{ Key = '11'; Label = 'WiFi Tools     - Optimize and Scan' }
        @{ IsHeader = $true; Label = '' }
        @{ Key = '/'; Label = 'Search tools' }
        @{ Key = '0'; Label = 'Exit' }
    )
}

# Maps each manifest-backed category to its main-menu number, so search
# results can be labeled and jumped to consistently with Show-MainMenu above.
# This mirrors Show-MainMenu's own numbering rather than deriving it, since
# Show-MainMenu is intentionally hand-written (see the architecture note at
# the top of this file) - there is no single source of truth to read this
# from without re-introducing the dynamic-main-menu complexity that note
# explains was deliberately avoided.
function Get-DevKitSearchableCategories {
    return @(
        @{ Folder = 'ports'; MainMenuKey = '1' }
        @{ Folder = 'node'; MainMenuKey = '2' }
        @{ Folder = 'nextjs'; MainMenuKey = '3' }
        @{ Folder = 'vite'; MainMenuKey = '4' }
        @{ Folder = 'git'; MainMenuKey = '5' }
        @{ Folder = 'docker'; MainMenuKey = '6' }
        @{ Folder = 'system'; MainMenuKey = '7' }
        @{ Folder = 'workflow'; MainMenuKey = '8' }
        @{ Folder = 'diagnostics'; MainMenuKey = '9' }
        @{ Folder = 'maintenance'; MainMenuKey = '12' }
        @{ Folder = 'agents'; MainMenuKey = '13' }
        @{ Folder = 'wifi'; MainMenuKey = '11' }
    )
}

function Search-DevKitTools {
    <#
    .SYNOPSIS
        Searches every manifest-backed category's item labels and jumps
        straight to a match, instead of drilling down through submenus by
        number when you already know roughly what you're looking for.
    #>
    Clear-Host
    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host "  Search Tools" -ForegroundColor Cyan
    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host ""
    $keyword = Read-Host "Search (e.g. 'port', 'cache', 'reinstall')"
    if ([string]::IsNullOrWhiteSpace($keyword)) { return }

    $found = @()
    foreach ($cat in (Get-DevKitSearchableCategories)) {
        $folderPath = Join-Path $ScriptDir $cat.Folder
        try {
            $module = Get-DevKitModule -FolderPath $folderPath
        } catch {
            continue
        }
        foreach ($item in $module.Items) {
            $haystack = "$($module.Name) $($item.Label)"
            if ($haystack -match [regex]::Escape($keyword)) {
                $found += [PSCustomObject]@{
                    ModuleName  = $module.Name
                    MainMenuKey = $cat.MainMenuKey
                    Label       = $item.Label
                    FolderPath  = $folderPath
                    Item        = $item
                }
            }
        }
    }

    if ($found.Count -eq 0) {
        Write-Host "  No matches for '$keyword'." -ForegroundColor Yellow
        Read-Host "Press Enter to continue"
        return
    }

    Write-Host ""
    Write-Host "  Results for '$keyword':" -ForegroundColor Magenta
    $entries = @()
    for ($i = 0; $i -lt $found.Count; $i++) {
        $entries += @{ Key = "$($i + 1)"; Label = ("[{0}] {1} -> {2}" -f $found[$i].MainMenuKey, $found[$i].ModuleName, $found[$i].Label) }
    }
    $entries += @{ Key = '0'; Label = 'Cancel' }
    $choice = Show-DevKitInteractiveMenu -Entries $entries -PromptLabel 'Jump to'
    if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $found.Count) {
        $picked = $found[[int]$choice - 1]
        Clear-Host
        Invoke-DevKitTool -FolderPath $picked.FolderPath -Item $picked.Item
        Read-Host "Press Enter to continue"
    }
}

# ==================== PROJECTS ====================
# Hand-written rather than manifest-driven: this menu manages the picker
# system itself (Select-DevKitProject / the linked-projects registry), it
# doesn't dispatch a chosen project path to an external leaf script the way
# every other category does, so it doesn't fit the generic Items/Script
# shape Start-DevKitModuleTools expects.
function Show-ProjectsMenu {
    Show-Header "Projects"
}

function Start-ProjectTools {
    while ($true) {
        Show-ProjectsMenu
        $entries = @(
            @{ Key = '1'; Label = 'Set Active Project (pick / browse / link)' }
            @{ Key = '2'; Label = 'Clear Active Project' }
            @{ Key = '3'; Label = 'Manage Linked Projects (rename / pin / unlink / relink)' }
            @{ Key = '0'; Label = 'Back' }
        )
        $choice = Show-DevKitInteractiveMenu -Entries $entries -PromptLabel 'Select option'
        switch ($choice) {
            '1' {
                Clear-Host
                $picked = Select-DevKitProject -Prompt "Set Active Project" -ForceReprompt
                if ($picked) {
                    Write-Host "  DONE: Active project set." -ForegroundColor Green
                } else {
                    Write-Host "  Cancelled -- no project selected." -ForegroundColor Yellow
                }
                Read-Host "Press Enter to continue"
            }
            '2' {
                Clear-Host
                Clear-DevKitActiveProject
                Write-Host "  DONE: Active project cleared." -ForegroundColor Green
                Read-Host "Press Enter to continue"
            }
            '3' {
                Invoke-DevKitManageProjects
            }
            '0' { return }
            default { Write-Host "  Invalid option. Press Enter to continue." -ForegroundColor Red; Read-Host }
        }
    }
}

# Entry Point
while ($true) {
    Show-MainMenu
    $mainChoice = Show-DevKitInteractiveMenu -Entries (Get-DevKitMainMenuEntries) -PromptLabel 'Select option'
    switch ($mainChoice.Trim()) {
        '1' { Start-DevKitModuleTools -FolderPath (Join-Path $ScriptDir "ports") }
        '2' { Start-DevKitModuleTools -FolderPath (Join-Path $ScriptDir "node") }
        '3' { Start-DevKitModuleTools -FolderPath (Join-Path $ScriptDir "nextjs") }
        '4' { Start-DevKitModuleTools -FolderPath (Join-Path $ScriptDir "vite") }
        '5' { Start-DevKitModuleTools -FolderPath (Join-Path $ScriptDir "git") }
        '6' { Start-DevKitModuleTools -FolderPath (Join-Path $ScriptDir "docker") }
        '7' { Start-DevKitModuleTools -FolderPath (Join-Path $ScriptDir "system") }
        '8' { Start-DevKitModuleTools -FolderPath (Join-Path $ScriptDir "workflow") }
        '9' { Start-DevKitModuleTools -FolderPath (Join-Path $ScriptDir "diagnostics") }
        '10' { Start-ProjectTools }
        '11' { Start-DevKitModuleTools -FolderPath (Join-Path $ScriptDir "wifi") }
        '12' { Start-DevKitModuleTools -FolderPath (Join-Path $ScriptDir "maintenance") }
        '13' { Start-DevKitModuleTools -FolderPath (Join-Path $ScriptDir "agents") }
        '/' { Search-DevKitTools }
        '0' { exit }
        default { Write-Host "  Invalid option. Press Enter to continue." -ForegroundColor Red; Read-Host }
    }
}
