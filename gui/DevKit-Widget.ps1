#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Northstar DevKit Companion - persistent desktop widget
.DESCRIPTION
    A small always-available WPF widget that lives on the desktop and in the
    system tray, independent of the main DevKit GUI process: launch it once
    from DevKit and it keeps running after DevKit closes.

    Shows live CPU/memory/GPU load with best-effort temperatures (plus a
    reboot-pending / long-uptime hint), a System Junk dial (reclaimable
    temp/Windows-Update/Recycle-Bin bytes, with a safe in-widget clean of
    temp files + Recycle Bin behind a confirm) next to a Disk Free dial per
    ready drive (added/removed live as USB sticks etc. connect and
    disconnect), the running Node.js processes with their ages and listening
    ports (click a port to open it in the browser, kill just one process after a confirm,
    and get warned when a dev port sits inside a Hyper-V/winnat-reserved
    range), quick-action buttons that launch real DevKit tools in terminal
    windows (including Editor / Explorer / Terminal / Run Script... for the
    active project), a project selector (the same Active Project the GUI/TUI
    share, with a permanent "+ Add new project..." row that links a folder
    via a browse dialog) backed by an ambient git badge (branch +
    uncommitted/ahead/behind/stash) and an .env drift hint, and an AGENTS
    section nesting the Claude Code and Kimi Code CLI + MCP server
    status boxes (Connected / Disconnected / Requires Auth badges; Kimi
    reports Configured/Disabled from its documented mcp.json files since it
    has no headless status command) - each with a "Manage..." dialog
    (re-check, sign-in, catalog add, gap scan, Claude server removal, Kimi
    config file). A side pull-tab (on whichever edge faces into the screen)
    slides out a Git panel for the active project: branch + ahead/behind, a
    drawn commit graph (bright lanes, gradient S-curve links, branch/tag
    pills), fetch/pull/push, open-on-GitHub / Actions links, and the Git
    Cleanup tool. The panel's own width is grip-resizable too.

    The window is always work-area full height and always docked to the left
    or right screen edge (no free-floating rest state); its width is fixed
    (not interactively resizable) and comes from the persisted
    preferences.widgetWidth, applied once at startup. Dragging the title bar
    moves it and releasing it always snaps to whichever edge it is nearer to
    (persisted as preferences.widgetDockMode). The Settings expander sits at
    the bottom and expands upward.

    The tray icon offers Show/Hide, Open DevKit, a reversible "Start with
    Windows" toggle (HKCU Run key), and Exit. Closing the widget window only
    hides it - Exit happens from the tray menu.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.EXAMPLE
    .\gui\DevKit-Widget.ps1
#>
[CmdletBinding()]
param()

# Log any terminating startup error to disk before the process disappears.
# This runs headless (WindowStyle Hidden, no console) both from Start with
# Windows and from a normal launch, so an uncaught exception here is
# otherwise completely invisible - the process just vanishes and it LOOKS
# like a crash with no way to tell why. `trap` (not a wrapping try/catch)
# is used deliberately: it stays in effect for the WHOLE script from this
# point on, including the relaunch guards below and everything dot-sourced
# afterward, without having to indent the entire file inside one big block.
trap {
    try {
        $logDir = Join-Path $env:LOCALAPPDATA "NorthstarDevKit"
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        $logPath = Join-Path $logDir "widget-startup.log"
        $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] PID=$PID PSEdition=$($PSVersionTable.PSEdition) " +
                 "$($_.Exception.GetType().FullName): $($_.Exception.Message)`n$($_.InvocationInfo.PositionMessage)`n"
        Add-Content -LiteralPath $logPath -Value $entry -Encoding UTF8
    } catch { }
    # No 'continue': a startup-time terminating error means the process is in
    # an unknown state, so let it keep propagating and exit rather than try
    # to soldier on - the log entry above is what matters here.
}

# WPF requires STA (same guard as DevKit-GUI.ps1).
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $selfPath = $PSCommandPath
    if ([string]::IsNullOrWhiteSpace($selfPath)) { $selfPath = $MyInvocation.MyCommand.Path }
    $shellExe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
    Start-Process $shellExe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File `"$selfPath`"" | Out-Null
    exit
}

# A Microsoft Store-packaged pwsh (installed under WindowsApps, an MSIX
# package) cannot have its taskbar identity (AppUserModelID) overridden -
# Windows silently ignores SetCurrentProcessExplicitAppUserModelID for
# packaged processes, so the taskbar/Alt+Tab keep showing pwsh's own icon
# no matter what the window itself requests. Hop once to a non-packaged
# shell (a traditional pwsh 7 install if one exists on PATH, else the
# always-unpackaged Windows PowerShell 5.1) so the icon fix actually works.
if ($PSHOME -like '*\WindowsApps\*') {
    $selfPath = $PSCommandPath
    if ([string]::IsNullOrWhiteSpace($selfPath)) { $selfPath = $MyInvocation.MyCommand.Path }
    $altShell = Get-Command pwsh -All -ErrorAction SilentlyContinue |
        Where-Object { $_.Source -notlike '*\WindowsApps\*' } | Select-Object -First 1 -ExpandProperty Source
    if (-not $altShell) { $altShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    if (Test-Path $altShell) {
        Start-Process $altShell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File `"$selfPath`"" | Out-Null
        exit
    }
}

# Single instance: a second launch signals the first to surface its window
# (via a named event) and exits - so launching the widget from DevKit always
# brings it up, even on shells that hide new tray icons from the overflow.
#
# Local\ (per-session) namespace, not Global\: the widget is a per-desktop
# tray app, so each signed-in session gets its own instance - a Global\
# mutex from one session would invisibly veto launches in every other one.
#
# The mutex and event are created with an ACL granting authenticated users
# Synchronize+Modify where the runtime supports it (Windows PowerShell - and
# the MSIX hop above means that is the usual final host). The default DACL
# of an elevated process does NOT let a normal-elevation process open its
# kernel objects, so without this an accidental "Run as administrator"
# widget turns every later normal launch into a silent no-op: it can
# neither take the mutex nor summon the owner. With the ACL, summoning
# works across the elevation boundary (UIPI blocks window messages, not
# kernel-object signaling); when even opening the mutex is denied, the
# blocked branch below says so out loud instead of just vanishing.
$script:InstanceMutexName = 'Local\NorthstarDevKitCompanion'
$script:SummonEventName = 'Local\NorthstarDevKitCompanionSummon'
$authUsersSid = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::AuthenticatedUserSid, $null)
$script:InstanceMutex = $null
$mutexCreated = $false
$mutexBlocked = $false
try {
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        $mutexSec = New-Object System.Security.AccessControl.MutexSecurity
        $mutexSec.AddAccessRule((New-Object System.Security.AccessControl.MutexAccessRule($authUsersSid,
            ([System.Security.AccessControl.MutexRights]::Synchronize -bor [System.Security.AccessControl.MutexRights]::Modify),
            [System.Security.AccessControl.AccessControlType]::Allow)))
        $script:InstanceMutex = New-Object System.Threading.Mutex($true, $script:InstanceMutexName, [ref]$mutexCreated, $mutexSec)
    }
} catch [System.UnauthorizedAccessException] {
    $mutexBlocked = $true
} catch { }
if (-not $script:InstanceMutex -and -not $mutexBlocked) {
    try {
        $script:InstanceMutex = New-Object System.Threading.Mutex($true, $script:InstanceMutexName, [ref]$mutexCreated)
    } catch [System.UnauthorizedAccessException] {
        $mutexBlocked = $true
    } catch { }
}
if ($mutexBlocked) {
    $summoned = $false
    try {
        $summon = [System.Threading.EventWaitHandle]::OpenExisting($script:SummonEventName)
        $summon.Set() | Out-Null
        $summon.Dispose()
        $summoned = $true
    } catch { }
    if (-not $summoned) {
        try {
            Add-Type -AssemblyName PresentationFramework
            [System.Windows.MessageBox]::Show(
                ("The companion widget is already running at a different elevation level (it was probably started with " +
                 """Run as administrator""), and this launch cannot reach it.`n`n" +
                 "Close that instance first (Task Manager > powershell.exe / pwsh.exe running DevKit-Widget.ps1), " +
                 "or sign out and back in, then launch the widget again."),
                'Northstar DevKit Companion',
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Warning) | Out-Null
        } catch { }
    }
    exit
}
if ($script:InstanceMutex -and -not $mutexCreated) {
    try {
        $summon = [System.Threading.EventWaitHandle]::OpenExisting($script:SummonEventName)
        $summon.Set() | Out-Null
        $summon.Dispose()
    } catch { }
    exit
}
$script:SummonEvent = $null
try {
    $eventCreated = $false
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        $eventSec = New-Object System.Security.AccessControl.EventWaitHandleSecurity
        $eventSec.AddAccessRule((New-Object System.Security.AccessControl.EventWaitHandleAccessRule($authUsersSid,
            ([System.Security.AccessControl.EventWaitHandleRights]::Synchronize -bor [System.Security.AccessControl.EventWaitHandleRights]::Modify),
            [System.Security.AccessControl.AccessControlType]::Allow)))
        $script:SummonEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, $script:SummonEventName, [ref]$eventCreated, $eventSec)
    } else {
        $script:SummonEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, $script:SummonEventName, [ref]$eventCreated)
    }
} catch {
    try {
        $eventCreated = $false
        $script:SummonEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, $script:SummonEventName, [ref]$eventCreated)
    } catch { }
}

$ErrorActionPreference = 'Stop'
$GuiDir = $PSScriptRoot
$ScriptDir = Split-Path -Parent $PSScriptRoot   # repo root

. (Join-Path $ScriptDir "lib\DevKit-Common.ps1")
. (Join-Path $ScriptDir "lib\DevKit-McpList.ps1")
. (Join-Path $GuiDir "DevKit-GuiCore.ps1")
. (Join-Path $GuiDir "DevKit-WidgetCore.ps1")
# Open-Repo is dot-source-safe by design (its InvocationName guard stops
# before the interactive body) - this brings in ConvertTo-DevKitBrowsableUrl
# for the GitHub flyout's "Open on GitHub" / "Actions" buttons.
. (Join-Path $ScriptDir "workflow\Open-Repo.ps1")

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Windows groups taskbar buttons by "Application User Model ID", and a
# script-hosted window with no explicit AUMID is grouped under its HOST EXE
# (pwsh.exe/powershell.exe) - so the taskbar shows the PowerShell icon for
# the group regardless of what WM_SETICON sets on the window itself. Giving
# this process its own AUMID, before any window is created, is what makes
# Windows treat it as a distinct app and actually honor the window's icon.
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DevKitAppId {
    [DllImport("shell32.dll", SetLastError = true)]
    public static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string AppID);
}
'@
    [DevKitAppId]::SetCurrentProcessExplicitAppUserModelID('Northstar.DevKit.Companion') | Out-Null
} catch { }

# ==================== XAML LOAD (theme lives in APPLICATION resources) ====================
# A WPF Application must exist BEFORE the window XAML loads, with the theme
# in ITS resources: keyless styles (ScrollBar, ToolTip, CheckBox) only reach
# template-generated elements (the ScrollBars inside every ScrollViewer and
# ComboBox popup) through application resources - merging the theme into
# Window.Resources left every scrollbar in stock light Windows chrome. As a
# bonus, dialog windows inherit app resources, so their tooltips/check boxes
# stay themed too. The message-loop pattern (Application.Run with
# OnExplicitShutdown, so Hide() doesn't end the loop) is unchanged - the app
# is simply created at the top now instead of at the bottom.
$script:App = [Windows.Application]::Current
if (-not $script:App) {
    $script:App = New-Object Windows.Application
    $script:App.ShutdownMode = [Windows.ShutdownMode]::OnExplicitShutdown
}
$themeText = Get-Content -Path (Join-Path $GuiDir "Theme.xaml") -Raw
$script:App.Resources = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$themeText)))

$windowText = Get-Content -Path (Join-Path $GuiDir "DevKit-Widget.xaml") -Raw
$xmlDoc = [xml]$windowText
$nodeReader = New-Object System.Xml.XmlNodeReader $xmlDoc
$window = [Windows.Markup.XamlReader]::Load($nodeReader)

$ui = @{}
foreach ($name in @(
    'RootBorder', 'TitleBar', 'WidgetLogoImage', 'BtnPin', 'BtnHide', 'BtnGitTab', 'ProjectCombo',
    'GitBadgeText', 'EnvDriftRow', 'EnvDriftText', 'BtnEnvFix', 'BtnEnvSilence', 'BtnEnvDriftUnsilence',
    'CpuGaugeTrack', 'CpuGaugeArc', 'CpuGaugeValue', 'CpuGaugeSub',
    'MemGaugeTrack', 'MemGaugeArc', 'MemGaugeValue', 'MemGaugeSub',
    'GpuGaugeTrack', 'GpuGaugeArc', 'GpuGaugeValue', 'GpuGaugeSub', 'MetricsHint',
    'JunkGaugeTrack', 'JunkGaugeArc', 'JunkGaugeValue', 'JunkGaugeSub',
    'DiskGaugesPanel',
    'BtnJunkClean', 'BtnJunkTool', 'JunkStatusText',
    'NodeCountBadge', 'NodeCountBadgeText', 'NodeListPanel', 'OtherPortsText', 'ReservedPortsText',
    'QuickActionsExpander',
    'BtnClearNpmCache', 'BtnKillNode', 'BtnKillPort', 'BtnDoctor', 'BtnOpenDevKit',
    'BtnOpenEditor', 'BtnOpenExplorer', 'BtnOpenTerminal', 'BtnRunScript',
    'AgentsExpander', 'ClaudeExpander', 'ClaudeCliBadge', 'ClaudeCliBadgeText', 'ClaudeMcpPanel', 'BtnClaudeManage',
    'KimiExpander', 'KimiCliBadge', 'KimiCliBadgeText', 'KimiMcpPanel', 'BtnKimiManage', 'McpLoadingBar',
    'SettingsExpander', 'ChkStartup', 'ChkTopmost', 'CmbDefaultView',
    'MainColumn',
    'GitFlyout', 'GitFlyoutInner', 'GitFlyoutGrip', 'GitFlyoutTitle', 'GitFlyoutBranch', 'GitGraphText', 'GitGraphCanvas', 'GitFlyoutStatus',
    'UncommittedExpander', 'UncommittedCountBadgeText', 'UncommittedFilesPanel',
    'TabCommits', 'TabPullRequests', 'TabIssues', 'PrCountBadge', 'PrCountBadgeText', 'IssuesCountBadge', 'IssuesCountBadgeText',
    'GitTabCommitsView', 'GitTabPullRequestsView', 'GitTabIssuesView', 'PullRequestsPanel', 'IssuesPanel', 'GitFlyoutFooter',
    'BtnGitFetch', 'BtnGitPull', 'BtnGitPush', 'BtnGitOpenHub', 'BtnGitActions', 'BtnGitCleanup', 'BtnGitClose',
    'SideTabStack', 'BtnNotesTab', 'NotesFlyout', 'NotesFlyoutInner', 'NotesFlyoutGrip',
    'NotesFlyoutTitle', 'NotesFlyoutSub', 'BtnNoteAdd', 'BtnNotesClose', 'NotesPanel',
    'LastUpdatedText', 'BtnRefreshMcp', 'ContentScroll'
)) {
    $ui[$name] = $window.FindName($name)
}

$logoBitmap = New-Object Windows.Media.Imaging.BitmapImage (New-Object System.Uri (Join-Path $GuiDir "Assets\logo-256.png"))
$ui.WidgetLogoImage.Source = $logoBitmap
$window.Icon = [Windows.Media.Imaging.BitmapFrame]::Create((New-Object System.Uri (Join-Path $GuiDir "Assets\logo.ico")))

$DevKitVersion = '3.8.0'
try {
    $versionFile = Join-Path $ScriptDir "VERSION"
    if (Test-Path $versionFile) {
        $rawVersion = (Get-Content -Path $versionFile -Raw -ErrorAction Stop).Trim()
        if (-not [string]::IsNullOrWhiteSpace($rawVersion)) { $DevKitVersion = $rawVersion }
    }
} catch { }

# ==================== WINDOW SIZE + DOCKING (LEFT / RIGHT ONLY) ====================
# The widget is ALWAYS work-area full height and ALWAYS docked to the left or
# right screen edge - there is no free-floating rest state. The mode persists
# in settings.json (preferences.widgetDockMode) and is applied at startup; the
# Settings expander's "Default view" combo both switches it live and saves it
# as the default. The content width persists too (preferences.widgetWidth) but
# is NOT interactively resizable - it is only ever applied once at startup
# (Get-DevKitWidgetWidth below); $script:MinWidgetWidth/$script:MaxWidgetWidth
# remain as the clamp range for that stored value. Use WPF's own
# SystemParameters.WorkArea (device-independent units) - the WinForms Screen
# API returns physical pixels, which puts the window off-screen on
# DPI-scaled displays.
$script:DockMode = $null   # sentinel: never a real 'Left'/'Right' Mode, so the first
                           # Set-DevKitWidgetDock call at startup always applies even
                           # though the saved/default dock setting is 'Right'.
$script:SuppressDockUi = $false
$script:MinWidgetWidth = 340
$script:MaxWidgetWidth = 700
# The main widget column is a FIXED pixel width (see MainColumn in the XAML),
# never "*". A star column means "absorb whatever is left over", so any
# imprecision between the window's width and the flyout's width was silently
# charged to the main widget - which is what made the flyout's INNER edge (its
# boundary against the widget) creep while the user dragged its OUTER grip.
# Pinning Main makes that boundary immovable by construction.
$script:WidgetContentWidth = 475
# Everything in the window that is neither Main nor the flyout: RootBorder's
# 8px margin and 1px border on each side, plus the 24px GIT pull-tab column.
$script:WidgetChromeWidth = 42

function Sync-DevKitDockUi {
    $script:SuppressDockUi = $true
    for ($i = 0; $i -lt $ui.CmbDefaultView.Items.Count; $i++) {
        if ([string]$ui.CmbDefaultView.Items[$i].Tag -eq $script:DockMode) {
            $ui.CmbDefaultView.SelectedIndex = $i
            break
        }
    }
    $script:SuppressDockUi = $false
}

function Get-DevKitWidgetDockSetting {
    # 'Right' is the fallback default (matches the removed Free mode's old
    # first-run placement, which docked near the right edge) - never returns
    # 'Free', that mode no longer exists.
    try {
        $mode = [string](Get-DevKitSettings).preferences.widgetDockMode
        if ($mode -in @('Left', 'Right')) { return $mode }
    } catch { }
    return 'Right'
}

function Save-DevKitWidgetDockSetting {
    param([string]$Mode)
    try {
        $settings = Get-DevKitSettings
        $settings.preferences.widgetDockMode = $Mode
        Set-DevKitSettings -Settings $settings
    } catch { }
}

function Get-DevKitWidgetWidth {
    # The widget's width is no longer user-adjustable, so the persisted
    # preferences.widgetWidth (which may still hold a width dragged in an older
    # build) is deliberately ignored - honoring it would fight the fixed Main
    # column and reintroduce the drifting-inner-edge problem.
    return $script:WidgetContentWidth
}

function Update-DevKitWidgetGeometry {
    # The one place window width/position is decided, computed ABSOLUTELY from
    # the fixed parts rather than by nudging the current values: width is
    # exactly chrome + Main + (flyout, when open), and the docked edge is
    # re-pinned from the work area. Deriving it fresh every time is what keeps
    # many small drag steps from accumulating rounding drift.
    $flyout = 0
    if ($script:GitFlyoutOpen) { $flyout = $script:FlyoutWidth }
    elseif ($script:NotesFlyoutOpen) { $flyout = $script:NotesFlyoutWidth }
    $window.Width = $script:WidgetChromeWidth + $script:WidgetContentWidth + $flyout
    try {
        $wa = [System.Windows.SystemParameters]::WorkArea
        if ($script:DockMode -eq 'Right') {
            $window.Left = $wa.Right - $window.Width
        } else {
            $window.Left = $wa.Left
        }
    } catch { }
}

function Save-DevKitWidgetWidthSetting {
    # Persist the CONTENT width - the GitHub flyout's extra pixels (see
    # Get-DevKitWidgetFlyoutExtra) are temporary and never saved.
    try {
        $settings = Get-DevKitSettings
        $settings.preferences.widgetWidth = [int][math]::Round($window.Width - (Get-DevKitWidgetFlyoutExtra))
        Set-DevKitSettings -Settings $settings
    } catch { }
}

function Set-DevKitWidgetDock {
    param([ValidateSet('Left', 'Right')][string]$Mode)
    # No-op if this side is already current (title-bar drag release fires this
    # unconditionally even when the drop lands back on the same edge) - avoids
    # needlessly closing an already-open Git flyout for a no-op dock change.
    if ($Mode -eq $script:DockMode) { return }
    try {
        # A dock-side change while the Git flyout is open would otherwise
        # have to reflow a live-open panel across sides mid-flight - simplest
        # correct behavior is to close it first; it reopens fresh on the
        # newly-correct side next time. -Instant snaps the close straight to
        # its final values instead of animating: the plain Left/Width
        # reassignments just below (computed for the NEW dock side) would
        # otherwise be fought/overridden by an in-flight close animation still
        # chasing the OLD side's geometry (WPF animations win over local value
        # sets while running), and its Completed handler would later pin
        # window.Left back to that stale OLD-side target.
        if ($script:GitFlyoutOpen) { Set-DevKitGitFlyout -Open $false -Instant }
        if ($script:NotesFlyoutOpen) { Set-DevKitNotesFlyout -Open $false -Instant }
        $wa = [System.Windows.SystemParameters]::WorkArea
        $script:DockMode = $Mode
        # Full height in every mode - modes only set horizontal placement.
        $window.Top = $wa.Top
        $window.Height = $wa.Height
        Update-DevKitWidgetGeometry
        # The Git pull-tab and flyout always sit on whichever side FACES INTO
        # the screen - i.e. mirrors the dock side: docked right -> west slot
        # (flyout column 1, tab column 0 - the window's true left edge, flyout
        # opens between the tab and Main); docked left -> east slot (flyout
        # column 3, tab column 4 - the window's true right edge). Each of
        # GitFlyout/BtnGitTab now owns its own dedicated column (see the root
        # Grid's 5-column layout in the XAML), so they never overlap Main or
        # each other. The flyout's grip sits on its OUTER edge - the side
        # facing the tab/window edge, away from Main - so it flips opposite
        # to the tab's own facing side: west flyout's outer edge is its LEFT
        # (grip HorizontalAlignment="Left"), east flyout's outer edge is its
        # RIGHT (grip HorizontalAlignment="Right").
        if ($Mode -eq 'Right') {
            [Windows.Controls.Grid]::SetColumn($ui.GitFlyout, 1)
            [Windows.Controls.Grid]::SetColumn($ui.NotesFlyout, 1)
            [Windows.Controls.Grid]::SetColumn($ui.SideTabStack, 0)
            $ui.SideTabStack.HorizontalAlignment = 'Left'
            $ui.BtnGitTab.Style = Get-WidgetResource 'GitTabButtonWest'
            $ui.BtnNotesTab.Style = Get-WidgetResource 'NotesTabButtonWest'
            $ui.GitFlyoutGrip.HorizontalAlignment = 'Left'
            $ui.NotesFlyoutGrip.HorizontalAlignment = 'Left'
            # Panel content hugs the INNER edge (the boundary against Main) so
            # the open/close reveal unfurls outward from the widget instead of
            # the content sliding sideways under the clip.
            $ui.GitFlyoutInner.HorizontalAlignment = 'Right'
            $ui.NotesFlyoutInner.HorizontalAlignment = 'Right'
        } else {
            [Windows.Controls.Grid]::SetColumn($ui.GitFlyout, 3)
            [Windows.Controls.Grid]::SetColumn($ui.NotesFlyout, 3)
            [Windows.Controls.Grid]::SetColumn($ui.SideTabStack, 4)
            $ui.SideTabStack.HorizontalAlignment = 'Right'
            $ui.BtnGitTab.Style = Get-WidgetResource 'GitTabButtonEast'
            $ui.BtnNotesTab.Style = Get-WidgetResource 'NotesTabButtonEast'
            $ui.GitFlyoutGrip.HorizontalAlignment = 'Right'
            $ui.NotesFlyoutGrip.HorizontalAlignment = 'Right'
            $ui.GitFlyoutInner.HorizontalAlignment = 'Left'
            $ui.NotesFlyoutInner.HorizontalAlignment = 'Left'
        }
    } catch { }
    Sync-DevKitDockUi
}

$ui.CmbDefaultView.Add_SelectionChanged({
    if ($script:SuppressDockUi) { return }
    $item = $ui.CmbDefaultView.SelectedItem
    if ($null -eq $item) { return }
    $mode = [string]$item.Tag
    if ($mode -notin @('Left', 'Right')) { return }
    Set-DevKitWidgetDock -Mode $mode
    Save-DevKitWidgetDockSetting -Mode $mode
})

function Get-WidgetResource([string]$Key) { return $window.FindResource($Key) }

# ==================== TRAY ICON ====================

$script:TrayIcon = New-Object System.Windows.Forms.NotifyIcon
# Ask the multi-size .ico for the shell's small-icon size (16px at 96 DPI,
# scaled up on high-DPI displays) so the tray gets a purpose-rendered frame
# instead of a blurry downscale of the default 32/48px one.
try {
    $script:TrayIcon.Icon = New-Object System.Drawing.Icon ((Join-Path $GuiDir "Assets\logo.ico"), [System.Windows.Forms.SystemInformation]::SmallIconSize)
} catch {
    $script:TrayIcon.Icon = New-Object System.Drawing.Icon (Join-Path $GuiDir "Assets\logo.ico")
}
$script:TrayIcon.Text = "Northstar DevKit Companion v$DevKitVersion"
$script:TrayIcon.Visible = $true

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$script:TrayStartupItem = $null

# Dark menu renderer to match the brand (falls back to the system renderer
# if inline compilation is unavailable).
try {
    Add-Type -TypeDefinition @'
using System.Drawing;
using System.Windows.Forms;
public class DevKitDarkMenuColors : ProfessionalColorTable {
    private static readonly Color Bg = Color.FromArgb(19, 26, 38);
    private static readonly Color BgSel = Color.FromArgb(30, 39, 53);
    private static readonly Color Border = Color.FromArgb(43, 53, 71);
    public override Color MenuStripGradientBegin { get { return Bg; } }
    public override Color MenuStripGradientEnd { get { return Bg; } }
    public override Color ToolStripDropDownBackground { get { return Bg; } }
    public override Color ImageMarginGradientBegin { get { return Bg; } }
    public override Color ImageMarginGradientMiddle { get { return Bg; } }
    public override Color ImageMarginGradientEnd { get { return Bg; } }
    public override Color MenuItemSelected { get { return BgSel; } }
    public override Color MenuItemBorder { get { return BgSel; } }
    public override Color MenuBorder { get { return Border; } }
    public override Color SeparatorDark { get { return Border; } }
    public override Color SeparatorLight { get { return Border; } }
    public override Color MenuItemPressedGradientBegin { get { return BgSel; } }
    public override Color MenuItemPressedGradientMiddle { get { return BgSel; } }
    public override Color MenuItemPressedGradientEnd { get { return BgSel; } }
    public override Color CheckBackground { get { return BgSel; } }
    public override Color CheckSelectedBackground { get { return BgSel; } }
    public override Color CheckPressedBackground { get { return BgSel; } }
}
'@ -ReferencedAssemblies System.Drawing, System.Windows.Forms
    $trayMenu.Renderer = New-Object System.Windows.Forms.ToolStripProfessionalRenderer((New-Object DevKitDarkMenuColors))
    $trayMenu.BackColor = [System.Drawing.Color]::FromArgb(19, 26, 38)
    $trayMenu.ForeColor = [System.Drawing.Color]::FromArgb(233, 238, 246)
} catch { }

$script:ReallyClose = $false
# The window is shown at startup, so the toggle item starts as 'Hide'.
$script:TrayShowItem = $trayMenu.Items.Add('Hide Companion')
$trayMenu.Items.Add('Open DevKit') | Out-Null
[void]$trayMenu.Items.Add('-')
$script:TrayStartupItem = $trayMenu.Items.Add('Start with Windows')
[void]$trayMenu.Items.Add('-')
$trayMenu.Items.Add('Exit') | Out-Null
$script:TrayIcon.ContextMenuStrip = $trayMenu

function Show-DevKitWidget {
    $window.Show()
    $window.WindowState = 'Normal'
    $window.Activate() | Out-Null
    $script:TrayShowItem.Text = 'Hide Companion'
}
function Hide-DevKitWidget {
    $window.Hide()
    $script:TrayShowItem.Text = 'Show Companion'
    if (-not $script:TrayHintShown) {
        $script:TrayHintShown = $true
        $script:TrayIcon.BalloonTipTitle = 'Northstar DevKit Companion'
        $script:TrayIcon.BalloonTipText = 'Still running in the system tray - left-click the icon to bring me back, right-click for options.'
        $script:TrayIcon.ShowBalloonTip(3500)
    }
}

# Left-click on the tray icon: bring the widget up whenever it is hidden OR
# buried behind other windows; only hide it when the user clicked while it
# was focused. (A plain visible/hidden toggle read as "the widget closed"
# the moment the user clicked the icon while the window was on screen.)
# IsActive alone cannot express "was focused": clicking the notification
# area activates the taskbar BEFORE the click event is delivered, so the
# window is always deactivated by handler time. Track the deactivation
# moment instead - deactivated-a-blink-ago means the click stole the focus.
$script:LastDeactivated = [DateTime]::MinValue
$window.Add_Deactivated({ $script:LastDeactivated = Get-Date })
$script:TrayIcon.Add_MouseClick({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $wasFocused = $window.IsActive -or (((Get-Date) - $script:LastDeactivated).TotalMilliseconds -lt 400)
        if ($window.IsVisible -and $wasFocused) { Hide-DevKitWidget } else { Show-DevKitWidget }
    }
})
$script:TrayShowItem.Add_Click({ if ($window.IsVisible) { Hide-DevKitWidget } else { Show-DevKitWidget } })
$trayMenu.Items[1].Add_Click({ Start-Process (Join-Path $ScriptDir 'DevKit-GUI.bat') -WorkingDirectory $ScriptDir })

# "Start with Windows" is a reversible HKCU Run-key entry, explicit opt-in.
# It has two equal front-ends - this tray menu item and the checkbox in the
# widget's Settings section - so the state lives in Get/Set functions and
# both controls resync through Sync-DevKitStartupUi.
$script:RunKeyPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$script:RunValueName = 'NorthstarDevKitCompanion'
$script:SuppressStartupUi = $false

function Get-DevKitStartupEnabled {
    return $null -ne (Get-ItemProperty -Path $script:RunKeyPath -Name $script:RunValueName -ErrorAction SilentlyContinue)
}
function Set-DevKitStartupEnabled {
    param([bool]$Enabled)
    try {
        if ($Enabled) {
            # Point at the .vbs startup launcher, NOT a resolved pwsh.exe
            # path (Store-packaged pwsh lives in a version-stamped folder
            # that moves on every background auto-update, so a baked-in
            # path goes stale and the launch fails with no visible error)
            # and NOT a .bat (a Run-key .bat flashes a console window at
            # every sign-in). The 45 is a startup delay in seconds: at
            # sign-in powershell.exe can fail to initialize with loader
            # error 0xC0000142 while the logon storm is still settling -
            # the identical launch works moments later - so the launcher
            # waits it out and retries fast failures. Every path baked in
            # here is stable: wscript.exe (System32) and the .vbs itself
            # (moves only if DevKit is reinstalled/moved, which
            # re-registers Startup anyway).
            $launcher = Join-Path $GuiDir 'Start-Widget-Startup.vbs'
            $wscript = Join-Path ([Environment]::SystemDirectory) 'wscript.exe'
            Set-ItemProperty -Path $script:RunKeyPath -Name $script:RunValueName -Value "`"$wscript`" `"$launcher`" 45"
        } else {
            Remove-ItemProperty -Path $script:RunKeyPath -Name $script:RunValueName -ErrorAction SilentlyContinue
        }
    } catch { }
    Sync-DevKitStartupUi
}
function Sync-DevKitStartupUi {
    $enabled = Get-DevKitStartupEnabled
    $script:TrayStartupItem.Checked = $enabled
    $script:SuppressStartupUi = $true
    $ui.ChkStartup.IsChecked = $enabled
    $script:SuppressStartupUi = $false
}

$script:TrayStartupItem.Add_Click({ Set-DevKitStartupEnabled -Enabled (-not (Get-DevKitStartupEnabled)) })
$ui.ChkStartup.Add_Checked({ if (-not $script:SuppressStartupUi) { Set-DevKitStartupEnabled -Enabled $true } })
$ui.ChkStartup.Add_Unchecked({ if (-not $script:SuppressStartupUi) { Set-DevKitStartupEnabled -Enabled $false } })
Sync-DevKitStartupUi

$trayMenu.Items[5].Add_Click({
    $script:ReallyClose = $true
    $script:TrayIcon.Visible = $false
    $script:TrayIcon.Dispose()
    $window.Close()
    # The widget runs its own Application.Run() dispatcher loop (Hide()
    # would otherwise end a ShowDialog() modal loop the moment the widget
    # is first hidden/minimized) - Close() alone does not stop that loop.
    if ([Windows.Application]::Current) { [Windows.Application]::Current.Shutdown() }
})

# ==================== WINDOW CHROME ====================

# Title-bar drag always moves the window (docked or not); where the button
# comes back up decides whether the drop snaps to a screen edge.
$ui.TitleBar.Add_MouseLeftButtonDown({
    param($s, $e)
    if ($e.ClickCount -eq 2) { return }
    try { $window.DragMove() } catch { }
})
$ui.TitleBar.Add_MouseLeftButtonUp({
    # There is no free-floating rest state: wherever the drag left the
    # window, the drop always resolves to whichever screen edge the
    # window's center is nearer to (live visual feedback while held, but
    # release always docks).
    try {
        $wa = [System.Windows.SystemParameters]::WorkArea
        # Full height in every mode: the drag also moved Top, so re-apply.
        $window.Top = $wa.Top
        $window.Height = $wa.Height
        $centerX = $window.Left + ($window.Width / 2)
        $waCenterX = ($wa.Left + $wa.Right) / 2
        $mode = if ($centerX -lt $waCenterX) { 'Left' } else { 'Right' }
        Set-DevKitWidgetDock -Mode $mode
        Save-DevKitWidgetDockSetting -Mode $mode
    } catch { }
})

# ==================== FLYOUT WIDTH GRIPS (GIT + NOTES) ====================
# The main widget window is NOT interactively width-resizable - its width
# comes solely from the persisted preferences.widgetWidth, applied once at
# startup via Get-DevKitWidgetWidth (window.Width assignment near the bottom
# of this file). Only the flyouts keep drag-to-resize grips, each on its own
# OUTER edge (the far side from the main widget, facing the pull-tab/window
# edge - see GitFlyoutGrip/NotesFlyoutGrip in the XAML). A drag only ever
# adjusts that flyout's own width variable - the main content width is
# untouched. One shared set of drag functions serves both flyouts, routed
# by $Kind ('Git'/'Notes'); only one can be mid-drag at a time because only
# one is ever open at a time.
$script:FlyoutResizeActive = $false
$script:FlyoutResizeKind = 'Git'
$script:FlyoutResizeStartX = 0.0
$script:FlyoutResizeStartWidth = 0.0

function Get-DevKitFlyoutKindParts {
    # The per-kind pieces the shared drag handlers need: the animated outer
    # Border, the fixed-width inner content Grid, and the current width.
    param([string]$Kind)
    if ($Kind -eq 'Notes') {
        return @{ Border = $ui.NotesFlyout; Inner = $ui.NotesFlyoutInner; Width = $script:NotesFlyoutWidth }
    }
    return @{ Border = $ui.GitFlyout; Inner = $ui.GitFlyoutInner; Width = $script:FlyoutWidth }
}

function Start-DevKitFlyoutGripDrag {
    param($Sender, $MouseArgs, [string]$Kind = 'Git')
    # Grabbing the grip within ~220ms of a flyout toggle would otherwise fight
    # that slide: while an animation is active on a property, WPF ignores plain
    # assignments to it, so every drag frame would be silently discarded and the
    # animation's Completed handler would then snap back to its own target.
    # Detach the animations and bump the token so that stale handler no-ops.
    $script:GitFlyoutAnimToken++
    $parts = Get-DevKitFlyoutKindParts -Kind $Kind
    try {
        $window.BeginAnimation([Windows.Window]::WidthProperty, $null)
        $window.BeginAnimation([Windows.Window]::LeftProperty, $null)
        $parts.Border.BeginAnimation([Windows.Controls.Border]::WidthProperty, $null)
        $parts.Border.Width = $parts.Width
        Update-DevKitWidgetGeometry
    } catch { }
    $script:FlyoutResizeActive = $true
    $script:FlyoutResizeKind = $Kind
    $script:FlyoutResizeStartX = $MouseArgs.GetPosition($null).X
    $script:FlyoutResizeStartWidth = $parts.Width
    $Sender.CaptureMouse() | Out-Null
}

function Update-DevKitFlyoutGripDrag {
    param($Sender, $MouseArgs)
    if (-not $script:FlyoutResizeActive -or -not $Sender.IsMouseCaptured) { return }
    $dx = $MouseArgs.GetPosition($null).X - $script:FlyoutResizeStartX
    # The grip sits on the flyout's OUTER edge (away from Main, facing the
    # pull-tab/window edge) in both dock modes, so "drag away from Main"
    # is what must widen the panel in each case. Right-docked (west/column-1
    # flyout): the outer edge is the flyout's LEFT edge, so dragging LEFT
    # (dx<0) widens it - newWidth = StartWidth - dx. Left-docked (east/
    # column-3 flyout): the outer edge is the flyout's RIGHT edge, so
    # dragging RIGHT (dx>0) widens it - newWidth = StartWidth + dx. (Both
    # signs are the mirror image of the old inner-edge grip's formulas.)
    $newWidth = if ($script:DockMode -eq 'Right') { $script:FlyoutResizeStartWidth - $dx } else { $script:FlyoutResizeStartWidth + $dx }
    $newWidth = [math]::Min($script:MaxFlyoutWidth, [math]::Max($script:MinFlyoutWidth, $newWidth))
    $parts = Get-DevKitFlyoutKindParts -Kind $script:FlyoutResizeKind
    if ($newWidth -eq $parts.Width) { return }
    if ($script:FlyoutResizeKind -eq 'Notes') { $script:NotesFlyoutWidth = $newWidth } else { $script:FlyoutWidth = $newWidth }
    $parts.Border.Width = $newWidth
    $parts.Inner.Width = $newWidth
    # Main is a fixed column and the docked edge is re-pinned from the work
    # area, so this can only ever move the flyout's OUTER edge - the inner
    # boundary against the widget is arithmetically incapable of shifting.
    Update-DevKitWidgetGeometry
}

function Stop-DevKitFlyoutGripDrag {
    param($Sender)
    if (-not $script:FlyoutResizeActive) { return }
    $script:FlyoutResizeActive = $false
    try { $Sender.ReleaseMouseCapture() } catch { }
    if ($script:FlyoutResizeKind -eq 'Notes') { Save-DevKitNotesFlyoutWidthSetting } else { Save-DevKitGitFlyoutWidthSetting }
}

$ui.GitFlyoutGrip.Add_MouseLeftButtonDown({ param($s, $e) Start-DevKitFlyoutGripDrag -Sender $s -MouseArgs $e -Kind 'Git' })
$ui.GitFlyoutGrip.Add_MouseMove({ param($s, $e) Update-DevKitFlyoutGripDrag -Sender $s -MouseArgs $e })
$ui.GitFlyoutGrip.Add_MouseLeftButtonUp({ param($s, $e) Stop-DevKitFlyoutGripDrag -Sender $s })
$ui.GitFlyoutGrip.Add_MouseEnter({ param($s, $e) $s.Background = Get-DevKitGitBrush '#264FA3FF' })
$ui.GitFlyoutGrip.Add_MouseLeave({ param($s, $e) if (-not $s.IsMouseCaptured) { $s.Background = [Windows.Media.Brushes]::Transparent } })

$ui.NotesFlyoutGrip.Add_MouseLeftButtonDown({ param($s, $e) Start-DevKitFlyoutGripDrag -Sender $s -MouseArgs $e -Kind 'Notes' })
$ui.NotesFlyoutGrip.Add_MouseMove({ param($s, $e) Update-DevKitFlyoutGripDrag -Sender $s -MouseArgs $e })
$ui.NotesFlyoutGrip.Add_MouseLeftButtonUp({ param($s, $e) Stop-DevKitFlyoutGripDrag -Sender $s })
$ui.NotesFlyoutGrip.Add_MouseEnter({ param($s, $e) $s.Background = Get-DevKitGitBrush '#26E5C07B' })
$ui.NotesFlyoutGrip.Add_MouseLeave({ param($s, $e) if (-not $s.IsMouseCaptured) { $s.Background = [Windows.Media.Brushes]::Transparent } })

# "Keep on top" also has two front-ends (title-bar pin + Settings checkbox);
# same pattern as the startup toggle.
$script:SuppressTopmostUi = $false
function Set-DevKitWidgetTopmost {
    param([bool]$Topmost)
    $window.Topmost = $Topmost
    $ui.BtnPin.Foreground = if ($Topmost) { Get-WidgetResource 'BrushAccentBlue' } else { Get-WidgetResource 'BrushTextMuted' }
    $ui.BtnPin.ToolTip = if ($Topmost) { 'Unpin (allow other windows to cover me)' } else { 'Pin (keep me on top)' }
    $script:SuppressTopmostUi = $true
    $ui.ChkTopmost.IsChecked = $Topmost
    $script:SuppressTopmostUi = $false
}
$ui.BtnPin.Add_Click({ Set-DevKitWidgetTopmost -Topmost (-not $window.Topmost) })
$ui.ChkTopmost.Add_Checked({ if (-not $script:SuppressTopmostUi) { Set-DevKitWidgetTopmost -Topmost $true } })
$ui.ChkTopmost.Add_Unchecked({ if (-not $script:SuppressTopmostUi) { Set-DevKitWidgetTopmost -Topmost $false } })
Set-DevKitWidgetTopmost -Topmost $true
$ui.BtnHide.Add_Click({ Hide-DevKitWidget })

# Closing the window only hides it - real exit lives in the tray menu.
$window.Add_Closing({
    param($s, $e)
    if (-not $script:ReallyClose) {
        $e.Cancel = $true
        Hide-DevKitWidget
    }
})

# Clicking the widget's taskbar button minimizes a borderless window, which
# looks exactly like it closed (there is no chrome to see restored later).
# Treat minimize as "hide to tray" instead - the balloon tip explains where
# it went, and the tray icon brings it back.
$window.Add_StateChanged({
    if ($window.WindowState -eq [Windows.WindowState]::Minimized) {
        $window.WindowState = [Windows.WindowState]::Normal
        Hide-DevKitWidget
    }
})

# ==================== PROJECT SELECTOR ====================

$script:SuppressCombo = $false
$script:ComboProjects = @()
$script:ComboAddIndex = -1      # position of the permanent '+ Add new project...' row
$script:ActiveProjectPath = $null
$script:ActiveProjectName = $null
$script:ProjectsFileStamp = $null

function Update-DevKitWidgetProjects {
    $script:SuppressCombo = $true
    # -Descending applies to every sort key, so negating .pinned here (as a
    # prior version of this line did) inverted the intended order and put
    # pinned projects LAST. Match the canonical form used in lib/DevKit-Common.ps1.
    $script:ComboProjects = @(Get-DevKitLinkedProjects | Sort-Object -Property @{Expression = 'pinned'; Descending = $true }, @{Expression = 'lastUsedUtc'; Descending = $true })
    $ui.ProjectCombo.Items.Clear()
    $ui.ProjectCombo.Items.Add('No active project') | Out-Null
    foreach ($p in $script:ComboProjects) {
        $label = $p.name
        if ($p.Missing) { $label += '  (missing)' }
        $ui.ProjectCombo.Items.Add($label) | Out-Null
    }
    # Permanent last row: an action, not a selectable project.
    $ui.ProjectCombo.Items.Add('+ Add new project...') | Out-Null
    $script:ComboAddIndex = $ui.ProjectCombo.Items.Count - 1
    $active = Get-DevKitActiveProject
    $selected = 0
    if ($active) {
        for ($i = 0; $i -lt $script:ComboProjects.Count; $i++) {
            if ($script:ComboProjects[$i].id -eq $active.id) { $selected = $i + 1; break }
        }
    }
    $ui.ProjectCombo.SelectedIndex = $selected
    $script:SuppressCombo = $false
    Sync-DevKitWidgetActiveProject
}

function Select-DevKitComboActiveProject {
    # Re-select whatever the registry says is active without touching
    # anything else - used to revert after the '+ Add new project...' row was
    # picked (that row is an action and must never remain selected).
    $script:SuppressCombo = $true
    $selected = 0
    $active = Get-DevKitActiveProject
    if ($active) {
        for ($i = 0; $i -lt $script:ComboProjects.Count; $i++) {
            if ($script:ComboProjects[$i].id -eq $active.id) { $selected = $i + 1; break }
        }
    }
    $ui.ProjectCombo.SelectedIndex = $selected
    $script:SuppressCombo = $false
}

function Sync-DevKitWidgetActiveProject {
    $idx = $ui.ProjectCombo.SelectedIndex
    if ($idx -gt 0 -and $idx -le $script:ComboProjects.Count) {
        $script:ActiveProjectPath = $script:ComboProjects[$idx - 1].path
        $script:ActiveProjectName = $script:ComboProjects[$idx - 1].name
    } else {
        $script:ActiveProjectPath = $null
        $script:ActiveProjectName = $null
    }
    Sync-DevKitWidgetGitState
}

function Add-DevKitWidgetProjectFromPicker {
    # Folder picker behind the combo's '+ Add new project...' row.
    Initialize-DevKitFormsInterop   # compiles DevKit.Win32Window/NativeMethods on first use
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Choose the project folder'
    $dialog.ShowNewFolderButton = $false
    $owner = $null
    try {
        $hwnd = (New-Object Windows.Interop.WindowInteropHelper $window).Handle
        if ($hwnd -ne [IntPtr]::Zero) { $owner = New-Object DevKit.Win32Window ($hwnd) }
    } catch { }
    $result = if ($owner) { $dialog.ShowDialog($owner) } else { $dialog.ShowDialog() }
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return }
    $folder = $dialog.SelectedPath
    if ([string]::IsNullOrWhiteSpace($folder)) { return }
    try {
        $p = Add-DevKitLinkedProject -Path $folder   # handles duplicates
        if ($p) { Set-DevKitActiveProject -Id $p.id }
    } catch { }
    # Rebuilds the combo (new project selected, add-row still last) and - via
    # Sync-DevKitWidgetActiveProject -> Sync-DevKitWidgetGitState - refreshes
    # the GitHub flyout for the new project.
    Update-DevKitWidgetProjects
    Start-DevKitMcpRefresh
}

$ui.ProjectCombo.Add_SelectionChanged({
    if ($script:SuppressCombo) { return }
    $idx = $ui.ProjectCombo.SelectedIndex
    if ($idx -gt 0 -and $idx -eq $script:ComboAddIndex) {
        # The add-row is an action, not a selection: revert to the current
        # active project first, then browse for a folder to link.
        Select-DevKitComboActiveProject
        Add-DevKitWidgetProjectFromPicker
        return
    }
    Sync-DevKitWidgetActiveProject
    try {
        if ($idx -gt 0 -and $idx -le $script:ComboProjects.Count) {
            Set-DevKitActiveProject -Id $script:ComboProjects[$idx - 1].id
        } else {
            Clear-DevKitActiveProject
        }
    } catch { }
    Start-DevKitMcpRefresh
})

# ==================== METRICS (RADIAL GAUGES) + NODE SNAPSHOT ====================
# Each gauge is a 270-degree dial: the track Path is the full arc, the value
# Path covers 0..270 degrees of it. New readings only set a target; a short
# ~30fps easing timer glides the arc there so the dials move fluidly instead
# of snapping every poll.

$script:LastNodeSig = ''
# User-adjustable node-table column widths (pixels), session-only. Both the
# header row and every data row build their ColumnDefinitions from this same
# dictionary (see New-DevKitNodeColumnDefinitions) so a drag on the header
# splitter and a full table rebuild always agree on widths - no drift.
# These 5 sum to 300px, plus the fixed ~24px kill-glyph column = 324px. That
# has to fit inside the default 380px widget width minus the ToolCard's 24px
# horizontal padding (356px usable) - wider defaults (previously summing to
# 386+24=410px) silently pushed the kill button entirely past the window's
# right edge on a freshly-launched, never-resized widget.
$script:NodeColumnWidths = @{ Name = 100; Pid = 38; Mem = 52; Age = 36; Ports = 74 }
$script:NodeColumnMinWidth = 34
# PORTS gets a bigger floor than the shared min: its StackPanel is
# right-aligned and not clipped to the cell, so a process with 2+ ports
# dragged down toward the shared 34px min bleeds leftward into AGE.
$script:NodeColumnMinWidths = @{ Ports = 60 }
# Upper bound on any resizable column - ContentScroll (gui/DevKit-Widget.xaml)
# has horizontal scrolling disabled, so an unbounded drag can push PORTS/kill
# past the visible width with no mouse-driven way back.
$script:NodeColumnMaxWidth = 260

function Get-DevKitNodeColumnMinWidth {
    param([string]$ColKey)
    if ($script:NodeColumnMinWidths.ContainsKey($ColKey)) { return $script:NodeColumnMinWidths[$ColKey] }
    return $script:NodeColumnMinWidth
}
$script:GaugeStartAngle = -135.0   # 7 o'clock, sweeping clockwise
$script:GaugeSweepMax = 270.0
$script:GaugeHotColor = [Windows.Media.Color]::FromRgb(0xFF, 0x6B, 0x3D)
$script:GaugeCoolColor = [Windows.Media.Color]::FromRgb(0x4F, 0xA3, 0xFF)

function Get-DevKitGaugePoint {
    param([double]$Angle, [double]$Radius, [double]$Center)
    $rad = $Angle * [math]::PI / 180.0
    return New-Object Windows.Point (($Center + $Radius * [math]::Sin($rad)), ($Center - $Radius * [math]::Cos($rad)))
}

function New-DevKitGaugeGeometry {
    param([double]$Percent, [double]$Radius = 36.0, [double]$Center = 44.0)
    $clamped = [math]::Min(100.0, [math]::Max(0.0, $Percent))
    $sweep = $script:GaugeSweepMax * ($clamped / 100.0)
    $figure = New-Object Windows.Media.PathFigure
    $figure.StartPoint = Get-DevKitGaugePoint -Angle $script:GaugeStartAngle -Radius $Radius -Center $Center
    $figure.IsClosed = $false
    $arc = New-Object Windows.Media.ArcSegment
    $arc.Point = Get-DevKitGaugePoint -Angle ($script:GaugeStartAngle + $sweep) -Radius $Radius -Center $Center
    $arc.Size = New-Object Windows.Size ($Radius, $Radius)
    $arc.IsLargeArc = ($sweep -gt 180.0)
    $arc.SweepDirection = [Windows.Media.SweepDirection]::Clockwise
    $figure.Segments.Add($arc)
    $geometry = New-Object Windows.Media.PathGeometry
    $geometry.Figures.Add($figure)
    return $geometry
}

$script:Gauges = [ordered]@{
    Cpu = @{ Current = 0.0; Target = 0.0; Arc = $ui.CpuGaugeArc; Track = $ui.CpuGaugeTrack; Value = $ui.CpuGaugeValue; Sub = $ui.CpuGaugeSub }
    Mem = @{ Current = 0.0; Target = 0.0; Arc = $ui.MemGaugeArc; Track = $ui.MemGaugeTrack; Value = $ui.MemGaugeValue; Sub = $ui.MemGaugeSub }
    Gpu = @{ Current = 0.0; Target = 0.0; Arc = $ui.GpuGaugeArc; Track = $ui.GpuGaugeTrack; Value = $ui.GpuGaugeValue; Sub = $ui.GpuGaugeSub }
    Junk = @{ Current = 0.0; Target = 0.0; Arc = $ui.JunkGaugeArc; Track = $ui.JunkGaugeTrack; Value = $ui.JunkGaugeValue; Sub = $ui.JunkGaugeSub }
    # Disk_<letter> entries (e.g. Disk_C, Disk_D) are added/removed at
    # runtime by Update-DevKitDiskGauges as drives connect/disconnect - see
    # New-DevKitDynamicGaugeControl below.
}
foreach ($gauge in $script:Gauges.Values) {
    $gauge.Track.Data = New-DevKitGaugeGeometry -Percent 100
    $gauge.Arc.Data = New-DevKitGaugeGeometry -Percent 0
    $gauge.Arc.Visibility = 'Hidden'
}

function New-DevKitDynamicGaugeControl {
    <#
    .SYNOPSIS
        Builds one drive gauge's visual tree in code: an 88x88 radial dial in
        the same CPU/MEM/GPU layout (WidgetGaugeValue inside the ring,
        WidgetGaugeSub as a sibling below it, WidgetGaugeLabel below that) and
        the same style resources (BrushGaugeTrack/BrushGaugeArc, the cool-blue
        DropShadowEffect) as every hardcoded gauge, so a gauge added at
        runtime for a newly-connected drive is visually indistinguishable from
        one that shipped in the XAML. Returns the same Arc/Track/Value/Sub
        shape as a $script:Gauges entry so it drops straight into
        Set-DevKitGauge and the shared easing timer once registered.
    .OUTPUTS
        @{ Root (StackPanel - add this to a panel's Children); Arc; Track; Value; Sub }
    #>
    param([Parameter(Mandatory = $true)][string]$Label, [string]$ToolTipText)

    $root = New-Object Windows.Controls.StackPanel
    $root.HorizontalAlignment = 'Center'
    $root.Width = 100
    $root.Margin = '0,0,0,8'

    $grid = New-Object Windows.Controls.Grid
    $grid.Width = 88
    $grid.Height = 88
    if (-not [string]::IsNullOrWhiteSpace($ToolTipText)) { $grid.ToolTip = $ToolTipText }

    $track = New-Object Windows.Shapes.Path
    $track.Stroke = Get-WidgetResource 'BrushGaugeTrack'
    $track.StrokeThickness = 7
    $track.StrokeStartLineCap = 'Round'
    $track.StrokeEndLineCap = 'Round'
    $grid.Children.Add($track) | Out-Null

    $arc = New-Object Windows.Shapes.Path
    $arc.Stroke = Get-WidgetResource 'BrushGaugeArc'
    $arc.StrokeThickness = 7
    $arc.StrokeStartLineCap = 'Round'
    $arc.StrokeEndLineCap = 'Round'
    $effect = New-Object Windows.Media.Effects.DropShadowEffect
    $effect.Color = $script:GaugeCoolColor
    $effect.Opacity = 0.55
    $effect.BlurRadius = 9
    $effect.ShadowDepth = 0
    $arc.Effect = $effect
    $grid.Children.Add($arc) | Out-Null

    $value = New-Object Windows.Controls.TextBlock
    $value.Style = Get-WidgetResource 'WidgetGaugeValue'
    $value.Text = '...'
    $value.VerticalAlignment = 'Center'
    $grid.Children.Add($value) | Out-Null

    $root.Children.Add($grid) | Out-Null

    $sub = New-Object Windows.Controls.TextBlock
    $sub.Style = Get-WidgetResource 'WidgetGaugeSub'
    $sub.Text = ''
    $sub.Visibility = 'Hidden'
    $root.Children.Add($sub) | Out-Null

    $labelBlock = New-Object Windows.Controls.TextBlock
    $labelBlock.Style = Get-WidgetResource 'WidgetGaugeLabel'
    $labelBlock.Text = $Label
    $labelBlock.Margin = '0,2,0,0'
    $root.Children.Add($labelBlock) | Out-Null

    $track.Data = New-DevKitGaugeGeometry -Percent 100
    $arc.Data = New-DevKitGaugeGeometry -Percent 0
    $arc.Visibility = 'Hidden'

    return @{ Root = $root; Arc = $arc; Track = $track; Value = $value; Sub = $sub }
}

$script:DiskGaugeControls = @{}   # drive letter ("C:") -> New-DevKitDynamicGaugeControl bundle, for removal on disconnect

function Update-DevKitDiskGauges {
    <#
    .SYNOPSIS
        Reconciles one gauge per ready drive against the live Drives array
        every metrics cycle: adds a gauge for a drive letter not seen before
        (a USB stick just mounted), removes one for a drive that dropped out
        of the list (unplugged/ejected), and renders every surviving gauge.
        Same "dial shows USED space, number shows FREE" convention as the old
        single system-drive gauge - a full disk breaks builds with symptoms
        that look like everything except disk space.
    #>
    param([array]$Drives)

    $seen = @{}
    foreach ($d in $Drives) {
        $letter = [string]$d.Name   # e.g. "C:"
        if ([string]::IsNullOrWhiteSpace($letter)) { continue }
        $seen[$letter] = $true
        $key = "Disk_$($letter.TrimEnd(':'))"

        if (-not $script:DiskGaugeControls.ContainsKey($letter)) {
            $tip = "Free space on $letter - a full disk breaks builds. Ember when under 10% free."
            $control = New-DevKitDynamicGaugeControl -Label $letter -ToolTipText $tip
            $ui.DiskGaugesPanel.Children.Add($control.Root) | Out-Null
            $script:DiskGaugeControls[$letter] = $control
            $script:Gauges[$key] = @{ Current = 0.0; Target = 0.0; Arc = $control.Arc; Track = $control.Track; Value = $control.Value; Sub = $control.Sub }
        }

        $total = [double]$d.TotalBytes
        $free = [double]$d.FreeBytes
        $driveAvail = $total -gt 0
        $usedPercent = 0.0
        $freePercent = 100.0
        if ($driveAvail) {
            $usedPercent = (($total - $free) / $total) * 100.0
            $freePercent = ($free / $total) * 100.0
        }
        Set-DevKitGauge -Key $key -Percent $usedPercent -Available $driveAvail -Hot ($driveAvail -and $freePercent -lt 10) `
            -ValueString $(if ($driveAvail) { Format-DevKitJunkSize $free } else { '' }) `
            -SubString $(if ($driveAvail) { 'free' } else { '' })
    }

    foreach ($letter in @($script:DiskGaugeControls.Keys)) {
        if ($seen.ContainsKey($letter)) { continue }
        $key = "Disk_$($letter.TrimEnd(':'))"
        $control = $script:DiskGaugeControls[$letter]
        try { $ui.DiskGaugesPanel.Children.Remove($control.Root) } catch { }
        $script:Gauges.Remove($key)
        $script:DiskGaugeControls.Remove($letter)
    }
}

$script:GaugeAnimTimer = New-Object Windows.Threading.DispatcherTimer
$script:GaugeAnimTimer.Interval = [TimeSpan]::FromMilliseconds(33)
$script:GaugeAnimTimer.Add_Tick({
    $settled = $true
    foreach ($gauge in $script:Gauges.Values) {
        $diff = $gauge.Target - $gauge.Current
        if ([math]::Abs($diff) -lt 0.15) {
            if ($gauge.Current -ne $gauge.Target) {
                $gauge.Current = $gauge.Target
                $gauge.Arc.Data = New-DevKitGaugeGeometry -Percent $gauge.Current
            }
        } else {
            $gauge.Current += $diff * 0.18
            $gauge.Arc.Data = New-DevKitGaugeGeometry -Percent $gauge.Current
            $settled = $false
        }
        # A sub-1% arc with round caps renders as a stray dot; hide it instead.
        $gauge.Arc.Visibility = if ($gauge.Current -ge 1.0) { 'Visible' } else { 'Hidden' }
    }
    if ($settled) { $script:GaugeAnimTimer.Stop() }
})

function Set-DevKitGauge {
    # $Percent stays untyped: a typed [double] would silently coerce $null to
    # 0 and report a dead sensor as a real zero reading.
    param([string]$Key, $Percent, [string]$ValueString, [string]$SubString, [bool]$Hot, [bool]$Available)
    $gauge = $script:Gauges[$Key]
    if (-not $Available) {
        $gauge.Target = 0.0
        $gauge.Value.Text = 'n/a'
        $gauge.Value.Foreground = Get-WidgetResource 'BrushTextDim'
        $gauge.Sub.Visibility = 'Hidden'
    } else {
        $gauge.Target = [math]::Min(100.0, [math]::Max(0.0, [double]$Percent))
        $gauge.Value.Text = $ValueString
        $gauge.Value.Foreground = if ($Hot) { Get-WidgetResource 'BrushAccentEmber' } else { Get-WidgetResource 'BrushTextBright' }
        if ([string]::IsNullOrWhiteSpace($SubString)) {
            $gauge.Sub.Visibility = 'Hidden'
        } else {
            $gauge.Sub.Text = $SubString
            $gauge.Sub.Visibility = 'Visible'
        }
        $gauge.Arc.Stroke = Get-WidgetResource $(if ($Hot) { 'BrushGaugeArcHot' } else { 'BrushGaugeArc' })
        if ($gauge.Arc.Effect) { $gauge.Arc.Effect.Color = if ($Hot) { $script:GaugeHotColor } else { $script:GaugeCoolColor } }
    }
    if (-not $script:GaugeAnimTimer.IsEnabled -and [math]::Abs($gauge.Target - $gauge.Current) -ge 0.15) {
        $script:GaugeAnimTimer.Start()
    }
}

function Update-DevKitWidgetMetrics {
    # Pure render: takes an already-collected snapshot rather than calling
    # Get-DevKitSystemMetrics itself. That collector issues several
    # Get-Counter/CIM queries that each cost roughly a second, and this
    # function used to be called straight from the dispatcher-thread
    # FastTimer tick - blocking the UI thread for longer than the timer's
    # own interval and starving the gauge-easing timer. Collection now runs
    # in the background runspace below; only rendering stays on the UI thread.
    param($Metrics)
    $m = $Metrics

    $cpuAvail = $null -ne $m.CpuPercent
    $cpuHot = $cpuAvail -and (($m.CpuPercent -ge 90) -or ($null -ne $m.CpuTempC -and $m.CpuTempC -ge 85))
    Set-DevKitGauge -Key 'Cpu' -Percent $m.CpuPercent -Available $cpuAvail -Hot $cpuHot `
        -ValueString $(if ($cpuAvail) { "$([int][math]::Round($m.CpuPercent))%" } else { '' }) `
        -SubString $(if ($null -ne $m.CpuTempC) { "$([int][math]::Round($m.CpuTempC))$([char]0x00B0)C" } else { '' })

    $memAvail = $null -ne $m.MemoryPercent
    Set-DevKitGauge -Key 'Mem' -Percent $m.MemoryPercent -Available $memAvail -Hot ($memAvail -and $m.MemoryPercent -ge 90) `
        -ValueString $(if ($memAvail) { "$([int][math]::Round($m.MemoryPercent))%" } else { '' }) `
        -SubString $(if ($memAvail) { "$($m.MemoryUsedGB) / $($m.MemoryTotalGB) GB" } else { '' })

    # GPU: temp can be present without a utilization percentage - on this test
    # machine GpuPercent is normally 0/n-a while GpuTempC is normally readable.
    # When Percent is missing but Temp is present, drive the WHOLE gauge (ring
    # value + arc fill) from temperature instead of showing a near-empty ring
    # under a fake "0%"/"n/a". The arc is scaled off a 30C (idle) - 90C (hot)
    # window - a reasonable idle-to-thermal-limit span for a GPU without
    # querying a per-card thermal throttle point. "Hot" still triggers at the
    # same >=85C used elsewhere in this function. If a real utilization
    # percent IS available, keep the existing percent-drives-the-ring
    # behavior with temp shown as the Sub line beneath it.
    $gpuPercentAvail = $null -ne $m.GpuPercent
    $gpuTempAvail = $null -ne $m.GpuTempC
    $gpuAvail = $gpuPercentAvail -or $gpuTempAvail
    $gpuHot = ($gpuPercentAvail -and $m.GpuPercent -ge 90) -or ($gpuTempAvail -and $m.GpuTempC -ge 85)
    if ($gpuPercentAvail) {
        $gpuGaugePercent = $m.GpuPercent
        $gpuValueString = "$([int][math]::Round($m.GpuPercent))%"
        $gpuSubString = $(if ($gpuTempAvail) { "$([int][math]::Round($m.GpuTempC))$([char]0x00B0)C" } else { '' })
    } elseif ($gpuTempAvail) {
        $gpuGaugePercent = [math]::Min(100.0, [math]::Max(0.0, ($m.GpuTempC - 30.0) / (90.0 - 30.0) * 100.0))
        $gpuValueString = "$([int][math]::Round($m.GpuTempC))$([char]0x00B0)C"
        $gpuSubString = ''
    } else {
        $gpuGaugePercent = 0
        $gpuValueString = 'n/a'
        $gpuSubString = ''
    }
    Set-DevKitGauge -Key 'Gpu' -Percent $gpuGaugePercent -Available $gpuAvail -Hot $gpuHot `
        -ValueString $gpuValueString -SubString $gpuSubString

    # Disk: one gauge per ready drive, added/removed as drives connect and
    # disconnect. See Update-DevKitDiskGauges for the reconcile + render.
    Update-DevKitDiskGauges -Drives $m.Drives

    $hints = @()
    if ($null -eq $m.CpuTempC) { $hints += 'CPU temp sensor unavailable' }
    if (-not $gpuAvail) { $hints += 'GPU sensors unavailable' }
    if ($m.RebootPending) { $hints += 'REBOOT PENDING - restart Windows to finish updates' }
    elseif ($null -ne $m.UptimeDays -and $m.UptimeDays -ge 7) { $hints += "up $([int][math]::Floor($m.UptimeDays)) days - a reboot may help" }
    if ($hints.Count -gt 0) {
        $ui.MetricsHint.Text = ($hints -join '  |  ')
        $ui.MetricsHint.Foreground = Get-WidgetResource $(if ($m.RebootPending) { 'BrushAccentEmber' } else { 'BrushTextDim' })
        $ui.MetricsHint.Visibility = 'Visible'
    } else {
        $ui.MetricsHint.Visibility = 'Collapsed'
    }
}

function Format-DevKitNodeAge {
    # Compact age for the table: 5m / 3h / 2d. $null (StartTime unreadable) -> '-'.
    param($Minutes)
    if ($null -eq $Minutes) { return '-' }
    if ($Minutes -lt 60) { return "$([int]$Minutes)m" }
    if ($Minutes -lt 1440) { return "$([int][math]::Floor($Minutes / 60))h" }
    return "$([int][math]::Floor($Minutes / 1440))d"
}

$script:NodeColumnOrder = @('Name', 'Pid', 'Mem', 'Age', 'Ports')

function New-DevKitNodeColumnDefinitions {
    # Single source of truth for the node table's column widths: both the
    # header row and every data row call this, so they can never drift apart.
    # Columns 0-4 (Name/Pid/Mem/Age/Ports) are user-resizable pixel widths
    # read from $script:NodeColumnWidths; column 5 (kill) is a fixed Auto
    # glyph column, not user-resizable.
    $defs = @()
    foreach ($key in $script:NodeColumnOrder) {
        $col = New-Object Windows.Controls.ColumnDefinition
        $col.Width = [Windows.GridLength]::new($script:NodeColumnWidths[$key])
        $col.MinWidth = Get-DevKitNodeColumnMinWidth $key
        $col.MaxWidth = $script:NodeColumnMaxWidth
        $defs += $col
    }
    $killCol = New-Object Windows.Controls.ColumnDefinition
    $killCol.Width = [Windows.GridLength]::Auto
    $defs += $killCol
    return $defs
}

function Update-DevKitNodeColumnWidths {
    # Live-restyles every already-built row Grid (header + data) to match
    # $script:NodeColumnWidths, without waiting for a full table rebuild -
    # mirrors the instant feedback Update-DevKitFlyoutGripDrag gives the Git
    # flyout's own width grip.
    foreach ($child in @($ui.NodeListPanel.Children)) {
        if ($child -isnot [Windows.Controls.Grid]) { continue }
        for ($i = 0; $i -lt $script:NodeColumnOrder.Count; $i++) {
            if ($child.ColumnDefinitions.Count -gt $i) {
                $child.ColumnDefinitions[$i].Width = [Windows.GridLength]::new($script:NodeColumnWidths[$script:NodeColumnOrder[$i]])
            }
        }
    }
}

# ---- Column-boundary drag handles (header row only) ----
# Same manual capture-drag pattern as Start/Update/Stop-DevKitFlyoutGripDrag
# above, scaled down to one column instead of the whole flyout.
$script:NodeColDrag = $null       # column key ('Name'/'Pid'/...) while captured
$script:NodeColDragStartX = 0.0
$script:NodeColDragStartWidth = 0.0

function Start-DevKitNodeColDrag {
    param($Sender, $MouseArgs, [string]$ColKey)
    $script:NodeColDrag = $ColKey
    $script:NodeColDragStartX = $MouseArgs.GetPosition($null).X
    $script:NodeColDragStartWidth = $script:NodeColumnWidths[$ColKey]
    $Sender.CaptureMouse() | Out-Null
}

function Update-DevKitNodeColDrag {
    param($Sender, $MouseArgs, [string]$ColKey)
    if ($script:NodeColDrag -ne $ColKey -or -not $Sender.IsMouseCaptured) { return }
    $dx = $MouseArgs.GetPosition($null).X - $script:NodeColDragStartX
    $width = [math]::Max((Get-DevKitNodeColumnMinWidth $ColKey), $script:NodeColDragStartWidth + $dx)
    $script:NodeColumnWidths[$ColKey] = [math]::Min($script:NodeColumnMaxWidth, $width)
    Update-DevKitNodeColumnWidths
}

function Stop-DevKitNodeColDrag {
    param($Sender, [string]$ColKey)
    if ($script:NodeColDrag -ne $ColKey) { return }
    $script:NodeColDrag = $null
    try { $Sender.ReleaseMouseCapture() } catch { }
}

function Add-DevKitNodeColSplitter {
    # Adds a thin invisible-until-hover drag handle over the right edge of
    # header column $ColIndex (same key used in $script:NodeColumnWidths).
    # Overlaid via HorizontalAlignment=Right + a small negative right margin
    # rather than a real extra GridSplitter column, so it never shifts any
    # other column's index between the header and data rows.
    param($Grid, [string]$ColKey, [int]$ColIndex)
    $splitter = New-Object Windows.Controls.Border
    $splitter.Width = 6
    $splitter.HorizontalAlignment = 'Right'
    $splitter.Margin = '0,0,-3,0'
    $splitter.Background = [Windows.Media.Brushes]::Transparent
    $splitter.Cursor = [System.Windows.Input.Cursors]::SizeWE
    $splitter.ToolTip = "Drag to resize the $ColKey column"
    [Windows.Controls.Grid]::SetColumn($splitter, $ColIndex)
    [Windows.Controls.Panel]::SetZIndex($splitter, 10)
    $keyCopy = $ColKey
    $splitter.Add_MouseLeftButtonDown({ param($s, $e) Start-DevKitNodeColDrag -Sender $s -MouseArgs $e -ColKey $keyCopy }.GetNewClosure())
    $splitter.Add_MouseMove({ param($s, $e) Update-DevKitNodeColDrag -Sender $s -MouseArgs $e -ColKey $keyCopy }.GetNewClosure())
    $splitter.Add_MouseLeftButtonUp({ param($s, $e) Stop-DevKitNodeColDrag -Sender $s -ColKey $keyCopy }.GetNewClosure())
    $splitter.Add_MouseEnter({ param($s, $e) $s.Background = Get-DevKitGitBrush '#264FA3FF' }.GetNewClosure())
    $splitter.Add_MouseLeave({ param($s, $e) if (-not $s.IsMouseCaptured) { $s.Background = [Windows.Media.Brushes]::Transparent } }.GetNewClosure())
    $Grid.Children.Add($splitter) | Out-Null
}

function New-DevKitNodeRow {
    # One row of the node-process table: NAME | PID | MEM | AGE | PORTS | kill.
    # Columns 0-4 are user-resizable pixel widths sourced from
    # $script:NodeColumnWidths via New-DevKitNodeColumnDefinitions (shared by
    # header and data rows so they can't drift out of alignment); the header
    # row additionally gets drag handles on those columns' right edges. Ports
    # are clickable (open http://localhost:<port>); the x kills just that pid.
    param(
        [string]$Name, [string]$PidText, [string]$MemText, [string]$AgeText,
        $Ports = @(), [bool]$IsHeader = $false, [int]$ProcessId = 0
    )
    $grid = New-Object Windows.Controls.Grid
    $grid.Margin = '0,1,0,1'

    foreach ($col in (New-DevKitNodeColumnDefinitions)) { $grid.ColumnDefinitions.Add($col) | Out-Null }

    $textCells = @(
        @{ Text = $Name;    Column = 0; Align = 'Left' }
        @{ Text = $PidText; Column = 1; Align = 'Right' }
        @{ Text = $MemText; Column = 2; Align = 'Right' }
        @{ Text = $AgeText; Column = 3; Align = 'Right' }
    )
    foreach ($cell in $textCells) {
        $tb = New-Object Windows.Controls.TextBlock
        $tb.Style = Get-WidgetResource 'WidgetRowText'
        $tb.Text = $cell.Text
        $tb.HorizontalAlignment = $cell.Align
        $tb.Foreground = Get-WidgetResource $(if ($IsHeader) { 'BrushTextDim' } else { 'BrushTextBright' })
        if ($IsHeader) { $tb.FontSize = 9.5 }
        if ($cell.Column -eq 0) { $tb.TextTrimming = 'CharacterEllipsis' }
        if ($cell.Column -gt 0) { $tb.Margin = '10,0,0,0' }
        [Windows.Controls.Grid]::SetColumn($tb, $cell.Column)
        $grid.Children.Add($tb) | Out-Null
    }

    if ($IsHeader) {
        $portsHead = New-Object Windows.Controls.TextBlock
        $portsHead.Style = Get-WidgetResource 'WidgetRowText'
        $portsHead.Text = 'PORTS'
        $portsHead.HorizontalAlignment = 'Right'
        $portsHead.Foreground = Get-WidgetResource 'BrushTextDim'
        $portsHead.FontSize = 9.5
        $portsHead.Margin = '10,0,0,0'
        [Windows.Controls.Grid]::SetColumn($portsHead, 4)
        $grid.Children.Add($portsHead) | Out-Null

        for ($i = 0; $i -lt $script:NodeColumnOrder.Count; $i++) {
            Add-DevKitNodeColSplitter -Grid $grid -ColKey $script:NodeColumnOrder[$i] -ColIndex $i
        }
    } else {
        $portsPanel = New-Object Windows.Controls.StackPanel
        $portsPanel.Orientation = 'Horizontal'
        $portsPanel.HorizontalAlignment = 'Right'
        $portsPanel.Margin = '10,0,0,0'
        if ($Ports.Count -eq 0) {
            $dash = New-Object Windows.Controls.TextBlock
            $dash.Style = Get-WidgetResource 'WidgetRowText'
            $dash.Text = '-'
            $dash.Foreground = Get-WidgetResource 'BrushTextDim'
            $portsPanel.Children.Add($dash) | Out-Null
        } else {
            foreach ($port in $Ports) {
                $portBtn = New-Object Windows.Controls.Button
                $portBtn.Background = [Windows.Media.Brushes]::Transparent
                $portBtn.BorderThickness = [Windows.Thickness]::new(0)
                $portBtn.Padding = [Windows.Thickness]::new(2, 0, 2, 0)
                $portBtn.Cursor = [System.Windows.Input.Cursors]::Hand
                $portBtn.Content = ":$port"
                $portBtn.FontSize = 11
                $portBtn.Foreground = Get-WidgetResource 'BrushAccentBlue'
                $portBtn.ToolTip = "Open http://localhost:$port in the browser"
                $openUrl = "http://localhost:$port"
                $portBtn.Add_Click({ Start-Process $openUrl }.GetNewClosure())
                $portsPanel.Children.Add($portBtn) | Out-Null
            }
        }
        [Windows.Controls.Grid]::SetColumn($portsPanel, 4)
        $grid.Children.Add($portsPanel) | Out-Null

        $killBtn = New-Object Windows.Controls.Button
        $killBtn.Background = [Windows.Media.Brushes]::Transparent
        $killBtn.BorderThickness = [Windows.Thickness]::new(0)
        $killBtn.Padding = [Windows.Thickness]::new(4, 0, 4, 0)
        $killBtn.Margin = '16,0,0,0'
        $killBtn.Cursor = [System.Windows.Input.Cursors]::Hand
        $killBtn.Content = [char]0x00D7   # multiplication x
        $killBtn.FontSize = 12
        $killBtn.Foreground = Get-WidgetResource 'BrushDangerRed'
        $killBtn.ToolTip = "Kill $Name (pid $ProcessId) - asks first"
        $killName = $Name
        $killBtn.Add_Click({
            # Identity baseline right as the button is pressed (Name via the
            # closure, StartTime fetched fresh here since the snapshot
            # doesn't carry it) - same TOCTOU guard ports/Kill-Port.ps1 uses.
            $preProc = $null
            try { $preProc = Get-Process -Id $ProcessId -ErrorAction Stop } catch { }
            if (-not $preProc -or $preProc.ProcessName -ne $killName) { return }
            $preStart = try { $preProc.StartTime } catch { $null }
            $yes = Show-DevKitWidgetConfirm -Title 'Kill Node Process' -Message "Stop $killName (pid $ProcessId)?`n`nUnsaved work in that process is lost."
            if (-not $yes) { return }
            # Show-DevKitWidgetConfirm's dialog can stay open indefinitely -
            # re-verify immediately before killing so a dev-server restart
            # that lets Windows reuse $ProcessId for an unrelated process (or
            # a new node.exe instance) while the user was deciding doesn't
            # get silently killed instead.
            $postProc = $null
            try { $postProc = Get-Process -Id $ProcessId -ErrorAction Stop } catch { }
            if (-not $postProc -or $postProc.ProcessName -ne $killName) { return }
            $postStart = try { $postProc.StartTime } catch { $null }
            if ($postStart -ne $preStart) { return }
            try { Stop-Process -Id $ProcessId -Force -ErrorAction Stop } catch { }
        }.GetNewClosure())
        [Windows.Controls.Grid]::SetColumn($killBtn, 5)
        $grid.Children.Add($killBtn) | Out-Null

        $portTip = if ($Ports.Count -gt 0) { ($Ports | ForEach-Object { ":$_" }) -join ' ' } else { 'no listening ports' }
        $grid.ToolTip = "$Name (pid $PidText) - up $AgeText, $portTip"
    }
    return $grid
}

function Update-DevKitWidgetNode {
    # Pure render, same reason as Update-DevKitWidgetMetrics above:
    # Get-DevKitNodeSnapshot's Get-NetTCPConnection call is not free, and now
    # runs in the background runspace instead of on the dispatcher thread.
    param($Snapshot)
    # A column-splitter drag is live (mouse captured on a header Border) -
    # rebuilding now would Clear() and recreate that Border out from under the
    # capture with no LostMouseCapture handler to recover, silently freezing
    # the drag (see Start-DevKitNodeColDrag). Skip this render entirely
    # (without updating $script:LastNodeSig) so the next metrics cycle after
    # the drag ends still sees a signature change and rebuilds then.
    if ($script:NodeColDrag) { return }
    $snap = $Snapshot
    $sig = (($snap.Processes | ForEach-Object { "$($_.Pid):$($_.Name):$($_.MemoryMB):$($_.AgeMinutes):$($_.Ports -join ',')" }) -join '|') +
           '##' + (($snap.OtherPorts | ForEach-Object { "$($_.Port):$($_.ProcessName)" }) -join '|') +
           '##' + ($snap.ReservedPorts -join ',')
    if ($sig -eq $script:LastNodeSig) { return }
    $script:LastNodeSig = $sig

    $ui.NodeCountBadgeText.Text = "$($snap.Processes.Count)"
    $ui.NodeListPanel.Children.Clear()
    if ($snap.Processes.Count -eq 0) {
        $none = New-Object Windows.Controls.TextBlock
        $none.Style = Get-WidgetResource 'WidgetRowText'
        $none.Foreground = Get-WidgetResource 'BrushTextDim'
        $none.Text = 'No node processes running. Start a dev server and it shows up here.'
        $none.TextWrapping = 'Wrap'
        $ui.NodeListPanel.Children.Add($none) | Out-Null
    } else {
        # Columnar list: NAME / PID / MEM / AGE / PORTS / kill. Every row (and
        # the header) reads its column widths from $script:NodeColumnWidths
        # via New-DevKitNodeColumnDefinitions, so they stay aligned - and the
        # header's drag splitters let the user override those widths.
        $header = New-DevKitNodeRow -Name 'NAME' -PidText 'PID' -MemText 'MEM' -AgeText 'AGE' -IsHeader $true
        $ui.NodeListPanel.Children.Add($header) | Out-Null

        $shown = @($snap.Processes | Select-Object -First 6)
        foreach ($proc in $shown) {
            $row = New-DevKitNodeRow -Name ([string]$proc.Name) -PidText "$($proc.Pid)" -MemText "$($proc.MemoryMB) MB" `
                -AgeText (Format-DevKitNodeAge $proc.AgeMinutes) -Ports $proc.Ports -ProcessId ([int]$proc.Pid)
            $ui.NodeListPanel.Children.Add($row) | Out-Null
        }
        if ($snap.Processes.Count -gt 6) {
            $more = New-Object Windows.Controls.TextBlock
            $more.Style = Get-WidgetResource 'WidgetRowText'
            $more.Foreground = Get-WidgetResource 'BrushTextDim'
            $more.Text = "+ $($snap.Processes.Count - 6) more"
            $more.Margin = '0,3,0,0'
            $ui.NodeListPanel.Children.Add($more) | Out-Null
        }
    }

    if ($snap.OtherPorts.Count -gt 0) {
        $ui.OtherPortsText.Text = 'Also listening:  ' + (($snap.OtherPorts | ForEach-Object { ":$($_.Port) $($_.ProcessName)" }) -join '  |  ')
        $ui.OtherPortsText.Visibility = 'Visible'
    } else {
        $ui.OtherPortsText.Visibility = 'Collapsed'
    }

    if ($snap.ReservedPorts -and $snap.ReservedPorts.Count -gt 0) {
        $ui.ReservedPortsText.Text = "Reserved by Windows (Hyper-V/winnat): $(($snap.ReservedPorts | ForEach-Object { ":$_" }) -join ' ') - nothing can bind these. See Ports menu > Show Reserved Port Ranges."
        $ui.ReservedPortsText.Visibility = 'Visible'
    } else {
        $ui.ReservedPortsText.Visibility = 'Collapsed'
    }
}

# ==================== ABANDONED RUNSPACE CLEANUP ====================
# The Metrics/MCP/Work Reset-* functions below recover from a wedged
# pipeline (stuck native call: nvidia-smi, a hung WMI query, a flaky MCP
# server, a dead network share) by firing BeginStop and moving on - a
# synchronous Stop()/Dispose() could itself hang the dispatcher thread on
# the same wedge it's trying to escape. Rather than dropping the old
# shell/runspace outright (which leaks the ReuseThread OS thread + handles
# for good if the native call never returns), they're parked here and the
# SlowTimer polls them: once BeginStop's async handle actually completes,
# the shell is Disposed and the runspace Closed so the resources are
# reclaimed instead of accumulating for the life of the widget.
$script:AbandonedRunspaces = New-Object System.Collections.Generic.List[object]

function Register-DevKitAbandonedRunspace {
    param($Shell, $StopAsync, $Runspace)
    if (-not $Shell) { return }
    $script:AbandonedRunspaces.Add([pscustomobject]@{
        Shell     = $Shell
        StopAsync = $StopAsync
        Runspace  = $Runspace
        Since     = Get-Date
    })
}

function Update-DevKitAbandonedRunspaceCleanup {
    if ($script:AbandonedRunspaces.Count -eq 0) { return }
    $stillPending = New-Object System.Collections.Generic.List[object]
    foreach ($item in $script:AbandonedRunspaces) {
        $done = $true
        try { if ($item.StopAsync) { $done = $item.StopAsync.IsCompleted } } catch { $done = $true }
        if ($done) {
            try { $item.Shell.Dispose() } catch { }
            try { if ($item.Runspace) { $item.Runspace.Close() } } catch { }
            try { if ($item.Runspace) { $item.Runspace.Dispose() } } catch { }
        } else {
            $stillPending.Add($item)
        }
    }
    $script:AbandonedRunspaces = $stillPending
}

# ==================== METRICS + NODE COLLECTION (ASYNC) ====================
# A full metrics cycle costs ~1.5-3s (Win32_Processor's LoadPercentage waits
# out its own ~1s sampling window; the thermal-zone counter and nvidia-smi
# are cached per-runspace for 45s/10s so they don't add a second each cycle).
# Collecting on the dispatcher-thread FastTimer tick blocked the UI for
# longer than the timer's own interval, starving the gauge-easing timer and
# stalling drag/click input. Collection runs in this background runspace,
# and the FastTimer only re-arms a refresh ~2s after the previous one
# COMPLETED (completion-time gate) so the runspace gets idle gaps.
# Same async-runspace-plus-poll pattern as the MCP refresh below.

$script:MetricsRunspace = [runspacefactory]::CreateRunspace()
$script:MetricsRunspace.ApartmentState = 'MTA'
$script:MetricsRunspace.ThreadOptions = 'ReuseThread'
$script:MetricsRunspace.Open()
$script:MetricsBusy = $false
$script:MetricsShell = $null
$script:MetricsAsync = $null
$script:MetricsStarted = $null
$script:MetricsLastDone = [datetime]::MinValue

function Start-DevKitMetricsRefresh {
    if ($script:MetricsBusy) { return }
    $script:MetricsBusy = $true
    try {
        $ps = [powershell]::Create()
        $ps.Runspace = $script:MetricsRunspace
        $lib = (Join-Path $ScriptDir 'lib\DevKit-Common.ps1') -replace "'", "''"
        $core = (Join-Path $GuiDir 'DevKit-WidgetCore.ps1') -replace "'", "''"
        $scriptText = ". '$lib'; . '$core'; @{ Metrics = (Get-DevKitSystemMetrics); Node = (Get-DevKitNodeSnapshot) }"
        [void]$ps.AddScript($scriptText)
        $script:MetricsShell = $ps
        $script:MetricsAsync = $ps.BeginInvoke()
        $script:MetricsStarted = Get-Date
    } catch {
        $script:MetricsBusy = $false
    }
}

function Update-DevKitMetricsAsyncPoll {
    if (-not $script:MetricsBusy) { return }
    if ($script:MetricsAsync.IsCompleted) {
        $snap = $null
        try {
            $out = $script:MetricsShell.EndInvoke($script:MetricsAsync)
            if ($out -and $out.Count -gt 0) { $snap = $out[0] }
        } catch { }
        try { $script:MetricsShell.Dispose() } catch { }
        $script:MetricsShell = $null
        $script:MetricsBusy = $false
        $script:MetricsLastDone = Get-Date
        if ($snap) {
            try { Update-DevKitWidgetMetrics -Metrics $snap.Metrics } catch { }
            try { Update-DevKitWidgetNode -Snapshot $snap.Node } catch { }
        }
    } elseif (((Get-Date) - $script:MetricsStarted).TotalSeconds -gt 10) {
        Reset-DevKitMetricsRunspace
        $script:MetricsBusy = $false
        $script:MetricsLastDone = Get-Date
    }
}

function Reset-DevKitMetricsRunspace {
    # Same recovery pattern as Reset-DevKitMcpRunspace: a synchronous
    # Stop()/Dispose() on a pipeline blocked inside a native call (nvidia-smi,
    # a wedged WMI query) can itself hang the dispatcher, so BeginStop is
    # fire-and-forget and a fresh runspace is opened immediately - otherwise
    # every later metrics refresh would queue behind the stuck one and the
    # gauges/node list would freeze permanently. The old shell/runspace are
    # handed to Register-DevKitAbandonedRunspace instead of being dropped, so
    # they still get Disposed/Closed later (see ABANDONED RUNSPACE CLEANUP).
    try {
        if ($script:MetricsShell) {
            $stopAsync = $script:MetricsShell.BeginStop($null, $null)
            Register-DevKitAbandonedRunspace -Shell $script:MetricsShell -StopAsync $stopAsync -Runspace $script:MetricsRunspace
        }
    } catch { }
    $script:MetricsShell = $null
    $script:MetricsAsync = $null
    try {
        $fresh = [runspacefactory]::CreateRunspace()
        $fresh.ApartmentState = 'MTA'
        $fresh.ThreadOptions = 'ReuseThread'
        $fresh.Open()
        $script:MetricsRunspace = $fresh
    } catch { }
}

# ==================== MCP STATUS (ASYNC) ====================
# 'claude mcp list' health-checks every server and can take 10+ seconds, so
# the refresh runs in a background runspace; the fast timer polls for
# completion and renders on the dispatcher thread. A hung refresh is stopped
# after 45s and reported as timed out instead of freezing the widget.

$script:McpRunspace = [runspacefactory]::CreateRunspace()
$script:McpRunspace.ApartmentState = 'MTA'
$script:McpRunspace.ThreadOptions = 'ReuseThread'
$script:McpRunspace.Open()
$script:McpBusy = $false
$script:McpShell = $null
$script:McpAsync = $null
$script:McpStarted = $null
$script:McpLastDone = $null
$script:McpEverLoaded = $false
$script:LastMcpReport = $null   # last full report, for the agent Manage dialogs
# Set on every finished attempt (success OR timeout) so the periodic
# recheck can re-arm even when the very first load times out - McpLastDone
# alone only ever reflects a success, so gating retry on it left the widget
# stuck after a first-run timeout with no automatic recovery.
$script:McpLastAttempt = Get-Date

function Start-DevKitMcpRefresh {
    if ($script:McpBusy) { return }
    $script:McpBusy = $true
    if (-not $script:McpEverLoaded) { $ui.McpLoadingBar.Visibility = 'Visible' }
    try {
        $ps = [powershell]::Create()
        $ps.Runspace = $script:McpRunspace
        $lib = (Join-Path $ScriptDir 'lib\DevKit-Common.ps1') -replace "'", "''"
        $mcpList = (Join-Path $ScriptDir 'lib\DevKit-McpList.ps1') -replace "'", "''"
        $core = (Join-Path $GuiDir 'DevKit-WidgetCore.ps1') -replace "'", "''"
        $scriptText = "param(`$projectPath) . '$lib'; . '$mcpList'; . '$core'; Get-DevKitMcpWidgetReport -ProjectPath `$projectPath"
        [void]$ps.AddScript($scriptText).AddArgument([string]$script:ActiveProjectPath)
        $script:McpShell = $ps
        $script:McpAsync = $ps.BeginInvoke()
        $script:McpStarted = Get-Date
    } catch {
        $script:McpBusy = $false
    }
}

function Reset-DevKitMcpRunspace {
    # Best-effort recovery from a hung 'claude mcp list' call: BeginStop is
    # fire-and-forget (a synchronous Stop()/Dispose() on a pipeline still
    # blocked inside a native process can itself hang the caller - the
    # dispatcher thread here), and a fresh runspace is opened so the NEXT
    # refresh isn't stuck behind a runspace whose single pipeline slot never
    # actually freed. The old runspace/shell aren't dropped outright - they're
    # handed to Register-DevKitAbandonedRunspace, which Disposes/Closes them
    # later once the stop actually completes (see ABANDONED RUNSPACE CLEANUP),
    # so a rare wedged native call no longer leaks the thread/handles forever.
    try {
        if ($script:McpShell) {
            $stopAsync = $script:McpShell.BeginStop($null, $null)
            Register-DevKitAbandonedRunspace -Shell $script:McpShell -StopAsync $stopAsync -Runspace $script:McpRunspace
        }
    } catch { }
    $script:McpShell = $null
    $script:McpAsync = $null
    try {
        $fresh = [runspacefactory]::CreateRunspace()
        $fresh.ApartmentState = 'MTA'
        $fresh.ThreadOptions = 'ReuseThread'
        $fresh.Open()
        $script:McpRunspace = $fresh
    } catch { }
}

function New-DevKitStatusBadge([string]$Status) {
    $border = New-Object Windows.Controls.Border
    $label = New-Object Windows.Controls.TextBlock
    switch ($Status) {
        'Connected'     { $style = 'BadgeConnected'; $textStyle = 'BadgeConnectedText'; $text = 'CONNECTED' }
        'Configured'    { $style = 'BadgeConnected'; $textStyle = 'BadgeConnectedText'; $text = 'CONFIGURED' }
        'RequiresAuth'  { $style = 'BadgeAuth'; $textStyle = 'BadgeAuthText'; $text = 'REQUIRES AUTH' }
        'Disabled'      { $style = 'BadgeDisconnected'; $textStyle = 'BadgeDisconnectedText'; $text = 'DISABLED' }
        'Disconnected'  { $style = 'BadgeDisconnected'; $textStyle = 'BadgeDisconnectedText'; $text = 'DISCONNECTED' }
        default         { $style = 'BadgeNeutral'; $textStyle = 'BadgeNeutralText'; $text = 'UNKNOWN' }
    }
    $border.Style = Get-WidgetResource $style
    $label.Style = Get-WidgetResource $textStyle
    $label.Text = $text
    $border.Child = $label
    return $border
}

function Add-DevKitMcpGroupHeader {
    param($Panel, [string]$Text, [bool]$First)
    $header = New-Object Windows.Controls.TextBlock
    $header.Style = Get-WidgetResource 'WidgetSectionHeader'
    $header.Text = $Text
    if (-not $First) { $header.Margin = '0,9,0,0' }
    $Panel.Children.Add($header) | Out-Null
}

function Add-DevKitMcpServerRow {
    param($Panel, $Server, [switch]$ShowTransport)
    $grid = New-Object Windows.Controls.Grid
    $colName = New-Object Windows.Controls.ColumnDefinition; $colName.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
    $colBadge = New-Object Windows.Controls.ColumnDefinition; $colBadge.Width = [Windows.GridLength]::Auto
    $grid.ColumnDefinitions.Add($colName)
    $grid.ColumnDefinitions.Add($colBadge)
    $grid.Margin = '0,4,0,0'

    $nameText = New-Object Windows.Controls.TextBlock
    $nameText.Style = Get-WidgetResource 'WidgetRowText'
    $nameText.Foreground = Get-WidgetResource 'BrushTextBright'
    $nameText.Text = $Server.Name
    $nameText.TextTrimming = 'CharacterEllipsis'
    $tooltip = "$($Server.Name)"
    if ($Server.Target) { $tooltip += "  |  $($Server.Target)" }
    if ($ShowTransport -and $Server.Transport) { $tooltip += "  |  $($Server.Transport)" }
    $nameText.ToolTip = $tooltip
    [Windows.Controls.Grid]::SetColumn($nameText, 0)
    $grid.Children.Add($nameText) | Out-Null

    $badge = New-DevKitStatusBadge ([string]$Server.Status)
    $badge.HorizontalAlignment = 'Right'
    [Windows.Controls.Grid]::SetColumn($badge, 1)
    $grid.Children.Add($badge) | Out-Null

    $Panel.Children.Add($grid) | Out-Null
}

function Add-DevKitMcpNote {
    param($Panel, [string]$Text, [switch]$Ember)
    $note = New-Object Windows.Controls.TextBlock
    $note.Style = Get-WidgetResource 'WidgetRowText'
    $note.Text = $Text
    $note.TextWrapping = 'Wrap'
    $note.Margin = '0,4,0,0'
    $note.Foreground = Get-WidgetResource $(if ($Ember) { 'BrushAccentEmber' } else { 'BrushTextDim' })
    $Panel.Children.Add($note) | Out-Null
}

function Update-DevKitCliBadge {
    param($BadgeBorder, $BadgeText, [bool]$Installed, [string]$Version)
    if ($Installed) {
        $BadgeBorder.Style = Get-WidgetResource 'BadgeConnected'
        $BadgeText.Style = Get-WidgetResource 'BadgeConnectedText'
        $BadgeText.Text = if ($Version) { $Version } else { 'installed' }
    } else {
        $BadgeBorder.Style = Get-WidgetResource 'BadgeDisconnected'
        $BadgeText.Style = Get-WidgetResource 'BadgeDisconnectedText'
        $BadgeText.Text = 'not installed'
    }
}

function Render-DevKitMcpPanel {
    param($Panel, $ToolStatus, [switch]$ShowTransport)

    $Panel.Children.Clear()
    if (-not $ToolStatus.CliInstalled) {
        Add-DevKitMcpNote -Panel $Panel -Text 'CLI not found on PATH.'
        return
    }
    if ($ToolStatus.ErrorMessage) {
        Add-DevKitMcpNote -Panel $Panel -Text $ToolStatus.ErrorMessage -Ember
        return
    }

    $userServers = @($ToolStatus.Servers | Where-Object { $_.Scope -eq 'User' })
    $projectServers = @($ToolStatus.Servers | Where-Object { $_.Scope -eq 'Project' })

    Add-DevKitMcpGroupHeader -Panel $Panel -Text 'THIS MACHINE (USER)' -First $true
    if ($userServers.Count -eq 0) {
        Add-DevKitMcpNote -Panel $Panel -Text 'No user-scope servers configured.'
    } else {
        foreach ($server in $userServers) { Add-DevKitMcpServerRow -Panel $Panel -Server $server -ShowTransport:$ShowTransport }
    }

    $projectHeader = if ($script:ActiveProjectName) { "PROJECT ($($script:ActiveProjectName))" } else { 'PROJECT (none selected)' }
    Add-DevKitMcpGroupHeader -Panel $Panel -Text $projectHeader -First $false
    if (-not $script:ActiveProjectPath) {
        Add-DevKitMcpNote -Panel $Panel -Text 'Select a project above to see its servers.'
    } elseif ($projectServers.Count -eq 0) {
        Add-DevKitMcpNote -Panel $Panel -Text 'No project-scope servers configured.'
    } else {
        foreach ($server in $projectServers) { Add-DevKitMcpServerRow -Panel $Panel -Server $server -ShowTransport:$ShowTransport }
    }
}

function Update-DevKitMcpPanels($Report) {
    if ($null -eq $Report) { return }
    $script:LastMcpReport = $Report   # the per-agent Manage dialogs summarize this
    $ui.McpLoadingBar.Visibility = 'Collapsed'
    Update-DevKitCliBadge -BadgeBorder $ui.ClaudeCliBadge -BadgeText $ui.ClaudeCliBadgeText -Installed $Report.Claude.CliInstalled -Version $Report.Claude.Version
    Update-DevKitCliBadge -BadgeBorder $ui.KimiCliBadge -BadgeText $ui.KimiCliBadgeText -Installed $Report.Kimi.CliInstalled -Version $Report.Kimi.Version
    Render-DevKitMcpPanel -Panel $ui.ClaudeMcpPanel -ToolStatus $Report.Claude
    Render-DevKitMcpPanel -Panel $ui.KimiMcpPanel -ToolStatus $Report.Kimi -ShowTransport
    $script:McpEverLoaded = $true
    $script:McpLastDone = Get-Date
}

function Update-DevKitMcpAsyncPoll {
    if (-not $script:McpBusy) { return }
    if ($script:McpAsync.IsCompleted) {
        $report = $null
        try {
            $out = $script:McpShell.EndInvoke($script:McpAsync)
            if ($out -and $out.Count -gt 0) { $report = $out[0] }
        } catch { }
        try { $script:McpShell.Dispose() } catch { }
        $script:McpShell = $null
        $script:McpBusy = $false
        $script:McpLastAttempt = Get-Date
        if ($report) { Update-DevKitMcpPanels $report }
    } elseif (((Get-Date) - $script:McpStarted).TotalSeconds -gt 45) {
        Reset-DevKitMcpRunspace
        $script:McpBusy = $false
        $script:McpLastAttempt = Get-Date
        $timeoutMsg = 'Status check timed out (claude mcp list did not answer). Will retry automatically.'
        $ui.McpLoadingBar.Visibility = 'Collapsed'
        $ui.ClaudeMcpPanel.Children.Clear()
        Add-DevKitMcpNote -Panel $ui.ClaudeMcpPanel -Text $timeoutMsg -Ember
        $ui.KimiMcpPanel.Children.Clear()
        Add-DevKitMcpNote -Panel $ui.KimiMcpPanel -Text $timeoutMsg -Ember
    }
}

$ui.BtnRefreshMcp.Add_Click({ Start-DevKitMcpRefresh })
foreach ($expander in @($ui.ClaudeExpander, $ui.KimiExpander)) {
    $expander.Add_Expanded({
        # First open (or a stale read) kicks a fresh check so the user never
        # looks at old health data.
        if (-not $script:McpEverLoaded -or ((Get-Date) - $script:McpLastDone).TotalSeconds -gt 30) {
            Start-DevKitMcpRefresh
        }
    })
}

# ==================== ACCORDION BEHAVIOR (MUTUALLY-EXCLUSIVE EXPANDERS) ====================
# Two independent accordion groups: the three top-level body cards (Quick
# Actions / Agents / Settings), and the two nested Agents children (Claude /
# Kimi). Only Add_Expanded is wired below - there is no Add_Collapsed handler
# on any of these Expanders, and none is needed: WPF only raises Expanded on a
# false->true transition, so forcing a sibling's IsExpanded to $false here
# only ever fires an unhandled Collapsed, which can't re-enter this function.
# The Suppress* guard flag is kept anyway as cheap insurance against a future
# Add_Collapsed handler being added to these Expanders without re-checking
# this comment - without it, that handler firing off the $false assignment
# below would re-enter and loop.
$script:SuppressTopAccordionUi = $false
function Set-DevKitWidgetAccordion {
    param([string]$OpenName)
    if ($script:SuppressTopAccordionUi) { return }
    $script:SuppressTopAccordionUi = $true
    foreach ($pair in @(@('QuickActions', $ui.QuickActionsExpander), @('Agents', $ui.AgentsExpander), @('Settings', $ui.SettingsExpander))) {
        if ($pair[0] -ne $OpenName) { $pair[1].IsExpanded = $false }
    }
    $script:SuppressTopAccordionUi = $false
}
$ui.QuickActionsExpander.Add_Expanded({ Set-DevKitWidgetAccordion -OpenName 'QuickActions' })
$ui.AgentsExpander.Add_Expanded({ Set-DevKitWidgetAccordion -OpenName 'Agents' })
$ui.SettingsExpander.Add_Expanded({ Set-DevKitWidgetAccordion -OpenName 'Settings' })

$script:SuppressAgentAccordionUi = $false
function Set-DevKitAgentAccordion {
    param([string]$OpenName)
    if ($script:SuppressAgentAccordionUi) { return }
    $script:SuppressAgentAccordionUi = $true
    foreach ($pair in @(@('Claude', $ui.ClaudeExpander), @('Kimi', $ui.KimiExpander))) {
        if ($pair[0] -ne $OpenName) { $pair[1].IsExpanded = $false }
    }
    $script:SuppressAgentAccordionUi = $false
}
$ui.ClaudeExpander.Add_Expanded({ Set-DevKitAgentAccordion -OpenName 'Claude' })
$ui.KimiExpander.Add_Expanded({ Set-DevKitAgentAccordion -OpenName 'Kimi' })

# ==================== BACKGROUND WORK (THIRD RUNSPACE) ====================
# One shared MTA runspace for the slow junk scan/clean and every git call
# (log graph / fetch / pull / push) - each of those can take seconds and must
# never run on the dispatcher thread. Same busy-flag + timeout pattern as the
# MCP refresh, with a 30s limit. Only one job runs at a time; a launch
# attempted while busy is declined (scans re-trigger from their own timers,
# button handlers tell the user to retry).

$script:WorkRunspace = [runspacefactory]::CreateRunspace()
$script:WorkRunspace.ApartmentState = 'MTA'
$script:WorkRunspace.ThreadOptions = 'ReuseThread'
$script:WorkRunspace.Open()
$script:WorkBusy = $false
$script:WorkShell = $null
$script:WorkAsync = $null
$script:WorkStarted = $null
$script:WorkKind = $null

function Start-DevKitWorkJob {
    param(
        # 'JunkScan' | 'JunkClean' | 'GitOverview' | 'GitFetch' | 'GitPull' | 'GitPush' | 'EnvDrift' | 'GitHubPRs' | 'GitHubIssues'
        [Parameter(Mandatory = $true)][string]$Kind,
        [string]$ProjectPath
    )
    if ($script:WorkBusy) { return $false }
    $script:WorkBusy = $true
    try {
        $ps = [powershell]::Create()
        $ps.Runspace = $script:WorkRunspace
        $lib = (Join-Path $ScriptDir 'lib\DevKit-Common.ps1') -replace "'", "''"
        $core = (Join-Path $GuiDir 'DevKit-WidgetCore.ps1') -replace "'", "''"
        $body = switch ($Kind) {
            'JunkScan'    { '@{ Junk = (Get-DevKitSystemJunk) }' }
            'JunkClean'   { '@{ Clean = (Clear-DevKitSystemJunk) }' }
            'GitOverview' {
                # Badge-only refreshes (flyout closed) skip the log spawn +
                # layout - the badge only needs branch/dirty/ahead/stash.
                "@{ Git = (Get-DevKitRepoOverview -Path `$path -IncludeGraph `$$script:GitFlyoutOpen) }"
            }
            'EnvDrift'    { '@{ Drift = (Get-DevKitEnvDrift -Path $path) }' }
            'GitHubPRs'    { '@{ PullRequests = (Get-DevKitGitHubPullRequests -Path $path) }' }
            'GitHubIssues' { '@{ Issues = (Get-DevKitGitHubIssues -Path $path) }' }
            default {
                # GitFetch/GitPull/GitPush: run the action, then immediately
                # re-read the overview so the graph reflects the result.
                $action = $Kind.Replace('Git', '').ToLower()
                "@{ GitAction = (Invoke-DevKitGitAction -Path `$path -Action '$action'); Git = (Get-DevKitRepoOverview -Path `$path -IncludeGraph `$$script:GitFlyoutOpen) }"
            }
        }
        $scriptText = "param(`$path) . '$lib'; . '$core'; $body"
        [void]$ps.AddScript($scriptText).AddArgument([string]$ProjectPath)
        $script:WorkKind = $Kind
        $script:WorkProjectPath = $ProjectPath   # stale-result guard for project switches mid-flight
        $script:WorkShell = $ps
        $script:WorkAsync = $ps.BeginInvoke()
        $script:WorkStarted = Get-Date
    } catch {
        $script:WorkBusy = $false
        return $false
    }
    return $true
}

function Reset-DevKitWorkRunspace {
    # Same recovery pattern as Reset-DevKitMcpRunspace: BeginStop is
    # fire-and-forget and a fresh runspace is opened immediately. The old
    # shell/runspace aren't dropped outright - they're handed to
    # Register-DevKitAbandonedRunspace, which Disposes/Closes them later once
    # the stop actually completes (see ABANDONED RUNSPACE CLEANUP above).
    try {
        if ($script:WorkShell) {
            $stopAsync = $script:WorkShell.BeginStop($null, $null)
            Register-DevKitAbandonedRunspace -Shell $script:WorkShell -StopAsync $stopAsync -Runspace $script:WorkRunspace
        }
    } catch { }
    $script:WorkShell = $null
    $script:WorkAsync = $null
    try {
        $fresh = [runspacefactory]::CreateRunspace()
        $fresh.ApartmentState = 'MTA'
        $fresh.ThreadOptions = 'ReuseThread'
        $fresh.Open()
        $script:WorkRunspace = $fresh
    } catch { }
}

function Update-DevKitWorkAsyncPoll {
    if (-not $script:WorkBusy) { return }
    if ($script:WorkAsync.IsCompleted) {
        $result = $null
        try {
            $out = $script:WorkShell.EndInvoke($script:WorkAsync)
            if ($out -and $out.Count -gt 0) { $result = $out[0] }
        } catch { }
        try { $script:WorkShell.Dispose() } catch { }
        $script:WorkShell = $null
        $script:WorkBusy = $false
        $kind = $script:WorkKind
        $script:WorkKind = $null
        if ($result) {
            switch ($kind) {
                'JunkScan'    { Update-DevKitWidgetJunk -Junk $result.Junk }
                'JunkClean'   { Complete-DevKitJunkClean -Clean $result.Clean }
                'GitOverview' {
                    # A project switch mid-flight must not render the OLD
                    # project's graph/badge under the NEW project's name.
                    if ($script:WorkProjectPath -and $script:ActiveProjectPath -and $script:WorkProjectPath -ne $script:ActiveProjectPath) {
                        $script:GitRefreshPending = $true
                    } else {
                        Update-DevKitWidgetGitFlyout -Overview $result.Git
                    }
                }
                'EnvDrift' {
                    # Same stale-result guard as GitOverview: a project switch
                    # mid-flight must not render the OLD project's drift hint
                    # under the NEW project's name, and silencing that raced
                    # with the check wins over a stale drift result.
                    if ($script:WorkProjectPath -and $script:ActiveProjectPath -and $script:WorkProjectPath -ne $script:ActiveProjectPath) {
                        $script:EnvDriftRefreshPending = $true
                    } elseif ($script:ActiveProjectPath -and (Test-DevKitEnvDriftSilenced -Path $script:ActiveProjectPath)) {
                        $ui.EnvDriftRow.Visibility = 'Collapsed'
                    } else {
                        Set-DevKitWidgetEnvDriftResult -Drift $result.Drift
                    }
                }
                'GitHubPRs' {
                    # Same stale-project guard as GitOverview/EnvDrift. No
                    # button fires this Kind yet (stage 2 adds that trigger,
                    # plus a re-fire-when-free pending flag to match
                    # GitRefreshPending/EnvDriftRefreshPending if it needs
                    # one) - a stale result is simply dropped for now rather
                    # than rendered under the wrong project.
                    if (-not $script:WorkProjectPath -or -not $script:ActiveProjectPath -or $script:WorkProjectPath -eq $script:ActiveProjectPath) {
                        Update-DevKitWidgetPullRequests -Result $result.PullRequests
                    }
                }
                'GitHubIssues' {
                    # Same stale-project guard; see GitHubPRs comment above.
                    if (-not $script:WorkProjectPath -or -not $script:ActiveProjectPath -or $script:WorkProjectPath -eq $script:ActiveProjectPath) {
                        Update-DevKitWidgetIssues -Result $result.Issues
                    }
                }
                default {
                    # GitFetch/GitPull/GitPush: last output line to the status
                    # line, fresh overview to the graph - but only if the
                    # project didn't switch mid-action (same stale guard as
                    # the GitOverview branch).
                    if (-not $script:WorkProjectPath -or -not $script:ActiveProjectPath -or $script:WorkProjectPath -eq $script:ActiveProjectPath) {
                        if ($result.GitAction) {
                            $ui.GitFlyoutStatus.Text = [string]$result.GitAction.LastLine
                            $ui.GitFlyoutStatus.Foreground = Get-WidgetResource $(if ($result.GitAction.Success) { 'BrushTextDim' } else { 'BrushAccentEmber' })
                        }
                        Update-DevKitWidgetGitFlyout -Overview $result.Git
                    } else {
                        $script:GitRefreshPending = $true
                    }
                }
            }
        }
        # A refresh declined while this job held the slot fires now that it
        # is free (covers project switches and the periodic badge refresh).
        if ($script:GitRefreshPending -and $script:ActiveProjectPath) {
            $script:GitRefreshPending = $false
            Start-DevKitGitRefresh
        } else {
            $script:GitRefreshPending = $false
        }
        # Same re-fire for an EnvDrift check declined while this job held the
        # slot (project switch, or it lost the race against a junk/git job).
        if ($script:EnvDriftRefreshPending -and $script:ActiveProjectPath) {
            $script:EnvDriftRefreshPending = $false
            Update-DevKitWidgetEnvDrift
        } else {
            $script:EnvDriftRefreshPending = $false
        }
    } elseif (((Get-Date) - $script:WorkStarted).TotalSeconds -gt 30) {
        $kind = $script:WorkKind
        $script:WorkKind = $null
        Reset-DevKitWorkRunspace
        $script:WorkBusy = $false
        if ($kind -like 'Junk*') {
            $ui.BtnJunkClean.IsEnabled = $true
            $ui.JunkStatusText.Text = 'Operation timed out - try again.'
            $ui.JunkStatusText.Visibility = 'Visible'
        } elseif ($kind -eq 'GitHubPRs' -or $kind -eq 'GitHubIssues') {
            # Checked ahead of the 'Git*' wildcard below - GitHubPRs/
            # GitHubIssues would otherwise match it and wrongly stamp the git
            # flyout's status line / re-enable git action buttons. Replace the
            # stuck "Loading..." text left by Set-DevKitGitActiveTab, and
            # un-stamp the per-tab fetch timestamp (back to MinValue) so the
            # staleness check in Set-DevKitGitActiveTab doesn't block an
            # immediate retry on the next tab visit - mirrors the Junk*/Git*
            # branches above/below replacing their own stuck-loading UI.
            $timeoutResult = [pscustomobject]@{ ErrorMessage = 'GitHub CLI did not answer (timed out) - switch tabs to retry.' }
            if ($kind -eq 'GitHubPRs') {
                $script:GitPrLastFetch = [datetime]::MinValue
                Update-DevKitWidgetPullRequests -Result $timeoutResult
            } else {
                $script:GitIssuesLastFetch = [datetime]::MinValue
                Update-DevKitWidgetIssues -Result $timeoutResult
            }
        } elseif ($kind -like 'Git*') {
            $ui.GitFlyoutStatus.Text = 'git did not answer (timed out).'
            # A git ACTION that times out never produces an overview render,
            # which is what re-enables the buttons Start-DevKitGitAction
            # disabled - re-enable them here or they'd stay dead for minutes.
            if ($kind -ne 'GitOverview') {
                foreach ($b in @($ui.BtnGitFetch, $ui.BtnGitPull, $ui.BtnGitPush, $ui.BtnGitOpenHub, $ui.BtnGitActions)) { $b.IsEnabled = $true }
            }
        }
        if ($script:GitRefreshPending -and $script:ActiveProjectPath) {
            $script:GitRefreshPending = $false
            Start-DevKitGitRefresh
        } else {
            $script:GitRefreshPending = $false
        }
        if ($script:EnvDriftRefreshPending -and $script:ActiveProjectPath) {
            $script:EnvDriftRefreshPending = $false
            Update-DevKitWidgetEnvDrift
        } else {
            $script:EnvDriftRefreshPending = $false
        }
    }
}

# ==================== SYSTEM JUNK GAUGE ====================
# A fourth radial dial under the CPU/MEM/GPU card: total reclaimable junk
# (temp folders + Windows Update cache + Recycle Bin), where a full 270-degree
# arc means 10 GB. Scans run at startup, after a clean, and every 5 minutes
# from the slow timer - all in the shared work runspace above.
$script:JunkCapBytes = 10GB
$script:JunkLastScan = Get-Date
$script:GitBadgeLastRefresh = Get-Date   # ambient badge re-polls every 2 min via the slow timer
$script:EnvDriftLastCheck = [datetime]::MinValue

function Format-DevKitJunkSize {
    param([double]$Bytes)
    if ($Bytes -ge 1TB) { return '{0:N2} TB' -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return '{0:N1} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N0} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N0} KB' -f ($Bytes / 1KB) }
    return "$([int]$Bytes) B"
}

function Start-DevKitJunkScan {
    # Only stamp the clock when the job actually started - otherwise a busy
    # work runspace (git action/clean in flight) at the 5-minute tick would
    # defer the scan forever instead of retrying on the next tick.
    if (Start-DevKitWorkJob -Kind 'JunkScan') {
        $script:JunkLastScan = Get-Date
    } else {
        $script:JunkLastScan = (Get-Date).AddSeconds(-270)   # retry in ~30s, not 5 minutes
    }
}

function Update-DevKitWidgetJunk {
    # Pure render of an already-collected scan, on the dispatcher thread.
    param($Junk)
    if (-not $Junk) {
        Set-DevKitGauge -Key 'Junk' -Percent 0 -Available $false -Hot $false -ValueString '' -SubString ''
        return
    }
    $total = [double]$Junk.TotalBytes
    $percent = ($total / $script:JunkCapBytes) * 100.0
    Set-DevKitGauge -Key 'Junk' -Percent $percent -Available $true -Hot ($percent -ge 90) `
        -ValueString (Format-DevKitJunkSize $total) -SubString 'of 10 GB'
}

function Complete-DevKitJunkClean {
    param($Clean)
    $ui.BtnJunkClean.IsEnabled = $true
    $ui.JunkStatusText.Text = if ($Clean) { "Freed $(Format-DevKitJunkSize ([double]$Clean.FreedBytes))" } else { 'Clean finished.' }
    $ui.JunkStatusText.Foreground = Get-DevKitGitBrush '#3EDD8F'   # BrushSuccess hex (kept theme-independent)
    $ui.JunkStatusText.Visibility = 'Visible'
    Start-DevKitJunkScan   # re-scan so the gauge reflects the clean
}

$ui.BtnJunkTool.Add_Click({ Start-DevKitWidgetTool -RelativeScript 'maintenance\Clear-DiskJunk.ps1' -Title 'Clear Disk Junk' })
$ui.BtnJunkClean.Add_Click({
    if ($script:WorkBusy) {
        $ui.JunkStatusText.Text = 'Busy - try again in a moment.'
        $ui.JunkStatusText.Visibility = 'Visible'
        return
    }
    $yes = Show-DevKitWidgetConfirm -Title 'Clean System Junk' `
        -Message "This permanently deletes the contents of your user temp folder and empties the Recycle Bin.`n`nThis cannot be undone. Continue?"
    if (-not $yes) { return }
    $ui.BtnJunkClean.IsEnabled = $false
    $ui.JunkStatusText.Text = 'Cleaning...'
    $ui.JunkStatusText.Visibility = 'Visible'
    if (-not (Start-DevKitWorkJob -Kind 'JunkClean')) {
        $ui.BtnJunkClean.IsEnabled = $true
        $ui.JunkStatusText.Text = 'Could not start the clean - try again.'
    }
})

# ==================== GITHUB FLYOUT ====================
# Side panel for the active project: branch + ahead/behind, the drawn commit
# graph (lanes + gradient S-curves + ref pills - see Render-DevKitGitGraph),
# fetch/pull/push, open-on-GitHub links, and a shortcut to the real Git
# Cleanup tool. Lives in whichever root-Grid column (0/west or 2/east) faces
# INTO the screen - the opposite of the docked edge - toggled alongside
# $script:DockMode in Set-DevKitWidgetDock. Opening grows the window by
# FlyoutWidth px on that side; closing restores the geometry. The GIT
# pull-tab (BtnGitTab) that opens/closes it is always visible regardless of
# open state - see Sync-DevKitWidgetGitState below for its enabled/disabled
# state.
$script:MinFlyoutWidth = 220
$script:MaxFlyoutWidth = 500

function Get-DevKitGitFlyoutWidthSetting {
    # preferences.gitFlyoutWidth, clamped to the supported grip range; a
    # missing/zero/garbage value falls back to the old fixed width (300).
    # Loaded once at startup only (unlike widgetWidth, which is re-read
    # implicitly via Get-DevKitWidgetWidth before every dock) since it only
    # ever changes via this same session's grip drag.
    try {
        $w = [double](Get-DevKitSettings).preferences.gitFlyoutWidth
        if ($w -gt 0) { return [math]::Min($script:MaxFlyoutWidth, [math]::Max($script:MinFlyoutWidth, $w)) }
    } catch { }
    return 300
}

function Save-DevKitGitFlyoutWidthSetting {
    try {
        $settings = Get-DevKitSettings
        $settings.preferences.gitFlyoutWidth = [int][math]::Round($script:FlyoutWidth)
        Set-DevKitSettings -Settings $settings
    } catch { }
}

function Get-DevKitNotesFlyoutWidthSetting {
    # preferences.notesFlyoutWidth - same clamp/fallback contract as the Git
    # flyout's width above, persisted independently so each panel keeps the
    # width the user actually gave it.
    try {
        $w = [double](Get-DevKitSettings).preferences.notesFlyoutWidth
        if ($w -gt 0) { return [math]::Min($script:MaxFlyoutWidth, [math]::Max($script:MinFlyoutWidth, $w)) }
    } catch { }
    return 300
}

function Save-DevKitNotesFlyoutWidthSetting {
    try {
        $settings = Get-DevKitSettings
        $settings.preferences.notesFlyoutWidth = [int][math]::Round($script:NotesFlyoutWidth)
        Set-DevKitSettings -Settings $settings
    } catch { }
}

$script:FlyoutWidth = Get-DevKitGitFlyoutWidthSetting
$script:GitFlyoutOpen = $false
$script:NotesFlyoutWidth = Get-DevKitNotesFlyoutWidthSetting
$script:NotesFlyoutOpen = $false
$script:GitOverview = $null     # last Get-DevKitRepoOverview result
$script:GitRefreshPending = $false   # a GitOverview was declined while the work runspace was busy
$script:EnvDriftRefreshPending = $false   # an EnvDrift check was declined while the work runspace was busy

function Get-DevKitWidgetFlyoutExtra {
    if ($script:GitFlyoutOpen) { return $script:FlyoutWidth }
    if ($script:NotesFlyoutOpen) { return $script:NotesFlyoutWidth }
    return 0
}

function Test-DevKitEnvDriftSilenced {
    # True when the given project path is on the user's dismissed list
    # (preferences.envDriftSilencedProjects). String -contains is already
    # case-insensitive, matching how Windows paths compare everywhere else
    # in this file.
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        $list = @((Get-DevKitSettings).preferences.envDriftSilencedProjects)
        return [bool]($list -contains $Path)
    } catch { return $false }
}

function Set-DevKitEnvDriftSilenced {
    # Adds/removes one project path from the dismissed list and persists it.
    param([Parameter(Mandatory = $true)][string]$Path, [bool]$Silenced)
    try {
        $settings = Get-DevKitSettings
        $list = @($settings.preferences.envDriftSilencedProjects)
        if ($Silenced) {
            if ($list -notcontains $Path) { $list += $Path }
        } else {
            $list = @($list | Where-Object { $_ -ne $Path })
        }
        $settings.preferences.envDriftSilencedProjects = $list
        Set-DevKitSettings -Settings $settings
    } catch { }
}

function Clear-DevKitEnvDriftSilenced {
    # "Re-enable dismissed .env warnings" in Settings - the reversal path
    # for BtnEnvSilence, since dismissing is otherwise permanent/per-project
    # and has no other UI surface to toggle back individually.
    try {
        $settings = Get-DevKitSettings
        $settings.preferences.envDriftSilencedProjects = @()
        Set-DevKitSettings -Settings $settings
    } catch { }
}

function Update-DevKitWidgetEnvDrift {
    # Kicks off the .env drift check for the active project (or hides the
    # row/skips the check when there's nothing to show). The actual
    # Test-Path/Get-Content calls run in the shared work runspace via
    # Start-DevKitWorkJob -Kind 'EnvDrift' - a project on an unreachable
    # mapped/UNC network drive can otherwise block Test-Path/Get-Content for
    # the OS SMB timeout (tens of seconds), and this runs on the dispatcher
    # thread (project-switch handler, once-a-minute SlowTimer tick), so
    # collecting inline would freeze the whole widget for that long. Same
    # async start/poll/render pattern as GitOverview; the actual render
    # happens in Set-DevKitWidgetEnvDriftResult once the job completes.
    if (-not $script:ActiveProjectPath) { $ui.EnvDriftRow.Visibility = 'Collapsed'; return }
    if (Test-DevKitEnvDriftSilenced -Path $script:ActiveProjectPath) {
        $ui.EnvDriftRow.Visibility = 'Collapsed'
        return
    }
    if (-not (Start-DevKitWorkJob -Kind 'EnvDrift' -ProjectPath $script:ActiveProjectPath)) {
        # Work runspace busy (junk scan/git call in flight) - retried once
        # the slot frees, same as a declined GitOverview.
        $script:EnvDriftRefreshPending = $true
    }
}

function Set-DevKitWidgetEnvDriftResult {
    # Renders the .env drift hint from an already-collected Get-DevKitEnvDrift
    # result (computed off-thread by the 'EnvDrift' work job). Pure render -
    # no file I/O here, mirroring Render-DevKitGitGraph.
    param($Drift)
    if (-not $Drift -or (@($Drift.Missing).Count -eq 0 -and @($Drift.Empty).Count -eq 0)) {
        $ui.EnvDriftRow.Visibility = 'Collapsed'
        return
    }
    $bits = @()
    if (@($Drift.Missing).Count -gt 0) { $bits += "missing $(@($Drift.Missing).Count) key$(if (@($Drift.Missing).Count -ne 1) { 's' })" }
    if (@($Drift.Empty).Count -gt 0) { $bits += "$(@($Drift.Empty).Count) empty" }
    $names = (@($Drift.Missing) | Select-Object -First 4) -join ', '
    if (@($Drift.Missing).Count -gt 4) { $names += ', ...' }
    $envFile = if ($Drift.EnvFile) { $Drift.EnvFile } else { '.env' }
    $ui.EnvDriftText.Text = "$envFile vs $($Drift.Template): $($bits -join ', ')$(if ($names) { " - $names" })"
    $ui.EnvDriftRow.Visibility = 'Visible'
}

function Sync-DevKitWidgetGitState {
    # The flyout toggle and the project-scoped quick actions only work with
    # an active project; losing the active project while the flyout is open
    # closes it (and hides the ambient badge / env hint).
    $hasProject = $null -ne $script:ActiveProjectPath
    $ui.BtnGitTab.IsEnabled = $hasProject
    $ui.BtnGitTab.Opacity = if ($hasProject) { 1.0 } else { 0.45 }
    $ui.BtnNotesTab.IsEnabled = $hasProject
    $ui.BtnNotesTab.Opacity = if ($hasProject) { 1.0 } else { 0.45 }
    foreach ($b in @($ui.BtnOpenEditor, $ui.BtnOpenExplorer, $ui.BtnOpenTerminal, $ui.BtnRunScript)) {
        $b.IsEnabled = $hasProject
        $b.Opacity = if ($hasProject) { 1.0 } else { 0.45 }
    }
    if (-not $hasProject) {
        $ui.GitBadgeText.Visibility = 'Collapsed'
        $ui.EnvDriftRow.Visibility = 'Collapsed'
        if ($script:GitFlyoutOpen) { Set-DevKitGitFlyout -Open $false }
        if ($script:NotesFlyoutOpen) { Set-DevKitNotesFlyout -Open $false }
        return
    }
    # Project changed while the Notes panel is open: flush the old project's
    # pending edits and re-render for the new one (closed panels just reload
    # lazily on their next open).
    if ($script:NotesFlyoutOpen -and $script:NotesProjectPath -ne $script:ActiveProjectPath) {
        Open-DevKitWidgetNotesProject
    }
    Start-DevKitGitRefresh   # keeps the ambient badge (and open flyout) current
    # Active project changed under us - never leave the PR/Issues tabs (if
    # currently shown) staring at the OLD project's data; reset to Commits,
    # same as opening the flyout fresh. Set-DevKitGitActiveTab itself only
    # re-fetches PRs/Issues lazily when THEIR tab is next selected, so this
    # is cheap even when called redundantly (e.g. the initial project load).
    Set-DevKitGitActiveTab -Tab 'Commits'
    if ($script:GitFlyoutOpen) {
        $ui.GitFlyoutTitle.Text = [string]$script:ActiveProjectName
    }
    Update-DevKitWidgetEnvDrift
}

$script:GitFlyoutAnimToken = 0

function Start-DevKitFlyoutSlide {
    # Animates one animatable dependency property (Border.Width / Window.Width
    # / Window.Left) toward $To over ~220ms - EaseOut reads natural for the
    # flyout/window arriving on open, EaseIn for it leaving on close. A bare
    # "To" DoubleAnimation (no From) always starts from whatever the property's
    # CURRENT effective value is, so a rapid double-toggle that begins a new
    # animation mid-flight still eases smoothly from wherever things actually
    # sit - BeginAnimation on the same property naturally supersedes whatever
    # animation was running before, no manual "read the live value first"
    # bookkeeping needed here.
    #
    # The one thing BeginAnimation does NOT do on its own: once a Storyboard
    # completes, WPF holds the property at its final animated value forever
    # (FillBehavior.HoldEnd) - a later plain ".Width = x" assignment would
    # silently lose to that held animation. So Completed clears the animation
    # and re-applies the exact target as a plain local value once. $Token
    # (the caller's per-toggle counter snapshot) guards against a STALE
    # Completed - from a toggle that got superseded by a newer one before it
    # finished - clobbering the newer animation's own hold.
    param(
        [System.Windows.DependencyObject]$Target,
        [System.Windows.DependencyProperty]$Property,
        [double]$To,
        [bool]$Opening,
        [int]$Token
    )
    $anim = New-Object Windows.Media.Animation.DoubleAnimation
    $anim.To = $To
    $anim.Duration = New-Object Windows.Duration ([TimeSpan]::FromMilliseconds(220))
    $ease = New-Object Windows.Media.Animation.QuadraticEase
    $ease.EasingMode = if ($Opening) { [Windows.Media.Animation.EasingMode]::EaseOut } else { [Windows.Media.Animation.EasingMode]::EaseIn }
    $anim.EasingFunction = $ease
    $anim.Add_Completed({
        if ($script:GitFlyoutAnimToken -ne $Token) { return }
        $Target.BeginAnimation($Property, $null)
        $Target.SetValue($Property, $To)
    }.GetNewClosure())
    $Target.BeginAnimation($Property, $anim)
}

function Set-DevKitGitFlyout {
    param([bool]$Open, [switch]$Instant)
    if ($Open -eq $script:GitFlyoutOpen) { return }
    if ($Open -and -not $script:ActiveProjectPath) { return }
    # Only one flyout at a time. Close-the-other INSTANTLY (not animated):
    # both panels animate window.Width/Left, and two slides in flight would
    # fight over them; the instant close settles the window synchronously
    # before this open computes its own targets from the current geometry.
    if ($Open -and $script:NotesFlyoutOpen) { Set-DevKitNotesFlyout -Open $false -Instant }

    # window.Width/Left and GitFlyout.Width are always animated together, in
    # lockstep (same target delta, same Duration/Easing), by this function -
    # so "content-only width/left" (the geometry the flyout ADDS on top of) is
    # invariant at any instant, mid-animation or fully at rest: reading it back
    # out via subtraction below always recovers the same value, whether or not
    # a previous slide is still finishing. That is what makes it safe to
    # recompute fresh targets on every call (including a rapid re-toggle)
    # without tracking a separate "logical base width" anywhere.
    $script:GitFlyoutAnimToken++
    $token = $script:GitFlyoutAnimToken
    $curFlyoutWidth = $ui.GitFlyout.Width
    $curLeft = $window.Left
    $contentWidth = $window.Width - $curFlyoutWidth
    $targetFlyoutWidth = if ($Open) { $script:FlyoutWidth } else { 0 }
    $targetWindowWidth = $contentWidth + $targetFlyoutWidth

    if ($Instant) {
        # Snap straight to the final values instead of animating - used by a
        # dock-side switch, which needs the flyout closed and window geometry
        # settled synchronously so its own plain Left/Width reassignment (for
        # the NEW dock side) isn't fought by a live slide still chasing the
        # OLD side's target. Cancel first: the token bump above already makes
        # any in-flight animation's Completed handler a no-op, but the
        # animation itself is still driving these properties every frame
        # until BeginAnimation(..., $null) detaches it. Note BeginAnimation(
        # ..., $null) reverts to the PRE-animation base value, not the live
        # mid-flight one - so $curLeft/$curFlyoutWidth (captured above, before
        # any cancel) are used for the math below, never a post-cancel re-read.
        $window.BeginAnimation([Windows.Window]::WidthProperty, $null)
        $window.BeginAnimation([Windows.Window]::LeftProperty, $null)
        $ui.GitFlyout.BeginAnimation([Windows.Controls.Border]::WidthProperty, $null)
        $ui.GitFlyout.Width = $targetFlyoutWidth
        $window.Width = $targetWindowWidth
        if ($script:DockMode -eq 'Right') {
            $contentLeft = $curLeft + $curFlyoutWidth
            $window.Left = if ($Open) { $contentLeft - $targetFlyoutWidth } else { $contentLeft }
        }
        $script:GitFlyoutOpen = $Open
        if ($Open) {
            $ui.GitFlyoutInner.Width = $script:FlyoutWidth
            $ui.BtnGitTab.Foreground = Get-WidgetResource 'BrushAccentBlue'
            $ui.GitFlyoutTitle.Text = [string]$script:ActiveProjectName
            $ui.GitFlyoutStatus.Text = ''
            Set-DevKitGitActiveTab -Tab 'Commits'   # never reopen mid-way through a stale PR/Issues tab
            Start-DevKitGitRefresh
        } else {
            $ui.BtnGitTab.Foreground = Get-WidgetResource 'BrushTextMuted'
        }
        return
    }

    if ($Open) {
        $script:GitFlyoutOpen = $true
        $ui.GitFlyoutInner.Width = $script:FlyoutWidth
        Start-DevKitFlyoutSlide -Target $ui.GitFlyout -Property ([Windows.Controls.Border]::WidthProperty) -To $targetFlyoutWidth -Opening $true -Token $token
        Start-DevKitFlyoutSlide -Target $window -Property ([Windows.Window]::WidthProperty) -To $targetWindowWidth -Opening $true -Token $token
        if ($script:DockMode -eq 'Right') {
            # Right-docked: the main widget's RIGHT edge is the pinned,
            # docked edge, so the flyout (west slot, column 0) must grow the
            # window LEFTWARD - Left slides left as Width grows, keeping
            # Left+Width (the right edge) fixed. Same lockstep invariant as
            # contentWidth above applies to window.Left + GitFlyout.Width.
            $contentLeft = $window.Left + $curFlyoutWidth
            $targetLeft = $contentLeft - $targetFlyoutWidth
            Start-DevKitFlyoutSlide -Target $window -Property ([Windows.Window]::LeftProperty) -To $targetLeft -Opening $true -Token $token
        }
        # Left-docked: the main widget's LEFT edge is the pinned edge (stays
        # at wa.Left), so the flyout (east slot, column 2) just grows the
        # window RIGHTWARD - Width grows, Left is untouched.
        $ui.BtnGitTab.Foreground = Get-WidgetResource 'BrushAccentBlue'
        $ui.GitFlyoutTitle.Text = [string]$script:ActiveProjectName
        $ui.GitFlyoutStatus.Text = ''
        Set-DevKitGitActiveTab -Tab 'Commits'   # never reopen mid-way through a stale PR/Issues tab
        Start-DevKitGitRefresh
    } else {
        $script:GitFlyoutOpen = $false
        Start-DevKitFlyoutSlide -Target $ui.GitFlyout -Property ([Windows.Controls.Border]::WidthProperty) -To 0 -Opening $false -Token $token
        Start-DevKitFlyoutSlide -Target $window -Property ([Windows.Window]::WidthProperty) -To $targetWindowWidth -Opening $false -Token $token
        if ($script:DockMode -eq 'Right') {
            # Mirror the open-side math: restore the right edge by sliding
            # Left back out by the same amount Width shrinks by.
            $contentLeft = $window.Left + $curFlyoutWidth
            Start-DevKitFlyoutSlide -Target $window -Property ([Windows.Window]::LeftProperty) -To $contentLeft -Opening $false -Token $token
        }
        $ui.BtnGitTab.Foreground = Get-WidgetResource 'BrushTextMuted'
    }
}

function Start-DevKitGitRefresh {
    if (-not $script:GitFlyoutOpen -and -not $script:ActiveProjectPath) { return }
    # Declined while the work runspace is busy? Remember it - the completion
    # poll re-fires once the slot frees, so a project switch mid-flight never
    # leaves the previous project's graph/badge on screen permanently.
    if (-not (Start-DevKitWorkJob -Kind 'GitOverview' -ProjectPath $script:ActiveProjectPath)) {
        $script:GitRefreshPending = $true
    }
}

$script:GitBrushCache = @{}
function Get-DevKitGitBrush {
    # Frozen-brush cache: the graph is rebuilt on every refresh, so brushes are
    # allocated once per hex value and reused. Accepts '#RRGGBB' or '#AARRGGBB'.
    param([Parameter(Mandatory = $true)][string]$Hex)
    if (-not $script:GitBrushCache) { $script:GitBrushCache = @{} }
    if (-not $script:GitBrushCache.ContainsKey($Hex)) {
        $brush = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($Hex))
        $brush.Freeze()
        $script:GitBrushCache[$Hex] = $brush
    }
    return $script:GitBrushCache[$Hex]
}

function Get-DevKitGitLinkBrush {
    # Curved links flow from the child lane's color into the parent lane's via
    # a vertical gradient - the "fluid line" look. Straight links stay solid.
    param([Parameter(Mandatory = $true)][string]$FromHex, [Parameter(Mandatory = $true)][string]$ToHex)
    $key = "$FromHex>$ToHex"
    if (-not $script:GitBrushCache.ContainsKey($key)) {
        $grad = New-Object Windows.Media.LinearGradientBrush
        $grad.StartPoint = [Windows.Point]::new(0, 0)
        $grad.EndPoint = [Windows.Point]::new(0, 1)
        $grad.MappingMode = [Windows.Media.BrushMappingMode]::RelativeToBoundingBox
        $grad.GradientStops.Add((New-Object Windows.Media.GradientStop ([Windows.Media.ColorConverter]::ConvertFromString($FromHex), 0.0))) | Out-Null
        $grad.GradientStops.Add((New-Object Windows.Media.GradientStop ([Windows.Media.ColorConverter]::ConvertFromString($ToHex), 1.0))) | Out-Null
        $grad.Freeze()
        $script:GitBrushCache[$key] = $grad
    }
    return $script:GitBrushCache[$key]
}

function Render-DevKitGitGraph {
    # Draws Get-DevKitRepoOverview's lane layout onto GitGraphCanvas: gradient
    # S-curve links between lanes, bright node dots with a HEAD ring, branch/
    # tag pills, and subject + meta text per commit. Pure render - the layout
    # was computed in the work runspace.
    param([Parameter(Mandatory = $true)]$Graph)

    $canvas = $ui.GitGraphCanvas
    $canvas.Children.Clear()

    $laneDx = 15.0; $rowH = 36.0; $leftPad = 16.0; $topPad = 10.0; $nodeR = 4.5
    $laneCount = [Math]::Max(1, [int]$Graph.LaneCount)
    $textX = $leftPad + ($laneCount * $laneDx) + 6.0
    # Member enumeration, not Measure-Object -Property: on Windows PowerShell
    # 5.1, -Property can't see hashtable keys (works on pwsh 7) and the
    # terminating error would kill every render on a supported shell.
    $maxRow = ($Graph.Nodes | ForEach-Object Row | Measure-Object -Maximum).Maximum
    $canvas.Width = $textX + 200
    $canvas.Height = $topPad * 2 + ($maxRow + 1) * $rowH

    # Links first so nodes sit on top of the lines.
    foreach ($link in $Graph.Links) {
        $x1 = $leftPad + $link.FromLane * $laneDx
        $y1 = $topPad + $link.FromRow * $rowH + ($rowH / 2)
        $x2 = $leftPad + $link.ToLane * $laneDx
        $y2 = $topPad + $link.ToRow * $rowH + ($rowH / 2)
        $geo = New-Object Windows.Media.StreamGeometry
        $ctx = $geo.Open()
        $ctx.BeginFigure([Windows.Point]::new($x1, $y1 + $nodeR), $false, $false)
        if ($link.FromLane -eq $link.ToLane) {
            $ctx.LineTo([Windows.Point]::new($x2, $y2 - $nodeR), $true, $false)
        } else {
            # S-curve: bend out of the child, travel, bend into the parent.
            $bend = [Math]::Min(26.0, ($y2 - $y1) / 2.0)
            $ctx.BezierTo([Windows.Point]::new($x1, $y1 + $bend), [Windows.Point]::new($x2, $y2 - $bend), [Windows.Point]::new($x2, $y2 - $nodeR), $true, $false)
        }
        $ctx.Close()
        $geo.Freeze()
        $path = New-Object Windows.Shapes.Path
        $path.Data = $geo
        $path.StrokeThickness = 1.8
        $path.StrokeStartLineCap = [Windows.Media.PenLineCap]::Round
        $path.StrokeEndLineCap = [Windows.Media.PenLineCap]::Round
        $path.Stroke = if ($link.FromLane -eq $link.ToLane) { Get-DevKitGitBrush $link.FromColor } else { Get-DevKitGitLinkBrush $link.FromColor $link.ToColor }
        $canvas.Children.Add($path) | Out-Null
    }

    $brightBrush = Get-WidgetResource 'BrushTextBright'
    $dimBrush = Get-WidgetResource 'BrushTextDim'
    $darkBrush = Get-DevKitGitBrush '#0A0D12'
    foreach ($node in $Graph.Nodes) {
        $cx = $leftPad + $node.Lane * $laneDx
        $cy = $topPad + $node.Row * $rowH + ($rowH / 2)
        $commit = $node.Commit
        $laneBrush = Get-DevKitGitBrush $node.Color
        $tip = "$($commit.Subject)`n$($commit.ShortHash)  -  $($commit.Author), $($commit.When)"

        if ($commit.IsHead) {
            $ring = New-Object Windows.Shapes.Ellipse
            $ring.Width = 14; $ring.Height = 14
            $ring.Stroke = $brightBrush
            $ring.StrokeThickness = 1.4
            [Windows.Controls.Canvas]::SetLeft($ring, $cx - 7)
            [Windows.Controls.Canvas]::SetTop($ring, $cy - 7)
            $ring.ToolTip = $tip
            $canvas.Children.Add($ring) | Out-Null
        }
        $dot = New-Object Windows.Shapes.Ellipse
        $dot.Width = $nodeR * 2; $dot.Height = $nodeR * 2
        $dot.Fill = $laneBrush
        $dot.Stroke = $darkBrush
        $dot.StrokeThickness = 1.2
        [Windows.Controls.Canvas]::SetLeft($dot, $cx - $nodeR)
        [Windows.Controls.Canvas]::SetTop($dot, $cy - $nodeR)
        $dot.ToolTip = $tip
        $canvas.Children.Add($dot) | Out-Null

        # Ref pills + subject on one line, meta line underneath.
        $panel = New-Object Windows.Controls.StackPanel
        $panel.Orientation = 'Horizontal'
        foreach ($ref in @($commit.Refs)) {
            $refColor = switch ($ref.Kind) { 'tag' { '#FFB020' } default { $node.Color } }
            $pill = New-Object Windows.Controls.Border
            $pill.CornerRadius = [Windows.CornerRadius]::new(7)
            $pill.Padding = [Windows.Thickness]::new(6, 1, 6, 1)
            $pill.Margin = [Windows.Thickness]::new(0, 0, 5, 0)
            $pillText = New-Object Windows.Controls.TextBlock
            $pillText.FontSize = 9
            $pillText.Text = [string]$ref.Name
            if ($ref.Kind -eq 'head') {
                $pill.Background = Get-DevKitGitBrush $refColor
                $pillText.Foreground = $darkBrush
            } else {
                $pill.Background = Get-DevKitGitBrush "#26$($refColor.Substring(1))"
                $pill.BorderBrush = Get-DevKitGitBrush $refColor
                $pill.BorderThickness = [Windows.Thickness]::new(1)
                $pillText.Foreground = Get-DevKitGitBrush $refColor
            }
            $pill.Child = $pillText
            $pill.ToolTip = $tip
            $panel.Children.Add($pill) | Out-Null
        }
        $subject = [string]$commit.Subject
        if ($subject.Length -gt 58) { $subject = $subject.Substring(0, 57) + '...' }
        $subjectText = New-Object Windows.Controls.TextBlock
        $subjectText.FontSize = 11
        $subjectText.Foreground = $brightBrush
        $subjectText.Text = $subject
        $subjectText.VerticalAlignment = 'Center'
        $panel.Children.Add($subjectText) | Out-Null
        [Windows.Controls.Canvas]::SetLeft($panel, $textX)
        [Windows.Controls.Canvas]::SetTop($panel, $cy - 16)
        $canvas.Children.Add($panel) | Out-Null

        $metaText = New-Object Windows.Controls.TextBlock
        $metaText.FontSize = 9
        $metaText.Foreground = $dimBrush
        $metaText.Text = "$($commit.ShortHash)  -  $($commit.Author)  -  $($commit.When)"
        [Windows.Controls.Canvas]::SetLeft($metaText, $textX)
        [Windows.Controls.Canvas]::SetTop($metaText, $cy + 4)
        $canvas.Children.Add($metaText) | Out-Null
    }

    # Width = what the rows actually need (measured), so the horizontal
    # scrollbar appears exactly when a subject/pill row outgrows the flyout.
    $neededWidth = $textX + 200
    $measureSize = New-Object Windows.Size ([double]::PositiveInfinity, [double]::PositiveInfinity)
    foreach ($child in $canvas.Children) {
        if ($child -is [Windows.Controls.StackPanel] -or $child -is [Windows.Controls.TextBlock]) {
            $child.Measure($measureSize)
            $right = [Windows.Controls.Canvas]::GetLeft($child) + $child.DesiredSize.Width
            if ($right -gt $neededWidth) { $neededWidth = $right }
        }
    }
    $canvas.Width = $neededWidth + 12
}

function Get-DevKitGitStatusStyle {
    # Maps a porcelain XY status code to a single display letter + brush key.
    # Staged half (X) wins over unstaged (Y) when both are set, matching how
    # most git UIs prioritize what's about to be committed.
    param([string]$Status)
    $code = if ($Status -and $Status.Length -ge 1 -and $Status[0] -ne ' ') { $Status[0] } elseif ($Status -and $Status.Length -ge 2) { $Status[1] } else { '?' }
    switch ($code) {
        'A' { return @{ Letter = 'A'; BrushKey = 'BrushSuccess' } }
        'M' { return @{ Letter = 'M'; BrushKey = 'BrushWarning' } }
        'D' { return @{ Letter = 'D'; BrushKey = 'BrushAccentEmber' } }
        'R' { return @{ Letter = 'R'; BrushKey = 'BrushAccentBlue' } }
        'C' { return @{ Letter = 'C'; BrushKey = 'BrushAccentBlue' } }
        'U' { return @{ Letter = 'U'; BrushKey = 'BrushAccentEmber' } }
        '?' { return @{ Letter = '?'; BrushKey = 'BrushTextSteel' } }
        default { return @{ Letter = $code; BrushKey = 'BrushTextMuted' } }
    }
}

function Add-DevKitUncommittedFileRow {
    # One row: a status-colored letter glyph + the (possibly long) path.
    param($Panel, $File)
    $grid = New-Object Windows.Controls.Grid
    $colGlyph = New-Object Windows.Controls.ColumnDefinition; $colGlyph.Width = [Windows.GridLength]::Auto
    $colPath = New-Object Windows.Controls.ColumnDefinition; $colPath.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
    $grid.ColumnDefinitions.Add($colGlyph)
    $grid.ColumnDefinitions.Add($colPath)
    $grid.Margin = '0,2,0,0'

    $style = Get-DevKitGitStatusStyle -Status ([string]$File.Status)
    $glyph = New-Object Windows.Controls.TextBlock
    $glyph.Style = Get-WidgetResource 'WidgetRowText'
    $glyph.Text = $style.Letter
    $glyph.FontWeight = 'SemiBold'
    $glyph.Width = 14
    $glyph.Foreground = Get-WidgetResource $style.BrushKey
    [Windows.Controls.Grid]::SetColumn($glyph, 0)
    $grid.Children.Add($glyph) | Out-Null

    $pathText = New-Object Windows.Controls.TextBlock
    $pathText.Style = Get-WidgetResource 'WidgetRowText'
    $pathText.Text = [string]$File.Path
    $pathText.ToolTip = [string]$File.Path
    $pathText.TextTrimming = 'CharacterEllipsis'
    $pathText.Margin = '6,0,0,0'
    [Windows.Controls.Grid]::SetColumn($pathText, 1)
    $grid.Children.Add($pathText) | Out-Null

    $Panel.Children.Add($grid) | Out-Null
}

function Update-DevKitGitUncommittedList {
    # Header badge (count) is cheap and always kept accurate, even on a
    # closed/background refresh, so the number is right the instant the user
    # opens the flyout. Rebuilding the N file rows is pure UI cost with zero
    # visible benefit while collapsed/closed, so - mirroring how the commit
    # graph itself is deferred via GraphSkipped - that part is skipped until
    # the flyout is actually open; Set-DevKitGitFlyout's open path triggers
    # Start-DevKitGitRefresh, which lands here again with the flyout already
    # marked open and repopulates the list then.
    param($Overview)
    $files = @()
    if ($Overview -and $Overview.DirtyFiles) { $files = @($Overview.DirtyFiles) }

    if ($files.Count -eq 0) {
        $ui.UncommittedExpander.Visibility = 'Collapsed'
        return
    }
    $ui.UncommittedExpander.Visibility = 'Visible'
    $ui.UncommittedCountBadgeText.Text = [string]$files.Count

    if (-not $script:GitFlyoutOpen) { return }
    $ui.UncommittedFilesPanel.Children.Clear()
    foreach ($f in $files) { Add-DevKitUncommittedFileRow -Panel $ui.UncommittedFilesPanel -File $f }
}

# ==================== GITHUB PRs / ISSUES ====================
# Tab strip (Commits | Pull Requests | Issues) lives in the Git flyout's
# content-area row - Set-DevKitGitActiveTab swaps which of the three
# GitTab*View siblings is Visible and lazily kicks off a background fetch via
# Start-DevKitWorkJob. Update-DevKitWidgetPullRequests/Issues below (invoked
# from Update-DevKitWorkAsyncPoll once that job completes) render the real
# PR-row / issue-accordion lists via Add-DevKitPrRow / Add-DevKitIssueAccordion.
$script:LastPrResult = $null
$script:LastIssuesResult = $null
$script:GitActiveTab = 'Commits'
# Per-tab staleness tracking (path + timestamp), mirroring $script:EnvDriftLastCheck's
# "re-check if more than 60s old" pattern, plus a path comparison so switching
# to a DIFFERENT project always counts as stale even if under 60s old.
$script:GitPrLastFetch = [datetime]::MinValue
$script:GitPrLastPath = $null
$script:GitIssuesLastFetch = [datetime]::MinValue
$script:GitIssuesLastPath = $null

function Set-DevKitGitPanelMessage {
    # Clears Panel and drops in a single dim message line - covers both the
    # "Loading X..." state (same idiom as GitGraphText's default "Loading
    # commit graph..." text) and the placeholder count/error text once a
    # fetch completes, since PullRequestsPanel/IssuesPanel have no XAML
    # fallback text of their own.
    param($Panel, [string]$Message)
    $Panel.Children.Clear()
    $line = New-Object Windows.Controls.TextBlock
    $line.Text = $Message
    $line.FontSize = 10.5
    $line.Foreground = Get-WidgetResource 'BrushTextDim'
    $line.TextWrapping = 'Wrap'
    $line.Margin = '0,6,0,0'
    $Panel.Children.Add($line) | Out-Null
}

function Set-DevKitGitActiveTab {
    <#
    .SYNOPSIS
        Switches the Git flyout's Commits/Pull-Requests/Issues tab: toggles
        the three GitTab*View panels' Visibility (and the Commits-only
        footer's), syncs the RadioButton group's checked state, and - when
        landing on PullRequests/Issues - lazily fires a background fetch if
        no data has been fetched yet for the CURRENT active project, or the
        last fetch is more than 60s old, or the active project changed since
        that fetch.
    #>
    param([ValidateSet('Commits', 'PullRequests', 'Issues')][string]$Tab)

    $script:GitActiveTab = $Tab
    $ui.GitTabCommitsView.Visibility = if ($Tab -eq 'Commits') { 'Visible' } else { 'Collapsed' }
    $ui.GitTabPullRequestsView.Visibility = if ($Tab -eq 'PullRequests') { 'Visible' } else { 'Collapsed' }
    $ui.GitTabIssuesView.Visibility = if ($Tab -eq 'Issues') { 'Visible' } else { 'Collapsed' }
    # Fetch/Pull/Push and the status line are meaningless outside Commits (a
    # PR/Issues list isn't a git working-tree action) - hide the whole footer
    # StackPanel (GitFlyoutStatus lives inside it) rather than treat the
    # status line separately.
    $ui.GitFlyoutFooter.Visibility = if ($Tab -eq 'Commits') { 'Visible' } else { 'Collapsed' }

    # Keep the RadioButton group in sync when this was invoked programmatically
    # (flyout open, project switch) rather than by the user clicking a tab -
    # assigning IsChecked on the already-checked button is a no-op, and the
    # Checked event only fires on the newly-checked one, which harmlessly
    # re-enters this same Tab branch (idempotent, no guard flag needed).
    $ui.TabCommits.IsChecked = ($Tab -eq 'Commits')
    $ui.TabPullRequests.IsChecked = ($Tab -eq 'PullRequests')
    $ui.TabIssues.IsChecked = ($Tab -eq 'Issues')

    if (-not $script:ActiveProjectPath) { return }

    if ($Tab -eq 'PullRequests') {
        $stale = ($script:GitPrLastPath -ne $script:ActiveProjectPath) -or (((Get-Date) - $script:GitPrLastFetch).TotalSeconds -gt 60)
        if ($stale) {
            Set-DevKitGitPanelMessage -Panel $ui.PullRequestsPanel -Message 'Loading pull requests...'
            if (Start-DevKitWorkJob -Kind 'GitHubPRs' -ProjectPath $script:ActiveProjectPath) {
                $script:GitPrLastFetch = Get-Date
                $script:GitPrLastPath = $script:ActiveProjectPath
            } else {
                # Work slot busy - render an error instead of leaving the
                # "Loading..." text stuck. GitPrLastFetch/Path are left as-is
                # (unstamped), so the NEXT switch to this tab still sees it
                # as stale and retries - no separate pending-flag needed here.
                Update-DevKitWidgetPullRequests -Result ([pscustomobject]@{ ErrorMessage = 'Busy with another operation - switch tabs to retry.' })
            }
        }
    } elseif ($Tab -eq 'Issues') {
        $stale = ($script:GitIssuesLastPath -ne $script:ActiveProjectPath) -or (((Get-Date) - $script:GitIssuesLastFetch).TotalSeconds -gt 60)
        if ($stale) {
            Set-DevKitGitPanelMessage -Panel $ui.IssuesPanel -Message 'Loading issues...'
            if (Start-DevKitWorkJob -Kind 'GitHubIssues' -ProjectPath $script:ActiveProjectPath) {
                $script:GitIssuesLastFetch = Get-Date
                $script:GitIssuesLastPath = $script:ActiveProjectPath
            } else {
                Update-DevKitWidgetIssues -Result ([pscustomobject]@{ ErrorMessage = 'Busy with another operation - switch tabs to retry.' })
            }
        }
    }
}

function Format-DevKitRelativeTime {
    # Compact "X ago" for GitHub timestamps (PR/issue updatedAt, ISO 8601) -
    # same compact-unit spirit as Format-DevKitNodeAge above, but extended
    # out to weeks/months/years since these can be genuinely old (unlike
    # node process uptime, which never is). Returns '' on an unparsable/
    # empty timestamp so callers can just omit the "updated ..." clause.
    param([string]$Iso)
    if ([string]::IsNullOrWhiteSpace($Iso)) { return '' }
    $then = $null
    try {
        $then = [datetime]::Parse($Iso, [System.Globalization.CultureInfo]::InvariantCulture,
            ([System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal))
    } catch {
        return ''
    }
    $span = (Get-Date).ToUniversalTime() - $then
    if ($span.TotalSeconds -lt 0) { $span = [timespan]::Zero }
    if ($span.TotalMinutes -lt 1) { return 'just now' }
    if ($span.TotalMinutes -lt 60) { return "$([int]$span.TotalMinutes)m ago" }
    if ($span.TotalHours -lt 24) { return "$([int]$span.TotalHours)h ago" }
    if ($span.TotalDays -lt 7) { return "$([int]$span.TotalDays)d ago" }
    if ($span.TotalDays -lt 30) { return "$([int][math]::Floor($span.TotalDays / 7))w ago" }
    if ($span.TotalDays -lt 365) { return "$([int][math]::Floor($span.TotalDays / 30))mo ago" }
    return "$([int][math]::Floor($span.TotalDays / 365))y ago"
}

function Open-DevKitExternalUrl {
    # Safe Start-Process wrapper for opening a URL in the default browser -
    # same try/catch shape Open-DevKitRepoPage (BtnGitOpenHub) already uses,
    # just with no status line to report failure into (PR rows/issue
    # accordions don't have one - the Commits-only GitFlyoutFooter is hidden
    # on these tabs), so a failure is silently swallowed rather than thrown.
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return }
    try { Start-Process $Url } catch { }
}

function Get-DevKitLabelChipBrush {
    # GitHub label 'color' is a hex string with NO leading '#' (verified
    # against real 'gh issue list --json labels' output). Builds the chip's
    # background brush from that color and picks a white/black foreground
    # via a standard perceptual-luminance check so the label text stays
    # legible against ANY color GitHub allows - verified against real label
    # colors: d73a4a (red, ~107 luma -> white), 0e8a16 (green, ~88 -> white),
    # fbca04 (yellow, ~194 -> black).
    param([string]$HexColor)
    $hex = "$HexColor".TrimStart('#')
    if ($hex -notmatch '^[0-9A-Fa-f]{6}$') { $hex = '6E7681' }  # GitHub's own default gray, used as a safe fallback
    [byte]$r = [Convert]::ToInt32($hex.Substring(0, 2), 16)
    [byte]$g = [Convert]::ToInt32($hex.Substring(2, 2), 16)
    [byte]$b = [Convert]::ToInt32($hex.Substring(4, 2), 16)
    $luminance = (0.299 * $r) + (0.587 * $g) + (0.114 * $b)
    $fg = if ($luminance -gt 145) { [Windows.Media.Brushes]::Black } else { [Windows.Media.Brushes]::White }
    $bg = [Windows.Media.SolidColorBrush]::new([Windows.Media.Color]::FromRgb($r, $g, $b))
    return @{ Background = $bg; Foreground = $fg }
}

function New-DevKitLabelChip {
    param([string]$Name, [string]$HexColor)
    $colors = Get-DevKitLabelChipBrush -HexColor $HexColor
    $chip = New-Object Windows.Controls.Border
    $chip.Background = $colors.Background
    $chip.CornerRadius = 8
    $chip.Padding = '6,1'
    $chip.Margin = '4,0,0,0'
    $chip.VerticalAlignment = 'Center'
    $text = New-Object Windows.Controls.TextBlock
    $text.Text = $Name
    $text.FontSize = 9
    $text.FontWeight = 'SemiBold'
    $text.Foreground = $colors.Foreground
    $chip.Child = $text
    return $chip
}

function Add-DevKitPrRow {
    # One clickable PR card (ToolCard reuses its existing hover-lift/glow
    # animation for free): "#N  Title" (ellipsis) + draft/review badges on
    # the title line, "by author  |  head -> base  |  updated X ago" below.
    # Clicking anywhere on the row opens the PR on GitHub, same as a node
    # table port link.
    param($Panel, $Pr)

    $row = New-Object Windows.Controls.Border
    $row.Style = Get-WidgetResource 'ToolCard'
    $row.Cursor = [System.Windows.Input.Cursors]::Hand
    $row.ToolTip = "Open #$($Pr.number) on GitHub"
    $prUrl = [string]$Pr.url
    $row.Add_MouseLeftButtonUp({ Open-DevKitExternalUrl -Url $prUrl }.GetNewClosure())

    $stack = New-Object Windows.Controls.StackPanel

    $titleGrid = New-Object Windows.Controls.Grid
    $colTitle = New-Object Windows.Controls.ColumnDefinition; $colTitle.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
    $colBadges = New-Object Windows.Controls.ColumnDefinition; $colBadges.Width = [Windows.GridLength]::Auto
    $titleGrid.ColumnDefinitions.Add($colTitle)
    $titleGrid.ColumnDefinitions.Add($colBadges)

    $titleText = New-Object Windows.Controls.TextBlock
    $titleText.Style = Get-WidgetResource 'WidgetExpanderTitle'
    $titleText.Text = "#$($Pr.number)  $($Pr.title)"
    $titleText.TextTrimming = 'CharacterEllipsis'
    $titleText.ToolTip = [string]$Pr.title
    [Windows.Controls.Grid]::SetColumn($titleText, 0)
    $titleGrid.Children.Add($titleText) | Out-Null

    $badgePanel = New-Object Windows.Controls.StackPanel
    $badgePanel.Orientation = 'Horizontal'
    $badgePanel.Margin = '8,0,0,0'
    if ($Pr.isDraft) {
        $b = New-Object Windows.Controls.Border
        $b.Style = Get-WidgetResource 'BadgeNeutral'
        $b.VerticalAlignment = 'Center'
        $t = New-Object Windows.Controls.TextBlock
        $t.Style = Get-WidgetResource 'BadgeNeutralText'
        $t.Text = 'DRAFT'
        $b.Child = $t
        $badgePanel.Children.Add($b) | Out-Null
    }
    $decision = [string]$Pr.reviewDecision
    if ($decision -eq 'APPROVED') {
        $b = New-Object Windows.Controls.Border
        $b.Style = Get-WidgetResource 'BadgeSuccess'
        $b.VerticalAlignment = 'Center'
        $b.Margin = '4,0,0,0'
        $t = New-Object Windows.Controls.TextBlock
        $t.Style = Get-WidgetResource 'BadgeSuccessText'
        $t.Text = 'APPROVED'
        $b.Child = $t
        $badgePanel.Children.Add($b) | Out-Null
    } elseif ($decision -eq 'CHANGES_REQUESTED') {
        $b = New-Object Windows.Controls.Border
        $b.Style = Get-WidgetResource 'BadgeWarning'
        $b.VerticalAlignment = 'Center'
        $b.Margin = '4,0,0,0'
        $t = New-Object Windows.Controls.TextBlock
        $t.Style = Get-WidgetResource 'BadgeWarningText'
        $t.Text = 'CHANGES REQUESTED'
        $b.Child = $t
        $badgePanel.Children.Add($b) | Out-Null
    }
    [Windows.Controls.Grid]::SetColumn($badgePanel, 1)
    $titleGrid.Children.Add($badgePanel) | Out-Null
    $stack.Children.Add($titleGrid) | Out-Null

    $sub = New-Object Windows.Controls.TextBlock
    $sub.Style = Get-WidgetResource 'WidgetExpanderSub'
    $sub.TextTrimming = 'CharacterEllipsis'
    $author = if ($Pr.author -and $Pr.author.login) { [string]$Pr.author.login } else { 'unknown' }
    $subParts = @("by $author", "$($Pr.headRefName) -> $($Pr.baseRefName)")
    $when = Format-DevKitRelativeTime -Iso ([string]$Pr.updatedAt)
    if ($when) { $subParts += "updated $when" }
    $sub.Text = ($subParts -join '  |  ')
    $stack.Children.Add($sub) | Out-Null

    $row.Child = $stack
    $Panel.Children.Add($row) | Out-Null
}

function Get-DevKitIssueBodyText {
    # Plain-text rendering of a GitHub issue body: no markdown renderer in
    # this app (adding one is out of scope) - the raw markdown source reads
    # fine on its own once triple-backtick code-fence markers are stripped
    # so they don't clutter the text as stray backticks. Empty/null bodies
    # (GitHub allows them) get a friendly placeholder instead of blank space.
    param([string]$Body)
    if ([string]::IsNullOrWhiteSpace($Body)) { return 'No description provided.' }
    return ($Body -replace '```', '').Trim()
}

function Add-DevKitIssueAccordion {
    # One collapsed-by-default Expander per issue - the shared Expander
    # ControlTemplate in Theme.xaml already gives this the fade+unfold
    # animation for free. Header = "#N  Title" (ellipsis) + label-color
    # chips; Content = full body + comment count + an Open-on-GitHub link,
    # matching Add-DevKitPrRow's safe Start-Process pattern.
    param($Panel, $Issue)

    $expander = New-Object Windows.Controls.Expander
    $expander.IsExpanded = $false
    $expander.Margin = '0,0,0,8'
    $expander.ToolTip = 'Click to expand or collapse'

    $headerGrid = New-Object Windows.Controls.Grid
    $colTitle = New-Object Windows.Controls.ColumnDefinition; $colTitle.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
    $colChips = New-Object Windows.Controls.ColumnDefinition; $colChips.Width = [Windows.GridLength]::Auto
    $headerGrid.ColumnDefinitions.Add($colTitle)
    $headerGrid.ColumnDefinitions.Add($colChips)

    $titleText = New-Object Windows.Controls.TextBlock
    $titleText.Style = Get-WidgetResource 'WidgetExpanderTitle'
    $titleText.Text = "#$($Issue.number)  $($Issue.title)"
    $titleText.TextTrimming = 'CharacterEllipsis'
    $titleText.ToolTip = [string]$Issue.title
    [Windows.Controls.Grid]::SetColumn($titleText, 0)
    $headerGrid.Children.Add($titleText) | Out-Null

    $chipPanel = New-Object Windows.Controls.StackPanel
    $chipPanel.Orientation = 'Horizontal'
    $chipPanel.Margin = '8,0,0,0'
    foreach ($lbl in @($Issue.labels)) {
        if (-not $lbl) { continue }
        $chipPanel.Children.Add((New-DevKitLabelChip -Name ([string]$lbl.name) -HexColor ([string]$lbl.color))) | Out-Null
    }
    [Windows.Controls.Grid]::SetColumn($chipPanel, 1)
    $headerGrid.Children.Add($chipPanel) | Out-Null
    $expander.Header = $headerGrid

    $content = New-Object Windows.Controls.StackPanel

    $bodyText = New-Object Windows.Controls.TextBlock
    $bodyText.Style = Get-WidgetResource 'CardSubtitle'
    $bodyText.Margin = 0
    $bodyText.Text = Get-DevKitIssueBodyText -Body ([string]$Issue.body)
    $content.Children.Add($bodyText) | Out-Null

    $commentCount = 0
    if ($Issue.comments) { $commentCount = @($Issue.comments).Count }
    $meta = New-Object Windows.Controls.TextBlock
    $meta.Style = Get-WidgetResource 'WidgetExpanderSub'
    $meta.Margin = '0,8,0,0'
    $suffix = if ($commentCount -ne 1) { 's' } else { '' }
    $metaParts = @("$commentCount comment$suffix")
    $when = Format-DevKitRelativeTime -Iso ([string]$Issue.updatedAt)
    if ($when) { $metaParts += "updated $when" }
    $meta.Text = ($metaParts -join '  |  ')
    $content.Children.Add($meta) | Out-Null

    $openBtn = New-Object Windows.Controls.Button
    $openBtn.Style = Get-WidgetResource 'GhostButton'
    $openBtn.FontSize = 10.5
    $openBtn.Content = 'Open on GitHub'
    $openBtn.HorizontalAlignment = 'Left'
    $openBtn.Margin = '0,8,0,0'
    $issueUrl = [string]$Issue.url
    $openBtn.Add_Click({ Open-DevKitExternalUrl -Url $issueUrl }.GetNewClosure())
    $content.Children.Add($openBtn) | Out-Null

    $expander.Content = $content
    $Panel.Children.Add($expander) | Out-Null
}

function Update-DevKitWidgetPullRequests {
    # Full render: one clickable Add-DevKitPrRow card per open PR, or the
    # CLI-not-found/not-a-repo/error/empty-state message in the same tone
    # Render-DevKitMcpPanel/Start-DevKitAgentCli already use for other CLIs.
    param($Result)
    $script:LastPrResult = $Result
    $ui.PullRequestsPanel.Children.Clear()
    $count = 0
    if (-not $Result) {
        Set-DevKitGitPanelMessage -Panel $ui.PullRequestsPanel -Message 'No data.'
    } elseif ($Result.ErrorMessage) {
        Set-DevKitGitPanelMessage -Panel $ui.PullRequestsPanel -Message ([string]$Result.ErrorMessage)
    } elseif (-not $Result.CliInstalled) {
        Set-DevKitGitPanelMessage -Panel $ui.PullRequestsPanel -Message 'GitHub CLI (gh) not found on PATH - install it to see pull requests here.'
    } elseif (-not $Result.IsRepo) {
        Set-DevKitGitPanelMessage -Panel $ui.PullRequestsPanel -Message 'Not a GitHub repository.'
    } else {
        $prs = @($Result.PullRequests)
        $count = $prs.Count
        if ($count -eq 0) {
            Set-DevKitGitPanelMessage -Panel $ui.PullRequestsPanel -Message 'No open pull requests.'
        } else {
            foreach ($pr in $prs) { Add-DevKitPrRow -Panel $ui.PullRequestsPanel -Pr $pr }
        }
    }
    if ($Result -and $Result.Truncated) {
        $ui.PrCountBadgeText.Text = "$count+"
        $ui.PrCountBadge.ToolTip = "Showing the first $count open pull requests - there are more than that open."
    } else {
        $ui.PrCountBadgeText.Text = [string]$count
        $ui.PrCountBadge.ToolTip = $null
    }
}

function Update-DevKitWidgetIssues {
    # Full render: one Add-DevKitIssueAccordion per open issue, or the
    # CLI-not-found/not-a-repo/error/empty-state message in the same tone
    # Render-DevKitMcpPanel/Start-DevKitAgentCli already use for other CLIs.
    param($Result)
    $script:LastIssuesResult = $Result
    $ui.IssuesPanel.Children.Clear()
    $count = 0
    if (-not $Result) {
        Set-DevKitGitPanelMessage -Panel $ui.IssuesPanel -Message 'No data.'
    } elseif ($Result.ErrorMessage) {
        Set-DevKitGitPanelMessage -Panel $ui.IssuesPanel -Message ([string]$Result.ErrorMessage)
    } elseif (-not $Result.CliInstalled) {
        Set-DevKitGitPanelMessage -Panel $ui.IssuesPanel -Message 'GitHub CLI (gh) not found on PATH - install it to see issues here.'
    } elseif (-not $Result.IsRepo) {
        Set-DevKitGitPanelMessage -Panel $ui.IssuesPanel -Message 'Not a GitHub repository.'
    } else {
        $issues = @($Result.Issues)
        $count = $issues.Count
        if ($count -eq 0) {
            Set-DevKitGitPanelMessage -Panel $ui.IssuesPanel -Message 'No open issues.'
        } else {
            foreach ($issue in $issues) { Add-DevKitIssueAccordion -Panel $ui.IssuesPanel -Issue $issue }
        }
    }
    if ($Result -and $Result.Truncated) {
        $ui.IssuesCountBadgeText.Text = "$count+"
        $ui.IssuesCountBadge.ToolTip = "Showing the first $count open issues - there are more than that open."
    } else {
        $ui.IssuesCountBadgeText.Text = [string]$count
        $ui.IssuesCountBadge.ToolTip = $null
    }
}

$ui.TabCommits.Add_Checked({ Set-DevKitGitActiveTab -Tab 'Commits' })
$ui.TabPullRequests.Add_Checked({ Set-DevKitGitActiveTab -Tab 'PullRequests' })
$ui.TabIssues.Add_Checked({ Set-DevKitGitActiveTab -Tab 'Issues' })

function Update-DevKitWidgetGitFlyout {
    # Pure render of an already-collected overview, on the dispatcher thread.
    param($Overview)
    $script:GitOverview = $Overview
    Update-DevKitGitUncommittedList -Overview $Overview
    $ui.GitFlyoutTitle.Text = if ($script:ActiveProjectName) { [string]$script:ActiveProjectName } else { 'Project' }
    $repoButtons = @($ui.BtnGitFetch, $ui.BtnGitPull, $ui.BtnGitPush, $ui.BtnGitOpenHub, $ui.BtnGitActions)

    $showText = {
        param([string]$Message, [string]$BrushKey)
        $ui.GitGraphCanvas.Children.Clear()
        $ui.GitGraphCanvas.Visibility = 'Collapsed'
        $ui.GitGraphText.Text = $Message
        $ui.GitGraphText.Foreground = Get-WidgetResource $BrushKey
        $ui.GitGraphText.Visibility = 'Visible'
    }

    if (-not $Overview -or -not $Overview.IsRepo) {
        $ui.GitFlyoutBranch.Text = ''
        $ui.GitBadgeText.Visibility = 'Collapsed'
        & $showText $(if ($Overview -and $Overview.Error) { [string]$Overview.Error } else { 'Not a git repository.' }) 'BrushTextDim'
        foreach ($b in $repoButtons) { $b.IsEnabled = $false }
        return
    }
    $branchText = [string]$Overview.Branch
    if ($null -ne $Overview.Ahead -and $null -ne $Overview.Behind -and ($Overview.Ahead -gt 0 -or $Overview.Behind -gt 0)) {
        $branchText += "  (ahead $($Overview.Ahead), behind $($Overview.Behind))"
    }
    $ui.GitFlyoutBranch.Text = $branchText
    foreach ($b in $repoButtons) { $b.IsEnabled = $true }

    # Ambient badge under the project combo: branch + work-in-progress counts.
    $badgeParts = @([string]$Overview.Branch)
    if ($Overview.DirtyCount -gt 0) { $badgeParts += "$($Overview.DirtyCount) uncommitted" }
    if ($null -ne $Overview.Ahead -and $Overview.Ahead -gt 0) { $badgeParts += "ahead $($Overview.Ahead)" }
    if ($null -ne $Overview.Behind -and $Overview.Behind -gt 0) { $badgeParts += "behind $($Overview.Behind)" }
    if ($Overview.StashCount -gt 0) { $badgeParts += "$($Overview.StashCount) stashed" }
    $ui.GitBadgeText.Text = $badgeParts -join '  |  '
    $ui.GitBadgeText.Visibility = 'Visible'

    if (-not $Overview.Graph -or @($Overview.Graph.Nodes).Count -eq 0) {
        # GraphSkipped = the job deliberately didn't collect the log (badge
        # refresh while closed); the flyout's own open-refresh is on its way.
        & $showText $(if ($Overview.GraphSkipped -and $script:GitFlyoutOpen) { 'Loading commit graph...' } else { 'No commits yet.' }) 'BrushTextDim'
        return
    }
    if (-not $script:GitFlyoutOpen) { return }   # badge-only refresh: leave the canvas alone
    try {
        Render-DevKitGitGraph -Graph $Overview.Graph
        $ui.GitGraphText.Visibility = 'Collapsed'
        $ui.GitGraphCanvas.Visibility = 'Visible'
    } catch {
        & $showText "Could not draw the graph: $_" 'BrushAccentEmber'
    }
}

function Open-DevKitRepoPage {
    # "Open on GitHub" / "Actions": convert the cached origin URL with
    # Open-Repo's converter and hand it to the default browser.
    param([switch]$ActionsTab)
    $remote = $null
    if ($script:GitOverview -and $script:GitOverview.RemoteUrl) { $remote = [string]$script:GitOverview.RemoteUrl }
    if (-not $remote) {
        $ui.GitFlyoutStatus.Text = 'No origin remote configured.'
        return
    }
    $url = ConvertTo-DevKitBrowsableUrl -RemoteUrl $remote
    if (-not $url) {
        $ui.GitFlyoutStatus.Text = "Remote URL is not browsable: $remote"
        return
    }
    if ($ActionsTab) { $url += '/actions' }
    try {
        Start-Process $url
        $ui.GitFlyoutStatus.Text = "Opened $url"
    } catch {
        $ui.GitFlyoutStatus.Text = "Could not open the browser: $_"
    }
}

function Start-DevKitGitAction {
    param([string]$Kind, [string]$Verb)
    if ($script:WorkBusy) {
        $ui.GitFlyoutStatus.Text = 'Busy - try again in a moment.'
        $ui.GitFlyoutStatus.Foreground = Get-WidgetResource 'BrushTextDim'
        return
    }
    $ui.GitFlyoutStatus.Text = "$Verb..."
    $ui.GitFlyoutStatus.Foreground = Get-WidgetResource 'BrushTextDim'
    if (-not (Start-DevKitWorkJob -Kind $Kind -ProjectPath $script:ActiveProjectPath)) {
        $ui.GitFlyoutStatus.Text = "Could not start git $Verb - try again."
    } else {
        # Re-enabled by Update-DevKitWidgetGitFlyout when the action's fresh
        # overview arrives; prevents double-firing while git is working.
        foreach ($b in @($ui.BtnGitFetch, $ui.BtnGitPull, $ui.BtnGitPush, $ui.BtnGitOpenHub, $ui.BtnGitActions)) { $b.IsEnabled = $false }
    }
}

$ui.BtnGitTab.Add_Click({ Set-DevKitGitFlyout -Open (-not $script:GitFlyoutOpen) })
$ui.BtnGitClose.Add_Click({ Set-DevKitGitFlyout -Open $false })

# ==================== NOTES FLYOUT (PER-PROJECT STICKY NOTES) ====================
# Little sticky notes/prompts scoped to the active project, behind the NOTES
# pull-tab under GIT. Persistence is Get/Save-DevKitProjectNotes
# (DevKit-WidgetCore.ps1, notes.json in %LOCALAPPDATA%); this section owns
# rendering, the debounced autosave, and the slide-out panel - which reuses
# the Git flyout's animation/geometry machinery wholesale (shared
# Start-DevKitFlyoutSlide, shared anim token, shared grip handlers routed by
# -Kind), since the two panels are mutually exclusive by design.

$script:ActiveNotes = @()            # live note objects bound to the rendered cards
$script:NotesProjectPath = $null     # the project the CURRENT cards belong to
$script:NotesDirty = $false

# Sticky-tint rotation for new notes: color KEYS are persisted (not hex), so
# a future palette tweak restyles existing notes for free.
$script:NoteColorOrder = @('amber', 'blue', 'green', 'violet')
$script:NoteColorMap = @{
    amber  = @{ Bg = '#2A2416'; Border = '#4E4122'; Accent = '#E5C07B' }
    blue   = @{ Bg = '#16222E'; Border = '#28425E'; Accent = '#4FA3FF' }
    green  = @{ Bg = '#18251A'; Border = '#2C4A30'; Accent = '#98C379' }
    violet = @{ Bg = '#241A2B'; Border = '#44305C'; Accent = '#C678DD' }
}

# Debounced autosave: every keystroke re-arms this; the file is written at
# most ~once per pause in typing. Add/remove/close/project-switch flush
# immediately instead of waiting on it.
$script:NotesSaveTimer = New-Object Windows.Threading.DispatcherTimer
$script:NotesSaveTimer.Interval = [TimeSpan]::FromMilliseconds(800)
$script:NotesSaveTimer.Add_Tick({
    $script:NotesSaveTimer.Stop()
    Save-DevKitWidgetNotesFlush
})

function Request-DevKitNotesAutosave {
    # The per-card TextChanged closures call THIS instead of touching
    # $script: state directly: a .GetNewClosure() block is bound to a fresh
    # dynamic module, where $script:X resolves to that module's own (empty)
    # script scope - $script:NotesSaveTimer would read $null and .Stop()
    # would throw right inside the TextChanged event (surfacing as a bare
    # "System error" to UIA callers). Function CALLS resolve normally from
    # closures, and inside a normal function $script: is the real script
    # scope again.
    $script:NotesDirty = $true
    $script:NotesSaveTimer.Stop()
    $script:NotesSaveTimer.Start()
}

function Save-DevKitWidgetNotesFlush {
    # Persists the CURRENT cards to the project they belong to
    # ($script:NotesProjectPath - deliberately NOT ActiveProjectPath, so a
    # flush that happens as part of a project switch still lands on the
    # project the user actually typed into).
    if (-not $script:NotesDirty -or -not $script:NotesProjectPath) { return }
    try {
        Save-DevKitProjectNotes -ProjectPath $script:NotesProjectPath -Notes @($script:ActiveNotes)
        $script:NotesDirty = $false
    } catch { }
}

function Open-DevKitWidgetNotesProject {
    # Flush whatever project the cards currently belong to, then load and
    # render the active project's notes.
    Save-DevKitWidgetNotesFlush
    $script:NotesProjectPath = $script:ActiveProjectPath
    $script:ActiveNotes = @(Get-DevKitProjectNotes -ProjectPath $script:NotesProjectPath)
    $script:NotesDirty = $false
    $ui.NotesFlyoutSub.Text = [string]$script:ActiveProjectName
    Update-DevKitWidgetNotesPanel
}

function Update-DevKitWidgetNotesPanel {
    $ui.NotesPanel.Children.Clear()
    if (@($script:ActiveNotes).Count -eq 0) {
        $empty = New-Object Windows.Controls.TextBlock
        $empty.Text = "No notes yet - '+ Note' adds a sticky for this project."
        $empty.FontSize = 10.5
        $empty.Foreground = Get-WidgetResource 'BrushTextDim'
        $empty.TextWrapping = 'Wrap'
        $empty.Margin = '2,6,2,0'
        $ui.NotesPanel.Children.Add($empty) | Out-Null
        return
    }
    foreach ($note in $script:ActiveNotes) {
        $ui.NotesPanel.Children.Add((New-DevKitNoteCard -Note $note)) | Out-Null
    }
}

function New-DevKitNoteCard {
    # One sticky-note card: tinted rounded Border, colored accent bar on the
    # left, a borderless multiline TextBox, and a footer with the last-edited
    # time and a two-step delete ('x' -> 'sure?' for 3s -> gone) - lighter
    # than a modal popup but still a guard against a stray click.
    # Returns the card Border; its .Tag is the TextBox (used to focus a
    # freshly added note).
    param([Parameter(Mandatory = $true)]$Note)

    $palette = $script:NoteColorMap[[string]$Note.Color]
    if (-not $palette) { $palette = $script:NoteColorMap['amber'] }

    $card = New-Object Windows.Controls.Border
    $card.CornerRadius = 6
    $card.BorderThickness = 1
    $card.BorderBrush = Get-DevKitGitBrush $palette.Border
    $card.Background = Get-DevKitGitBrush $palette.Bg
    $card.Margin = '0,0,0,8'

    $grid = New-Object Windows.Controls.Grid
    $c0 = New-Object Windows.Controls.ColumnDefinition; $c0.Width = 'Auto'
    $c1 = New-Object Windows.Controls.ColumnDefinition
    $grid.ColumnDefinitions.Add($c0); $grid.ColumnDefinitions.Add($c1)

    $accent = New-Object Windows.Controls.Border
    $accent.Width = 3
    $accent.Background = Get-DevKitGitBrush $palette.Accent
    $accent.CornerRadius = New-Object Windows.CornerRadius(5, 0, 0, 5)
    $grid.Children.Add($accent) | Out-Null

    $body = New-Object Windows.Controls.Grid
    [Windows.Controls.Grid]::SetColumn($body, 1)
    $r0 = New-Object Windows.Controls.RowDefinition; $r0.Height = 'Auto'
    $r1 = New-Object Windows.Controls.RowDefinition; $r1.Height = 'Auto'
    $body.RowDefinitions.Add($r0); $body.RowDefinitions.Add($r1)

    $tb = New-Object Windows.Controls.TextBox
    $tb.Text = [string]$Note.Text
    $tb.Background = [Windows.Media.Brushes]::Transparent
    $tb.BorderThickness = 0
    $tb.Foreground = Get-WidgetResource 'BrushTextBright'
    $tb.CaretBrush = Get-DevKitGitBrush $palette.Accent
    $tb.FontSize = 11.5
    $tb.TextWrapping = 'Wrap'
    $tb.AcceptsReturn = $true
    $tb.MinHeight = 44
    $tb.Padding = '8,6,8,2'
    # Stable UIA ids (suffixed with the note id) so E2E checks can find a
    # specific card's editor/delete without guessing among look-alikes.
    [System.Windows.Automation.AutomationProperties]::SetAutomationId($tb, "NoteText_$($Note.Id)")
    $body.Children.Add($tb) | Out-Null

    $footer = New-Object Windows.Controls.Grid
    [Windows.Controls.Grid]::SetRow($footer, 1)
    $edited = New-Object Windows.Controls.TextBlock
    $edited.FontSize = 9
    $edited.Foreground = Get-WidgetResource 'BrushTextDim'
    $edited.VerticalAlignment = 'Center'
    $edited.Margin = '11,0,0,5'
    $edited.Text = if ([string]::IsNullOrWhiteSpace([string]$Note.UpdatedAt)) { '' } else { "edited $(Format-DevKitRelativeTime -Iso ([string]$Note.UpdatedAt))" }
    $footer.Children.Add($edited) | Out-Null

    $del = New-Object Windows.Controls.Button
    $del.Style = Get-WidgetResource 'ChromeButton'
    $del.FontFamily = New-Object Windows.Media.FontFamily('Segoe MDL2 Assets')
    $del.FontSize = 9
    $del.Content = [char]0xE106
    $del.MinWidth = 24
    $del.Height = 18
    $del.HorizontalAlignment = 'Right'
    $del.Margin = '0,0,4,4'
    $del.ToolTip = 'Delete this note'
    $del.Tag = $false   # $true while in the 'sure?' confirm window
    [System.Windows.Automation.AutomationProperties]::SetAutomationId($del, "NoteDelete_$($Note.Id)")
    $footer.Children.Add($del) | Out-Null
    $body.Children.Add($footer) | Out-Null

    $grid.Children.Add($body) | Out-Null
    $card.Child = $grid
    $card.Tag = $tb

    $tb.Add_TextChanged({
        $Note.Text = $tb.Text
        $Note.UpdatedAt = [DateTime]::UtcNow.ToString('o')
        $edited.Text = 'edited just now'
        Request-DevKitNotesAutosave   # NOT inline $script: sets - see the function's comment
    }.GetNewClosure())

    # Two-step delete. The revert timer is per-card; the token-free Tag flag
    # is enough state because a re-render rebuilds the card (and its state)
    # from scratch anyway.
    $revert = New-Object Windows.Threading.DispatcherTimer
    $revert.Interval = [TimeSpan]::FromSeconds(3)
    $revert.Add_Tick({
        $revert.Stop()
        $del.Tag = $false
        $del.FontFamily = New-Object Windows.Media.FontFamily('Segoe MDL2 Assets')
        $del.FontSize = 9
        $del.Content = [char]0xE106
        $del.ClearValue([Windows.Controls.Control]::ForegroundProperty)
    }.GetNewClosure())
    $del.Add_Click({
        if (-not $del.Tag) {
            $del.Tag = $true
            $del.FontFamily = New-Object Windows.Media.FontFamily('Segoe UI')
            $del.FontSize = 9
            $del.Content = 'sure?'
            $del.Foreground = Get-WidgetResource 'BrushDangerRed'
            $revert.Start()
            return
        }
        $revert.Stop()
        Remove-DevKitWidgetNote -Note $Note
    }.GetNewClosure())

    return $card
}

function Add-DevKitWidgetNote {
    if (-not $script:NotesProjectPath) { return }
    $color = $script:NoteColorOrder[@($script:ActiveNotes).Count % $script:NoteColorOrder.Count]
    $note = [PSCustomObject]@{
        Id        = [guid]::NewGuid().ToString('N')
        Text      = ''
        Color     = $color
        UpdatedAt = [DateTime]::UtcNow.ToString('o')
    }
    # Newest on top, like a fresh sticky slapped over the pile.
    $script:ActiveNotes = @($note) + @($script:ActiveNotes)
    $script:NotesDirty = $true
    Save-DevKitWidgetNotesFlush
    Update-DevKitWidgetNotesPanel
    try { $ui.NotesPanel.Children[0].Tag.Focus() | Out-Null } catch { }
}

function Remove-DevKitWidgetNote {
    param([Parameter(Mandatory = $true)]$Note)
    $script:ActiveNotes = @($script:ActiveNotes | Where-Object { $_.Id -ne $Note.Id })
    $script:NotesDirty = $true
    Save-DevKitWidgetNotesFlush
    Update-DevKitWidgetNotesPanel
}

function Set-DevKitNotesFlyout {
    param([bool]$Open, [switch]$Instant)
    if ($Open -eq $script:NotesFlyoutOpen) { return }
    if ($Open -and -not $script:ActiveProjectPath) { return }
    # Only one flyout at a time - mirror of the guard in Set-DevKitGitFlyout
    # (see the comment there for why the close is -Instant).
    if ($Open -and $script:GitFlyoutOpen) { Set-DevKitGitFlyout -Open $false -Instant }

    # Same lockstep window/flyout animation contract as Set-DevKitGitFlyout
    # (see the long comment there). The two flyouts share one anim token:
    # only one slide is ever in flight, and a toggle of either must stale-out
    # the other's pending Completed handlers.
    $script:GitFlyoutAnimToken++
    $token = $script:GitFlyoutAnimToken
    $curFlyoutWidth = $ui.NotesFlyout.Width
    $curLeft = $window.Left
    $contentWidth = $window.Width - $curFlyoutWidth
    $targetFlyoutWidth = if ($Open) { $script:NotesFlyoutWidth } else { 0 }
    $targetWindowWidth = $contentWidth + $targetFlyoutWidth

    if ($Instant) {
        $window.BeginAnimation([Windows.Window]::WidthProperty, $null)
        $window.BeginAnimation([Windows.Window]::LeftProperty, $null)
        $ui.NotesFlyout.BeginAnimation([Windows.Controls.Border]::WidthProperty, $null)
        $ui.NotesFlyout.Width = $targetFlyoutWidth
        $window.Width = $targetWindowWidth
        if ($script:DockMode -eq 'Right') {
            $contentLeft = $curLeft + $curFlyoutWidth
            $window.Left = if ($Open) { $contentLeft - $targetFlyoutWidth } else { $contentLeft }
        }
        $script:NotesFlyoutOpen = $Open
        if ($Open) {
            $ui.NotesFlyoutInner.Width = $script:NotesFlyoutWidth
            $ui.BtnNotesTab.Foreground = Get-DevKitGitBrush '#E5C07B'
            Open-DevKitWidgetNotesProject
        } else {
            $ui.BtnNotesTab.Foreground = Get-WidgetResource 'BrushTextMuted'
            Save-DevKitWidgetNotesFlush
        }
        return
    }

    if ($Open) {
        $script:NotesFlyoutOpen = $true
        $ui.NotesFlyoutInner.Width = $script:NotesFlyoutWidth
        Start-DevKitFlyoutSlide -Target $ui.NotesFlyout -Property ([Windows.Controls.Border]::WidthProperty) -To $targetFlyoutWidth -Opening $true -Token $token
        Start-DevKitFlyoutSlide -Target $window -Property ([Windows.Window]::WidthProperty) -To $targetWindowWidth -Opening $true -Token $token
        if ($script:DockMode -eq 'Right') {
            # Right-docked: pinned right edge, window grows leftward - same
            # Left+Width lockstep as the Git flyout's open path.
            $contentLeft = $window.Left + $curFlyoutWidth
            $targetLeft = $contentLeft - $targetFlyoutWidth
            Start-DevKitFlyoutSlide -Target $window -Property ([Windows.Window]::LeftProperty) -To $targetLeft -Opening $true -Token $token
        }
        $ui.BtnNotesTab.Foreground = Get-DevKitGitBrush '#E5C07B'
        Open-DevKitWidgetNotesProject
    } else {
        $script:NotesFlyoutOpen = $false
        Start-DevKitFlyoutSlide -Target $ui.NotesFlyout -Property ([Windows.Controls.Border]::WidthProperty) -To 0 -Opening $false -Token $token
        Start-DevKitFlyoutSlide -Target $window -Property ([Windows.Window]::WidthProperty) -To $targetWindowWidth -Opening $false -Token $token
        if ($script:DockMode -eq 'Right') {
            $contentLeft = $window.Left + $curFlyoutWidth
            Start-DevKitFlyoutSlide -Target $window -Property ([Windows.Window]::LeftProperty) -To $contentLeft -Opening $false -Token $token
        }
        $ui.BtnNotesTab.Foreground = Get-WidgetResource 'BrushTextMuted'
        Save-DevKitWidgetNotesFlush
    }
}

$ui.BtnNotesTab.Add_Click({ Set-DevKitNotesFlyout -Open (-not $script:NotesFlyoutOpen) })
$ui.BtnNotesClose.Add_Click({ Set-DevKitNotesFlyout -Open $false })
$ui.BtnNoteAdd.Add_Click({ Add-DevKitWidgetNote })
$ui.BtnGitFetch.Add_Click({ Start-DevKitGitAction -Kind 'GitFetch' -Verb 'fetch' })
$ui.BtnGitPull.Add_Click({ Start-DevKitGitAction -Kind 'GitPull' -Verb 'pull' })
$ui.BtnGitPush.Add_Click({ Start-DevKitGitAction -Kind 'GitPush' -Verb 'push' })
$ui.BtnGitOpenHub.Add_Click({ Open-DevKitRepoPage })
$ui.BtnGitActions.Add_Click({ Open-DevKitRepoPage -ActionsTab })
$ui.BtnGitCleanup.Add_Click({
    $args = @{}
    if ($script:ActiveProjectPath) { $args['Path'] = $script:ActiveProjectPath }
    Start-DevKitWidgetTool -RelativeScript 'git\Git-Cleanup.ps1' -Arguments $args -Title 'Git Cleanup'
})

# ==================== QUICK ACTIONS ====================

function Start-DevKitWidgetTool {
    param(
        [Parameter(Mandatory = $true)][string]$RelativeScript,
        [hashtable]$Arguments = @{},
        [Parameter(Mandatory = $true)][string]$Title
    )
    $launch = Get-DevKitTerminalCommand -ScriptPath (Join-Path $ScriptDir $RelativeScript) `
        -Arguments $Arguments -WorkingDirectory $ScriptDir -Title $Title
    if (-not $launch.FilePath) {
        $script:TrayIcon.BalloonTipTitle = 'Cannot launch tool'
        $script:TrayIcon.BalloonTipText = 'No PowerShell executable was found on PATH.'
        $script:TrayIcon.ShowBalloonTip(3000)
        return
    }
    try {
        Start-Process -FilePath $launch.FilePath -ArgumentList $launch.Arguments -WorkingDirectory $launch.WorkingDirectory
    } catch {
        $script:TrayIcon.BalloonTipTitle = 'Cannot launch tool'
        $script:TrayIcon.BalloonTipText = "$_"
        $script:TrayIcon.ShowBalloonTip(3000)
    }
}

$ui.BtnClearNpmCache.Add_Click({
    $args = @{}
    if ($script:ActiveProjectPath) { $args['Path'] = $script:ActiveProjectPath }
    Start-DevKitWidgetTool -RelativeScript 'node\Clear-NpmCache.ps1' -Arguments $args -Title 'Clear NPM Cache'
})
$ui.BtnKillNode.Add_Click({ Start-DevKitWidgetTool -RelativeScript 'ports\Kill-AllNode.ps1' -Title 'Kill All Node Processes' })
$ui.BtnDoctor.Add_Click({ Start-DevKitWidgetTool -RelativeScript 'diagnostics\DevKit-Doctor.ps1' -Title 'DevKit Doctor' })
$ui.BtnOpenDevKit.Add_Click({ Start-Process (Join-Path $ScriptDir 'DevKit-GUI.bat') -WorkingDirectory $ScriptDir })

# Project-scoped launchers (enabled/disabled by Sync-DevKitWidgetGitState).
$ui.BtnOpenEditor.Add_Click({
    if (-not $script:ActiveProjectPath) { return }
    Start-DevKitWidgetTool -RelativeScript 'workflow\Code-Here.ps1' -Arguments @{ Path = $script:ActiveProjectPath } -Title 'Open in Editor'
})
$ui.BtnOpenExplorer.Add_Click({
    if (-not $script:ActiveProjectPath) { return }
    try { Start-Process 'explorer.exe' -ArgumentList "`"$($script:ActiveProjectPath)`"" } catch { }
})
$ui.BtnOpenTerminal.Add_Click({
    if (-not $script:ActiveProjectPath) { return }
    try {
        if (Get-Command wt -ErrorAction SilentlyContinue) {
            Start-Process 'wt.exe' -ArgumentList "-d $(Format-DevKitShellArgument -Value $script:ActiveProjectPath)" -WorkingDirectory $script:ActiveProjectPath
        } else {
            $shell = Get-DevKitWindowsExecutable -Name 'pwsh'
            $shellPath = if ($shell) { $shell.Source } else { Join-Path $PSHOME 'powershell.exe' }
            Start-Process $shellPath -WorkingDirectory $script:ActiveProjectPath
        }
    } catch { }
})
$ui.BtnRunScript.Add_Click({
    if (-not $script:ActiveProjectPath) { return }
    Start-DevKitWidgetTool -RelativeScript 'node\Start-PackageScript.ps1' -Arguments @{ Path = $script:ActiveProjectPath } -Title 'Run Package Script'
})
$ui.BtnEnvFix.Add_Click({
    if (-not $script:ActiveProjectPath) { return }
    Start-DevKitWidgetTool -RelativeScript 'workflow\Copy-EnvTemplate.ps1' -Arguments @{ Path = $script:ActiveProjectPath } -Title 'Copy .env Template'
})
$ui.BtnEnvSilence.Add_Click({
    if (-not $script:ActiveProjectPath) { return }
    Set-DevKitEnvDriftSilenced -Path $script:ActiveProjectPath -Silenced $true
    Update-DevKitWidgetEnvDrift
})
$ui.BtnEnvDriftUnsilence.Add_Click({
    Clear-DevKitEnvDriftSilenced
    Update-DevKitWidgetEnvDrift
})

# Small styled input dialog for Kill Port (variable dialogs stay in code,
# same rule as the main GUI).
function Show-DevKitWidgetInput {
    param([Parameter(Mandatory = $true)][string]$Title, [Parameter(Mandatory = $true)][string]$Label)
    $dlg = New-Object Windows.Window
    $dlg.Title = $Title
    $dlg.Width = 300
    $dlg.SizeToContent = [Windows.SizeToContent]::Height
    $dlg.WindowStyle = [Windows.WindowStyle]::None
    $dlg.AllowsTransparency = $true
    $dlg.Background = [Windows.Media.Brushes]::Transparent
    $dlg.WindowStartupLocation = [Windows.WindowStartupLocation]::CenterOwner
    $dlg.Owner = $window
    $dlg.Icon = $window.Icon
    $dlg.FontFamily = $window.FontFamily
    $dlg.Topmost = $true

    $root = New-Object Windows.Controls.Border
    $root.Style = Get-WidgetResource 'RootWindow'
    $stack = New-Object Windows.Controls.StackPanel
    $stack.Margin = '16,14,16,14'

    $titleText = New-Object Windows.Controls.TextBlock
    $titleText.Style = Get-WidgetResource 'GroupTitle'
    $titleText.Text = $Title
    $stack.Children.Add($titleText) | Out-Null

    $labelText = New-Object Windows.Controls.TextBlock
    $labelText.Style = Get-WidgetResource 'WidgetRowText'
    $labelText.Text = $Label
    $labelText.Margin = '0,8,0,0'
    $stack.Children.Add($labelText) | Out-Null

    $box = New-Object Windows.Controls.TextBox
    $box.Style = Get-WidgetResource 'InputBox'
    $box.Height = 30
    $box.Margin = '0,6,0,0'
    $stack.Children.Add($box) | Out-Null

    $errorText = New-Object Windows.Controls.TextBlock
    $errorText.Style = Get-WidgetResource 'WidgetRowText'
    $errorText.Foreground = Get-WidgetResource 'BrushAccentEmber'
    $errorText.Margin = '0,6,0,0'
    $stack.Children.Add($errorText) | Out-Null

    $row = New-Object Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'
    $row.HorizontalAlignment = 'Right'
    $row.Margin = '0,10,0,0'
    $cancelBtn = New-Object Windows.Controls.Button
    $cancelBtn.Style = Get-WidgetResource 'GhostButton'
    $cancelBtn.Content = 'Cancel'
    $cancelBtn.Margin = '0,0,8,0'
    $okBtn = New-Object Windows.Controls.Button
    $okBtn.Style = Get-WidgetResource 'PrimaryButton'
    $okBtn.Content = 'OK'
    $row.Children.Add($cancelBtn) | Out-Null
    $row.Children.Add($okBtn) | Out-Null
    $stack.Children.Add($row) | Out-Null
    $root.Child = $stack
    $dlg.Content = $root

    $dlg.Tag = $null
    $cancelBtn.Add_Click({ $dlg.Close() })
    $submit = {
        $raw = $box.Text
        $parsed = 0
        if ([string]::IsNullOrWhiteSpace($raw) -or -not [int]::TryParse($raw.Trim(), [ref]$parsed) -or $parsed -lt 1 -or $parsed -gt 65535) {
            $errorText.Text = 'Enter a valid port number (1-65535).'
            return
        }
        $dlg.Tag = $parsed
        $dlg.Close()
    }
    $okBtn.Add_Click($submit)
    $box.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { & $submit } })
    $dlg.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Escape') { $s.Close() } })
    $dlg.Add_ContentRendered({ $box.Focus() | Out-Null })
    $dlg.ShowDialog() | Out-Null
    return $dlg.Tag
}

# Yes/No variant of the dialog chrome above, for the in-widget junk clean.
function Show-DevKitWidgetConfirm {
    param([Parameter(Mandatory = $true)][string]$Title, [Parameter(Mandatory = $true)][string]$Message)
    $dlg = New-Object Windows.Window
    $dlg.Title = $Title
    $dlg.Width = 320
    $dlg.SizeToContent = [Windows.SizeToContent]::Height
    $dlg.WindowStyle = [Windows.WindowStyle]::None
    $dlg.AllowsTransparency = $true
    $dlg.Background = [Windows.Media.Brushes]::Transparent
    $dlg.WindowStartupLocation = [Windows.WindowStartupLocation]::CenterOwner
    $dlg.Owner = $window
    $dlg.Icon = $window.Icon
    $dlg.FontFamily = $window.FontFamily
    $dlg.Topmost = $true

    $root = New-Object Windows.Controls.Border
    $root.Style = Get-WidgetResource 'RootWindow'
    $stack = New-Object Windows.Controls.StackPanel
    $stack.Margin = '16,14,16,14'

    $titleText = New-Object Windows.Controls.TextBlock
    $titleText.Style = Get-WidgetResource 'GroupTitle'
    $titleText.Text = $Title
    $stack.Children.Add($titleText) | Out-Null

    $messageText = New-Object Windows.Controls.TextBlock
    $messageText.Style = Get-WidgetResource 'WidgetRowText'
    $messageText.Text = $Message
    $messageText.TextWrapping = 'Wrap'
    $messageText.Margin = '0,8,0,0'
    $stack.Children.Add($messageText) | Out-Null

    $row = New-Object Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'
    $row.HorizontalAlignment = 'Right'
    $row.Margin = '0,12,0,0'
    $noBtn = New-Object Windows.Controls.Button
    $noBtn.Style = Get-WidgetResource 'GhostButton'
    $noBtn.Content = 'No'
    $noBtn.Margin = '0,0,8,0'
    $yesBtn = New-Object Windows.Controls.Button
    $yesBtn.Style = Get-WidgetResource 'DangerButton'
    $yesBtn.Content = 'Yes'
    $row.Children.Add($noBtn) | Out-Null
    $row.Children.Add($yesBtn) | Out-Null
    $stack.Children.Add($row) | Out-Null
    $root.Child = $stack
    $dlg.Content = $root

    $dlg.Tag = $false
    $noBtn.Add_Click({ $dlg.Close() })
    $yesBtn.Add_Click({ $dlg.Tag = $true; $dlg.Close() })
    $dlg.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Escape') { $s.Close() } })
    # Focus 'No' so Enter can't accidentally confirm a destructive action.
    $dlg.Add_ContentRendered({ $noBtn.Focus() | Out-Null })
    $dlg.ShowDialog() | Out-Null
    return [bool]$dlg.Tag
}

# ==================== AGENT MANAGE DIALOGS ====================
# The per-agent "Manage..." flyout: a short honest status summary (from the
# last MCP report) plus buttons that launch the real CLIs / DevKit agent
# tools. "Connect" means exactly what it says below - for Claude, 'claude mcp
# list' performs the real health check; for Kimi the config is re-read.

function Show-DevKitWidgetBalloon {
    param([string]$Title, [string]$Text)
    $script:TrayIcon.BalloonTipTitle = $Title
    $script:TrayIcon.BalloonTipText = $Text
    $script:TrayIcon.ShowBalloonTip(3000)
}

function Get-DevKitAgentSummary {
    param([Parameter(Mandatory = $true)][ValidateSet('Claude', 'Kimi')][string]$Agent)
    $report = $script:LastMcpReport
    if (-not $report -or -not $report.Contains($Agent)) {
        return 'Status not loaded yet - use Connect / Re-check below.'
    }
    $t = $report[$Agent]
    $lines = @()
    if ($t.CliInstalled) {
        $lines += if ($t.Version) { "CLI: installed ($($t.Version))" } else { 'CLI: installed' }
    } else {
        $lines += 'CLI: not installed (not found on PATH)'
    }
    $servers = @($t.Servers)
    if ($t.ErrorMessage) {
        $lines += "Status: $($t.ErrorMessage)"
    } elseif ($servers.Count -eq 0) {
        $lines += 'MCP servers: none configured.'
    } else {
        foreach ($scope in @('User', 'Project')) {
            $scoped = @($servers | Where-Object { $_.Scope -eq $scope })
            if ($scoped.Count -eq 0) { continue }
            $counts = [ordered]@{}
            foreach ($s in $scoped) { $counts[$s.Status] = [int]$counts[$s.Status] + 1 }
            $parts = foreach ($k in $counts.Keys) { "$($counts[$k]) $($k.ToLower())" }
            $lines += "$($scope.ToLower()) servers: $($parts -join ', ')"
        }
    }
    return ($lines -join "`n")
}

function Start-DevKitAgentCli {
    # Launch the agent CLI itself (interactive TUI) in a real terminal window
    # so the user can sign in / authenticate there.
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][string]$DisplayName)
    $exe = Get-DevKitWindowsExecutable -Name $Name
    if (-not $exe) {
        Show-DevKitWidgetBalloon -Title $DisplayName -Text "$DisplayName CLI not found on PATH - install it first."
        return
    }
    try {
        # cmd /k keeps the console open after the CLI exits so any output
        # (e.g. a printed auth URL) stays readable.
        $inner = "cmd /k `"`"$($exe.Source)`"`""
        if (Get-Command wt -ErrorAction SilentlyContinue) {
            Start-Process 'wt.exe' -ArgumentList "--title $(Format-DevKitShellArgument -Value $DisplayName) -d $(Format-DevKitShellArgument -Value $ScriptDir) $inner" -WorkingDirectory $ScriptDir
        } else {
            Start-Process 'cmd.exe' -ArgumentList "/k `"`"$($exe.Source)`"`"" -WorkingDirectory $ScriptDir
        }
    } catch {
        Show-DevKitWidgetBalloon -Title $DisplayName -Text "Could not launch the CLI: $_"
    }
}

function Open-DevKitKimiConfig {
    # Kimi Code has no headless MCP management command - its documented
    # config file is the management surface.
    $kimiHome = if ($env:KIMI_CODE_HOME) { $env:KIMI_CODE_HOME } else { Join-Path $HOME '.kimi-code' }
    $configPath = Join-Path $kimiHome 'mcp.json'
    try {
        if (Test-Path -LiteralPath $configPath) {
            Start-Process -FilePath $configPath          # default editor/association
        } elseif (Test-Path -LiteralPath $kimiHome) {
            Start-Process -FilePath $kimiHome            # containing folder
        } else {
            Show-DevKitWidgetBalloon -Title 'Kimi Code' -Text 'No Kimi Code config found yet (no ~/.kimi-code folder).'
        }
    } catch {
        Show-DevKitWidgetBalloon -Title 'Kimi Code' -Text "Could not open the config: $_"
    }
}

function Show-DevKitAgentManage {
    param([Parameter(Mandatory = $true)][ValidateSet('Claude', 'Kimi')][string]$Agent)
    $displayName = if ($Agent -eq 'Claude') { 'Claude Code' } else { 'Kimi Code' }
    $cliName = if ($Agent -eq 'Claude') { 'claude' } else { 'kimi' }

    $dlg = New-Object Windows.Window
    $dlg.Title = "$displayName - Manage"
    $dlg.Width = 340
    $dlg.SizeToContent = [Windows.SizeToContent]::Height
    $dlg.WindowStyle = [Windows.WindowStyle]::None
    $dlg.AllowsTransparency = $true
    $dlg.Background = [Windows.Media.Brushes]::Transparent
    $dlg.WindowStartupLocation = [Windows.WindowStartupLocation]::CenterOwner
    $dlg.Owner = $window
    $dlg.Icon = $window.Icon
    $dlg.FontFamily = $window.FontFamily
    $dlg.Topmost = $true

    $root = New-Object Windows.Controls.Border
    $root.Style = Get-WidgetResource 'RootWindow'
    $stack = New-Object Windows.Controls.StackPanel
    $stack.Margin = '16,14,16,14'

    $titleText = New-Object Windows.Controls.TextBlock
    $titleText.Style = Get-WidgetResource 'GroupTitle'
    $titleText.Text = "$displayName - Manage"
    $stack.Children.Add($titleText) | Out-Null

    $summary = New-Object Windows.Controls.TextBlock
    $summary.Style = Get-WidgetResource 'WidgetRowText'
    $summary.Text = Get-DevKitAgentSummary -Agent $Agent
    $summary.TextWrapping = 'Wrap'
    $summary.Margin = '0,8,0,0'
    $stack.Children.Add($summary) | Out-Null

    $addBtn = {
        param([string]$Text, [string]$ToolTip = '')
        $b = New-Object Windows.Controls.Button
        $b.Style = Get-WidgetResource 'GhostButton'
        $b.Content = $Text
        $b.FontSize = 11.5
        $b.Margin = '0,8,0,0'
        if ($ToolTip) { $b.ToolTip = $ToolTip }
        $stack.Children.Add($b) | Out-Null
        return $b
    }

    $btnRecheck = & $addBtn 'Connect / Re-check' 'For Claude this runs the real claude mcp list health check; for Kimi the mcp.json config is re-read.'
    $btnSignIn = & $addBtn 'Sign In / Authenticate...' "Launch the $cliName CLI in a terminal window so you can log in."
    $btnScan = & $addBtn 'Scan & Fix MCP Gaps' 'Cross-check configured servers against the DevKit catalog and offer to fill gaps (runs in a terminal).'
    $btnCatalog = & $addBtn 'Add Server from Catalog...' 'Browse the curated MCP server catalog and add one (runs in a terminal).'
    $btnExtra = $null
    if ($Agent -eq 'Claude') {
        $btnExtra = & $addBtn 'Disconnect a Server...' 'Remove a configured MCP server (runs in a terminal).'
    } else {
        $btnExtra = & $addBtn 'Open Config File' 'Open mcp.json in the default editor (or its folder, if no file exists yet).'
    }
    $btnClose = & $addBtn 'Close'
    $root.Child = $stack
    $dlg.Content = $root

    $btnRecheck.Add_Click({ Start-DevKitMcpRefresh; $dlg.Close() })
    $btnSignIn.Add_Click({ Start-DevKitAgentCli -Name $cliName -DisplayName $displayName; $dlg.Close() })
    $btnScan.Add_Click({ Start-DevKitWidgetTool -RelativeScript 'agents\Scan-McpServers.ps1' -Title 'Scan MCP Servers'; $dlg.Close() })
    $btnCatalog.Add_Click({ Start-DevKitWidgetTool -RelativeScript 'agents\Add-McpServerFromCatalog.ps1' -Title 'Add MCP Server from Catalog'; $dlg.Close() })
    if ($Agent -eq 'Claude') {
        $btnExtra.Add_Click({ Start-DevKitWidgetTool -RelativeScript 'agents\Remove-McpServer.ps1' -Title 'Remove MCP Server'; $dlg.Close() })
    } else {
        $btnExtra.Add_Click({ Open-DevKitKimiConfig; $dlg.Close() })
    }
    $btnClose.Add_Click({ $dlg.Close() })
    $dlg.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Escape') { $s.Close() } })
    $dlg.ShowDialog() | Out-Null
}

$ui.BtnClaudeManage.Add_Click({ Show-DevKitAgentManage -Agent 'Claude' })
$ui.BtnKimiManage.Add_Click({ Show-DevKitAgentManage -Agent 'Kimi' })

$ui.BtnKillPort.Add_Click({
    $port = Show-DevKitWidgetInput -Title 'Kill Port' -Label 'Port number to free up (asks before killing):'
    if ($null -ne $port) {
        Start-DevKitWidgetTool -RelativeScript 'ports\Kill-Port.ps1' -Arguments @{ Port = $port } -Title "Kill Port $port"
    }
})

# ==================== SHELL RESILIENCE ====================
# If explorer.exe restarts, every tray icon is dropped until its app
# re-registers; the shell announces this with the "TaskbarCreated" broadcast.
# Hook the widget window's message pump and re-add our icon when it fires.
# The same hook also forces the window's real taskbar/Alt+Tab icon: WPF's
# Window.Icon property alone is not reliable enough for a script-hosted
# window (no compiled .exe carries the icon as a resource) - Windows can
# still show the hosting powershell.exe/pwsh.exe icon instead. Sending
# WM_SETICON with real HICON handles once the HWND exists is the fix; the
# icon objects are kept alive in $script: scope for the window's lifetime
# since WM_SETICON does not take ownership of them.
$window.Add_SourceInitialized({
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class DevKitShellMessages {
    [DllImport("user32.dll")] public static extern uint RegisterWindowMessage(string lpString);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
}
'@
        $script:TaskbarCreatedMsg = [DevKitShellMessages]::RegisterWindowMessage('TaskbarCreated')
        $src = [Windows.Interop.HwndSource]::FromVisual($window)
        if ($src) {
            $src.AddHook([Windows.Interop.HwndSourceHook]{
                param($hwnd, $msg, $wParam, $lParam, [ref]$handled)
                if ($msg -eq $script:TaskbarCreatedMsg) {
                    $script:TrayIcon.Visible = $false
                    $script:TrayIcon.Visible = $true
                }
                return [IntPtr]::Zero
            })

            $iconPath = Join-Path $GuiDir "Assets\logo.ico"
            $script:TaskbarIconSmall = New-Object System.Drawing.Icon($iconPath, 16, 16)
            $script:TaskbarIconBig = New-Object System.Drawing.Icon($iconPath, 32, 32)
            [DevKitShellMessages]::SendMessage($src.Handle, 0x0080, [IntPtr]0, $script:TaskbarIconSmall.Handle) | Out-Null   # ICON_SMALL
            [DevKitShellMessages]::SendMessage($src.Handle, 0x0080, [IntPtr]1, $script:TaskbarIconBig.Handle) | Out-Null     # ICON_BIG
        }
    } catch { }
})

# A second widget launch (e.g. clicking the gauge in DevKit again) signals
# this event; poll it on the dispatcher and surface the window.
$script:SummonTimer = New-Object Windows.Threading.DispatcherTimer
$script:SummonTimer.Interval = [TimeSpan]::FromMilliseconds(750)
$script:SummonTimer.Add_Tick({
    if ($script:SummonEvent -and $script:SummonEvent.WaitOne(0)) {
        Show-DevKitWidget
    }
})
$script:SummonTimer.Start()

# ==================== TIMERS ====================

function Update-DevKitWidgetFooter {
    $time = (Get-Date).ToString('HH:mm')
    $mcpText = if ($script:McpBusy) { 'MCP checking...' } elseif ($script:McpLastDone) { "MCP $($script:McpLastDone.ToString('HH:mm'))" } else { 'MCP pending' }
    $text = "updated $time  |  $mcpText"
    if ($ui.LastUpdatedText.Text -ne $text) { $ui.LastUpdatedText.Text = $text }   # don't invalidate layout for an unchanged footer
}

$script:FastTimer = New-Object Windows.Threading.DispatcherTimer
$script:FastTimer.Interval = [TimeSpan]::FromSeconds(2)
$script:FastTimer.Add_Tick({
    try { Update-DevKitMetricsAsyncPoll } catch { }
    # Completion-time gate, not a fixed cadence: the collectors take ~1.5-3s,
    # so starting the next job a beat after the last one FINISHED keeps the
    # metrics runspace from running at 100% duty with zero idle.
    if (-not $script:MetricsBusy -and ((Get-Date) - $script:MetricsLastDone).TotalSeconds -ge 2) { Start-DevKitMetricsRefresh }
    try { Update-DevKitMcpAsyncPoll } catch { }
    try { Update-DevKitWorkAsyncPoll } catch { }
    Update-DevKitWidgetFooter
})

$script:SlowTimer = New-Object Windows.Threading.DispatcherTimer
$script:SlowTimer.Interval = [TimeSpan]::FromSeconds(5)
$script:SlowTimer.Add_Tick({
    # Reap any Metrics/MCP/Work shells abandoned by a Reset-* timeout once
    # their BeginStop actually finishes, so a wedged native call doesn't leak
    # the runspace's OS thread/handles for the life of the widget.
    try { Update-DevKitAbandonedRunspaceCleanup } catch { }
    # Reflect project changes made in the GUI/TUI (they share projects.json).
    try {
        $projectsFile = Get-DevKitProjectsFile
        if (Test-Path $projectsFile) {
            $stamp = (Get-Item $projectsFile).LastWriteTimeUtc
            if ($null -ne $script:ProjectsFileStamp -and $stamp -ne $script:ProjectsFileStamp) {
                Update-DevKitWidgetProjects
                Start-DevKitMcpRefresh
            }
            $script:ProjectsFileStamp = $stamp
        }
    } catch { }
    # Periodic health re-check, cheap because it no-ops while one is running.
    # Gated on McpLastAttempt (set after every finished attempt, success or
    # timeout) rather than McpEverLoaded/McpLastDone, which only ever
    # reflect a success - that used to leave the widget stuck forever if
    # the very first refresh timed out. 10 minutes is plenty for a badge:
    # the full check costs ~10s of CLI spawns, and user-driven freshness
    # (expander open at 30s staleness, manual Refresh, project switch)
    # covers anyone actively looking at it.
    if (-not $script:McpBusy -and ((Get-Date) - $script:McpLastAttempt).TotalSeconds -gt 600) {
        Start-DevKitMcpRefresh
    }
    # Junk rescan every 5 minutes; a no-op while the work runspace is busy.
    if (-not $script:WorkBusy -and ((Get-Date) - $script:JunkLastScan).TotalSeconds -gt 300) {
        Start-DevKitJunkScan
    }
    # Ambient git badge refresh every 2 minutes while a project is active.
    if (-not $script:WorkBusy -and $script:ActiveProjectPath -and ((Get-Date) - $script:GitBadgeLastRefresh).TotalSeconds -gt 120) {
        $script:GitBadgeLastRefresh = Get-Date
        Start-DevKitGitRefresh
    }
    # .env drift check once a minute - Update-DevKitWidgetEnvDrift only
    # kicks off the background work job (see Get-DevKitEnvDrift's Test-Path/
    # Get-Content calls, which can block for the OS SMB timeout on a project
    # living on an unreachable network share), so this is safe to call
    # unconditionally on WorkBusy same as the git badge refresh above.
    if ($script:ActiveProjectPath -and ((Get-Date) - $script:EnvDriftLastCheck).TotalSeconds -gt 60) {
        $script:EnvDriftLastCheck = Get-Date
        try { Update-DevKitWidgetEnvDrift } catch { }
    }
})

# ==================== START ====================

Update-DevKitWidgetProjects
# Main's fixed width is set from the one constant so the XAML's design-time
# value can never silently disagree with the geometry math.
if ($ui.MainColumn) { $ui.MainColumn.Width = [Windows.GridLength]::new($script:WidgetContentWidth) }
$window.Width = $script:WidgetChromeWidth + $script:WidgetContentWidth
Set-DevKitWidgetDock -Mode (Get-DevKitWidgetDockSetting)
Start-DevKitMetricsRefresh
Start-DevKitJunkScan
Update-DevKitWidgetFooter
$script:FastTimer.Start()
$script:SlowTimer.Start()
Start-DevKitMcpRefresh

# A WPF Application (created at the top, holding the theme resources) owns the
# message loop: Hide() (every hide-to-tray path - the X button, minimize, the
# hide button, a tray click) ends a ShowDialog() modal loop the instant it
# first runs, which silently killed the whole process on the very first hide.
# OnExplicitShutdown keeps the loop (and the tray icon) alive with no window
# visible in between.

# First-run hint so the user notices the tray presence right away.
$window.Add_ContentRendered({
    if (-not $script:TrayHintShown) {
        $script:TrayHintShown = $true
        $script:TrayIcon.BalloonTipTitle = 'Northstar DevKit Companion'
        $script:TrayIcon.BalloonTipText = 'Running in the system tray (check the ^ overflow near the clock). Closing or minimizing me just hides me there - left-click the tray icon to bring me back, right-click for options.'
        $script:TrayIcon.ShowBalloonTip(5000)
    }
})

$window.Show()
if ($script:App) { $script:App.Run() | Out-Null } else { [Windows.Application]::Current.Run() | Out-Null }

# Run() only returns after a real Exit (Application.Shutdown()) - Closing
# cancels every other path, and Hide() no longer ends the loop.
try { Save-DevKitWidgetNotesFlush } catch { }   # any keystrokes still inside the autosave debounce window
$script:FastTimer.Stop()
$script:SlowTimer.Stop()
$script:SummonTimer.Stop()
$script:GaugeAnimTimer.Stop()
$script:TrayIcon.Visible = $false
try { $script:TrayIcon.Dispose() } catch { }
try { if ($script:McpShell) { $script:McpShell.Dispose() } } catch { }
try { $script:McpRunspace.Close() } catch { }
try { if ($script:MetricsShell) { $script:MetricsShell.Dispose() } } catch { }
try { $script:MetricsRunspace.Close() } catch { }
try { if ($script:WorkShell) { $script:WorkShell.Dispose() } } catch { }
try { $script:WorkRunspace.Close() } catch { }
try { if ($script:InstanceMutex) { $script:InstanceMutex.ReleaseMutex(); $script:InstanceMutex.Dispose() } } catch { }
try { if ($script:SummonEvent) { $script:SummonEvent.Dispose() } } catch { }
