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


$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
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

function Get-DevKitToolVersion {
    <#
    .SYNOPSIS
        Safely invokes `<Path> <ArgumentList>` (e.g. --version) and validates
        the result instead of assuming success just because the binary resolved.
    .DESCRIPTION
        Wraps the native call in try/catch (a corrupted/non-executable binary
        throws rather than crashing the caller) and only reports Responding =
        $true when the process exits cleanly AND its output matches Pattern.
        This lets callers distinguish "installed and healthy" from "resolves
        via Get-Command but is a dangling/broken shim".
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [string[]]$ArgumentList = @('--version'),

        [Parameter(Mandatory = $true)]
        [string]$Pattern
    )

    $result = [PSCustomObject]@{
        Responding = $false
        ExitOk     = $false
        Output     = $null
        Version    = $null
    }

    try {
        $rawOutput = & $Path @ArgumentList 2>&1
        $exitCode = $LASTEXITCODE
        $firstLine = $rawOutput | Select-Object -First 1
        if ($null -ne $firstLine) { $result.Output = "$firstLine" }

        $result.ExitOk = ($exitCode -eq 0 -or $null -eq $exitCode)

        if ($result.ExitOk -and $result.Output -and ($result.Output -match $Pattern)) {
            $result.Responding = $true
            $result.Version = $matches[1]
        }
    } catch {
        # Native invocation threw (corrupted / non-executable binary, etc.)
        # Leave Responding/ExitOk = $false so callers report a clean failure.
    }

    return $result
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
$psMessage = "v$($psVersion.ToString())"
if (-not $ps7Installed) {
    # This host is running Windows PowerShell 5.1, but PS7 may still be
    # installed system-wide (e.g. the .bat launcher didn't find pwsh).
    # Only report the "install PS7" hint if pwsh truly isn't present.
    $pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwshCmd) {
        $ps7Installed = $true
        $psMessage = "v$($psVersion.ToString()) (PowerShell 7 is installed, but this session launched under Windows PowerShell)"
    }
}
Write-Check "PowerShell Version" $ps7Installed $psMessage "Install PowerShell 7 from https://aka.ms/powershell"
if (-not $ps7Installed) { $issuesFound++ }

# ==================== Node.js ====================
Write-Host "`n  Node.js:" -ForegroundColor Cyan
$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if ($nodeCmd) {
    $nodeCheck = Get-DevKitToolVersion -Path $nodeCmd.Source -ArgumentList @('--version') -Pattern '^v?(\d+\.\d+\.\d+)'
    if ($nodeCheck.Responding) {
        $versionNum = [version]$nodeCheck.Version
        $nodeCurrent = $versionNum.Major -ge 20
        Write-Check "Node.js Installed" $true "v$($nodeCheck.Version)"
        Write-Check "Node.js Version (20+)" $nodeCurrent "v$versionNum" "Update Node.js from https://nodejs.org"
        if (-not $nodeCurrent) { $warningsFound++ }
    } elseif ($nodeCheck.Output) {
        # Node responded but the output didn't match the expected version
        # pattern (e.g. a pre-release/RC build). Best-effort major-version
        # extraction instead of silently skipping the adequacy check.
        Write-Check "Node.js Installed" $true $nodeCheck.Output
        if ($nodeCheck.Output -match '(\d+)\.\d+') {
            $nodeMajor = [int]$matches[1]
            $nodeCurrent = $nodeMajor -ge 20
            Write-Check "Node.js Version (20+)" $nodeCurrent "v$($nodeCheck.Output)" "Update Node.js from https://nodejs.org"
            if (-not $nodeCurrent) { $warningsFound++ }
        } else {
            Write-Check "Node.js Version (20+)" $false "Unknown - could not parse version" "Update Node.js from https://nodejs.org"
            $warningsFound++
        }
    } else {
        Write-Check "Node.js Installed" $false "Found but not responding" "Reinstall Node.js from https://nodejs.org"
        $issuesFound++
    }
} else {
    Write-Check "Node.js Installed" $false "" "Install Node.js from https://nodejs.org"
    $issuesFound++
}

# NPM
$npmCmd = Get-Command npm -ErrorAction SilentlyContinue
if ($npmCmd) {
    $npmCheck = Get-DevKitToolVersion -Path $npmCmd.Source -ArgumentList @('--version') -Pattern '^(\d+\.\d+\.\d+)'
    if ($npmCheck.Responding) {
        Write-Check "NPM Installed" $true "v$($npmCheck.Version)"
    } else {
        Write-Check "NPM Installed" $false "Found but not responding" "Reinstall Node.js (includes NPM)"
        $issuesFound++
    }
} else {
    Write-Check "NPM Installed" $false "" "Reinstall Node.js (includes NPM)"
    $issuesFound++
}

# Yarn/PNPM/Bun (optional but nice)
$yarnCmd = Get-Command yarn -ErrorAction SilentlyContinue
if ($yarnCmd) {
    $yarnCheck = Get-DevKitToolVersion -Path $yarnCmd.Source -ArgumentList @('--version') -Pattern '(\d+\.\d+\.\d+)'
    if ($yarnCheck.Responding) {
        Write-Check "Yarn Installed" $true "v$($yarnCheck.Version)"
    } else {
        Write-Check "Yarn Installed" $false "Found but not responding"
    }
}

$pnpmCmd = Get-Command pnpm -ErrorAction SilentlyContinue
if ($pnpmCmd) {
    $pnpmCheck = Get-DevKitToolVersion -Path $pnpmCmd.Source -ArgumentList @('--version') -Pattern '(\d+\.\d+\.\d+)'
    if ($pnpmCheck.Responding) {
        Write-Check "PNPM Installed" $true "v$($pnpmCheck.Version)"
    } else {
        Write-Check "PNPM Installed" $false "Found but not responding"
    }
}

$bunCmd = Get-Command bun -ErrorAction SilentlyContinue
if ($bunCmd) {
    $bunCheck = Get-DevKitToolVersion -Path $bunCmd.Source -ArgumentList @('--version') -Pattern '(\d+\.\d+\.\d+)'
    if ($bunCheck.Responding) {
        Write-Check "Bun Installed" $true "v$($bunCheck.Version)"
    } else {
        Write-Check "Bun Installed" $false "Found but not responding"
    }
}

# ==================== Git ====================
Write-Host "`n  Git:" -ForegroundColor Cyan
$gitCmd = Get-Command git -ErrorAction SilentlyContinue
if ($gitCmd) {
    $gitCheck = Get-DevKitToolVersion -Path $gitCmd.Source -ArgumentList @('--version') -Pattern 'git version (\d+\.\d+(?:\.\d+)?)'
    if ($gitCheck.Responding) {
        Write-Check "Git Installed" $true $gitCheck.Version
    } else {
        Write-Check "Git Installed" $false "Found but not responding" "Reinstall Git from https://git-scm.com"
        $issuesFound++
    }

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
    $dockerCheck = Get-DevKitToolVersion -Path $dockerCmd.Source -ArgumentList @('--version') -Pattern 'Docker version (\d+\.\d+\.\d+)'
    if ($dockerCheck.Responding) {
        Write-Check "Docker CLI" $true $dockerCheck.Version
    } else {
        Write-Check "Docker CLI" $false "Found but not responding" "Reinstall Docker Desktop from https://docker.com"
        $warningsFound++
    }

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
    $codeCheck = Get-DevKitToolVersion -Path $codeCmd.Source -ArgumentList @('--version') -Pattern '(\d+\.\d+\.\d+)'
    if ($codeCheck.Responding) {
        Write-Check "VS Code" $true $codeCheck.Version
    } else {
        Write-Check "VS Code" $false "Found but not responding" "Install from https://code.visualstudio.com"
    }
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
    $pythonCheck = Get-DevKitToolVersion -Path $pythonCmd.Source -ArgumentList @('--version') -Pattern 'Python (\d+\.\d+\.\d+)'
    if ($pythonCheck.Responding) {
        Write-Check "Python Installed" $true $pythonCheck.Version
    } elseif ($pythonCheck.ExitOk) {
        # Ran cleanly but the output didn't look like a Python version banner.
        Write-Check "Python Installed" $true "Unknown version"
    } else {
        # Non-zero exit code - most likely the Windows "App Execution Alias"
        # stub at %LOCALAPPDATA%\Microsoft\WindowsApps\python.exe, which
        # exists even when Python is NOT installed and just prints a
        # Microsoft Store redirect message instead of a version string.
        Write-Check "Python" $false "" "Optional - Install from https://python.org if needed"
    }
} else {
    Write-Check "Python" $false "" "Optional - Install from https://python.org if needed"
}

# ==================== System ====================
Write-Host "`n  System:" -ForegroundColor Cyan

# Windows version
try {
    $osInfo = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $windowsVersion = $osInfo.Caption
    $windowsBuild = [System.Environment]::OSVersion.Version
    Write-Check "Windows Version" ($windowsBuild.Major -ge 10) $windowsVersion
} catch {
    Write-Check "Windows Version" $false "Could not query WMI/CIM" "Check that the WMI/Winmgmt service is running"
    $warningsFound++
}

# Admin check
$isAdmin = Test-DevKitAdmin
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
try {
    $systemDrive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'" -ErrorAction Stop
    if (-not $systemDrive) { throw "No disk information returned for $($env:SystemDrive)" }
    $freeSpaceGB = [math]::Round($systemDrive.FreeSpace / 1GB, 1)
    $totalSpaceGB = [math]::Round($systemDrive.Size / 1GB, 1)
    $diskOk = $freeSpaceGB -gt 10
    Write-Check "Disk Space (C:)" $diskOk "$freeSpaceGB GB free / $totalSpaceGB GB total" "Free up disk space"
    if (-not $diskOk) { $warningsFound++ }
} catch {
    Write-Check "Disk Space (C:)" $false "Could not query WMI/CIM" "Check that the WMI/Winmgmt service is running"
    $warningsFound++
}

# RAM
try {
    $totalRAM = [math]::Round((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory / 1GB, 1)
    Write-Check "Memory (RAM)" ($totalRAM -ge 8) "$totalRAM GB total" "Consider upgrading to 16GB+ for development"
    if ($totalRAM -lt 8) { $warningsFound++ }
} catch {
    Write-Check "Memory (RAM)" $false "Could not query WMI/CIM" "Check that the WMI/Winmgmt service is running"
    $warningsFound++
}

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
