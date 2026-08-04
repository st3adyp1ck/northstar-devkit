#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Northstar DevKit - Portable Installer
.DESCRIPTION
    Installs DevKit permanently on this machine from a copy that was either
    built by Build-UsbPortable.ps1 (a curated folder meant for a flash drive)
    or a plain git clone - both layouts work, since this script only ever
    reads its own directory ($PSScriptRoot) as the source.

    What it does, in order:
      1. Copies the toolkit to a permanent per-user location (default
         %LOCALAPPDATA%\Programs\NorthstarDevKit) - never the flash drive
         itself, so nothing breaks when the drive is unplugged.
      2. Adds that location to the user's PATH (same dedupe-safe logic as
         Setup-Path.bat, just targeting the new permanent location instead
         of wherever this script happened to run from).
      3. Optionally creates Start Menu / Desktop shortcuts for the GUI and
         the classic terminal menu.
      4. Optionally runs the two existing opt-in integrations from their
         NEW location - system\Install-ShellIntegration.ps1 (Explorer
         right-click) and system\Register-DevKitTerminalProfile.ps1
         (Windows Terminal profile) - so their registered commands point at
         the permanent install, not the transient source.

    Every change is per-user (HKCU registry, user PATH, %LOCALAPPDATA%,
    %APPDATA%\...\Start Menu) - no administrator privileges are used or
    required anywhere in this script. Settings/projects data
    (%LOCALAPPDATA%\NorthstarDevKit\settings.json) lives in a DIFFERENT
    folder than the program files, so re-running this (to update an
    existing install) never touches user data.

    Safe to re-run: copying is idempotent, PATH-adding is dedupe-checked,
    and shortcuts/integrations simply get rewritten with the same content.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Destination
    Where to install DevKit. Defaults to %LOCALAPPDATA%\Programs\NorthstarDevKit.
.PARAMETER Silent
    No prompts. PATH and shortcuts are still applied (pass -SkipPath /
    -SkipShortcuts to turn those off too); the two opt-in integrations
    (shell right-click, Terminal profile) stay OFF unless you also pass
    -AddShellIntegration / -AddTerminalProfile - matches how those two are
    opt-in everywhere else in DevKit.
.PARAMETER SkipPath
    Don't add the install location to PATH.
.PARAMETER AddShellIntegration
    Also add the Explorer "Open Northstar DevKit Here" right-click entry.
.PARAMETER AddTerminalProfile
    Also register the Windows Terminal profile.
.PARAMETER SkipShortcuts
    Don't create Start Menu / Desktop shortcuts.
.PARAMETER NoDesktopShortcut
    Create the Start Menu shortcuts but skip the Desktop one.
.EXAMPLE
    .\Install.ps1
.EXAMPLE
    .\Install.ps1 -Silent -AddShellIntegration -AddTerminalProfile
.EXAMPLE
    .\Install.ps1 -Destination "D:\Tools\DevKit" -Silent
#>
[CmdletBinding()]
param(
    [string]$Destination,
    [switch]$Silent,
    [switch]$SkipPath,
    [switch]$AddShellIntegration,
    [switch]$AddTerminalProfile,
    [switch]$SkipShortcuts,
    [switch]$NoDesktopShortcut
)

$ErrorActionPreference = 'Stop'
$SourceDir = $PSScriptRoot
. (Join-Path $SourceDir "lib\DevKit-Common.ps1")

Write-DevKitHeader "Portable Installer"
Write-Host "  No administrator privileges are used or required - everything below is" -ForegroundColor Gray
Write-Host "  per-user (registry HKCU, user PATH, %LOCALAPPDATA%, your own Start Menu)." -ForegroundColor Gray
Write-Host ""

$destinationExplicit = $PSBoundParameters.ContainsKey('Destination')
if (-not $destinationExplicit) {
    $Destination = Join-Path $env:LOCALAPPDATA "Programs\NorthstarDevKit"
}
if (-not $Silent -and -not $destinationExplicit) {
    $typed = Read-Host "  Install location [$Destination]"
    if (-not [string]::IsNullOrWhiteSpace($typed)) { $Destination = $typed }
}
$Destination = [System.IO.Path]::GetFullPath($Destination)

# ==================== 1. COPY FILES ====================

$sourceResolved = [System.IO.Path]::GetFullPath($SourceDir)
if ($sourceResolved.TrimEnd('\') -ieq $Destination.TrimEnd('\')) {
    Write-DevKitInfo "Already running from the install location - skipping the copy step."
} else {
    Write-DevKitStep "Copying DevKit to $Destination"
    if (-not (Test-Path $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }
    # /E copies subfolders including empty ones; /XD excludes dev-only/VCS
    # directories that don't belong in an installed copy; /NFL /NDL /NJH /NJS
    # silence robocopy's normally very chatty per-file logging; /R:1 /W:1 keep
    # a locked file (e.g. this script's own console host) from stalling the
    # whole copy for robocopy's 1-million-millisecond default retry window.
    $excludeDirs = @('.git', '.kimi', '.github', 'tests', 'USB', '.vscode', '.idea')
    $robocopyArgs = @($SourceDir, $Destination, '/E', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/XD') + $excludeDirs
    & robocopy @robocopyArgs | Out-Null
    # Robocopy's exit codes are a bitmask where 0-7 all mean success (some
    # combination of "files copied"/"extra files"/"mismatched"); only 8+
    # indicates a real failure.
    if ($LASTEXITCODE -ge 8) {
        Write-DevKitError "robocopy failed (exit $LASTEXITCODE)"
        exit 1
    }
    Write-DevKitDone
}

# ==================== 2. PATH ====================

if ($SkipPath) {
    Write-DevKitSkip
} else {
    Write-DevKitStep "Adding $Destination to PATH"
    $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
    $entries = @($userPath -split ';' | Where-Object { $_ })
    $normDest = $Destination.TrimEnd('\')
    $alreadyAdded = @($entries | Where-Object { $_.Trim().TrimEnd('\') -ieq $normDest }).Count -gt 0
    if ($alreadyAdded) {
        Write-Host " (already there)" -ForegroundColor Gray
    } else {
        [Environment]::SetEnvironmentVariable('PATH', ($entries + $Destination) -join ';', 'User')
        Write-DevKitDone
    }
}

# ==================== 3. SHORTCUTS ====================

if ($SkipShortcuts) {
    Write-DevKitSkip
} else {
    Write-DevKitStep "Creating Start Menu shortcuts"
    try {
        $startMenuDir = Join-Path ([Environment]::GetFolderPath('StartMenu')) "Programs\Northstar DevKit"
        if (-not (Test-Path $startMenuDir)) { New-Item -ItemType Directory -Path $startMenuDir -Force | Out-Null }
        $iconPath = Join-Path $Destination "gui\Assets\logo.ico"
        $wsh = New-Object -ComObject WScript.Shell

        $guiShortcut = $wsh.CreateShortcut((Join-Path $startMenuDir "Northstar DevKit.lnk"))
        $guiShortcut.TargetPath = Join-Path $Destination "DevKit-GUI.bat"
        $guiShortcut.WorkingDirectory = $Destination
        if (Test-Path $iconPath) { $guiShortcut.IconLocation = $iconPath }
        $guiShortcut.Description = "Northstar DevKit - Desktop GUI"
        $guiShortcut.Save()

        $tuiShortcut = $wsh.CreateShortcut((Join-Path $startMenuDir "Northstar DevKit (Terminal).lnk"))
        $tuiShortcut.TargetPath = Join-Path $Destination "DevKit.bat"
        $tuiShortcut.WorkingDirectory = $Destination
        if (Test-Path $iconPath) { $tuiShortcut.IconLocation = $iconPath }
        $tuiShortcut.Description = "Northstar DevKit - Terminal Menu"
        $tuiShortcut.Save()

        if (-not $NoDesktopShortcut) {
            $desktopShortcut = $wsh.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) "Northstar DevKit.lnk"))
            $desktopShortcut.TargetPath = Join-Path $Destination "DevKit-GUI.bat"
            $desktopShortcut.WorkingDirectory = $Destination
            if (Test-Path $iconPath) { $desktopShortcut.IconLocation = $iconPath }
            $desktopShortcut.Description = "Northstar DevKit - Desktop GUI"
            $desktopShortcut.Save()
        }
        Write-DevKitDone
    } catch {
        Write-DevKitError "$_"
    }
}

# ==================== 4. OPT-IN INTEGRATIONS ====================
# Both scripts below are run from the NEW ($Destination) copy, not the
# source - so the registry command / Terminal profile they write points at
# the permanent install, never at a flash drive or temp checkout.

$wantShellIntegration = $AddShellIntegration
$wantTerminalProfile = $AddTerminalProfile
if (-not $Silent) {
    if (-not $wantShellIntegration) {
        $answer = Read-Host "  Add 'Open Northstar DevKit Here' to the Explorer right-click menu? (y/N)"
        $wantShellIntegration = ($answer -eq 'y')
    }
    if (-not $wantTerminalProfile) {
        $answer = Read-Host "  Register a Windows Terminal profile? (y/N)"
        $wantTerminalProfile = ($answer -eq 'y')
    }
}

if ($wantShellIntegration) {
    # Always -Force here: consent was already gathered above, either via the
    # y/N prompt just asked or an explicit -AddShellIntegration switch - a
    # second confirmation from the sub-script would just be a redundant gate.
    Write-DevKitStep "Explorer right-click integration"
    Write-Host ""
    & (Join-Path $Destination "system\Install-ShellIntegration.ps1") -Force
}
if ($wantTerminalProfile) {
    Write-DevKitStep "Windows Terminal profile"
    Write-Host ""
    & (Join-Path $Destination "system\Register-DevKitTerminalProfile.ps1")
}

# ==================== DONE ====================

Write-Host ""
Write-Host "  DONE - Northstar DevKit is installed at:" -ForegroundColor Green
Write-Host "    $Destination" -ForegroundColor Gray
Write-Host ""
Write-Host "  Open a NEW terminal window and run 'devkit' (or 'devkit-gui'), or find" -ForegroundColor Green
Write-Host "  Northstar DevKit in your Start Menu." -ForegroundColor Green
Write-Host ""
