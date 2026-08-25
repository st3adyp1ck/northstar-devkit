#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Northstar DevKit - Installer
.DESCRIPTION
    Installs Northstar DevKit as a real Windows application: the companion
    widget is the main face of the app, so every shortcut this creates opens
    the widget directly (its single-instance summon event simply surfaces an
    already-running instance).

    What it does, step by step:
      0. Welcome / permissions screen - the install is fully per-user
         (HKCU registry, user PATH, %LOCALAPPDATA%, your own Start Menu), so
         NO administrator privileges are used or required. The few tools that
         need admin (WiFi optimize, SFC/DISM, hosts file) ask Windows for
         elevation themselves, at runtime, when you run them.
      1. Install location (default %LOCALAPPDATA%\Programs\NorthstarDevKit).
      2. Options (start with Windows, desktop shortcut, PATH, opt-in
         Explorer/Terminal integrations).
      3. Copies the toolkit to the install location - works identically from
         a git clone or a USB/ portable build, since it only ever reads its
         own directory ($PSScriptRoot) as the source.
      4. Registers the app with Windows (HKCU ...\Uninstall\<ArpKeyName>) so
         it appears in Settings > Apps and can be uninstalled from there.
      5. Start Menu + Desktop shortcuts - the main "Northstar DevKit" icon
         opens the WIDGET; "Control Center" and "Terminal" variants open the
         full GUI and the classic menu.
      6. Adds the install location to the user PATH (dedupe-checked).
      7. Optional "Start with Windows" (the widget's Run-key entry).
      8. Optional opt-in integrations, run from the NEW location so their
         registered commands point at the permanent install.

    Safe to re-run: copying is idempotent, PATH-adding is dedupe-checked,
    and shortcuts/registration simply get rewritten with current content -
    re-running over an existing install is the supported upgrade path.
    Settings/projects/notes data (%LOCALAPPDATA%\NorthstarDevKit\) lives in
    a DIFFERENT folder than the program files and is never touched here.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Destination
    Where to install DevKit. Defaults to %LOCALAPPDATA%\Programs\NorthstarDevKit.
.PARAMETER Silent
    No prompts. Defaults apply: shortcuts on, PATH on, start-with-Windows on,
    opt-in integrations OFF unless -AddShellIntegration / -AddTerminalProfile.
.PARAMETER NoStartWithWindows
    Don't register the widget to start at logon.
.PARAMETER SkipPath
    Don't add the install location to the user PATH.
.PARAMETER SkipShortcuts
    Don't create Start Menu / Desktop shortcuts.
.PARAMETER NoDesktopShortcut
    Create the Start Menu shortcuts but skip the Desktop one.
.PARAMETER AddShellIntegration
    Also add the Explorer "Open Northstar DevKit Here" right-click entry.
.PARAMETER AddTerminalProfile
    Also register the Windows Terminal profile.
.PARAMETER ArpKeyName
    Registry key name under HKCU\...\Uninstall. Default "NorthstarDevKit";
    override only for side-by-side test installs.
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
    [switch]$NoStartWithWindows,
    [switch]$SkipPath,
    [switch]$SkipShortcuts,
    [switch]$NoDesktopShortcut,
    [switch]$AddShellIntegration,
    [switch]$AddTerminalProfile,
    [string]$ArpKeyName = 'NorthstarDevKit'
)

$ErrorActionPreference = 'Stop'
$SourceDir = $PSScriptRoot
. (Join-Path $SourceDir "tools\lib\DevKit-Common.ps1")

$AppVersion = 'unknown'
try {
    $rawVersion = (Get-Content -Path (Join-Path $SourceDir "VERSION") -Raw -ErrorAction Stop).Trim()
    if (-not [string]::IsNullOrWhiteSpace($rawVersion)) { $AppVersion = $rawVersion }
} catch { }

# Steps 1-2 (location + options) are interactive only; in -Silent mode the
# defaults below apply unchanged. Steps 3+ run the same either way.
$totalSteps = 8
$step = 0
function Show-InstallStep([string]$Name) {
    $script:step++
    Write-Host ""
    Write-Host "  Step $script:step of $totalSteps - $Name" -ForegroundColor Cyan
    Write-Host ("  " + ("-" * 52)) -ForegroundColor DarkGray
}

# ==================== STEP 0: WELCOME / PERMISSIONS ====================

Write-DevKitHeader "Northstar DevKit Installer"
Write-Host "  This installs Northstar DevKit as a real Windows app. The companion" -ForegroundColor Gray
Write-Host "  widget is the main face: your Start Menu/Desktop icon opens it directly." -ForegroundColor Gray
Write-Host ""
Write-Host "  Permissions:" -ForegroundColor White
Write-Host "    - The install is fully per-user (HKCU registry, your PATH, your Start" -ForegroundColor Gray
Write-Host "      Menu, %LOCALAPPDATA%). No administrator rights are needed now." -ForegroundColor Gray
Write-Host "    - A few individual tools (WiFi optimize, system repair, hosts file)" -ForegroundColor Gray
Write-Host "      need admin - they ask Windows for elevation themselves, only when" -ForegroundColor Gray
Write-Host "      you actually run them." -ForegroundColor Gray
Write-Host "    - Uninstall any time from Settings > Apps > Northstar DevKit - it" -ForegroundColor Gray
Write-Host "      removes every trace this installer creates." -ForegroundColor Gray

# ==================== STEP 1: INSTALL LOCATION ====================

Show-InstallStep "Install location"
$destinationExplicit = $PSBoundParameters.ContainsKey('Destination')
if (-not $destinationExplicit) {
    $Destination = Join-Path $env:LOCALAPPDATA "Programs\NorthstarDevKit"
}
if (-not $Silent -and -not $destinationExplicit) {
    $typed = Read-Host "  Install location [$Destination]"
    if (-not [string]::IsNullOrWhiteSpace($typed)) { $Destination = $typed }
}
$Destination = [System.IO.Path]::GetFullPath($Destination)
Write-Host "  $Destination" -ForegroundColor Gray

# ==================== STEP 2: OPTIONS ====================

Show-InstallStep "Options"
$wantStartWithWindows = -not $NoStartWithWindows
$wantShellIntegration = $AddShellIntegration
$wantTerminalProfile = $AddTerminalProfile
if (-not $Silent) {
    $answer = Read-Host "  Start the widget automatically when you sign in? (Y/n)"
    if ($answer -eq 'n') { $wantStartWithWindows = $false }
    if (-not $wantShellIntegration) {
        $answer = Read-Host "  Add 'Open Northstar DevKit Here' to the Explorer right-click menu? (y/N)"
        $wantShellIntegration = ($answer -eq 'y')
    }
    if (-not $wantTerminalProfile) {
        $answer = Read-Host "  Register a Windows Terminal profile? (y/N)"
        $wantTerminalProfile = ($answer -eq 'y')
    }
}
Write-Host ("  Start with Windows : {0}" -f $(if ($wantStartWithWindows) { 'yes' } else { 'no' })) -ForegroundColor Gray
Write-Host ("  Shortcuts          : {0}" -f $(if ($SkipShortcuts) { 'no' } else { 'yes' })) -ForegroundColor Gray
Write-Host ("  PATH               : {0}" -f $(if ($SkipPath) { 'no' } else { 'yes' })) -ForegroundColor Gray
Write-Host ("  Explorer integration / Terminal profile : {0} / {1}" -f $(if ($wantShellIntegration) { 'yes' } else { 'no' }), $(if ($wantTerminalProfile) { 'yes' } else { 'no' })) -ForegroundColor Gray

# ==================== STEP 3: COPY FILES ====================

Show-InstallStep "Copy files"
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
    $excludeDirs = @('.git', '.kimi', '.github', 'tests', 'USB', '.vscode', '.idea', 'dev')
    $robocopyArgs = @($SourceDir, $Destination, '/E', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/XD') + $excludeDirs
    & robocopy @robocopyArgs | Out-Null
    # Robocopy's exit codes are a bitmask where 0-7 all mean success (some
    # combination of "files copied"/"extra files"/"mismatched"); only 8+
    # indicates a real failure.
    if ($LASTEXITCODE -ge 8) {
        Write-DevKitError "robocopy failed (exit $LASTEXITCODE)"
        exit 1
    }
    # Marker file: Uninstall.ps1 refuses to delete an install dir WITHOUT it,
    # so running the repo's own Uninstall.ps1 can never eat a source checkout.
    Set-Content -LiteralPath (Join-Path $Destination ".northstar-installed") -Value "Northstar DevKit $AppVersion installed $(Get-Date -Format 'yyyy-MM-dd')" -Encoding ASCII
    Write-DevKitDone
}

# Heal the widget's "Start with Windows" Run value: it bakes in the .vbs
# launcher's absolute path, so a DevKit that was moved or reinstalled to a
# new location leaves the old entry pointing at a script that no longer
# exists (wscript pops "Can not find script file" at every logon). If the
# entry exists but does not point at THIS install's launcher - or its target
# is simply gone - rewrite it to the new location.
$wscript = Join-Path ([Environment]::SystemDirectory) 'wscript.exe'
$widgetLauncher = Join-Path $Destination "gui\Start-Widget-Startup.vbs"
try {
    $runKeyPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    $runValueName = 'NorthstarDevKitCompanion'
    $registered = (Get-ItemProperty -Path $runKeyPath -Name $runValueName -ErrorAction SilentlyContinue).$runValueName
    if ($null -ne $registered) {
        $expected = "`"$wscript`" `"$widgetLauncher`" 45"
        $stale = ($registered -ne $expected)
        if (-not $stale -and $registered -match '"([^"]+\.vbs)"') {
            $stale = -not (Test-Path $Matches[1])
        }
        if ($stale) {
            Set-ItemProperty -Path $runKeyPath -Name $runValueName -Value $expected
            Write-Host "  Repaired the 'Start with Windows' entry to point at this install." -ForegroundColor Cyan
        }
    }
} catch { }

# Drop any Mark-of-the-Web zone tag from the installed copy: users who copy
# the folder manually (instead of running this installer from a robocopy
# source) get zone-tagged .bat files that SmartScreen blocks on every launch.
try {
    Get-ChildItem -Path $Destination -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue
} catch { }

# ==================== STEP 4: REGISTER WITH WINDOWS (ADD/REMOVE PROGRAMS) ====================

Show-InstallStep "Register with Windows (Apps & Features)"
try {
    $arpKey = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$ArpKeyName"
    New-Item -Path $arpKey -Force | Out-Null
    $sizeKB = 0
    try {
        $sizeKB = [int][math]::Ceiling(((Get-ChildItem -Path $Destination -Recurse -File -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum / 1KB))
    } catch { }
    $psExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $uninstallScript = Join-Path $Destination "Uninstall.ps1"
    $iconPath = Join-Path $Destination "gui\Assets\logo.ico"
    Set-ItemProperty -Path $arpKey -Name 'DisplayName' -Value 'Northstar DevKit'
    Set-ItemProperty -Path $arpKey -Name 'DisplayVersion' -Value $AppVersion
    Set-ItemProperty -Path $arpKey -Name 'Publisher' -Value 'Northstar Software Development'
    Set-ItemProperty -Path $arpKey -Name 'URLInfoAbout' -Value 'https://www.northstarcoding.com'
    Set-ItemProperty -Path $arpKey -Name 'InstallLocation' -Value $Destination
    Set-ItemProperty -Path $arpKey -Name 'InstallDate' -Value (Get-Date -Format 'yyyyMMdd')
    if (Test-Path $iconPath) { Set-ItemProperty -Path $arpKey -Name 'DisplayIcon' -Value $iconPath }
    if ($sizeKB -gt 0) { Set-ItemProperty -Path $arpKey -Name 'EstimatedSize' -Value $sizeKB -Type DWord }
    Set-ItemProperty -Path $arpKey -Name 'NoModify' -Value 1 -Type DWord
    Set-ItemProperty -Path $arpKey -Name 'NoRepair' -Value 1 -Type DWord
    Set-ItemProperty -Path $arpKey -Name 'UninstallString' -Value "`"$psExe`" -NoProfile -ExecutionPolicy Bypass -File `"$uninstallScript`" -ArpKeyName $ArpKeyName"
    Set-ItemProperty -Path $arpKey -Name 'QuietUninstallString' -Value "`"$psExe`" -NoProfile -ExecutionPolicy Bypass -File `"$uninstallScript`" -Silent -ArpKeyName $ArpKeyName"
    Write-DevKitDone
} catch {
    Write-DevKitError "Could not register the app with Windows: $_"
}

# ==================== STEP 5: SHORTCUTS ====================

Show-InstallStep "Shortcuts"
if ($SkipShortcuts) {
    Write-DevKitSkip
} else {
    try {
        $startMenuDir = Join-Path ([Environment]::GetFolderPath('StartMenu')) "Programs\Northstar DevKit"
        if (-not (Test-Path $startMenuDir)) { New-Item -ItemType Directory -Path $startMenuDir -Force | Out-Null }
        $iconPath = Join-Path $Destination "gui\Assets\logo.ico"
        $wsh = New-Object -ComObject WScript.Shell

        # The MAIN icon: opens the widget. wscript launches the startup .vbs
        # windowlessly; if the widget is already running, its single-instance
        # summon event surfaces the existing window instead of a second copy.
        $widgetShortcut = $wsh.CreateShortcut((Join-Path $startMenuDir "Northstar DevKit.lnk"))
        $widgetShortcut.TargetPath = $wscript
        $widgetShortcut.Arguments = "`"$widgetLauncher`" 0"
        $widgetShortcut.WorkingDirectory = $Destination
        if (Test-Path $iconPath) { $widgetShortcut.IconLocation = $iconPath }
        $widgetShortcut.Description = "Northstar DevKit - companion widget"
        $widgetShortcut.Save()

        $guiShortcut = $wsh.CreateShortcut((Join-Path $startMenuDir "Northstar DevKit Control Center.lnk"))
        $guiShortcut.TargetPath = Join-Path $Destination "DevKit-GUI.bat"
        $guiShortcut.WorkingDirectory = $Destination
        if (Test-Path $iconPath) { $guiShortcut.IconLocation = $iconPath }
        $guiShortcut.Description = "Northstar DevKit - full toolkit GUI"
        $guiShortcut.Save()

        $tuiShortcut = $wsh.CreateShortcut((Join-Path $startMenuDir "Northstar DevKit (Terminal).lnk"))
        $tuiShortcut.TargetPath = Join-Path $Destination "DevKit.bat"
        $tuiShortcut.WorkingDirectory = $Destination
        if (Test-Path $iconPath) { $tuiShortcut.IconLocation = $iconPath }
        $tuiShortcut.Description = "Northstar DevKit - Terminal Menu"
        $tuiShortcut.Save()

        if (-not $NoDesktopShortcut) {
            $desktopShortcut = $wsh.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) "Northstar DevKit.lnk"))
            $desktopShortcut.TargetPath = $wscript
            $desktopShortcut.Arguments = "`"$widgetLauncher`" 0"
            $desktopShortcut.WorkingDirectory = $Destination
            if (Test-Path $iconPath) { $desktopShortcut.IconLocation = $iconPath }
            $desktopShortcut.Description = "Northstar DevKit - companion widget"
            $desktopShortcut.Save()
        }
        Write-DevKitDone
    } catch {
        Write-DevKitError "$_"
    }
}

# ==================== STEP 6: PATH ====================

Show-InstallStep "PATH"
if ($SkipPath) {
    Write-DevKitSkip
} else {
    $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
    $entries = @($userPath -split ';' | Where-Object { $_ })
    $normDest = $Destination.TrimEnd('\')
    $alreadyAdded = @($entries | Where-Object { $_.Trim().TrimEnd('\') -ieq $normDest }).Count -gt 0
    if ($alreadyAdded) {
        Write-DevKitInfo "Already on the user PATH."
    } else {
        [Environment]::SetEnvironmentVariable('PATH', ($entries + $Destination) -join ';', 'User')
        Write-DevKitDone
    }
}

# ==================== STEP 7: START WITH WINDOWS ====================

Show-InstallStep "Start with Windows"
if (-not $wantStartWithWindows) {
    Write-DevKitSkip
} else {
    try {
        Set-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' `
            -Name 'NorthstarDevKitCompanion' -Value "`"$wscript`" `"$widgetLauncher`" 45"
        Write-DevKitDone
    } catch {
        Write-DevKitError "Could not register startup: $_"
    }
}

# ==================== STEP 8: OPT-IN INTEGRATIONS ====================

Show-InstallStep "Optional integrations"
# Both scripts below are run from the NEW ($Destination) copy, not the
# source - so the registry command / Terminal profile they write points at
# the permanent install, never at a flash drive or temp checkout.
if (-not $wantShellIntegration -and -not $wantTerminalProfile) {
    Write-DevKitSkip
} else {
    if ($wantShellIntegration) {
        # Always -Force here: consent was already gathered above, either via the
        # y/N prompt just asked or an explicit -AddShellIntegration switch - a
        # second confirmation from the sub-script would just be a redundant gate.
        Write-DevKitStep "Explorer right-click integration"
        & (Join-Path $Destination "tools\system\Install-ShellIntegration.ps1") -Force
    }
    if ($wantTerminalProfile) {
        Write-DevKitStep "Windows Terminal profile"
        & (Join-Path $Destination "tools\system\Register-DevKitTerminalProfile.ps1")
    }
}

# ==================== DONE ====================

Write-Host ""
Write-Host "  DONE - Northstar DevKit $AppVersion is installed at:" -ForegroundColor Green
Write-Host "    $Destination" -ForegroundColor Gray
Write-Host ""
Write-Host "  Your Start Menu/Desktop 'Northstar DevKit' icon opens the widget" -ForegroundColor Green
Write-Host "  directly. Uninstall any time from Settings > Apps." -ForegroundColor Green

if (-not $Silent) {
    Write-Host ""
    $answer = Read-Host "  Launch the widget now? (Y/n)"
    if ($answer -ne 'n') {
        try { Start-Process $wscript -ArgumentList "`"$widgetLauncher`" 0" } catch { }
    }
}
Write-Host ""
