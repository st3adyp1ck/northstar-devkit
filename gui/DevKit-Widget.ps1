#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Northstar DevKit Companion - persistent desktop widget
.DESCRIPTION
    A small always-available WPF widget that lives on the desktop and in the
    system tray, independent of the main DevKit GUI process: launch it once
    from DevKit and it keeps running after DevKit closes.

    Shows live CPU/memory/GPU load with best-effort temperatures (plus a
    reboot-pending / long-uptime hint) - each gauge is clickable and toggles a
    slide-out per-process management panel (top processes by that metric,
    SAFE TO CLOSE / CAUTION / LEAVE ALONE badges, confirmed per-row kills,
    and for memory a working-set Free Memory button), refreshed every 3s from
    the work runspace while open - a System Junk dial (reclaimable
    temp/Windows-Update/Recycle-Bin bytes, with a safe in-widget clean behind
    a confirm that reports a per-category breakdown, and a Details... dialog
    showing what the last scan found - no terminal window anywhere in the flow)
    next to a Disk Free dial per
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
    config file). Side pull-tabs (on whichever edge faces into the screen)
    slide out per-project panels - Git (branch + ahead/behind, a
    drawn commit graph (bright lanes, gradient S-curve links, branch/tag
    pills), fetch/pull/push, open-on-GitHub / Actions links, and the Git
    Cleanup tool), Notes, Files, On-Deck - which form a single-flyout
    carousel together with the gauge management panel (opening one closes the
    others). A bottom-anchored TERMINAL tab slides out a REAL hosted terminal
    (Windows Terminal when available, a classic pwsh/powershell console
    window otherwise - its chrome stripped, owned by the widget window and
    glued over the panel, so interactive CLIs like kimi/claude work exactly
    as in a normal terminal) that opens in the active project's folder and
    is INDEPENDENT of the carousel: it coexists with any open flyout,
    sitting on the outside. Each panel's own width is grip-resizable too.

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
        # The log alone made startup deaths invisible (headless launch, no
        # console): say out loud that the widget failed and where the detail is.
        try {
            Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
            [System.Windows.MessageBox]::Show(
                "The Northstar DevKit companion widget failed to start:`n`n$($_.Exception.Message)`n`nDetails: $logPath",
                'Northstar DevKit Companion',
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Error) | Out-Null
        } catch { }
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
# Synchronize+Modify on BOTH PowerShell editions (on pwsh 7 the
# System.Threading.AccessControl assembly has to be loaded first). An
# explicit ACL is belt-and-braces against cross-integrity/edge cases: an
# instance created at a different elevation level (e.g. an accidental "Run
# as administrator" launch) can otherwise leave normal launches unable to
# take the mutex or summon the owner, turning every later launch into a
# silent no-op. With the ACL, summoning works across the elevation boundary
# (UIPI blocks window messages, not kernel-object signaling); when even
# opening the mutex is denied, the blocked branch below says so out loud
# instead of just vanishing.
$script:InstanceMutexName = 'Local\NorthstarDevKitCompanion'
$script:SummonEventName = 'Local\NorthstarDevKitCompanionSummon'
$authUsersSid = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::AuthenticatedUserSid, $null)
$script:InstanceMutex = $null
$mutexCreated = $false
$mutexBlocked = $false
$script:CanAclKernelObjects = $true
if ($PSVersionTable.PSEdition -ne 'Desktop') {
    try {
        Add-Type -AssemblyName System.Threading.AccessControl -ErrorAction Stop
    } catch {
        $script:CanAclKernelObjects = $false
    }
}
try {
    if ($script:CanAclKernelObjects) {
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
    if ($script:CanAclKernelObjects) {
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
$ToolsDir = Join-Path $ScriptDir "tools"        # categories + shared lib (4.0 layout)

. (Join-Path $ToolsDir "lib\DevKit-Common.ps1")
. (Join-Path $ToolsDir "lib\DevKit-McpList.ps1")
. (Join-Path $GuiDir "DevKit-GuiCore.ps1")
. (Join-Path $GuiDir "DevKit-WidgetCore.ps1")
# Built-in vector icon set (Files flyout tree + git graph pills). UI-side
# only - the background runspaces (New-DevKitWidgetRunspace) load just
# lib + WidgetCore, never this.
. (Join-Path $GuiDir "DevKit-WidgetIcons.ps1")
# Open-Repo is dot-source-safe by design (its InvocationName guard stops
# before the interactive body) - this brings in ConvertTo-DevKitBrowsableUrl
# for the GitHub flyout's "Open on GitHub" / "Actions" buttons.
. (Join-Path $ToolsDir "workflow\Open-Repo.ps1")

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
    'RootBorder', 'TitleBar', 'WidgetLogoImage', 'BtnPin', 'BtnHide', 'BtnDevKitHub', 'BtnGitTab', 'ProjectCombo',
    'GitBadgeText', 'EnvDriftRow', 'EnvDriftText', 'BtnEnvFix', 'BtnEnvSilence', 'BtnEnvDriftUnsilence',
    'CpuGaugeTrack', 'CpuGaugeArc', 'CpuGaugeValue', 'CpuGaugeSub', 'CpuGaugeStack',
    'MemGaugeTrack', 'MemGaugeArc', 'MemGaugeValue', 'MemGaugeSub', 'MemGaugeStack',
    'GpuGaugeTrack', 'GpuGaugeArc', 'GpuGaugeValue', 'GpuGaugeSub', 'GpuGaugeStack', 'MetricsHint',
    'GaugesCard', 'JunkCard',
    'JunkGaugeTrack', 'JunkGaugeArc', 'JunkGaugeValue', 'JunkGaugeSub',
    'DiskGaugesPanel',
    'BtnJunkClean', 'BtnJunkDetails', 'JunkStatusText',
    'NodeCountBadge', 'NodeCountBadgeText', 'NodeListPanel', 'OtherPortsText', 'ReservedPortsText',
    'QuickActionsExpander',
    'BtnClearNpmCache', 'BtnKillNode', 'BtnKillPort', 'BtnDoctor', 'BtnOpenDevKit',
    'BtnOpenEditor', 'BtnOpenExplorer', 'BtnOpenTerminal', 'BtnRunScript',
    'AgentsExpander', 'ClaudeExpander', 'ClaudeCliBadge', 'ClaudeCliBadgeText', 'ClaudeMcpPanel', 'BtnClaudeManage',
    'KimiExpander', 'KimiCliBadge', 'KimiCliBadgeText', 'KimiMcpPanel', 'BtnKimiManage', 'McpLoadingBar',
    'SettingsExpander', 'ChkStartup', 'ChkTopmost', 'CmbDefaultView',
    'MainColumn',
    'GitFlyout', 'GitFlyoutInner', 'GitFlyoutGrip', 'GitFlyoutTitle', 'GitFlyoutBranch', 'GitGraphText', 'GitGraphCanvas', 'GitFlyoutStatus',
    'UncommittedExpander', 'UncommittedCountBadgeText', 'UncommittedFilesPanel', 'CommitGraphExpander', 'CommitGraphCountBadgeText',
    'TabCommits', 'TabPullRequests', 'TabIssues', 'PrCountBadge', 'PrCountBadgeText', 'IssuesCountBadge', 'IssuesCountBadgeText',
    'GitTabCommitsView', 'GitTabPullRequestsView', 'GitTabIssuesView', 'PullRequestsPanel', 'IssuesPanel', 'GitFlyoutFooter',
    'BtnGitFetch', 'BtnGitPull', 'BtnGitPush', 'BtnGitOpenHub', 'BtnGitActions', 'BtnGitCleanup', 'BtnGitClose',
    'SideTabStack', 'SideTabCanvas', 'SideTabDivider', 'TabGroupFilesGit', 'TabGroupNotesOnDeck', 'TabGroupSepBig',
    'BtnNotesTab', 'NotesFlyout', 'NotesFlyoutInner', 'NotesFlyoutGrip',
    'NotesFlyoutTitle', 'NotesFlyoutSub', 'BtnNoteAdd', 'BtnNotesClose', 'NotesPanel',
    'BtnFilesTab', 'FilesFlyout', 'FilesFlyoutInner', 'FilesFlyoutGrip',
    'FilesFlyoutTitle', 'FilesFlyoutSub', 'BtnFilesClose', 'BtnFileNew', 'BtnFolderNew',
    'BtnFilesRefresh', 'BtnFilesCollapse', 'FilesTree', 'FilesEmptyText', 'FilesFlyoutStatus',
    'BtnOnDeckTab', 'OnDeckFlyout', 'OnDeckFlyoutInner', 'OnDeckFlyoutGrip',
    'OnDeckFlyoutTitle', 'OnDeckFlyoutSub', 'BtnOnDeckClose', 'OnDeckNewText', 'BtnOnDeckAdd', 'OnDeckPanel',
    'BtnTerminalTab', 'TermFlyout', 'TermFlyoutInner', 'TermFlyoutGrip',
    'TermFlyoutTitle', 'TermFlyoutSub', 'TermNoProjectNote', 'TermHostSurface', 'TermHostStatus',
    'BtnTermRestart', 'BtnTermClose', 'TermFlyoutStatus',
    'ProcFlyout', 'ProcFlyoutInner', 'ProcFlyoutGrip',
    'ProcFlyoutTitle', 'ProcFlyoutSub', 'BtnProcClose', 'ProcSummaryText', 'BtnProcFreeMem',
    'ProcAdapterPanel', 'ProcRowsPanel', 'ProcFlyoutStatus',
    'LastUpdatedText', 'BtnRefreshMcp', 'ContentScroll', 'BodyContent'
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
# Everything in the window that is neither Main nor a side panel: RootBorder's
# 8px margin and 1px border on each side, plus the 26px side-tab strip column
# (24px of tabs + the 2px SideTabDivider hairline; the terminal and carousel
# panels are 0-width until opened and are counted separately via
# Get-DevKitWidgetPanelExtra).
$script:WidgetChromeWidth = 44

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

function Get-DevKitWidgetPanelExtra {
    # The TARGET layout's extra width beyond chrome+Main: whichever CAROUSEL
    # flyout is open (Git/Notes/Files/OnDeck/gauge panel - flag-driven, so it
    # reads correctly even mid-slide), plus the independent terminal panel's
    # width when open. Both Update-DevKitWidgetGeometry and every
    # Set-DevKit*Flyout slide derive window.Width from these flags/width
    # variables (the target layout), never from live animated values - which
    # is what lets a terminal slide and a carousel slide safely overlap: when
    # the newer BeginAnimation supersedes the older one on window.Width/Left,
    # both were chasing flag-derived totals, so whichever wins converges to
    # the same correct end state.
    $extra = 0
    if ($script:GitFlyoutOpen) { $extra += $script:FlyoutWidth }
    elseif ($script:NotesFlyoutOpen) { $extra += $script:NotesFlyoutWidth }
    elseif ($script:FilesFlyoutOpen) { $extra += $script:FilesFlyoutWidth }
    elseif ($script:OnDeckFlyoutOpen) { $extra += $script:OnDeckFlyoutWidth }
    elseif ($script:ProcPanelKind) { $extra += $script:ProcFlyoutWidth }
    if ($script:TermFlyoutOpen) { $extra += $script:TermFlyoutWidth }
    return $extra
}

function Update-DevKitWidgetGeometry {
    # The one place window width/position is decided, computed ABSOLUTELY from
    # the fixed parts rather than by nudging the current values: width is
    # exactly chrome + Main + (open side panels), and the docked edge is
    # re-pinned from the work area. Deriving it fresh every time is what keeps
    # many small drag steps from accumulating rounding drift.
    $window.Width = $script:WidgetChromeWidth + $script:WidgetContentWidth + (Get-DevKitWidgetPanelExtra)
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
    # Persist the CONTENT width - every side panel's extra pixels (carousel
    # flyout + terminal, see Get-DevKitWidgetPanelExtra) are temporary and
    # never saved.
    try {
        $settings = Get-DevKitSettings
        $settings.preferences.widgetWidth = [int][math]::Round($window.Width - (Get-DevKitWidgetPanelExtra))
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
        # A dock-side change while a flyout is open would otherwise
        # have to reflow a live-open panel across sides mid-flight - simplest
        # correct behavior is to close it first; it reopens fresh on the
        # newly-correct side next time. -Instant snaps the close straight to
        # its final values instead of animating: the plain Left/Width
        # reassignments just below (computed for the NEW dock side) would
        # otherwise be fought/overridden by an in-flight close animation still
        # chasing the OLD side's geometry (WPF animations win over local value
        # sets while running), and its Completed handler would later pin
        # window.Left back to that stale OLD-side target. This covers the
        # independent terminal panel too - it reflows sides no better than
        # the carousel panels do.
        if ($script:GitFlyoutOpen) { Set-DevKitGitFlyout -Open $false -Instant }
        if ($script:NotesFlyoutOpen) { Set-DevKitNotesFlyout -Open $false -Instant }
        if ($script:FilesFlyoutOpen) { Set-DevKitFilesFlyout -Open $false -Instant }
        if ($script:OnDeckFlyoutOpen) { Set-DevKitOnDeckFlyout -Open $false -Instant }
        if ($script:ProcPanelKind) { Set-DevKitProcPanel -Open $false -Instant }
        if ($script:TermFlyoutOpen) { Set-DevKitTerminalFlyout -Open $false -Instant }
        $wa = [System.Windows.SystemParameters]::WorkArea
        $script:DockMode = $Mode
        # Full height in every mode - modes only set horizontal placement.
        $window.Top = $wa.Top
        $window.Height = $wa.Height
        Update-DevKitWidgetGeometry
        # The pull-tabs and panels always sit on whichever side FACES INTO
        # the screen - i.e. mirrors the dock side: docked right -> west slots
        # (terminal column 0, tab strip column 1, carousel flyout column 2);
        # docked left -> east slots (carousel column 4, tab strip column 5,
        # terminal column 6). The terminal column is FARTHER OUT than the tab
        # strip so the terminal panel always sits on the outside when it
        # coexists with a carousel flyout: docked right, west-to-east order is
        # [terminal][tabs][flyout][widget]. Each panel owns (or shares, for
        # the mutually-exclusive carousel) a dedicated column, so nothing ever
        # overlaps Main. A panel's grip sits on its OUTER edge - the side
        # facing the tab/window edge, away from Main - so it flips opposite
        # to the tab's own facing side: west panels' outer edge is their LEFT
        # (grip HorizontalAlignment="Left"), east panels' outer edge is their
        # RIGHT (grip HorizontalAlignment="Right").
        if ($Mode -eq 'Right') {
            [Windows.Controls.Grid]::SetColumn($ui.GitFlyout, 2)
            [Windows.Controls.Grid]::SetColumn($ui.NotesFlyout, 2)
            [Windows.Controls.Grid]::SetColumn($ui.FilesFlyout, 2)
            [Windows.Controls.Grid]::SetColumn($ui.OnDeckFlyout, 2)
            [Windows.Controls.Grid]::SetColumn($ui.ProcFlyout, 2)
            [Windows.Controls.Grid]::SetColumn($ui.TermFlyout, 0)
            [Windows.Controls.Grid]::SetColumn($ui.SideTabStack, 1)
            $ui.SideTabStack.HorizontalAlignment = 'Left'
            # The tab buttons hug the window's outer edge; the divider
            # hairline sits on the strip's widget-facing (inner) edge.
            $ui.SideTabCanvas.HorizontalAlignment = 'Left'
            $ui.SideTabDivider.HorizontalAlignment = 'Right'
            $ui.BtnGitTab.Style = Get-WidgetResource 'GitTabButtonWest'
            $ui.BtnNotesTab.Style = Get-WidgetResource 'NotesTabButtonWest'
            $ui.BtnFilesTab.Style = Get-WidgetResource 'FilesTabButtonWest'
            $ui.BtnOnDeckTab.Style = Get-WidgetResource 'OnDeckTabButtonWest'
            $ui.BtnTerminalTab.Style = Get-WidgetResource 'TerminalTabButtonWest'
            $ui.GitFlyoutGrip.HorizontalAlignment = 'Left'
            $ui.NotesFlyoutGrip.HorizontalAlignment = 'Left'
            $ui.FilesFlyoutGrip.HorizontalAlignment = 'Left'
            $ui.OnDeckFlyoutGrip.HorizontalAlignment = 'Left'
            $ui.ProcFlyoutGrip.HorizontalAlignment = 'Left'
            $ui.TermFlyoutGrip.HorizontalAlignment = 'Left'
            # Panel content hugs the INNER edge (the boundary against Main) so
            # the open/close reveal unfurls outward from the widget instead of
            # the content sliding sideways under the clip.
            $ui.GitFlyoutInner.HorizontalAlignment = 'Right'
            $ui.NotesFlyoutInner.HorizontalAlignment = 'Right'
            $ui.FilesFlyoutInner.HorizontalAlignment = 'Right'
            $ui.OnDeckFlyoutInner.HorizontalAlignment = 'Right'
            $ui.ProcFlyoutInner.HorizontalAlignment = 'Right'
            $ui.TermFlyoutInner.HorizontalAlignment = 'Right'
        } else {
            [Windows.Controls.Grid]::SetColumn($ui.GitFlyout, 4)
            [Windows.Controls.Grid]::SetColumn($ui.NotesFlyout, 4)
            [Windows.Controls.Grid]::SetColumn($ui.FilesFlyout, 4)
            [Windows.Controls.Grid]::SetColumn($ui.OnDeckFlyout, 4)
            [Windows.Controls.Grid]::SetColumn($ui.ProcFlyout, 4)
            [Windows.Controls.Grid]::SetColumn($ui.TermFlyout, 6)
            [Windows.Controls.Grid]::SetColumn($ui.SideTabStack, 5)
            $ui.SideTabStack.HorizontalAlignment = 'Right'
            $ui.SideTabCanvas.HorizontalAlignment = 'Right'
            $ui.SideTabDivider.HorizontalAlignment = 'Left'
            $ui.BtnGitTab.Style = Get-WidgetResource 'GitTabButtonEast'
            $ui.BtnNotesTab.Style = Get-WidgetResource 'NotesTabButtonEast'
            $ui.BtnFilesTab.Style = Get-WidgetResource 'FilesTabButtonEast'
            $ui.BtnOnDeckTab.Style = Get-WidgetResource 'OnDeckTabButtonEast'
            $ui.BtnTerminalTab.Style = Get-WidgetResource 'TerminalTabButtonEast'
            $ui.GitFlyoutGrip.HorizontalAlignment = 'Right'
            $ui.NotesFlyoutGrip.HorizontalAlignment = 'Right'
            $ui.FilesFlyoutGrip.HorizontalAlignment = 'Right'
            $ui.OnDeckFlyoutGrip.HorizontalAlignment = 'Right'
            $ui.ProcFlyoutGrip.HorizontalAlignment = 'Right'
            $ui.TermFlyoutGrip.HorizontalAlignment = 'Right'
            $ui.GitFlyoutInner.HorizontalAlignment = 'Left'
            $ui.NotesFlyoutInner.HorizontalAlignment = 'Left'
            $ui.FilesFlyoutInner.HorizontalAlignment = 'Left'
            $ui.OnDeckFlyoutInner.HorizontalAlignment = 'Left'
            $ui.ProcFlyoutInner.HorizontalAlignment = 'Left'
            $ui.TermFlyoutInner.HorizontalAlignment = 'Left'
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

# ==================== SIDE-TAB SECTION ANCHORING ====================
# The strip's tabs sit ACROSS FROM the body section they belong to instead of
# in one centered stack: FILES+GIT centered on the gauges card (GaugesCard),
# NOTES+ON DECK centered on the SYSTEM JUNK/drives card (JunkCard), TERMINAL
# centered on the QUICK ACTIONS expander. The groups live on a full-height
# Canvas (SideTabCanvas) and are positioned purely by Canvas.Top.
# POSITIONS ARE FIXED, NOT SCROLL-TRACKED: each anchor's center is read at
# SCROLL-OFFSET ZERO (Get-DevKitAnchorCenterY adds ContentScroll's live
# VerticalOffset back onto the rendered position), so scrolling the body
# under the strip never moves a tab - there is deliberately NO
# ScrollChanged hook. Positions are recomputed only on structural changes
# (cheap, event-driven; NO timers): window SizeChanged (the dock-mode
# height set), BodyContent LayoutUpdated (content layout changes that shift
# the un-scrolled layout - expander opens, node-list rebuilds, badge rows
# appearing), and ContentRendered once at startup.
# Clamp invariants (Resolve-DevKitSideTabTops): the stack order FILES+GIT ->
# NOTES+ON DECK -> TERMINAL is fixed, consecutive groups always keep at
# least their gap pixels (never overlap), nothing goes above/below the
# strip, and on a very short window the gaps give first, then the stack
# compresses against the top/bottom - tabs may end up touching but are
# never pushed off-screen. The math is side-independent (only Y), so both
# dock sides behave identically.

function Get-DevKitAnchorCenterY {
    # The anchor element's vertical center in the strip canvas's coordinate
    # space AS IF THE BODY WERE SCROLLED TO THE TOP: TransformToVisual (not
    # TransformToAncestor - the anchor lives in the Main column, the canvas
    # in the tab column, neither is an ancestor of the other) returns the
    # live RENDERED position, which scrolling shifted up by the scroll
    # offset, so ContentScroll's VerticalOffset is added back on. That makes
    # the reading scroll-independent: the same layout yields the same center
    # no matter where the user has scrolled, which is exactly what keeps the
    # tabs fixed while the body scrolls underneath them. $null when the
    # visual tree can't transform yet (early load) so the caller can fall
    # back to a stack-order estimate.
    param([Windows.FrameworkElement]$Anchor, [Windows.FrameworkElement]$RelativeTo)
    try {
        if ($null -eq $Anchor -or $null -eq $RelativeTo -or -not $Anchor.IsLoaded) { return $null }
        $origin = $Anchor.TransformToVisual($RelativeTo).Transform([Windows.Point]::new(0, 0))
        $offset = 0.0
        if ($ui.ContentScroll) { $offset = $ui.ContentScroll.VerticalOffset }
        return $origin.Y + $offset + ($Anchor.ActualHeight / 2.0)
    } catch { return $null }
}

function Resolve-DevKitSideTabTops {
    # Pure clamp: given desired tops and the strip height, return the three
    # clamped Canvas.Top values in fixed stack order with non-overlap gaps.
    # Forward pass pins each group between the previous group's bottom and
    # the strip bottom; the backward pass then pulls the stack back up if the
    # forward clamp overflowed the bottom (near-full strips). Callers shrink
    # the gaps to fit BEFORE calling, so g1+g2+heights never exceeds H here.
    param(
        [double]$H,
        [double]$D1, [double]$H1,
        [double]$D2, [double]$H2,
        [double]$D3, [double]$H3,
        [double]$Gap12, [double]$Gap23
    )
    $t1 = [math]::Min([math]::Max($D1, 0), [math]::Max(0, $H - $H1))
    $t2min = $t1 + $H1 + $Gap12
    $t2 = [math]::Min([math]::Max($D2, $t2min), [math]::Max($t2min, $H - $H2))
    $t3min = $t2 + $H2 + $Gap23
    $t3 = [math]::Min([math]::Max($D3, $t3min), [math]::Max($t3min, $H - $H3))
    # Backward pass: only moves anything when the forward pass was forced
    # past the strip bottom (content nearly fills the strip).
    if ($t3 + $H3 -gt $H) { $t3 = [math]::Max(0, $H - $H3) }
    if ($t2 + $H2 + $Gap23 -gt $t3) { $t2 = [math]::Max(0, $t3 - $Gap23 - $H2) }
    if ($t1 + $H1 + $Gap12 -gt $t2) { $t1 = [math]::Max(0, $t2 - $Gap12 - $H1) }
    return @($t1, $t2, $t3)
}

function Update-DevKitSideTabLayout {
    try {
        $canvas = $ui.SideTabCanvas
        if ($null -eq $canvas -or $canvas.ActualHeight -le 0) { return }
        $H = $canvas.ActualHeight
        $g1 = $ui.TabGroupFilesGit; $g2 = $ui.TabGroupNotesOnDeck; $tb = $ui.BtnTerminalTab
        if ($null -eq $g1 -or $null -eq $g2 -or $null -eq $tb) { return }
        $h1 = $g1.ActualHeight; $h2 = $g2.ActualHeight; $h3 = $tb.ActualHeight
        if ($h1 -le 0 -or $h2 -le 0 -or $h3 -le 0) { return }   # pre-layout
        # Group 2 leads with the tall separator (kept from the old centered
        # stack so a compressed strip keeps the same group break), so only
        # its BUTTONS portion is centered on the anchor.
        $sepBig = 0.0
        if ($ui.TabGroupSepBig) { $sepBig = $ui.TabGroupSepBig.ActualHeight }
        # Scroll-compensated (offset-zero) anchor centers - see
        # Get-DevKitAnchorCenterY. The same un-scrolled layout therefore
        # always yields the same tab tops, scrolled or not.
        $c1 = Get-DevKitAnchorCenterY -Anchor $ui.GaugesCard -RelativeTo $canvas
        $c2 = Get-DevKitAnchorCenterY -Anchor $ui.JunkCard -RelativeTo $canvas
        $c3 = Get-DevKitAnchorCenterY -Anchor $ui.QuickActionsExpander -RelativeTo $canvas
        # Fallbacks (anchor not transformable yet) keep the stack order with
        # sensible gaps; the very next SizeChanged replaces them.
        $d1 = if ($null -ne $c1) { $c1 - $h1 / 2.0 } else { 0.0 }
        $d2 = if ($null -ne $c2) { $c2 - $sepBig - ($h2 - $sepBig) / 2.0 } else { $d1 + $h1 + 24.0 }
        $d3 = if ($null -ne $c3) { $c3 - $h3 / 2.0 } else { $d2 + $h2 + 8.0 }
        # Gaps: none needed after group 1 (group 2's leading tall separator IS
        # the visual break) and 8px before TERMINAL; the gap yields first on
        # very short strips so the groups themselves never overlap.
        $gap12 = 0.0; $gap23 = 8.0
        if (($h1 + $gap12 + $h2 + $gap23 + $h3) -gt $H) { $gap23 = 0.0 }
        $tops = Resolve-DevKitSideTabTops -H $H -D1 $d1 -H1 $h1 -D2 $d2 -H2 $h2 -D3 $d3 -H3 $h3 -Gap12 $gap12 -Gap23 $gap23
        # Rounded to whole DIPs so unchanged results set the same value and
        # never re-invalidate layout on a no-change structural event.
        [Windows.Controls.Canvas]::SetTop($g1, [double][math]::Round($tops[0]))
        [Windows.Controls.Canvas]::SetTop($g2, [double][math]::Round($tops[1]))
        [Windows.Controls.Canvas]::SetTop($tb, [double][math]::Round($tops[2]))
    } catch { }
}

# Recompute triggers - structural changes only, NEVER scroll: BodyContent's
# LayoutUpdated fires after any layout pass that actually changed the body
# (expander opens, node-list rebuilds, badge rows appearing, text rewraps) -
# and, raised AFTER the pass completes, it always reads post-layout anchor
# positions. Pure scrolling never fires it (the ScrollViewer translates the
# content; it does not re-layout it), and the scroll-compensated anchor read
# would return the same tops anyway. Window SizeChanged covers the dock-mode
# height set, ContentRendered places the tabs once at startup. SetTop writes
# are value-rounded no-ops when nothing moved, so a fire changes no layout
# and cannot self-trigger. There is intentionally no ScrollChanged hook and
# no timer.
$ui.BodyContent.Add_LayoutUpdated({ Update-DevKitSideTabLayout })
$window.Add_SizeChanged({ Update-DevKitSideTabLayout })
$window.Add_ContentRendered({ Update-DevKitSideTabLayout })

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
$trayMenu.Items.Add('Open DevKit Control Center') | Out-Null
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
    # Wake from the hidden-to-tray sleep (see Hide-DevKitWidget): resume the
    # refresh timers and kick a metrics cycle right away so the dials aren't
    # showing pre-hide readings for the first couple of seconds.
    if ($script:FastTimer -and -not $script:FastTimer.IsEnabled) {
        $script:FastTimer.Start()
        $script:SlowTimer.Start()
        if (-not $script:MetricsBusy) { Start-DevKitMetricsRefresh }
    }
    # The hosted terminal's SESSION was left running across the hide: re-show
    # its window over the panel and resume its rect sync (stopped on hide).
    if ($script:TermFlyoutOpen -and $null -ne $script:TermHostedHwnd -and $script:TermHostedHwnd -ne [IntPtr]::Zero) {
        try { [DevKitTermWin32]::ShowWindow($script:TermHostedHwnd, [DevKitTermWin32]::SW_SHOWNA) | Out-Null } catch { }
        if ($script:TermSyncTimer -and -not $script:TermSyncTimer.IsEnabled) { $script:TermSyncTimer.Start() }
        try { Sync-DevKitHostedTerminalRect } catch { }
    }
}
function Hide-DevKitWidget {
    $window.Hide()
    $script:TrayShowItem.Text = 'Show Companion'
    # Hidden-to-tray sleep: stop every refresh timer. A tray-resident widget
    # must cost the machine ~nothing while it isn't visible - no metrics
    # cycles, no junk rescans, no git/env/MCP checks. The SummonTimer keeps
    # running (a 750ms WaitOne(0), effectively free) because it's the wake-up
    # path; any in-flight job simply completes and renders harmlessly into
    # the hidden window, and its result poll resumes on Show.
    if ($script:FastTimer) { $script:FastTimer.Stop() }
    if ($script:SlowTimer) { $script:SlowTimer.Stop() }
    # An open gauge management PANEL (Task Manager-style process list) must
    # close too: its 3s refresh jobs are collected by the FastTimer's
    # work-runspace poll, which just stopped - a panel left open on a hidden
    # widget would keep spawning jobs whose results are never picked up,
    # wedging the shared work runspace until each 30s timeout. The close also
    # stops the panel's own DispatcherTimer (see Set-DevKitProcPanel).
    Close-DevKitProcessDialogs
    # The hosted terminal's SESSION survives a hide (it is not a timer-driven
    # REPL) - only its window is hidden alongside the widget, and its rect
    # sync stops so a tray-resident widget keeps costing ~nothing. (The window
    # manager hides owned windows with their owner anyway; the explicit
    # SW_HIDE just makes it deterministic.)
    if ($null -ne $script:TermHostedHwnd -and $script:TermHostedHwnd -ne [IntPtr]::Zero) {
        try { [DevKitTermWin32]::ShowWindow($script:TermHostedHwnd, [DevKitTermWin32]::SW_HIDE) | Out-Null } catch { }
    }
    if ($script:TermSyncTimer) { $script:TermSyncTimer.Stop() }
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
function Get-DevKitStartupCommand {
    # The exact Run-value string both registration and self-healing use, so
    # they can never disagree about what "correct" looks like. Point at the
    # .vbs startup launcher, NOT a resolved pwsh.exe path (Store-packaged
    # pwsh lives in a version-stamped folder that moves on every background
    # auto-update, so a baked-in path goes stale and the launch fails with
    # no visible error) and NOT a .bat (a Run-key .bat flashes a console
    # window at every sign-in). The 45 is a startup delay in seconds: at
    # sign-in powershell.exe can fail to initialize with loader error
    # 0xC0000142 while the logon storm is still settling - the identical
    # launch works moments later - so the launcher waits it out and retries
    # via its pid-file handshake. Every path baked in here is stable:
    # wscript.exe (System32) and the .vbs itself (moves only if DevKit is
    # reinstalled/moved - which the self-heal below then repairs).
    $launcher = Join-Path $GuiDir 'Start-Widget-Startup.vbs'
    $wscript = Join-Path ([Environment]::SystemDirectory) 'wscript.exe'
    return "`"$wscript`" `"$launcher`" 45"
}
function Set-DevKitStartupEnabled {
    param([bool]$Enabled)
    try {
        if ($Enabled) {
            Set-ItemProperty -Path $script:RunKeyPath -Name $script:RunValueName -Value (Get-DevKitStartupCommand)
        } else {
            Remove-ItemProperty -Path $script:RunKeyPath -Name $script:RunValueName -ErrorAction SilentlyContinue
        }
    } catch {
        # Never swallow this silently - a failed write with the checkbox
        # still showing "on" is how "Start with Windows just stopped working"
        # bugs stay invisible. Balloon tip first, MessageBox as fallback.
        try {
            $script:TrayIcon.BalloonTipTitle = 'Northstar DevKit Companion'
            $script:TrayIcon.BalloonTipText = "Could not update the 'Start with Windows' setting: $($_.Exception.Message)"
            $script:TrayIcon.ShowBalloonTip(8000)
        } catch {
            try {
                [System.Windows.MessageBox]::Show(
                    "Could not update the 'Start with Windows' setting:`n`n$($_.Exception.Message)",
                    'Northstar DevKit Companion',
                    [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Warning) | Out-Null
            } catch { }
        }
    }
    Sync-DevKitStartupUi
}
function Sync-DevKitStartupUi {
    $enabled = Get-DevKitStartupEnabled
    $script:TrayStartupItem.Checked = $enabled
    $script:SuppressStartupUi = $true
    $ui.ChkStartup.IsChecked = $enabled
    $script:SuppressStartupUi = $false
}
function Repair-DevKitStartupRegistration {
    # Self-heal a stale Run value: the registered command bakes in the .vbs
    # absolute path, and nothing re-registers it when DevKit is moved or
    # reinstalled elsewhere - the old entry then pops "Can not find script
    # file" at every logon. If startup is enabled but the value differs from
    # what this install would write, or the .vbs it points at is gone,
    # rewrite it. Silent on success and on failure (the next widget start
    # simply tries again).
    if (-not (Get-DevKitStartupEnabled)) { return }
    try {
        $expected = Get-DevKitStartupCommand
        $current = (Get-ItemProperty -Path $script:RunKeyPath -Name $script:RunValueName -ErrorAction Stop).$($script:RunValueName)
        $stale = ($current -ne $expected)
        if (-not $stale -and $current -match '"([^"]+\.vbs)"') {
            $stale = -not (Test-Path $Matches[1])
        }
        if ($stale) {
            Set-ItemProperty -Path $script:RunKeyPath -Name $script:RunValueName -Value $expected
        }
    } catch { }
}

$script:TrayStartupItem.Add_Click({ Set-DevKitStartupEnabled -Enabled (-not (Get-DevKitStartupEnabled)) })
$ui.ChkStartup.Add_Checked({ if (-not $script:SuppressStartupUi) { Set-DevKitStartupEnabled -Enabled $true } })
$ui.ChkStartup.Add_Unchecked({ if (-not $script:SuppressStartupUi) { Set-DevKitStartupEnabled -Enabled $false } })
Repair-DevKitStartupRegistration
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

# ==================== PANEL WIDTH GRIPS (CAROUSEL FLYOUTS + TERMINAL) ====================
# The main widget window is NOT interactively width-resizable - its width
# comes solely from the persisted preferences.widgetWidth, applied once at
# startup via Get-DevKitWidgetWidth (window.Width assignment near the bottom
# of this file). Only the side panels keep drag-to-resize grips, each on its
# own OUTER edge (the far side from the main widget, facing the pull-tab/
# window edge). A drag only ever adjusts that panel's own width variable -
# the main content width is untouched. One shared set of drag functions
# serves all six panels (Git/Notes/Files/OnDeck carousel flyouts, the gauge
# management panel, and the independent terminal panel), routed by $Kind.
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
    if ($Kind -eq 'Files') {
        return @{ Border = $ui.FilesFlyout; Inner = $ui.FilesFlyoutInner; Width = $script:FilesFlyoutWidth }
    }
    if ($Kind -eq 'OnDeck') {
        return @{ Border = $ui.OnDeckFlyout; Inner = $ui.OnDeckFlyoutInner; Width = $script:OnDeckFlyoutWidth }
    }
    if ($Kind -eq 'Proc') {
        return @{ Border = $ui.ProcFlyout; Inner = $ui.ProcFlyoutInner; Width = $script:ProcFlyoutWidth }
    }
    if ($Kind -eq 'Terminal') {
        return @{ Border = $ui.TermFlyout; Inner = $ui.TermFlyoutInner; Width = $script:TermFlyoutWidth }
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
    if ($script:FlyoutResizeKind -eq 'Notes') { $script:NotesFlyoutWidth = $newWidth }
    elseif ($script:FlyoutResizeKind -eq 'Files') { $script:FilesFlyoutWidth = $newWidth }
    elseif ($script:FlyoutResizeKind -eq 'OnDeck') { $script:OnDeckFlyoutWidth = $newWidth }
    elseif ($script:FlyoutResizeKind -eq 'Proc') { $script:ProcFlyoutWidth = $newWidth }
    elseif ($script:FlyoutResizeKind -eq 'Terminal') { $script:TermFlyoutWidth = $newWidth }
    else { $script:FlyoutWidth = $newWidth }
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
    if ($script:FlyoutResizeKind -eq 'Notes') { Save-DevKitNotesFlyoutWidthSetting }
    elseif ($script:FlyoutResizeKind -eq 'Files') { Save-DevKitFilesFlyoutWidthSetting }
    elseif ($script:FlyoutResizeKind -eq 'OnDeck') { Save-DevKitOnDeckFlyoutWidthSetting }
    elseif ($script:FlyoutResizeKind -eq 'Proc') { Save-DevKitProcFlyoutWidthSetting }
    elseif ($script:FlyoutResizeKind -eq 'Terminal') { Save-DevKitTerminalFlyoutWidthSetting }
    else { Save-DevKitGitFlyoutWidthSetting }
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

$ui.FilesFlyoutGrip.Add_MouseLeftButtonDown({ param($s, $e) Start-DevKitFlyoutGripDrag -Sender $s -MouseArgs $e -Kind 'Files' })
$ui.FilesFlyoutGrip.Add_MouseMove({ param($s, $e) Update-DevKitFlyoutGripDrag -Sender $s -MouseArgs $e })
$ui.FilesFlyoutGrip.Add_MouseLeftButtonUp({ param($s, $e) Stop-DevKitFlyoutGripDrag -Sender $s })
$ui.FilesFlyoutGrip.Add_MouseEnter({ param($s, $e) $s.Background = Get-DevKitGitBrush '#2698C379' })
$ui.FilesFlyoutGrip.Add_MouseLeave({ param($s, $e) if (-not $s.IsMouseCaptured) { $s.Background = [Windows.Media.Brushes]::Transparent } })

$ui.OnDeckFlyoutGrip.Add_MouseLeftButtonDown({ param($s, $e) Start-DevKitFlyoutGripDrag -Sender $s -MouseArgs $e -Kind 'OnDeck' })
$ui.OnDeckFlyoutGrip.Add_MouseMove({ param($s, $e) Update-DevKitFlyoutGripDrag -Sender $s -MouseArgs $e })
$ui.OnDeckFlyoutGrip.Add_MouseLeftButtonUp({ param($s, $e) Stop-DevKitFlyoutGripDrag -Sender $s })
$ui.OnDeckFlyoutGrip.Add_MouseEnter({ param($s, $e) $s.Background = Get-DevKitGitBrush '#26C678DD' })
$ui.OnDeckFlyoutGrip.Add_MouseLeave({ param($s, $e) if (-not $s.IsMouseCaptured) { $s.Background = [Windows.Media.Brushes]::Transparent } })

$ui.ProcFlyoutGrip.Add_MouseLeftButtonDown({ param($s, $e) Start-DevKitFlyoutGripDrag -Sender $s -MouseArgs $e -Kind 'Proc' })
$ui.ProcFlyoutGrip.Add_MouseMove({ param($s, $e) Update-DevKitFlyoutGripDrag -Sender $s -MouseArgs $e })
$ui.ProcFlyoutGrip.Add_MouseLeftButtonUp({ param($s, $e) Stop-DevKitFlyoutGripDrag -Sender $s })
$ui.ProcFlyoutGrip.Add_MouseEnter({ param($s, $e) $s.Background = Get-DevKitGitBrush '#2694A3B8' })
$ui.ProcFlyoutGrip.Add_MouseLeave({ param($s, $e) if (-not $s.IsMouseCaptured) { $s.Background = [Windows.Media.Brushes]::Transparent } })

$ui.TermFlyoutGrip.Add_MouseLeftButtonDown({ param($s, $e) Start-DevKitFlyoutGripDrag -Sender $s -MouseArgs $e -Kind 'Terminal' })
$ui.TermFlyoutGrip.Add_MouseMove({ param($s, $e) Update-DevKitFlyoutGripDrag -Sender $s -MouseArgs $e })
$ui.TermFlyoutGrip.Add_MouseLeftButtonUp({ param($s, $e) Stop-DevKitFlyoutGripDrag -Sender $s })
$ui.TermFlyoutGrip.Add_MouseEnter({ param($s, $e) $s.Background = Get-DevKitGitBrush '#2656B6C2' })
$ui.TermFlyoutGrip.Add_MouseLeave({ param($s, $e) if (-not $s.IsMouseCaptured) { $s.Background = [Windows.Media.Brushes]::Transparent } })

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
    $newPath = $null; $newName = $null
    if ($idx -gt 0 -and $idx -le $script:ComboProjects.Count) {
        $newPath = $script:ComboProjects[$idx - 1].path
        $newName = $script:ComboProjects[$idx - 1].name
    }
    if ($newPath -ne $script:ActiveProjectPath) {
        # A real project switch: the graph's expanded-commit card belongs to
        # the OLD project's history - drop it (and any queued re-fetch).
        $script:GitExpandedCommitHash = $null
        $script:GitCommitDetails = $null
        $script:GitCommitDetailsPending = $false
    }
    $script:ActiveProjectPath = $newPath
    $script:ActiveProjectName = $newName
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
# The "+N more" footer click re-renders on demand instead of waiting for the
# next metrics cycle, so the last snapshot is kept; NodeListShowAll is the
# session-only expanded/collapsed state that footer toggles.
$script:LastNodeSnapshot = $null
$script:NodeListShowAll = $false
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

# Every gauge uses New-DevKitGaugeGeometry's default radius/center, so the
# whole arc space is 101 possible shapes. They are built once, Frozen (which
# also lets WPF share them across every gauge Path), and reused - the old
# code allocated a fresh PathGeometry per gauge per 33ms easing-timer tick,
# which (combined with the arcs' old DropShadowEffect and this window's
# AllowsTransparency recomposite) was the single biggest GPU/CPU cost in the
# widget. Dial resolution of 1% is far finer than the ~4s metrics cadence.
$script:GaugeGeometryCache = @{}
function Get-DevKitGaugeGeometry {
    param([double]$Percent)
    $key = [int][math]::Round([math]::Min(100.0, [math]::Max(0.0, $Percent)))
    $geometry = $script:GaugeGeometryCache[$key]
    if ($null -eq $geometry) {
        $geometry = New-DevKitGaugeGeometry -Percent $key
        $geometry.Freeze()
        $script:GaugeGeometryCache[$key] = $geometry
    }
    return $geometry
}

$script:Gauges = [ordered]@{
    Cpu = @{ Current = 0.0; Arc = $ui.CpuGaugeArc; Track = $ui.CpuGaugeTrack; Value = $ui.CpuGaugeValue; Sub = $ui.CpuGaugeSub }
    Mem = @{ Current = 0.0; Arc = $ui.MemGaugeArc; Track = $ui.MemGaugeTrack; Value = $ui.MemGaugeValue; Sub = $ui.MemGaugeSub }
    Gpu = @{ Current = 0.0; Arc = $ui.GpuGaugeArc; Track = $ui.GpuGaugeTrack; Value = $ui.GpuGaugeValue; Sub = $ui.GpuGaugeSub }
    Junk = @{ Current = 0.0; Arc = $ui.JunkGaugeArc; Track = $ui.JunkGaugeTrack; Value = $ui.JunkGaugeValue; Sub = $ui.JunkGaugeSub }
    # Disk_<letter> entries (e.g. Disk_C, Disk_D) are added/removed at
    # runtime by Update-DevKitDiskGauges as drives connect/disconnect - see
    # New-DevKitDynamicGaugeControl below.
}
foreach ($gauge in $script:Gauges.Values) {
    $gauge.Track.Data = Get-DevKitGaugeGeometry -Percent 100
    $gauge.Arc.Data = Get-DevKitGaugeGeometry -Percent 0
    $gauge.Arc.Visibility = 'Hidden'
}

function New-DevKitDynamicGaugeControl {
    <#
    .SYNOPSIS
        Builds one drive gauge's visual tree in code: an 88x88 radial dial in
        the same CPU/MEM/GPU layout (WidgetGaugeValue inside the ring,
        WidgetGaugeSub as a sibling below it, WidgetGaugeLabel below that) and
        the same style resources (BrushGaugeTrack/BrushGaugeArc) as every
        hardcoded gauge, so a gauge added at runtime for a newly-connected
        drive is visually indistinguishable from one that shipped in the
        XAML. Returns the same Arc/Track/Value/Sub shape as a $script:Gauges
        entry so it drops straight into Set-DevKitGauge once registered.
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

    $track.Data = Get-DevKitGaugeGeometry -Percent 100
    $arc.Data = Get-DevKitGaugeGeometry -Percent 0
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
            $script:Gauges[$key] = @{ Current = 0.0; Arc = $control.Arc; Track = $control.Track; Value = $control.Value; Sub = $control.Sub }
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

function Set-DevKitGauge {
    <#
    .SYNOPSIS
        Applies one gauge reading immediately. There is deliberately NO
        easing/animation timer: readings only change once per metrics cycle
        (~4s), so a 30fps animation between two stale values was pure cost -
        and on this AllowsTransparency window every animated frame forced a
        full-window recomposite. The arc is assigned from the frozen cached
        geometry table (Get-DevKitGaugeGeometry), never allocated per render.
    #>
    # $Percent stays untyped: a typed [double] would silently coerce $null to
    # 0 and report a dead sensor as a real zero reading.
    param([string]$Key, $Percent, [string]$ValueString, [string]$SubString, [bool]$Hot, [bool]$Available)
    $gauge = $script:Gauges[$Key]
    if (-not $Available) {
        $gauge.Current = 0.0
        $gauge.Value.Text = 'n/a'
        $gauge.Value.Foreground = Get-WidgetResource 'BrushTextDim'
        $gauge.Sub.Visibility = 'Hidden'
    } else {
        $gauge.Current = [math]::Min(100.0, [math]::Max(0.0, [double]$Percent))
        $gauge.Value.Text = $ValueString
        $gauge.Value.Foreground = if ($Hot) { Get-WidgetResource 'BrushAccentEmber' } else { Get-WidgetResource 'BrushTextBright' }
        if ([string]::IsNullOrWhiteSpace($SubString)) {
            $gauge.Sub.Visibility = 'Hidden'
        } else {
            $gauge.Sub.Text = $SubString
            $gauge.Sub.Visibility = 'Visible'
        }
        $gauge.Arc.Stroke = Get-WidgetResource $(if ($Hot) { 'BrushGaugeArcHot' } else { 'BrushGaugeArc' })
    }
    $gauge.Arc.Data = Get-DevKitGaugeGeometry -Percent $gauge.Current
    # A sub-1% arc with round caps renders as a stray dot; hide it instead.
    $gauge.Arc.Visibility = if ($gauge.Current -ge 1.0) { 'Visible' } else { 'Hidden' }
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
    # Adds a drag handle over the right edge of header column $ColIndex (same
    # key used in $script:NodeColumnWidths). Overlaid via
    # HorizontalAlignment=Right + a small negative right margin rather than a
    # real extra GridSplitter column, so it never shifts any other column's
    # index between the header and data rows. The transparent 6px Border is
    # the hit area; inside it sits an always-visible 2px grip bar so the user
    # can SEE where to grab (a purely hover-revealed splitter proved
    # undiscoverable). The bar brightens sapphire on hover/drag.
    param($Grid, [string]$ColKey, [int]$ColIndex)
    $splitter = New-Object Windows.Controls.Border
    $splitter.Width = 6
    $splitter.HorizontalAlignment = 'Right'
    $splitter.Margin = '0,0,-3,0'
    $splitter.Background = [Windows.Media.Brushes]::Transparent
    $splitter.Cursor = [System.Windows.Input.Cursors]::SizeWE
    $splitter.ToolTip = "Drag to resize the $ColKey column"
    $bar = New-Object Windows.Controls.Border
    $bar.Width = 2
    $bar.Height = 12
    $bar.CornerRadius = '1'
    $bar.Background = Get-WidgetResource 'BrushScrollThumb'
    $bar.IsHitTestVisible = $false
    $splitter.Child = $bar
    [Windows.Controls.Grid]::SetColumn($splitter, $ColIndex)
    [Windows.Controls.Panel]::SetZIndex($splitter, 10)
    $keyCopy = $ColKey
    $splitter.Add_MouseLeftButtonDown({ param($s, $e) Start-DevKitNodeColDrag -Sender $s -MouseArgs $e -ColKey $keyCopy }.GetNewClosure())
    $splitter.Add_MouseMove({ param($s, $e) Update-DevKitNodeColDrag -Sender $s -MouseArgs $e -ColKey $keyCopy }.GetNewClosure())
    $splitter.Add_MouseLeftButtonUp({ param($s, $e) Stop-DevKitNodeColDrag -Sender $s -ColKey $keyCopy }.GetNewClosure())
    $splitter.Add_MouseEnter({ param($s, $e) $s.Child.Background = Get-WidgetResource 'BrushAccentBlue' }.GetNewClosure())
    $splitter.Add_MouseLeave({ param($s, $e) if (-not $s.IsMouseCaptured) { $s.Child.Background = Get-WidgetResource 'BrushScrollThumb' } }.GetNewClosure())
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

function Toggle-DevKitNodeListExpanded {
    # The "+N more"/"Show less" footer click handler. Clearing LastNodeSig
    # forces the re-render past the signature gate; the snapshot kept by
    # Update-DevKitWidgetNode means no fresh (expensive) collection is needed.
    $script:NodeListShowAll = -not $script:NodeListShowAll
    $script:LastNodeSig = $null
    if ($script:LastNodeSnapshot) { Update-DevKitWidgetNode -Snapshot $script:LastNodeSnapshot }
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
    # Kept so the "+N more"/"Show less" footer can re-render on click instead
    # of waiting out the next metrics cycle (see Toggle-DevKitNodeListExpanded).
    $script:LastNodeSnapshot = $Snapshot
    # Rebuild signature. Raw MemoryMB/AgeMinutes used to be in here, which
    # meant the whole table (header + drag splitters + ~6 rows x ~10
    # elements + event-handler closures) was torn down and rebuilt nearly
    # every metrics cycle - dev-server memory fluctuates constantly. The
    # values are now bucketed (memory to 25MB, age to 5 minutes): the list
    # only rebuilds when the process SET changes or a displayed value would
    # actually move at the coarseness the table reads at.
    $sig = (($snap.Processes | ForEach-Object { "$($_.Pid):$($_.Name):$([math]::Floor([double]$_.MemoryMB / 25)):$([math]::Floor([double]$_.AgeMinutes / 5)):$($_.Ports -join ',')" }) -join '|') +
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

        $shown = if ($script:NodeListShowAll) { @($snap.Processes) } else { @($snap.Processes | Select-Object -First 6) }
        foreach ($proc in $shown) {
            $row = New-DevKitNodeRow -Name ([string]$proc.Name) -PidText "$($proc.Pid)" -MemText "$($proc.MemoryMB) MB" `
                -AgeText (Format-DevKitNodeAge $proc.AgeMinutes) -Ports $proc.Ports -ProcessId ([int]$proc.Pid)
            $ui.NodeListPanel.Children.Add($row) | Out-Null
        }
        if ($snap.Processes.Count -gt 6) {
            # Clickable footer: collapsed shows "+N more", expanded shows
            # "Show less" - the click toggles and re-renders immediately.
            $more = New-Object Windows.Controls.TextBlock
            $more.Style = Get-WidgetResource 'WidgetRowText'
            $more.Foreground = Get-WidgetResource 'BrushTextDim'
            if ($script:NodeListShowAll) {
                $more.Text = 'Show less'
                $more.ToolTip = 'Click to collapse back to the first 6 processes'
            } else {
                $more.Text = "+ $($snap.Processes.Count - 6) more"
                $more.ToolTip = "Click to show all $($snap.Processes.Count) processes"
            }
            $more.Margin = '0,3,0,0'
            $more.Cursor = [System.Windows.Input.Cursors]::Hand
            $more.Add_MouseLeftButtonDown({ Toggle-DevKitNodeListExpanded })
            $more.Add_MouseEnter({ param($s, $e) $s.Foreground = Get-WidgetResource 'BrushAccentBlue' })
            $more.Add_MouseLeave({ param($s, $e) $s.Foreground = Get-WidgetResource 'BrushTextDim' })
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
# out its own ~1s sampling window). Collecting on the dispatcher-thread
# FastTimer tick blocked the UI for longer than the timer's own interval,
# stalling drag/click input. Collection runs in this background runspace,
# and the FastTimer only re-arms a refresh ~2s after the previous one
# COMPLETED (completion-time gate) so the runspace gets idle gaps.
# Same async-runspace-plus-poll pattern as the MCP refresh below.

function New-DevKitWidgetRunspace {
    <#
    .SYNOPSIS
        Creates, opens, and BOOTSTRAPS one background runspace: the shared
        libraries are dot-sourced into its session state exactly once here,
        so every later job pipeline is a bare function call.
    .DESCRIPTION
        This matters twice over. First, the old per-job dot-source re-read,
        re-parsed, and re-executed ~140-150KB of PowerShell on EVERY cycle
        (~every 4s, forever). Second, it re-ran DevKit-WidgetCore.ps1's
        top-level `$script:*Cache = $null` initializers before every job,
        which wiped the per-runspace sensor caches - so nvidia-smi was
        spawned every cycle instead of every 10s, the thermal-zone counter
        paid its ~1s PDH sample stall every cycle instead of every 45s, and
        `netsh show excludedportrange` ran every cycle instead of every 30
        minutes. Bootstrapping once keeps those caches alive between jobs.
    #>
    param([switch]$IncludeMcpList)
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    try {
        $lib = (Join-Path $ToolsDir 'lib\DevKit-Common.ps1') -replace "'", "''"
        $core = (Join-Path $GuiDir 'DevKit-WidgetCore.ps1') -replace "'", "''"
        $scriptText = ". '$lib'; . '$core'"
        if ($IncludeMcpList) {
            $mcpList = (Join-Path $ToolsDir 'lib\DevKit-McpList.ps1') -replace "'", "''"
            $scriptText = ". '$lib'; . '$mcpList'; . '$core'"
        }
        $bootstrap = [powershell]::Create()
        $bootstrap.Runspace = $rs
        [void]$bootstrap.AddScript($scriptText)
        $bootstrap.Invoke()
        $bootstrap.Dispose()
    } catch { }
    return $rs
}

$script:MetricsRunspace = New-DevKitWidgetRunspace
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
        # Libraries were dot-sourced once at runspace creation
        # (New-DevKitWidgetRunspace) - jobs are bare collector calls.
        $scriptText = "@{ Metrics = (Get-DevKitSystemMetrics); Node = (Get-DevKitNodeSnapshot) }"
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
        $script:MetricsRunspace = New-DevKitWidgetRunspace
    } catch { }
}

# ==================== MCP STATUS (ASYNC) ====================
# 'claude mcp list' health-checks every server and can take 10+ seconds, so
# the refresh runs in a background runspace; the fast timer polls for
# completion and renders on the dispatcher thread. A hung refresh is stopped
# after 45s and reported as timed out instead of freezing the widget.

$script:McpRunspace = New-DevKitWidgetRunspace -IncludeMcpList
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
        $scriptText = "param(`$projectPath) Get-DevKitMcpWidgetReport -ProjectPath `$projectPath"
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
        $script:McpRunspace = New-DevKitWidgetRunspace -IncludeMcpList
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

$script:WorkRunspace = New-DevKitWidgetRunspace
$script:WorkBusy = $false
$script:WorkShell = $null
$script:WorkAsync = $null
$script:WorkStarted = $null
$script:WorkKind = $null

function Start-DevKitWorkJob {
    param(
        # 'JunkScan' | 'JunkClean' | 'GitOverview' | 'GitFetch' | 'GitPull' | 'GitPush' | 'EnvDrift' | 'GitHubPRs' | 'GitHubIssues'
        # | 'ProcCpu' | 'ProcMem' | 'ProcGpu' | 'FreeMem' | 'ProcKill'   (gauge management panel - see GAUGE MANAGEMENT PANEL)
        # | 'CommitDetails'   (commit graph click-to-expand - 'git show' for one hash)
        [Parameter(Mandatory = $true)][string]$Kind,
        [string]$ProjectPath,
        [int]$TargetPid = 0,   # ProcKill only: the process id to stop
        [string]$CommitHash = ''   # CommitDetails only: the commit hash to show
    )
    if ($script:WorkBusy) { return $false }
    $script:WorkBusy = $true
    try {
        $ps = [powershell]::Create()
        $ps.Runspace = $script:WorkRunspace
        # Libraries were dot-sourced once at runspace creation
        # (New-DevKitWidgetRunspace) - job bodies are bare collector calls.
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
            # $chash is the third script argument (hex-validated inside the
            # collector, so quoting here is never an injection surface).
            'CommitDetails' { '@{ CommitDetails = (Get-DevKitCommitDetails -Path $path -Hash $chash) }' }
            # Gauge panel collectors. ProcCpu wraps in @() so a single-row
            # result still survives the runspace trip as an array; the others
            # return a single shaped object either way. $tpid (not $pid - that
            # name collides with the read-only automatic $PID variable) is the
            # second script argument, only meaningful for ProcKill.
            'ProcCpu'  { '@{ ProcCpu = @(Get-DevKitTopCpuProcesses -Count 15) }' }
            'ProcMem'  { '@{ ProcMem = (Get-DevKitTopMemoryProcesses -Count 15) }' }
            'ProcGpu'  { '@{ ProcGpu = (Get-DevKitGpuProcessUsage -Count 15) }' }
            'FreeMem'  { '@{ FreeMem = (Invoke-DevKitFreeMemory) }' }
            'ProcKill' { '@{ ProcKill = (Stop-DevKitProcessById -Pid $tpid) }' }
            default {
                # GitFetch/GitPull/GitPush: run the action, then immediately
                # re-read the overview so the graph reflects the result.
                $action = $Kind.Replace('Git', '').ToLower()
                "@{ GitAction = (Invoke-DevKitGitAction -Path `$path -Action '$action'); Git = (Get-DevKitRepoOverview -Path `$path -IncludeGraph `$$script:GitFlyoutOpen) }"
            }
        }
        $scriptText = "param(`$path, `$tpid, `$chash) $body"
        [void]$ps.AddScript($scriptText).AddArgument([string]$ProjectPath).AddArgument($TargetPid).AddArgument($CommitHash)
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
        $script:WorkRunspace = New-DevKitWidgetRunspace
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
                'CommitDetails' {
                    # Same stale-project guard as GitHubPRs above; the
                    # hash-still-selected check lives in Update-DevKitCommitDetails.
                    if (-not $script:WorkProjectPath -or -not $script:ActiveProjectPath -or $script:WorkProjectPath -eq $script:ActiveProjectPath) {
                        Update-DevKitCommitDetails -Result $result.CommitDetails
                    }
                }
                # Gauge management panel results. Each render/completion
                # function no-ops when its kind has since been unregistered
                # (panel closed or metric switched), so a late result is
                # dropped, never rendered into a panel showing another metric.
                'ProcCpu'  { Update-DevKitProcDialog -Kind 'Cpu' -Result $result.ProcCpu }
                'ProcMem'  { Update-DevKitProcDialog -Kind 'Mem' -Result $result.ProcMem }
                'ProcGpu'  { Update-DevKitProcDialog -Kind 'Gpu' -Result $result.ProcGpu }
                'FreeMem'  { Complete-DevKitFreeMemory -Result $result.FreeMem }
                'ProcKill' { Complete-DevKitProcKill -Result $result.ProcKill }
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
        # Same re-fire for a commit-details fetch declined while this job held
        # the slot (user clicked a commit row while another job was running).
        # No selection + pending means the user collapsed the card meanwhile.
        if ($script:GitCommitDetailsPending -and $script:ActiveProjectPath -and $script:GitExpandedCommitHash) {
            $script:GitCommitDetailsPending = $false
            [void](Start-DevKitWorkJob -Kind 'CommitDetails' -ProjectPath $script:ActiveProjectPath -CommitHash $script:GitExpandedCommitHash)
        } else {
            $script:GitCommitDetailsPending = $false
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
        } elseif ($kind -like 'Proc*' -or $kind -eq 'FreeMem') {
            # A gauge panel's job hit the 30s timeout (checked before the
            # 'Git*' wildcard below only for clarity - no overlap). The
            # panel's own 3s timer retries plain refreshes on its own, but
            # a timed-out kill/free-mem needs its button re-enabled and a
            # message stamped or the panel would look stuck forever.
            Update-DevKitProcDialogTimeout -Kind $kind
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
        } elseif ($kind -eq 'CommitDetails') {
            # Checked ahead of the 'Git*' wildcard for clarity (no overlap).
            # Un-stick the inline "Loading commit details..." card: stamp an
            # honest timeout error into the details cache (keyed to the still-
            # expanded hash, if any) and re-render so it shows in place.
            if ($script:GitExpandedCommitHash) {
                $script:GitCommitDetails = [pscustomobject]@{
                    Found = $false; Hash = $script:GitExpandedCommitHash
                    Error = 'git show did not answer (timed out) - click the commit to retry.'
                    Author = ''; Email = ''; Date = ''; Message = ''
                    Files = @(); FilesChanged = 0; Insertions = 0; Deletions = 0
                }
                if ($script:GitFlyoutOpen -and $script:GitOverview -and $script:GitOverview.Graph) {
                    Render-DevKitGitGraph -Graph $script:GitOverview.Graph
                }
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
        # Same re-fire as in the completion path above: a commit-details fetch
        # declined while the timed-out job held the slot gets its turn now.
        if ($script:GitCommitDetailsPending -and $script:ActiveProjectPath -and $script:GitExpandedCommitHash) {
            $script:GitCommitDetailsPending = $false
            [void](Start-DevKitWorkJob -Kind 'CommitDetails' -ProjectPath $script:ActiveProjectPath -CommitHash $script:GitExpandedCommitHash)
        } else {
            $script:GitCommitDetailsPending = $false
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
$script:LastJunkScanResult = $null   # last Get-DevKitSystemJunk result, for the Details... dialog
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

function Get-DevKitWidgetField {
    # Shape-tolerant reader for collector results crossing the runspace
    # boundary: they arrive as deserialized PSObjects, a couple of call sites
    # also see raw hashtables, and fields added by a newer WidgetCore build
    # may simply be absent on an older one. Returns $Default instead of
    # throwing on any of those.
    param($Obj, [Parameter(Mandatory = $true)][string]$Name, $Default = $null)
    if ($null -eq $Obj) { return $Default }
    if ($Obj -is [System.Collections.IDictionary]) {
        if ($Obj.Contains($Name)) { return $Obj[$Name] }
        return $Default
    }
    $prop = $Obj.PSObject.Properties[$Name]
    if ($null -ne $prop) { return $prop.Value }
    return $Default
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
    $script:LastJunkScanResult = $Junk   # kept for the Details... dialog's per-category breakdown
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
    $successBrush = Get-DevKitGitBrush '#3EDD8F'   # BrushSuccess hex (kept theme-independent)
    # Reset any inline runs a previous clean left behind before stamping plain
    # text (Text and Inlines share the same content store on a TextBlock).
    $ui.JunkStatusText.Inlines.Clear()
    if (-not $Clean) {
        $ui.JunkStatusText.Text = 'Clean finished.'
        $ui.JunkStatusText.Foreground = $successBrush
    } else {
        # Per-category breakdown from the extended Clear-DevKitSystemJunk:
        # only categories that actually freed anything are named, so a routine
        # clean keeps the line short. Missing fields (older WidgetCore) read
        # as 0 via Get-DevKitWidgetField and simply drop out of the list.
        $parts = @()
        foreach ($pair in @(@('TempUserFreed', 'temp'), @('TempWindowsFreed', 'Windows temp'), @('WuCacheFreed', 'update cache'), @('RecycleFreed', 'recycle bin'))) {
            $bytes = [double](Get-DevKitWidgetField $Clean $pair[0] 0)
            if ($bytes -gt 0) { $parts += "$($pair[1]) $(Format-DevKitJunkSize $bytes)" }
        }
        $main = "Freed $(Format-DevKitJunkSize ([double](Get-DevKitWidgetField $Clean 'FreedBytes' 0)))"
        if ($parts.Count -gt 0) { $main += " - $($parts -join ', ')" }
        $ui.JunkStatusText.Text = $main
        $ui.JunkStatusText.Foreground = $successBrush
        $skipped = @(@(Get-DevKitWidgetField $Clean 'SkippedNeedsAdmin' @()) | Where-Object { $_ })
        if ($skipped.Count -gt 0) {
            # The hint goes in as its own Run so it can carry the ember
            # warning color without recoloring the (successful) result line.
            $pretty = @($skipped | ForEach-Object { ([string]$_) -replace '(?<=[a-z])(?=[A-Z])', ' ' })
            $ui.JunkStatusText.Inlines.Add((New-Object Windows.Documents.LineBreak)) | Out-Null
            $hintRun = New-Object Windows.Documents.Run
            $hintRun.Text = "Skipped admin-only areas ($($pretty -join ', ')) - restart the widget as administrator to reach them."
            $hintRun.Foreground = Get-WidgetResource 'BrushAccentEmber'
            $ui.JunkStatusText.Inlines.Add($hintRun) | Out-Null
        }
    }
    $ui.JunkStatusText.Visibility = 'Visible'
    Start-DevKitJunkScan   # re-scan so the gauge reflects the clean
}

function Show-DevKitJunkDetails {
    # Per-category breakdown of the last junk scan - the in-GUI replacement
    # for the old "Cleanup Tool..." button, which launched Clear-DiskJunk.ps1
    # in a terminal and made the user type CLEAN. Cleanup in the widget is
    # now 100% GUI-side (styled confirms only, no terminal anywhere). Modal
    # (ShowDialog) like the Manage... dialogs: a point-in-time snapshot has
    # nothing to refresh, so there is no timer to manage.
    $dlg = New-Object Windows.Window
    $dlg.Title = 'System Junk - Details'
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
    $titleText.Text = 'System Junk - Details'
    $stack.Children.Add($titleText) | Out-Null

    $scan = $script:LastJunkScanResult
    if (-not $scan) {
        $none = New-Object Windows.Controls.TextBlock
        $none.Style = Get-WidgetResource 'WidgetRowText'
        $none.TextWrapping = 'Wrap'
        $none.Margin = '0,8,0,0'
        $none.Text = 'No scan has finished yet - one has been kicked off now; reopen this in a few seconds.'
        $stack.Children.Add($none) | Out-Null
        Start-DevKitJunkScan
    } else {
        $addRow = {
            param([string]$Label, [string]$Value, [bool]$Total = $false)
            $g = New-Object Windows.Controls.Grid
            $g.Margin = $(if ($Total) { '0,8,0,0' } else { '0,3,0,0' })
            $colLeft = New-Object Windows.Controls.ColumnDefinition
            $colLeft.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
            $g.ColumnDefinitions.Add($colLeft) | Out-Null
            $colRight = New-Object Windows.Controls.ColumnDefinition
            $colRight.Width = [Windows.GridLength]::Auto
            $g.ColumnDefinitions.Add($colRight) | Out-Null
            $l = New-Object Windows.Controls.TextBlock
            $l.Style = Get-WidgetResource 'WidgetRowText'
            $l.Text = $Label
            $v = New-Object Windows.Controls.TextBlock
            $v.Style = Get-WidgetResource 'WidgetRowText'
            $v.Foreground = Get-WidgetResource 'BrushTextBright'
            $v.HorizontalAlignment = 'Right'
            $v.Text = $Value
            if ($Total) { $l.FontWeight = 'SemiBold'; $v.FontWeight = 'SemiBold' }
            [Windows.Controls.Grid]::SetColumn($v, 1)
            $g.Children.Add($l) | Out-Null
            $g.Children.Add($v) | Out-Null
            $stack.Children.Add($g) | Out-Null
        }.GetNewClosure()
        # Field names follow Get-DevKitSystemJunk's documented shape; a missing
        # field reads as 0 rather than breaking the dialog.
        & $addRow 'Temp files' (Format-DevKitJunkSize ([double](Get-DevKitWidgetField $scan 'TempBytes' 0)))
        & $addRow 'Windows Update cache' (Format-DevKitJunkSize ([double](Get-DevKitWidgetField $scan 'WuBytes' 0)))
        & $addRow 'Recycle Bin' (Format-DevKitJunkSize ([double](Get-DevKitWidgetField $scan 'RecycleBytes' 0)))
        & $addRow 'Total' (Format-DevKitJunkSize ([double](Get-DevKitWidgetField $scan 'TotalBytes' 0))) $true
        $note = New-Object Windows.Controls.TextBlock
        $note.Style = Get-WidgetResource 'StatusText'
        $note.FontSize = 9.5
        $note.TextWrapping = 'Wrap'
        $note.Margin = '0,8,0,0'
        $note.Text = 'Admin-only areas (Windows temp, update cache) can read lower than reality when the widget is not running as administrator.'
        $stack.Children.Add($note) | Out-Null
    }

    $row = New-Object Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'
    $row.HorizontalAlignment = 'Right'
    $row.Margin = '0,12,0,0'
    $closeBtn = New-Object Windows.Controls.Button
    $closeBtn.Style = Get-WidgetResource 'GhostButton'
    $closeBtn.Content = 'Close'
    $row.Children.Add($closeBtn) | Out-Null
    $stack.Children.Add($row) | Out-Null
    $root.Child = $stack
    $dlg.Content = $root

    $closeBtn.Add_Click({ $dlg.Close() }.GetNewClosure())
    $dlg.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Escape') { $s.Close() } })
    $dlg.Add_ContentRendered({ $closeBtn.Focus() | Out-Null }.GetNewClosure())
    $dlg.ShowDialog() | Out-Null
}

$ui.BtnJunkDetails.Add_Click({ Show-DevKitJunkDetails })
$ui.BtnJunkClean.Add_Click({
    if ($script:WorkBusy) {
        $ui.JunkStatusText.Text = 'Busy - try again in a moment.'
        $ui.JunkStatusText.Visibility = 'Visible'
        return
    }
    $yes = Show-DevKitWidgetConfirm -Title 'Clean System Junk' `
        -Message "This permanently deletes the contents of your temp folders (plus Windows temp and the update cache when running as administrator) and empties the Recycle Bin.`n`nThis cannot be undone. Continue?"
    if (-not $yes) { return }
    $ui.BtnJunkClean.IsEnabled = $false
    $ui.JunkStatusText.Text = 'Cleaning...'
    $ui.JunkStatusText.Visibility = 'Visible'
    if (-not (Start-DevKitWorkJob -Kind 'JunkClean')) {
        $ui.BtnJunkClean.IsEnabled = $true
        $ui.JunkStatusText.Text = 'Could not start the clean - try again.'
    }
})

# ==================== GAUGE MANAGEMENT PANEL ====================
# Clicking a CPU/MEM/GPU gauge toggles a Task Manager-style slide-out PANEL
# (a member of the flyout carousel, NOT a separate window anymore) listing
# the processes behind that metric, with SAFE TO CLOSE / CAUTION / LEAVE
# ALONE classification badges and confirmed per-row kills (System rows get no
# kill button; Stop-DevKitProcessById refuses them server-side too). The
# panel joins the single-flyout carousel: opening one closes whichever
# carousel flyout is open (and vice versa), while coexisting with the
# independent terminal panel. It refreshes every 3 seconds WHILE OPEN via
# the shared work runspace (the ProcCpu/ProcMem/ProcGpu/FreeMem/ProcKill
# Kinds in Start-DevKitWorkJob above). All collection happens in the
# runspace; the UI thread only renders completed results routed through
# Update-DevKitWorkAsyncPoll.
#
# Timer discipline (the "no always-on timers" rule): the 3s DispatcherTimer
# is created when the panel opens and Stopped the moment it closes (the
# close path also unregisters the kind from $script:ProcDialogs - a result
# arriving for a closed panel is then dropped by the render functions instead
# of touching stale elements). A refresh declined because the work runspace
# is busy (junk scan, git action) is not an error: the next timer tick simply
# retries. Hide-DevKitWidget closes an open panel via
# Close-DevKitProcessDialogs, since the work-runspace poll lives on the
# FastTimer, which stops while the widget is hidden.
$script:ProcDialogs = @{}          # 'Cpu'/'Mem'/'Gpu' -> open panel kind's render-state hashtable
$script:ProcKillContext = $null    # @{ Kind; Name; Pid } of the in-flight ProcKill job

function Set-DevKitProcKillContext {
    # Assignment helper for the GetNewClosure()'d click handlers below: inside
    # such a closure, a $script: name binds to the closure's COPIED scope -
    # where ProcKillContext does not exist - so the write would be lost. A
    # hashtable like $script:ProcDialogs can instead be captured by REFERENCE
    # in a local (mutating the same live object stays visible), but
    # ProcKillContext is REASSIGNED, so it goes through this script-level
    # setter whose own $script: resolves correctly.
    param($Ctx)
    $script:ProcKillContext = $Ctx
}

function Close-DevKitProcessDialogs {
    # Panel model: at most one gauge panel exists (it is one shared Border in
    # the XAML whose content is re-titled per kind). Instant close - this
    # usually runs mid-hide-to-tray or mid-dock-flip, where an animation
    # would never be seen anyway. The close path stops the panel's 3s refresh
    # timer and unregisters its render state.
    if ($script:ProcPanelKind) { Set-DevKitProcPanel -Open $false -Instant }
}

function Request-DevKitProcRefresh {
    # Fire-and-forget refresh for the open gauge panel. A declined start
    # ($false = work runspace busy) needs no handling: the panel's own 3s
    # timer fires Request- again shortly.
    param([Parameter(Mandatory = $true)][string]$Kind)
    if (-not $script:ProcDialogs.Contains($Kind)) { return }
    [void](Start-DevKitWorkJob -Kind ('Proc' + $Kind))
}

function New-DevKitClassificationBadge {
    # SAFE TO CLOSE (green) / CAUTION (ember) / LEAVE ALONE (grey), built on
    # the theme's existing badge style pairs.
    param([Parameter(Mandatory = $true)][string]$Classification)
    $spec = switch ($Classification) {
        'Safe'   { @{ Text = 'SAFE TO CLOSE'; Border = 'BadgeSuccess'; TextStyle = 'BadgeSuccessText' } }
        'System' { @{ Text = 'LEAVE ALONE';   Border = 'BadgeNeutral'; TextStyle = 'BadgeNeutralText' } }
        default  { @{ Text = 'CAUTION';       Border = 'BadgeAuth';    TextStyle = 'BadgeAuthText' } }
    }
    $badge = New-Object Windows.Controls.Border
    $badge.Style = Get-WidgetResource $spec.Border
    $badge.VerticalAlignment = 'Center'
    $text = New-Object Windows.Controls.TextBlock
    $text.Style = Get-WidgetResource $spec.TextStyle
    $text.Text = $spec.Text
    $badge.Child = $text
    return $badge
}

function New-DevKitProcRow {
    # One row of the gauge panel: NAME | PID | metric cell(s) | badge | Kill.
    # The name column is a star so long process names ellipsize instead of
    # pushing the value columns around; everything else is Auto.
    param(
        [Parameter(Mandatory = $true)][string]$Kind,          # owning metric (kill completion routes back to it)
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [Parameter(Mandatory = $true)][string[]]$MetricTexts, # right-aligned value cells, e.g. @('12.3 %', '456 MB')
        [Parameter(Mandatory = $true)][string]$Classification # 'System' | 'Safe' | 'Caution'
    )
    $grid = New-Object Windows.Controls.Grid
    $grid.Margin = '0,2,0,2'
    $nameCol = New-Object Windows.Controls.ColumnDefinition
    $nameCol.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
    $nameCol.MinWidth = 80
    $grid.ColumnDefinitions.Add($nameCol) | Out-Null
    for ($i = 0; $i -lt (2 + $MetricTexts.Count + 1); $i++) {   # pid + metrics + badge + kill
        $autoCol = New-Object Windows.Controls.ColumnDefinition
        $autoCol.Width = [Windows.GridLength]::Auto
        $grid.ColumnDefinitions.Add($autoCol) | Out-Null
    }

    $nameText = New-Object Windows.Controls.TextBlock
    $nameText.Style = Get-WidgetResource 'WidgetRowText'
    $nameText.Foreground = Get-WidgetResource 'BrushTextBright'
    $nameText.Text = $Name
    $nameText.TextTrimming = 'CharacterEllipsis'
    [Windows.Controls.Grid]::SetColumn($nameText, 0)
    $grid.Children.Add($nameText) | Out-Null

    $col = 1
    $pidText = New-Object Windows.Controls.TextBlock
    $pidText.Style = Get-WidgetResource 'WidgetRowText'
    $pidText.Foreground = Get-WidgetResource 'BrushTextDim'
    $pidText.Text = "$ProcessId"
    $pidText.Margin = '10,0,0,0'
    [Windows.Controls.Grid]::SetColumn($pidText, $col)
    $grid.Children.Add($pidText) | Out-Null
    $col++

    foreach ($metric in $MetricTexts) {
        $metricText = New-Object Windows.Controls.TextBlock
        $metricText.Style = Get-WidgetResource 'WidgetRowText'
        $metricText.Foreground = Get-WidgetResource 'BrushTextBright'
        $metricText.Text = $metric
        $metricText.Margin = '12,0,0,0'
        [Windows.Controls.Grid]::SetColumn($metricText, $col)
        $grid.Children.Add($metricText) | Out-Null
        $col++
    }

    $badge = New-DevKitClassificationBadge -Classification $Classification
    $badge.Margin = '10,0,0,0'
    [Windows.Controls.Grid]::SetColumn($badge, $col)
    $grid.Children.Add($badge) | Out-Null
    $col++

    if ($Classification -ne 'System') {
        $killBtn = New-Object Windows.Controls.Button
        $killBtn.Style = Get-WidgetResource 'GhostButton'
        $killBtn.Content = 'Kill'
        $killBtn.FontSize = 9.5
        $killBtn.Padding = '7,1'
        $killBtn.Margin = '10,0,0,0'
        $killBtn.Cursor = [System.Windows.Input.Cursors]::Hand
        $killBtn.ToolTip = "Stop $Name (pid $ProcessId) - asks first"
        $procName = $Name
        $kindCopy = $Kind
        # Captured by REFERENCE for the closure below: $script: names inside a
        # GetNewClosure()'d handler bind to the closure's copied scope (where
        # this hashtable doesn't exist), but a local holding the same live
        # hashtable mutates the real registry. See Set-DevKitProcKillContext.
        $procDialogs = $script:ProcDialogs
        $killBtn.Add_Click({
            # Same TOCTOU guard as the node table's per-pid kill, in miniature:
            # re-verify the pid still belongs to the same process before AND
            # after the confirm dialog (which can stay open indefinitely), so
            # a pid recycled while the user was deciding never takes the hit.
            # Names are compared with any ".exe" suffix stripped on BOTH sides
            # - collectors report Name without a documented suffix convention,
            # while Get-Process's ProcessName never carries one.
            $normName = { param($n) ([string]$n) -replace '\.exe$', '' }
            $preProc = $null
            try { $preProc = Get-Process -Id $ProcessId -ErrorAction Stop } catch { }
            if (-not $preProc -or ((& $normName $preProc.ProcessName) -ine (& $normName $procName))) { return }
            $preStart = try { $preProc.StartTime } catch { $null }
            $yes = Show-DevKitWidgetConfirm -Title 'End Process' -Message "Stop $procName (pid $ProcessId)?`n`nUnsaved work in that process is lost."
            if (-not $yes) { return }
            $postProc = $null
            try { $postProc = Get-Process -Id $ProcessId -ErrorAction Stop } catch { }
            if (-not $postProc -or ((& $normName $postProc.ProcessName) -ine (& $normName $procName))) { return }
            $postStart = try { $postProc.StartTime } catch { $null }
            if ($postStart -ne $preStart) { return }
            # The actual Stop-Process runs in the work runspace like every
            # other mutating job; the panel's status line reports the Note
            # (kills on elevated processes legitimately fail from an
            # unelevated widget - shown, never thrown).
            if ($procDialogs.Contains($kindCopy)) {
                $dlgState = $procDialogs[$kindCopy]
                $dlgState.Status.Text = "Stopping $procName (pid $ProcessId)..."
                $dlgState.Status.Foreground = Get-WidgetResource 'BrushTextDim'
                $dlgState.Status.Visibility = 'Visible'
            }
            Set-DevKitProcKillContext -Ctx @{ Kind = $kindCopy; Name = $procName; Pid = $ProcessId }
            if (-not (Start-DevKitWorkJob -Kind 'ProcKill' -TargetPid $ProcessId)) {
                Set-DevKitProcKillContext -Ctx $null
                if ($procDialogs.Contains($kindCopy)) {
                    $dlgState = $procDialogs[$kindCopy]
                    $dlgState.Status.Text = 'Busy - try again in a moment.'
                    $dlgState.Status.Visibility = 'Visible'
                }
            }
        }.GetNewClosure())
        [Windows.Controls.Grid]::SetColumn($killBtn, $col)
        $grid.Children.Add($killBtn) | Out-Null
    }

    $grid.ToolTip = "$Name (pid $ProcessId)"
    return $grid
}

function Update-DevKitProcDialog {
    # Pure render of an already-collected snapshot, on the dispatcher thread.
    param([Parameter(Mandatory = $true)][string]$Kind, $Result)
    # The panel may have closed (or switched metric) while its job was in
    # flight - closing/switching unregisters the kind - so drop the result
    # rather than render into elements the user is no longer looking at.
    if (-not $script:ProcDialogs.Contains($Kind)) { return }
    $dlgState = $script:ProcDialogs[$Kind]
    $rows = @()

    if ($Kind -eq 'Mem') {
        if ($Result) {
            $dlgState.Summary.Text = ('{0:N1} GB used of {1:N1} GB ({2:N1} GB free)' -f `
                [double](Get-DevKitWidgetField $Result 'UsedGB' 0), `
                [double](Get-DevKitWidgetField $Result 'TotalGB' 0), `
                [double](Get-DevKitWidgetField $Result 'FreeGB' 0))
        }
        $procList = Get-DevKitWidgetField $Result 'Processes' $null
        if ($procList) {
            $rows = @($procList | Sort-Object { [double](Get-DevKitWidgetField $_ 'MemoryMB' 0) } -Descending)
        }
    } elseif ($Kind -eq 'Gpu') {
        $dlgState.Adapter.Children.Clear()
        $adapter = Get-DevKitWidgetField $Result 'Adapter' $null
        $adapterName = [string](Get-DevKitWidgetField $adapter 'Name' '')
        $util = Get-DevKitWidgetField $adapter 'UtilPercent' $null
        $temp = Get-DevKitWidgetField $adapter 'TempC' $null
        $memUsed = Get-DevKitWidgetField $adapter 'MemUsedMB' $null
        $memTotal = Get-DevKitWidgetField $adapter 'MemTotalMB' $null
        # Honest-empty rule, same as the gauges' "n/a": only when NOTHING
        # came back. Utilization alone (the no-nvidia-smi counter path) is
        # still real telemetry, shown under a generic adapter label.
        if (-not $adapter -or (-not $adapterName -and $null -eq $util -and $null -eq $temp -and $null -eq $memUsed)) {
            $noGpu = New-Object Windows.Controls.TextBlock
            $noGpu.Style = Get-WidgetResource 'WidgetRowText'
            $noGpu.Foreground = Get-WidgetResource 'BrushTextDim'
            $noGpu.TextWrapping = 'Wrap'
            $noGpu.Text = 'No GPU telemetry available on this machine.'
            $dlgState.Adapter.Children.Add($noGpu) | Out-Null
        } else {
            $nameBlock = New-Object Windows.Controls.TextBlock
            $nameBlock.Style = Get-WidgetResource 'WidgetRowText'
            $nameBlock.Foreground = Get-WidgetResource 'BrushTextBright'
            $nameBlock.FontWeight = 'SemiBold'
            $nameBlock.TextWrapping = 'Wrap'
            $nameBlock.Text = if ($adapterName) { $adapterName } else { 'GPU (adapter name unavailable)' }
            $dlgState.Adapter.Children.Add($nameBlock) | Out-Null
            $stats = @()
            if ($null -ne $util) { $stats += ('{0:N0}% util' -f [double]$util) }
            if ($null -ne $temp) { $stats += ('{0:N0} ' -f [double]$temp) + [char]0x00B0 + 'C' }
            if ($null -ne $memUsed) {
                $stats += if ($null -ne $memTotal -and [double]$memTotal -gt 0) {
                    ('{0:N1} / {1:N1} GB VRAM' -f ([double]$memUsed / 1024), ([double]$memTotal / 1024))
                } else {
                    ('{0:N0} MB VRAM' -f [double]$memUsed)
                }
            }
            if ($stats.Count -gt 0) {
                $statsBlock = New-Object Windows.Controls.TextBlock
                $statsBlock.Style = Get-WidgetResource 'WidgetRowText'
                $statsBlock.Text = $stats -join '  |  '
                $dlgState.Adapter.Children.Add($statsBlock) | Out-Null
            }
            $source = [string](Get-DevKitWidgetField $adapter 'Source' '')
            if ($source) {
                $sourceBlock = New-Object Windows.Controls.TextBlock
                $sourceBlock.Style = Get-WidgetResource 'StatusText'
                $sourceBlock.FontSize = 9
                $sourceBlock.Text = "telemetry via $source"
                $dlgState.Adapter.Children.Add($sourceBlock) | Out-Null
            }
        }
        $procList = Get-DevKitWidgetField $Result 'Processes' $null
        if ($procList) {
            $rows = @($procList | Sort-Object { [double](Get-DevKitWidgetField $_ 'GpuPercent' 0) } -Descending)
        }
    } else {
        # Cpu: ProcCpu returns the row array directly. Safe-to-close
        # candidates sort first, then caution, then system - in a 15-row list
        # the badge alone is too easy to skim past.
        if ($Result) {
            $rank = @{ Safe = 0; Caution = 1; System = 2 }
            $rows = @($Result | Sort-Object {
                    $r = $rank[[string](Get-DevKitWidgetField $_ 'Classification' 'Caution')]
                    if ($null -eq $r) { 1 } else { $r }
                }, { -[double](Get-DevKitWidgetField $_ 'CpuPercent' 0) })
        }
    }

    $dlgState.Rows.Children.Clear()
    if ($rows.Count -eq 0) {
        $none = New-Object Windows.Controls.TextBlock
        $none.Style = Get-WidgetResource 'WidgetRowText'
        $none.Foreground = Get-WidgetResource 'BrushTextDim'
        $none.TextWrapping = 'Wrap'
        $none.Text = 'No process data reported.'
        $dlgState.Rows.Children.Add($none) | Out-Null
    } else {
        foreach ($procRow in $rows) {
            $rowName = [string](Get-DevKitWidgetField $procRow 'Name' '?')
            $rowPid = [int](Get-DevKitWidgetField $procRow 'Pid' 0)
            $class = [string](Get-DevKitWidgetField $procRow 'Classification' '')
            if (-not $class) {
                # Rows are documented to carry Classification already; this is
                # the fallback for a partial/older collector. Pure name-based
                # classification - cheap enough to run on the UI thread.
                try { $class = [string](Get-DevKitProcessClassification -Name $rowName) } catch { $class = '' }
                if (-not $class) { $class = 'Caution' }
            }
            $metrics = switch ($Kind) {
                'Cpu' { @(('{0:N1} %' -f [double](Get-DevKitWidgetField $procRow 'CpuPercent' 0)), ('{0:N0} MB' -f [double](Get-DevKitWidgetField $procRow 'MemoryMB' 0))) }
                'Gpu' { @('{0:N1} %' -f [double](Get-DevKitWidgetField $procRow 'GpuPercent' 0)) }
                default { @('{0:N0} MB' -f [double](Get-DevKitWidgetField $procRow 'MemoryMB' 0)) }
            }
            $dlgState.Rows.Children.Add((New-DevKitProcRow -Kind $Kind -Name $rowName -ProcessId $rowPid -MetricTexts $metrics -Classification $class)) | Out-Null
        }
    }
    # The "Loading..." line only applies until the first real render.
    if ($dlgState.Status.Text -eq 'Loading...') { $dlgState.Status.Visibility = 'Collapsed' }
}

function Complete-DevKitProcKill {
    param($Result)
    $ctx = $script:ProcKillContext
    $script:ProcKillContext = $null
    if (-not $ctx) { return }
    if (-not $script:ProcDialogs.Contains($ctx.Kind)) { return }   # panel closed mid-kill: drop
    $dlgState = $script:ProcDialogs[$ctx.Kind]
    $stopped = [bool](Get-DevKitWidgetField $Result 'Stopped' $false)
    $note = [string](Get-DevKitWidgetField $Result 'Note' '')
    if (-not $note) { $note = if ($stopped) { "Stopped $($ctx.Name)." } else { "Could not stop $($ctx.Name) - it may be elevated; restart the widget as administrator." } }
    $dlgState.Status.Text = $note
    $dlgState.Status.Foreground = Get-WidgetResource $(if ($stopped) { 'BrushTextDim' } else { 'BrushAccentEmber' })
    $dlgState.Status.Visibility = 'Visible'
    Request-DevKitProcRefresh -Kind $ctx.Kind   # re-render without the dead process
}

function Complete-DevKitFreeMemory {
    param($Result)
    if (-not $script:ProcDialogs.Contains('Mem')) { return }   # panel closed mid-job: drop
    $dlgState = $script:ProcDialogs['Mem']
    $dlgState.FreeBtn.IsEnabled = $true
    $freed = Get-DevKitWidgetField $Result 'FreedMB' $null
    $trimmed = Get-DevKitWidgetField $Result 'TrimmedProcesses' $null
    if ($null -ne $freed -and $null -ne $trimmed) {
        $dlgState.Status.Text = "Freed $([int][double]$freed) MB across $([int]$trimmed) processes."
    } else {
        $dlgState.Status.Text = [string](Get-DevKitWidgetField $Result 'Note' 'Memory trim finished.')
    }
    $dlgState.Status.Foreground = Get-WidgetResource 'BrushTextDim'
    $dlgState.Status.Visibility = 'Visible'
    Request-DevKitProcRefresh -Kind 'Mem'   # the list's MEM MB column moved
}

function Update-DevKitProcDialogTimeout {
    # Called from Update-DevKitWorkAsyncPoll's 30s timeout branch. Plain
    # refreshes (ProcCpu/ProcMem/ProcGpu) just note it - the panel's timer
    # retries - but a timed-out kill/free-mem must also re-enable its button
    # and clear the kill context, or the panel would look stuck forever.
    param([Parameter(Mandatory = $true)][string]$Kind)
    if ($Kind -eq 'FreeMem') {
        if ($script:ProcDialogs.Contains('Mem')) {
            $dlgState = $script:ProcDialogs['Mem']
            $dlgState.FreeBtn.IsEnabled = $true
            $dlgState.Status.Text = 'Freeing memory timed out - try again.'
            $dlgState.Status.Foreground = Get-WidgetResource 'BrushAccentEmber'
            $dlgState.Status.Visibility = 'Visible'
        }
        return
    }
    if ($Kind -eq 'ProcKill') {
        $ctx = $script:ProcKillContext
        $script:ProcKillContext = $null
        if ($ctx -and $script:ProcDialogs.Contains($ctx.Kind)) {
            $dlgState = $script:ProcDialogs[$ctx.Kind]
            $dlgState.Status.Text = 'Kill timed out - the process may still be running.'
            $dlgState.Status.Foreground = Get-WidgetResource 'BrushAccentEmber'
            $dlgState.Status.Visibility = 'Visible'
        }
        return
    }
    $dlgKind = $Kind.Replace('Proc', '')
    if ($script:ProcDialogs.Contains($dlgKind)) {
        $dlgState = $script:ProcDialogs[$dlgKind]
        $dlgState.Status.Text = 'Collection timed out - retrying...'
        $dlgState.Status.Foreground = Get-WidgetResource 'BrushTextDim'
        $dlgState.Status.Visibility = 'Visible'
    }
}

function Show-DevKitProcessDialog {
    # Gauge-click entry (the name predates the panel model). Toggles that
    # metric's management PANEL: clicking the gauge whose panel is open
    # closes it - the same toggle convention as the side tabs.
    param([Parameter(Mandatory = $true)][ValidateSet('Cpu', 'Mem', 'Gpu')][string]$Kind)
    if ($script:ProcPanelKind -eq $Kind) { Set-DevKitProcPanel -Open $false }
    else { Set-DevKitProcPanel -Kind $Kind -Open $true }
}

function Unregister-DevKitProcPanelState {
    # Stops the panel's 3s refresh timer and drops the kind's render-state
    # registration, so a result arriving afterward is dropped by the render
    # functions (they all no-op when $script:ProcDialogs lacks the kind).
    # Never touches geometry - this is the state/teardown half of closing,
    # shared by Set-DevKitProcPanel's close path and its kind-switch path.
    if (-not $script:ProcPanelKind) { return }
    $kind = $script:ProcPanelKind
    if ($script:ProcDialogs.Contains($kind)) {
        try { $script:ProcDialogs[$kind].Timer.Stop() } catch { }
        $script:ProcDialogs.Remove($kind)
    }
}

function Set-DevKitProcPanel {
    # The CPU/MEM/GPU management panel: one shared carousel flyout (ProcFlyout
    # in the XAML) re-titled and re-populated per metric. Same slide/geometry
    # contract as Set-DevKitGitFlyout (see the long comment there: flag set
    # BEFORE targets are computed, every window target derived from the
    # flag-based target layout), and the same carousel exclusivity - opening
    # it instant-closes whichever carousel flyout is open, but never the
    # independent terminal panel.
    param([ValidateSet('Cpu', 'Mem', 'Gpu')][string]$Kind, [bool]$Open, [switch]$Instant)

    if ($Open) {
        if ($script:ProcPanelKind -eq $Kind) { return }   # already showing this metric
        if ($script:GitFlyoutOpen) { Set-DevKitGitFlyout -Open $false -Instant }
        if ($script:NotesFlyoutOpen) { Set-DevKitNotesFlyout -Open $false -Instant }
        if ($script:FilesFlyoutOpen) { Set-DevKitFilesFlyout -Open $false -Instant }
        if ($script:OnDeckFlyoutOpen) { Set-DevKitOnDeckFlyout -Open $false -Instant }
        # Switching metrics with the panel already open: tear down the old
        # kind's timer/registration first; the panel itself stays put (the
        # width is kind-independent, so the geometry targets don't change).
        if ($script:ProcPanelKind) { Unregister-DevKitProcPanelState }

        $titles = @{ Cpu = 'CPU - TOP PROCESSES'; Mem = 'MEMORY - TOP PROCESSES'; Gpu = 'GPU - USAGE BY PROCESS' }
        $ui.ProcFlyoutTitle.Text = $titles[$Kind]
        $memVisible = if ($Kind -eq 'Mem') { 'Visible' } else { 'Collapsed' }
        $ui.ProcSummaryText.Visibility = $memVisible
        $ui.BtnProcFreeMem.Visibility = $memVisible
        $ui.ProcAdapterPanel.Visibility = if ($Kind -eq 'Gpu') { 'Visible' } else { 'Collapsed' }
        $ui.ProcAdapterPanel.Children.Clear()
        $ui.ProcRowsPanel.Children.Clear()
        $ui.ProcFlyoutStatus.Text = 'Loading...'
        $ui.ProcFlyoutStatus.Foreground = Get-WidgetResource 'BrushTextDim'
        $ui.ProcFlyoutStatus.Visibility = 'Visible'

        $script:GitFlyoutAnimToken++
        $token = $script:GitFlyoutAnimToken
        $script:ProcPanelKind = $Kind   # flag-first, before target computation
        $targetFlyoutWidth = $script:ProcFlyoutWidth
        $targetWindowWidth = $script:WidgetChromeWidth + $script:WidgetContentWidth + (Get-DevKitWidgetPanelExtra)
        $pinnedRight = $window.Left + $window.Width
        $targetLeft = $pinnedRight - $targetWindowWidth

        if ($Instant) {
            $window.BeginAnimation([Windows.Window]::WidthProperty, $null)
            $window.BeginAnimation([Windows.Window]::LeftProperty, $null)
            $ui.ProcFlyout.BeginAnimation([Windows.Controls.Border]::WidthProperty, $null)
            $ui.ProcFlyout.Width = $targetFlyoutWidth
            $window.Width = $targetWindowWidth
            if ($script:DockMode -eq 'Right') { $window.Left = $targetLeft }
        } else {
            Start-DevKitFlyoutSlide -Target $ui.ProcFlyout -Property ([Windows.Controls.Border]::WidthProperty) -To $targetFlyoutWidth -Opening $true -Token $token
            Start-DevKitFlyoutSlide -Target $window -Property ([Windows.Window]::WidthProperty) -To $targetWindowWidth -Opening $true -Token $token
            if ($script:DockMode -eq 'Right') {
                Start-DevKitFlyoutSlide -Target $window -Property ([Windows.Window]::LeftProperty) -To $targetLeft -Opening $true -Token $token
            }
        }
        $ui.ProcFlyoutInner.Width = $script:ProcFlyoutWidth

        # Created WITH the open panel and stopped on close - never an
        # always-on timer. The tick only ASKS for a refresh; collection runs
        # in the work runspace and the result comes back via
        # Update-DevKitWorkAsyncPoll.
        $timer = New-Object Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromSeconds(3)
        $kindCopy = $Kind
        $timer.Add_Tick({ Request-DevKitProcRefresh -Kind $kindCopy }.GetNewClosure())
        # The render-state registry the render/completion functions read. Rows/
        # Status/Summary/Adapter/FreeBtn point at the panel's SHARED XAML
        # elements (Visibility-gated per kind above); there is no per-kind
        # window anymore.
        $script:ProcDialogs[$Kind] = @{
            Rows    = $ui.ProcRowsPanel
            Status  = $ui.ProcFlyoutStatus
            Summary = $ui.ProcSummaryText
            Adapter = $ui.ProcAdapterPanel
            FreeBtn = $ui.BtnProcFreeMem
            Timer   = $timer
        }
        Request-DevKitProcRefresh -Kind $Kind   # first fill right away, not 3s in
        $timer.Start()
        return
    }

    if (-not $script:ProcPanelKind) { return }   # already closed
    Unregister-DevKitProcPanelState

    $script:GitFlyoutAnimToken++
    $token = $script:GitFlyoutAnimToken
    $script:ProcPanelKind = $null   # flag-first, before target computation
    $targetWindowWidth = $script:WidgetChromeWidth + $script:WidgetContentWidth + (Get-DevKitWidgetPanelExtra)
    $pinnedRight = $window.Left + $window.Width
    $targetLeft = $pinnedRight - $targetWindowWidth

    if ($Instant) {
        $window.BeginAnimation([Windows.Window]::WidthProperty, $null)
        $window.BeginAnimation([Windows.Window]::LeftProperty, $null)
        $ui.ProcFlyout.BeginAnimation([Windows.Controls.Border]::WidthProperty, $null)
        $ui.ProcFlyout.Width = 0
        $window.Width = $targetWindowWidth
        if ($script:DockMode -eq 'Right') { $window.Left = $targetLeft }
    } else {
        Start-DevKitFlyoutSlide -Target $ui.ProcFlyout -Property ([Windows.Controls.Border]::WidthProperty) -To 0 -Opening $false -Token $token
        Start-DevKitFlyoutSlide -Target $window -Property ([Windows.Window]::WidthProperty) -To $targetWindowWidth -Opening $false -Token $token
        if ($script:DockMode -eq 'Right') {
            Start-DevKitFlyoutSlide -Target $window -Property ([Windows.Window]::LeftProperty) -To $targetLeft -Opening $false -Token $token
        }
    }
}

$ui.BtnProcClose.Add_Click({ Set-DevKitProcPanel -Open $false })
$ui.BtnProcFreeMem.Add_Click({
    $yes = Show-DevKitWidgetConfirm -Title 'Free Memory' `
        -Message "This trims the working sets of running applications, returning unused memory to Windows.`n`nNo processes are closed - this is safe. Continue?"
    if (-not $yes) { return }
    $ui.BtnProcFreeMem.IsEnabled = $false
    $ui.ProcFlyoutStatus.Text = 'Freeing memory...'
    $ui.ProcFlyoutStatus.Foreground = Get-WidgetResource 'BrushTextDim'
    $ui.ProcFlyoutStatus.Visibility = 'Visible'
    if (-not (Start-DevKitWorkJob -Kind 'FreeMem')) {
        $ui.BtnProcFreeMem.IsEnabled = $true
        $ui.ProcFlyoutStatus.Text = 'Busy - try again in a moment.'
    }
})

# The gauge stacks are clickable (hand cursor + "Click to manage" tooltip set
# in the XAML); children (Path/TextBlock) don't handle clicks, so the press
# bubbles up to the stack. MouseLeftButtonUp (not Down) so a mis-click that
# turns into a drag doesn't fire. Each click TOGGLES that metric's panel.
$ui.CpuGaugeStack.Add_MouseLeftButtonUp({ Show-DevKitProcessDialog -Kind 'Cpu' })
$ui.MemGaugeStack.Add_MouseLeftButtonUp({ Show-DevKitProcessDialog -Kind 'Mem' })
$ui.GpuGaugeStack.Add_MouseLeftButtonUp({ Show-DevKitProcessDialog -Kind 'Gpu' })

# ==================== GITHUB FLYOUT ====================
# Side panel for the active project: branch + ahead/behind, the drawn commit
# graph (lanes + gradient S-curves + ref pills - see Render-DevKitGitGraph),
# fetch/pull/push, open-on-GitHub links, and a shortcut to the real Git
# Cleanup tool. Lives in the shared CAROUSEL root-Grid column (2/west or
# 4/east - the terminal panel has its own outer column) on whichever side
# faces INTO the screen - the opposite of the docked edge - toggled alongside
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

function Get-DevKitFilesFlyoutWidthSetting {
    # preferences.filesFlyoutWidth - same clamp/fallback contract as the Git
    # and Notes flyout widths above, persisted independently so each panel
    # keeps the width the user actually gave it.
    try {
        $w = [double](Get-DevKitSettings).preferences.filesFlyoutWidth
        if ($w -gt 0) { return [math]::Min($script:MaxFlyoutWidth, [math]::Max($script:MinFlyoutWidth, $w)) }
    } catch { }
    return 300
}

function Save-DevKitFilesFlyoutWidthSetting {
    try {
        $settings = Get-DevKitSettings
        $settings.preferences.filesFlyoutWidth = [int][math]::Round($script:FilesFlyoutWidth)
        Set-DevKitSettings -Settings $settings
    } catch { }
}

function Get-DevKitOnDeckFlyoutWidthSetting {
    # preferences.onDeckFlyoutWidth - same clamp/fallback contract as the
    # Git, Notes and Files flyout widths above, persisted independently so
    # each panel keeps the width the user actually gave it.
    try {
        $w = [double](Get-DevKitSettings).preferences.onDeckFlyoutWidth
        if ($w -gt 0) { return [math]::Min($script:MaxFlyoutWidth, [math]::Max($script:MinFlyoutWidth, $w)) }
    } catch { }
    return 300
}

function Save-DevKitOnDeckFlyoutWidthSetting {
    try {
        $settings = Get-DevKitSettings
        $settings.preferences.onDeckFlyoutWidth = [int][math]::Round($script:OnDeckFlyoutWidth)
        Set-DevKitSettings -Settings $settings
    } catch { }
}

function Get-DevKitProcFlyoutWidthSetting {
    # preferences.procFlyoutWidth - the gauge management panel's width; same
    # clamp/fallback contract as the carousel flyout widths above.
    try {
        $w = [double](Get-DevKitSettings).preferences.procFlyoutWidth
        if ($w -gt 0) { return [math]::Min($script:MaxFlyoutWidth, [math]::Max($script:MinFlyoutWidth, $w)) }
    } catch { }
    return 340
}

function Save-DevKitProcFlyoutWidthSetting {
    try {
        $settings = Get-DevKitSettings
        $settings.preferences.procFlyoutWidth = [int][math]::Round($script:ProcFlyoutWidth)
        Set-DevKitSettings -Settings $settings
    } catch { }
}

function Get-DevKitTerminalFlyoutWidthSetting {
    # preferences.terminalFlyoutWidth - the terminal panel's width; same
    # clamp/fallback contract, just a wider default (console output wants
    # more columns than a notes list does).
    try {
        $w = [double](Get-DevKitSettings).preferences.terminalFlyoutWidth
        if ($w -gt 0) { return [math]::Min($script:MaxFlyoutWidth, [math]::Max($script:MinFlyoutWidth, $w)) }
    } catch { }
    return 420
}

function Save-DevKitTerminalFlyoutWidthSetting {
    try {
        $settings = Get-DevKitSettings
        $settings.preferences.terminalFlyoutWidth = [int][math]::Round($script:TermFlyoutWidth)
        Set-DevKitSettings -Settings $settings
    } catch { }
}

$script:FlyoutWidth = Get-DevKitGitFlyoutWidthSetting
$script:GitFlyoutOpen = $false
$script:NotesFlyoutWidth = Get-DevKitNotesFlyoutWidthSetting
$script:NotesFlyoutOpen = $false
$script:FilesFlyoutWidth = Get-DevKitFilesFlyoutWidthSetting
$script:FilesFlyoutOpen = $false
$script:OnDeckFlyoutWidth = Get-DevKitOnDeckFlyoutWidthSetting
$script:OnDeckFlyoutOpen = $false
$script:ProcFlyoutWidth = Get-DevKitProcFlyoutWidthSetting
# Which gauge metric the management panel is currently showing - $null when
# the panel is closed. Doubles as the panel's open flag (it is always set/
# cleared BEFORE window geometry targets are computed - see
# Get-DevKitWidgetPanelExtra for why the target layout is flag-derived).
$script:ProcPanelKind = $null
$script:TermFlyoutWidth = Get-DevKitTerminalFlyoutWidthSetting
$script:TermFlyoutOpen = $false
$script:GitOverview = $null     # last Get-DevKitRepoOverview result
$script:GitRefreshPending = $false   # a GitOverview was declined while the work runspace was busy
$script:EnvDriftRefreshPending = $false   # an EnvDrift check was declined while the work runspace was busy
# Commit graph click-to-expand: the hash whose inline details card is open,
# the last Get-DevKitCommitDetails result (keyed by .Hash), and the re-fire
# flag for a CommitDetails job declined while the work runspace was busy.
$script:GitExpandedCommitHash = $null
$script:GitCommitDetails = $null
$script:GitCommitDetailsPending = $false

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
    # The flyout toggles and the project-scoped quick actions only work with
    # an active project; losing the active project while a carousel flyout is
    # open closes it (and hides the ambient badge / env hint). The TERMINAL
    # tab is deliberately NOT in the disabled set: its panel stays available
    # without a project (commands fall back to the DevKit root, with a note).
    $hasProject = $null -ne $script:ActiveProjectPath
    $ui.BtnGitTab.IsEnabled = $hasProject
    $ui.BtnGitTab.Opacity = if ($hasProject) { 1.0 } else { 0.45 }
    $ui.BtnNotesTab.IsEnabled = $hasProject
    $ui.BtnNotesTab.Opacity = if ($hasProject) { 1.0 } else { 0.45 }
    $ui.BtnFilesTab.IsEnabled = $hasProject
    $ui.BtnFilesTab.Opacity = if ($hasProject) { 1.0 } else { 0.45 }
    $ui.BtnOnDeckTab.IsEnabled = $hasProject
    $ui.BtnOnDeckTab.Opacity = if ($hasProject) { 1.0 } else { 0.45 }
    foreach ($b in @($ui.BtnOpenEditor, $ui.BtnOpenExplorer, $ui.BtnOpenTerminal, $ui.BtnRunScript)) {
        $b.IsEnabled = $hasProject
        $b.Opacity = if ($hasProject) { 1.0 } else { 0.45 }
    }
    # Project changed (or was lost) while the terminal panel is open: re-home
    # it. The terminal never closes on project loss - it is independent of
    # the flyout carousel - it just re-roots to the DevKit root and shows the
    # no-project note. Placed ahead of the no-project early-return below so
    # BOTH paths re-home it.
    if ($script:TermFlyoutOpen) {
        $termRoot = if ($hasProject) { $script:ActiveProjectPath } else { $ScriptDir }
        if ($script:TermCwd -ne $termRoot) { Set-DevKitTermLocation -Note }
    }
    if (-not $hasProject) {
        $ui.GitBadgeText.Visibility = 'Collapsed'
        $ui.EnvDriftRow.Visibility = 'Collapsed'
        if ($script:GitFlyoutOpen) { Set-DevKitGitFlyout -Open $false }
        if ($script:NotesFlyoutOpen) { Set-DevKitNotesFlyout -Open $false }
        if ($script:FilesFlyoutOpen) { Set-DevKitFilesFlyout -Open $false }
        if ($script:OnDeckFlyoutOpen) { Set-DevKitOnDeckFlyout -Open $false }
        return
    }
    # Project changed while the Notes panel is open: flush the old project's
    # pending edits and re-render for the new one (closed panels just reload
    # lazily on their next open).
    if ($script:NotesFlyoutOpen -and $script:NotesProjectPath -ne $script:ActiveProjectPath) {
        Open-DevKitWidgetNotesProject
    }
    # Project changed while the Files panel is open: re-root the tree (and
    # drop the old project's clipboard/expansion state) for the new one.
    if ($script:FilesFlyoutOpen -and $script:FilesProjectPath -ne $script:ActiveProjectPath) {
        Open-DevKitWidgetFilesProject
    }
    # Project changed while the On-Deck panel is open: load the new project's
    # list (closed panels just reload lazily on their next open).
    if ($script:OnDeckFlyoutOpen -and $script:OnDeckProjectPath -ne $script:ActiveProjectPath) {
        Open-DevKitWidgetOnDeckProject
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
    # Only one CAROUSEL flyout at a time (the terminal panel is independent
    # and never closed by this - see Set-DevKitTerminalFlyout). Close-the-other
    # INSTANTLY (not animated): both panels animate window.Width/Left, and two
    # slides in flight would fight over them; the instant close settles the
    # window synchronously before this open computes its own targets.
    if ($Open -and $script:NotesFlyoutOpen) { Set-DevKitNotesFlyout -Open $false -Instant }
    if ($Open -and $script:FilesFlyoutOpen) { Set-DevKitFilesFlyout -Open $false -Instant }
    if ($Open -and $script:OnDeckFlyoutOpen) { Set-DevKitOnDeckFlyout -Open $false -Instant }
    if ($Open -and $script:ProcPanelKind) { Set-DevKitProcPanel -Open $false -Instant }

    # window.Width/Left and the panel's Border.Width are always animated
    # together, in lockstep (same Duration/Easing). The open flag is set
    # BEFORE targets are computed, and every window target is derived from the
    # state flags + width variables (the TARGET layout, via
    # Get-DevKitWidgetPanelExtra), never from live animated values - so a
    # slide that supersedes a still-finishing one (possible now that the
    # independent terminal panel can animate at the same time as a carousel
    # panel) still lands on the correct final geometry: WPF lets the newer
    # BeginAnimation replace the older one per property, and because both
    # chase flag-derived totals, whichever animation wins converges to the
    # same end state.
    $script:GitFlyoutAnimToken++
    $token = $script:GitFlyoutAnimToken
    $script:GitFlyoutOpen = $Open
    $targetFlyoutWidth = if ($Open) { $script:FlyoutWidth } else { 0 }
    $targetWindowWidth = $script:WidgetChromeWidth + $script:WidgetContentWidth + (Get-DevKitWidgetPanelExtra)
    # The window's live RIGHT edge (read BEFORE any BeginAnimation cancel
    # below - canceling reverts to pre-animation base values, so never re-read
    # afterward). Docked right, that edge is pinned to the screen edge: the
    # target Left is whatever keeps Left+Width fixed at it.
    $pinnedRight = $window.Left + $window.Width
    $targetLeft = $pinnedRight - $targetWindowWidth

    if ($Instant) {
        # Snap straight to the final values instead of animating - used by a
        # dock-side switch, which needs the flyout closed and window geometry
        # settled synchronously so its own plain Left/Width reassignment (for
        # the NEW dock side) isn't fought by a live slide still chasing the
        # OLD side's target. Cancel first: the token bump above already makes
        # any in-flight animation's Completed handler a no-op, but the
        # animation itself is still driving these properties every frame
        # until BeginAnimation(..., $null) detaches it.
        $window.BeginAnimation([Windows.Window]::WidthProperty, $null)
        $window.BeginAnimation([Windows.Window]::LeftProperty, $null)
        $ui.GitFlyout.BeginAnimation([Windows.Controls.Border]::WidthProperty, $null)
        $ui.GitFlyout.Width = $targetFlyoutWidth
        $window.Width = $targetWindowWidth
        if ($script:DockMode -eq 'Right') { $window.Left = $targetLeft }
        if ($Open) {
            $ui.GitFlyoutInner.Width = $script:FlyoutWidth
            $ui.BtnGitTab.Foreground = Get-WidgetResource 'BrushAccentBlue'
            $ui.GitFlyoutTitle.Text = [string]$script:ActiveProjectName
            $ui.GitFlyoutStatus.Text = ''
            Set-DevKitGitActiveTab -Tab 'Commits'   # never reopen mid-way through a stale PR/Issues tab
            # Both Commits-tab sections default to EXPANDED on every open. In
            # code, not markup: the theme's Expander template reveals content
            # via the Expanded EVENT's storyboard (ExpandSite starts Collapsed/
            # ScaleY 0), so a markup-initial IsExpanded=True never fires the
            # event and the content stays hidden forever. The flyout's template
            # is long applied by the time it opens, so the toggle works here.
            $ui.UncommittedExpander.IsExpanded = $true
            $ui.CommitGraphExpander.IsExpanded = $true
            Start-DevKitGitRefresh
        } else {
            $ui.BtnGitTab.Foreground = Get-WidgetResource 'BrushTextMuted'
        }
        return
    }

    if ($Open) {
        $ui.GitFlyoutInner.Width = $script:FlyoutWidth
        Start-DevKitFlyoutSlide -Target $ui.GitFlyout -Property ([Windows.Controls.Border]::WidthProperty) -To $targetFlyoutWidth -Opening $true -Token $token
        Start-DevKitFlyoutSlide -Target $window -Property ([Windows.Window]::WidthProperty) -To $targetWindowWidth -Opening $true -Token $token
        if ($script:DockMode -eq 'Right') {
            # Right-docked: the main widget's RIGHT edge is the pinned,
            # docked edge, so the flyout (west carousel slot) must grow the
            # window LEFTWARD - Left slides left as Width grows, keeping
            # Left+Width (the right edge) fixed.
            Start-DevKitFlyoutSlide -Target $window -Property ([Windows.Window]::LeftProperty) -To $targetLeft -Opening $true -Token $token
        }
        # Left-docked: the main widget's LEFT edge is the pinned edge (stays
        # at wa.Left), so the flyout (east carousel slot) just grows the
        # window RIGHTWARD - Width grows, Left is untouched.
        $ui.BtnGitTab.Foreground = Get-WidgetResource 'BrushAccentBlue'
        $ui.GitFlyoutTitle.Text = [string]$script:ActiveProjectName
        $ui.GitFlyoutStatus.Text = ''
        Set-DevKitGitActiveTab -Tab 'Commits'   # never reopen mid-way through a stale PR/Issues tab
        # Both Commits-tab sections default to EXPANDED on every open. In
        # code, not markup: the theme's Expander template reveals content via
        # the Expanded EVENT's storyboard (ExpandSite starts Collapsed/ScaleY
        # 0), so a markup-initial IsExpanded=True never fires the event and
        # the content stays hidden forever. The flyout's template is long
        # applied by the time it opens, so the toggle works here.
        $ui.UncommittedExpander.IsExpanded = $true
        $ui.CommitGraphExpander.IsExpanded = $true
        Start-DevKitGitRefresh
    } else {
        Start-DevKitFlyoutSlide -Target $ui.GitFlyout -Property ([Windows.Controls.Border]::WidthProperty) -To 0 -Opening $false -Token $token
        Start-DevKitFlyoutSlide -Target $window -Property ([Windows.Window]::WidthProperty) -To $targetWindowWidth -Opening $false -Token $token
        if ($script:DockMode -eq 'Right') {
            # Mirror the open-side math: restore the right edge by sliding
            # Left back out by the same amount Width shrinks by.
            Start-DevKitFlyoutSlide -Target $window -Property ([Windows.Window]::LeftProperty) -To $targetLeft -Opening $false -Token $token
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

function Show-DevKitCommitDetails {
    # Commit-row click handler (the graph canvas's per-row hit areas call
    # this): click a commit -> expand its details card inline under the row;
    # click the SAME commit -> collapse; click another -> switch. The fetch
    # ('git show') runs in the shared work runspace as a CommitDetails job;
    # declined-while-busy re-fires from the completion poll via
    # $script:GitCommitDetailsPending, mirroring GitRefreshPending.
    param([Parameter(Mandatory = $true)][string]$Hash)

    if ($script:GitExpandedCommitHash -eq $Hash) {
        $script:GitExpandedCommitHash = $null
        $script:GitCommitDetails = $null
    } else {
        $script:GitExpandedCommitHash = $Hash
        $script:GitCommitDetails = $null   # a stale card for another hash never shows
        if (-not (Start-DevKitWorkJob -Kind 'CommitDetails' -ProjectPath $script:ActiveProjectPath -CommitHash $Hash)) {
            $script:GitCommitDetailsPending = $true
        }
    }
    # Immediate re-render: an expanding row shows its card with a Loading
    # line until the job result lands (Update-DevKitCommitDetails).
    if ($script:GitOverview -and $script:GitOverview.Graph) {
        Render-DevKitGitGraph -Graph $script:GitOverview.Graph
    }
}

function Update-DevKitCommitDetails {
    # CommitDetails job completed (work-poll, UI thread): cache the result
    # and re-render so the expanded row's card swaps Loading -> content.
    # A result whose hash no longer matches the selection (user collapsed or
    # clicked another commit mid-flight) is kept cached but renders nothing.
    param($Result)
    if (-not $Result) { return }
    $script:GitCommitDetails = $Result
    if ($script:GitFlyoutOpen -and $script:GitExpandedCommitHash -and $script:GitOverview -and $script:GitOverview.Graph) {
        Render-DevKitGitGraph -Graph $script:GitOverview.Graph
    }
}

function New-DevKitCommitDetailsCard {
    # Builds the inline card injected under the expanded commit row: full
    # hash, author + commit date, the FULL commit message, and the changed-
    # files summary from the cached Get-DevKitCommitDetails result - or a
    # Loading line while its work-runspace job is still out, or the honest
    # Error line when the commit couldn't be read (e.g. rebased away).
    param([Parameter(Mandatory = $true)][string]$Hash, [double]$Width)

    $card = New-Object Windows.Controls.Border
    $card.Background = Get-WidgetResource 'BrushInputBg'
    $card.BorderBrush = Get-WidgetResource 'BrushCardBorder'
    $card.BorderThickness = [Windows.Thickness]::new(1)
    $card.CornerRadius = [Windows.CornerRadius]::new(6)
    $card.Padding = [Windows.Thickness]::new(10, 7, 10, 8)
    $card.Width = $Width
    $stack = New-Object Windows.Controls.StackPanel
    $card.Child = $stack

    $addLine = {
        param([string]$Text, [double]$Size, $Brush, [bool]$Wrap = $false, [bool]$Mono = $false, [double]$TopMargin = 0)
        $tb = New-Object Windows.Controls.TextBlock
        $tb.FontSize = $Size
        $tb.Foreground = $Brush
        $tb.Text = $Text
        if ($Wrap) { $tb.TextWrapping = 'Wrap' }
        if ($Mono) { $tb.FontFamily = New-Object Windows.Media.FontFamily 'Consolas'; $tb.TextTrimming = 'CharacterEllipsis' }
        if ($TopMargin -gt 0) { $tb.Margin = [Windows.Thickness]::new(0, $TopMargin, 0, 0) }
        $stack.Children.Add($tb) | Out-Null
    }

    $details = $script:GitCommitDetails
    if (-not $details -or [string]$details.Hash -ne $Hash) {
        & $addLine 'Loading commit details...' 10 (Get-WidgetResource 'BrushTextDim')
        return $card
    }
    if (-not $details.Found) {
        & $addLine ([string]$details.Error) 10 (Get-WidgetResource 'BrushAccentEmber') $true
        return $card
    }

    $bright = Get-WidgetResource 'BrushTextBright'
    $dim = Get-WidgetResource 'BrushTextDim'
    & $addLine ([string]$details.Hash) 9.5 $dim $false $true
    $dateText = [string]$details.Date
    try { $dateText = ([datetimeoffset]::Parse([string]$details.Date)).ToString('yyyy-MM-dd HH:mm') } catch { }
    $byline = [string]$details.Author
    if ($details.Email) { $byline += " <$($details.Email)>" }
    if ($dateText) { $byline += "  -  $dateText" }
    & $addLine $byline 9.5 $dim
    if ($details.Message) {
        & $addLine ([string]$details.Message) 10.5 $bright $true $false 6
    }
    # Changed-files summary: a count/+/- header line, then per-file rows
    # (capped - a 500-file squash merge shouldn't bury the graph).
    if ($details.FilesChanged -gt 0 -or @($details.Files).Count -gt 0) {
        $fileWord = if ($details.FilesChanged -eq 1) { 'file' } else { 'files' }
        & $addLine ("{0} {1} changed  (+{2} / -{3})" -f $details.FilesChanged, $fileWord, $details.Insertions, $details.Deletions) 9.5 $dim $false $false 6
        $rows = @($details.Files)
        $cap = 12
        foreach ($f in ($rows | Select-Object -First $cap)) {
            $stat = if ($f.IsBinary) { 'binary' } else { "+$($f.Added)/-$($f.Deleted)" }
            & $addLine ("{0}   {1}" -f $f.Path, $stat) 9 $dim $false $true 1
        }
        if ($rows.Count -gt $cap) { & $addLine ("+{0} more" -f ($rows.Count - $cap)) 9 $dim $false $false 1 }
    }
    return $card
}

function Render-DevKitGitGraph {
    # Draws Get-DevKitRepoOverview's lane layout onto GitGraphCanvas: gradient
    # S-curve links between lanes, bright node dots with a HEAD ring, branch/
    # tag pills, and subject + meta text per commit. Pure render - the layout
    # was computed in the work runspace. When a commit row is selected
    # ($script:GitExpandedCommitHash, toggled by Show-DevKitCommitDetails) an
    # inline details card is injected directly under that row and every row
    # below it shifts down by the card's measured height - lane columns and
    # row pitches are untouched, only Y positions move.
    param([Parameter(Mandatory = $true)]$Graph)

    $canvas = $ui.GitGraphCanvas
    $canvas.Children.Clear()

    $laneDx = 15.0; $rowH = 36.0; $leftPad = 16.0; $topPad = 10.0; $nodeR = 4.5
    $laneCount = [Math]::Max(1, [int]$Graph.LaneCount)
    $textX = $leftPad + ($laneCount * $laneDx) + 6.0

    # Inline commit-details expansion: find the selected commit's node (a
    # selection whose hash fell out of the 40-commit window - refresh after
    # fetch/rebase - is silently dropped, never an error) and pre-measure its
    # card so every Y below can be shifted BEFORE anything is drawn.
    $expandedNode = $null
    if ($script:GitExpandedCommitHash) {
        foreach ($n in $Graph.Nodes) {
            if ([string]$n.Commit.Hash -eq $script:GitExpandedCommitHash) { $expandedNode = $n; break }
        }
        if (-not $expandedNode) {
            $script:GitExpandedCommitHash = $null
            $script:GitCommitDetails = $null
        }
    }
    $detailsCard = $null
    $detailsH = 0.0
    if ($expandedNode) {
        # Card width tracks the flyout, not the (possibly wider) canvas: the
        # graph scrolls horizontally, reading a commit shouldn't.
        $detailsWidth = [Math]::Max(220.0, [double]$ui.GitFlyoutInner.Width - 66.0)
        $detailsCard = New-DevKitCommitDetailsCard -Hash ([string]$expandedNode.Commit.Hash) -Width $detailsWidth
        $detailsCard.Measure((New-Object Windows.Size ($detailsWidth, [double]::PositiveInfinity)))
        $detailsH = [Math]::Ceiling($detailsCard.DesiredSize.Height) + 4.0
    }
    $rowShift = {
        param([int]$Row)
        if ($expandedNode -and $Row -gt $expandedNode.Row) { return $detailsH }
        return 0.0
    }
    # Member enumeration, not Measure-Object -Property: on Windows PowerShell
    # 5.1, -Property can't see hashtable keys (works on pwsh 7) and the
    # terminating error would kill every render on a supported shell.
    $maxRow = ($Graph.Nodes | ForEach-Object Row | Measure-Object -Maximum).Maximum
    $canvas.Width = $textX + 200
    $canvas.Height = $topPad * 2 + ($maxRow + 1) * $rowH + $detailsH

    # Links first so nodes sit on top of the lines.
    foreach ($link in $Graph.Links) {
        $x1 = $leftPad + $link.FromLane * $laneDx
        $y1 = $topPad + $link.FromRow * $rowH + ($rowH / 2) + (& $rowShift ([int]$link.FromRow))
        $x2 = $leftPad + $link.ToLane * $laneDx
        $y2 = $topPad + $link.ToRow * $rowH + ($rowH / 2) + (& $rowShift ([int]$link.ToRow))
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
        $cy = $topPad + $node.Row * $rowH + ($rowH / 2) + (& $rowShift ([int]$node.Row))
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
            $pillContent = New-Object Windows.Controls.StackPanel
            $pillContent.Orientation = 'Horizontal'
            # Small glyph before the pill text: branch / tag / HEAD - frozen
            # shared drawings, same discipline as the Files tree icons.
            $pillIconKey = switch ($ref.Kind) { 'tag' { 'git-tag' } 'head' { 'git-head' } default { 'git-branch' } }
            $pillIcon = New-DevKitIconImage -Key $pillIconKey -Size 9
            $pillIcon.Margin = [Windows.Thickness]::new(0, 0, 3, 0)
            $pillContent.Children.Add($pillIcon) | Out-Null
            $pillText = New-Object Windows.Controls.TextBlock
            $pillText.FontSize = 9
            $pillText.Text = [string]$ref.Name
            $pillText.VerticalAlignment = 'Center'
            $pillContent.Children.Add($pillText) | Out-Null
            if ($ref.Kind -eq 'head') {
                $pill.Background = Get-DevKitGitBrush $refColor
                $pillText.Foreground = $darkBrush
            } else {
                $pill.Background = Get-DevKitGitBrush "#26$($refColor.Substring(1))"
                $pill.BorderBrush = Get-DevKitGitBrush $refColor
                $pill.BorderThickness = [Windows.Thickness]::new(1)
                $pillText.Foreground = Get-DevKitGitBrush $refColor
            }
            $pill.Child = $pillContent
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

    # Clickable row hit areas go in LAST so they sit on top: one transparent
    # rect per commit row spanning the full content width, tagged (via the
    # handler closure) with the commit hash. They carry a hand cursor and the
    # row tooltip (topmost hit wins, so the dots'/pills' own tips under the
    # rect are shadowed - the rect repeats the same text), and clicking one
    # toggles that commit's inline details card. The canvas is rebuilt every
    # render, so handlers attach per render and each closes over its own
    # $hash via GetNewClosure().
    foreach ($node in $Graph.Nodes) {
        $hash = [string]$node.Commit.Hash
        $hit = New-Object Windows.Shapes.Rectangle
        $hit.Width = $neededWidth + 12
        $hit.Height = $rowH
        $hit.Fill = if ($expandedNode -and $node.Row -eq $expandedNode.Row) { Get-DevKitGitBrush '#1AFFFFFF' } else { [Windows.Media.Brushes]::Transparent }
        $hit.Cursor = [Windows.Input.Cursors]::Hand
        $hitCommit = $node.Commit
        $hit.ToolTip = "$($hitCommit.Subject)`n$($hitCommit.ShortHash)  -  $($hitCommit.Author), $($hitCommit.When)`nClick for commit details"
        [Windows.Controls.Canvas]::SetLeft($hit, 0)
        [Windows.Controls.Canvas]::SetTop($hit, $topPad + $node.Row * $rowH + (& $rowShift ([int]$node.Row)))
        $hit.Add_MouseLeftButtonUp({ Show-DevKitCommitDetails -Hash $hash }.GetNewClosure())
        $canvas.Children.Add($hit) | Out-Null
    }

    # The expanded commit's details card slots into the gap the row shift
    # opened up, directly under its row.
    if ($detailsCard) {
        [Windows.Controls.Canvas]::SetLeft($detailsCard, $leftPad)
        [Windows.Controls.Canvas]::SetTop($detailsCard, $topPad + ($expandedNode.Row + 1) * $rowH)
        $canvas.Children.Add($detailsCard) | Out-Null
    }
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
# PR/issue accordion lists via Add-DevKitPrRow / Add-DevKitIssueAccordion.
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
    # One collapsed-by-default Expander per PR - the SAME accordion treatment
    # as the Issues tab (Add-DevKitIssueAccordion): the shared Expander
    # ControlTemplate in Theme.xaml gives the header-click behavior, chevron
    # and fade/unfold animation for free. Header = "#N  Title" (ellipsis) +
    # draft/review badges; Content = the author/branches/updated meta line +
    # an Open-on-GitHub button (the issue accordion's safe Start-Process
    # pattern - the header itself now expands/collapses instead of opening
    # the browser, which is what the whole row used to do on click).
    param($Panel, $Pr)

    $expander = New-Object Windows.Controls.Expander
    $expander.IsExpanded = $false
    $expander.Margin = '0,0,0,8'
    $expander.ToolTip = 'Click to expand or collapse'

    $headerGrid = New-Object Windows.Controls.Grid
    $colTitle = New-Object Windows.Controls.ColumnDefinition; $colTitle.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
    $colBadges = New-Object Windows.Controls.ColumnDefinition; $colBadges.Width = [Windows.GridLength]::Auto
    $headerGrid.ColumnDefinitions.Add($colTitle)
    $headerGrid.ColumnDefinitions.Add($colBadges)

    $titleText = New-Object Windows.Controls.TextBlock
    $titleText.Style = Get-WidgetResource 'WidgetExpanderTitle'
    $titleText.Text = "#$($Pr.number)  $($Pr.title)"
    $titleText.TextTrimming = 'CharacterEllipsis'
    $titleText.ToolTip = [string]$Pr.title
    [Windows.Controls.Grid]::SetColumn($titleText, 0)
    $headerGrid.Children.Add($titleText) | Out-Null

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
    $headerGrid.Children.Add($badgePanel) | Out-Null
    $expander.Header = $headerGrid

    $content = New-Object Windows.Controls.StackPanel

    $sub = New-Object Windows.Controls.TextBlock
    $sub.Style = Get-WidgetResource 'WidgetExpanderSub'
    $sub.Margin = 0
    $sub.TextWrapping = 'Wrap'
    $author = if ($Pr.author -and $Pr.author.login) { [string]$Pr.author.login } else { 'unknown' }
    $subParts = @("by $author", "$($Pr.headRefName) -> $($Pr.baseRefName)")
    $when = Format-DevKitRelativeTime -Iso ([string]$Pr.updatedAt)
    if ($when) { $subParts += "updated $when" }
    $sub.Text = ($subParts -join '  |  ')
    $content.Children.Add($sub) | Out-Null

    $openBtn = New-Object Windows.Controls.Button
    $openBtn.Style = Get-WidgetResource 'GhostButton'
    $openBtn.FontSize = 10.5
    $openBtn.Content = 'Open on GitHub'
    $openBtn.HorizontalAlignment = 'Left'
    $openBtn.Margin = '0,8,0,0'
    $prUrl = [string]$Pr.url
    $openBtn.Add_Click({ Open-DevKitExternalUrl -Url $prUrl }.GetNewClosure())
    $content.Children.Add($openBtn) | Out-Null

    $expander.Content = $content
    $Panel.Children.Add($expander) | Out-Null
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
    # Full render: one collapsed-by-default Add-DevKitPrRow accordion per open
    # PR (same Expander treatment as the issue accordions), or the
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
        $ui.CommitGraphCountBadgeText.Text = '0'
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
        $ui.CommitGraphCountBadgeText.Text = '0'
        & $showText $(if ($Overview.GraphSkipped -and $script:GitFlyoutOpen) { 'Loading commit graph...' } else { 'No commits yet.' }) 'BrushTextDim'
        return
    }
    $ui.CommitGraphCountBadgeText.Text = [string]@($Overview.Graph.Nodes).Count
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
# -Kind), since the four side panels are mutually exclusive by design.
#
# Note lifecycle: a note is either an EXPANDED editor (the one note whose Id
# is $script:ExpandedNoteId - tinted card with the multiline TextBox) or a
# COLLAPSED title card (default; one line, ellipsis, title derived from the
# body's first line by Get-DevKitNoteTitle - the on-disk schema is unchanged,
# so older widget builds read the same notes.json and nothing migrates).
# Clicking a card expands it; saving (the Done button) or clicking/focusing
# away collapses it back. Every note renders collapsed when the flyout opens.

$script:ActiveNotes = @()            # live note objects bound to the rendered cards
$script:NotesProjectPath = $null     # the project the CURRENT cards belong to
$script:NotesDirty = $false
$script:ExpandedNoteId = $null       # the one note currently open for editing ($null = all collapsed)
$script:ExpandedNoteCard = $null     # its live card Border (click-outside detection)

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
    # render the active project's notes. Every note starts COLLAPSED (title
    # card) on (re)load - the flyout never reopens mid-edit.
    Save-DevKitWidgetNotesFlush
    $script:NotesProjectPath = $script:ActiveProjectPath
    $script:ActiveNotes = @(Get-DevKitProjectNotes -ProjectPath $script:NotesProjectPath)
    $script:NotesDirty = $false
    $script:ExpandedNoteId = $null
    $script:ExpandedNoteCard = $null
    $ui.NotesFlyoutSub.Text = [string]$script:ActiveProjectName
    Update-DevKitWidgetNotesPanel
}

function Update-DevKitWidgetNotesPanel {
    $ui.NotesPanel.Children.Clear()
    $script:ExpandedNoteCard = $null   # rebuilt below if a note is expanded
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

function Test-DevKitWidgetWithin {
    # True when $Source is $Ancestor itself or sits anywhere under it. Walks
    # the visual tree first and falls back to the logical tree (some event
    # sources are not Visuals). Used to tell "clicked/focused inside this
    # card" from "clicked away from it" - a plain Border is not focusable,
    # so focus events alone can't answer that.
    param($Ancestor, $Source)
    $cur = $Source
    while ($null -ne $cur) {
        if ($cur -eq $Ancestor) { return $true }
        $parent = $null
        if ($cur -is [System.Windows.Media.Visual]) {
            try { $parent = [System.Windows.Media.VisualTreeHelper]::GetParent($cur) } catch { }
        }
        if ($null -eq $parent) {
            try { $parent = [System.Windows.LogicalTreeHelper]::GetParent($cur) } catch { }
        }
        if ($parent -eq $cur) { return $false }   # paranoia: never loop on a self-parent
        $cur = $parent
    }
    return $false
}

function Open-DevKitWidgetNoteEditor {
    # Expands one note into its editor (collapsing whichever note was open -
    # its pending debounced edits are flushed first). Re-renders the panel
    # and focuses the fresh TextBox (the expanded card's Tag).
    param([Parameter(Mandatory = $true)][string]$NoteId)
    if ($script:ExpandedNoteId -eq $NoteId) { return }
    Save-DevKitWidgetNotesFlush
    $script:ExpandedNoteId = $NoteId
    Update-DevKitWidgetNotesPanel
    foreach ($child in @($ui.NotesPanel.Children)) {
        if ($child.Tag -is [Windows.Controls.TextBox]) {
            try {
                $child.Tag.Focus() | Out-Null
                $child.Tag.CaretIndex = $child.Tag.Text.Length
            } catch { }
            break
        }
    }
}

function Close-DevKitWidgetNoteEditor {
    # Collapses the open editor back to its title card, flushing any
    # still-debounced edits first (this IS the note's "save" - typing only
    # arms the 800ms autosave).
    if (-not $script:ExpandedNoteId) { return }
    Save-DevKitWidgetNotesFlush
    $script:ExpandedNoteId = $null
    $script:ExpandedNoteCard = $null
    Update-DevKitWidgetNotesPanel
}

function Close-DevKitWidgetNoteEditorIfOutside {
    # The editor TextBox's LostFocus handler: collapses the editor only when
    # keyboard focus actually moved OUTSIDE its card (clicking the card's
    # own Done/delete moves focus within the card and must not collapse it
    # out from under the click). Focus has already settled when LostFocus
    # fires, so Keyboard.FocusedElement is the NEW element here.
    param($Card, [Parameter(Mandatory = $true)][string]$NoteId)
    if ($script:ExpandedNoteId -ne $NoteId) { return }
    $focused = [System.Windows.Input.Keyboard]::FocusedElement
    if ($null -ne $focused -and (Test-DevKitWidgetWithin -Ancestor $Card -Source $focused)) { return }
    Close-DevKitWidgetNoteEditor
}

function New-DevKitNoteDeleteButton {
    # The shared two-step delete ('x' -> 'sure?' for 3s -> gone), used by
    # both the collapsed title card and the expanded editor - lighter than a
    # modal popup but still a guard against a stray click. The revert timer
    # is per-button; the token-free Tag flag is enough state because a
    # re-render rebuilds the card (and its state) from scratch anyway.
    # The Click closure captures $Note/$del/$revert via .GetNewClosure() and
    # only CALLS functions for shared state - see Request-DevKitNotesAutosave
    # for why a closure must never touch $script: directly.
    param([Parameter(Mandatory = $true)]$Note)

    $del = New-Object Windows.Controls.Button
    $del.Style = Get-WidgetResource 'ChromeButton'
    $del.FontFamily = New-Object Windows.Media.FontFamily('Segoe MDL2 Assets')
    $del.FontSize = 9
    $del.Content = [char]0xE106
    $del.MinWidth = 24
    $del.Height = 18
    $del.HorizontalAlignment = 'Right'
    $del.VerticalAlignment = 'Center'
    $del.Margin = '0,0,4,0'
    $del.ToolTip = 'Delete this note'
    $del.Tag = $false   # $true while in the 'sure?' confirm window
    [System.Windows.Automation.AutomationProperties]::SetAutomationId($del, "NoteDelete_$($Note.Id)")

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
    return $del
}

function New-DevKitNoteCard {
    # One sticky note, in one of two shapes:
    #  - COLLAPSED (the default): a compact card showing just the note's
    #    title - the first body line via Get-DevKitNoteTitle, single line
    #    with ellipsis - plus the same two-step delete the editor has.
    #    Clicking the card expands it into the editor.
    #  - EXPANDED (only the note whose Id is $script:ExpandedNoteId): the
    #    full editor - borderless multiline TextBox with debounced autosave,
    #    a footer with the last-edited time, a Done button (flush + collapse)
    #    and the two-step delete. Clicking/focusing away collapses it (see
    #    Close-DevKitWidgetNoteEditorIfOutside and the flyout-level
    #    PreviewMouseLeftButtonDown handler).
    # Returns the card Border; an EXPANDED card's .Tag is its TextBox (used
    # to focus a freshly added/opened note), a collapsed card's .Tag is $null.
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

    if ($script:ExpandedNoteId -ne $Note.Id) {
        # ---- Collapsed title card ----
        $row = New-Object Windows.Controls.Grid
        [Windows.Controls.Grid]::SetColumn($row, 1)
        $rc0 = New-Object Windows.Controls.ColumnDefinition
        $rc1 = New-Object Windows.Controls.ColumnDefinition; $rc1.Width = 'Auto'
        $row.ColumnDefinitions.Add($rc0); $row.ColumnDefinitions.Add($rc1)

        $title = New-Object Windows.Controls.TextBlock
        $title.Text = Get-DevKitNoteTitle -Text ([string]$Note.Text)
        $title.Foreground = Get-WidgetResource 'BrushTextBright'
        $title.FontSize = 11.5
        $title.TextTrimming = 'CharacterEllipsis'
        $title.VerticalAlignment = 'Center'
        $title.Margin = '8,7'
        $title.ToolTip = 'Click to edit this note'
        $row.Children.Add($title) | Out-Null

        $delCollapsed = New-DevKitNoteDeleteButton -Note $Note
        [Windows.Controls.Grid]::SetColumn($delCollapsed, 1)
        $row.Children.Add($delCollapsed) | Out-Null

        $grid.Children.Add($row) | Out-Null
        $card.Child = $grid
        $card.Tag = $null
        $card.Cursor = [System.Windows.Input.Cursors]::Hand
        $card.ToolTip = 'Click to edit this note'
        # Expand on click - but NOT when the click landed on the delete
        # button (bubbling would otherwise expand as the note is deleted).
        $card.Add_MouseLeftButtonUp({
            param($s, $e)
            if (Test-DevKitWidgetWithin -Ancestor $delCollapsed -Source $e.OriginalSource) { return }
            Open-DevKitWidgetNoteEditor -NoteId $Note.Id
        }.GetNewClosure())
        return $card
    }

    # ---- Expanded editor ----
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

    $footerButtons = New-Object Windows.Controls.StackPanel
    $footerButtons.Orientation = 'Horizontal'
    $footerButtons.HorizontalAlignment = 'Right'
    $footerButtons.Margin = '0,0,4,4'

    $done = New-Object Windows.Controls.Button
    $done.Style = Get-WidgetResource 'GhostButton'
    $done.FontSize = 9.5
    $done.Padding = '6,1'
    $done.Content = 'Done'
    $done.VerticalAlignment = 'Center'
    $done.Margin = '0,0,6,0'
    $done.ToolTip = 'Save and collapse this note'
    $done.Add_Click({ Close-DevKitWidgetNoteEditor })
    $footerButtons.Children.Add($done) | Out-Null

    $del = New-DevKitNoteDeleteButton -Note $Note
    $del.Margin = '0'
    $footerButtons.Children.Add($del) | Out-Null

    $footer.Children.Add($footerButtons) | Out-Null
    $body.Children.Add($footer) | Out-Null

    $grid.Children.Add($body) | Out-Null
    $card.Child = $grid
    $card.Tag = $tb
    $script:ExpandedNoteCard = $card

    $tb.Add_TextChanged({
        $Note.Text = $tb.Text
        $Note.UpdatedAt = [DateTime]::UtcNow.ToString('o')
        $edited.Text = 'edited just now'
        Request-DevKitNotesAutosave   # NOT inline $script: sets - see the function's comment
    }.GetNewClosure())
    # Clicked/focused away -> collapse back to the title card (function call,
    # never inline $script: state, same closure rule as above).
    $tb.Add_LostFocus({
        Close-DevKitWidgetNoteEditorIfOutside -Card $card -NoteId $Note.Id
    }.GetNewClosure())
    # Escape saves + collapses too.
    $tb.Add_KeyDown({
        param($s, $e)
        if ($e.Key -eq 'Escape') { Close-DevKitWidgetNoteEditor }
    })

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
    # Newest on top, like a fresh sticky slapped over the pile. A new note
    # opens straight into its editor (every other note is a collapsed card).
    $script:ActiveNotes = @($note) + @($script:ActiveNotes)
    $script:ExpandedNoteId = $note.Id
    $script:NotesDirty = $true
    Save-DevKitWidgetNotesFlush
    Update-DevKitWidgetNotesPanel
    try { $ui.NotesPanel.Children[0].Tag.Focus() | Out-Null } catch { }
}

function Remove-DevKitWidgetNote {
    param([Parameter(Mandatory = $true)]$Note)
    if ($script:ExpandedNoteId -eq $Note.Id) {
        $script:ExpandedNoteId = $null
        $script:ExpandedNoteCard = $null
    }
    $script:ActiveNotes = @($script:ActiveNotes | Where-Object { $_.Id -ne $Note.Id })
    $script:NotesDirty = $true
    Save-DevKitWidgetNotesFlush
    Update-DevKitWidgetNotesPanel
}

function Set-DevKitNotesFlyout {
    param([bool]$Open, [switch]$Instant)
    if ($Open -eq $script:NotesFlyoutOpen) { return }
    if ($Open -and -not $script:ActiveProjectPath) { return }
    # Only one CAROUSEL flyout at a time - mirror of the guard in
    # Set-DevKitGitFlyout (see the comment there for why the close is
    # -Instant, and why the terminal panel is deliberately NOT in this list).
    if ($Open -and $script:GitFlyoutOpen) { Set-DevKitGitFlyout -Open $false -Instant }
    if ($Open -and $script:FilesFlyoutOpen) { Set-DevKitFilesFlyout -Open $false -Instant }
    if ($Open -and $script:OnDeckFlyoutOpen) { Set-DevKitOnDeckFlyout -Open $false -Instant }
    if ($Open -and $script:ProcPanelKind) { Set-DevKitProcPanel -Open $false -Instant }

    # Same lockstep window/flyout animation contract as Set-DevKitGitFlyout
    # (see the long comment there - flag set BEFORE target computation, all
    # window targets derived from the flag-based target layout so overlapping
    # slides still converge). All panels share one anim token: a toggle of
    # any one must stale-out another's pending Completed handlers.
    $script:GitFlyoutAnimToken++
    $token = $script:GitFlyoutAnimToken
    $script:NotesFlyoutOpen = $Open
    $targetFlyoutWidth = if ($Open) { $script:NotesFlyoutWidth } else { 0 }
    $targetWindowWidth = $script:WidgetChromeWidth + $script:WidgetContentWidth + (Get-DevKitWidgetPanelExtra)
    $pinnedRight = $window.Left + $window.Width
    $targetLeft = $pinnedRight - $targetWindowWidth

    if ($Instant) {
        $window.BeginAnimation([Windows.Window]::WidthProperty, $null)
        $window.BeginAnimation([Windows.Window]::LeftProperty, $null)
        $ui.NotesFlyout.BeginAnimation([Windows.Controls.Border]::WidthProperty, $null)
        $ui.NotesFlyout.Width = $targetFlyoutWidth
        $window.Width = $targetWindowWidth
        if ($script:DockMode -eq 'Right') { $window.Left = $targetLeft }
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
        $ui.NotesFlyoutInner.Width = $script:NotesFlyoutWidth
        Start-DevKitFlyoutSlide -Target $ui.NotesFlyout -Property ([Windows.Controls.Border]::WidthProperty) -To $targetFlyoutWidth -Opening $true -Token $token
        Start-DevKitFlyoutSlide -Target $window -Property ([Windows.Window]::WidthProperty) -To $targetWindowWidth -Opening $true -Token $token
        if ($script:DockMode -eq 'Right') {
            # Right-docked: pinned right edge, window grows leftward - same
            # Left+Width lockstep as the Git flyout's open path.
            Start-DevKitFlyoutSlide -Target $window -Property ([Windows.Window]::LeftProperty) -To $targetLeft -Opening $true -Token $token
        }
        $ui.BtnNotesTab.Foreground = Get-DevKitGitBrush '#E5C07B'
        Open-DevKitWidgetNotesProject
    } else {
        Start-DevKitFlyoutSlide -Target $ui.NotesFlyout -Property ([Windows.Controls.Border]::WidthProperty) -To 0 -Opening $false -Token $token
        Start-DevKitFlyoutSlide -Target $window -Property ([Windows.Window]::WidthProperty) -To $targetWindowWidth -Opening $false -Token $token
        if ($script:DockMode -eq 'Right') {
            Start-DevKitFlyoutSlide -Target $window -Property ([Windows.Window]::LeftProperty) -To $targetLeft -Opening $false -Token $token
        }
        $ui.BtnNotesTab.Foreground = Get-WidgetResource 'BrushTextMuted'
        Save-DevKitWidgetNotesFlush
    }
}

$ui.BtnNotesTab.Add_Click({ Set-DevKitNotesFlyout -Open (-not $script:NotesFlyoutOpen) })
$ui.BtnNotesClose.Add_Click({ Set-DevKitNotesFlyout -Open $false })
$ui.BtnNoteAdd.Add_Click({ Add-DevKitWidgetNote })
# Click-away collapse for the open note editor: a Border isn't focusable, so
# clicking a collapsed card or dead space never raises LostFocus on the
# editor - catch the mouse-down at the flyout root instead (Preview* fires
# before the click lands, so the collapse/re-render can't eat the click: the
# collapsed card under the cursor is only rebuilt afterwards, and a click on
# the editor's own card is inside it and ignored).
$ui.NotesFlyoutInner.Add_PreviewMouseLeftButtonDown({
    param($s, $e)
    if (-not $script:ExpandedNoteId -or -not $script:ExpandedNoteCard) { return }
    if (Test-DevKitWidgetWithin -Ancestor $script:ExpandedNoteCard -Source $e.OriginalSource) { return }
    Close-DevKitWidgetNoteEditor
})

# ==================== FILES FLYOUT (PROJECT FILE EXPLORER) ====================
# A mini VS Code-style explorer for the active project's root folder, behind
# the FILES pull-tab under NOTES. The tree lazy-loads one directory level per
# expansion (Get-DevKitDirChildren, DevKit-WidgetCore.ps1) via a dummy child
# that is replaced on first expand - nothing ever auto-recurses. Expansion
# state is a live set of root-relative paths so a rebuild keeps the same
# folders open; EVERY open of the panel re-enumerates from disk through that
# rebuild (same path as the Refresh button), so the tree never shows a stale
# snapshot cached from before the panel was closed. Cut/Copy/Paste are an
# INTERNAL clipboard (no Windows file-clipboard interop); Delete goes to the
# Recycle Bin behind the styled confirm dialog; every mutating op re-validates
# containment with Test-DevKitPathWithinRoot. Panel slide/geometry reuses the
# Git/Notes machinery wholesale (shared Start-DevKitFlyoutSlide, shared anim
# token, shared grip handlers routed by -Kind 'Files').

# Recycle-Bin deletes (Microsoft.VisualBasic.FileIO) - load once, best effort.
try { Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop } catch { }

$script:FilesProjectPath = $null        # the project folder the CURRENT tree belongs to
$script:FilesExpandedPaths = @{}        # root-relative path ('' = root) -> $true
$script:FilesClipboard = $null          # @{ Paths = @(...); Cut = $bool } - internal only
$script:FilesCutPaths = @{}             # full paths currently shown dimmed (pending cut)
$script:FilesSelectedItem = $null       # last selected TreeViewItem

function Set-DevKitFilesStatus {
    # The flyout's status line - same contract as the Git flyout's: dim for
    # routine info, ember for failures.
    param([string]$Text, [bool]$IsError = $false)
    $ui.FilesFlyoutStatus.Text = $Text
    $ui.FilesFlyoutStatus.Foreground = Get-WidgetResource $(if ($IsError) { 'BrushAccentEmber' } else { 'BrushTextDim' })
}

function Test-DevKitFilesNodeInfo {
    # True when a tree item's Tag is a real file/folder entry (dummy placeholder
    # and "access denied" nodes carry no FullName and fail every file op).
    param($Info)
    return ($null -ne $Info -and $Info.PSObject.Properties['FullName'] -and -not [string]::IsNullOrEmpty($Info.FullName))
}

function Test-DevKitFilesIsRootInfo {
    # The project root node itself: no Rename/Delete/Cut - those would rip the
    # ground out from under the whole tree.
    param($Info)
    if (-not (Test-DevKitFilesNodeInfo -Info $Info) -or -not $script:FilesProjectPath) { return $false }
    try {
        return [IO.Path]::GetFullPath($Info.FullName).TrimEnd('\').Equals(
            [IO.Path]::GetFullPath($script:FilesProjectPath).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}

function Get-DevKitFilesItemRelPath {
    param($Info)
    if (-not (Test-DevKitFilesNodeInfo -Info $Info) -or -not $script:FilesProjectPath) { return $null }
    return Get-DevKitRelativePath -Root $script:FilesProjectPath -Path $Info.FullName
}

function Get-DevKitFilesTargetFolder {
    # Where a toolbar create/paste lands: the selected folder, the selected
    # file's parent folder, or the project root when nothing usable is selected.
    $info = $null
    if ($script:FilesSelectedItem) { $info = $script:FilesSelectedItem.Tag }
    if (Test-DevKitFilesNodeInfo -Info $info) {
        if ($info.IsDirectory) { return $info.FullName }
        return Split-Path -Parent $info.FullName
    }
    return $script:FilesProjectPath
}

function Get-DevKitFilesInfoTargetFolder {
    # 'Here' for a right-clicked item: the folder itself, or the file's parent.
    param($Info)
    if (Test-DevKitFilesNodeInfo -Info $Info) {
        if ($Info.IsDirectory) { return $Info.FullName }
        return Split-Path -Parent $Info.FullName
    }
    return $script:FilesProjectPath
}

function New-DevKitFilesTreeItem {
    # One tree node: a type icon (frozen shared DrawingImage - see
    # gui/DevKit-WidgetIcons.ps1) + name header, Tag carrying the
    # path info the shared (capture-free) event handlers act on. Folders get a
    # single dummy child so a closed folder still shows an expander arrow; the
    # real children are enumerated on first expand and cached in the item.
    param([Parameter(Mandatory = $true)]$Entry)
    $info = [PSCustomObject]@{
        Name        = [string]$Entry.Name
        FullName    = [string]$Entry.FullName
        IsDirectory = [bool]$Entry.IsDirectory
        Loaded      = $false
    }
    $item = New-Object Windows.Controls.TreeViewItem
    $item.Style = Get-WidgetResource 'FilesTreeViewItem'

    $header = New-Object Windows.Controls.StackPanel
    $header.Orientation = 'Horizontal'
    # The icon Image is always header.Children[0] - the expand/collapse
    # handlers swap its Source between the frozen 'folder'/'folder-open'
    # drawings (a pointer swap, no allocation).
    $iconKey = (Get-DevKitFileIconInfo -Name $info.Name -IsFolder:$info.IsDirectory).Key
    $icon = New-DevKitIconImage -Key $iconKey -Size 14
    $icon.Margin = [Windows.Thickness]::new(0, 0, 5, 0)
    $header.Children.Add($icon) | Out-Null
    $label = New-Object Windows.Controls.TextBlock
    $label.Text = $info.Name
    $label.Foreground = Get-WidgetResource 'BrushTextBright'
    $label.VerticalAlignment = 'Center'
    $header.Children.Add($label) | Out-Null
    $item.Header = $header
    $item.ToolTip = $info.FullName
    $item.Tag = $info
    # A rebuilt tree re-applies the dimmed look for paths still pending a cut.
    if ($script:FilesCutPaths.ContainsKey($info.FullName)) { $item.Opacity = 0.5 }

    if ($info.IsDirectory) {
        $dummy = New-Object Windows.Controls.TreeViewItem
        $dummy.Header = '...'
        $dummy.Foreground = Get-WidgetResource 'BrushTextDim'
        $dummy.Tag = [PSCustomObject]@{ IsDummy = $true }
        $item.Items.Add($dummy) | Out-Null
    }

    $item.ContextMenu = New-DevKitFilesItemMenu -Info $info
    # These handlers capture NO locals (everything routes through $s.Tag and
    # function calls), so they deliberately do NOT use .GetNewClosure() - a
    # closure would rebind $script: to a dead dynamic module (see the notes
    # autosave comment for that trap).
    $item.Add_Expanded({ param($s, $e) $e.Handled = $true; Expand-DevKitFilesTreeItem -Item $s })
    $item.Add_Collapsed({ param($s, $e) $e.Handled = $true; Remove-DevKitFilesExpansion -Item $s })
    $item.Add_MouseDoubleClick({ param($s, $e)
        # Clicks landing on the expander arrow are its own business.
        if ($e.OriginalSource -is [Windows.Controls.Primitives.ToggleButton]) { return }
        $e.Handled = $true
        Invoke-DevKitFilesItemDefault -Item $s
    })
    $item.Add_PreviewMouseRightButtonDown({ param($s, $e) $s.IsSelected = $true })
    return $item
}

function Expand-DevKitFilesTreeItem {
    # First-expand lazy load: swap the dummy child for the directory's real
    # entries (one level only). Enumeration errors degrade to a greyed
    # "access denied" node - never a throw.
    param([Parameter(Mandatory = $true)]$Item)
    $info = $Item.Tag
    if (-not (Test-DevKitFilesNodeInfo -Info $info)) { return }
    if (-not $info.IsDirectory) { return }
    $rel = Get-DevKitFilesItemRelPath -Info $info
    if ($null -ne $rel) { $script:FilesExpandedPaths[$rel] = $true }
    # Folder closed -> open icon (frozen-source pointer swap, no allocation).
    if ($Item.Header -is [Windows.Controls.StackPanel] -and $Item.Header.Children.Count -gt 0) {
        $Item.Header.Children[0].Source = Get-DevKitIconDrawing -Key 'folder-open'
    }
    if ($info.Loaded) { return }
    $Item.Items.Clear()
    $info.Loaded = $true
    $result = Get-DevKitDirChildren -Path $info.FullName
    if ($result.Error) {
        $errItem = New-Object Windows.Controls.TreeViewItem
        $errItem.Header = "(access denied)"
        $errItem.Foreground = Get-WidgetResource 'BrushTextDim'
        $errItem.Tag = [PSCustomObject]@{ IsError = $true }
        $Item.Items.Add($errItem) | Out-Null
        Set-DevKitFilesStatus "Cannot list $($info.Name): $($result.Error)" -IsError $true
        return
    }
    foreach ($child in $result.Children) {
        $Item.Items.Add((New-DevKitFilesTreeItem -Entry $child)) | Out-Null
    }
}

function Remove-DevKitFilesExpansion {
    # Collapsed handler: drop the folder from the expansion set. Descendants
    # keep their entries so re-expanding restores the whole branch.
    param([Parameter(Mandatory = $true)]$Item)
    $info = $Item.Tag
    if (-not (Test-DevKitFilesNodeInfo -Info $info)) { return }
    $rel = Get-DevKitFilesItemRelPath -Info $info
    if ($null -ne $rel -and $script:FilesExpandedPaths.ContainsKey($rel)) {
        $script:FilesExpandedPaths.Remove($rel)
    }
    # Folder open -> closed icon (frozen-source pointer swap).
    if ($info.IsDirectory -and $Item.Header -is [Windows.Controls.StackPanel] -and $Item.Header.Children.Count -gt 0) {
        $Item.Header.Children[0].Source = Get-DevKitIconDrawing -Key 'folder'
    }
}

function Restore-DevKitFilesExpansion {
    # After a rebuild, re-expand (which lazy-loads, synchronously) every folder
    # still in the expansion set, breadth-first so freshly loaded levels get
    # their own chance to restore.
    param([Parameter(Mandatory = $true)]$Item)
    $queue = New-Object System.Collections.Generic.Queue[object]
    $queue.Enqueue($Item)
    while ($queue.Count -gt 0) {
        $cur = $queue.Dequeue()
        foreach ($child in @($cur.Items)) {
            $info = $child.Tag
            if (-not (Test-DevKitFilesNodeInfo -Info $info)) { continue }
            if (-not $info.IsDirectory) { continue }
            $rel = Get-DevKitFilesItemRelPath -Info $info
            if ($null -ne $rel -and $script:FilesExpandedPaths.ContainsKey($rel)) {
                if (-not $child.IsExpanded) { $child.IsExpanded = $true }
                $queue.Enqueue($child)
            }
        }
    }
}

function Update-DevKitFilesTree {
    # Full rebuild of the visible tree from disk, preserving the expansion set
    # (maintained live by the Expanded/Collapsed handlers). Refresh, project
    # switch, and every mutating op funnel through here.
    $ui.FilesTree.Items.Clear()
    $script:FilesSelectedItem = $null
    if (-not $script:FilesProjectPath) {
        $ui.FilesEmptyText.Text = 'Link a project to browse files'
        $ui.FilesEmptyText.Visibility = 'Visible'
        return
    }
    if (-not (Test-Path -LiteralPath $script:FilesProjectPath -PathType Container)) {
        $ui.FilesEmptyText.Text = "Project folder not found:`n$script:FilesProjectPath"
        $ui.FilesEmptyText.Visibility = 'Visible'
        return
    }
    $ui.FilesEmptyText.Visibility = 'Collapsed'
    $rootEntry = [PSCustomObject]@{
        Name        = Split-Path ($script:FilesProjectPath.TrimEnd('\')) -Leaf
        FullName    = $script:FilesProjectPath
        IsDirectory = $true
    }
    $rootItem = New-DevKitFilesTreeItem -Entry $rootEntry
    $ui.FilesTree.Items.Add($rootItem) | Out-Null
    $script:FilesExpandedPaths[''] = $true
    $rootItem.IsExpanded = $true   # fires Expanded -> loads the top level
    Restore-DevKitFilesExpansion -Item $rootItem
}

function Open-DevKitWidgetFilesProject {
    # (Re)roots the tree on the active project, dropping the previous
    # project's clipboard/cut marks and expansion state with it.
    $script:FilesProjectPath = $script:ActiveProjectPath
    $script:FilesClipboard = $null
    $script:FilesCutPaths = @{}
    $script:FilesExpandedPaths = @{}
    $ui.FilesFlyoutSub.Text = [string]$script:ActiveProjectName
    $ui.FilesFlyoutSub.ToolTip = [string]$script:ActiveProjectPath
    Set-DevKitFilesStatus ''
    Update-DevKitFilesTree
}

function Find-DevKitFilesTreeItem {
    # Locates the TreeViewItem for a full path among the currently loaded
    # (i.e. visible-or-previously-expanded) nodes; $null when it was never
    # expanded into existence.
    param([Parameter(Mandatory = $true)][string]$FullName)
    $queue = New-Object System.Collections.Generic.Queue[object]
    foreach ($root in @($ui.FilesTree.Items)) { $queue.Enqueue($root) }
    while ($queue.Count -gt 0) {
        $cur = $queue.Dequeue()
        $info = $cur.Tag
        if ((Test-DevKitFilesNodeInfo -Info $info) -and $info.FullName -ieq $FullName) { return $cur }
        foreach ($child in @($cur.Items)) { $queue.Enqueue($child) }
    }
    return $null
}

function Invoke-DevKitFilesItemDefault {
    # Double-click / context "Open": folders toggle expansion, files open with
    # the shell default association.
    param([Parameter(Mandatory = $true)]$Item)
    $info = $Item.Tag
    if (-not (Test-DevKitFilesNodeInfo -Info $info)) { return }
    if ($info.IsDirectory) {
        $Item.IsExpanded = -not $Item.IsExpanded
        return
    }
    try {
        Start-Process -FilePath $info.FullName
    } catch {
        Set-DevKitFilesStatus "Could not open $($info.Name): $($_.Exception.Message)" -IsError $true
    }
}

function Invoke-DevKitFilesExplorerSelect {
    # 'Open in Explorer' - Explorer window with the item pre-selected.
    param([Parameter(Mandatory = $true)]$Info)
    if (-not (Test-DevKitFilesNodeInfo -Info $Info)) { return }
    try {
        Start-Process 'explorer.exe' -ArgumentList "/select,`"$($Info.FullName)`""
    } catch {
        Set-DevKitFilesStatus "Could not open Explorer: $($_.Exception.Message)" -IsError $true
    }
}

function Open-DevKitWidgetEditorPath {
    # 'Open in Editor' from the Files flyout. Folders go through the real
    # Code-Here tool (exactly like the Editor quick action); files launch the
    # detected editor directly with the file path - Code-Here only accepts
    # directories and would flash a terminal for nothing.
    param([Parameter(Mandatory = $true)]$Info)
    if (-not (Test-DevKitFilesNodeInfo -Info $Info)) { return }
    if ($Info.IsDirectory) {
        Start-DevKitWidgetTool -RelativeScript 'workflow\Code-Here.ps1' -Arguments @{ Path = $Info.FullName } -Title 'Open in Editor'
        return
    }
    $editor = Get-DevKitWindowsExecutable -Name 'code'
    if (-not $editor) {
        # Mirror workflow/Code-Here.ps1's Cursor fallback locations.
        foreach ($candidate in @(
            (Join-Path $env:LOCALAPPDATA 'Programs\cursor\resources\app\bin\cursor.cmd'),
            (Join-Path $env:LOCALAPPDATA 'Programs\cursor\bin\cursor.cmd'),
            (Join-Path $env:LOCALAPPDATA 'Programs\cursor\Cursor.exe'))) {
            if (Test-Path $candidate) { $editor = @{ Source = $candidate }; break }
        }
    }
    if (-not $editor) {
        Set-DevKitFilesStatus 'No editor found (expected VS Code or Cursor).' -IsError $true
        return
    }
    try {
        Start-Process -FilePath $editor.Source -ArgumentList (Format-DevKitShellArgument -Value $Info.FullName)
    } catch {
        Set-DevKitFilesStatus "Could not launch the editor: $($_.Exception.Message)" -IsError $true
    }
}

function Set-DevKitFilesClipboard {
    # Internal Copy/Cut. Cut dims the item until the paste lands or Esc cancels.
    param([Parameter(Mandatory = $true)]$Info, [switch]$Cut)
    if (-not (Test-DevKitFilesNodeInfo -Info $Info)) { return }
    Clear-DevKitFilesCutMarks
    $script:FilesClipboard = @{ Paths = @($Info.FullName); Cut = [bool]$Cut }
    if ($Cut) {
        $script:FilesCutPaths[$Info.FullName] = $true
        $it = Find-DevKitFilesTreeItem -FullName $Info.FullName
        if ($it) { $it.Opacity = 0.5 }
        Set-DevKitFilesStatus "Cut $($Info.Name) - right-click a folder and Paste (Esc cancels)."
    } else {
        Set-DevKitFilesStatus "Copied $($Info.Name)."
    }
}

function Clear-DevKitFilesCutMarks {
    foreach ($p in @($script:FilesCutPaths.Keys)) {
        $it = Find-DevKitFilesTreeItem -FullName $p
        if ($it) { $it.Opacity = 1.0 }
    }
    $script:FilesCutPaths = @{}
}

function Invoke-DevKitFilesPaste {
    # Paste the internal clipboard into $TargetDir: Copy duplicates, Cut moves
    # (once - the clipboard clears after a successful cut-paste, like Explorer).
    # Name collisions get Explorer's ' - Copy' suffix via Get-DevKitCopyName.
    param([Parameter(Mandatory = $true)][string]$TargetDir)
    if (-not $script:FilesProjectPath) { return }
    if (-not $script:FilesClipboard -or @($script:FilesClipboard.Paths).Count -eq 0) {
        Set-DevKitFilesStatus 'Nothing to paste - Copy or Cut an item first.'
        return
    }
    if (-not (Test-DevKitPathWithinRoot -Root $script:FilesProjectPath -Path $TargetDir)) {
        Set-DevKitFilesStatus 'Paste target is outside the project - refused.' -IsError $true
        return
    }
    if (-not (Test-Path -LiteralPath $TargetDir -PathType Container)) {
        Set-DevKitFilesStatus 'Paste target folder no longer exists.' -IsError $true
        return
    }
    $cut = [bool]$script:FilesClipboard.Cut
    $done = 0
    foreach ($src in @($script:FilesClipboard.Paths)) {
        if (-not (Test-DevKitPathWithinRoot -Root $script:FilesProjectPath -Path $src)) { continue }
        if (-not (Test-Path -LiteralPath $src)) {
            Set-DevKitFilesStatus "No longer exists: $(Split-Path $src -Leaf)" -IsError $true
            continue
        }
        $srcIsDir = Test-Path -LiteralPath $src -PathType Container
        # Never paste a folder into itself or its own descendant (a copy would
        # recurse forever, a move would be nonsensical).
        if ($srcIsDir -and (Test-DevKitPathWithinRoot -Root $src -Path $TargetDir)) {
            Set-DevKitFilesStatus "Cannot paste '$(Split-Path $src -Leaf)' into itself." -IsError $true
            continue
        }
        if ($cut -and ((Split-Path -Parent $src).TrimEnd('\') -ieq $TargetDir.TrimEnd('\'))) {
            # Cut + Paste into the item's own folder is a no-op, like Explorer.
            continue
        }
        $leaf = Split-Path $src -Leaf
        $destName = Get-DevKitCopyName -Folder $TargetDir -Name $leaf -IsDirectory:$srcIsDir
        $dest = Join-Path $TargetDir $destName
        try {
            if ($cut) {
                Move-Item -LiteralPath $src -Destination $dest -ErrorAction Stop
            } else {
                Copy-Item -LiteralPath $src -Destination $dest -Recurse -ErrorAction Stop
            }
            $done++
        } catch {
            Set-DevKitFilesStatus "Paste failed for $($leaf): $($_.Exception.Message)" -IsError $true
        }
    }
    if ($cut -and $done -gt 0) {
        $script:FilesClipboard = $null
        $script:FilesCutPaths = @{}
    }
    # Reveal the paste target after the rebuild.
    $rel = Get-DevKitRelativePath -Root $script:FilesProjectPath -Path $TargetDir
    if ($null -ne $rel) { $script:FilesExpandedPaths[$rel] = $true }
    Update-DevKitFilesTree
    if ($done -gt 0) { Set-DevKitFilesStatus "Pasted $done item$(if ($done -ne 1) { 's' })." }
}

function Invoke-DevKitFilesNew {
    # Toolbar '+ File'/'+ Folder' and the context menu's 'New ... Here'.
    param(
        [Parameter(Mandatory = $true)][ValidateSet('File', 'Folder')][string]$Kind,
        [Parameter(Mandatory = $true)][string]$TargetDir
    )
    if (-not $script:FilesProjectPath) { return }
    if (-not (Test-DevKitPathWithinRoot -Root $script:FilesProjectPath -Path $TargetDir)) {
        Set-DevKitFilesStatus 'Target is outside the project - refused.' -IsError $true
        return
    }
    $name = Show-DevKitWidgetTextInput -Title "New $Kind" -Label "$Kind name (created inside the selected folder):"
    if ($null -eq $name) { return }   # cancelled (validation happens in the dialog)
    $dest = Join-Path $TargetDir $name
    if (Test-Path -LiteralPath $dest) {
        Set-DevKitFilesStatus "'$name' already exists there." -IsError $true
        return
    }
    try {
        if ($Kind -eq 'File') {
            New-Item -ItemType File -Path $dest -ErrorAction Stop | Out-Null
        } else {
            New-Item -ItemType Directory -Path $dest -ErrorAction Stop | Out-Null
        }
    } catch {
        Set-DevKitFilesStatus "Could not create $($Kind.ToLower()): $($_.Exception.Message)" -IsError $true
        return
    }
    $rel = Get-DevKitRelativePath -Root $script:FilesProjectPath -Path $TargetDir
    if ($null -ne $rel) { $script:FilesExpandedPaths[$rel] = $true }
    Update-DevKitFilesTree
    Set-DevKitFilesStatus "Created $name."
}

function Invoke-DevKitFilesRename {
    param([Parameter(Mandatory = $true)]$Info)
    if (-not (Test-DevKitFilesNodeInfo -Info $Info)) { return }
    if (Test-DevKitFilesIsRootInfo -Info $Info) {
        Set-DevKitFilesStatus 'The project root cannot be renamed here.' -IsError $true
        return
    }
    $newName = Show-DevKitWidgetTextInput -Title 'Rename' -Label "New name for '$($Info.Name)':" -Initial $Info.Name
    if ($null -eq $newName -or $newName -ceq $Info.Name) { return }
    $parent = Split-Path -Parent $Info.FullName
    $dest = Join-Path $parent $newName
    # A case-only rename (Foo.txt -> foo.txt) targets the same file - allowed.
    if ((Test-Path -LiteralPath $dest) -and ($dest -ine $Info.FullName)) {
        Set-DevKitFilesStatus "'$newName' already exists there." -IsError $true
        return
    }
    try {
        Move-Item -LiteralPath $Info.FullName -Destination $dest -ErrorAction Stop
    } catch {
        Set-DevKitFilesStatus "Rename failed: $($_.Exception.Message)" -IsError $true
        return
    }
    Update-DevKitFilesTree
    Set-DevKitFilesStatus "Renamed to $newName."
}

function Invoke-DevKitFilesDelete {
    # Recycle Bin only, behind the styled confirm - never a hard delete.
    param([Parameter(Mandatory = $true)]$Info)
    if (-not (Test-DevKitFilesNodeInfo -Info $Info)) { return }
    if (Test-DevKitFilesIsRootInfo -Info $Info) {
        Set-DevKitFilesStatus 'The project root cannot be deleted here.' -IsError $true
        return
    }
    $kind = if ($Info.IsDirectory) { 'folder' } else { 'file' }
    $yes = Show-DevKitWidgetConfirm -Title "Delete $kind" -Message "Move '$($Info.Name)' to the Recycle Bin?"
    if (-not $yes) { return }
    try {
        if ($Info.IsDirectory) {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($Info.FullName,
                [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
        } else {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($Info.FullName,
                [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
        }
    } catch {
        Set-DevKitFilesStatus "Delete failed: $($_.Exception.Message)" -IsError $true
        return
    }
    # Drop the deleted folder (and anything under it) from the expansion set.
    $rel = Get-DevKitFilesItemRelPath -Info $Info
    if ($null -ne $rel -and $Info.IsDirectory) {
        foreach ($k in @($script:FilesExpandedPaths.Keys)) {
            if ($k -eq $rel -or $k.StartsWith($rel + '\', [StringComparison]::OrdinalIgnoreCase)) {
                $script:FilesExpandedPaths.Remove($k)
            }
        }
    }
    Update-DevKitFilesTree
    Set-DevKitFilesStatus "Moved $($Info.Name) to the Recycle Bin."
}

function Copy-DevKitFilesPath {
    # 'Copy Full Path' / 'Copy Relative Path' - plain text to the Windows
    # clipboard (the file clipboard itself stays internal by design).
    param([Parameter(Mandatory = $true)]$Info, [switch]$Relative)
    if (-not (Test-DevKitFilesNodeInfo -Info $Info)) { return }
    $text = $Info.FullName
    if ($Relative) {
        $rel = Get-DevKitFilesItemRelPath -Info $Info
        if ($null -eq $rel) {
            Set-DevKitFilesStatus 'Not inside the project root.' -IsError $true
            return
        }
        $text = if ($rel -eq '') { '.' } else { $rel }
    }
    try {
        [Windows.Clipboard]::SetText($text)
        Set-DevKitFilesStatus "Copied: $text"
    } catch {
        Set-DevKitFilesStatus "Clipboard error: $($_.Exception.Message)" -IsError $true
    }
}

function Collapse-DevKitFilesTree {
    # Fold every folder except the root (which IS the project). Children of a
    # collapsing parent keep IsExpanded=true while hidden, so this walks the
    # whole loaded tree rather than just the visible frontier.
    $script:FilesExpandedPaths = @{}
    $queue = New-Object System.Collections.Generic.Queue[object]
    foreach ($root in @($ui.FilesTree.Items)) { $queue.Enqueue($root) }
    $isRoot = $true
    while ($queue.Count -gt 0) {
        $cur = $queue.Dequeue()
        foreach ($child in @($cur.Items)) { $queue.Enqueue($child) }
        if ($isRoot) { $isRoot = $false; continue }
        if ($cur.IsExpanded) { $cur.IsExpanded = $false }
    }
    $script:FilesExpandedPaths[''] = $true
    Set-DevKitFilesStatus 'Collapsed all folders.'
}

function Add-DevKitFilesMenuItem {
    # One MenuItem in a Files context menu. The $Action scriptblock must stay
    # capture-free - it receives the entry info back via $s.Tag, so no
    # .GetNewClosure() is needed (or wanted - see New-DevKitFilesTreeItem).
    param($Menu, [string]$Header, [scriptblock]$Action, [bool]$Enabled = $true, $Tag = $null)
    $mi = New-Object Windows.Controls.MenuItem
    $mi.Header = $Header
    $mi.Tag = $Tag
    if (-not $Enabled) { $mi.IsEnabled = $false }
    if ($null -ne $Action) { $mi.Add_Click($Action) }
    $Menu.Items.Add($mi) | Out-Null
}

function New-DevKitFilesItemMenu {
    # Right-click menu for a file/folder node. Rebuilt per node creation; the
    # project root gets Copy/Open entries only (no Cut/Rename/Delete).
    param([Parameter(Mandatory = $true)]$Info)
    $isRoot = Test-DevKitFilesIsRootInfo -Info $Info
    $menu = New-Object Windows.Controls.ContextMenu
    $menu.Style = Get-WidgetResource 'FilesContextMenu'
    Add-DevKitFilesMenuItem $menu 'Open' { param($s, $e) Invoke-DevKitFilesContextOpen -Info $s.Tag } -Tag $Info
    Add-DevKitFilesMenuItem $menu 'Open in Explorer' { param($s, $e) Invoke-DevKitFilesExplorerSelect -Info $s.Tag } -Tag $Info
    Add-DevKitFilesMenuItem $menu 'Open in Editor' { param($s, $e) Open-DevKitWidgetEditorPath -Info $s.Tag } -Tag $Info
    $menu.Items.Add((New-Object Windows.Controls.Separator)) | Out-Null
    Add-DevKitFilesMenuItem $menu 'Copy' { param($s, $e) Set-DevKitFilesClipboard -Info $s.Tag } -Tag $Info -Enabled (-not $isRoot)
    Add-DevKitFilesMenuItem $menu 'Cut' { param($s, $e) Set-DevKitFilesClipboard -Info $s.Tag -Cut } -Tag $Info -Enabled (-not $isRoot)
    Add-DevKitFilesMenuItem $menu 'Paste' { param($s, $e) Invoke-DevKitFilesPaste -TargetDir (Get-DevKitFilesInfoTargetFolder -Info $s.Tag) } -Tag $Info
    $menu.Items.Add((New-Object Windows.Controls.Separator)) | Out-Null
    Add-DevKitFilesMenuItem $menu 'New File Here' { param($s, $e) Invoke-DevKitFilesNew -Kind 'File' -TargetDir (Get-DevKitFilesInfoTargetFolder -Info $s.Tag) } -Tag $Info
    Add-DevKitFilesMenuItem $menu 'New Folder Here' { param($s, $e) Invoke-DevKitFilesNew -Kind 'Folder' -TargetDir (Get-DevKitFilesInfoTargetFolder -Info $s.Tag) } -Tag $Info
    $menu.Items.Add((New-Object Windows.Controls.Separator)) | Out-Null
    Add-DevKitFilesMenuItem $menu 'Rename...' { param($s, $e) Invoke-DevKitFilesRename -Info $s.Tag } -Tag $Info -Enabled (-not $isRoot)
    Add-DevKitFilesMenuItem $menu 'Delete' { param($s, $e) Invoke-DevKitFilesDelete -Info $s.Tag } -Tag $Info -Enabled (-not $isRoot)
    $menu.Items.Add((New-Object Windows.Controls.Separator)) | Out-Null
    Add-DevKitFilesMenuItem $menu 'Copy Full Path' { param($s, $e) Copy-DevKitFilesPath -Info $s.Tag } -Tag $Info
    Add-DevKitFilesMenuItem $menu 'Copy Relative Path' { param($s, $e) Copy-DevKitFilesPath -Info $s.Tag -Relative } -Tag $Info
    return $menu
}

function Invoke-DevKitFilesContextOpen {
    # 'Open' from a context menu (only the path info is at hand, so the item
    # is located by path for the folder-toggle case).
    param([Parameter(Mandatory = $true)]$Info)
    if (-not (Test-DevKitFilesNodeInfo -Info $Info)) { return }
    $it = Find-DevKitFilesTreeItem -FullName $Info.FullName
    if ($it) { Invoke-DevKitFilesItemDefault -Item $it }
}

function Set-DevKitFilesFlyout {
    param([bool]$Open, [switch]$Instant)
    if ($Open -eq $script:FilesFlyoutOpen) { return }
    if ($Open -and -not $script:ActiveProjectPath) { return }
    # Only one CAROUSEL flyout at a time - mirror of the guard in
    # Set-DevKitGitFlyout (see the comment there for why the close is
    # -Instant, and why the terminal panel is deliberately NOT in this list).
    if ($Open -and $script:GitFlyoutOpen) { Set-DevKitGitFlyout -Open $false -Instant }
    if ($Open -and $script:NotesFlyoutOpen) { Set-DevKitNotesFlyout -Open $false -Instant }
    if ($Open -and $script:OnDeckFlyoutOpen) { Set-DevKitOnDeckFlyout -Open $false -Instant }
    if ($Open -and $script:ProcPanelKind) { Set-DevKitProcPanel -Open $false -Instant }

    # Same lockstep window/flyout animation contract as Set-DevKitGitFlyout
    # (see the long comment there - flag set BEFORE target computation, all
    # window targets derived from the flag-based target layout so overlapping
    # slides still converge). All panels share one anim token.
    $script:GitFlyoutAnimToken++
    $token = $script:GitFlyoutAnimToken
    $script:FilesFlyoutOpen = $Open
    $targetFlyoutWidth = if ($Open) { $script:FilesFlyoutWidth } else { 0 }
    $targetWindowWidth = $script:WidgetChromeWidth + $script:WidgetContentWidth + (Get-DevKitWidgetPanelExtra)
    $pinnedRight = $window.Left + $window.Width
    $targetLeft = $pinnedRight - $targetWindowWidth

    if ($Instant) {
        $window.BeginAnimation([Windows.Window]::WidthProperty, $null)
        $window.BeginAnimation([Windows.Window]::LeftProperty, $null)
        $ui.FilesFlyout.BeginAnimation([Windows.Controls.Border]::WidthProperty, $null)
        $ui.FilesFlyout.Width = $targetFlyoutWidth
        $window.Width = $targetWindowWidth
        if ($script:DockMode -eq 'Right') { $window.Left = $targetLeft }
        if ($Open) {
            $ui.FilesFlyoutInner.Width = $script:FilesFlyoutWidth
            $ui.BtnFilesTab.Foreground = Get-DevKitGitBrush '#98C379'
            if ($script:FilesProjectPath -ne $script:ActiveProjectPath) {
                Open-DevKitWidgetFilesProject
            } else {
                # Every open re-enumerates from disk (same rescan the Refresh
                # button performs) - the tree never serves a stale snapshot
                # from before the panel was closed. The expansion set is
                # live, so expanded folders survive the rebuild.
                Update-DevKitFilesTree
            }
        } else {
            $ui.BtnFilesTab.Foreground = Get-WidgetResource 'BrushTextMuted'
        }
        return
    }

    if ($Open) {
        $ui.FilesFlyoutInner.Width = $script:FilesFlyoutWidth
        Start-DevKitFlyoutSlide -Target $ui.FilesFlyout -Property ([Windows.Controls.Border]::WidthProperty) -To $targetFlyoutWidth -Opening $true -Token $token
        Start-DevKitFlyoutSlide -Target $window -Property ([Windows.Window]::WidthProperty) -To $targetWindowWidth -Opening $true -Token $token
        if ($script:DockMode -eq 'Right') {
            # Right-docked: pinned right edge, window grows leftward - same
            # Left+Width lockstep as the Git flyout's open path.
            Start-DevKitFlyoutSlide -Target $window -Property ([Windows.Window]::LeftProperty) -To $targetLeft -Opening $true -Token $token
        }
        $ui.BtnFilesTab.Foreground = Get-DevKitGitBrush '#98C379'
        if ($script:FilesProjectPath -ne $script:ActiveProjectPath) {
            Open-DevKitWidgetFilesProject
        } else {
            # Same rescan-on-open as the -Instant path above: reopening the
            # panel for the SAME project re-enumerates from disk instead of
            # keeping the cached tree; expanded folders are restored.
            Update-DevKitFilesTree
        }
    } else {
        Start-DevKitFlyoutSlide -Target $ui.FilesFlyout -Property ([Windows.Controls.Border]::WidthProperty) -To 0 -Opening $false -Token $token
        Start-DevKitFlyoutSlide -Target $window -Property ([Windows.Window]::WidthProperty) -To $targetWindowWidth -Opening $false -Token $token
        if ($script:DockMode -eq 'Right') {
            Start-DevKitFlyoutSlide -Target $window -Property ([Windows.Window]::LeftProperty) -To $targetLeft -Opening $false -Token $token
        }
        $ui.BtnFilesTab.Foreground = Get-WidgetResource 'BrushTextMuted'
    }
}

$ui.BtnFilesTab.Add_Click({ Set-DevKitFilesFlyout -Open (-not $script:FilesFlyoutOpen) })
$ui.BtnFilesClose.Add_Click({ Set-DevKitFilesFlyout -Open $false })
$ui.BtnFileNew.Add_Click({ Invoke-DevKitFilesNew -Kind 'File' -TargetDir (Get-DevKitFilesTargetFolder) })
$ui.BtnFolderNew.Add_Click({ Invoke-DevKitFilesNew -Kind 'Folder' -TargetDir (Get-DevKitFilesTargetFolder) })
$ui.BtnFilesRefresh.Add_Click({ Update-DevKitFilesTree; Set-DevKitFilesStatus 'Refreshed.' })
$ui.BtnFilesCollapse.Add_Click({ Collapse-DevKitFilesTree })

$ui.FilesTree.Add_SelectedItemChanged({ param($s, $e) $script:FilesSelectedItem = $e.NewValue })
# Esc cancels a pending cut (clears the internal clipboard + the dimmed look).
$ui.FilesTree.Add_KeyDown({
    param($s, $e)
    if ($e.Key -eq 'Escape' -and $script:FilesClipboard) {
        Clear-DevKitFilesCutMarks
        $script:FilesClipboard = $null
        Set-DevKitFilesStatus 'Clipboard cleared.'
    }
})
# Right-click on empty background (below the last item): project-level menu.
$filesBgMenu = New-Object Windows.Controls.ContextMenu
$filesBgMenu.Style = Get-WidgetResource 'FilesContextMenu'
Add-DevKitFilesMenuItem $filesBgMenu 'Refresh' { param($s, $e) Update-DevKitFilesTree; Set-DevKitFilesStatus 'Refreshed.' }
Add-DevKitFilesMenuItem $filesBgMenu 'New File' { param($s, $e) Invoke-DevKitFilesNew -Kind 'File' -TargetDir $script:FilesProjectPath }
Add-DevKitFilesMenuItem $filesBgMenu 'New Folder' { param($s, $e) Invoke-DevKitFilesNew -Kind 'Folder' -TargetDir $script:FilesProjectPath }
Add-DevKitFilesMenuItem $filesBgMenu 'Paste' { param($s, $e) Invoke-DevKitFilesPaste -TargetDir $script:FilesProjectPath }
Add-DevKitFilesMenuItem $filesBgMenu 'Copy Project Path' { param($s, $e)
    try {
        [Windows.Clipboard]::SetText([string]$script:FilesProjectPath)
        Set-DevKitFilesStatus 'Project path copied.'
    } catch {
        Set-DevKitFilesStatus "Clipboard error: $($_.Exception.Message)" -IsError $true
    }
}
$ui.FilesTree.ContextMenu = $filesBgMenu

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

# ==================== ON-DECK FLYOUT (PER-PROJECT TO-DO LIST) ====================
# A three-section to-do list (NOT STARTED / IN PROGRESS / DONE) scoped to the
# active project, behind the ON DECK pull-tab under FILES. Persistence is
# Get/Save-DevKitProjectOnDeck (DevKit-WidgetCore.ps1, ondeck.json in
# %LOCALAPPDATA%) - the same per-project keying and forgiving load/save
# posture as the notes store. Mutations (add/delete/status change/clear
# done) are discrete user actions, so they save IMMEDIATELY - no debounce
# like the notes' per-keystroke autosave needs. The stored list is always
# kept section-grouped (Group-DevKitOnDeckItems), so a status change moves
# the item to its new section with no manual reordering. Panel slide/
# geometry reuses the Git/Notes/Files machinery wholesale (shared
# Start-DevKitFlyoutSlide, shared anim token, shared grip handlers routed by
# -Kind 'OnDeck').

$script:OnDeckItems = @()              # live item objects behind the rendered rows
$script:OnDeckProjectPath = $null      # the project the CURRENT list belongs to

function Save-DevKitWidgetOnDeck {
    # Persists the CURRENT list to the project it belongs to - called after
    # every mutation, never just on close.
    if (-not $script:OnDeckProjectPath) { return }
    try { Save-DevKitProjectOnDeck -ProjectPath $script:OnDeckProjectPath -Items @($script:OnDeckItems) } catch { }
}

function Open-DevKitWidgetOnDeckProject {
    # Loads and renders the active project's on-deck list (a corrupt/missing
    # store just reads as empty - Get-DevKitProjectOnDeck never throws).
    $script:OnDeckProjectPath = $script:ActiveProjectPath
    $script:OnDeckItems = @(Get-DevKitProjectOnDeck -ProjectPath $script:OnDeckProjectPath)
    $ui.OnDeckFlyoutSub.Text = [string]$script:ActiveProjectName
    Update-DevKitWidgetOnDeckPanel
}

function Get-DevKitOnDeckNextStatus {
    # The cycle button's rotation: notStarted -> inProgress -> done -> ...
    param([string]$Status)
    switch (Get-DevKitOnDeckStatus -Status $Status) {
        'notStarted' { return 'inProgress' }
        'inProgress' { return 'done' }
        default      { return 'notStarted' }
    }
}

function Get-DevKitOnDeckStatusLabel {
    param([string]$Status)
    switch (Get-DevKitOnDeckStatus -Status $Status) {
        'notStarted' { return 'Not Started' }
        'inProgress' { return 'In Progress' }
        default      { return 'Done' }
    }
}

function Add-DevKitWidgetOnDeckItem {
    # Add-row (button or Enter): new items land at the top of NOT STARTED.
    if (-not $script:OnDeckProjectPath) { return }
    $text = [string]$ui.OnDeckNewText.Text
    if ([string]::IsNullOrWhiteSpace($text)) { return }
    $script:OnDeckItems = @(Add-DevKitOnDeckItem -Items $script:OnDeckItems -Text $text)
    $ui.OnDeckNewText.Text = ''
    Save-DevKitWidgetOnDeck
    Update-DevKitWidgetOnDeckPanel
    try { $ui.OnDeckNewText.Focus() | Out-Null } catch { }
}

function Remove-DevKitWidgetOnDeckItem {
    # Immediate delete (a list, not files - no recycle bin); reachability is
    # guarded by the delete being a deliberate click on the row's own small
    # x button or context-menu entry, never a plain row click.
    param([Parameter(Mandatory = $true)]$Item)
    $script:OnDeckItems = @(Remove-DevKitOnDeckItem -Items $script:OnDeckItems -Id ([string]$Item.Id))
    Save-DevKitWidgetOnDeck
    Update-DevKitWidgetOnDeckPanel
}

function Set-DevKitWidgetOnDeckItemStatus {
    # Cycle button / context-menu status change: the core helper returns the
    # regrouped list, so the row lands in its new section on the re-render.
    param([Parameter(Mandatory = $true)]$Item, [Parameter(Mandatory = $true)][string]$Status)
    $script:OnDeckItems = @(Set-DevKitOnDeckItemStatus -Items $script:OnDeckItems -Id ([string]$Item.Id) -Status $Status)
    Save-DevKitWidgetOnDeck
    Update-DevKitWidgetOnDeckPanel
}

function Clear-DevKitWidgetOnDeckDone {
    $script:OnDeckItems = @(Clear-DevKitOnDeckDone -Items $script:OnDeckItems)
    Save-DevKitWidgetOnDeck
    Update-DevKitWidgetOnDeckPanel
}

function New-DevKitOnDeckItemRow {
    # One to-do row: a status cycle button (glyph colored by state, click
    # rotates notStarted -> inProgress -> done), the item text (dimmed +
    # strikethrough when done), and a small x delete (single deliberate
    # click). The right-click menu (Files flyout's context-menu styling)
    # offers the three statuses explicitly - the current one disabled - plus
    # Delete. Menu state travels via MenuItem.Tag and the Click handlers are
    # capture-free (the Files flyout's documented pattern); the row's own
    # buttons capture $Item via .GetNewClosure() and only CALL functions for
    # shared state (see Request-DevKitNotesAutosave for why).
    param([Parameter(Mandatory = $true)]$Item)

    $status = Get-DevKitOnDeckStatus -Status ([string]$Item.Status)
    $isDone = ($status -eq 'done')

    $card = New-Object Windows.Controls.Border
    $card.Background = Get-WidgetResource 'BrushInputBg'
    $card.BorderBrush = Get-WidgetResource 'BrushCardBorder'
    $card.BorderThickness = 1
    $card.CornerRadius = 6
    $card.Padding = '6,4'
    $card.Margin = '0,0,0,6'
    if ($isDone) { $card.Opacity = 0.6 }

    $grid = New-Object Windows.Controls.Grid
    $gc0 = New-Object Windows.Controls.ColumnDefinition; $gc0.Width = 'Auto'
    $gc1 = New-Object Windows.Controls.ColumnDefinition
    $gc2 = New-Object Windows.Controls.ColumnDefinition; $gc2.Width = 'Auto'
    $grid.ColumnDefinitions.Add($gc0); $grid.ColumnDefinitions.Add($gc1); $grid.ColumnDefinitions.Add($gc2)

    $cycle = New-Object Windows.Controls.Button
    $cycle.Style = Get-WidgetResource 'ChromeButton'
    $cycle.FontFamily = New-Object Windows.Media.FontFamily('Segoe UI Symbol')
    $cycle.FontSize = 11
    $cycle.Width = 24
    $cycle.Height = 22
    $cycle.Padding = 0
    $cycle.VerticalAlignment = 'Top'
    $cycle.Margin = '0,0,4,0'
    switch ($status) {
        'notStarted' { $cycle.Content = [char]0x25CB; $cycle.Foreground = Get-WidgetResource 'BrushTextDim' }
        'inProgress' { $cycle.Content = [char]0x25D0; $cycle.Foreground = Get-DevKitGitBrush '#E5C07B' }
        default      { $cycle.Content = [char]0x25CF; $cycle.Foreground = Get-DevKitGitBrush '#3EDD8F' }
    }
    $next = Get-DevKitOnDeckNextStatus -Status $status
    $cycle.ToolTip = "Status: $(Get-DevKitOnDeckStatusLabel -Status $status) - click to move to $(Get-DevKitOnDeckStatusLabel -Status $next) (right-click for all choices)"
    [System.Windows.Automation.AutomationProperties]::SetAutomationId($cycle, "OnDeckCycle_$($Item.Id)")
    $cycle.Add_Click({ Set-DevKitWidgetOnDeckItemStatus -Item $Item -Status $next }.GetNewClosure())
    $grid.Children.Add($cycle) | Out-Null

    $txt = New-Object Windows.Controls.TextBlock
    $txt.Text = [string]$Item.Text
    $txt.FontSize = 11
    $txt.TextWrapping = 'Wrap'
    $txt.VerticalAlignment = 'Center'
    $txt.Margin = '2,1,4,1'
    if ($isDone) {
        $txt.Foreground = Get-WidgetResource 'BrushTextDim'
        $txt.TextDecorations = [Windows.TextDecorations]::Strikethrough
    } else {
        $txt.Foreground = Get-WidgetResource 'BrushTextBright'
    }
    [Windows.Controls.Grid]::SetColumn($txt, 1)
    $grid.Children.Add($txt) | Out-Null

    $del = New-Object Windows.Controls.Button
    $del.Style = Get-WidgetResource 'ChromeButton'
    $del.FontFamily = New-Object Windows.Media.FontFamily('Segoe MDL2 Assets')
    $del.FontSize = 9
    $del.Content = [char]0xE106
    $del.MinWidth = 24
    $del.Height = 18
    $del.VerticalAlignment = 'Top'
    $del.ToolTip = 'Delete this item'
    [System.Windows.Automation.AutomationProperties]::SetAutomationId($del, "OnDeckDelete_$($Item.Id)")
    $del.Add_Click({ Remove-DevKitWidgetOnDeckItem -Item $Item }.GetNewClosure())
    [Windows.Controls.Grid]::SetColumn($del, 2)
    $grid.Children.Add($del) | Out-Null

    $card.Child = $grid

    # Right-click status menu - same styling/pattern as the Files flyout's
    # context menus (FilesContextMenu + capture-free handlers + Tag state).
    $menu = New-Object Windows.Controls.ContextMenu
    $menu.Style = Get-WidgetResource 'FilesContextMenu'
    Add-DevKitFilesMenuItem $menu 'Not Started' { param($s, $e) Set-DevKitWidgetOnDeckItemStatus -Item $s.Tag -Status 'notStarted' } -Tag $Item -Enabled ($status -ne 'notStarted')
    Add-DevKitFilesMenuItem $menu 'In Progress' { param($s, $e) Set-DevKitWidgetOnDeckItemStatus -Item $s.Tag -Status 'inProgress' } -Tag $Item -Enabled ($status -ne 'inProgress')
    Add-DevKitFilesMenuItem $menu 'Done'        { param($s, $e) Set-DevKitWidgetOnDeckItemStatus -Item $s.Tag -Status 'done' } -Tag $Item -Enabled ($status -ne 'done')
    $menu.Items.Add((New-Object Windows.Controls.Separator)) | Out-Null
    Add-DevKitFilesMenuItem $menu 'Delete' { param($s, $e) Remove-DevKitWidgetOnDeckItem -Item $s.Tag } -Tag $Item
    $card.ContextMenu = $menu

    return $card
}

function Update-DevKitWidgetOnDeckPanel {
    # Full re-render: the three sections in fixed order, each header showing
    # its live count; empty sections get a subtle hint instead of rows. The
    # stored list is already section-grouped (every mutation re-groups), so
    # this just filters per section.
    $ui.OnDeckPanel.Children.Clear()
    foreach ($sec in @(
        @{ Status = 'notStarted'; Title = 'NOT STARTED' },
        @{ Status = 'inProgress'; Title = 'IN PROGRESS' },
        @{ Status = 'done';       Title = 'DONE' }
    )) {
        $items = @($script:OnDeckItems | Where-Object { (Get-DevKitOnDeckStatus -Status ([string]$_.Status)) -eq $sec.Status })

        $header = New-Object Windows.Controls.Grid
        $header.Margin = '2,8,2,4'
        $hc0 = New-Object Windows.Controls.ColumnDefinition
        $hc1 = New-Object Windows.Controls.ColumnDefinition; $hc1.Width = 'Auto'
        $header.ColumnDefinitions.Add($hc0); $header.ColumnDefinitions.Add($hc1)

        $ht = New-Object Windows.Controls.TextBlock
        $ht.Style = Get-WidgetResource 'WidgetSectionHeader'
        $ht.Text = "$($sec.Title) ($($items.Count))"
        $ht.VerticalAlignment = 'Center'
        $header.Children.Add($ht) | Out-Null

        if ($sec.Status -eq 'done' -and $items.Count -gt 0) {
            $clear = New-Object Windows.Controls.Button
            $clear.Style = Get-WidgetResource 'GhostButton'
            $clear.FontSize = 9.5
            $clear.Padding = '6,1'
            $clear.Content = 'Clear Done'
            $clear.ToolTip = 'Delete every item in DONE'
            $clear.Add_Click({ Clear-DevKitWidgetOnDeckDone })
            [Windows.Controls.Grid]::SetColumn($clear, 1)
            $header.Children.Add($clear) | Out-Null
        }
        $ui.OnDeckPanel.Children.Add($header) | Out-Null

        if ($items.Count -eq 0) {
            $hint = New-Object Windows.Controls.TextBlock
            $hint.Text = 'No items'
            $hint.FontSize = 10
            $hint.Foreground = Get-WidgetResource 'BrushTextDim'
            $hint.Opacity = 0.7
            $hint.Margin = '4,0,0,6'
            $ui.OnDeckPanel.Children.Add($hint) | Out-Null
        } else {
            foreach ($item in $items) {
                $ui.OnDeckPanel.Children.Add((New-DevKitOnDeckItemRow -Item $item)) | Out-Null
            }
        }
    }
}

function Set-DevKitOnDeckFlyout {
    param([bool]$Open, [switch]$Instant)
    if ($Open -eq $script:OnDeckFlyoutOpen) { return }
    if ($Open -and -not $script:ActiveProjectPath) { return }
    # Only one CAROUSEL flyout at a time - mirror of the guard in
    # Set-DevKitGitFlyout (see the comment there for why the close is
    # -Instant, and why the terminal panel is deliberately NOT in this list).
    if ($Open -and $script:GitFlyoutOpen) { Set-DevKitGitFlyout -Open $false -Instant }
    if ($Open -and $script:NotesFlyoutOpen) { Set-DevKitNotesFlyout -Open $false -Instant }
    if ($Open -and $script:FilesFlyoutOpen) { Set-DevKitFilesFlyout -Open $false -Instant }
    if ($Open -and $script:ProcPanelKind) { Set-DevKitProcPanel -Open $false -Instant }

    # Same lockstep window/flyout animation contract as Set-DevKitGitFlyout
    # (see the long comment there - flag set BEFORE target computation, all
    # window targets derived from the flag-based target layout so overlapping
    # slides still converge). All panels share one anim token.
    $script:GitFlyoutAnimToken++
    $token = $script:GitFlyoutAnimToken
    $script:OnDeckFlyoutOpen = $Open
    $targetFlyoutWidth = if ($Open) { $script:OnDeckFlyoutWidth } else { 0 }
    $targetWindowWidth = $script:WidgetChromeWidth + $script:WidgetContentWidth + (Get-DevKitWidgetPanelExtra)
    $pinnedRight = $window.Left + $window.Width
    $targetLeft = $pinnedRight - $targetWindowWidth

    if ($Instant) {
        $window.BeginAnimation([Windows.Window]::WidthProperty, $null)
        $window.BeginAnimation([Windows.Window]::LeftProperty, $null)
        $ui.OnDeckFlyout.BeginAnimation([Windows.Controls.Border]::WidthProperty, $null)
        $ui.OnDeckFlyout.Width = $targetFlyoutWidth
        $window.Width = $targetWindowWidth
        if ($script:DockMode -eq 'Right') { $window.Left = $targetLeft }
        if ($Open) {
            $ui.OnDeckFlyoutInner.Width = $script:OnDeckFlyoutWidth
            $ui.BtnOnDeckTab.Foreground = Get-DevKitGitBrush '#C678DD'
            Open-DevKitWidgetOnDeckProject
        } else {
            $ui.BtnOnDeckTab.Foreground = Get-WidgetResource 'BrushTextMuted'
        }
        return
    }

    if ($Open) {
        $ui.OnDeckFlyoutInner.Width = $script:OnDeckFlyoutWidth
        Start-DevKitFlyoutSlide -Target $ui.OnDeckFlyout -Property ([Windows.Controls.Border]::WidthProperty) -To $targetFlyoutWidth -Opening $true -Token $token
        Start-DevKitFlyoutSlide -Target $window -Property ([Windows.Window]::WidthProperty) -To $targetWindowWidth -Opening $true -Token $token
        if ($script:DockMode -eq 'Right') {
            # Right-docked: pinned right edge, window grows leftward - same
            # Left+Width lockstep as the Git flyout's open path.
            Start-DevKitFlyoutSlide -Target $window -Property ([Windows.Window]::LeftProperty) -To $targetLeft -Opening $true -Token $token
        }
        $ui.BtnOnDeckTab.Foreground = Get-DevKitGitBrush '#C678DD'
        Open-DevKitWidgetOnDeckProject
    } else {
        Start-DevKitFlyoutSlide -Target $ui.OnDeckFlyout -Property ([Windows.Controls.Border]::WidthProperty) -To 0 -Opening $false -Token $token
        Start-DevKitFlyoutSlide -Target $window -Property ([Windows.Window]::WidthProperty) -To $targetWindowWidth -Opening $false -Token $token
        if ($script:DockMode -eq 'Right') {
            Start-DevKitFlyoutSlide -Target $window -Property ([Windows.Window]::LeftProperty) -To $targetLeft -Opening $false -Token $token
        }
        $ui.BtnOnDeckTab.Foreground = Get-WidgetResource 'BrushTextMuted'
    }
}

$ui.BtnOnDeckTab.Add_Click({ Set-DevKitOnDeckFlyout -Open (-not $script:OnDeckFlyoutOpen) })
$ui.BtnOnDeckClose.Add_Click({ Set-DevKitOnDeckFlyout -Open $false })
$ui.BtnOnDeckAdd.Add_Click({ Add-DevKitWidgetOnDeckItem })
$ui.OnDeckNewText.Add_KeyDown({
    param($s, $e)
    if ($e.Key -eq 'Return') {
        Add-DevKitWidgetOnDeckItem
        $e.Handled = $true
    }
})

# ==================== TERMINAL PANEL (HOSTED REAL TERMINAL) ====================
# A REAL terminal hosted inside the panel (replacing the old embedded-REPL:
# queue/pump/dot-sourced ScriptBlocks). Opening the TERMINAL side tab
# launches an actual terminal process - Windows Terminal (wt.exe, forced
# into a NEW window via `-w new`, with the registered "Northstar DevKit"
# fragment profile when present, else the default profile) when available,
# a classic pwsh/powershell console window otherwise - strips its window
# chrome, makes the widget its OWNER (GWL_HWNDPARENT), and glues it over the
# panel's TermHostSurface element. Interactive CLIs (kimi, claude) work
# exactly as in a normal terminal because it IS a normal terminal - real
# console/WT process, real Win32 keyboard focus.
#
# Why ownership + position sync instead of a SetParent'd HwndHost: this
# window is AllowsTransparency=True (a per-pixel-alpha layered window), and
# WPF renders those through UpdateLayeredWindow - a child HWND inside them
# NEVER renders (documented HwndHost airspace restriction). An owned
# TOP-LEVEL window renders on its own, and the window manager keeps it above
# its owner, hidden with its owner, destroyed with its owner, and out of
# Alt+Tab/the taskbar - the panel only has to keep it positioned over
# TermHostSurface, which the 40ms TermSyncTimer does from the surface's live
# PointToScreen rect (so open/close slides, dock flips, grip resizes and
# title-bar drags all track). One z-order subtlety: the owned-above-owner
# rule holds only WITHIN a z-band - an owned window that is not itself
# topmost sinks BELOW a topmost owner - so the hosted window's WS_EX_TOPMOST
# is kept identical to the widget's pin state (set on attach, re-asserted by
# every sync tick), or the terminal is invisible while the widget is pinned.
# The timer runs ONLY while a session is hosted and the widget is visible
# (hidden = costs ~nothing, same discipline as FastTimer/SlowTimer), and it
# doubles as the session watchdog: if the hosted window vanishes (the user
# typed `exit`), the panel says so instead of framing a ghost.
#
# Lifecycle: the session belongs to the panel. Closing the panel CLOSES the
# session (WM_CLOSE, escalated to a kill ~1.2s later by the one-shot
# TermKillTimer - a full process-tree kill for the conhost shell; for
# Windows Terminal only when its PID owns no other window, so the user's
# existing WT is never collateral damage). A project switch while open
# RESTARTS the session in the new project root (Set-DevKitTermLocation - the
# old REPL re-home hook, kept). Hiding the widget only hides the hosted
# window - the session SURVIVES the hide. Widget exit closes the session.
# Dock-side flips close the panel (the long-standing Set-DevKitWidgetDock
# behavior for every panel), which ends the session - it relaunches on the
# new side when the tab is reopened.
#
# Honest limitations: a native console/WT window is hosted, so it renders
# whatever it renders (WT keeps its own tab strip; its minimum window size
# can overflow a narrowly grip-resized panel); for the ~0.2-1s between
# process start and the HWND poll finding the window it can flash at its
# default position before being glued; a wt launch cancelled mid-flight
# (panel closed within the first second or two) can't be recalled - its
# window may still appear, untracked. When neither wt.exe nor a PowerShell
# executable exists, or no window shows within 15s, the panel shows an
# honest "could not host a terminal here" note instead of a fake console.

# Win32 interop for the hosted terminal, compiled once. Guarded: if the
# compile itself fails, Start-DevKitHostedTerminal shows the honest note.
if (-not ('DevKitTermWin32' -as [type])) {
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class DevKitTermWin32
{
    public const int GWL_STYLE = -16;
    public const int GWL_EXSTYLE = -20;
    public const int GWL_HWNDPARENT = -8;

    public const long WS_CAPTION = 0x00C00000L;
    public const long WS_THICKFRAME = 0x00040000L;
    public const long WS_MINIMIZEBOX = 0x00020000L;
    public const long WS_MAXIMIZEBOX = 0x00010000L;
    public const long WS_SYSMENU = 0x00080000L;
    public const long WS_CHILD = 0x40000000L;
    public const long WS_EX_TOPMOST = 0x00000008L;

    public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    public static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);

    public const int SW_HIDE = 0;
    public const int SW_SHOWNA = 8;

    public const uint SWP_NOSIZE = 0x0001;
    public const uint SWP_NOMOVE = 0x0002;
    public const uint SWP_NOZORDER = 0x0004;
    public const uint SWP_NOACTIVATE = 0x0010;
    public const uint SWP_FRAMECHANGED = 0x0020;
    // Skips WM_WINDOWPOSCHANGING - and with it the WM_GETMINMAXINFO clamp
    // Windows Terminal applies to plain resizes (its minimum window width
    // would otherwise overflow a narrower panel; verified live).
    public const uint SWP_NOSENDCHANGING = 0x0400;

    public const uint WM_CLOSE = 0x0010;

    public const string WindowsTerminalClass = "CASCADIA_HOSTING_WINDOW_CLASS";

    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")] private static extern int GetWindowLong32(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] private static extern IntPtr GetWindowLongPtr64(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongW")] private static extern int SetWindowLong32(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] private static extern IntPtr SetWindowLongPtr64(IntPtr hWnd, int nIndex, IntPtr dwNewLong);

    public static long GetWindowStyle(IntPtr hWnd)
    {
        return IntPtr.Size == 8 ? GetWindowLongPtr64(hWnd, GWL_STYLE).ToInt64() : (long)GetWindowLong32(hWnd, GWL_STYLE);
    }

    public static void SetWindowStyle(IntPtr hWnd, long style)
    {
        if (IntPtr.Size == 8) { SetWindowLongPtr64(hWnd, GWL_STYLE, new IntPtr(style)); }
        else { SetWindowLong32(hWnd, GWL_STYLE, (int)style); }
    }

    public static void SetWindowOwnerHwnd(IntPtr hWnd, IntPtr owner)
    {
        if (IntPtr.Size == 8) { SetWindowLongPtr64(hWnd, GWL_HWNDPARENT, owner); }
        else { SetWindowLong32(hWnd, GWL_HWNDPARENT, (int)owner); }
    }

    // Removes every trace of the window frame and makes `owner` the window's
    // OWNER (z-order above the owner, hidden/destroyed with it, no
    // Alt+Tab/taskbar entry) - NOT a child: the widget window is layered
    // (AllowsTransparency), where a child HWND would never render.
    public static void StripChromeAndOwn(IntPtr hwnd, IntPtr owner)
    {
        long style = GetWindowStyle(hwnd);
        style &= ~(WS_CAPTION | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_SYSMENU | WS_CHILD);
        SetWindowStyle(hwnd, style);
        SetWindowOwnerHwnd(hwnd, owner);
        SetWindowPos(hwnd, IntPtr.Zero, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
    }

    public static void MoveTo(IntPtr hwnd, int x, int y, int w, int h)
    {
        SetWindowPos(hwnd, IntPtr.Zero, x, y, w, h, SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOSENDCHANGING);
    }

    // The widget's pin (Topmost) decides which z-band the hosted window lives
    // in: an owned window that is NOT itself topmost sinks BELOW a topmost
    // owner (the owned-above-owner rule only holds within a band) - that was
    // the "terminal invisible while pinned" bug. This keeps the hosted
    // window's WS_EX_TOPMOST identical to the widget's.
    public static bool IsTopmost(IntPtr hwnd)
    {
        long ex = IntPtr.Size == 8 ? GetWindowLongPtr64(hwnd, GWL_EXSTYLE).ToInt64() : (long)GetWindowLong32(hwnd, GWL_EXSTYLE);
        return (ex & WS_EX_TOPMOST) != 0;
    }

    public static void SetTopmost(IntPtr hwnd, bool topmost)
    {
        SetWindowPos(hwnd, topmost ? HWND_TOPMOST : HWND_NOTOPMOST, 0, 0, 0, 0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOSENDCHANGING);
    }

    public static uint GetPid(IntPtr hwnd)
    {
        uint pid;
        GetWindowThreadProcessId(hwnd, out pid);
        return pid;
    }

    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);
    public const uint GW_OWNER = 4;

    public static IntPtr GetWindowOwner(IntPtr hwnd)
    {
        return GetWindow(hwnd, GW_OWNER);
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    public static bool TryGetRect(IntPtr hwnd, out int x, out int y, out int w, out int h)
    {
        RECT r;
        x = y = w = h = 0;
        if (!GetWindowRect(hwnd, out r)) { return false; }
        x = r.Left; y = r.Top; w = r.Right - r.Left; h = r.Bottom - r.Top;
        return true;
    }

    private static EnumWindowsProc _enumProc;
    private static List<IntPtr> _found;
    private static string _wantedClass;
    private static uint _wantedPid;

    private static bool EnumProc(IntPtr hWnd, IntPtr lParam)
    {
        if (_wantedClass != null)
        {
            StringBuilder sb = new StringBuilder(256);
            GetClassName(hWnd, sb, sb.Capacity);
            if (sb.ToString() != _wantedClass) { return true; }
        }
        if (_wantedPid != 0)
        {
            uint pid;
            GetWindowThreadProcessId(hWnd, out pid);
            if (pid != _wantedPid) { return true; }
        }
        _found.Add(hWnd);
        return true;
    }

    public static IntPtr[] FindTopLevelWindowsByClass(string className)
    {
        _found = new List<IntPtr>();
        _wantedClass = className;
        _wantedPid = 0;
        if (_enumProc == null) { _enumProc = new EnumWindowsProc(EnumProc); }
        EnumWindows(_enumProc, IntPtr.Zero);
        _wantedClass = null;
        return _found.ToArray();
    }

    public static IntPtr[] FindWindowsForPid(uint pid)
    {
        _found = new List<IntPtr>();
        _wantedClass = null;
        _wantedPid = pid;
        if (_enumProc == null) { _enumProc = new EnumWindowsProc(EnumProc); }
        EnumWindows(_enumProc, IntPtr.Zero);
        _wantedPid = 0;
        return _found.ToArray();
    }
}
'@
    } catch { }
}

$script:TermHostedHwnd = [IntPtr]::Zero
$script:TermHostedProcess = $null   # conhost-kind shell process (kept for the tree-kill); $null for wt
$script:TermHostedPid = 0           # PID that owns the hosted window
$script:TermHostedKind = $null      # 'wt' | 'conhost'
$script:TermLaunchPending = $false
$script:TermLaunchElapsedMs = 0
$script:TermMaxLaunchMs = 15000
$script:TermWtBefore = @()
$script:TermConBefore = @()
$script:TermCwd = $null             # directory the hosted session was started in (Sync-DevKitWidgetGitState compares against it)
$script:TermWidgetHwnd = [IntPtr]::Zero

function Get-DevKitTermHostRoot {
    if ($script:ActiveProjectPath) { return $script:ActiveProjectPath }
    return $ScriptDir
}

function Set-DevKitTermStatus {
    # Status line text; -Overlay ALSO shows it centered on the dark surface
    # (the launch/failure note the hosted window covers once attached).
    param([string]$Text, [switch]$Overlay)
    $ui.TermFlyoutStatus.Text = $Text
    if ($Overlay) {
        $ui.TermHostStatus.Text = $Text
        $ui.TermHostStatus.Visibility = 'Visible'
    } else {
        $ui.TermHostStatus.Visibility = 'Collapsed'
    }
}

function Stop-DevKitProcessTree {
    # Depth-first kill of a process and every descendant. Stop-Process (not
    # taskkill) is used deliberately: taskkill is a console app and would
    # flash a console window from this headless tray process.
    param([int]$RootPid)
    try {
        foreach ($k in @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$RootPid" -ErrorAction Stop)) {
            Stop-DevKitProcessTree -RootPid ([int]$k.ProcessId)
        }
    } catch { }
    try { Stop-Process -Id $RootPid -Force -ErrorAction Stop } catch { }
}

function Invoke-DevKitTermPendingKill {
    # The escalated half of session close (see Stop-DevKitHostedTerminal):
    # ~1.2s after WM_CLOSE, force-kill whatever ignored it. Runs off the
    # one-shot TermKillTimer's Tag context, so a NEW session started meanwhile
    # is never touched by an old session's backstop.
    $ctx = $script:TermKillTimer.Tag
    $script:TermKillTimer.Stop()
    $script:TermKillTimer.Tag = $null
    if ($null -eq $ctx) { return }
    try {
        if (-not [DevKitTermWin32]::IsWindow($ctx.Hwnd)) { return }
        if ($ctx.Kind -eq 'conhost' -and $ctx.ProcId -gt 0) {
            Stop-DevKitProcessTree -RootPid $ctx.ProcId
        } elseif ($ctx.OwnedPid -gt 0) {
            # Windows Terminal: the last-resort kill fires only when the window
            # is still demonstrably OURS (HWND values get recycled between
            # windows, so re-verify owner AND pid) and its PID owns no other
            # window - on single-process WT installs that PID also hosts the
            # user's own windows, which must never be collateral damage.
            $stillOurs = ([DevKitTermWin32]::GetWindowOwner($ctx.Hwnd) -eq $script:TermWidgetHwnd)
            $samePid = ([int][DevKitTermWin32]::GetPid($ctx.Hwnd) -eq $ctx.OwnedPid)
            if ($stillOurs -and $samePid) {
                $others = @([DevKitTermWin32]::FindWindowsForPid([uint32]$ctx.OwnedPid))
                if ($others.Count -le 1) { Stop-Process -Id $ctx.OwnedPid -Force -ErrorAction Stop }
            }
        }
    } catch { }
}

function Reset-DevKitHostedTerminalState {
    $script:TermHostedHwnd = [IntPtr]::Zero
    $script:TermHostedProcess = $null
    $script:TermHostedPid = 0
    $script:TermHostedKind = $null
    $script:TermLaunchPending = $false
    $script:TermPollTimer.Stop()
    $script:TermSyncTimer.Stop()
}

function Stop-DevKitHostedTerminal {
    # Closes the hosted SESSION (panel close / restart / widget exit): the
    # window gets WM_CLOSE first (graceful - closing a console window ends
    # its whole attached tree; closing a WT window ends that window's
    # sessions), with the force-kill backstop above firing ~1.2s later.
    Invoke-DevKitTermPendingKill   # a previous backstop must not fire into new state
    $hwnd = $script:TermHostedHwnd
    $proc = $script:TermHostedProcess
    $kind = $script:TermHostedKind
    $ownedPid = $script:TermHostedPid
    Reset-DevKitHostedTerminalState
    if ($hwnd -ne [IntPtr]::Zero -and [DevKitTermWin32]::IsWindow($hwnd)) {
        [DevKitTermWin32]::PostMessage($hwnd, [DevKitTermWin32]::WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
        $script:TermKillTimer.Tag = @{
            Hwnd     = $hwnd
            Kind     = $kind
            ProcId   = $(if ($proc) { try { $proc.Id } catch { 0 } } else { 0 })
            OwnedPid = $ownedPid
        }
        $script:TermKillTimer.Start()
    } elseif ($proc) {
        # Launch still pending (no window yet): kill the half-started shell
        # before its console can flash on screen. (A pending wt launch can't
        # be recalled - its window may still appear, untracked; see header.)
        try { if (-not $proc.HasExited) { Stop-DevKitProcessTree -RootPid $proc.Id } } catch { }
    }
}

function Start-DevKitHostedTerminal {
    # Launches the real terminal for the current root and begins the HWND
    # poll. Preference order: (a) wt.exe with the registered "Northstar
    # DevKit" fragment profile, (b) wt.exe default profile, (c) a classic
    # pwsh/powershell console window. Whatever hosts, it starts already cd'd
    # to the active project (DevKit root + dim note when none is selected).
    if ($script:TermHostedHwnd -ne [IntPtr]::Zero -or $script:TermLaunchPending) { return }
    if (-not ('DevKitTermWin32' -as [type])) {
        Set-DevKitTermStatus 'Could not host a terminal here: the Win32 host component failed to compile.' -Overlay
        return
    }
    $root = Get-DevKitTermHostRoot
    $script:TermCwd = $root
    $ui.TermFlyoutSub.Text = $root
    $ui.TermNoProjectNote.Visibility = if ($script:ActiveProjectPath) { 'Collapsed' } else { 'Visible' }

    if (Get-Command wt.exe -ErrorAction SilentlyContinue) {
        $fragment = Join-Path (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\Fragments\Northstar DevKit') 'devkit.json'
        $wtArgs = '-w new --title "Northstar DevKit" -d "' + $root + '"'
        if (Test-Path $fragment) { $wtArgs += ' -p "Northstar DevKit"' }
        # Snapshot the existing WT windows so the poll can recognize OURS as
        # "the one that wasn't there before" (wt.exe just hands the request
        # to the WindowsTerminal.exe peasant process - its own PID is useless).
        $script:TermWtBefore = @([DevKitTermWin32]::FindTopLevelWindowsByClass([DevKitTermWin32]::WindowsTerminalClass) | ForEach-Object { $_.ToInt64() })
        try {
            Start-Process -FilePath 'wt.exe' -ArgumentList $wtArgs
            $script:TermHostedKind = 'wt'
            $script:TermLaunchPending = $true
            $script:TermLaunchElapsedMs = 0
            Set-DevKitTermStatus 'Starting Windows Terminal...' -Overlay
            $script:TermPollTimer.Start()
            return
        } catch { }   # fall through to the console host below
    }

    $shellCmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if (-not $shellCmd) { $shellCmd = Get-Command powershell -ErrorAction SilentlyContinue }
    if (-not $shellCmd) {
        Set-DevKitTermStatus 'Could not host a terminal here: neither wt.exe nor a PowerShell executable was found on PATH.' -Overlay
        return
    }
    try {
        # -NoLogo but deliberately NOT -NoProfile: this is the user's REAL
        # terminal, so it loads their profile like any freshly opened console.
        # Snapshot BOTH window classes first: the shell's window can be a
        # classic ConsoleWindowClass console OR - on machines whose default
        # terminal application is Windows Terminal - a new CASCADIA window
        # (console delegation; Process.MainWindowHandle never populates in
        # that case, which is why discovery is a window diff, never that).
        $script:TermConBefore = @([DevKitTermWin32]::FindTopLevelWindowsByClass('ConsoleWindowClass') | ForEach-Object { $_.ToInt64() })
        $script:TermWtBefore = @([DevKitTermWin32]::FindTopLevelWindowsByClass([DevKitTermWin32]::WindowsTerminalClass) | ForEach-Object { $_.ToInt64() })
        $script:TermHostedProcess = Start-Process -FilePath $shellCmd.Source -ArgumentList '-NoLogo' -WorkingDirectory $root -PassThru
    } catch {
        Set-DevKitTermStatus "Could not host a terminal here: $($_.Exception.Message)" -Overlay
        return
    }
    $script:TermHostedKind = 'conhost'
    $script:TermLaunchPending = $true
    $script:TermLaunchElapsedMs = 0
    Set-DevKitTermStatus "Starting $([IO.Path]::GetFileNameWithoutExtension($shellCmd.Name)) console..." -Overlay
    $script:TermPollTimer.Start()
}

function Update-DevKitTermLaunchPoll {
    # TermPollTimer tick: look for the just-launched window (a brand-new
    # ConsoleWindowClass or CASCADIA window - never Process.MainWindowHandle,
    # which stays 0 when the console is delegated to Windows Terminal) and
    # attach it, or give up honestly after TermMaxLaunchMs.
    if (-not $script:TermLaunchPending) { $script:TermPollTimer.Stop(); return }
    $script:TermLaunchElapsedMs += 200
    $hwnd = [IntPtr]::Zero
    if ($script:TermHostedKind -eq 'conhost') {
        foreach ($h in @([DevKitTermWin32]::FindTopLevelWindowsByClass('ConsoleWindowClass'))) {
            if ($script:TermConBefore -notcontains $h.ToInt64()) { $hwnd = $h; break }
        }
        if ($hwnd -eq [IntPtr]::Zero) {
            # Console delegated to Windows Terminal: the shell landed in a
            # fresh WT window instead - host that (and treat it as wt-kind
            # from here, so the close/kill semantics stay correct).
            foreach ($h in @([DevKitTermWin32]::FindTopLevelWindowsByClass([DevKitTermWin32]::WindowsTerminalClass))) {
                if ($script:TermWtBefore -notcontains $h.ToInt64()) { $hwnd = $h; $script:TermHostedKind = 'wt'; break }
            }
        }
    } elseif ($script:TermHostedKind -eq 'wt') {
        foreach ($h in @([DevKitTermWin32]::FindTopLevelWindowsByClass([DevKitTermWin32]::WindowsTerminalClass))) {
            if ($script:TermWtBefore -notcontains $h.ToInt64()) { $hwnd = $h; break }
        }
    }
    if ($hwnd -ne [IntPtr]::Zero) {
        $script:TermPollTimer.Stop()
        $script:TermLaunchPending = $false
        Complete-DevKitTermAttach -Hwnd $hwnd
        return
    }
    if ($script:TermLaunchElapsedMs -ge $script:TermMaxLaunchMs) {
        $kind = $script:TermHostedKind
        $proc = $script:TermHostedProcess
        Reset-DevKitHostedTerminalState
        try { if ($proc -and -not $proc.HasExited) { Stop-DevKitProcessTree -RootPid $proc.Id } } catch { }
        Set-DevKitTermStatus "Could not host a terminal here: the $kind window never appeared (15s). Use Restart to try again." -Overlay
    }
}

function Complete-DevKitTermAttach {
    # The poll found the launched window: strip its chrome, make the widget
    # its OWNER (not its parent - see the section header for why), park it
    # over the panel surface, and start the rect sync.
    param([IntPtr]$Hwnd)
    try {
        if ($script:TermWidgetHwnd -eq [IntPtr]::Zero) {
            $script:TermWidgetHwnd = (New-Object Windows.Interop.WindowInteropHelper $window).Handle
        }
        [DevKitTermWin32]::StripChromeAndOwn($Hwnd, $script:TermWidgetHwnd)
    } catch {
        Reset-DevKitHostedTerminalState
        Set-DevKitTermStatus "Could not host a terminal here: $($_.Exception.Message)" -Overlay
        return
    }
    $script:TermHostedHwnd = $Hwnd
    $script:TermHostedPid = [int][DevKitTermWin32]::GetPid($Hwnd)
    # Match the widget's pin band immediately - a non-topmost owned window
    # sinks BELOW a topmost owner (the terminal would be invisible while the
    # widget is pinned). The sync timer re-asserts this on every toggle.
    [DevKitTermWin32]::SetTopmost($Hwnd, [bool]$window.Topmost)
    Set-DevKitTermStatus "$(if ($script:TermHostedKind -eq 'wt') { 'Windows Terminal' } else { 'PowerShell console' }) hosted - running in $($script:TermCwd)"
    $ui.TermHostStatus.Visibility = 'Collapsed'
    Sync-DevKitHostedTerminalRect
    if ($window.IsVisible) {
        [DevKitTermWin32]::ShowWindow($Hwnd, [DevKitTermWin32]::SW_SHOWNA) | Out-Null
        $script:TermSyncTimer.Start()
        # The panel was just opened interactively - hand the terminal real
        # keyboard focus so typing works without an extra click.
        if ($window.IsActive) { [DevKitTermWin32]::SetForegroundWindow($Hwnd) | Out-Null }
    } else {
        [DevKitTermWin32]::ShowWindow($Hwnd, [DevKitTermWin32]::SW_HIDE) | Out-Null
    }
}

function Sync-DevKitHostedTerminalRect {
    # Glues the hosted window to TermHostSurface's live screen rect. Runs on
    # the 40ms TermSyncTimer (only while a session is hosted AND the widget
    # is visible) and is called directly on attach/show. Authoritative: the
    # window's ACTUAL rect is compared to the target every tick, so the glue
    # holds no matter who moved the window (slide animations, grip resizes,
    # dock flips - or the terminal app itself). Also the session watchdog: a
    # vanished hosted window means the shell exited on its own.
    $hwnd = $script:TermHostedHwnd
    if ($hwnd -eq [IntPtr]::Zero) { return }
    if (-not [DevKitTermWin32]::IsWindow($hwnd)) {
        Reset-DevKitHostedTerminalState
        Set-DevKitTermStatus 'Terminal session ended - Restart relaunches it here.' -Overlay
        return
    }
    if (-not $window.IsVisible) { return }
    $surface = $ui.TermHostSurface
    if ($surface.ActualWidth -lt 20 -or $surface.ActualHeight -lt 20) { return }
    try {
        # PointToScreen returns PHYSICAL pixels (DPI-correct); mapping both
        # corners avoids any DIP/px math of our own.
        $p0 = $surface.PointToScreen((New-Object Windows.Point(0, 0)))
        $p1 = $surface.PointToScreen((New-Object Windows.Point($surface.ActualWidth, $surface.ActualHeight)))
    } catch { return }
    $x = [int][math]::Round($p0.X); $y = [int][math]::Round($p0.Y)
    $w = [int][math]::Round($p1.X - $p0.X); $h = [int][math]::Round($p1.Y - $p0.Y)
    if ($w -lt 20 -or $h -lt 20) { return }
    $ax = 0; $ay = 0; $aw = 0; $ah = 0
    if (-not [DevKitTermWin32]::TryGetRect($hwnd, [ref]$ax, [ref]$ay, [ref]$aw, [ref]$ah)) { return }
    if ($ax -ne $x -or $ay -ne $y -or $aw -ne $w -or $ah -ne $h) {
        [DevKitTermWin32]::MoveTo($hwnd, $x, $y, $w, $h) | Out-Null
    }
    # Keep the hosted window in the widget's pin z-band: an owned window that
    # is not itself topmost sinks BELOW a topmost owner, which made the
    # terminal invisible whenever the widget was pinned. Enforced here (not
    # just on the pin toggle) so nothing can strand it - toggle the pin,
    # hide/show, dock flip; the next tick heals the band.
    $wantTopmost = [bool]$window.Topmost
    if ([DevKitTermWin32]::IsTopmost($hwnd) -ne $wantTopmost) {
        [DevKitTermWin32]::SetTopmost($hwnd, $wantTopmost)
    }
    # WT draws its own title-bar buttons even with the Win32 frame stripped -
    # its Minimize can park the hosted window iconic; drag it right back.
    if ([DevKitTermWin32]::IsIconic($hwnd)) {
        [DevKitTermWin32]::ShowWindow($hwnd, [DevKitTermWin32]::SW_SHOWNA) | Out-Null
    }
}

function Restart-DevKitHostedTerminal {
    Stop-DevKitHostedTerminal
    Start-DevKitHostedTerminal
}

function Set-DevKitTermLocation {
    # Re-homes the hosted terminal: the active project's root, or the DevKit
    # root when no project is selected (the dim note row says so). A real
    # terminal has no injectable Set-Location, so a re-home is a session
    # RESTART in the new directory. Kept as the project-switch hook called by
    # Sync-DevKitWidgetGitState; -Note reports the restart on the status line.
    param([switch]$Note)
    if (-not $script:TermFlyoutOpen) { return }
    $root = Get-DevKitTermHostRoot
    $ui.TermNoProjectNote.Visibility = if ($script:ActiveProjectPath) { 'Collapsed' } else { 'Visible' }
    if ($script:TermCwd -ne $root) {
        Restart-DevKitHostedTerminal
        if ($Note) { $ui.TermFlyoutStatus.Text = "Terminal restarted in $root" }
    }
}

function Set-DevKitTerminalFlyout {
    # Opens/closes the terminal panel. Same slide/geometry contract as
    # Set-DevKitGitFlyout (flag set BEFORE targets are computed; every window
    # target derived from the flag-based target layout) - but deliberately NO
    # carousel exclusivity in either direction: the terminal coexists with
    # whichever flyout is open.
    param([bool]$Open, [switch]$Instant)
    if ($Open -eq $script:TermFlyoutOpen) { return }
    $script:GitFlyoutAnimToken++
    $token = $script:GitFlyoutAnimToken
    $script:TermFlyoutOpen = $Open
    $targetFlyoutWidth = if ($Open) { $script:TermFlyoutWidth } else { 0 }
    $targetWindowWidth = $script:WidgetChromeWidth + $script:WidgetContentWidth + (Get-DevKitWidgetPanelExtra)
    $pinnedRight = $window.Left + $window.Width
    $targetLeft = $pinnedRight - $targetWindowWidth

    if ($Instant) {
        $window.BeginAnimation([Windows.Window]::WidthProperty, $null)
        $window.BeginAnimation([Windows.Window]::LeftProperty, $null)
        $ui.TermFlyout.BeginAnimation([Windows.Controls.Border]::WidthProperty, $null)
        $ui.TermFlyout.Width = $targetFlyoutWidth
        $window.Width = $targetWindowWidth
        if ($script:DockMode -eq 'Right') { $window.Left = $targetLeft }
    } else {
        Start-DevKitFlyoutSlide -Target $ui.TermFlyout -Property ([Windows.Controls.Border]::WidthProperty) -To $targetFlyoutWidth -Opening $Open -Token $token
        Start-DevKitFlyoutSlide -Target $window -Property ([Windows.Window]::WidthProperty) -To $targetWindowWidth -Opening $Open -Token $token
        if ($script:DockMode -eq 'Right') {
            # Right-docked: pinned right edge - the terminal (the OUTERMOST
            # panel) grows/shrinks the window leftward, pushing nothing on
            # the widget side.
            Start-DevKitFlyoutSlide -Target $window -Property ([Windows.Window]::LeftProperty) -To $targetLeft -Opening $Open -Token $token
        }
    }

    if ($Open) {
        $ui.TermFlyoutInner.Width = $script:TermFlyoutWidth
        $ui.BtnTerminalTab.Foreground = Get-DevKitGitBrush '#56B6C2'
        # Every open hosts a FRESH session for the current project root (the
        # close below killed the previous one); Start-DevKitHostedTerminal
        # also re-homes the subtitle and the no-project note.
        Start-DevKitHostedTerminal
    } else {
        $ui.BtnTerminalTab.Foreground = Get-WidgetResource 'BrushTextMuted'
        # The session belongs to the panel: closing the panel closes the
        # hosted terminal (graceful WM_CLOSE + the kill backstop).
        Stop-DevKitHostedTerminal
    }
}

# The three hosted-terminal timers, all created STOPPED - none is ever an
# always-on timer: the launch poll only ticks while a window is being found,
# the rect sync only while a session is hosted AND the widget is visible
# (same hidden-costs-nothing discipline as FastTimer/SlowTimer), and the kill
# timer is a one-shot backstop for the graceful WM_CLOSE.
$script:TermPollTimer = New-Object Windows.Threading.DispatcherTimer
$script:TermPollTimer.Interval = [TimeSpan]::FromMilliseconds(200)
$script:TermPollTimer.Add_Tick({ try { Update-DevKitTermLaunchPoll } catch { } })

$script:TermSyncTimer = New-Object Windows.Threading.DispatcherTimer
$script:TermSyncTimer.Interval = [TimeSpan]::FromMilliseconds(40)
$script:TermSyncTimer.Add_Tick({ try { Sync-DevKitHostedTerminalRect } catch { } })

$script:TermKillTimer = New-Object Windows.Threading.DispatcherTimer
$script:TermKillTimer.Interval = [TimeSpan]::FromMilliseconds(1200)
$script:TermKillTimer.Add_Tick({ try { Invoke-DevKitTermPendingKill } catch { } })

$ui.BtnTerminalTab.Add_Click({ Set-DevKitTerminalFlyout -Open (-not $script:TermFlyoutOpen) })
$ui.BtnTermClose.Add_Click({ Set-DevKitTerminalFlyout -Open $false })
$ui.BtnTermRestart.Add_Click({ Restart-DevKitHostedTerminal })

# ==================== QUICK ACTIONS ====================

function Start-DevKitWidgetTool {
    param(
        [Parameter(Mandatory = $true)][string]$RelativeScript,
        [hashtable]$Arguments = @{},
        [Parameter(Mandatory = $true)][string]$Title
    )
    # RelativeScript is relative to tools\ (the 4.0 layout keeps every
    # category folder under tools\ instead of the repo root).
    $launch = Get-DevKitTerminalCommand -ScriptPath (Join-Path $ToolsDir $RelativeScript) `
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
$ui.BtnDevKitHub.Add_Click({ Start-Process (Join-Path $ScriptDir 'DevKit-GUI.bat') -WorkingDirectory $ScriptDir })

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

# Free-text variant of the dialog chrome above, for the Files flyout's
# New File/New Folder/Rename prompts. Names are validated in-dialog with
# Get-DevKitSafeChildName (DevKit-WidgetCore.ps1); returns the validated
# name, or $null when cancelled/closed.
function Show-DevKitWidgetTextInput {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Label,
        [string]$Initial = ''
    )
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

    $labelText = New-Object Windows.Controls.TextBlock
    $labelText.Style = Get-WidgetResource 'WidgetRowText'
    $labelText.Text = $Label
    $labelText.TextWrapping = 'Wrap'
    $labelText.Margin = '0,8,0,0'
    $stack.Children.Add($labelText) | Out-Null

    $box = New-Object Windows.Controls.TextBox
    $box.Style = Get-WidgetResource 'InputBox'
    $box.Height = 30
    $box.Margin = '0,6,0,0'
    $box.Text = $Initial
    $stack.Children.Add($box) | Out-Null

    $errorText = New-Object Windows.Controls.TextBlock
    $errorText.Style = Get-WidgetResource 'WidgetRowText'
    $errorText.Foreground = Get-WidgetResource 'BrushAccentEmber'
    $errorText.TextWrapping = 'Wrap'
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
        $safe = Get-DevKitSafeChildName -Name $box.Text
        if ($null -eq $safe) {
            $errorText.Text = 'Enter a valid name - no \ / : * ? " < > | characters, not empty, no trailing dot or space.'
            return
        }
        $dlg.Tag = $safe
        $dlg.Close()
    }
    $okBtn.Add_Click($submit)
    $box.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { & $submit } })
    $dlg.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Escape') { $s.Close() } })
    $dlg.Add_ContentRendered({
        $box.Focus() | Out-Null
        # A prefilled Rename keeps the extension out of the selection so
        # typing replaces just the base name, Explorer-style.
        if (-not [string]::IsNullOrEmpty($box.Text)) {
            $stem = [IO.Path]::GetFileNameWithoutExtension($box.Text)
            $box.Select($stem.Length, $box.Text.Length - $stem.Length)
        }
    })
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
        # The startup .vbs deletes the pid file before EVERY launch attempt
        # (stale-handshake guard) - including ones that just summon this
        # already-running instance - so re-write it here, otherwise the file
        # Uninstall.ps1 uses to find and stop this process goes missing after
        # any icon click while the widget is up.
        try {
            Set-Content -LiteralPath (Join-Path $env:LOCALAPPDATA "NorthstarDevKit\widget.pid") -Value $PID -Encoding ASCII
        } catch { }
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
    # Junk rescan every 30 minutes; a no-op while the work runspace is busy.
    # A scan is a full recursive enumeration of the temp folders - far too
    # expensive to run more often for a dial, and it doesn't run at all while
    # the window is hidden (SlowTimer is stopped - see Hide-DevKitWidget).
    if (-not $script:WorkBusy -and ((Get-Date) - $script:JunkLastScan).TotalSeconds -gt 1800) {
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

# One failing initializer must not take the whole widget down via the trap -
# with $ErrorActionPreference='Stop' a single throwing call (e.g.
# Update-DevKitWidgetProjects hitting an unwritable %LOCALAPPDATA% dir) used
# to be an invisible startup death. Log and continue instead; every one of
# these is individually re-runnable (timers/watchers fire them again later).
foreach ($startupStep in @(
    { Update-DevKitWidgetProjects },
    { Set-DevKitWidgetDock -Mode (Get-DevKitWidgetDockSetting) },
    { Start-DevKitMetricsRefresh },
    { Start-DevKitJunkScan },
    { Update-DevKitWidgetFooter },
    { Start-DevKitMcpRefresh }
)) {
    try {
        & $startupStep
    } catch {
        try {
            $startupLogDir = Join-Path $env:LOCALAPPDATA "NorthstarDevKit"
            if (-not (Test-Path $startupLogDir)) { New-Item -ItemType Directory -Path $startupLogDir -Force | Out-Null }
            Add-Content -LiteralPath (Join-Path $startupLogDir "widget-startup.log") -Encoding UTF8 -Value (
                "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] PID=$PID startup step failed: $($_.Exception.Message)`n$($_.InvocationInfo.PositionMessage)`n")
        } catch { }
    }
}
# Main's fixed width is set from the one constant so the XAML's design-time
# value can never silently disagree with the geometry math.
if ($ui.MainColumn) { $ui.MainColumn.Width = [Windows.GridLength]::new($script:WidgetContentWidth) }
$window.Width = $script:WidgetChromeWidth + $script:WidgetContentWidth
$script:FastTimer.Start()
$script:SlowTimer.Start()

# Startup-launcher handshake: Start-Widget-Startup.vbs polls for this file
# (written only once the window exists and every initializer above has run)
# to know the launch actually worked - see that script's header. Best-effort:
# the widget runs fine without it, the launcher just can't confirm success.
try {
    $pidDir = Join-Path $env:LOCALAPPDATA "NorthstarDevKit"
    if (-not (Test-Path $pidDir)) { New-Item -ItemType Directory -Path $pidDir -Force | Out-Null }
    Set-Content -LiteralPath (Join-Path $pidDir "widget.pid") -Value $PID -Encoding ASCII
} catch { }

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
# Close the hosted terminal session (WM_CLOSE, then a 600ms beat for the
# graceful close before the kill backstop is flushed inline - the dispatcher
# is ending, so the one-shot TermKillTimer would never fire on its own).
try { Stop-DevKitHostedTerminal } catch { }
Start-Sleep -Milliseconds 600
try { Invoke-DevKitTermPendingKill } catch { }
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
