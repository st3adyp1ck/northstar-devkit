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
    2.0.0
.NOTES
    Requires PowerShell 5.1 or PowerShell 7+
    Run as Administrator for full network optimization features
.LINK
    https://www.northstarcoding.com
.EXAMPLE
    .\DevKit.ps1
#>

$ScriptDir = $PSScriptRoot
$CommonPorts = @(3000, 3001, 5173, 8000, 8080, 9000, 4200, 5000, 5500)

function Show-Header {
    param([string]$Title)
    Clear-Host
    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host "        Northstar DevKit v2.0              " -ForegroundColor Cyan
    Write-Host "    Developer Toolkit by Northstar.com      " -ForegroundColor Cyan
    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host "  Current: $Title" -ForegroundColor Yellow
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
    Write-Host "  Network:" -ForegroundColor Magenta
    Write-Host "    [10] WiFi Tools    - Optimize and Scan"
    Write-Host ""
    Write-Host "    [0] Exit"
    Write-Host ""
}

# ==================== PORT TOOLS ====================
function Show-PortMenu {
    Show-Header "Port Tools"
    Write-Host "  [1] Scan Common Dev Ports"
    Write-Host "  [2] Scan Specific Port"
    Write-Host "  [3] Kill Process by PID"
    Write-Host "  [4] Kill All Node Processes"
    Write-Host ""
    Write-Host "  [0] Back"
    Write-Host ""
}

function Invoke-PortScan {
    Show-Header "Scanning Common Dev Ports"
    Write-Host "Ports: $($CommonPorts -join ', ')" -ForegroundColor Gray
    Write-Host ""

    $found = $false
    foreach ($port in $CommonPorts) {
        $connection = Get-NetTCPConnection -LocalPort $port -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($connection) {
            $found = $true
            $process = Get-Process -Id $connection.OwningProcess -ErrorAction SilentlyContinue
            Write-Host "  WARNING: Port $port" -ForegroundColor Red -NoNewline
            Write-Host " -> PID: $($connection.OwningProcess)" -ForegroundColor Yellow -NoNewline
            if ($process) {
                Write-Host " ($($process.ProcessName))" -ForegroundColor Gray
            } else {
                Write-Host ""
            }
        }
    }

    if (-not $found) {
        Write-Host "  OK: All clear! No processes on common dev ports." -ForegroundColor Green
    }
    Write-Host ""
    Read-Host "Press Enter to continue"
}

function Invoke-PortScanSpecific {
    Show-Header "Scan Specific Port"
    $port = Read-Host "Enter port number"
    
    if ($port -match '^\d+$') {
        $connection = Get-NetTCPConnection -LocalPort ([int]$port) -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($connection) {
            $process = Get-Process -Id $connection.OwningProcess -ErrorAction SilentlyContinue
            Write-Host ""
            Write-Host "  WARNING: Port $port is IN USE" -ForegroundColor Red
            Write-Host "  PID: $($connection.OwningProcess)" -ForegroundColor Yellow
            if ($process) {
                Write-Host "  Process: $($process.ProcessName)" -ForegroundColor Yellow
                Write-Host "  Path: $($process.Path)" -ForegroundColor Gray
            }
        } else {
            Write-Host ""
            Write-Host "  OK: Port $port is free." -ForegroundColor Green
        }
    } else {
        Write-Host "  ERROR: Invalid port number." -ForegroundColor Red
    }
    Write-Host ""
    Read-Host "Press Enter to continue"
}

function Invoke-KillProcess {
    Show-Header "Kill Process by PID"
    $pidInput = Read-Host "Enter PID to kill"
    
    if ($pidInput -match '^\d+$') {
        $targetPid = [int]$pidInput
        try {
            $process = Get-Process -Id $targetPid -ErrorAction Stop
            Write-Host ""
            Write-Host "  Process: $($process.ProcessName) (PID: $targetPid)" -ForegroundColor Yellow
            $confirm = Read-Host "  Confirm kill? (y/n)"
            if ($confirm -eq 'y') {
                Stop-Process -Id $targetPid -Force
                Write-Host "  DONE: Process killed." -ForegroundColor Green
            } else {
                Write-Host "  Cancelled." -ForegroundColor Gray
            }
        } catch {
            Write-Host "  ERROR: Process not found." -ForegroundColor Red
        }
    } else {
        Write-Host "  ERROR: Invalid PID." -ForegroundColor Red
    }
    Write-Host ""
    Read-Host "Press Enter to continue"
}

function Invoke-KillAllNode {
    Show-Header "Kill All Node Processes"
    $nodeProcesses = Get-Process -Name "node" -ErrorAction SilentlyContinue
    
    if ($nodeProcesses) {
        $count = ($nodeProcesses | Measure-Object).Count
        Write-Host "  Found $count node process(es)." -ForegroundColor Yellow
        $confirm = Read-Host "  Confirm kill all? (y/n)"
        if ($confirm -eq 'y') {
            $nodeProcesses | Stop-Process -Force
            Write-Host "  DONE: All node processes killed." -ForegroundColor Green
        } else {
            Write-Host "  Cancelled." -ForegroundColor Gray
        }
    } else {
        Write-Host "  OK: No node processes running." -ForegroundColor Green
    }
    Write-Host ""
    Read-Host "Press Enter to continue"
}

function Start-PortTools {
    while ($true) {
        Show-PortMenu
        $choice = Read-Host "Select option"
        switch ($choice) {
            '1' { Invoke-PortScan }
            '2' { Invoke-PortScanSpecific }
            '3' { Invoke-KillProcess }
            '4' { Invoke-KillAllNode }
            '0' { return }
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

function Invoke-ClearNpmCache {
    Show-Header "Clear NPM Cache"
    Write-Host "  Running: npm cache clean --force" -ForegroundColor Gray
    Write-Host ""
    npm cache clean --force
    Write-Host ""
    Write-Host "  DONE: NPM cache cleared." -ForegroundColor Green
    Write-Host ""
    Read-Host "Press Enter to continue"
}

function Invoke-DeleteNodeModules {
    Show-Header "Delete node_modules"
    $targetPath = Read-Host "Enter project path (or '.' for current)"
    if ($targetPath -eq '.') { $targetPath = Get-Location }
    
    $nmPath = Join-Path $targetPath "node_modules"
    if (Test-Path $nmPath) {
        Write-Host "  Found node_modules. Deleting..." -ForegroundColor Yellow
        Remove-Item -Path $nmPath -Recurse -Force
        Write-Host "  DONE: node_modules deleted." -ForegroundColor Green
    } else {
        Write-Host "  ERROR: node_modules not found at $nmPath" -ForegroundColor Red
    }
    Write-Host ""
    Read-Host "Press Enter to continue"
}

function Invoke-NukeAndReinstall {
    Show-Header "Nuke and Reinstall"
    $targetPath = Read-Host "Enter project path (or '.' for current)"
    if ($targetPath -eq '.') { $targetPath = Get-Location }
    
    Push-Location $targetPath
    
    try {
        if (Test-Path "node_modules") {
            Write-Host "  Deleting node_modules..." -ForegroundColor Yellow
            Remove-Item -Path "node_modules" -Recurse -Force
        }
        if (Test-Path "package-lock.json") {
            Write-Host "  Deleting package-lock.json..." -ForegroundColor Yellow
            Remove-Item -Path "package-lock.json" -Force
        }
        Write-Host "  Running npm install..." -ForegroundColor Yellow
        npm install
        Write-Host ""
        Write-Host "  DONE: Fresh install complete." -ForegroundColor Green
    } catch {
        Write-Host "  ERROR: $_" -ForegroundColor Red
    } finally {
        Pop-Location
    }
    Write-Host ""
    Read-Host "Press Enter to continue"
}

function Invoke-CheckNpmCacheSize {
    Show-Header "NPM Cache Size"
    $cacheInfo = npm cache verify 2>&1
    $cachePath = npm config get cache
    
    Write-Host "  Cache Path: $cachePath" -ForegroundColor Gray
    Write-Host ""
    Write-Host ($cacheInfo | Out-String) -ForegroundColor Gray
    Read-Host "Press Enter to continue"
}

function Start-NodeTools {
    while ($true) {
        Show-NodeMenu
        $choice = Read-Host "Select option"
        switch ($choice) {
            '1' { Invoke-ClearNpmCache }
            '2' { Invoke-DeleteNodeModules }
            '3' { Invoke-NukeAndReinstall }
            '4' { Invoke-CheckNpmCacheSize }
            '0' { return }
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

function Invoke-ClearNextCache {
    Show-Header "Clear .next Cache"
    $targetPath = Read-Host "Enter project path (or '.' for current)"
    if ($targetPath -eq '.') { $targetPath = Get-Location }
    
    $nextPath = Join-Path $targetPath ".next"
    if (Test-Path $nextPath) {
        Write-Host "  Deleting .next folder..." -ForegroundColor Yellow
        Remove-Item -Path $nextPath -Recurse -Force
        Write-Host "  DONE: .next cache cleared." -ForegroundColor Green
    } else {
        Write-Host "  WARNING: .next folder not found." -ForegroundColor Yellow
    }
    Write-Host ""
    Read-Host "Press Enter to continue"
}

function Invoke-ClearTurbopackCache {
    Show-Header "Clear Turbopack Cache"
    $targetPath = Read-Host "Enter project path (or '.' for current)"
    if ($targetPath -eq '.') { $targetPath = Get-Location }
    
    $cachePaths = @(
        (Join-Path $targetPath ".next\cache"),
        (Join-Path $targetPath "node_modules\.cache"),
        (Join-Path $targetPath ".turbo")
    )
    
    $found = $false
    foreach ($path in $cachePaths) {
        if (Test-Path $path) {
            Write-Host "  Deleting $path..." -ForegroundColor Yellow
            Remove-Item -Path $path -Recurse -Force
            $found = $true
        }
    }
    
    if ($found) {
        Write-Host "  DONE: Turbopack caches cleared." -ForegroundColor Green
    } else {
        Write-Host "  WARNING: No Turbopack caches found." -ForegroundColor Yellow
    }
    Write-Host ""
    Read-Host "Press Enter to continue"
}

function Invoke-FullNextClean {
    Show-Header "Full Next.js Clean"
    $targetPath = Read-Host "Enter project path (or '.' for current)"
    if ($targetPath -eq '.') { $targetPath = Get-Location }
    
    Push-Location $targetPath
    
    try {
        $nodeProcs = Get-Process -Name "node" -ErrorAction SilentlyContinue | 
            Where-Object { $_.Path -like "*$targetPath*" }
        if ($nodeProcs) {
            Write-Host "  Stopping local node processes..." -ForegroundColor Yellow
            $nodeProcs | Stop-Process -Force
        }
        
        $pathsToDelete = @(".next", "node_modules", "package-lock.json")
        foreach ($p in $pathsToDelete) {
            if (Test-Path $p) {
                Write-Host "  Deleting $p..." -ForegroundColor Yellow
                Remove-Item -Path $p -Recurse -Force
            }
        }
        
        Write-Host "  Running npm install..." -ForegroundColor Yellow
        npm install
        Write-Host ""
        Write-Host "  DONE: Full clean and reinstall complete!" -ForegroundColor Green
    } catch {
        Write-Host "  ERROR: $_" -ForegroundColor Red
    } finally {
        Pop-Location
    }
    Write-Host ""
    Read-Host "Press Enter to continue"
}

function Invoke-NextDevFresh {
    Show-Header "Next.js Dev Server (Fresh Start)"
    $targetPath = Read-Host "Enter project path (or '.' for current)"
    if ($targetPath -eq '.') { $targetPath = Get-Location }
    
    Push-Location $targetPath
    
    try {
        if (Test-Path ".next") {
            Write-Host "  Clearing .next cache..." -ForegroundColor Yellow
            Remove-Item -Path ".next" -Recurse -Force
        }
        
        Write-Host "  Starting dev server..." -ForegroundColor Green
        Write-Host ""
        npm run dev
    } catch {
        Write-Host "  ERROR: $_" -ForegroundColor Red
        Read-Host "Press Enter to continue"
    } finally {
        Pop-Location
    }
}

function Start-NextJsTools {
    while ($true) {
        Show-NextJsMenu
        $choice = Read-Host "Select option"
        switch ($choice) {
            '1' { Invoke-ClearNextCache }
            '2' { Invoke-ClearTurbopackCache }
            '3' { Invoke-FullNextClean }
            '4' { Invoke-NextDevFresh }
            '0' { return }
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
            '1' { 
                Clear-Host
                $targetPath = Read-Host "Enter project path (or '.' for current)"
                if ($targetPath -eq '.') { $targetPath = Get-Location }
                & "$ScriptDir\vite\Vite-DevFresh.ps1" -Path $targetPath
                Read-Host "Press Enter to continue"
            }
            '2' { 
                Clear-Host
                $targetPath = Read-Host "Enter project path (or '.' for current)"
                if ($targetPath -eq '.') { $targetPath = Get-Location }
                & "$ScriptDir\vite\Vite-PreviewBuild.ps1" -Path $targetPath
                Read-Host "Press Enter to continue"
            }
            '0' { return }
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
            '1' { 
                Clear-Host
                $targetPath = Read-Host "Enter project path (or '.' for current)"
                if ($targetPath -eq '.') { $targetPath = Get-Location }
                & "$ScriptDir\git\Git-Cleanup.ps1" -Path $targetPath
                Read-Host "Press Enter to continue"
            }
            '2' { 
                Clear-Host
                $targetPath = Read-Host "Enter root path to scan (or '.' for current)"
                if ($targetPath -eq '.') { $targetPath = Get-Location }
                & "$ScriptDir\git\Git-StatusAll.ps1" -Path $targetPath
                Read-Host "Press Enter to continue"
            }
            '3' { 
                Clear-Host
                $targetPath = Read-Host "Enter project path (or '.' for current)"
                if ($targetPath -eq '.') { $targetPath = Get-Location }
                & "$ScriptDir\git\Git-SyncFork.ps1" -Path $targetPath
                Read-Host "Press Enter to continue"
            }
            '0' { return }
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
                & "$ScriptDir\docker\Docker-Nuke.ps1"
            }
            '2' { 
                Clear-Host
                & "$ScriptDir\docker\Docker-Cleanup.ps1"
            }
            '3' { 
                Clear-Host
                & "$ScriptDir\docker\Docker-QuickLogs.ps1"
            }
            '0' { return }
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
                & "$ScriptDir\system\Edit-Path.ps1"
            }
            '2' { 
                Clear-Host
                $targetPath = Read-Host "Enter backup output path (or '.' for current)"
                if ($targetPath -eq '.') { $targetPath = Get-Location }
                & "$ScriptDir\system\Env-Backup.ps1" -OutputPath $targetPath
                Read-Host "Press Enter to continue"
            }
            '3' { 
                Clear-Host
                $backupFile = Read-Host "Enter backup file path to restore"
                & "$ScriptDir\system\Env-Restore.ps1" -BackupFile $backupFile
                Read-Host "Press Enter to continue"
            }
            '4' { 
                Clear-Host
                & "$ScriptDir\system\Shell-Reload.ps1"
            }
            '0' { return }
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
            '1' { 
                Clear-Host
                $targetPath = Read-Host "Enter project path (or '.' for current)"
                if ($targetPath -eq '.') { $targetPath = Get-Location }
                & "$ScriptDir\workflow\Code-Here.ps1" -Path $targetPath
                Read-Host "Press Enter to continue"
            }
            '2' { 
                Clear-Host
                $targetPath = Read-Host "Enter project path (or '.' for current)"
                if ($targetPath -eq '.') { $targetPath = Get-Location }
                & "$ScriptDir\workflow\Open-Repo.ps1" -Path $targetPath
                Read-Host "Press Enter to continue"
            }
            '3' { 
                Clear-Host
                $targetPath = Read-Host "Enter project path (or '.' for current)"
                if ($targetPath -eq '.') { $targetPath = Get-Location }
                & "$ScriptDir\workflow\Copy-EnvTemplate.ps1" -Path $targetPath
                Read-Host "Press Enter to continue"
            }
            '0' { return }
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
                & "$ScriptDir\diagnostics\DevKit-Doctor.ps1"
                Read-Host "Press Enter to continue"
            }
            '2' { 
                Clear-Host
                & "$ScriptDir\diagnostics\System-DevInfo.ps1"
                Read-Host "Press Enter to continue"
            }
            '0' { return }
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
    & "$ScriptDir\wifi\WiFi-Optimize.ps1"
}

function Invoke-WiFiFast {
    Clear-Host
    & "$ScriptDir\wifi\WiFi-Optimize.ps1" -Fast
}

function Invoke-WiFiScan {
    Clear-Host
    & "$ScriptDir\wifi\WiFi-Scan.ps1"
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
        '10' { Start-WiFiTools }
        '0' { exit }
    }
}
