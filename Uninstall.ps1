#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Northstar DevKit - Uninstaller
.DESCRIPTION
    Removes Northstar DevKit and every trace it leaves behind. This is the
    script Windows runs when you pick "Uninstall" under Settings > Apps >
    Northstar DevKit (the installer registers it in the per-user Uninstall
    registry key).

    What it removes, in order:
      1. The running companion widget (stopped via its pid file).
      2. The opt-in integrations, if present (Explorer right-click entry,
         Windows Terminal profile) via the existing tools\system scripts.
      3. The "Start with Windows" Run-key value (NorthstarDevKitCompanion).
      4. The install location from the user PATH.
      5. Start Menu shortcuts (the "Northstar DevKit" folder) and the Desktop
         shortcut.
      6. The Apps & Features registry entry itself.
      7. The install directory.
      8. The app-data folder %LOCALAPPDATA%\NorthstarDevKit (settings, linked
         projects, notes, on-deck lists, logs) - unless -KeepUserData, or you
         answer "n" to the interactive prompt.

    Safety: step 7 only proceeds when the install dir carries the
    ".northstar-installed" marker file the installer drops there - running
    this script from a source checkout (repo clone) aborts the delete, so
    development trees can never be eaten by accident.

    Because the uninstaller usually lives INSIDE the directory it deletes, it
    first copies itself to %TEMP% and re-launches from there; the temp copy
    deletes itself on the way out.

    Every step is per-user (HKCU, user PATH, your own Start Menu) - no
    administrator privileges are used or required.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Silent
    No prompts (used by the QuietUninstallString): user data is deleted.
.PARAMETER KeepUserData
    Keep %LOCALAPPDATA%\NorthstarDevKit (settings, projects, notes).
.PARAMETER InstallDir
    The install directory to remove. Defaults to this script's own folder.
.PARAMETER ArpKeyName
    The Uninstall registry key name to remove. Default "NorthstarDevKit".
.PARAMETER Relocated
    Internal: set on the %TEMP% copy so it doesn't try to relocate again.
.EXAMPLE
    .\Uninstall.ps1
#>
[CmdletBinding()]
param(
    [switch]$Silent,
    [switch]$KeepUserData,
    [string]$InstallDir,
    [string]$ArpKeyName = 'NorthstarDevKit',
    [switch]$Relocated
)

$ErrorActionPreference = 'Continue'   # uninstall must push through individual failures and report them
$script:Failed = @()

function Write-UninstallStep([string]$Text) { Write-Host "  * $Text" -ForegroundColor Cyan }
function Write-UninstallDone { Write-Host "    done" -ForegroundColor Green }
function Write-UninstallSkipped([string]$Why) { Write-Host "    skipped - $Why" -ForegroundColor DarkGray }
function Write-UninstallFailed([string]$What, [string]$Why) {
    Write-Host "    FAILED: $What - $Why" -ForegroundColor Red
    $script:Failed += $What
}

# ==================== RELOCATE TO %TEMP% ====================
# The uninstaller normally lives inside the folder it deletes. Copy itself to
# %TEMP% and re-run from there so the install dir isn't locked by its own
# script file.

if (-not $InstallDir) { $InstallDir = $PSScriptRoot }
$InstallDir = [System.IO.Path]::GetFullPath($InstallDir)

if (-not $Relocated) {
    $tempCopy = Join-Path $env:TEMP "NorthstarDevKit-Uninstall.ps1"
    try {
        Copy-Item -LiteralPath $PSCommandPath -Destination $tempCopy -Force
    } catch {
        Write-Host "  ERROR: could not stage the uninstaller in %TEMP%: $_" -ForegroundColor Red
        exit 1
    }
    $psExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$tempCopy`"",
        '-Relocated', '-InstallDir', "`"$InstallDir`"", '-ArpKeyName', $ArpKeyName)
    if ($Silent) { $argList += '-Silent' }
    if ($KeepUserData) { $argList += '-KeepUserData' }
    Start-Process -FilePath $psExe -ArgumentList $argList | Out-Null
    exit 0
}

Write-Host ""
Write-Host "  =============================================" -ForegroundColor Cyan
Write-Host "    Northstar DevKit - Uninstall" -ForegroundColor Cyan
Write-Host "  =============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Install dir: $InstallDir" -ForegroundColor Gray

# ==================== 1. STOP THE WIDGET ====================

Write-UninstallStep "Stopping the companion widget"
$dataDir = Join-Path $env:LOCALAPPDATA "NorthstarDevKit"
$pidFile = Join-Path $dataDir "widget.pid"
$stopped = $false
try {
    if (Test-Path $pidFile) {
        $widgetPid = [int](Get-Content -LiteralPath $pidFile -Raw).Trim()
        # Verify the pid really is a widget process before killing it - pid
        # reuse could otherwise assassinate an innocent process.
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $widgetPid" -ErrorAction SilentlyContinue
        if ($proc -and $proc.CommandLine -match 'DevKit-Widget\.ps1') {
            Stop-Process -Id $widgetPid -Force -ErrorAction Stop
            $stopped = $true
        }
    }
    # Fallback: the pid file can be missing (an older build's launcher
    # deleted it on a summon). Find the widget by its command line instead -
    # but only one launched from THIS install dir, never a checkout's copy.
    if (-not $stopped) {
        $escaped = [regex]::Escape($InstallDir.TrimEnd('\'))
        $candidates = Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match 'DevKit-Widget\.ps1' -and $_.CommandLine -match $escaped }
        foreach ($candidate in $candidates) {
            try { Stop-Process -Id $candidate.ProcessId -Force -ErrorAction Stop; $stopped = $true } catch { }
        }
    }
} catch { }
if ($stopped) { Write-UninstallDone } else { Write-UninstallSkipped "widget not running" }

# ==================== 2. OPT-IN INTEGRATIONS ====================

Write-UninstallStep "Removing Explorer / Windows Terminal integrations"
foreach ($integration in @("tools\system\Uninstall-ShellIntegration.ps1", "tools\system\Unregister-DevKitTerminalProfile.ps1")) {
    $scriptPath = Join-Path $InstallDir $integration
    if (Test-Path $scriptPath) {
        try { & $scriptPath | Out-Null } catch { Write-UninstallFailed $integration "$_" }
    }
}
Write-UninstallDone

# ==================== 3. START-WITH-WINDOWS ENTRY ====================

Write-UninstallStep "Removing the 'Start with Windows' entry"
try {
    Remove-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' `
        -Name 'NorthstarDevKitCompanion' -ErrorAction Stop
    Write-UninstallDone
} catch {
    Write-UninstallSkipped "not registered"
}

# ==================== 4. PATH ====================

Write-UninstallStep "Removing the install dir from the user PATH"
try {
    $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
    $normDest = $InstallDir.TrimEnd('\')
    $kept = @($userPath -split ';' | Where-Object { $_ -and ($_.Trim().TrimEnd('\') -ine $normDest) })
    if ($kept.Count -lt @($userPath -split ';' | Where-Object { $_ }).Count) {
        [Environment]::SetEnvironmentVariable('PATH', ($kept -join ';'), 'User')
        Write-UninstallDone
    } else {
        Write-UninstallSkipped "not on the PATH"
    }
} catch {
    Write-UninstallFailed "PATH cleanup" "$_"
}

# ==================== 5. SHORTCUTS ====================

Write-UninstallStep "Removing Start Menu / Desktop shortcuts"
try {
    $startMenuDir = Join-Path ([Environment]::GetFolderPath('StartMenu')) "Programs\Northstar DevKit"
    if (Test-Path $startMenuDir) { Remove-Item -LiteralPath $startMenuDir -Recurse -Force -ErrorAction Stop }
    $desktopLink = Join-Path ([Environment]::GetFolderPath('Desktop')) "Northstar DevKit.lnk"
    if (Test-Path $desktopLink) { Remove-Item -LiteralPath $desktopLink -Force -ErrorAction Stop }
    Write-UninstallDone
} catch {
    Write-UninstallFailed "shortcut cleanup" "$_"
}

# ==================== 6. APPS & FEATURES ENTRY ====================

Write-UninstallStep "Removing the Apps & Features registration"
try {
    Remove-Item -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$ArpKeyName" -Recurse -Force -ErrorAction Stop
    Write-UninstallDone
} catch {
    Write-UninstallSkipped "not registered"
}

# ==================== 7. INSTALL DIRECTORY ====================

Write-UninstallStep "Deleting the install directory"
$marker = Join-Path $InstallDir ".northstar-installed"
if (-not (Test-Path $marker)) {
    # No marker = this is a source checkout or a hand-copied folder, NOT a
    # real install. Refuse to delete it - the repo's own Uninstall.ps1 must
    # never eat the development tree.
    Write-UninstallFailed "install directory" "no .northstar-installed marker found - refusing to delete an unmanaged folder"
} else {
    try {
        Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction Stop
        Write-UninstallDone
    } catch {
        Write-UninstallFailed "install directory" "$_"
    }
}

# ==================== 8. APP DATA ====================

if (-not $KeepUserData -and -not $Silent) {
    Write-Host ""
    $answer = Read-Host "  Also delete saved settings, linked projects, and notes? (Y/n)"
    if ($answer -eq 'n') { $KeepUserData = $true }
}
if ($KeepUserData) {
    Write-UninstallStep "App data ($dataDir)"
    Write-UninstallSkipped "keeping your settings, projects and notes"
} else {
    Write-UninstallStep "Deleting app data ($dataDir)"
    try {
        if (Test-Path $dataDir) { Remove-Item -LiteralPath $dataDir -Recurse -Force -ErrorAction Stop }
        Write-UninstallDone
    } catch {
        Write-UninstallFailed "app data" "$_"
    }
}

# ==================== REPORT + SELF-DELETE ====================

Write-Host ""
if ($script:Failed.Count -eq 0) {
    Write-Host "  Northstar DevKit has been completely removed." -ForegroundColor Green
} else {
    Write-Host "  Uninstall finished with $($script:Failed.Count) problem(s):" -ForegroundColor Yellow
    foreach ($f in $script:Failed) { Write-Host "    - $f" -ForegroundColor Yellow }
    Write-Host "  Remove the items above manually if they still exist." -ForegroundColor Gray
}
if (-not $Silent) { Read-Host "`n  Press Enter to close" | Out-Null }

# Delete the staged %TEMP% copy of this script after it exits.
try {
    Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', 'ping', '127.0.0.1', '-n', '3', '>nul', '&', 'del', "/f", "/q", "`"$PSCommandPath`"" `
        -WindowStyle Hidden | Out-Null
} catch { }
exit 0
