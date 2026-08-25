#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Start Package Script - Northstar DevKit
.DESCRIPTION
    The daily-driver "npm run" picker: lists the scripts defined in the
    project's package.json and runs the chosen one with the project's
    detected package manager (npm/yarn/pnpm/bun).

    Run with no -Name to pick a script from the interactive menu, or pass
    -Name to run one directly. This runs the project's OWN script
    verbatim (whatever the package.json author put there) - DevKit adds
    nothing to it and never installs, deletes, or modifies anything.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Path
    The project directory containing package.json. Defaults to current directory.
.PARAMETER Name
    The script name to run (e.g. "dev", "build"). When empty, an
    interactive picker is shown.
.EXAMPLE
    .\Start-PackageScript.ps1
    .\Start-PackageScript.ps1 -Path "C:\my-project" -Name "build"
#>
[CmdletBinding()]
param(
    [string]$Path = ".",
    [string]$Name = ""
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

try {
    $targetPath = Resolve-DevKitDirectory -Path $Path
} catch {
    Write-DevKitHeader "Run Package Script"
    Write-DevKitError $_
    exit 1
}

Write-DevKitHeader "Run Package Script"
Write-DevKitInfo "Path: $targetPath"

$packageJsonPath = Join-Path $targetPath "package.json"
if (-not (Test-Path $packageJsonPath)) {
    Write-DevKitError "No package.json found in '$targetPath'."
    exit 1
}

try {
    $packageJson = Get-Content $packageJsonPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
} catch {
    Write-DevKitError "Could not parse package.json: $_"
    exit 1
}

$scriptNames = @()
if ($packageJson.PSObject.Properties.Name -contains "scripts" -and $packageJson.scripts) {
    $scriptNames = @($packageJson.scripts.PSObject.Properties.Name)
}

if ($scriptNames.Count -eq 0) {
    Write-DevKitError "package.json defines no scripts."
    exit 1
}

$scriptName = $Name
if ([string]::IsNullOrWhiteSpace($scriptName)) {
    Write-Host "  Scripts in package.json:" -ForegroundColor Cyan
    Write-Host ""
    $entries = @()
    for ($i = 0; $i -lt $scriptNames.Count; $i++) {
        $n = $scriptNames[$i]
        $entries += @{ Key = [string]($i + 1); Label = "$n  ->  $($packageJson.scripts.$n)" }
    }
    $entries += @{ Key = '0'; Label = 'Cancel' }

    $choice = (Show-DevKitInteractiveMenu -Entries $entries -PromptLabel 'Select a script to run').Trim()
    if ($choice -eq '0' -or [string]::IsNullOrWhiteSpace($choice)) {
        Write-DevKitInfo "Cancelled."
        exit 0
    }
    if (-not ($choice -match '^\d+$') -or [int]$choice -lt 1 -or [int]$choice -gt $scriptNames.Count) {
        Write-DevKitError "Invalid selection: $choice"
        exit 1
    }
    $scriptName = $scriptNames[[int]$choice - 1]
}

if ($scriptNames -notcontains $scriptName) {
    Write-DevKitError "Script '$scriptName' not found in package.json."
    Write-DevKitInfo "Available: $($scriptNames -join ', ')"
    exit 1
}

$manager = Get-DevKitPackageManager -Path $targetPath
Write-DevKitInfo "Package manager: $($manager.Command)"
Write-Host "`n  Running '$scriptName'...`n" -ForegroundColor Green

Invoke-DevKitInDirectory -Path $targetPath -ScriptBlock {
    try {
        if (-not (Test-DevKitCommand $manager.Command)) {
            throw "$($manager.Command) is not installed or not in PATH."
        }
        # 'run <name>' works for npm and pnpm; yarn and bun also accept it
        # (their bare-name shorthand is just sugar over the same subcommand).
        & $manager.Command @("run", $scriptName)
        if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            Write-DevKitError "Script '$scriptName' exited with code $LASTEXITCODE"
            exit $LASTEXITCODE
        }
    } catch {
        Write-DevKitError $_
        exit 1
    }
}
