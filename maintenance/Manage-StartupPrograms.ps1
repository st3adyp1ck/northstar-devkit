#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Manage Startup Programs - Northstar DevKit
.DESCRIPTION
    Reports startup entries from three sources - the current user's Run
    registry key (HKCU), the all-users Run registry key (HKLM, read-only
    unless disabling one), and shortcuts in the current user's and all-users
    Startup folders - and can disable or re-enable a single entry by name.
    After the report, an interactive run offers to toggle an entry right
    away; -Disable / -Enable do the same non-interactively.

    Disabling is fully reversible and never touches Explorer's internal
    binary "StartupApproved" flag format: a Run value is renamed to
    "DevKitDisabled_<original>" (keeping the data intact) and a Startup
    folder shortcut is moved into a sibling "Disabled" folder. Enabling
    reverses whichever scheme applied.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Disable
    Visible name of a startup entry to disable, matched across all three
    sources. If more than one entry shares this name, you'll be asked which
    one to disable.
.PARAMETER Enable
    Visible name of a previously-disabled startup entry to re-enable.
.PARAMETER Force
    Skip the confirmation prompt when using -Disable or -Enable.
.EXAMPLE
    .\Manage-StartupPrograms.ps1
    .\Manage-StartupPrograms.ps1 -Disable "Spotify"
    .\Manage-StartupPrograms.ps1 -Enable "Spotify" -Force
#>
[CmdletBinding()]
param(
    [string]$Disable,
    [string]$Enable,
    [switch]$Force
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

Write-DevKitHeader "Manage Startup Programs"

if ($Disable -and $Enable) {
    Write-DevKitError "Specify only one of -Disable or -Enable, not both."
    exit 1
}

function Get-DevKitRegistryRawValue {
    param(
        [Parameter(Mandatory = $true)][string]$RegistryPath,
        [Parameter(Mandatory = $true)][string]$ValueName
    )
    $key = Get-Item -LiteralPath $RegistryPath -ErrorAction Stop
    $kind = $key.GetValueKind($ValueName)
    # DoNotExpandEnvironmentNames keeps a REG_EXPAND_SZ value (e.g.
    # "%ProgramFiles%\App\app.exe") literal instead of baking in this
    # machine's current expansion, so the renamed copy round-trips exactly.
    $data = $key.GetValue($ValueName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $propertyType = if ($kind -eq [Microsoft.Win32.RegistryValueKind]::ExpandString) { 'ExpandString' } else { 'String' }
    return @{ Data = $data; PropertyType = $propertyType }
}

function Get-DevKitRunKeyStartupEntries {
    param(
        [Parameter(Mandatory = $true)][string]$RegistryPath,
        [Parameter(Mandatory = $true)][string]$SourceLabel,
        [Parameter(Mandatory = $true)][string]$Source
    )

    $entries = @()
    try {
        if (-not (Test-Path $RegistryPath)) { return $entries }
        $key = Get-Item -LiteralPath $RegistryPath -ErrorAction Stop
        foreach ($valueName in $key.GetValueNames()) {
            if ([string]::IsNullOrEmpty($valueName)) { continue }
            $disabled = $valueName.StartsWith('DevKitDisabled_')
            $displayName = if ($disabled) { $valueName.Substring('DevKitDisabled_'.Length) } else { $valueName }
            $raw = Get-DevKitRegistryRawValue -RegistryPath $RegistryPath -ValueName $valueName
            $entries += [PSCustomObject]@{
                Source        = $Source
                SourceLabel   = $SourceLabel
                Name          = $displayName
                Command       = $raw.Data
                Disabled      = $disabled
                RegistryPath  = $RegistryPath
                ValueName     = $valueName
                ShortcutPath  = $null
                StartupFolder = $null
                Scope         = $null
            }
        }
    } catch {
        Write-DevKitError "Could not read $SourceLabel entries: $_"
    }
    return $entries
}

function Get-DevKitShortcutTarget {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        $Shell
    )
    if (-not $Shell) { return $null }
    try {
        $lnk = $Shell.CreateShortcut($Path)
        if ($lnk -and $lnk.TargetPath) { return $lnk.TargetPath }
    } catch {
        # A malformed/broken shortcut just falls back to showing its own path.
    }
    return $null
}

function Get-DevKitStartupFolderEntries {
    param(
        [Parameter(Mandatory = $true)][string]$FolderPath,
        [Parameter(Mandatory = $true)][string]$Scope,
        $Shell
    )

    $entries = @()
    if (-not (Test-Path -LiteralPath $FolderPath)) { return $entries }

    $disabledFolder = Join-Path (Split-Path -Parent $FolderPath) "Disabled"

    $groups = @(
        @{ Folder = $FolderPath; Disabled = $false },
        @{ Folder = $disabledFolder; Disabled = $true }
    )

    foreach ($group in $groups) {
        if (-not (Test-Path -LiteralPath $group.Folder)) { continue }
        try {
            $items = @(Get-ChildItem -LiteralPath $group.Folder -Filter '*.lnk' -File -ErrorAction Stop)
        } catch {
            Write-DevKitError "Could not read '$($group.Folder)': $_"
            continue
        }
        foreach ($item in $items) {
            $target = Get-DevKitShortcutTarget -Path $item.FullName -Shell $Shell
            $entries += [PSCustomObject]@{
                Source        = 'StartupFolder'
                SourceLabel   = 'Startup Folder Shortcuts'
                Name          = [IO.Path]::GetFileNameWithoutExtension($item.Name)
                Command       = if ($target) { $target } else { $item.FullName }
                Disabled      = $group.Disabled
                RegistryPath  = $null
                ValueName     = $null
                ShortcutPath  = $item.FullName
                StartupFolder = $FolderPath
                Scope         = $Scope
            }
        }
    }
    return $entries
}

function Show-DevKitStartupSourceGroup {
    param(
        [Parameter(Mandatory = $true)][string]$Heading,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Entries,
        [switch]$ShowScope
    )

    Write-Host "  $Heading" -ForegroundColor Magenta
    if ($Entries.Count -eq 0) {
        Write-DevKitInfo "No entries found."
        Write-Host ""
        return
    }

    $i = 0
    foreach ($e in ($Entries | Sort-Object Name)) {
        $i++
        $tag = if ($e.Disabled) { " (disabled)" } else { "" }
        $scopeTag = if ($ShowScope -and $e.Scope) { "  [$($e.Scope)]" } else { "" }
        $line = "    [{0}] {1}{2}{3}" -f $i, $e.Name, $tag, $scopeTag
        # Omitting -ForegroundColor for an active entry (rather than querying
        # $Host.UI.RawUI.ForegroundColor) avoids a host that can't report its
        # own console color - e.g. output redirected to a file - throwing.
        if ($e.Disabled) {
            Write-Host $line -ForegroundColor Gray
        } else {
            Write-Host $line
        }
        if ($e.Command) {
            Write-Host "         $($e.Command)" -ForegroundColor DarkGray
        }
    }
    Write-Host ""
}

$hkcuPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$hklmPath = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'
$userStartupFolder = [Environment]::GetFolderPath('Startup')
$commonStartupFolder = [Environment]::GetFolderPath('CommonStartup')

$hkcuEntries = Get-DevKitRunKeyStartupEntries -RegistryPath $hkcuPath -SourceLabel 'Current User (HKCU) - Run Registry' -Source 'HKCU'

$hklmEntries = @()
try {
    $hklmEntries = Get-DevKitRunKeyStartupEntries -RegistryPath $hklmPath -SourceLabel 'All Users (HKLM) - Run Registry' -Source 'HKLM'
} catch {
    Write-DevKitError "Could not read HKLM Run entries: $_"
}

$wshShell = $null
try {
    $wshShell = New-Object -ComObject WScript.Shell
} catch {
    $wshShell = $null
}

$folderEntries = @()
try {
    $folderEntries += Get-DevKitStartupFolderEntries -FolderPath $userStartupFolder -Scope 'Current User' -Shell $wshShell
    $folderEntries += Get-DevKitStartupFolderEntries -FolderPath $commonStartupFolder -Scope 'All Users' -Shell $wshShell
} finally {
    if ($wshShell) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($wshShell) }
}

$allEntries = @($hkcuEntries) + @($hklmEntries) + @($folderEntries)

if (-not $Disable -and -not $Enable) {
    Show-DevKitStartupSourceGroup -Heading "(a) Current User (HKCU) - Run Registry" -Entries $hkcuEntries
    Show-DevKitStartupSourceGroup -Heading "(b) All Users (HKLM) - Run Registry" -Entries $hklmEntries
    Show-DevKitStartupSourceGroup -Heading "(c) Startup Folder Shortcuts (Current User + All Users)" -Entries $folderEntries -ShowScope

    if ([Console]::IsInputRedirected) {
        Write-DevKitInfo "Use -Disable <Name> / -Enable <Name> to toggle an entry (matched by its visible name)."
        exit 0
    }
    $name = Read-Host "  Entry name to disable or re-enable (Enter to exit)"
    if (-not $name) {
        Write-DevKitInfo "No changes made."
        exit 0
    }
    if (@($allEntries | Where-Object { $_.Name -eq $name -and -not $_.Disabled }).Count -gt 0) {
        $Disable = $name
    } elseif (@($allEntries | Where-Object { $_.Name -eq $name -and $_.Disabled }).Count -gt 0) {
        $Enable = $name
    } else {
        Write-DevKitError "No startup entry named '$name' was found."
        exit 1
    }
}

if ($Disable) {
    $activeMatches = @($allEntries | Where-Object { $_.Name -eq $Disable -and -not $_.Disabled })

    if ($activeMatches.Count -eq 0) {
        $disabledMatches = @($allEntries | Where-Object { $_.Name -eq $Disable -and $_.Disabled })
        if ($disabledMatches.Count -gt 0) {
            Write-DevKitInfo "'$Disable' is already disabled."
            exit 0
        }
        Write-DevKitError "No startup entry named '$Disable' was found. Run with no parameters to see the current list."
        exit 1
    }

    $target = $activeMatches[0]
    if ($activeMatches.Count -gt 1) {
        Write-Host ""
        Write-Host "  Multiple startup entries named '$Disable' were found:" -ForegroundColor Magenta
        for ($i = 0; $i -lt $activeMatches.Count; $i++) {
            Write-Host ("    [{0}] {1}  ({2})" -f ($i + 1), $activeMatches[$i].Name, $activeMatches[$i].SourceLabel)
        }
        Write-Host ""
        $choice = Read-Host "  Which one do you want to disable? (1-$($activeMatches.Count), or 0 to cancel)"
        if ($choice -notmatch '^\d+$' -or [int]$choice -lt 1 -or [int]$choice -gt $activeMatches.Count) {
            Write-DevKitInfo "Cancelled."
            exit 0
        }
        $target = $activeMatches[[int]$choice - 1]
    }

    # Moving an all-users Startup-folder shortcut needs elevation just like
    # writing the HKLM Run key does.
    $requiresAdmin = ($target.Source -eq 'HKLM') -or
        ($target.Source -eq 'StartupFolder' -and $target.Scope -eq 'All Users')
    if ($requiresAdmin -and -not (Test-DevKitAdmin)) {
        Write-DevKitError "Disabling an All Users startup entry (HKLM or the common Startup folder) requires an elevated (Administrator) session."
        exit 1
    }

    if (-not (Confirm-DevKitDestructiveAction -Action "disable startup entry '$($target.Name)'" -Force:$Force)) {
        Write-DevKitInfo "Cancelled."
        exit 0
    }

    # A leftover backup under the same name (a DevKitDisabled_* registry
    # value, or a same-named .lnk in the Disabled folder) must never be
    # silently overwritten - abort this entry instead.
    if ($target.Source -eq 'StartupFolder') {
        $collisionPath = Join-Path (Join-Path (Split-Path -Parent $target.StartupFolder) "Disabled") (Split-Path -Leaf $target.ShortcutPath)
        if (Test-Path -LiteralPath $collisionPath) {
            Write-DevKitError "A disabled copy already exists at '$collisionPath' - refusing to overwrite it. Rename or remove it first."
            exit 1
        }
    } else {
        $backupValueName = "DevKitDisabled_$($target.ValueName)"
        if (Get-ItemProperty -Path $target.RegistryPath -Name $backupValueName -ErrorAction SilentlyContinue) {
            Write-DevKitError "A disabled backup value '$backupValueName' already exists under $($target.RegistryPath) - refusing to overwrite it. Rename or remove it first."
            exit 1
        }
    }

    Write-DevKitStep "Disabling '$($target.Name)'"
    try {
        if ($target.Source -eq 'StartupFolder') {
            $disabledFolder = Join-Path (Split-Path -Parent $target.StartupFolder) "Disabled"
            if (-not (Test-Path -LiteralPath $disabledFolder)) {
                New-Item -ItemType Directory -Path $disabledFolder -Force -ErrorAction Stop | Out-Null
            }
            $destination = Join-Path $disabledFolder (Split-Path -Leaf $target.ShortcutPath)
            Move-Item -LiteralPath $target.ShortcutPath -Destination $destination -Force -ErrorAction Stop
        } else {
            $raw = Get-DevKitRegistryRawValue -RegistryPath $target.RegistryPath -ValueName $target.ValueName
            $newValueName = "DevKitDisabled_$($target.ValueName)"
            New-ItemProperty -Path $target.RegistryPath -Name $newValueName -Value $raw.Data -PropertyType $raw.PropertyType -Force -ErrorAction Stop | Out-Null
            Remove-ItemProperty -Path $target.RegistryPath -Name $target.ValueName -Force -ErrorAction Stop
        }
        Write-DevKitDone
    } catch {
        Write-DevKitDone
        Write-DevKitError "Failed to disable '$($target.Name)': $_"
        exit 1
    }

    exit 0
}

if ($Enable) {
    $disabledMatches = @($allEntries | Where-Object { $_.Name -eq $Enable -and $_.Disabled })

    if ($disabledMatches.Count -eq 0) {
        $activeMatches = @($allEntries | Where-Object { $_.Name -eq $Enable -and -not $_.Disabled })
        if ($activeMatches.Count -gt 0) {
            Write-DevKitInfo "'$Enable' is already enabled."
            exit 0
        }
        Write-DevKitError "No disabled startup entry named '$Enable' was found. Run with no parameters to see the current list."
        exit 1
    }

    $target = $disabledMatches[0]
    if ($disabledMatches.Count -gt 1) {
        Write-Host ""
        Write-Host "  Multiple disabled startup entries named '$Enable' were found:" -ForegroundColor Magenta
        for ($i = 0; $i -lt $disabledMatches.Count; $i++) {
            Write-Host ("    [{0}] {1}  ({2})" -f ($i + 1), $disabledMatches[$i].Name, $disabledMatches[$i].SourceLabel)
        }
        Write-Host ""
        $choice = Read-Host "  Which one do you want to enable? (1-$($disabledMatches.Count), or 0 to cancel)"
        if ($choice -notmatch '^\d+$' -or [int]$choice -lt 1 -or [int]$choice -gt $disabledMatches.Count) {
            Write-DevKitInfo "Cancelled."
            exit 0
        }
        $target = $disabledMatches[[int]$choice - 1]
    }

    # Moving an all-users Startup-folder shortcut needs elevation just like
    # writing the HKLM Run key does.
    $requiresAdmin = ($target.Source -eq 'HKLM') -or
        ($target.Source -eq 'StartupFolder' -and $target.Scope -eq 'All Users')
    if ($requiresAdmin -and -not (Test-DevKitAdmin)) {
        Write-DevKitError "Enabling an All Users startup entry (HKLM or the common Startup folder) requires an elevated (Administrator) session."
        exit 1
    }

    if (-not (Confirm-DevKitDestructiveAction -Action "enable startup entry '$($target.Name)'" -Force:$Force)) {
        Write-DevKitInfo "Cancelled."
        exit 0
    }

    Write-DevKitStep "Enabling '$($target.Name)'"
    # Mirror of the disable path's collision guard: if the app re-created its
    # active entry after it was disabled (auto-updaters do this), restoring
    # the older backup over the newer value/shortcut would silently destroy
    # current state - abort instead.
    if ($target.Source -eq 'StartupFolder') {
        $restorePath = Join-Path $target.StartupFolder (Split-Path -Leaf $target.ShortcutPath)
        if (Test-Path -LiteralPath $restorePath) {
            Write-DevKitError "An active shortcut already exists at '$restorePath' - refusing to overwrite it with the older disabled copy. Remove the newer one first if you really want the backup back."
            exit 1
        }
    } else {
        if (Get-ItemProperty -Path $target.RegistryPath -Name $target.Name -ErrorAction SilentlyContinue) {
            Write-DevKitError "An active value '$($target.Name)' already exists under $($target.RegistryPath) - refusing to overwrite it with the older disabled backup. Remove the newer one first if you really want the backup back."
            exit 1
        }
    }
    try {
        if ($target.Source -eq 'StartupFolder') {
            $destination = Join-Path $target.StartupFolder (Split-Path -Leaf $target.ShortcutPath)
            Move-Item -LiteralPath $target.ShortcutPath -Destination $destination -Force -ErrorAction Stop
        } else {
            $raw = Get-DevKitRegistryRawValue -RegistryPath $target.RegistryPath -ValueName $target.ValueName
            New-ItemProperty -Path $target.RegistryPath -Name $target.Name -Value $raw.Data -PropertyType $raw.PropertyType -Force -ErrorAction Stop | Out-Null
            Remove-ItemProperty -Path $target.RegistryPath -Name $target.ValueName -Force -ErrorAction Stop
        }
        Write-DevKitDone
    } catch {
        Write-DevKitDone
        Write-DevKitError "Failed to enable '$($target.Name)': $_"
        exit 1
    }

    exit 0
}

exit 0
