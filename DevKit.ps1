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
    3.0.0
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
    Write-Host "       Northstar DevKit v3.0.0             " -ForegroundColor Cyan
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
    Write-Host "  Development Tools:" -ForegroundColor Magenta
    Write-Host "    [1] Port Tools     - Scan and Kill"
    Write-Host "    [2] Node.js Tools  - Cache & Modules"
    Write-Host "    [3] Next.js Tools  - Build Cache"
    Write-Host "    [4] Vite Tools     - Dev Server"
    Write-Host ""
    Write-Host "  Version Control & Containers:" -ForegroundColor Magenta
    Write-Host "    [5] Git Tools      - Repo Management"
    Write-Host "    [6] Docker Tools   - Container Cleanup"
    Write-Host ""
    Write-Host "  System & Workflow:" -ForegroundColor Magenta
    Write-Host "    [7] System Tools   - PATH & Environment"
    Write-Host "    [8] Workflow       - IDE & Utils"
    Write-Host "    [9] Diagnostics    - Health Check"
    Write-Host ""
    Write-Host "  Projects & Network:" -ForegroundColor Magenta
    Write-Host "    [10] Projects      - Link, Switch, Manage"
    Write-Host "    [11] WiFi Tools    - Optimize and Scan"
    Write-Host ""
    Write-Host "    [0] Exit"
    Write-Host "    [/] Search tools"
    Write-Host ""
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
    for ($i = 0; $i -lt $found.Count; $i++) {
        Write-Host ("    [{0}] [{1}] {2} -> {3}" -f ($i + 1), $found[$i].MainMenuKey, $found[$i].ModuleName, $found[$i].Label)
    }
    Write-Host ""
    Write-Host "    [0] Cancel"
    $choice = Read-Host "Jump to"
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
    Write-Host "  [1] Set Active Project (pick / browse / link)"
    Write-Host "  [2] Clear Active Project"
    Write-Host "  [3] Manage Linked Projects (rename / pin / unlink / relink)"
    Write-Host ""
    Write-Host "  [0] Back"
    Write-Host ""
}

function Start-ProjectTools {
    while ($true) {
        Show-ProjectsMenu
        $choice = Read-Host "Select option"
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
    $mainChoice = Read-Host "Select option"
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
        '/' { Search-DevKitTools }
        '0' { exit }
        default { Write-Host "  Invalid option. Press Enter to continue." -ForegroundColor Red; Read-Host }
    }
}
