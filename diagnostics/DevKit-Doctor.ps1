#!/usr/bin/env pwsh
<#
.SYNOPSIS
    DevKit Doctor - Northstar DevKit
.DESCRIPTION
    Health check for development environment. Verifies installations
    of essential tools, checks versions, and detects common issues.
    
    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Quiet
    Only show errors and warnings.
.EXAMPLE
    .\DevKit-Doctor.ps1
    .\DevKit-Doctor.ps1 -Quiet
#>[CmdletBinding()]
param(
    [switch]$Quiet
)


$CommonModule = Join-Path $PSScriptRoot ".." "lib" "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }


function Write-Check {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Message = "",
        [string]$FixMessage = ""
    )
    
    $icon = if ($Passed) { "OK" } else { "FAIL" }
    $color = if ($Passed) { "Green" } else { "Red" }
    
    if ($Quiet -and $Passed) { return }
    
    Write-Host "  [$icon] $Name" -ForegroundColor $color -NoNewline
    if ($Message) {
        Write-Host " - $Message" -ForegroundColor Gray
    } else {
        Write-Host ""
    }
    
    if (-not $Passed -and $FixMessage) {
        Write-Host "      -> $FixMessage" -ForegroundColor Yellow
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
$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if ($nodeCmd) {
    $nodeVersion = & node --version 2>$null
    $nodeInstalled = $true
    if ($nodeVersion -match '^v?(\d+\.\d+\.\d+)') {
        $versionNum = [version]$matches[1]
        $nodeCurrent = $versionNum.Major -ge 18
        Write-Check "Node.js Installed" $true $nodeVersion
        Write-Check "Node.js Version (18+)" $nodeCurrent "v$versionNum" "Update Node.js from https://nodejs.org"
        if (-not $nodeCurrent) { $warningsFound++ }
    } else {
        Write-Check "Node.js Installed" $true $nodeVersion
    }
} else {
    Write-Check "Node.js Installed" $false "" "Install Node.js from https://nodejs.org"
    $issuesFound++
}

# NPM
$npmCmd = Get-Command npm -ErrorAction SilentlyContinue
if ($npmCmd) {
    $npmVersion = & npm --version 2>$null
    Write-Check "NPM Installed" $true "v$npmVersion"
} else {
    Write-Check "NPM Installed" $false "" "Reinstall Node.js (includes NPM)"
    $issuesFound++
}

# Yarn/PNPM/Bun (optional but nice)
$yarnCmd = Get-Command yarn -ErrorAction SilentlyContinue
if ($yarnCmd) {
    $yarnVersion = & yarn --version 2>$null
    Write-Check "Yarn Installed" $true "v$yarnVersion"
}

$pnpmCmd = Get-Command pnpm -ErrorAction SilentlyContinue
if ($pnpmCmd) {
    $pnpmVersion = & pnpm --version 2>$null
    Write-Check "PNPM Installed" $true "v$pnpmVersion"
}

$bunCmd = Get-Command bun -ErrorAction SilentlyContinue
if ($bunCmd) {
    $bunVersion = & bun --version 2>$null
    Write-Check "Bun Installed" $true "v$bunVersion"
}

# ==================== Git ====================
Write-Host "`n  Git:" -ForegroundColor Cyan
$gitCmd = Get-Command git -ErrorAction SilentlyContinue
if ($gitCmd) {
    $gitVersion = & git --version 2>$null
    Write-Check "Git Installed" $true ($gitVersion -replace '^git version ','')
    
    # Check Git config
    $gitName = & git config user.name 2>$null
    $gitEmail = & git config user.email 2>$null
    
    $gitConfigOk = $gitName -and $gitEmail
    Write-Check "Git Config (name/email)" $gitConfigOk "" "Run: git config --global user.name 'Your Name' && git config --global user.email 'your@email.com'"
    if (-not $gitConfigOk) { $warningsFound++ }

    # Check defaultBranch
    $defaultBranch = & git config init.defaultBranch 2>$null
    if ($defaultBranch) {
        Write-Check "Git defaultBranch" $true $defaultBranch
    }

    # Check core.autocrlf
    $autocrlf = & git config core.autocrlf 2>$null
    if ($autocrlf) {
        Write-Check "Git core.autocrlf" $true $autocrlf
    }
} else {
    Write-Check "Git Installed" $false "" "Install Git from https://git-scm.com"
    $issuesFound++
}

# ==================== Docker ====================
Write-Host "`n  Docker:" -ForegroundColor Cyan
$dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
if ($dockerCmd) {
    $dockerVersion = & docker --version 2>$null
    Write-Check "Docker CLI" $true ($dockerVersion -replace '^Docker version ','' -replace ',.*$','')
    
    # Check if daemon is running
    $null = & docker info 2>$null
    $dockerRunning = $LASTEXITCODE -eq 0
    Write-Check "Docker Daemon" $dockerRunning "" "Start Docker Desktop"
    if (-not $dockerRunning) { $warningsFound++ }

    # Check docker compose
    $composeCmd = Get-Command docker-compose -ErrorAction SilentlyContinue
    if (-not $composeCmd) {
        $composePlugin = & docker compose version 2>$null
        if ($LASTEXITCODE -eq 0) { $composeCmd = $true }
    }
    if ($composeCmd) {
        Write-Check "Docker Compose" $true "Installed"
    } else {
        Write-Check "Docker Compose" $false "" "Install Docker Compose"
    }
} else {
    Write-Check "Docker" $false "" "Install Docker Desktop from https://docker.com"
    $warningsFound++
}

# ==================== VS Code ====================
Write-Host "`n  Editors:" -ForegroundColor Cyan
$codeCmd = Get-Command code -ErrorAction SilentlyContinue
if ($codeCmd) {
    $codeVersion = & code --version 2>$null | Select-Object -First 1
    Write-Check "VS Code" $true $codeVersion
} else {
    Write-Check "VS Code" $false "" "Install from https://code.visualstudio.com"
}

$cursorCmd = Get-Command cursor -ErrorAction SilentlyContinue
if ($cursorCmd) {
    Write-Check "Cursor" $true "Installed"
}

# ==================== GitHub CLI ====================
$ghCmd = Get-Command gh -CommandType Application -ErrorAction SilentlyContinue | 
    Where-Object { $_.Source -match '\.(exe|cmd|bat|com)$' } | 
    Select-Object -First 1
if ($ghCmd) {
    try {
        $ghOutput = & $ghCmd.Source --version 2>$null
        $ghVersion = $ghOutput | Select-Object -First 1
        Write-Check "GitHub CLI" $true ($ghVersion -replace '^gh version ','')
    } catch {
        Write-Check "GitHub CLI" $false "" "Optional - Install from https://cli.github.com"
    }
} else {
    Write-Check "GitHub CLI" $false "" "Optional - Install from https://cli.github.com"
}

# ==================== Python (optional) ====================
Write-Host "`n  Python:" -ForegroundColor Cyan
$pythonCmd = Get-Command python -ErrorAction SilentlyContinue
if (-not $pythonCmd) { $pythonCmd = Get-Command python3 -ErrorAction SilentlyContinue }
if ($pythonCmd) {
    $pythonVersion = & $pythonCmd.Source --version 2>&1
    if ($pythonVersion -match 'Python (\d+\.\d+\.\d+)') {
        Write-Check "Python Installed" $true $matches[1]
    } else {
        Write-Check "Python Installed" $true "Unknown version"
    }
} else {
    Write-Check "Python" $false "" "Optional - Install from https://python.org if needed"
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
try {
    $execPolicy = Get-ExecutionPolicy
} catch {
    $execPolicy = "Unknown"
}
$execPolicyOk = $execPolicy -in @('RemoteSigned', 'Unrestricted', 'Bypass', 'AllSigned')
Write-Check "Execution Policy" $execPolicyOk $execPolicy "Run: Set-ExecutionPolicy RemoteSigned -Scope CurrentUser"
if (-not $execPolicyOk) { $warningsFound++ }

# Disk space
$systemDrive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'"
$freeSpaceGB = [math]::Round($systemDrive.FreeSpace / 1GB, 1)
$totalSpaceGB = [math]::Round($systemDrive.Size / 1GB, 1)
$diskOk = $freeSpaceGB -gt 10
Write-Check "Disk Space (C:)" $diskOk "$freeSpaceGB GB free / $totalSpaceGB GB total" "Free up disk space"
if (-not $diskOk) { $warningsFound++ }

# RAM
$totalRAM = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
Write-Check "Memory (RAM)" ($totalRAM -ge 8) "$totalRAM GB total" "Consider upgrading to 16GB+ for development"
if ($totalRAM -lt 8) { $warningsFound++ }

# WSL
$wslCheck = Get-Command wsl -ErrorAction SilentlyContinue
if ($wslCheck) {
    Write-Check "WSL" $true "Installed"
} else {
    Write-Check "WSL" $false "" "Optional - Install WSL for Linux development"
}

# ==================== Summary ====================
Write-Host "`n  ===================================" -ForegroundColor Cyan
if ($issuesFound -eq 0 -and $warningsFound -eq 0) {
    Write-Host "  [OK] All checks passed!" -ForegroundColor Green
    Write-Host "  Your development environment looks good." -ForegroundColor Gray
} elseif ($issuesFound -eq 0) {
    Write-Host "  [!] $warningsFound warning(s) found" -ForegroundColor Yellow
    Write-Host "  Your environment works but could be improved." -ForegroundColor Gray
} else {
    Write-Host "  [FAIL] $issuesFound issue(s) and $warningsFound warning(s) found" -ForegroundColor Red
    Write-Host "  Please address the issues above." -ForegroundColor Gray
}
Write-Host "  ===================================`n" -ForegroundColor Cyan

# Exit with error code if issues found
if ($issuesFound -gt 0) {
    exit 1
}
