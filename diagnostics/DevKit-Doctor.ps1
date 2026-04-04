#!/usr/bin/env pwsh
<#
.SYNOPSIS
    DevKit Doctor - Northstar DevKit
.DESCRIPTION
    Health check for development environment. Verifies installations
    of essential tools, checks versions, and detects common issues.
    
    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Fix
    Attempt to automatically fix issues where possible.
.PARAMETER Quiet
    Only show errors and warnings.
.EXAMPLE
    .\DevKit-Doctor.ps1
    .\DevKit-Doctor.ps1 -Fix
    .\DevKit-Doctor.ps1 -Quiet
#>
[CmdletBinding()]
param(
    [switch]$Fix,
    [switch]$Quiet
)

function Write-Check {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Message = "",
        [string]$FixMessage = ""
    )
    
    $icon = if ($Passed) { "✓" } else { "✗" }
    $color = if ($Passed) { "Green" } else { "Red" }
    
    if ($Quiet -and $Passed) { return }
    
    Write-Host "  [$icon] $Name" -ForegroundColor $color -NoNewline
    if ($Message) {
        Write-Host " - $Message" -ForegroundColor Gray
    } else {
        Write-Host ""
    }
    
    if (-not $Passed -and $FixMessage) {
        Write-Host "      → $FixMessage" -ForegroundColor Yellow
    }
}

Write-Host "`nNorthstar DevKit - Doctor`n" -ForegroundColor Cyan
Write-Host "  Checking development environment health..." -ForegroundColor Yellow
Write-Host ""

$issuesFound = 0
$warningsFound = 0

# ==================== PowerShell ====================
Write-Host "  PowerShell:" -ForegroundColor Cyan
$psVersion = $PSVersionTable.PSVersion
$ps7Installed = $psVersion.Major -ge 7
Write-Check "PowerShell Version" $ps7Installed "v$($psVersion.ToString())" "Install PowerShell 7 from https://aka.ms/powershell"
if (-not $ps7Installed) { $issuesFound++ }

# ==================== Node.js ====================
Write-Host "`n  Node.js:" -ForegroundColor Cyan
try {
    $nodeVersion = node --version 2>$null
    if ($LASTEXITCODE -eq 0) {
        $nodeInstalled = $true
        $versionNum = [version]($nodeVersion -replace '^v','')
        $nodeCurrent = $versionNum.Major -ge 18
        Write-Check "Node.js Installed" $true $nodeVersion
        Write-Check "Node.js Version (18+)" $nodeCurrent "v$versionNum" "Update Node.js from https://nodejs.org"
        if (-not $nodeCurrent) { $warningsFound++ }
    } else {
        throw "Node not found"
    }
} catch {
    Write-Check "Node.js Installed" $false "" "Install Node.js from https://nodejs.org"
    $issuesFound++
}

# NPM
try {
    $npmVersion = npm --version 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Check "NPM Installed" $true "v$npmVersion"
    } else {
        throw "NPM not found"
    }
} catch {
    Write-Check "NPM Installed" $false "" "Reinstall Node.js (includes NPM)"
    $issuesFound++
}

# Yarn/PNPM (optional but nice)
try {
    $yarnVersion = yarn --version 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Check "Yarn Installed" $true "v$yarnVersion"
    }
} catch {}

try {
    $pnpmVersion = pnpm --version 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Check "PNPM Installed" $true "v$pnpmVersion"
    }
} catch {}

# ==================== Git ====================
Write-Host "`n  Git:" -ForegroundColor Cyan
try {
    $gitVersion = git --version 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Check "Git Installed" $true ($gitVersion -replace '^git version ','')
        
        # Check Git config
        $gitName = git config user.name 2>$null
        $gitEmail = git config user.email 2>$null
        
        $gitConfigOk = $gitName -and $gitEmail
        Write-Check "Git Config (name/email)" $gitConfigOk "" "Run: git config --global user.name 'Your Name' && git config --global user.email 'your@email.com'"
        if (-not $gitConfigOk) { $warningsFound++ }
    } else {
        throw "Git not found"
    }
} catch {
    Write-Check "Git Installed" $false "" "Install Git from https://git-scm.com"
    $issuesFound++
}

# ==================== Docker ====================
Write-Host "`n  Docker:" -ForegroundColor Cyan
try {
    $dockerVersion = docker --version 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Check "Docker CLI" $true ($dockerVersion -replace '^Docker version ','' -replace ',.*$','')
        
        # Check if daemon is running
        $dockerInfo = docker info 2>$null
        $dockerRunning = $LASTEXITCODE -eq 0
        Write-Check "Docker Daemon" $dockerRunning "" "Start Docker Desktop"
        if (-not $dockerRunning) { $warningsFound++ }
    } else {
        throw "Docker not found"
    }
} catch {
    Write-Check "Docker" $false "" "Install Docker Desktop from https://docker.com"
    $warningsFound++
}

# ==================== VS Code ====================
Write-Host "`n  Editors:" -ForegroundColor Cyan
try {
    $codeVersion = code --version 2>$null | Select-Object -First 1
    if ($LASTEXITCODE -eq 0) {
        Write-Check "VS Code" $true $codeVersion
    } else {
        throw "VS Code not found"
    }
} catch {
    Write-Check "VS Code" $false "" "Install from https://code.visualstudio.com"
}

try {
    $cursorCheck = Get-Command cursor -ErrorAction SilentlyContinue
    if ($cursorCheck) {
        Write-Check "Cursor" $true "Installed"
    }
} catch {}

# ==================== Python (optional) ====================
Write-Host "`n  Python:" -ForegroundColor Cyan
try {
    $pythonVersion = python --version 2>&1
    if ($pythonVersion -match 'Python (\d+\.\d+\.\d+)') {
        Write-Check "Python Installed" $true $matches[1]
    } else {
        throw "Python not found"
    }
} catch {
    try {
        $pythonVersion = python3 --version 2>&1
        if ($pythonVersion -match 'Python (\d+\.\d+\.\d+)') {
            Write-Check "Python Installed" $true $matches[1]
        }
    } catch {
        Write-Check "Python" $false "" "Optional - Install from https://python.org if needed"
    }
}

# ==================== System ====================
Write-Host "`n  System:" -ForegroundColor Cyan

# Windows version
$osInfo = Get-CimInstance Win32_OperatingSystem
$windowsVersion = $osInfo.Caption
$windowsBuild = [System.Environment]::OSVersion.Version
Write-Check "Windows Version" ($windowsBuild.Major -ge 10) $windowsVersion

# Admin check
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Check "Administrator Rights" $isAdmin "" "Some features require admin - Run as Administrator if needed"

# Execution policy
$execPolicy = Get-ExecutionPolicy
$execPolicyOk = $execPolicy -in @('RemoteSigned', 'Unrestricted', 'Bypass')
Write-Check "Execution Policy" $execPolicyOk $execPolicy "Run: Set-ExecutionPolicy RemoteSigned -Scope CurrentUser"
if (-not $execPolicyOk) { $warningsFound++ }

# Disk space
$systemDrive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'"
$freeSpaceGB = [math]::Round($systemDrive.FreeSpace / 1GB, 1)
$totalSpaceGB = [math]::Round($systemDrive.Size / 1GB, 1)
$diskOk = $freeSpaceGB -gt 10
Write-Check "Disk Space (C:)" $diskOk "$freeSpaceGB GB free / $totalSpaceGB GB total" "Free up disk space"
if (-not $diskOk) { $warningsFound++ }

# ==================== Summary ====================
Write-Host "`n  ===================================" -ForegroundColor Cyan
if ($issuesFound -eq 0 -and $warningsFound -eq 0) {
    Write-Host "  ✓ All checks passed!" -ForegroundColor Green
    Write-Host "  Your development environment looks good." -ForegroundColor Gray
} elseif ($issuesFound -eq 0) {
    Write-Host "  ⚠ $warningsFound warning(s) found" -ForegroundColor Yellow
    Write-Host "  Your environment works but could be improved." -ForegroundColor Gray
} else {
    Write-Host "  ✗ $issuesFound issue(s) and $warningsFound warning(s) found" -ForegroundColor Red
    Write-Host "  Please address the issues above." -ForegroundColor Gray
}
Write-Host "  ===================================`n" -ForegroundColor Cyan

# Exit with error code if issues found
if ($issuesFound -gt 0) {
    exit 1
}
