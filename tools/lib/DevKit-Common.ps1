#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Northstar DevKit - Common Helpers
.DESCRIPTION
    Shared functions used by DevKit scripts. This file is dot-sourced by
    standalone scripts; it does not produce output when loaded.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.VERSION
    3.8.0
#>

# Prevent double-loading. Scope-aware on purpose: a $global: bool would
# incorrectly skip loading for a sibling script invoked via `&` in the same
# process (a distinct child scope that never inherits functions defined by
# another sibling's dot-source), leaving it with the flag set but none of
# the functions actually defined. Checking for the function itself detects
# "already loaded in a scope this one can see" instead.
if (Get-Command Write-DevKitHeader -ErrorAction SilentlyContinue) { return }
$global:DevKitCommonLoaded = $true

# A process relaunched via Start-Process (e.g. the GUI's MTA->STA and
# packaged-shell hops in gui/DevKit-GUI.ps1) can have module auto-load
# resolve Microsoft.PowerShell.Utility to a same-named module from a
# DIFFERENT PowerShell install earlier on PSModulePath - observed on real
# hardware: a Store-packaged pwsh 7 build's copy (no
# Import-PowerShellDataFile) winning over this host's own copy. $PSHOME
# always points at the CURRENT host's own install regardless of how it was
# launched, so pin its own Utility module now, once, before anything below
# calls Import-PowerShellDataFile.
$devKitUtilityManifestPath = Join-Path $PSHOME "Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1"
if (Test-Path $devKitUtilityManifestPath) {
    Import-Module $devKitUtilityManifestPath -Force -ErrorAction SilentlyContinue
}

# Animation/color engine (gradient text, startup banner, spinner) - split
# out of this file so the terminal-capability probing and ANSI rendering
# live in one place. Dot-sourced here so every function below (and every
# script that dot-sources DevKit-Common.ps1) can call it directly.
. (Join-Path $PSScriptRoot "DevKit-UI.ps1")

# ==================== SETTINGS ====================

function Get-DevKitSettingsFile {
    $dir = Join-Path $env:LOCALAPPDATA "NorthstarDevKit"
    if (-not (Test-Path $dir)) {
        # Best-effort: a creation failure (permissions, profile not fully
        # loaded during logon) must not be a terminating error here -
        # downstream readers already tolerate the file simply being absent.
        try { New-Item -ItemType Directory -Path $dir -Force | Out-Null } catch { }
    }
    return Join-Path $dir "settings.json"
}

function Get-DevKitSettings {
    <#
    .SYNOPSIS
        Loads DevKit's settings, creating the file with defaults on first
        use. A corrupt/hand-edited file is quarantined and reset rather than
        crashing - the same pattern already used for the project registry.
    .OUTPUTS
        PSCustomObject with .schemaVersion and .preferences.
    #>
    $defaults = [PSCustomObject]@{
        schemaVersion = 1
        preferences   = [PSCustomObject]@{
            confirmDestructive = $true
            updateCheckEnabled = $true
            lastUpdateCheckUtc = $null
            enableAnimations   = $true
            widgetDockMode     = 'Right'
            widgetWidth        = 380
            gitFlyoutWidth     = 300
            notesFlyoutWidth   = 300
            envDriftSilencedProjects = @()
            # Tauri app appearance/UX (added with the 2026 Settings panel;
            # the name-level backfill above makes these safe to add - an
            # existing settings.json just gains them on next load).
            appTheme           = 'northstar'   # one of the 10 built-in theme presets
            accentColor        = $null         # hex override; $null = theme default
            fontFamily         = $null         # UI font override; $null = theme default
            uiScale            = 1.0           # 0.8 - 1.4, applied as root zoom
            terminalTheme      = 'northstar'   # embedded terminal color scheme
            uiSounds           = $true         # click/thud/swoosh feedback
            uiSoundVolume      = 0.5           # 0.0 - 1.0
            # Flyout trays + global summon (2026 tray revival - the
            # gitFlyoutWidth/notesFlyoutWidth above are the ORIGINAL WPF
            # widget's per-flyout widths, kept for continuity; flyoutWidth
            # is the default for flyouts that don't have their own).
            flyoutWidth        = 380
            controlCenterFlyoutWidth = $null  # $null = fill the remaining screen on open; a resize drag persists a number
            flyoutTabOrder     = @()           # rail tab order by tray id; empty = the code's default order. Written by drag-reordering the rail.
            globalHotkey       = 'CommandOrControl+Alt+D'  # summon/dismiss the widget
            runHistoryLimit    = 50            # tool runs retained in history
            # Icon rail (the vertical strip of flyout tabs on the widget's
            # inner edge). Width is the whole strip; iconSize is the glyph
            # inside it, kept separate so a wider strip with the same glyph
            # (more breathing room) is expressible.
            iconTheme          = 'outline'     # 'outline' | 'solid' | 'duotone'
            railWidth          = 44            # px, logical
            railIconSize       = 18            # px, logical
            # Widget width persisted on close so it reopens exactly as left.
            # $null = never set; the Rust side then falls back to its
            # quarter-screen default (see commands.rs).
            widgetSavedWidth   = $null
        }
    }

    $path = Get-DevKitSettingsFile
    if (-not (Test-Path $path)) { return $defaults }

    try {
        $raw = Get-Content -Path $path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $defaults }
        $data = $raw | ConvertFrom-Json -ErrorAction Stop
        if (-not $data.preferences) { return $defaults }
        # Fill in any preference missing from an older/partial file rather
        # than failing outright, so adding a new setting later never breaks
        # an existing settings.json.
        # Caveat: shallow name-level backfill only - any key present in the user file replaces the default wholesale (nested object values are never deep-merged).
        foreach ($prop in $defaults.preferences.PSObject.Properties.Name) {
            # @() + -contains, never .Name.Contains(): with exactly one
            # property on file the member-enumerated .Name is a bare string,
            # and String.Contains would do a substring match.
            if (-not (@($data.preferences.PSObject.Properties.Name) -contains $prop)) {
                $data.preferences | Add-Member -MemberType NoteProperty -Name $prop -Value $defaults.preferences.$prop
            }
        }
        return $data
    } catch {
        $backupPath = "$path.corrupt-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))"
        try { Move-Item -Path $path -Destination $backupPath -Force -ErrorAction SilentlyContinue } catch {}
        Write-DevKitError "Settings file was corrupted and has been reset. Backup: $backupPath"
        return $defaults
    }
}

function Set-DevKitSettings {
    param([Parameter(Mandatory = $true)]$Settings)
    $path = Get-DevKitSettingsFile
    $tempPath = "$path.tmp.$PID"
    try {
        # Merge over whatever is on disk right now instead of blindly
        # overwriting: another DevKit process (e.g. the long-lived widget) may
        # have written its own preference change since this caller loaded its
        # copy, and last-writer-wins would silently drop it. The caller's
        # preference keys win; on-disk keys the caller doesn't carry (e.g.
        # written by a newer build) are preserved. Best-effort: any
        # read/parse failure falls back to the caller's copy as-is.
        $toSave = $Settings
        try {
            if (Test-Path $path) {
                $raw = Get-Content -Path $path -Raw -ErrorAction Stop
                if (-not [string]::IsNullOrWhiteSpace($raw)) {
                    $onDisk = $raw | ConvertFrom-Json -ErrorAction Stop
                    if ($onDisk.preferences -and $Settings.preferences) {
                        foreach ($prop in @($Settings.preferences.PSObject.Properties.Name)) {
                            $onDisk.preferences | Add-Member -MemberType NoteProperty -Name $prop -Value $Settings.preferences.$prop -Force
                        }
                        # schemaVersion is deliberately NOT taken from the caller
                        # unconditionally. A caller sending a partial patch may omit it
                        # entirely (writing $null would make the next Get-DevKitSettings
                        # treat the file as unversioned), and an older build must never
                        # downgrade a file a newer build wrote. Keep the highest version
                        # either side knows about.
                        $diskVersion = 0
                        if ($null -ne $onDisk.schemaVersion) { [void][int]::TryParse([string]$onDisk.schemaVersion, [ref]$diskVersion) }
                        $callerVersion = 0
                        if ($null -ne $Settings.schemaVersion) { [void][int]::TryParse([string]$Settings.schemaVersion, [ref]$callerVersion) }
                        $keepVersion = [Math]::Max($diskVersion, $callerVersion)
                        if ($keepVersion -gt 0) {
                            $onDisk | Add-Member -MemberType NoteProperty -Name schemaVersion -Value $keepVersion -Force
                        }
                        $toSave = $onDisk
                    }
                }
            }
        } catch { $toSave = $Settings }
        $toSave | ConvertTo-Json -Depth 6 | Set-Content -Path $tempPath -Encoding UTF8
        Move-Item -Path $tempPath -Destination $path -Force
    } catch {
        if (Test-Path $tempPath) { Remove-Item $tempPath -Force -ErrorAction SilentlyContinue }
        throw "Failed to save settings: $_"
    }
}

function Confirm-DevKitDestructiveAction {
    <#
    .SYNOPSIS
        One reusable confirmation gate for destructive operations, so new
        (and eventually migrated) destructive scripts share a single,
        correctly-implemented prompt instead of each hand-rolling its own.
    .PARAMETER Action
        One-line description of what will happen, e.g. "delete all Docker
        containers, images, and volumes".
    .PARAMETER AffectedPaths
        Optional list of specific paths/items to display, so the user sees
        exactly what's affected rather than a vague summary.
    .PARAMETER TypedPhrase
        If set, the user must type this exact phrase (case-sensitive) to
        confirm, e.g. 'NUKE'. If omitted, a simple y/N prompt is used.
    .PARAMETER Force
        Bypass the prompt entirely (the caller's own -Force switch).
    .OUTPUTS
        [bool] $true if the action should proceed.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [string[]]$AffectedPaths = @(),
        [string]$TypedPhrase,
        [switch]$Force
    )

    if ($Force) { return $true }

    $settings = Get-DevKitSettings
    if (-not $settings.preferences.confirmDestructive) { return $true }

    Write-Host "  This will: $Action" -ForegroundColor Yellow
    foreach ($p in $AffectedPaths) { Write-Host "    - $p" -ForegroundColor Gray }

    # Read-Host THROWS under -NonInteractive ("PowerShell is in NonInteractive
    # mode"), which is exactly how the GUI launches tool scripts - it spawns
    # them with -NonInteractive and closes stdin. Without this guard every
    # destructive tool dies on an unhandled exception right after the user
    # already confirmed in the app's own caution dialog. Refuse safely instead:
    # declining is always the correct answer when consent cannot be obtained.
    if (-not (Test-DevKitCanPrompt)) {
        Write-Host "  Cannot prompt for confirmation in a non-interactive session - aborting." -ForegroundColor Yellow
        Write-Host "  Re-run this tool with -Force to proceed without a prompt." -ForegroundColor Gray
        return $false
    }

    if ($TypedPhrase) {
        $typed = Read-Host "  Type '$TypedPhrase' to confirm"
        return ($typed -ceq $TypedPhrase)
    }
    $answer = Read-Host "  Continue? (y/N)"
    return ($answer -eq 'y')
}

function Test-DevKitCanPrompt {
    <#
    .SYNOPSIS
        True when this session can actually read a console prompt.
    .DESCRIPTION
        PowerShell exposes no direct "am I -NonInteractive" flag, so probe the
        two conditions that make Read-Host fail: a host whose UI stack is
        absent (the -NonInteractive case, and runspaces created without a
        host), and redirected/absent stdin. Any probe failure is treated as
        "cannot prompt" - the safe direction for a destructive gate.
    .OUTPUTS
        [bool]
    #>
    try {
        if ($null -eq $Host -or $null -eq $Host.UI -or $null -eq $Host.UI.RawUI) { return $false }
        if ([System.Console]::IsInputRedirected) { return $false }
        return $true
    } catch {
        return $false
    }
}

# ==================== MODULE MENU DISPATCHER ====================
#
# DevKit.ps1's ten tool-category submenus (Port/Node/Next.js/Vite/Git/
# Docker/System/Workflow/Diagnostics/WiFi Tools) previously each hand-coded
# their own Show-XMenu + Start-XTools function pair, all following the exact
# same recipe: print numbered options, read a choice, switch on it, build a
# script path via Join-Path, Test-Path it, invoke it. That ~33x-duplicated
# recipe is exactly what caused two real regressions in this repo's history
# (see commits ecfff84, 776e166). The functions below replace all ten pairs
# with one generic implementation driven by a small "_module.psd1" manifest
# per tool folder. (The Main Menu and the Projects menu are deliberately
# NOT manifest-driven: Main Menu is a single hand-written function with
# intentional category groupings, not a duplicated pattern, and Projects
# manages the picker system itself rather than dispatching to a leaf
# script - neither fits this generic "run a script for a chosen project"
# shape, so forcing them into it would add risk without removing any real
# duplication.)

function Get-DevKitModule {
    <#
    .SYNOPSIS
        Loads a tool category's _module.psd1 manifest.
    .PARAMETER FolderPath
        Full path to the category folder (e.g. .../ports).
    #>
    param([Parameter(Mandatory = $true)][string]$FolderPath)

    $manifestPath = Join-Path $FolderPath "_module.psd1"
    if (-not (Test-Path $manifestPath)) {
        throw "No _module.psd1 manifest found in '$FolderPath'"
    }
    # Import-PowerShellDataFile only ever parses literal data (hashtables,
    # arrays, strings, numbers, booleans) - safe to load with no code
    # execution risk, unlike dot-sourcing an arbitrary .ps1.
    $module = Import-PowerShellDataFile -Path $manifestPath
    $module.FolderPath = $FolderPath
    return $module
}

function Read-DevKitTypedValue {
    <#
    .SYNOPSIS
        Prompts for and validates one typed value from a manifest Item's
        Prompts entry, replicating the exact validation each menu option
        used to hand-code (e.g. Kill-Port's "ERROR: Invalid port number.").
    .PARAMETER Spec
        A single Prompts hashtable: @{ Name; Type ('Int'|'YesNo'|'String');
        Prompt; Optional; Min; Max; InvalidMessage }.
    .OUTPUTS
        The typed value, or $null if the input was blank/invalid. For
        Type='YesNo' this never returns $null (blank/anything-but-'y' is a
        real, valid "no" answer, matching the original hand-coded behavior
        of only ever adding the arg when the answer was literally 'y').
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Spec)

    switch ($Spec.Type) {
        'Int' {
            $promptText = $Spec.Prompt
            $raw = Read-Host $promptText
            if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
            if ($raw -notmatch '^\d+$') { return $null }
            $val = [int64]$raw
            # $null checks, not truthiness: a Min/Max of 0 is a real bound.
            if ($null -ne $Spec.Min -and $val -lt [int64]$Spec.Min) { return $null }
            if ($null -ne $Spec.Max -and $val -gt [int64]$Spec.Max) { return $null }
            # Reject like any other invalid input instead of overflowing:
            # casting a value past Int32.MaxValue to [int] throws an uncaught
            # OverflowException that kills the whole menu loop.
            if ($val -gt [int]::MaxValue) { return $null }
            return [int]$val
        }
        'YesNo' {
            $raw = Read-Host "$($Spec.Prompt) (y/n)"
            return ($raw -eq 'y')
        }
        'String' {
            $raw = Read-Host $Spec.Prompt
            if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
            return $raw
        }
        default {
            throw "Unknown prompt type '$($Spec.Type)' in module manifest."
        }
    }
}

function Invoke-DevKitTool {
    <#
    .SYNOPSIS
        Generic dispatcher: resolves whatever a manifest Item needs (a
        project path, a file path, typed prompt values, static args) and
        invokes the item's script - replacing the hand-coded
        Join-Path/Test-Path/prompt/invoke block that used to be repeated at
        every single menu option across all ten tool categories.
    .PARAMETER FolderPath
        The tool category's folder (e.g. .../ports), containing the item's script.
    .PARAMETER Item
        One entry from a module manifest's Items array.
    .PARAMETER ForceReprompt
        Passed through to Select-DevKitProject for RequiresProject items,
        so a menu choice like "2p" can override the active project for one
        run without disturbing it.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$FolderPath,
        [Parameter(Mandatory = $true)][hashtable]$Item,
        [switch]$ForceReprompt
    )

    $callArgs = @{}

    if ($Item.RequiresProject) {
        $targetPath = Select-DevKitProject -Prompt $Item.Label -ForceReprompt:$ForceReprompt
        if ($null -eq $targetPath) {
            Write-Host "  Cancelled -- no project selected." -ForegroundColor Yellow
            return
        }
        $argName = if ($Item.ProjectArgName) { $Item.ProjectArgName } else { 'Path' }
        $callArgs[$argName] = $targetPath
    } elseif ($Item.RequiresFile) {
        Write-Host "  [B] Browse for a file..."
        Write-Host "  [T] Type a path manually"
        Write-Host "  [0] Cancel"
        $pickMode = Read-Host "Select option"
        $filePath = $null
        if ($pickMode -eq 'B' -or $pickMode -eq 'b') {
            $filePath = Show-DevKitFileBrowser -Description $Item.RequiresFile.Description -Filter $Item.RequiresFile.Filter
        } elseif ($pickMode -eq 'T' -or $pickMode -eq 't') {
            $filePath = Read-Host $Item.RequiresFile.TypePrompt
        }
        if ([string]::IsNullOrWhiteSpace($filePath)) {
            Write-Host "  Cancelled -- no file selected." -ForegroundColor Yellow
            return
        }
        $callArgs[$Item.RequiresFile.ParamName] = $filePath
    }

    if ($Item.Prompts) {
        foreach ($promptSpec in $Item.Prompts) {
            $value = Read-DevKitTypedValue -Spec $promptSpec
            if ($null -eq $value) {
                if ($promptSpec.Optional) { continue }
                $msg = if ($promptSpec.InvalidMessage) { $promptSpec.InvalidMessage } else { "Invalid value for $($promptSpec.Name)." }
                Write-Host "  ERROR: $msg" -ForegroundColor Red
                return
            }
            if ($promptSpec.Type -eq 'YesNo' -and -not $value) { continue }
            $callArgs[$promptSpec.Name] = $value
        }
    }

    if ($Item.StaticArgs) {
        foreach ($key in $Item.StaticArgs.Keys) { $callArgs[$key] = $Item.StaticArgs[$key] }
    }

    $scriptPath = Join-Path $FolderPath $Item.Script
    if (-not (Test-Path $scriptPath)) {
        Write-DevKitError "Script not found: $scriptPath"
        return
    }

    & $scriptPath @callArgs
}

function Show-DevKitInteractiveMenu {
    <#
    .SYNOPSIS
        Renders a bracketed option list and reads the user's choice, adding
        optional arrow-key navigation on top of the classic "type a number
        and press Enter" flow every menu already used.
    .DESCRIPTION
        Each entry is either selectable (@{ Key; Label }) or a non-selectable
        section heading (@{ IsHeader = $true; Label }) used for the Main
        Menu's grouped layout. On a console that supports raw key reads,
        UpArrow/DownArrow move a highlighted selection (skipping headings)
        and Enter confirms it; typed digits/letters are still captured and
        echoed like Read-Host, so existing conventions (typing "3p" to
        force-reprompt a project, typing a bare search keyword) keep working
        unchanged. On a console that can't do raw key reads (redirected
        input, CI, some non-interactive hosts) this transparently falls back
        to a plain Read-Host prompt - the exact behavior every menu had
        before this function existed. Always returns the same raw trimmed
        string a Read-Host call would, so callers (switch statements, regex
        matches like '^(.+)p$') require no changes at all.
    .PARAMETER Entries
        Ordered list of @{ Key; Label } and/or @{ IsHeader = $true; Label }.
    .PARAMETER PromptLabel
        Text shown at the input line (matches the prior Read-Host prompts).
    #>
    param(
        [Parameter(Mandatory = $true)][array]$Entries,
        [string]$PromptLabel = 'Select option'
    )

    $selectable = @()
    for ($i = 0; $i -lt $Entries.Count; $i++) {
        if (-not $Entries[$i].IsHeader) { $selectable += $i }
    }

    # Checked (and guarded) before ANY Console API touches the actual
    # screen buffer: on a redirected/piped host (CI, a plain pipe, some
    # non-console hosts) even a read-only property like CursorTop can throw
    # "handle is invalid" rather than just report redirected - so every
    # probe here is wrapped, and failure at any step degrades straight to
    # the classic Read-Host flow instead of crashing the menu.
    $canNavigate = $selectable.Count -gt 0
    if ($canNavigate) {
        try {
            $canNavigate = (-not [Console]::IsInputRedirected) -and (-not [Console]::IsOutputRedirected)
        } catch {
            $canNavigate = $false
        }
    }

    $entryTop = $null
    if ($canNavigate) {
        try { $entryTop = [Console]::CursorTop } catch { $canNavigate = $false }
    }

    foreach ($e in $Entries) {
        if ($e.IsHeader) {
            Write-Host "  $($e.Label)" -ForegroundColor White
        } else {
            Write-Host ("  [{0}] {1}" -f $e.Key, $e.Label)
        }
    }
    Write-Host ""

    if (-not $canNavigate) {
        $raw = Read-Host $PromptLabel
        # stdin EOF (redirected input exhausted) must not throw on .Trim() or
        # spin a re-prompt loop forever - treat it as Back, same as Escape.
        if ($null -eq $raw) { return '0' }
        return $raw.Trim()
    }

    $promptTop = $null
    try { $promptTop = [Console]::CursorTop } catch { $canNavigate = $false }
    if (-not $canNavigate) {
        $raw = Read-Host $PromptLabel
        if ($null -eq $raw) { return '0' }
        return $raw.Trim()
    }

    try {
        $bufferWidth = [Console]::BufferWidth
        $maxLen = [Math]::Max($bufferWidth - 1, 1)
        $selectedPos = 0
        $typed = ''

        $drawEntry = {
            param($entryIndex, $isSelected)
            [Console]::SetCursorPosition(0, $entryTop + $entryIndex)
            $e = $Entries[$entryIndex]
            $line = "  [{0}] {1}" -f $e.Key, $e.Label
            if ($line.Length -gt $maxLen) { $line = $line.Substring(0, $maxLen) }
            $padded = $line.PadRight($maxLen)
            if ($isSelected) {
                Write-Host ("> " + $padded.Substring(2)) -ForegroundColor Black -BackgroundColor Cyan -NoNewline
            } else {
                Write-Host $padded -NoNewline
            }
        }
        $drawPrompt = {
            [Console]::SetCursorPosition(0, $promptTop)
            $line = "${PromptLabel}: $typed"
            if ($line.Length -gt $maxLen) { $line = $line.Substring(0, $maxLen) }
            Write-Host $line.PadRight($maxLen) -NoNewline
            [Console]::SetCursorPosition([Math]::Min($line.Length, $maxLen), $promptTop)
        }

        & $drawEntry $selectable[$selectedPos] $true
        & $drawPrompt

        while ($true) {
            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow' {
                    & $drawEntry $selectable[$selectedPos] $false
                    $selectedPos = if ($selectedPos -eq 0) { $selectable.Count - 1 } else { $selectedPos - 1 }
                    & $drawEntry $selectable[$selectedPos] $true
                    $typed = ''
                    & $drawPrompt
                }
                'DownArrow' {
                    & $drawEntry $selectable[$selectedPos] $false
                    $selectedPos = ($selectedPos + 1) % $selectable.Count
                    & $drawEntry $selectable[$selectedPos] $true
                    $typed = ''
                    & $drawPrompt
                }
                'Enter' {
                    [Console]::SetCursorPosition(0, $promptTop + 1)
                    if ([string]::IsNullOrWhiteSpace($typed)) { return $Entries[$selectable[$selectedPos]].Key }
                    return $typed.Trim()
                }
                'Escape' {
                    [Console]::SetCursorPosition(0, $promptTop + 1)
                    return '0'
                }
                'Backspace' {
                    if ($typed.Length -gt 0) {
                        $typed = $typed.Substring(0, $typed.Length - 1)
                        & $drawPrompt
                    }
                }
                default {
                    if ($key.KeyChar -and -not [char]::IsControl($key.KeyChar)) {
                        $typed += $key.KeyChar
                        & $drawPrompt
                    }
                }
            }
        }
    } catch {
        Write-Host ""
        Write-Host "  (Arrow-key navigation unavailable in this console -- switched to typed input.)" -ForegroundColor DarkGray
        $raw = Read-Host $PromptLabel
        if ($null -eq $raw) { return '0' }   # stdin EOF: treat as Back, same as Escape
        return $raw.Trim()
    }
}

function Show-DevKitModuleMenu {
    param([Parameter(Mandatory = $true)]$Module)
    Show-Header $Module.Name
    if (-not [string]::IsNullOrWhiteSpace([string]$Module.Description)) {
        Write-Host "  $($Module.Description)" -ForegroundColor Gray
        Write-Host ""
    }
}

function Start-DevKitModuleTools {
    <#
    .SYNOPSIS
        Generic submenu loop for any manifest-backed tool category.
    .PARAMETER FolderPath
        Full path to the category folder (e.g. .../ports).
    #>
    param([Parameter(Mandatory = $true)][string]$FolderPath)

    $module = Get-DevKitModule -FolderPath $FolderPath

    while ($true) {
        Show-DevKitModuleMenu -Module $module
        $entries = @()
        foreach ($item in $module.Items) { $entries += @{ Key = $item.Key; Label = $item.Label } }
        $entries += @{ Key = '?'; Label = 'Help - what does each option do?' }
        $entries += @{ Key = '0'; Label = 'Back' }
        $choice = Show-DevKitInteractiveMenu -Entries $entries -PromptLabel 'Select option'
        $trimmed = $choice.Trim()

        if ($trimmed -eq '0') { return }

        if ($trimmed -eq '?') {
            Show-DevKitModuleMenu -Module $module
            foreach ($item in $module.Items) {
                Write-Host ("  [{0}] {1}" -f $item.Key, $item.Label) -ForegroundColor Cyan
                if (-not [string]::IsNullOrWhiteSpace([string]$item.Help)) {
                    Write-Host "      $($item.Help)" -ForegroundColor Gray
                } else {
                    Write-Host "      (no additional help for this item)" -ForegroundColor Gray
                }
            }
            Write-Host ""
            Read-Host "Press Enter to return to the menu"
            continue
        }

        $forceReprompt = $false
        $keyToMatch = $trimmed
        if ($trimmed -match '^(.+)p$') {
            $keyToMatch = $matches[1]
            $forceReprompt = $true
        }

        $item = $module.Items | Where-Object { $_.Key -eq $keyToMatch } | Select-Object -First 1
        if (-not $item) {
            Write-Host "  Invalid option. Press Enter to continue." -ForegroundColor Red
            Read-Host
            continue
        }

        Clear-Host
        Invoke-DevKitTool -FolderPath $FolderPath -Item $item -ForceReprompt:$forceReprompt
        Read-Host "Press Enter to continue"
    }
}

# ==================== OUTPUT HELPERS ====================

function Write-DevKitHeader {
    param([string]$Title)
    Write-Host "`nNorthstar DevKit - $Title`n" -ForegroundColor Cyan
}

function Write-DevKitStep {
    param([string]$Message)
    # Cyan, not Yellow: Yellow is reserved for real warnings (per AGENTS.md's
    # documented color convention). Routine in-progress chrome using the same
    # color as an actual warning diluted its meaning across the codebase.
    Write-Host "  $Message..." -ForegroundColor Cyan -NoNewline
}

function Write-DevKitDone {
    Write-Host " DONE" -ForegroundColor Green
}

function Write-DevKitSkip {
    Write-Host " SKIP" -ForegroundColor Gray
}

function Write-DevKitError {
    param([string]$Message)
    Write-Host " ERROR: $Message" -ForegroundColor Red
}

function Write-DevKitInfo {
    param([string]$Message)
    Write-Host "  $Message" -ForegroundColor Gray
}

# ==================== ENVIRONMENT / PRIVILEGE ====================

function Test-DevKitAdmin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-DevKitCommand {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-DevKitWindowsExecutable {
    <#
    .SYNOPSIS
        Resolves a command name to something safe to invoke directly with "&".
    .DESCRIPTION
        A real bug hit while building the AI CLI tools: on a machine with more
        than one "gh" on PATH, Get-Command's first match was an extension-less
        POSIX shim (an npm-installed unrelated "gh" package, not GitHub CLI).
        Invoking that directly with "&" makes PowerShell fall back to
        ShellExecute, which pops a real "Select an app to open" Windows dialog
        instead of failing cleanly - and can leave a caller waiting on GUI
        input that never arrives. Only ever invoke a match with a recognized
        Windows-executable extension (or a native PS command/function/alias,
        which never hits ShellExecute); anything else should be treated as
        "found but not safely runnable" rather than guessed at.
    #>
    param([Parameter(Mandatory = $true)][string]$Name)

    $appMatches = @(Get-Command $Name -All -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandType -eq 'Application' -and $_.Source -match '\.(exe|cmd|bat)$'
    })
    if ($appMatches.Count -gt 0) { return $appMatches[0] }

    $anyMatch = Get-Command $Name -ErrorAction SilentlyContinue
    if ($anyMatch -and $anyMatch.CommandType -ne 'Application') { return $anyMatch }

    return $null
}

# ==================== PATH HELPERS ====================

function Resolve-DevKitDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        throw "Path not found: $Path"
    }

    $resolved = (Resolve-Path $Path).Path
    if (-not (Test-Path $resolved -PathType Container)) {
        throw "Path is not a directory: $resolved"
    }

    return $resolved
}

function Invoke-DevKitInDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock
    )

    $resolved = Resolve-DevKitDirectory -Path $Path
    Push-Location $resolved
    try {
        & $ScriptBlock
    } finally {
        Pop-Location
    }
}

# ==================== FILE / CACHE HELPERS ====================

function Remove-DevKitNodeModules {
    <#
    .SYNOPSIS
        Deletes node_modules from the given project directory.
    .DESCRIPTION
        Long-path-safe deletion: mirrors an empty folder over node_modules
        with robocopy, then removes the (now-empty) directory tree.
        Robocopy is bounded with /R:2 /W:1 so a locked file cannot hang the
        call forever. Returns $false both when node_modules never existed
        and when the delete attempt could not fully remove it (e.g. locked
        files); throws if robocopy itself reports a hard failure
        (exit code >= 8), which is distinct from either $false case.
    .PARAMETER Path
        The project directory containing node_modules.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $resolved = Resolve-DevKitDirectory -Path $Path
    $nmPath = Join-Path $resolved "node_modules"

    if (-not (Test-Path $nmPath)) {
        return $false
    }

    # Long-path-safe deletion: mirror an empty folder, then remove
    $empty = Join-Path $env:TEMP "empty_devkit_$(Get-Random)"
    try {
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        robocopy $empty $nmPath /MIR /MT:8 /R:2 /W:1 /NFL /NDL /NJH /NJS | Out-Null
        # Robocopy exit codes 0-7 are all "success" (bitmask of what happened,
        # e.g. files copied/deleted); only >=8 indicates a real failure.
        if ($LASTEXITCODE -ge 8) {
            throw "robocopy failed to clear '$nmPath' (exit code $LASTEXITCODE) - files may be locked by a running process."
        }
        Remove-Item -Path $nmPath -Recurse -Force -ErrorAction SilentlyContinue
    } finally {
        if (Test-Path $empty) {
            Remove-Item $empty -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if (Test-Path $nmPath) {
        # Removal did not fully succeed (e.g. locked files) - report failure
        # instead of pretending the directory is gone.
        return $false
    }

    return $true
}

function Clear-DevKitNodeCaches {
    <#
    .SYNOPSIS
        Removes common Node.js dev/framework caches from a project directory.
    .DESCRIPTION
        By default only removes non-build cache folders: .next,
        node_modules\.cache, node_modules\.vite. Build-output folders
        (dist, and the project-root .vite folder) are NOT touched unless
        -IncludeBuildOutput is passed, since deleting them can silently wipe
        a production build with no confirmation from the caller.
    .PARAMETER Path
        The project directory to clean.
    .PARAMETER IncludeTurbo
        Also remove the Turborepo cache (.turbo).
    .PARAMETER IncludeBuildOutput
        Also remove build-output folders (dist, .vite at the project root).
        Defaults to $false for backward compatibility.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [switch]$IncludeTurbo,

        [switch]$IncludeBuildOutput
    )

    $resolved = Resolve-DevKitDirectory -Path $Path
    $cachePaths = @(
        (Join-Path $resolved ".next"),
        (Join-Path (Join-Path $resolved "node_modules") ".cache"),
        (Join-Path (Join-Path $resolved "node_modules") ".vite")
    )

    if ($IncludeBuildOutput) {
        $cachePaths += @(
            (Join-Path $resolved "dist"),
            (Join-Path $resolved ".vite")
        )
    }

    if ($IncludeTurbo) {
        # .next\cache lives under .next, which the base list already removes
        # wholesale, and node_modules\.cache is already in the base list -
        # only .turbo itself is unique to this switch.
        $cachePaths += (Join-Path $resolved ".turbo")
    }

    $cachePaths = $cachePaths | Select-Object -Unique

    $found = $false
    foreach ($cachePath in $cachePaths) {
        if (Test-Path $cachePath) {
            Remove-Item -Path $cachePath -Recurse -Force -ErrorAction SilentlyContinue
            $found = $true
        }
    }

    return $found
}

# ==================== PACKAGE MANAGER HELPERS ====================

function Get-DevKitPackageManager {
    <#
    .SYNOPSIS
        Detects which package manager a project uses.
    .DESCRIPTION
        Checks lock files first (bun.lock / bun.lockb, pnpm-lock.yaml,
        yarn.lock, package-lock.json, in that priority order). If none are
        found, falls back to package.json's corepack "packageManager" field
        (e.g. "pnpm@8.15.0") so freshly-scaffolded projects that don't yet
        have a lock file are still detected correctly. Defaults to npm if
        nothing matches. bun.lock (the text lockfile bun writes since 1.2)
        is probed before bun.lockb (the legacy binary one); they share one
        priority slot, so either one wins over every other manager's file.
    .PARAMETER Path
        The project directory to inspect.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $resolved = Resolve-DevKitDirectory -Path $Path

    $managers = @(
        @{ Lock = "bun.lock"; Command = "bun"; Install = @("install") },
        @{ Lock = "bun.lockb"; Command = "bun"; Install = @("install") },
        @{ Lock = "pnpm-lock.yaml"; Command = "pnpm"; Install = @("install") },
        @{ Lock = "yarn.lock"; Command = "yarn"; Install = @("install") },
        @{ Lock = "package-lock.json"; Command = "npm"; Install = @("install") }
    )

    foreach ($manager in $managers) {
        if (Test-Path (Join-Path $resolved $manager.Lock)) {
            return $manager
        }
    }

    # No lock file found - check package.json's corepack "packageManager"
    # field (e.g. "pnpm@8.15.0") before defaulting to npm.
    $packageJsonPath = Join-Path $resolved "package.json"
    if (Test-Path $packageJsonPath) {
        try {
            $packageJson = Get-Content $packageJsonPath -Raw | ConvertFrom-Json
            if ($packageJson.PSObject.Properties.Name -contains "packageManager" -and $packageJson.packageManager) {
                $managerName = ($packageJson.packageManager -split "@")[0].Trim()
                $matched = @($managers | Where-Object { $_.Command -eq $managerName })
                if ($matched.Count -gt 0) {
                    return $matched[0]
                }
            }
        } catch {
            # Malformed package.json - fall through to the npm default
        }
    }

    # Default to npm
    return @{ Lock = $null; Command = "npm"; Install = @("install") }
}

function Invoke-DevKitPackageInstall {
    <#
    .SYNOPSIS
        Runs the install command for a project's package manager.
    .PARAMETER Path
        The project directory to install in.
    .PARAMETER Manager
        Optional pre-resolved package manager (as returned by
        Get-DevKitPackageManager). Pass this when the caller already
        resolved the manager earlier (e.g. before deleting lock files), so
        this function does not need to re-derive it from a directory whose
        lock files may no longer be present. When omitted, the manager is
        auto-detected from $Path as before.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [hashtable]$Manager
    )

    $manager = $Manager
    if (-not $manager) {
        $manager = Get-DevKitPackageManager -Path $Path
    }

    if (-not (Test-DevKitCommand $manager.Command)) {
        throw "$($manager.Command) is not installed or not in PATH."
    }

    & $manager.Command @($manager.Install)
    if ($LASTEXITCODE -ne 0) {
        throw "Package install failed with exit code $LASTEXITCODE"
    }
}

function Invoke-DevKitPackageCacheClean {
    <#
    .SYNOPSIS
        Cleans the local cache for a project's package manager.
    .PARAMETER Path
        The project directory whose package manager cache to clean.
    .PARAMETER Manager
        Optional pre-resolved package manager (as returned by
        Get-DevKitPackageManager). Pass this when the caller already
        resolved the manager earlier (e.g. before deleting lock files), so
        this function does not need to re-derive it from a directory whose
        lock files may no longer be present. When omitted, the manager is
        auto-detected from $Path as before.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [hashtable]$Manager
    )

    $manager = $Manager
    if (-not $manager) {
        $manager = Get-DevKitPackageManager -Path $Path
    }

    if ($manager.Command -eq "npm") {
        if (-not (Test-DevKitCommand "npm")) { throw "npm is not installed or not in PATH." }
        npm cache clean --force | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "npm cache clean failed" }
    }
    elseif ($manager.Command -eq "pnpm") {
        if (-not (Test-DevKitCommand "pnpm")) { throw "pnpm is not installed or not in PATH." }
        pnpm store prune | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "pnpm store prune failed" }
    }
    elseif ($manager.Command -eq "yarn") {
        if (-not (Test-DevKitCommand "yarn")) { throw "yarn is not installed or not in PATH." }
        yarn cache clean --all | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "yarn cache clean failed" }
    }
    elseif ($manager.Command -eq "bun") {
        if (-not (Test-DevKitCommand "bun")) { throw "bun is not installed or not in PATH." }
        bun pm cache rm | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "bun cache clean failed" }
    }
}

# ==================== PORT / PROCESS HELPERS ====================

function Get-DevKitProcessByPort {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 65535)]
        [int]$Port
    )

    # Prefer the real listener: a stale non-Listen row (e.g. TIME_WAIT with
    # OwningProcess 0) can sort ahead of it in the raw Get-NetTCPConnection
    # output and would otherwise win the -First 1 pick, reporting PID 0.
    $connections = @(Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue)
    $connection = $connections | Where-Object { $_.State -eq 'Listen' -and $_.OwningProcess -ne 0 } | Select-Object -First 1
    if (-not $connection) { $connection = $connections | Select-Object -First 1 }
    if (-not $connection) {
        return $null
    }

    $process = Get-Process -Id $connection.OwningProcess -ErrorAction SilentlyContinue
    return [PSCustomObject]@{
        Port    = $Port
        PID     = $connection.OwningProcess
        Name    = if ($process) { $process.ProcessName } else { "Unknown" }
        Path    = if ($process) { $process.Path } else { $null }
    }
}

function ConvertFrom-DevKitExcludedPortRanges {
    <#
    .SYNOPSIS
        Parses `netsh interface ipv4 show excludedportrange protocol=tcp`
        output into a list of port-range records.
    .DESCRIPTION
        The netsh table is localized (its header text varies by Windows
        display language), so parsing never matches literal header words:
        a line is a data row when its first two whitespace-separated tokens
        both parse as integers (the table's Start Port / End Port columns).
        That single rule skips the title, blank lines, the header row, the
        dashed separator row, and the trailing "* - Administered port
        exclusions." footnote in every locale. A row whose two columns are
        equal (e.g. "5357  5357") is a real single-port exclusion and is
        returned as a range with Start -eq End; any third column netsh may
        print (the "*" marker) is ignored.
    .PARAMETER Output
        The full captured text of the netsh command (may be empty).
    .OUTPUTS
        An array (possibly empty) of hashtables @{ Start = [int]; End = [int] },
        in the order the rows appeared. Always a real array - the "return ,$"
        pattern keeps a single result from unrolling to a bare hashtable.
    .EXAMPLE
        $ranges = ConvertFrom-DevKitExcludedPortRanges -Output (netsh interface ipv4 show excludedportrange protocol=tcp | Out-String)
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Output)

    $results = @()
    if (-not [string]::IsNullOrWhiteSpace($Output)) {
        foreach ($line in ($Output -split "\r?\n")) {
            $tokens = @($line.Trim() -split '\s+')
            if ($tokens.Count -lt 2) { continue }
            $start = 0
            $end = 0
            if ([int]::TryParse($tokens[0], [ref]$start) -and [int]::TryParse($tokens[1], [ref]$end)) {
                $results += @{ Start = $start; End = $end }
            }
        }
    }
    return ,$results
}

# ==================== FOLDER / FILE BROWSER ====================

function Initialize-DevKitFormsInterop {
    <#
    .SYNOPSIS
        One-time native interop compile for a real console-window owner (so a
        dialog z-orders correctly above the console instead of floating
        globally topmost). Idempotent and cheap after first use - done lazily
        here rather than at dot-source time, because most tool runs never
        show a dialog and shouldn't pay the WinForms/C# compile cost.
    #>
    if ('DevKit.NativeMethods' -as [type]) { return }
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    Add-Type -ReferencedAssemblies 'System.Windows.Forms' -TypeDefinition @'
using System;
using System.Windows.Forms;
namespace DevKit {
    public static class NativeMethods {
        [System.Runtime.InteropServices.DllImport("kernel32.dll")]
        public static extern IntPtr GetConsoleWindow();
    }
    public class Win32Window : IWin32Window {
        private IntPtr _handle;
        public Win32Window(IntPtr handle) { _handle = handle; }
        public IntPtr Handle { get { return _handle; } }
    }
}
'@ -ErrorAction SilentlyContinue
}

function Show-DevKitFolderBrowser {
    <#
    .SYNOPSIS
        Shows a folder-browse dialog from a console host, regardless of the
        host's own apartment state.
    .DESCRIPTION
        Windows PowerShell 5.1's console host defaults to STA; pwsh's
        console host defaults to MTA. FolderBrowserDialog is OLE-based and
        requires STA. Rather than depend on whichever apartment state the
        calling host happens to be in (which silently varies by which
        PowerShell launched DevKit), this spins up a dedicated Runspace with
        ApartmentState=STA, shows the dialog there, and marshals only the
        resulting path string back out.
    .PARAMETER Description
        Text shown at the top of the dialog.
    .PARAMETER InitialDirectory
        Directory the dialog should start in, if it exists.
    .OUTPUTS
        [string] the chosen full path, or $null if the user cancelled or the
        folder browser is unavailable on this machine.
    #>
    [CmdletBinding()]
    param(
        [string]$Description = "Select a project folder",
        [string]$InitialDirectory
    )

    Initialize-DevKitFormsInterop   # process-wide types used inside the STA runspace below

    try {
        $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($iss)
        $rs.ApartmentState = [System.Threading.ApartmentState]::STA
        $rs.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
        $rs.Open()
    } catch {
        Write-DevKitError "Could not start a folder-browser session: $_"
        return $null
    }

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs

    [void]$ps.AddScript({
        param($Description, $InitialDirectory)

        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        } catch {
            return @{ Ok = $false; Error = "Folder browser unavailable on this PowerShell install (Desktop Runtime not found). Type the path manually, or reinstall PowerShell via the official MSI/winget package." }
        }

        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = $Description
        $dialog.ShowNewFolderButton = $true
        if ($InitialDirectory -and (Test-Path $InitialDirectory)) {
            $dialog.SelectedPath = $InitialDirectory
        }

        $consoleHwnd = [DevKit.NativeMethods]::GetConsoleWindow()
        $owner = $null
        if ($consoleHwnd -ne [IntPtr]::Zero) {
            $owner = New-Object DevKit.Win32Window ($consoleHwnd)
        }

        $result = if ($owner) { $dialog.ShowDialog($owner) } else { $dialog.ShowDialog() }

        if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
            return @{ Ok = $true; Path = $dialog.SelectedPath }
        }
        return @{ Ok = $true; Path = $null }
    }).AddArgument($Description).AddArgument($InitialDirectory)

    try {
        $outcome = ($ps.Invoke() | Select-Object -First 1)
    } catch {
        Write-DevKitError "Folder browser failed: $_"
        $ps.Dispose(); $rs.Close(); $rs.Dispose()
        return $null
    }
    $ps.Dispose()
    $rs.Close()
    $rs.Dispose()

    if (-not $outcome -or -not $outcome.Ok) {
        if ($outcome -and $outcome.Error) { Write-DevKitError $outcome.Error }
        return $null
    }
    return $outcome.Path
}

function Show-DevKitFileBrowser {
    <#
    .SYNOPSIS
        Shows a file-open dialog from a console host, regardless of the
        host's own apartment state. Same STA-runspace approach as
        Show-DevKitFolderBrowser.
    .PARAMETER Filter
        Standard Windows Forms file-dialog filter string, e.g.
        "JSON files (*.json)|*.json|All files (*.*)|*.*"
    .OUTPUTS
        [string] the chosen full file path, or $null if cancelled/unavailable.
    #>
    [CmdletBinding()]
    param(
        [string]$Description = "Select a file",
        [string]$InitialDirectory,
        [string]$Filter = "All files (*.*)|*.*"
    )

    Initialize-DevKitFormsInterop   # process-wide types used inside the STA runspace below

    try {
        $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($iss)
        $rs.ApartmentState = [System.Threading.ApartmentState]::STA
        $rs.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
        $rs.Open()
    } catch {
        Write-DevKitError "Could not start a file-browser session: $_"
        return $null
    }

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs

    [void]$ps.AddScript({
        param($Description, $InitialDirectory, $Filter)

        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        } catch {
            return @{ Ok = $false; Error = "File browser unavailable on this PowerShell install (Desktop Runtime not found). Type the path manually." }
        }

        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title = $Description
        $dialog.Filter = $Filter
        $dialog.Multiselect = $false
        if ($InitialDirectory -and (Test-Path $InitialDirectory)) {
            $dialog.InitialDirectory = $InitialDirectory
        }

        $consoleHwnd = [DevKit.NativeMethods]::GetConsoleWindow()
        $owner = $null
        if ($consoleHwnd -ne [IntPtr]::Zero) {
            $owner = New-Object DevKit.Win32Window ($consoleHwnd)
        }

        $result = if ($owner) { $dialog.ShowDialog($owner) } else { $dialog.ShowDialog() }

        if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
            return @{ Ok = $true; Path = $dialog.FileName }
        }
        return @{ Ok = $true; Path = $null }
    }).AddArgument($Description).AddArgument($InitialDirectory).AddArgument($Filter)

    try {
        $outcome = ($ps.Invoke() | Select-Object -First 1)
    } catch {
        Write-DevKitError "File browser failed: $_"
        $ps.Dispose(); $rs.Close(); $rs.Dispose()
        return $null
    }
    $ps.Dispose()
    $rs.Close()
    $rs.Dispose()

    if (-not $outcome -or -not $outcome.Ok) {
        if ($outcome -and $outcome.Error) { Write-DevKitError $outcome.Error }
        return $null
    }
    return $outcome.Path
}

# ==================== PROJECT REGISTRY ====================

function Get-DevKitProjectsFile {
    $dir = Join-Path $env:LOCALAPPDATA "NorthstarDevKit"
    if (-not (Test-Path $dir)) {
        # Best-effort, same as Get-DevKitSettingsFile: downstream readers
        # tolerate the registry file simply being absent.
        try { New-Item -ItemType Directory -Path $dir -Force | Out-Null } catch { }
    }
    return Join-Path $dir "projects.json"
}

function Save-DevKitProjectRegistry {
    param([Parameter(Mandatory = $true)]$Registry)

    $path = Get-DevKitProjectsFile
    $tempPath = "$path.tmp.$PID"
    try {
        # Merge over whatever is on disk right now instead of blindly
        # overwriting: another DevKit process (e.g. the long-lived widget) may
        # have added or updated a project since this caller loaded its copy,
        # and last-writer-wins would silently drop that. The caller's version
        # wins per project id, and its activeProjectId wins outright. An
        # on-disk project this process never read (absent from the
        # Get-DevKitProjectRegistry baseline, i.e. a concurrent add) is kept;
        # one the caller read and deliberately dropped (e.g.
        # Remove-DevKitLinkedProject) stays dropped. Best-effort: any
        # read/parse failure falls back to the caller's copy as-is.
        try {
            if (Test-Path $path) {
                $raw = Get-Content -Path $path -Raw -ErrorAction Stop
                if (-not [string]::IsNullOrWhiteSpace($raw)) {
                    $onDisk = $raw | ConvertFrom-Json -ErrorAction Stop
                    if ($null -ne $onDisk.projects) {
                        $callerIds = @($Registry.projects | ForEach-Object { $_.id })
                        $kept = @()
                        foreach ($diskProject in @($onDisk.projects)) {
                            if ($callerIds -contains $diskProject.id) { continue }
                            if ($null -eq $script:DevKitProjectRegistryReadIds -or
                                -not ($script:DevKitProjectRegistryReadIds -contains $diskProject.id)) {
                                $kept += $diskProject
                            }
                        }
                        if ($kept.Count -gt 0) {
                            $Registry.projects = @(@($Registry.projects) + $kept)
                        }
                    }
                }
            }
        } catch { }
        $Registry | ConvertTo-Json -Depth 6 | Set-Content -Path $tempPath -Encoding UTF8
        Move-Item -Path $tempPath -Destination $path -Force
    } catch {
        if (Test-Path $tempPath) { Remove-Item $tempPath -Force -ErrorAction SilentlyContinue }
        throw "Failed to save project registry: $_"
    }
}

function Get-DevKitProjectRegistry {
    <# .OUTPUTS PSCustomObject with .schemaVersion / .activeProjectId / .projects (array, always) #>
    $path = Get-DevKitProjectsFile
    $empty = [PSCustomObject]@{ schemaVersion = 1; activeProjectId = $null; projects = @() }

    # Baseline of project ids this process last read, for
    # Save-DevKitProjectRegistry's merge: it distinguishes "on disk but the
    # caller never saw it" (a concurrent add - keep) from "the caller saw it
    # and deliberately dropped it" (a Remove - keep the deletion).
    $script:DevKitProjectRegistryReadIds = @()

    if (-not (Test-Path $path)) { return $empty }

    try {
        $raw = Get-Content -Path $path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $empty }
        $data = $raw | ConvertFrom-Json -ErrorAction Stop
        # ConvertFrom-Json returns a bare PSCustomObject (not a 1-item array)
        # when "projects" has exactly one element - always wrap with @().
        $projects = @($data.projects)
        $script:DevKitProjectRegistryReadIds = @($projects | ForEach-Object { $_.id })
        return [PSCustomObject]@{
            schemaVersion   = $data.schemaVersion
            activeProjectId = $data.activeProjectId
            projects        = $projects
        }
    } catch {
        # A corrupt/hand-edited file must never crash DevKit.ps1 - Show-Header
        # reads the registry on every menu redraw. Quarantine and start clean.
        $backupPath = "$path.corrupt-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))"
        try { Move-Item -Path $path -Destination $backupPath -Force -ErrorAction SilentlyContinue } catch {}
        Write-DevKitError "Project registry was corrupted and has been reset. Backup: $backupPath"
        return $empty
    }
}

function Get-DevKitLinkedProjects {
    <# .OUTPUTS array of project PSCustomObjects, each with an extra computed .Missing [bool] #>
    $registry = Get-DevKitProjectRegistry
    $result = @()
    foreach ($p in $registry.projects) {
        $missing = -not (Test-Path -LiteralPath $p.path)
        $result += ($p | Select-Object *, @{ Name = 'Missing'; Expression = { $missing } })
    }
    return $result
}

function Get-DevKitProjectTags {
    param([Parameter(Mandatory = $true)][string]$Path)
    $tags = @()
    if (Test-Path (Join-Path $Path "package.json")) { $tags += "node" }
    if (Test-Path (Join-Path $Path ".git")) { $tags += "git" }
    if ((Test-Path (Join-Path $Path "next.config.js")) -or
        (Test-Path (Join-Path $Path "next.config.mjs")) -or
        (Test-Path (Join-Path $Path "next.config.ts"))) { $tags += "nextjs" }
    if ((Test-Path (Join-Path $Path "vite.config.js")) -or
        (Test-Path (Join-Path $Path "vite.config.ts"))) { $tags += "vite" }
    if ((Test-Path (Join-Path $Path "Dockerfile")) -or
        (Test-Path (Join-Path $Path "docker-compose.yml"))) { $tags += "docker" }
    return $tags
}

function Add-DevKitLinkedProject {
    <#
    .PARAMETER Path  Folder to link (must exist).
    .PARAMETER Name  Display name; defaults to the leaf folder name.
    .OUTPUTS the (new or matched-existing) project PSCustomObject.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Name
    )

    $resolved = Resolve-DevKitDirectory -Path $Path
    $registry = Get-DevKitProjectRegistry
    $projects = @($registry.projects)

    $existing = $projects | Where-Object {
        [string]::Equals($_.path.TrimEnd('\'), $resolved.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 1

    if ($existing) {
        return (Update-DevKitProjectLastUsed -Id $existing.id)
    }

    if (-not $Name) { $Name = Split-Path -Path $resolved -Leaf }

    $newProject = [PSCustomObject]@{
        id          = [guid]::NewGuid().ToString()
        name        = $Name
        path        = $resolved
        tags        = @(Get-DevKitProjectTags -Path $resolved)
        pinned      = $false
        addedUtc    = [DateTime]::UtcNow.ToString("o")
        lastUsedUtc = [DateTime]::UtcNow.ToString("o")
        useCount    = 1
    }

    $registry.projects = @($projects + $newProject)
    Save-DevKitProjectRegistry -Registry $registry
    return $newProject
}

function Update-DevKitProjectLastUsed {
    param([Parameter(Mandatory = $true)][string]$Id)
    $registry = Get-DevKitProjectRegistry
    $projects = @($registry.projects)
    $match = $null
    foreach ($p in $projects) {
        if ($p.id -eq $Id) {
            $p.lastUsedUtc = [DateTime]::UtcNow.ToString("o")
            $p.useCount = [int]$p.useCount + 1
            $match = $p
        }
    }
    $registry.projects = $projects
    Save-DevKitProjectRegistry -Registry $registry
    return $match
}

function Remove-DevKitLinkedProject {
    param([Parameter(Mandatory = $true)][string]$Id)
    $registry = Get-DevKitProjectRegistry
    $registry.projects = @($registry.projects | Where-Object { $_.id -ne $Id })
    if ($registry.activeProjectId -eq $Id) { $registry.activeProjectId = $null }
    Save-DevKitProjectRegistry -Registry $registry
    # Invalidate DevKit.ps1's Show-Header cache: the removed project may have
    # been the active one (same contract as Set/Clear-DevKitActiveProject).
    $global:DevKitActiveProjectCache = $null
}

function Rename-DevKitLinkedProject {
    param([Parameter(Mandatory = $true)][string]$Id, [Parameter(Mandatory = $true)][string]$NewName)
    $registry = Get-DevKitProjectRegistry
    foreach ($p in $registry.projects) { if ($p.id -eq $Id) { $p.name = $NewName } }
    Save-DevKitProjectRegistry -Registry $registry
    # Invalidate DevKit.ps1's Show-Header cache: it may be displaying the old name.
    $global:DevKitActiveProjectCache = $null
}

function Set-DevKitProjectPinned {
    param([Parameter(Mandatory = $true)][string]$Id, [Parameter(Mandatory = $true)][bool]$Pinned)
    $registry = Get-DevKitProjectRegistry
    foreach ($p in $registry.projects) { if ($p.id -eq $Id) { $p.pinned = $Pinned } }
    Save-DevKitProjectRegistry -Registry $registry
}

function Repair-DevKitLinkedProject {
    <# Relinks an existing entry (keeps id/name/tags/history) to a new path. #>
    param([Parameter(Mandatory = $true)][string]$Id, [Parameter(Mandatory = $true)][string]$NewPath)
    $resolved = Resolve-DevKitDirectory -Path $NewPath
    $registry = Get-DevKitProjectRegistry
    foreach ($p in $registry.projects) {
        if ($p.id -eq $Id) {
            $p.path = $resolved
            $p.tags = @(Get-DevKitProjectTags -Path $resolved)
            $p.lastUsedUtc = [DateTime]::UtcNow.ToString("o")
        }
    }
    Save-DevKitProjectRegistry -Registry $registry
    # Invalidate DevKit.ps1's Show-Header cache: it may be displaying the old path.
    $global:DevKitActiveProjectCache = $null
}

function Get-DevKitActiveProject {
    <# .OUTPUTS the active project PSCustomObject (with computed .Missing), or $null #>
    $registry = Get-DevKitProjectRegistry
    if (-not $registry.activeProjectId) { return $null }
    $match = $registry.projects | Where-Object { $_.id -eq $registry.activeProjectId } | Select-Object -First 1
    if (-not $match) { return $null }
    $missing = -not (Test-Path -LiteralPath $match.path)
    return ($match | Select-Object *, @{ Name = 'Missing'; Expression = { $missing } })
}

function Set-DevKitActiveProject {
    param([Parameter(Mandatory = $true)][string]$Id)
    $registry = Get-DevKitProjectRegistry
    $registry.activeProjectId = $Id
    Save-DevKitProjectRegistry -Registry $registry
    Update-DevKitProjectLastUsed -Id $Id | Out-Null
    $global:DevKitActiveProjectCache = $null
}

function Clear-DevKitActiveProject {
    $registry = Get-DevKitProjectRegistry
    $registry.activeProjectId = $null
    Save-DevKitProjectRegistry -Registry $registry
    $global:DevKitActiveProjectCache = $null
}

function Resolve-DevKitMissingActiveProject {
    <#
    .SYNOPSIS
        Interactively resolves a linked/active project whose saved path no
        longer exists on disk (moved, renamed, or deleted).
    .OUTPUTS
        The repaired project PSCustomObject, or $null if the caller should
        fall through to the normal interactive picker.
    #>
    param([Parameter(Mandatory = $true)]$Project)

    Write-Host ""
    Write-Host "  ! Project '$($Project.name)' points to a path that no longer exists:" -ForegroundColor DarkYellow
    Write-Host "      $($Project.path)" -ForegroundColor DarkYellow
    Write-Host "    It may have been moved, renamed, or deleted." -ForegroundColor DarkYellow
    Write-Host ""
    Write-Host "    [1] Locate it now (browse to the new location and relink)"
    Write-Host "    [2] Unlink it and pick a different project"
    Write-Host "    [3] Type the corrected path manually"
    Write-Host "    [0] Cancel"
    $c = Read-Host "Select option"

    switch ($c) {
        '1' {
            $seed = Split-Path -Path $Project.path -Parent
            if (-not (Test-Path $seed)) { $seed = $null }
            $newPath = Show-DevKitFolderBrowser -Description "Locate '$($Project.name)'" -InitialDirectory $seed
            if ($newPath) {
                Repair-DevKitLinkedProject -Id $Project.id -NewPath $newPath
                Set-DevKitActiveProject -Id $Project.id
                return (Get-DevKitActiveProject)
            }
            return $null
        }
        '2' {
            Remove-DevKitLinkedProject -Id $Project.id
            return $null
        }
        '3' {
            $typed = Read-Host "Enter corrected path"
            if (Test-Path $typed) {
                Repair-DevKitLinkedProject -Id $Project.id -NewPath $typed
                Set-DevKitActiveProject -Id $Project.id
                return (Get-DevKitActiveProject)
            }
            Write-Host "  ERROR: Path not found: $typed" -ForegroundColor Red
            return $null
        }
        default { return $null }
    }
}

function Invoke-DevKitManageProjects {
    <#
    .SYNOPSIS
        Rename / pin / unlink / relink submenu for the linked-projects list.
    #>
    while ($true) {
        Clear-Host
        Write-Host "=============================================" -ForegroundColor Cyan
        Write-Host "  Manage Linked Projects" -ForegroundColor Cyan
        Write-Host "=============================================" -ForegroundColor Cyan
        Write-Host ""

        $linked = @(Get-DevKitLinkedProjects | Sort-Object -Property @{Expression = 'pinned'; Descending = $true }, @{Expression = 'lastUsedUtc'; Descending = $true })

        if ($linked.Count -eq 0) {
            Write-Host "  No linked projects yet." -ForegroundColor Gray
            Read-Host "Press Enter to go back"
            return
        }

        for ($i = 0; $i -lt $linked.Count; $i++) {
            $p = $linked[$i]
            $pin = if ($p.pinned) { "*" } else { " " }
            if ($p.Missing) {
                Write-Host ("    [{0}] {1} {2,-22} {3,-30} !! MISSING" -f ($i + 1), $pin, $p.name, $p.path) -ForegroundColor DarkYellow
            } else {
                Write-Host ("    [{0}] {1} {2,-22} {3,-30} [{4}]" -f ($i + 1), $pin, $p.name, $p.path, ($p.tags -join ', '))
            }
        }
        Write-Host ""
        Write-Host "  Select a number to manage, or [0] to go back."
        $choice = Read-Host "Select project"

        if ($choice -eq '0' -or [string]::IsNullOrWhiteSpace($choice)) { return }
        if (-not ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $linked.Count)) { continue }

        $picked = $linked[[int]$choice - 1]
        Clear-Host
        Write-Host "  $($picked.name)  ($($picked.path))" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "    [R] Rename"
        Write-Host "    [P] Toggle pinned (currently: $($picked.pinned))"
        Write-Host "    [L] Relink to a new folder"
        Write-Host "    [U] Unlink"
        Write-Host "    [0] Back"
        $action = Read-Host "Select action"

        switch ($action) {
            { $_ -eq 'R' -or $_ -eq 'r' } {
                $newName = Read-Host "New name"
                if (-not [string]::IsNullOrWhiteSpace($newName)) {
                    Rename-DevKitLinkedProject -Id $picked.id -NewName $newName
                }
            }
            { $_ -eq 'P' -or $_ -eq 'p' } {
                Set-DevKitProjectPinned -Id $picked.id -Pinned (-not $picked.pinned)
            }
            { $_ -eq 'L' -or $_ -eq 'l' } {
                $newPath = Show-DevKitFolderBrowser -Description "Relink '$($picked.name)'"
                if ($newPath) { Repair-DevKitLinkedProject -Id $picked.id -NewPath $newPath }
            }
            { $_ -eq 'U' -or $_ -eq 'u' } {
                $confirm = Read-Host "Unlink '$($picked.name)'? (y/N)"
                if ($confirm -eq 'y') { Remove-DevKitLinkedProject -Id $picked.id }
            }
        }
    }
}

function Select-DevKitProject {
    <#
    .SYNOPSIS
        The shared "which project?" picker used everywhere DevKit.ps1 needs
        a project directory, replacing bare Read-Host path prompts.
    .DESCRIPTION
        Fast path: if an Active Project is set and its path still resolves,
        returns it immediately with no prompting at all. Otherwise shows an
        interactive picker: pick a linked project by number, browse for a
        new folder, use the current directory, or type a path manually.
        Whatever is chosen (other than "type manually" without linking)
        becomes the new Active Project.
    .PARAMETER Prompt
        Label shown at the top of the picker (e.g. the menu option's name).
    .PARAMETER ForceReprompt
        Bypass the silent "use Active Project" fast path even if one is set.
    .OUTPUTS
        [string] resolved project path, or $null if the user cancelled.
    #>
    [CmdletBinding()]
    param(
        [string]$Prompt = "Select a project",
        [switch]$ForceReprompt
    )

    if (-not $ForceReprompt) {
        $active = Get-DevKitActiveProject
        if ($active -and -not $active.Missing) {
            Write-Host "  Using active project: $($active.name)  ($($active.path))" -ForegroundColor Green
            Update-DevKitProjectLastUsed -Id $active.id | Out-Null
            return $active.path
        }
        if ($active -and $active.Missing) {
            $resolved = Resolve-DevKitMissingActiveProject -Project $active
            if ($resolved) { return $resolved.path }
            # falls through to the interactive picker below
        }
    }

    while ($true) {
        Clear-Host
        Write-Host "=============================================" -ForegroundColor Cyan
        Write-Host "  Select Project -- $Prompt" -ForegroundColor Cyan
        Write-Host "=============================================" -ForegroundColor Cyan
        Write-Host ""

        $linked = @(Get-DevKitLinkedProjects | Sort-Object -Property @{Expression = 'pinned'; Descending = $true }, @{Expression = 'lastUsedUtc'; Descending = $true })

        if ($linked.Count -gt 0) {
            Write-Host "  Linked Projects (most recently used first):" -ForegroundColor White
            for ($i = 0; $i -lt $linked.Count; $i++) {
                $p = $linked[$i]
                $pin = if ($p.pinned) { "*" } else { " " }
                if ($p.Missing) {
                    Write-Host ("    [{0}] {1} {2,-22} {3,-30} !! MISSING" -f ($i + 1), $pin, $p.name, $p.path) -ForegroundColor DarkYellow
                } else {
                    Write-Host ("    [{0}] {1} {2,-22} {3,-30} [{4}]" -f ($i + 1), $pin, $p.name, $p.path, ($p.tags -join ', '))
                }
            }
            Write-Host ""
        }

        Write-Host "  ---------------------------------------------"
        Write-Host "    [B] Browse for folder..."
        Write-Host "    [C] Use current directory ($((Get-Location).Path))"
        Write-Host "    [T] Type a path manually"
        if ($linked.Count -gt 0) { Write-Host "    [M] Manage list (rename / pin / unlink / relink)" }
        Write-Host "    [0] Cancel"
        Write-Host "  ---------------------------------------------"
        $choice = Read-Host "Select project"

        if ($choice -eq '0' -or [string]::IsNullOrWhiteSpace($choice)) { return $null }

        if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $linked.Count) {
            $picked = $linked[[int]$choice - 1]
            if ($picked.Missing) {
                $picked = Resolve-DevKitMissingActiveProject -Project $picked
                if (-not $picked) { continue }
            }
            Set-DevKitActiveProject -Id $picked.id
            return $picked.path
        }

        if ($choice -eq 'B' -or $choice -eq 'b') {
            $chosenPath = Show-DevKitFolderBrowser -Description "Select a project folder"
            if (-not $chosenPath) { continue }
            $project = Add-DevKitLinkedProject -Path $chosenPath
            Set-DevKitActiveProject -Id $project.id
            return $project.path
        }

        if ($choice -eq 'C' -or $choice -eq 'c') {
            $cur = (Get-Location).Path
            $project = Add-DevKitLinkedProject -Path $cur
            Set-DevKitActiveProject -Id $project.id
            return $project.path
        }

        if ($choice -eq 'T' -or $choice -eq 't') {
            $typed = Read-Host "Enter project path"
            if ([string]::IsNullOrWhiteSpace($typed) -or -not (Test-Path $typed)) {
                Write-Host "  ERROR: Path not found: $typed" -ForegroundColor Red
                Read-Host "Press Enter to continue"
                continue
            }
            $project = Add-DevKitLinkedProject -Path $typed
            Set-DevKitActiveProject -Id $project.id
            return $project.path
        }

        if (($choice -eq 'M' -or $choice -eq 'm') -and $linked.Count -gt 0) {
            Invoke-DevKitManageProjects
            continue
        }
    }
}

function Stop-DevKitNodeProcesses {
    <#
    .SYNOPSIS
        Stop Node processes that appear to belong to the given project path.
    .DESCRIPTION
        Uses the process command line to detect Node processes running code
        under the target directory. This is a heuristic; it will not catch
        every scenario, but it avoids the substring false positives of the
        previous implementation.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $resolved = Resolve-DevKitDirectory -Path $Path
    $pattern = "$resolved\"

    $procs = Get-CimInstance Win32_Process -Filter "Name='node.exe' or Name='bun.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -and
            ($_.CommandLine -like "*`"$pattern*`"*" -or
             $_.CommandLine -like "*$pattern*")
        }

    $killed = 0
    foreach ($proc in $procs) {
        try {
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
            $killed++
        } catch {
            # Ignore access-denied or already-exited processes
        }
    }

    return $killed
}
