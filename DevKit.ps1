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
    Write-Host "  Menu: $Title" -ForegroundColor Yellow

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
    Write-Host ""
}

# ==================== PORT TOOLS ====================
function Show-PortMenu {
    Show-Header "Port Tools"
    Write-Host "  [1] Scan Common Dev Ports"
    Write-Host "  [2] Scan Specific Port (Read-Only)"
    Write-Host "  [3] Kill Process by PID"
    Write-Host "  [4] Kill All Node Processes"
    Write-Host "  [5] Kill Process by Port Number (Force, No Confirm)"
    Write-Host "  [6] Kill Process by Port Number (With Confirmation)"
    Write-Host ""
    Write-Host "  [0] Back"
    Write-Host ""
}

function Start-PortTools {
    while ($true) {
        Show-PortMenu
        $choice = Read-Host "Select option"
        switch ($choice) {
            '1' {
                Clear-Host
                $scriptPath = Join-Path (Join-Path $ScriptDir "ports") "Scan-Ports.ps1"
                if (Test-Path $scriptPath) { & $scriptPath } else { Write-Host "  ERROR: Script not found: $scriptPath" -ForegroundColor Red }
                Read-Host "Press Enter to continue"
            }
            '2' {
                Clear-Host
                $port = Read-Host "Enter port number"
                if ($port -match '^\d+$') {
                    $scriptPath = Join-Path (Join-Path $ScriptDir "ports") "Kill-Port.ps1"
                    if (Test-Path $scriptPath) { & $scriptPath -Port ([int]$port) -InfoOnly } else { Write-Host "  ERROR: Script not found: $scriptPath" -ForegroundColor Red }
                } else {
                    Write-Host "  ERROR: Invalid port number." -ForegroundColor Red
                }
                Read-Host "Press Enter to continue"
            }
            '3' {
                Clear-Host
                $pidInput = Read-Host "Enter PID to kill"
                if ($pidInput -match '^\d+$') {
                    $scriptPath = Join-Path (Join-Path $ScriptDir "ports") "Kill-Port.ps1"
                    if (Test-Path $scriptPath) { & $scriptPath -ProcessId ([int]$pidInput) } else { Write-Host "  ERROR: Script not found: $scriptPath" -ForegroundColor Red }
                } else {
                    Write-Host "  ERROR: Invalid PID." -ForegroundColor Red
                }
                Read-Host "Press Enter to continue"
            }
            '4' {
                Clear-Host
                $scriptPath = Join-Path (Join-Path $ScriptDir "ports") "Kill-AllNode.ps1"
                if (Test-Path $scriptPath) { & $scriptPath } else { Write-Host "  ERROR: Script not found: $scriptPath" -ForegroundColor Red }
                Read-Host "Press Enter to continue"
            }
            '5' {
                Clear-Host
                $port = Read-Host "Enter port number"
                if ($port -match '^\d+$') {
                    $scriptPath = Join-Path (Join-Path $ScriptDir "ports") "Kill-Port.ps1"
                    if (Test-Path $scriptPath) { & $scriptPath -Port ([int]$port) -Force } else { Write-Host "  ERROR: Script not found: $scriptPath" -ForegroundColor Red }
                } else {
                    Write-Host "  ERROR: Invalid port number." -ForegroundColor Red
                }
                Read-Host "Press Enter to continue"
            }
            '6' {
                Clear-Host
                $port = Read-Host "Enter port number"
                if ($port -match '^\d+$') {
                    $scriptPath = Join-Path (Join-Path $ScriptDir "ports") "Kill-Port.ps1"
                    if (Test-Path $scriptPath) { & $scriptPath -Port ([int]$port) } else { Write-Host "  ERROR: Script not found: $scriptPath" -ForegroundColor Red }
                } else {
                    Write-Host "  ERROR: Invalid port number." -ForegroundColor Red
                }
                Read-Host "Press Enter to continue"
            }
            '0' { return }
            default { Write-Host "  Invalid option. Press Enter to continue." -ForegroundColor Red; Read-Host }
        }
    }
}

# ==================== NODE TOOLS ====================
function Show-NodeMenu {
    Show-Header "Node.js Tools"
    Write-Host "  [1] Clear NPM Cache"
    Write-Host "  [2] Delete node_modules"
    Write-Host "  [3] Delete node_modules + Lock + Reinstall"
    Write-Host "  [4] Check NPM Cache Size"
    Write-Host ""
    Write-Host "  [0] Back"
    Write-Host ""
}

function Start-NodeTools {
    while ($true) {
        Show-NodeMenu
        $choice = Read-Host "Select option"
        switch ($choice) {
            '1' {
                Clear-Host
                $scriptPath = Join-Path (Join-Path $ScriptDir "node") "Clear-NpmCache.ps1"
                if (Test-Path $scriptPath) { & $scriptPath } else { Write-Host "  ERROR: Script not found: $scriptPath" -ForegroundColor Red }
                Read-Host "Press Enter to continue"
            }
            { $_ -eq '2' -or $_ -eq '2p' } {
                Clear-Host
                $targetPath = Select-DevKitProject -Prompt "Delete node_modules" -ForceReprompt:($choice -eq '2p')
                if ($null -eq $targetPath) {
                    Write-Host "  Cancelled -- no project selected." -ForegroundColor Yellow
                } else {
                    $scriptPath = Join-Path (Join-Path $ScriptDir "node") "Remove-NodeModules.ps1"
                    if (Test-Path $scriptPath) { & $scriptPath -Path $targetPath } else { Write-Host "  ERROR: Script not found: $scriptPath" -ForegroundColor Red }
                }
                Read-Host "Press Enter to continue"
            }
            { $_ -eq '3' -or $_ -eq '3p' } {
                Clear-Host
                $targetPath = Select-DevKitProject -Prompt "Delete node_modules + Lock + Reinstall" -ForceReprompt:($choice -eq '3p')
                if ($null -eq $targetPath) {
                    Write-Host "  Cancelled -- no project selected." -ForegroundColor Yellow
                } else {
                    $scriptPath = Join-Path (Join-Path $ScriptDir "node") "Nuke-And-Reinstall.ps1"
                    if (Test-Path $scriptPath) { & $scriptPath -Path $targetPath } else { Write-Host "  ERROR: Script not found: $scriptPath" -ForegroundColor Red }
                }
                Read-Host "Press Enter to continue"
            }
            '4' {
                Clear-Host
                $scriptPath = Join-Path (Join-Path $ScriptDir "node") "Check-NpmCacheSize.ps1"
                if (Test-Path $scriptPath) { & $scriptPath } else { Write-Host "  ERROR: Script not found: $scriptPath" -ForegroundColor Red }
                Read-Host "Press Enter to continue"
            }
            '0' { return }
            default { Write-Host "  Invalid option. Press Enter to continue." -ForegroundColor Red; Read-Host }
        }
    }
}

# ==================== NEXT.JS TOOLS ====================
function Show-NextJsMenu {
    Show-Header "Next.js Tools"
    Write-Host "  [1] Clear .next Build Cache"
    Write-Host "  [2] Clear Turbopack Cache"
    Write-Host "  [3] Full Clean (.next + node_modules + reinstall)"
    Write-Host "  [4] Dev Server (Fresh Start)"
    Write-Host ""
    Write-Host "  [0] Back"
    Write-Host ""
}

function Start-NextJsTools {
    while ($true) {
        Show-NextJsMenu
        $choice = Read-Host "Select option"
        switch ($choice) {
            { $_ -eq '1' -or $_ -eq '1p' } {
                Clear-Host
                $targetPath = Select-DevKitProject -Prompt "Clear .next Build Cache" -ForceReprompt:($choice -eq '1p')
                if ($null -eq $targetPath) {
                    Write-Host "  Cancelled -- no project selected." -ForegroundColor Yellow
                } else {
                    $scriptPath = Join-Path (Join-Path $ScriptDir "nextjs") "Clear-NextCache.ps1"
                    if (Test-Path $scriptPath) { & $scriptPath -Path $targetPath } else { Write-Host "  ERROR: Script not found: $scriptPath" -ForegroundColor Red }
                }
                Read-Host "Press Enter to continue"
            }
            { $_ -eq '2' -or $_ -eq '2p' } {
                Clear-Host
                $targetPath = Select-DevKitProject -Prompt "Clear Turbopack Cache" -ForceReprompt:($choice -eq '2p')
                if ($null -eq $targetPath) {
                    Write-Host "  Cancelled -- no project selected." -ForegroundColor Yellow
                } else {
                    $scriptPath = Join-Path (Join-Path $ScriptDir "nextjs") "Clear-TurboCache.ps1"
                    if (Test-Path $scriptPath) { & $scriptPath -Path $targetPath } else { Write-Host "  ERROR: Script not found: $scriptPath" -ForegroundColor Red }
                }
                Read-Host "Press Enter to continue"
            }
            { $_ -eq '3' -or $_ -eq '3p' } {
                Clear-Host
                $targetPath = Select-DevKitProject -Prompt "Full Clean (.next + node_modules + reinstall)" -ForceReprompt:($choice -eq '3p')
                if ($null -eq $targetPath) {
                    Write-Host "  Cancelled -- no project selected." -ForegroundColor Yellow
                } else {
                    $scriptPath = Join-Path (Join-Path $ScriptDir "nextjs") "Next-FullClean.ps1"
                    if (Test-Path $scriptPath) { & $scriptPath -Path $targetPath } else { Write-Host "  ERROR: Script not found: $scriptPath" -ForegroundColor Red }
                }
                Read-Host "Press Enter to continue"
            }
            { $_ -eq '4' -or $_ -eq '4p' } {
                Clear-Host
                $targetPath = Select-DevKitProject -Prompt "Next.js Dev Server (Fresh Start)" -ForceReprompt:($choice -eq '4p')
                if ($null -eq $targetPath) {
                    Write-Host "  Cancelled -- no project selected." -ForegroundColor Yellow
                } else {
                    $scriptPath = Join-Path (Join-Path $ScriptDir "nextjs") "Next-DevFresh.ps1"
                    if (Test-Path $scriptPath) {
                        $turbo = Read-Host "Clear Turbopack cache too? (y/n)"
                        $port = Read-Host "Port (press Enter for default)"
                        $devArgs = @{ Path = $targetPath }
                        if ($turbo -eq 'y') { $devArgs['Turbo'] = $true }
                        if ($port -match '^\d+$') { $devArgs['Port'] = [int]$port }
                        & $scriptPath @devArgs
                    } else {
                        Write-Host "  ERROR: Script not found: $scriptPath" -ForegroundColor Red
                    }
                }
                Read-Host "Press Enter to continue"
            }
            '0' { return }
            default { Write-Host "  Invalid option. Press Enter to continue." -ForegroundColor Red; Read-Host }
        }
    }
}

# ==================== VITE TOOLS ====================
function Show-ViteMenu {
    Show-Header "Vite Tools"
    Write-Host "  [1] Vite Dev Server (Fresh Start)"
    Write-Host "  [2] Build and Preview"
    Write-Host ""
    Write-Host "  [0] Back"
    Write-Host ""
}

function Start-ViteTools {
    while ($true) {
        Show-ViteMenu
        $choice = Read-Host "Select option"
        switch ($choice) {
            { $_ -eq '1' -or $_ -eq '1p' } {
                Clear-Host
                $targetPath = Select-DevKitProject -Prompt "Vite Dev Server (Fresh Start)" -ForceReprompt:($choice -eq '1p')
                if ($null -eq $targetPath) {
                    Write-Host "  Cancelled -- no project selected." -ForegroundColor Yellow
                } else {
                    $scriptPath = Join-Path (Join-Path $ScriptDir "vite") "Vite-DevFresh.ps1"
                    if (Test-Path $scriptPath) { & $scriptPath -Path $targetPath } else { Write-Host "  ERROR: Script not found: $scriptPath" -ForegroundColor Red }
                }
                Read-Host "Press Enter to continue"
            }
            { $_ -eq '2' -or $_ -eq '2p' } {
                Clear-Host
                $targetPath = Select-DevKitProject -Prompt "Build and Preview" -ForceReprompt:($choice -eq '2p')
                if ($null -eq $targetPath) {
                    Write-Host "  Cancelled -- no project selected." -ForegroundColor Yellow
                } else {
                    $scriptPath = Join-Path (Join-Path $ScriptDir "vite") "Vite-PreviewBuild.ps1"
                    if (Test-Path $scriptPath) { & $scriptPath -Path $targetPath } else { Write-Host "  ERROR: Script not found: $scriptPath" -ForegroundColor Red }
                }
                Read-Host "Press Enter to continue"
            }
            '0' { return }
            default { Write-Host "  Invalid option. Press Enter to continue." -ForegroundColor Red; Read-Host }
        }
    }
}

# ==================== GIT TOOLS ====================
function Show-GitMenu {
    Show-Header "Git Tools"
    Write-Host "  [1] Git Cleanup (prune, gc, etc.)"
    Write-Host "  [2] Git Status All (scan repos)"
    Write-Host "  [3] Sync Fork with Upstream"
    Write-Host ""
    Write-Host "  [0] Back"
    Write-Host ""
}

function Start-GitTools {
    while ($true) {
        Show-GitMenu
        $choice = Read-Host "Select option"
        switch ($choice) {
            { $_ -eq '1' -or $_ -eq '1p' } {
                Clear-Host
                $targetPath = Select-DevKitProject -Prompt "Git Cleanup" -ForceReprompt:($choice -eq '1p')
                if ($null -eq $targetPath) {
                    Write-Host "  Cancelled -- no project selected." -ForegroundColor Yellow
                } else {
                    $scriptPath = Join-Path (Join-Path $ScriptDir "git") "Git-Cleanup.ps1"
                    if (Test-Path $scriptPath) { & $scriptPath -Path $targetPath } else { Write-Host "  ERROR: Script not found: $scriptPath" -ForegroundColor Red }
                }
                Read-Host "Press Enter to continue"
            }
            { $_ -eq '2' -or $_ -eq '2p' } {
                Clear-Host
                $targetPath = Select-DevKitProject -Prompt "Git Status All (scan root)" -ForceReprompt:($choice -eq '2p')
                if ($null -eq $targetPath) {
                    Write-Host "  Cancelled -- no scan root selected." -ForegroundColor Yellow
                } else {
                    $scriptPath = Join-Path (Join-Path $ScriptDir "git") "Git-StatusAll.ps1"
                    if (Test-Path $scriptPath) { & $scriptPath -Path $targetPath } else { Write-Host "  ERROR: Script not found: $scriptPath" -ForegroundColor Red }
                }
                Read-Host "Press Enter to continue"
            }
            { $_ -eq '3' -or $_ -eq '3p' } {
                Clear-Host
                $targetPath = Select-DevKitProject -Prompt "Sync Fork with Upstream" -ForceReprompt:($choice -eq '3p')
                if ($null -eq $targetPath) {
                    Write-Host "  Cancelled -- no project selected." -ForegroundColor Yellow
                } else {
                    $scriptPath = Join-Path (Join-Path $ScriptDir "git") "Git-SyncFork.ps1"
                    if (Test-Path $scriptPath) { & $scriptPath -Path $targetPath } else { Write-Host "  ERROR: Script not found: $scriptPath" -ForegroundColor Red }
                }
                Read-Host "Press Enter to continue"
            }
            '0' { return }
            default { Write-Host "  Invalid option. Press Enter to continue." -ForegroundColor Red; Read-Host }
        }
    }
}

# ==================== DOCKER TOOLS ====================
function Show-DockerMenu {
    Show-Header "Docker Tools"
    Write-Host "  [1] Docker Nuke (remove all)"
    Write-Host "  [2] Docker Cleanup (selective)"
    Write-Host "  [3] Quick Logs (multi-container)"
    Write-Host ""
    Write-Host "  [0] Back"
    Write-Host ""
}

function Start-DockerTools {
    while ($true) {
        Show-DockerMenu
        $choice = Read-Host "Select option"
        switch ($choice) {
            '1' { 
                Clear-Host
                $scriptPath = Join-Path (Join-Path $ScriptDir "docker") "Docker-Nuke.ps1"
                if (Test-Path $scriptPath) { & $scriptPath } else { Write-Host "  ERROR: Script not found: $scriptPath" -ForegroundColor Red }
                Read-Host "Press Enter to continue"
            }
            '2' { 
                Clear-Host
                $scriptPath = Join-Path (Join-Path $ScriptDir "docker") "Docker-Cleanup.ps1"
                if (Test-Path $scriptPath) { & $scriptPath } else { Write-Host "  ERROR: Script not found: $scriptPath" -ForegroundColor Red }
                Read-Host "Press Enter to continue"
            }
            '3' { 
                Clear-Host
                $scriptPath = Join-Path (Join-Path $ScriptDir "docker") "Docker-QuickLogs.ps1"
                if (Test-Path $scriptPath) { & $scriptPath } else { Write-Host "  ERROR: Script not found: $scriptPath" -ForegroundColor Red }
                Read-Host "Press Enter to continue"
            }
            '0' { return }
            default { Write-Host "  Invalid option. Press Enter to continue." -ForegroundColor Red; Read-Host }
        }
    }
}

# ==================== SYSTEM TOOLS ====================
function Show-SystemMenu {
    Show-Header "System Tools"
    Write-Host "  [1] Edit PATH Variable"
    Write-Host "  [2] Backup Environment Variables"
    Write-Host "  [3] Restore Environment Variables"
    Write-Host "  [4] Shell Reload (refresh env)"
    Write-Host ""
    Write-Host "  [0] Back"
    Write-Host ""
}

function Start-SystemTools {
    while ($true) {
        Show-SystemMenu
        $choice = Read-Host "Select option"
        switch ($choice) {
            '1' { 
                Clear-Host
                $scriptPath = Join-Path (Join-Path $ScriptDir "system") "Edit-Path.ps1"
                if (Test-Path $scriptPath) { & $scriptPath } else { Write-Host "  ERROR: Script not found: $scriptPath" -ForegroundColor Red }
                Read-Host "Press Enter to continue"
            }
            { $_ -eq '2' -or $_ -eq '2p' } {
                Clear-Host
                $targetPath = Select-DevKitProject -Prompt "Backup Environment Variables (output folder)" -ForceReprompt:($choice -eq '2p')
                if ($null -eq $targetPath) {
                    Write-Host "  Cancelled -- no output folder selected." -ForegroundColor Yellow
                } else {
                    $scriptPath = Join-Path (Join-Path $ScriptDir "system") "Env-Backup.ps1"
                    if (Test-Path $scriptPath) { & $scriptPath -OutputPath $targetPath } else { Write-Host "  ERROR: Script not found: $scriptPath" -ForegroundColor Red }
                }
                Read-Host "Press Enter to continue"
            }
            '3' {
                Clear-Host
                Write-Host "  [B] Browse for a backup file..."
                Write-Host "  [T] Type a path manually"
                Write-Host "  [0] Cancel"
                $pickMode = Read-Host "Select option"
                $backupFile = $null
                if ($pickMode -eq 'B' -or $pickMode -eq 'b') {
                    $backupFile = Show-DevKitFileBrowser -Description "Select an environment backup to restore" -Filter "DevKit backups (*.json)|*.json|All files (*.*)|*.*"
                } elseif ($pickMode -eq 'T' -or $pickMode -eq 't') {
                    $backupFile = Read-Host "Enter backup file path to restore"
                }
                if ([string]::IsNullOrWhiteSpace($backupFile)) {
                    Write-Host "  Cancelled -- no backup file selected." -ForegroundColor Yellow
                } else {
                    $scriptPath = Join-Path (Join-Path $ScriptDir "system") "Env-Restore.ps1"
                    if (Test-Path $scriptPath) { & $scriptPath -BackupFile $backupFile } else { Write-Host "  ERROR: Script not found: $scriptPath" -ForegroundColor Red }
                }
                Read-Host "Press Enter to continue"
            }
            '4' { 
                Clear-Host
                $scriptPath = Join-Path (Join-Path $ScriptDir "system") "Shell-Reload.ps1"
                if (Test-Path $scriptPath) { & $scriptPath } else { Write-Host "  ERROR: Script not found: $scriptPath" -ForegroundColor Red }
                Read-Host "Press Enter to continue"
            }
            '0' { return }
            default { Write-Host "  Invalid option. Press Enter to continue." -ForegroundColor Red; Read-Host }
        }
    }
}

# ==================== WORKFLOW TOOLS ====================
function Show-WorkflowMenu {
    Show-Header "Workflow Tools"
    Write-Host "  [1] Code Here (open VS Code/Cursor)"
    Write-Host "  [2] Open Repo in Browser"
    Write-Host "  [3] Copy .env Template"
    Write-Host ""
    Write-Host "  [0] Back"
    Write-Host ""
}

function Start-WorkflowTools {
    while ($true) {
        Show-WorkflowMenu
        $choice = Read-Host "Select option"
        switch ($choice) {
            { $_ -eq '1' -or $_ -eq '1p' } {
                Clear-Host
                $targetPath = Select-DevKitProject -Prompt "Code Here (open VS Code/Cursor)" -ForceReprompt:($choice -eq '1p')
                if ($null -eq $targetPath) {
                    Write-Host "  Cancelled -- no project selected." -ForegroundColor Yellow
                } else {
                    $scriptPath = Join-Path (Join-Path $ScriptDir "workflow") "Code-Here.ps1"
                    if (Test-Path $scriptPath) { & $scriptPath -Path $targetPath } else { Write-Host "  ERROR: Script not found: $scriptPath" -ForegroundColor Red }
                }
                Read-Host "Press Enter to continue"
            }
            { $_ -eq '2' -or $_ -eq '2p' } {
                Clear-Host
                $targetPath = Select-DevKitProject -Prompt "Open Repo in Browser" -ForceReprompt:($choice -eq '2p')
                if ($null -eq $targetPath) {
                    Write-Host "  Cancelled -- no project selected." -ForegroundColor Yellow
                } else {
                    $scriptPath = Join-Path (Join-Path $ScriptDir "workflow") "Open-Repo.ps1"
                    if (Test-Path $scriptPath) { & $scriptPath -Path $targetPath } else { Write-Host "  ERROR: Script not found: $scriptPath" -ForegroundColor Red }
                }
                Read-Host "Press Enter to continue"
            }
            { $_ -eq '3' -or $_ -eq '3p' } {
                Clear-Host
                $targetPath = Select-DevKitProject -Prompt "Copy .env Template" -ForceReprompt:($choice -eq '3p')
                if ($null -eq $targetPath) {
                    Write-Host "  Cancelled -- no project selected." -ForegroundColor Yellow
                } else {
                    $scriptPath = Join-Path (Join-Path $ScriptDir "workflow") "Copy-EnvTemplate.ps1"
                    if (Test-Path $scriptPath) { & $scriptPath -Path $targetPath } else { Write-Host "  ERROR: Script not found: $scriptPath" -ForegroundColor Red }
                }
                Read-Host "Press Enter to continue"
            }
            '0' { return }
            default { Write-Host "  Invalid option. Press Enter to continue." -ForegroundColor Red; Read-Host }
        }
    }
}

# ==================== DIAGNOSTICS ====================
function Show-DiagnosticsMenu {
    Show-Header "Diagnostics"
    Write-Host "  [1] DevKit Doctor (health check)"
    Write-Host "  [2] System Dev Info"
    Write-Host ""
    Write-Host "  [0] Back"
    Write-Host ""
}

function Start-DiagnosticsTools {
    while ($true) {
        Show-DiagnosticsMenu
        $choice = Read-Host "Select option"
        switch ($choice) {
            '1' { 
                Clear-Host
                $scriptPath = Join-Path (Join-Path $ScriptDir "diagnostics") "DevKit-Doctor.ps1"
                if (Test-Path $scriptPath) { & $scriptPath } else { Write-Host "  ERROR: Script not found: $scriptPath" -ForegroundColor Red }
                Read-Host "Press Enter to continue"
            }
            '2' { 
                Clear-Host
                $scriptPath = Join-Path (Join-Path $ScriptDir "diagnostics") "System-DevInfo.ps1"
                if (Test-Path $scriptPath) { & $scriptPath } else { Write-Host "  ERROR: Script not found: $scriptPath" -ForegroundColor Red }
                Read-Host "Press Enter to continue"
            }
            '0' { return }
            default { Write-Host "  Invalid option. Press Enter to continue." -ForegroundColor Red; Read-Host }
        }
    }
}

# ==================== PROJECTS ====================
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

# ==================== WIFI TOOLS ====================
function Show-WiFiMenu {
    Show-Header "WiFi Tools"
    Write-Host "  [1] WiFi Optimizer (Full)"
    Write-Host "  [2] WiFi Optimizer (Fast Mode)"
    Write-Host "  [3] WiFi Scanner"
    Write-Host ""
    Write-Host "  [0] Back"
    Write-Host ""
}

function Invoke-WiFiOptimize {
    Clear-Host
    $scriptPath = Join-Path (Join-Path $ScriptDir "wifi") "WiFi-Optimize.ps1"
    if (Test-Path $scriptPath) { & $scriptPath } else { Write-Host "  ERROR: Script not found: $scriptPath" -ForegroundColor Red }
    Read-Host "Press Enter to continue"
}

function Invoke-WiFiFast {
    Clear-Host
    $scriptPath = Join-Path (Join-Path $ScriptDir "wifi") "WiFi-FastMode.ps1"
    if (Test-Path $scriptPath) { & $scriptPath -Fast } else { Write-Host "  ERROR: Script not found: $scriptPath" -ForegroundColor Red }
    Read-Host "Press Enter to continue"
}

function Invoke-WiFiScan {
    Clear-Host
    $scriptPath = Join-Path (Join-Path $ScriptDir "wifi") "WiFi-Scan.ps1"
    if (Test-Path $scriptPath) { & $scriptPath } else { Write-Host "  ERROR: Script not found: $scriptPath" -ForegroundColor Red }
    Read-Host "Press Enter to continue"
}

function Start-WiFiTools {
    while ($true) {
        Show-WiFiMenu
        $choice = Read-Host "Select option"
        switch ($choice) {
            '1' { Invoke-WiFiOptimize }
            '2' { Invoke-WiFiFast }
            '3' { Invoke-WiFiScan }
            '0' { return }
            default { Write-Host "  Invalid option. Press Enter to continue." -ForegroundColor Red; Read-Host }
        }
    }
}

# Entry Point
while ($true) {
    Show-MainMenu
    $mainChoice = Read-Host "Select option"
    switch ($mainChoice) {
        '1' { Start-PortTools }
        '2' { Start-NodeTools }
        '3' { Start-NextJsTools }
        '4' { Start-ViteTools }
        '5' { Start-GitTools }
        '6' { Start-DockerTools }
        '7' { Start-SystemTools }
        '8' { Start-WorkflowTools }
        '9' { Start-DiagnosticsTools }
        '10' { Start-ProjectTools }
        '11' { Start-WiFiTools }
        '0' { exit }
        default { Write-Host "  Invalid option. Press Enter to continue." -ForegroundColor Red; Read-Host }
    }
}