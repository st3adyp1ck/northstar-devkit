#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Builds the portable USB/ distribution folder - Northstar DevKit
.DESCRIPTION
    Assembles a clean, current copy of the toolkit into USB/ (gitignored,
    regenerated on demand - never hand-maintained) with dev-only clutter
    stripped out: no .git, no .kimi (AI-session scratch files), no .github,
    no tests/ (Pester isn't needed at runtime), no editor folders.

    The result is meant to be copied wholesale onto a flash drive: carry it
    to any Windows machine, copy USB/ over, and run Install.ps1 (or
    Install.bat) from the copy to install DevKit there permanently - PATH,
    Start Menu shortcuts, and the two opt-in system integrations.

    Uses robocopy /MIR so re-running this after files are renamed/removed
    from the repo doesn't leave stale copies behind in USB/ - the folder
    always matches the current repo exactly (minus the exclusions above).

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER OutputDir
    Where to build the portable folder. Defaults to USB/ next to this script.
.EXAMPLE
    .\Build-UsbPortable.ps1
#>
[CmdletBinding()]
param(
    [string]$OutputDir
)

$ErrorActionPreference = 'Stop'
$RepoRoot = $PSScriptRoot
. (Join-Path $RepoRoot "lib\DevKit-Common.ps1")

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $RepoRoot "USB"
}
$OutputDir = [System.IO.Path]::GetFullPath($OutputDir)

Write-DevKitHeader "Build Portable USB Folder"

$excludeDirs = @('.git', '.kimi', '.github', 'tests', 'USB', '.vscode', '.idea')
Write-DevKitInfo "Source : $RepoRoot"
Write-DevKitInfo "Output : $OutputDir"
Write-DevKitInfo ("Excluding: {0}" -f ($excludeDirs -join ', '))
Write-Host ""

Write-DevKitStep "Mirroring into USB"
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
# /MIR keeps the output in exact sync with the repo (deletes anything in USB/
# that no longer exists in source) - safe here because everything under USB/
# is generated, never hand-edited. /XD applies to both source scan and
# destination cleanup, so excluded folders are never touched either way.
$robocopyArgs = @($RepoRoot, $OutputDir, '/MIR', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/XD') + $excludeDirs
& robocopy @robocopyArgs | Out-Null
if ($LASTEXITCODE -ge 8) {
    Write-DevKitError "robocopy failed (exit $LASTEXITCODE)"
    exit 1
}
Write-DevKitDone

$fileCount = (Get-ChildItem -Path $OutputDir -Recurse -File).Count
$sizeMb = [math]::Round(((Get-ChildItem -Path $OutputDir -Recurse -File | Measure-Object -Property Length -Sum).Sum) / 1MB, 1)

Write-Host ""
Write-Host "  DONE - $fileCount files, $sizeMb MB, ready at:" -ForegroundColor Green
Write-Host "    $OutputDir" -ForegroundColor Gray
Write-Host ""
Write-Host "  Copy that folder onto a flash drive. On each machine: copy it over," -ForegroundColor Green
Write-Host "  then run Install.bat (or Install.ps1) from inside the copy." -ForegroundColor Green
Write-Host ""
