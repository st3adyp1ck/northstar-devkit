#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Northstar DevKit - Desktop GUI
.DESCRIPTION
    The branded Windows front-end for the toolkit: a WPF shell themed on the
    Northstar compass-rose logo that renders every tool-category manifest
    (_module.psd1) as navigable pages of tool cards, with search, linked-
    project management, and GUI dialogs for each item's declared inputs
    (RequiresProject / RequiresFile / Prompts). Launching a tool opens it in
    a real terminal window (Windows Terminal when installed, classic console
    otherwise) so all existing script interactivity - arrow-key menus,
    banners, spinners, confirmations, dev servers - keeps working untouched.

    Purely additive: no leaf script, manifest, or the TUI (DevKit.ps1) is
    modified by this front-end. Adding a tool to a manifest makes it appear
    here automatically.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER NoWindowsTerminal
    Launch tools in the classic console host even if Windows Terminal is
    installed (fallback for wt.exe issues).
.EXAMPLE
    .\gui\DevKit-GUI.ps1
#>
[CmdletBinding()]
param(
    [switch]$NoWindowsTerminal
)

# WPF requires a single-threaded apartment. pwsh/Windows PowerShell default
# to STA on Windows, but if launched with -MTA, relaunch ourselves in STA.
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $selfPath = $PSCommandPath
    if ([string]::IsNullOrWhiteSpace($selfPath)) { $selfPath = $MyInvocation.MyCommand.Path }
    $shellExe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
    $argList = "-NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File `"$selfPath`""
    if ($NoWindowsTerminal) { $argList += ' -NoWindowsTerminal' }
    Start-Process $shellExe -ArgumentList $argList | Out-Null
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
        $argList = "-NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File `"$selfPath`""
        if ($NoWindowsTerminal) { $argList += ' -NoWindowsTerminal' }
        Start-Process $altShell -ArgumentList $argList | Out-Null
        exit
    }
}

$ErrorActionPreference = 'Stop'
$GuiDir = $PSScriptRoot
$ScriptDir = Split-Path -Parent $PSScriptRoot   # repo root (gui/ sits one level down)

. (Join-Path $ScriptDir "lib\DevKit-Common.ps1")
. (Join-Path $GuiDir "DevKit-GuiCore.ps1")

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Drawing

# Windows groups taskbar buttons by "Application User Model ID", and a
# script-hosted window with no explicit AUMID is grouped under its HOST EXE
# (pwsh.exe/powershell.exe) - so the taskbar shows the PowerShell icon for
# the group regardless of what WM_SETICON sets on the window itself. Giving
# this process its own AUMID, before any window is created, is what makes
# Windows treat it as a distinct app and actually honor the window's icon.
# A different ID than the companion widget's keeps the two apps from being
# grouped into one taskbar button together.
# DevKitIconNative (WM_SETICON at SourceInitialized) and DevKitGuiNative
# (edge-resize WM_NCLBUTTONDOWN for the resize grips) ride along in this one
# compile so startup pays for a single C# compiler invocation instead of
# three; their call sites live further down the file.
if (-not ('DevKitAppId' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DevKitAppId {
    [DllImport("shell32.dll", SetLastError = true)]
    public static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string AppID);
}
public static class DevKitIconNative {
    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
}
public static class DevKitGuiNative {
    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
}
'@
}
try {
    [DevKitAppId]::SetCurrentProcessExplicitAppUserModelID('Northstar.DevKit.GUI') | Out-Null
} catch { }

# ==================== XAML LOAD ====================
# Theme.xaml is a ResourceDictionary; loose XAML parsed by XamlReader cannot
# reference external dictionaries via pack URIs. String-merging the theme
# into the window's resources used to be the workaround, but keyless
# (implicit) styles in Window.Resources never reach template-generated
# elements (the ScrollBar inside a ScrollViewer, ToolTips, CheckBoxes in
# dialogs). Parsing the theme as its own dictionary and assigning it to the
# Application's resources fixes that application-wide - including dialogs -
# while keyed StaticResource lookups walk up from the window to the app.
# The Application must exist BEFORE any XamlReader.Load call.

if (-not [Windows.Application]::Current) {
    $script:App = New-Object Windows.Application
}
$themeDoc = [xml](Get-Content -Path (Join-Path $GuiDir "Theme.xaml") -Raw)
[Windows.Application]::Current.Resources = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $themeDoc))

$windowDoc = [xml](Get-Content -Path (Join-Path $GuiDir "DevKit-GUI.xaml") -Raw)
$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $windowDoc))

$ui = @{}
foreach ($name in @(
    'RootBorder', 'TitleBar', 'TitleLogoImage', 'TitleVersionText', 'AdminBadge',
    'BtnWidget', 'BtnMinimize', 'BtnMaximize', 'BtnClose', 'SearchBox', 'SearchWatermark',
    'NavList', 'PageTitle', 'PageDescription', 'ContentScroll', 'ContentPanel',
    'StatusProjectButton', 'StatusProjectText', 'StatusTerminalText', 'StatusVersionText'
)) {
    $ui[$name] = $window.FindName($name)
}

# Brand images (absolute URIs - loose XAML can't resolve relative paths).
$logoBitmap = New-Object Windows.Media.Imaging.BitmapImage (New-Object System.Uri (Join-Path $GuiDir "Assets\logo-256.png"))
$ui.TitleLogoImage.Source = $logoBitmap
$window.Icon = [Windows.Media.Imaging.BitmapFrame]::Create((New-Object System.Uri (Join-Path $GuiDir "Assets\logo.ico")))

# WPF's Window.Icon property alone is not reliable enough for a script-
# hosted window (there's no compiled .exe carrying the icon as a resource):
# the taskbar button and Alt+Tab can still show the hosting powershell.exe/
# pwsh.exe icon instead of the brand icon. Explicitly sending WM_SETICON
# with real HICON handles once the HWND exists (SourceInitialized) is the
# reliable fix - the icon objects are kept alive in $script: scope for the
# life of the window since WM_SETICON does not take ownership of them.
# (DevKitIconNative is compiled in the merged Add-Type near the top of the file.)
$window.Add_SourceInitialized({
    try {
        $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $window).Handle
        if ($hwnd -eq [IntPtr]::Zero) { return }
        $iconPath = Join-Path $GuiDir "Assets\logo.ico"
        $script:TaskbarIconSmall = New-Object System.Drawing.Icon($iconPath, 16, 16)
        $script:TaskbarIconBig = New-Object System.Drawing.Icon($iconPath, 32, 32)
        [DevKitIconNative]::SendMessage($hwnd, 0x0080, [IntPtr]0, $script:TaskbarIconSmall.Handle) | Out-Null   # ICON_SMALL
        [DevKitIconNative]::SendMessage($hwnd, 0x0080, [IntPtr]1, $script:TaskbarIconBig.Handle) | Out-Null     # ICON_BIG
    } catch { }
})

# Version from the VERSION file (same rule as DevKit.ps1).
$DevKitVersion = '3.8.0'
try {
    $versionFile = Join-Path $ScriptDir "VERSION"
    if (Test-Path $versionFile) {
        $rawVersion = (Get-Content -Path $versionFile -Raw -ErrorAction Stop).Trim()
        if (-not [string]::IsNullOrWhiteSpace($rawVersion)) { $DevKitVersion = $rawVersion }
    }
} catch { }
$ui.TitleVersionText.Text = "v$DevKitVersion"
$ui.StatusVersionText.Text = "v$DevKitVersion  |  northstarcoding.com"

# Cache the catalog and the terminal/shell probe once at startup.
$script:Catalog = Get-DevKitGuiCatalog -RootPath $ScriptDir
$script:TerminalProbe = Get-DevKitTerminalCommand -ScriptPath (Join-Path $ScriptDir "DevKit.ps1") -WorkingDirectory $ScriptDir -NoWindowsTerminal:$NoWindowsTerminal
$script:CurrentRender = $null   # scriptblock that re-renders the active page
$script:SuppressSearch = $false
$script:SearchActive = $false      # a search page is currently shown
$script:PreSearchRender = $null    # page render to restore when the search is cleared

# ==================== SHARED UI HELPERS ====================

function Get-DevKitGuiResource([string]$Key) {
    return $window.FindResource($Key)
}

function New-DevKitGuiText([string]$Text, [string]$Style, [double]$Opacity = 1.0) {
    $t = New-Object Windows.Controls.TextBlock
    if ($Style) { $t.Style = Get-DevKitGuiResource $Style }
    $t.Text = $Text
    if ($Opacity -lt 1.0) { $t.Opacity = $Opacity }
    return $t
}

function New-DevKitGuiChip([string]$Text, [switch]$Caution) {
    $border = New-Object Windows.Controls.Border
    $border.Style = Get-DevKitGuiResource $(if ($Caution) { 'CautionChip' } else { 'TagChip' })
    $label = New-Object Windows.Controls.TextBlock
    $label.Style = Get-DevKitGuiResource $(if ($Caution) { 'CautionChipText' } else { 'TagChipText' })
    $label.Text = $Text
    $border.Child = $label
    return $border
}

function New-DevKitGuiButton([string]$Text, [string]$Style) {
    $btn = New-Object Windows.Controls.Button
    $btn.Style = Get-DevKitGuiResource $Style
    $btn.Content = $Text
    return $btn
}

function Set-DevKitGuiHeader([string]$Title, [string]$Description) {
    $ui.PageTitle.Text = $Title
    $ui.PageDescription.Text = $Description
    $ui.ContentScroll.ScrollToTop()
}

# ==================== DIALOG FRAMEWORK ====================
# Dialogs are built in code (variable field counts make static XAML a poor
# fit) but reuse every Theme style, so they look identical to the shell.

function New-DevKitGuiDialog {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [double]$Width = 480
    )

    $dlg = New-Object Windows.Window
    $dlg.Title = $Title
    $dlg.Width = $Width
    $dlg.MaxHeight = 640
    $dlg.SizeToContent = [Windows.SizeToContent]::Height
    $dlg.WindowStyle = [Windows.WindowStyle]::None
    $dlg.AllowsTransparency = $true
    $dlg.Background = [Windows.Media.Brushes]::Transparent
    $dlg.WindowStartupLocation = [Windows.WindowStartupLocation]::CenterOwner
    $dlg.Owner = $window
    $dlg.FontFamily = $window.FontFamily
    $dlg.Icon = $window.Icon

    $root = New-Object Windows.Controls.Border
    $root.Style = Get-DevKitGuiResource 'RootWindow'

    $grid = New-Object Windows.Controls.Grid
    $rowTop = New-Object Windows.Controls.RowDefinition; $rowTop.Height = [Windows.GridLength]::Auto
    $rowBody = New-Object Windows.Controls.RowDefinition; $rowBody.Height = [Windows.GridLength]::Auto
    $grid.RowDefinitions.Add($rowTop)
    $grid.RowDefinitions.Add($rowBody)
    $root.Child = $grid

    # Dialog title bar (draggable, close [x] at the right).
    $titleBorder = New-Object Windows.Controls.Border
    $titleBorder.Padding = '20,16,20,10'
    $titleGrid = New-Object Windows.Controls.Grid
    $colTitle = New-Object Windows.Controls.ColumnDefinition; $colTitle.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
    $colClose = New-Object Windows.Controls.ColumnDefinition; $colClose.Width = [Windows.GridLength]::Auto
    $titleGrid.ColumnDefinitions.Add($colTitle)
    $titleGrid.ColumnDefinitions.Add($colClose)
    $titleStack = New-Object Windows.Controls.StackPanel
    $titleText = New-DevKitGuiText $Title 'GroupTitle'
    $titleText.FontSize = 15
    $titleText.Foreground = Get-DevKitGuiResource 'BrushMetalGradient'
    $titleStack.Children.Add($titleText) | Out-Null
    $accent = New-Object Windows.Controls.Border
    $accent.Width = 36; $accent.Height = 3
    $accent.HorizontalAlignment = 'Left'
    $accent.Margin = '0,8,0,0'
    $accent.Background = Get-DevKitGuiResource 'BrushAccentGradient'
    $accent.CornerRadius = [Windows.CornerRadius]::new(2)
    $titleStack.Children.Add($accent) | Out-Null
    [Windows.Controls.Grid]::SetColumn($titleStack, 0)
    $titleGrid.Children.Add($titleStack) | Out-Null
    $closeBtn = New-DevKitGuiButton ([string][char]0xE8BB) 'ChromeButton'
    $closeBtn.ToolTip = 'Close'
    $closeBtn.VerticalAlignment = 'Top'
    [Windows.Controls.Grid]::SetColumn($closeBtn, 1)
    $closeBtn.Add_Click({ $dlg.Close() }.GetNewClosure())
    $titleGrid.Children.Add($closeBtn) | Out-Null
    $titleBorder.Child = $titleGrid
    $titleBorder.Add_MouseLeftButtonDown({
        param($s, $e)
        try { $dlg.DragMove() } catch { }
    }.GetNewClosure())
    [Windows.Controls.Grid]::SetRow($titleBorder, 0)
    $grid.Children.Add($titleBorder) | Out-Null

    # Body (scrollable).
    $scroll = New-Object Windows.Controls.ScrollViewer
    $scroll.VerticalScrollBarVisibility = 'Auto'
    $scroll.HorizontalScrollBarVisibility = 'Disabled'
    $body = New-Object Windows.Controls.StackPanel
    $body.Margin = '20,4,20,16'
    $scroll.Content = $body
    [Windows.Controls.Grid]::SetRow($scroll, 1)
    $grid.Children.Add($scroll) | Out-Null

    $dlg.Content = $root
    $dlg.Add_KeyDown({
        param($s, $e)
        if ($e.Key -eq 'Escape') { $s.Close() }
    })

    return @{ Window = $dlg; Body = $body }
}

function Add-DevKitGuiDialogButtons {
    param(
        [Parameter(Mandatory = $true)]$Dialog,
        [Parameter(Mandatory = $true)][array]$Buttons   # @( @{ Text; Style; OnClick (returns $true to close) } )
    )
    $row = New-Object Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'
    $row.HorizontalAlignment = 'Right'
    $row.Margin = '0,14,0,4'
    foreach ($spec in $Buttons) {
        $btn = New-DevKitGuiButton $spec.Text $spec.Style
        $btn.Margin = '8,0,0,0'
        # Keyboard flow: Enter activates the primary action, Esc cancels.
        # IsDefault is keyed off the PrimaryButton style so the DangerButton
        # of a destructive confirm (Show-DevKitGuiConfirm) never gets it.
        if ($spec.Style -eq 'PrimaryButton') { $btn.IsDefault = $true }
        if ($spec.Text -eq 'Cancel') { $btn.IsCancel = $true }
        $handler = $spec.OnClick
        $dlgWindow = $Dialog.Window
        $btn.Add_Click({
            param($s, $e)
            $shouldClose = & $handler
            if ($shouldClose) { $dlgWindow.Close() }
        }.GetNewClosure())
        $row.Children.Add($btn) | Out-Null
    }
    $Dialog.Body.Children.Add($row) | Out-Null
}

function Show-DevKitGuiMessage {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Message,
        [switch]$IsError
    )
    $dialog = New-DevKitGuiDialog -Title $Title
    $text = New-DevKitGuiText $Message 'PageDescriptionText'
    if ($IsError) { $text.Foreground = Get-DevKitGuiResource 'BrushAccentEmber' }
    $dialog.Body.Children.Add($text) | Out-Null
    Add-DevKitGuiDialogButtons -Dialog $dialog -Buttons @(
        @{ Text = 'OK'; Style = 'PrimaryButton'; OnClick = { $true } }
    )
    $dialog.Window.ShowDialog() | Out-Null
}

function Show-DevKitGuiConfirm {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$ConfirmText = 'Confirm'
    )
    $dialog = New-DevKitGuiDialog -Title $Title
    $dialog.Body.Children.Add((New-DevKitGuiText $Message 'PageDescriptionText')) | Out-Null
    $dialog.Window.Tag = $false
    Add-DevKitGuiDialogButtons -Dialog $dialog -Buttons @(
        @{ Text = 'Cancel'; Style = 'GhostButton'; OnClick = { $true } }
        @{ Text = $ConfirmText; Style = 'DangerButton'; OnClick = { $dialog.Window.Tag = $true; $true }.GetNewClosure() }
    )
    $dialog.Window.ShowDialog() | Out-Null
    return [bool]$dialog.Window.Tag
}

function Show-DevKitGuiTextInput {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Label,
        [string]$Initial = ''
    )
    $dialog = New-DevKitGuiDialog -Title $Title
    $dialog.Body.Children.Add((New-DevKitGuiText $Label 'GroupTitle')) | Out-Null
    $box = New-Object Windows.Controls.TextBox
    $box.Style = Get-DevKitGuiResource 'InputBox'
    $box.Height = 32
    $box.Margin = '0,8,0,0'
    $box.Text = $Initial
    $dialog.Body.Children.Add($box) | Out-Null
    $dialog.Window.Tag = $null
    Add-DevKitGuiDialogButtons -Dialog $dialog -Buttons @(
        @{ Text = 'Cancel'; Style = 'GhostButton'; OnClick = { $true } }
        @{ Text = 'OK'; Style = 'PrimaryButton'; OnClick = {
            if ([string]::IsNullOrWhiteSpace($box.Text)) { $dialog.Window.Tag = $null } else { $dialog.Window.Tag = $box.Text.Trim() }
            $true
        }.GetNewClosure() }
    )
    $dialog.Window.Add_ContentRendered({ $box.Focus() | Out-Null; $box.SelectAll() })
    $dialog.Window.ShowDialog() | Out-Null
    return $dialog.Window.Tag
}

# ==================== PICKERS ====================

function Show-DevKitGuiFolderPicker {
    param([string]$Description = 'Select a folder')
    # .NET 8 WPF ships a native folder dialog (pwsh 7.4+).
    try {
        $ofdType = 'Microsoft.Win32.OpenFolderDialog' -as [type]
        if ($ofdType) {
            $dlg = New-Object Microsoft.Win32.OpenFolderDialog
            $dlg.Title = $Description
            if ($dlg.ShowDialog($window)) { return $dlg.FolderName }
            return $null
        }
    } catch { }
    # Windows PowerShell 5.1: WinForms is in-box.
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
        $fbd.Description = $Description
        $fbd.ShowNewFolderButton = $false
        if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $fbd.SelectedPath }
        return $null
    } catch { }
    # Last resort: type it.
    return (Show-DevKitGuiTextInput -Title $Description -Label 'Folder path')
}

function Show-DevKitGuiProjectPicker {
    <# Returns a project path, or $null when cancelled. #>
    param([Parameter(Mandatory = $true)][string]$Title)

    $dialog = New-DevKitGuiDialog -Title "Choose project - $Title" -Width 560
    $dialog.Window.Tag = $null

    # Pinned projects first, then most-recently used.
    # -Descending applies to every sort key, so negating .pinned here (as a
    # prior version of this line did) inverted the intended order and put
    # pinned projects LAST. Match the canonical form used in lib/DevKit-Common.ps1.
    $projects = @(Get-DevKitLinkedProjects | Sort-Object -Property @{Expression = 'pinned'; Descending = $true }, @{Expression = 'lastUsedUtc'; Descending = $true })

    $radioList = New-Object Windows.Controls.StackPanel
    $radios = @()
    if ($projects.Count -eq 0) {
        $radioList.Children.Add((New-DevKitGuiText 'No linked projects yet - browse for a folder below to link one.' 'PageDescriptionText')) | Out-Null
    } else {
        foreach ($p in $projects) {
            $rb = New-Object Windows.Controls.RadioButton
            $rb.Style = Get-DevKitGuiResource 'NavRadioButton'
            $rb.GroupName = 'DevKitProjectPick'
            $rb.Tag = $p
            $rb.IsEnabled = -not $p.Missing
            $stack = New-Object Windows.Controls.StackPanel
            $nameText = New-DevKitGuiText '' 'CardTitle'
            $nameText.FontSize = 13
            if ($p.pinned) {
                # The pin is a Segoe MDL2 Assets PUA char; the inherited UI
                # font has no glyph for it (renders as tofu), so it gets its
                # own Run with the icon font.
                $pinRun = New-Object Windows.Documents.Run ([string][char]0xE718)
                $pinRun.FontFamily = New-Object Windows.Media.FontFamily 'Segoe MDL2 Assets'
                $nameText.Inlines.Add($pinRun) | Out-Null
                $nameText.Inlines.Add((New-Object Windows.Documents.Run "  $($p.name)")) | Out-Null
            } else {
                $nameText.Text = $p.name
            }
            $stack.Children.Add($nameText) | Out-Null
            $pathText = New-DevKitGuiText ($(if ($p.Missing) { "$($p.path)   (missing)" } else { $p.path })) 'StatusText'
            if ($p.Missing) { $pathText.Foreground = Get-DevKitGuiResource 'BrushAccentEmber' }
            $stack.Children.Add($pathText) | Out-Null
            $rb.Content = $stack
            $radioList.Children.Add($rb) | Out-Null
            $radios += $rb
        }
    }
    $dialog.Body.Children.Add($radioList) | Out-Null

    Add-DevKitGuiDialogButtons -Dialog $dialog -Buttons @(
        @{ Text = 'Browse...'; Style = 'GhostButton'; OnClick = {
            $picked = Show-DevKitGuiFolderPicker -Description 'Choose a project folder'
            if (-not [string]::IsNullOrWhiteSpace($picked)) {
                try {
                    $linked = Add-DevKitLinkedProject -Path $picked
                    Set-DevKitActiveProject -Id $linked.id
                    $dialog.Window.Tag = $linked.path
                    Update-DevKitGuiStatus
                } catch {
                    Show-DevKitGuiMessage -Title 'Cannot link project' -Message "$_" -IsError
                }
            }
            return ($null -ne $dialog.Window.Tag)
        }.GetNewClosure() }
        @{ Text = 'Cancel'; Style = 'GhostButton'; OnClick = { $true } }
        @{ Text = 'Use Selected'; Style = 'PrimaryButton'; OnClick = {
            $selected = $radios | Where-Object { $_.IsChecked } | Select-Object -First 1
            if ($selected) {
                $proj = $selected.Tag
                Set-DevKitActiveProject -Id $proj.id
                Update-DevKitGuiStatus
                $dialog.Window.Tag = $proj.path
                return $true
            }
            return $false   # nothing selected - keep the dialog open
        }.GetNewClosure() }
    )
    $dialog.Window.ShowDialog() | Out-Null
    return $dialog.Window.Tag
}

function Show-DevKitGuiFilePicker {
    <# Returns a file path, or $null when cancelled. #>
    param([Parameter(Mandatory = $true)][hashtable]$Item)

    $dialog = New-DevKitGuiDialog -Title "Choose file - $($Item.Label)"
    $dialog.Window.Tag = $null

    $desc = if ($Item.RequiresFile.Description) { $Item.RequiresFile.Description } else { 'Select the file to use.' }
    $dialog.Body.Children.Add((New-DevKitGuiText $desc 'PageDescriptionText')) | Out-Null

    $box = New-Object Windows.Controls.TextBox
    $box.Style = Get-DevKitGuiResource 'InputBox'
    $box.Height = 32
    $box.Margin = '0,10,0,0'
    $dialog.Body.Children.Add($box) | Out-Null

    Add-DevKitGuiDialogButtons -Dialog $dialog -Buttons @(
        @{ Text = 'Browse...'; Style = 'GhostButton'; OnClick = {
            try {
                $ofd = New-Object Microsoft.Win32.OpenFileDialog
                if ($Item.RequiresFile.Filter) { $ofd.Filter = $Item.RequiresFile.Filter }
                if ($ofd.ShowDialog($dialog.Window)) { $box.Text = $ofd.FileName }
            } catch { }
            return $false
        }.GetNewClosure() }
        @{ Text = 'Cancel'; Style = 'GhostButton'; OnClick = { $true } }
        @{ Text = 'OK'; Style = 'PrimaryButton'; OnClick = {
            if (-not [string]::IsNullOrWhiteSpace($box.Text)) {
                $dialog.Window.Tag = $box.Text.Trim()
                return $true
            }
            return $false
        }.GetNewClosure() }
    )
    $dialog.Window.Add_ContentRendered({ $box.Focus() | Out-Null }.GetNewClosure())
    $dialog.Window.ShowDialog() | Out-Null
    return $dialog.Window.Tag
}

function Show-DevKitGuiPromptForm {
    <#
        Builds a validated form for a manifest item's Prompts array
        (Int with Min/Max, YesNo checkbox, String; Optional honored).
        Returns a hashtable of values, or $null when cancelled.
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Item)

    $dialog = New-DevKitGuiDialog -Title $Item.Label -Width 500
    $dialog.Window.Tag = $null

    # Tool context up top: the Help excerpt, plus the safety-note sentence
    # highlighted in ember when the tool has one (mirrors the CAUTION chip
    # and the DangerButton run style on the card).
    $help = [string]$Item.Help
    $excerpt = Get-DevKitGuiHelpExcerpt -Help $help
    if (-not [string]::IsNullOrWhiteSpace($excerpt)) {
        $helpBlock = New-DevKitGuiText $excerpt 'PageDescriptionText'
        if ($excerpt -match 'Safety note') { $helpBlock.Foreground = Get-DevKitGuiResource 'BrushAccentEmber' }
        $dialog.Body.Children.Add($helpBlock) | Out-Null
    }
    if ($help -match 'Safety note' -and $excerpt -notmatch 'Safety note') {
        $safety = ([string](($help -split '\.\s+') | Where-Object { $_ -match 'Safety note' } | Select-Object -First 1)).Trim()
        if ($safety) {
            if (-not $safety.EndsWith('.')) { $safety += '.' }
            $safetyBlock = New-DevKitGuiText $safety 'PageDescriptionText'
            $safetyBlock.Foreground = Get-DevKitGuiResource 'BrushAccentEmber'
            $safetyBlock.Margin = '0,6,0,0'
            $dialog.Body.Children.Add($safetyBlock) | Out-Null
        }
    }

    $fields = @()
    $firstInput = $null
    foreach ($spec in $Item.Prompts) {
        $labelText = $spec.Prompt
        if ($spec.Optional) { $labelText += '   (optional)' }
        $label = New-DevKitGuiText $labelText 'GroupTitle'
        $label.Margin = '0,10,0,0'
        $dialog.Body.Children.Add($label) | Out-Null

        if ($spec.Type -eq 'YesNo') {
            $check = New-Object Windows.Controls.CheckBox
            $check.Margin = '0,6,0,0'
            $check.Content = 'Yes'
            $dialog.Body.Children.Add($check) | Out-Null
            $fields += @{ Spec = $spec; Control = $check }
            if ($null -eq $firstInput) { $firstInput = $check }
        } else {
            $box = New-Object Windows.Controls.TextBox
            $box.Style = Get-DevKitGuiResource 'InputBox'
            $box.Height = 32
            $box.Margin = '0,6,0,0'
            # A validation failure paints this box's border ember; typing
            # again clears it back to the style's border.
            $box.Add_TextChanged({ param($s, $e) $s.ClearValue([Windows.Controls.Control]::BorderBrushProperty) })
            $dialog.Body.Children.Add($box) | Out-Null
            $fields += @{ Spec = $spec; Control = $box }
            if ($null -eq $firstInput) { $firstInput = $box }
        }
    }

    $errorText = New-DevKitGuiText '' 'StatusText'
    $errorText.Foreground = Get-DevKitGuiResource 'BrushAccentEmber'
    $errorText.Margin = '0,10,0,0'
    $dialog.Body.Children.Add($errorText) | Out-Null

    Add-DevKitGuiDialogButtons -Dialog $dialog -Buttons @(
        @{ Text = 'Cancel'; Style = 'GhostButton'; OnClick = { $true } }
        @{ Text = 'Run'; Style = 'PrimaryButton'; OnClick = {
            $values = @{}
            foreach ($field in $fields) {
                $spec = $field.Spec
                if ($spec.Type -eq 'YesNo') {
                    $values[$spec.Name] = [bool]$field.Control.IsChecked
                    continue
                }
                $raw = $field.Control.Text
                if ([string]::IsNullOrWhiteSpace($raw)) {
                    if ($spec.Optional) { continue }
                    $errorText.Text = $(if ($spec.InvalidMessage) { $spec.InvalidMessage } else { "A value is required for '$($spec.Prompt)'." })
                    $field.Control.BorderBrush = Get-DevKitGuiResource 'BrushAccentEmber'
                    return $false
                }
                if ($spec.Type -eq 'Int') {
                    $parsed = 0
                    if (-not [int]::TryParse($raw.Trim(), [ref]$parsed)) {
                        $errorText.Text = $(if ($spec.InvalidMessage) { $spec.InvalidMessage } else { "'$($raw)' is not a valid number." })
                        $field.Control.BorderBrush = Get-DevKitGuiResource 'BrushAccentEmber'
                        return $false
                    }
                    if ($null -ne $spec.Min -and $parsed -lt [int]$spec.Min) {
                        $errorText.Text = $(if ($spec.InvalidMessage) { $spec.InvalidMessage } else { "Value must be at least $($spec.Min)." })
                        $field.Control.BorderBrush = Get-DevKitGuiResource 'BrushAccentEmber'
                        return $false
                    }
                    if ($null -ne $spec.Max -and $parsed -gt [int]$spec.Max) {
                        $errorText.Text = $(if ($spec.InvalidMessage) { $spec.InvalidMessage } else { "Value must be at most $($spec.Max)." })
                        $field.Control.BorderBrush = Get-DevKitGuiResource 'BrushAccentEmber'
                        return $false
                    }
                    $values[$spec.Name] = $parsed
                } else {
                    $values[$spec.Name] = $raw.Trim()
                }
            }
            $dialog.Window.Tag = $values
            return $true
        }.GetNewClosure() }
    )
    if ($firstInput) { $dialog.Window.Add_ContentRendered({ $firstInput.Focus() | Out-Null }.GetNewClosure()) }
    $dialog.Window.ShowDialog() | Out-Null
    return $dialog.Window.Tag
}

# ==================== TOOL LAUNCH ====================

function Register-DevKitGuiLaunchFeedback {
    <#
    .SYNOPSIS
        Post-launch UI feedback: flashes 'Launched ✓' on the clicked button
        (restored after 2.5s) and reverts the status bar's terminal text to
        the terminal-capability string after ~6s. Both are DispatcherTimers,
        so they fire on the UI thread without blocking it.
    #>
    param([Windows.Controls.Button]$Button)

    if ($Button) {
        $original = $Button.Content
        $Button.Content = "Launched $([char]0x2713)"
        $buttonTimer = New-Object Windows.Threading.DispatcherTimer
        $buttonTimer.Interval = [TimeSpan]::FromSeconds(2.5)
        $buttonTimer.Add_Tick({
            param($s, $e)
            $s.Stop()
            $Button.Content = $original
        }.GetNewClosure())
        $buttonTimer.Start()
    }

    # A single reused script-scope timer (same pattern as
    # $script:SearchDebounceTimer below) so a second launch within 6s of the
    # first stops the first countdown instead of letting it fire later and
    # wipe out the newer "Launched: ..." status message.
    if (-not $script:StatusFeedbackTimer) {
        $script:StatusFeedbackTimer = New-Object Windows.Threading.DispatcherTimer
        $script:StatusFeedbackTimer.Interval = [TimeSpan]::FromSeconds(6)
        $script:StatusFeedbackTimer.Add_Tick({
            $script:StatusFeedbackTimer.Stop()
            Update-DevKitGuiStatus
        })
    }
    $script:StatusFeedbackTimer.Stop()
    $script:StatusFeedbackTimer.Start()
}

function Invoke-DevKitGuiTool {
    param(
        [Parameter(Mandatory = $true)][string]$FolderPath,
        [Parameter(Mandatory = $true)][hashtable]$Item,
        [Windows.Controls.Button]$SourceButton
    )

    $values = @{}

    # Project: reuse the active project silently (exactly what the TUI's
    # Select-DevKitProject does without -ForceReprompt); only ask when none
    # is linked. The status bar shows which project will be used, and the
    # Projects page changes it.
    if ($Item.RequiresProject) {
        $argName = if ($Item.ProjectArgName) { $Item.ProjectArgName } else { 'Path' }
        $active = Get-DevKitActiveProject
        if ($active -and -not $active.Missing) {
            Update-DevKitProjectLastUsed -Id $active.id
            $values[$argName] = $active.path
        } else {
            $picked = Show-DevKitGuiProjectPicker -Title $Item.Label
            if ([string]::IsNullOrWhiteSpace([string]$picked)) { return }
            $values[$argName] = $picked
        }
    } elseif ($Item.RequiresFile) {
        $filePath = Show-DevKitGuiFilePicker -Item $Item
        if ([string]::IsNullOrWhiteSpace([string]$filePath)) { return }
        $values[$Item.RequiresFile.ParamName] = $filePath
    }

    if ($Item.Prompts -and $Item.Prompts.Count -gt 0) {
        $promptValues = Show-DevKitGuiPromptForm -Item $Item
        if ($null -eq $promptValues) { return }
        foreach ($key in $promptValues.Keys) { $values[$key] = $promptValues[$key] }
    }

    try {
        $callArgs = ConvertTo-DevKitToolArguments -Item $Item -Values $values
    } catch {
        Show-DevKitGuiMessage -Title 'Cannot run tool' -Message "$_" -IsError
        return
    }

    $scriptPath = Join-Path $FolderPath $Item.Script
    if (-not (Test-Path $scriptPath)) {
        Show-DevKitGuiMessage -Title 'Cannot run tool' -Message "Script not found: $scriptPath" -IsError
        return
    }

    $launch = Get-DevKitTerminalCommand -ScriptPath $scriptPath -Arguments $callArgs `
        -WorkingDirectory $ScriptDir -Title $Item.Label -NoWindowsTerminal:$NoWindowsTerminal
    if (-not $launch.FilePath) {
        Show-DevKitGuiMessage -Title 'Cannot run tool' -Message 'No PowerShell executable (pwsh or powershell) was found on PATH.' -IsError
        return
    }

    try {
        Start-Process -FilePath $launch.FilePath -ArgumentList $launch.Arguments -WorkingDirectory $launch.WorkingDirectory
        $ui.StatusTerminalText.Text = "Launched: $($Item.Label)  |  $($script:TerminalProbe.Terminal) + $($script:TerminalProbe.Shell)"
        Register-DevKitGuiLaunchFeedback -Button $SourceButton
    } catch {
        Show-DevKitGuiMessage -Title 'Cannot run tool' -Message "Failed to start the terminal: $_" -IsError
    }
}

# ==================== CARDS & PAGES ====================

function Get-DevKitGuiHelpExcerpt {
    param([string]$Help)
    if ([string]::IsNullOrWhiteSpace($Help)) { return '' }
    $firstSentence = ($Help -split '\.\s+')[0].Trim()
    if ($firstSentence.Length -gt 170) { $firstSentence = $firstSentence.Substring(0, 167).TrimEnd() + '...' }
    if ($firstSentence.Length -lt $Help.Length -and -not $firstSentence.EndsWith('...')) { $firstSentence += '.' }
    return $firstSentence
}

function New-DevKitGuiToolCard {
    param(
        [Parameter(Mandatory = $true)][string]$ModuleName,
        [Parameter(Mandatory = $true)][string]$FolderPath,
        [Parameter(Mandatory = $true)][hashtable]$Item,
        [switch]$ShowModule
    )

    $card = New-Object Windows.Controls.Border
    $card.Style = Get-DevKitGuiResource 'ToolCard'

    if (-not [string]::IsNullOrWhiteSpace([string]$Item.Help)) {
        $tip = New-Object Windows.Controls.TextBlock
        $tip.Text = $Item.Help
        $tip.TextWrapping = 'Wrap'
        $tip.MaxWidth = 480
        $tip.Foreground = Get-DevKitGuiResource 'BrushTextMuted'
        $tip.FontSize = 12
        $card.ToolTip = $tip
    }

    $grid = New-Object Windows.Controls.Grid
    $colMain = New-Object Windows.Controls.ColumnDefinition; $colMain.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
    $colRun = New-Object Windows.Controls.ColumnDefinition; $colRun.Width = [Windows.GridLength]::Auto
    $grid.ColumnDefinitions.Add($colMain)
    $grid.ColumnDefinitions.Add($colRun)
    $card.Child = $grid

    $stack = New-Object Windows.Controls.StackPanel
    $stack.Children.Add((New-DevKitGuiText $Item.Label 'CardTitle')) | Out-Null

    # Chips: what this tool needs / what to watch out for.
    $chips = New-Object Windows.Controls.StackPanel
    $chips.Orientation = 'Horizontal'
    $chips.Margin = '0,8,0,0'
    $hasChip = $false
    if ($ShowModule) { $chips.Children.Add((New-DevKitGuiChip $ModuleName.ToUpper())) | Out-Null; $hasChip = $true }
    if ($Item.RequiresProject) { $chips.Children.Add((New-DevKitGuiChip 'PROJECT')) | Out-Null; $hasChip = $true }
    if ($Item.RequiresFile) { $chips.Children.Add((New-DevKitGuiChip 'FILE')) | Out-Null; $hasChip = $true }
    if ($Item.Prompts -and $Item.Prompts.Count -gt 0) { $chips.Children.Add((New-DevKitGuiChip 'INPUT')) | Out-Null; $hasChip = $true }
    if ([string]$Item.Help -match 'Safety note') { $chips.Children.Add((New-DevKitGuiChip 'CAUTION' -Caution)) | Out-Null; $hasChip = $true }
    if ($hasChip) { $stack.Children.Add($chips) | Out-Null }

    $excerpt = Get-DevKitGuiHelpExcerpt -Help ([string]$Item.Help)
    if (-not [string]::IsNullOrWhiteSpace($excerpt)) {
        $stack.Children.Add((New-DevKitGuiText $excerpt 'CardSubtitle')) | Out-Null
    }
    [Windows.Controls.Grid]::SetColumn($stack, 0)
    $grid.Children.Add($stack) | Out-Null

    $runButton = New-DevKitGuiButton 'Run' $(if ([string]$Item.Help -match 'Safety note') { 'DangerButton' } else { 'AccentButton' })
    $runButton.VerticalAlignment = 'Center'
    $runButton.Margin = '16,0,0,0'
    [Windows.Controls.Grid]::SetColumn($runButton, 1)
    $runButton.Add_Click({ Invoke-DevKitGuiTool -FolderPath $FolderPath -Item $Item -SourceButton $runButton }.GetNewClosure())
    $grid.Children.Add($runButton) | Out-Null

    return $card
}

function Show-DevKitGuiCategoryPage {
    param([Parameter(Mandatory = $true)]$Module)

    Set-DevKitGuiHeader $Module.Name ([string]$Module.Description)
    $ui.ContentPanel.Children.Clear()
    foreach ($item in $Module.Items) {
        $ui.ContentPanel.Children.Add((New-DevKitGuiToolCard -ModuleName $Module.Name -FolderPath $Module.FolderPath -Item $item)) | Out-Null
    }
    $script:CurrentRender = { Show-DevKitGuiCategoryPage -Module $Module }.GetNewClosure()
}

function Show-DevKitGuiSearchPage {
    param([Parameter(Mandatory = $true)][string]$Keyword)

    $found = @(Search-DevKitGuiTools -Catalog $script:Catalog -Keyword $Keyword)
    $summary = if ($found.Count -eq 0) { "No tools match '$Keyword'." }
               elseif ($found.Count -eq 1) { "1 tool matches '$Keyword'." }
               else { "$($found.Count) tools match '$Keyword'." }
    Set-DevKitGuiHeader "Search" $summary
    $ui.ContentPanel.Children.Clear()
    if ($found.Count -eq 0) {
        $empty = New-DevKitGuiText "Nothing found - try a keyword like 'port', 'cache', 'docker', 'wifi', 'env' or 'mcp'." 'PageDescriptionText'
        $empty.Foreground = Get-DevKitGuiResource 'BrushTextDim'
        $empty.HorizontalAlignment = 'Center'
        $empty.TextAlignment = 'Center'
        $empty.Margin = '0,60,0,0'
        $ui.ContentPanel.Children.Add($empty) | Out-Null
    }
    foreach ($hit in $found) {
        $ui.ContentPanel.Children.Add((New-DevKitGuiToolCard -ModuleName $hit.ModuleName -FolderPath $hit.FolderPath -Item $hit.Item -ShowModule)) | Out-Null
    }
    $script:CurrentRender = { Show-DevKitGuiSearchPage -Keyword $Keyword }.GetNewClosure()
}

function Show-DevKitGuiProjectsPage {
    # Project action buttons re-render this page in place; keep the user's
    # scroll position for those (nav switches still land at the top via
    # Set-DevKitGuiHeader's ScrollToTop).
    param([switch]$PreserveScroll)

    $scrollOffset = if ($PreserveScroll) { $ui.ContentScroll.VerticalOffset } else { 0 }
    Set-DevKitGuiHeader 'Projects' 'Link the folders you work in once, then every project-scoped tool runs against your Active Project without asking. The Active Project is shared with the terminal UI and shown in the status bar below.'
    $ui.ContentPanel.Children.Clear()

    $registry = Get-DevKitProjectRegistry
    $activeId = $registry.activeProjectId
    # -Descending applies to every sort key, so negating .pinned here (as a
    # prior version of this line did) inverted the intended order and put
    # pinned projects LAST. Match the canonical form used in lib/DevKit-Common.ps1.
    $projects = @(Get-DevKitLinkedProjects | Sort-Object -Property @{Expression = 'pinned'; Descending = $true }, @{Expression = 'lastUsedUtc'; Descending = $true })

    # --- Active project banner ---
    $activeCard = New-Object Windows.Controls.Border
    $activeCard.Style = Get-DevKitGuiResource 'ToolCard'
    $activeCard.BorderBrush = Get-DevKitGuiResource 'BrushAccentBlue'
    $activeStack = New-Object Windows.Controls.StackPanel
    $activeStack.Children.Add((New-DevKitGuiText 'ACTIVE PROJECT' 'GroupTitle')) | Out-Null
    if ($activeId) {
        $active = $projects | Where-Object { $_.id -eq $activeId } | Select-Object -First 1
        if ($active) {
            $nameText = New-DevKitGuiText $active.name 'CardTitle'
            $nameText.Margin = '0,6,0,0'
            $activeStack.Children.Add($nameText) | Out-Null
            $activeStack.Children.Add((New-DevKitGuiText $active.path 'StatusText')) | Out-Null
            $clearBtn = New-DevKitGuiButton 'Clear Active Project' 'GhostButton'
            $clearBtn.HorizontalAlignment = 'Left'
            $clearBtn.Margin = '0,10,0,0'
            $clearBtn.Add_Click({ Clear-DevKitActiveProject; Update-DevKitGuiStatus; Show-DevKitGuiProjectsPage -PreserveScroll })
            $activeStack.Children.Add($clearBtn) | Out-Null
        }
    } else {
        $noneText = New-DevKitGuiText 'No active project. Pick one below, or link a new folder.' 'PageDescriptionText'
        $noneText.Margin = '0,6,0,0'
        $activeStack.Children.Add($noneText) | Out-Null
    }
    $activeCard.Child = $activeStack
    $ui.ContentPanel.Children.Add($activeCard) | Out-Null

    # --- Linked projects ---
    $groupHeader = New-DevKitGuiText "LINKED PROJECTS  ($($projects.Count))" 'GroupTitle'
    $groupHeader.Margin = '0,10,0,10'
    $ui.ContentPanel.Children.Add($groupHeader) | Out-Null

    foreach ($p in $projects) {
        $card = New-Object Windows.Controls.Border
        $card.Style = Get-DevKitGuiResource 'ToolCard'

        $grid = New-Object Windows.Controls.Grid
        $colInfo = New-Object Windows.Controls.ColumnDefinition; $colInfo.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
        $colActions = New-Object Windows.Controls.ColumnDefinition; $colActions.Width = [Windows.GridLength]::Auto
        $grid.ColumnDefinitions.Add($colInfo)
        $grid.ColumnDefinitions.Add($colActions)

        $info = New-Object Windows.Controls.StackPanel
        $nameRow = New-Object Windows.Controls.StackPanel
        $nameRow.Orientation = 'Horizontal'
        $nameText = New-DevKitGuiText $p.name 'CardTitle'
        $nameRow.Children.Add($nameText) | Out-Null
        $chips = New-Object Windows.Controls.StackPanel
        $chips.Orientation = 'Horizontal'
        $chips.Margin = '12,2,0,0'
        if ($p.id -eq $activeId) { $chips.Children.Add((New-DevKitGuiChip 'ACTIVE')) | Out-Null }
        if ($p.pinned) { $chips.Children.Add((New-DevKitGuiChip 'PINNED')) | Out-Null }
        if ($p.Missing) { $chips.Children.Add((New-DevKitGuiChip 'MISSING' -Caution)) | Out-Null }
        foreach ($tag in @($p.tags)) { $chips.Children.Add((New-DevKitGuiChip ([string]$tag).ToUpper())) | Out-Null }
        if ($chips.Children.Count -gt 0) { $nameRow.Children.Add($chips) | Out-Null }
        $info.Children.Add($nameRow) | Out-Null
        $pathText = New-DevKitGuiText $p.path 'StatusText'
        $pathText.Margin = '0,5,0,0'
        if ($p.Missing) { $pathText.Foreground = Get-DevKitGuiResource 'BrushAccentEmber' }
        $info.Children.Add($pathText) | Out-Null
        [Windows.Controls.Grid]::SetColumn($info, 0)
        $grid.Children.Add($info) | Out-Null

        # Action buttons (each closure captures its own project object).
        $actions = New-Object Windows.Controls.StackPanel
        $actions.Orientation = 'Horizontal'
        $actions.VerticalAlignment = 'Center'
        $project = $p

        if ($p.id -ne $activeId -and -not $p.Missing) {
            $setActiveBtn = New-DevKitGuiButton 'Set Active' 'AccentButton'
            $setActiveBtn.Margin = '6,0,0,0'
            $setActiveBtn.Add_Click({ Set-DevKitActiveProject -Id $project.id; Update-DevKitGuiStatus; Show-DevKitGuiProjectsPage -PreserveScroll }.GetNewClosure())
            $actions.Children.Add($setActiveBtn) | Out-Null
        }
        if (-not $p.Missing) {
            $pinBtn = New-DevKitGuiButton $(if ($p.pinned) { 'Unpin' } else { 'Pin' }) 'GhostButton'
            $pinBtn.Margin = '6,0,0,0'
            $pinBtn.Add_Click({ Set-DevKitProjectPinned -Id $project.id -Pinned (-not $project.pinned); Show-DevKitGuiProjectsPage -PreserveScroll }.GetNewClosure())
            $actions.Children.Add($pinBtn) | Out-Null

            $renameBtn = New-DevKitGuiButton 'Rename' 'GhostButton'
            $renameBtn.Margin = '6,0,0,0'
            $renameBtn.Add_Click({
                $newName = Show-DevKitGuiTextInput -Title 'Rename project' -Label 'Display name' -Initial $project.name
                if (-not [string]::IsNullOrWhiteSpace($newName)) {
                    Rename-DevKitLinkedProject -Id $project.id -NewName $newName
                    Update-DevKitGuiStatus
                    Show-DevKitGuiProjectsPage -PreserveScroll
                }
            }.GetNewClosure())
            $actions.Children.Add($renameBtn) | Out-Null
        } else {
            $relinkBtn = New-DevKitGuiButton 'Relink...' 'GhostButton'
            $relinkBtn.Margin = '6,0,0,0'
            $relinkBtn.Add_Click({
                $newPath = Show-DevKitGuiFolderPicker -Description "Relink '$($project.name)' to its new folder"
                if (-not [string]::IsNullOrWhiteSpace($newPath)) {
                    try {
                        Repair-DevKitLinkedProject -Id $project.id -NewPath $newPath
                        Update-DevKitGuiStatus
                        Show-DevKitGuiProjectsPage -PreserveScroll
                    } catch {
                        Show-DevKitGuiMessage -Title 'Cannot relink' -Message "$_" -IsError
                    }
                }
            }.GetNewClosure())
            $actions.Children.Add($relinkBtn) | Out-Null
        }
        $removeBtn = New-DevKitGuiButton 'Remove' 'DangerButton'
        $removeBtn.Margin = '6,0,0,0'
        $removeBtn.Add_Click({
            $yes = Show-DevKitGuiConfirm -Title 'Remove project' -Message "Remove '$($project.name)' from the linked projects? The folder itself is not touched." -ConfirmText 'Remove'
            if ($yes) {
                Remove-DevKitLinkedProject -Id $project.id
                Update-DevKitGuiStatus
                Show-DevKitGuiProjectsPage -PreserveScroll
            }
        }.GetNewClosure())
        $actions.Children.Add($removeBtn) | Out-Null

        [Windows.Controls.Grid]::SetColumn($actions, 1)
        $grid.Children.Add($actions) | Out-Null
        $card.Child = $grid
        $ui.ContentPanel.Children.Add($card) | Out-Null
    }

    $linkBtn = New-DevKitGuiButton '+  Link a project folder' 'PrimaryButton'
    $linkBtn.HorizontalAlignment = 'Left'
    $linkBtn.Margin = '0,6,0,0'
    $linkBtn.Add_Click({
        $picked = Show-DevKitGuiFolderPicker -Description 'Choose a project folder to link'
        if (-not [string]::IsNullOrWhiteSpace($picked)) {
            try {
                $linked = Add-DevKitLinkedProject -Path $picked
                Set-DevKitActiveProject -Id $linked.id
                Update-DevKitGuiStatus
                Show-DevKitGuiProjectsPage -PreserveScroll
            } catch {
                Show-DevKitGuiMessage -Title 'Cannot link project' -Message "$_" -IsError
            }
        }
    })
    $ui.ContentPanel.Children.Add($linkBtn) | Out-Null

    if ($PreserveScroll) {
        # The new content's extent only exists after the next layout pass, so
        # restore the offset then (calling ScrollToVerticalOffset right away
        # would clamp against the still-collapsed extent).
        $ui.ContentScroll.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Loaded,
            [action]{ $ui.ContentScroll.ScrollToVerticalOffset($scrollOffset) }.GetNewClosure()) | Out-Null
    }

    $script:CurrentRender = { Show-DevKitGuiProjectsPage }
}

function Show-DevKitGuiAboutPage {
    Set-DevKitGuiHeader 'Getting Started' 'Northstar DevKit bundles your everyday Node/Next.js/Vite/Git/Docker maintenance tools into one branded console.'
    $ui.ContentPanel.Children.Clear()

    $hero = New-Object Windows.Controls.Border
    $hero.Style = Get-DevKitGuiResource 'ToolCard'
    $heroGrid = New-Object Windows.Controls.Grid
    $colLogo = New-Object Windows.Controls.ColumnDefinition; $colLogo.Width = [Windows.GridLength]::Auto
    $colText = New-Object Windows.Controls.ColumnDefinition; $colText.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
    $heroGrid.ColumnDefinitions.Add($colLogo)
    $heroGrid.ColumnDefinitions.Add($colText)

    $logo = New-Object Windows.Controls.Image
    $logo.Source = $logoBitmap
    $logo.Width = 96; $logo.Height = 96
    $logo.Margin = '4,4,18,4'
    [Windows.Controls.Grid]::SetColumn($logo, 0)
    $heroGrid.Children.Add($logo) | Out-Null

    $heroText = New-Object Windows.Controls.StackPanel
    $heroText.VerticalAlignment = 'Center'
    $title = New-DevKitGuiText 'Northstar DevKit' 'PageTitleText'
    $title.FontSize = 20
    $heroText.Children.Add($title) | Out-Null
    $sub = New-DevKitGuiText "Version $DevKitVersion  |  by Northstar Software Development" 'StatusText'
    $sub.Margin = '0,6,0,0'
    $heroText.Children.Add($sub) | Out-Null
    $links = New-Object Windows.Controls.StackPanel
    $links.Orientation = 'Horizontal'
    $links.Margin = '0,12,0,0'
    $siteBtn = New-DevKitGuiButton 'northstarcoding.com' 'GhostButton'
    $siteBtn.Add_Click({ Start-Process 'https://www.northstarcoding.com' })
    $links.Children.Add($siteBtn) | Out-Null
    $folderBtn = New-DevKitGuiButton 'Open install folder' 'GhostButton'
    $folderBtn.Margin = '8,0,0,0'
    $folderBtn.Add_Click({ Start-Process 'explorer.exe' -ArgumentList "`"$ScriptDir`"" })
    $links.Children.Add($folderBtn) | Out-Null
    $terminalBtn = New-DevKitGuiButton 'Open terminal UI' 'GhostButton'
    $terminalBtn.Margin = '8,0,0,0'
    $terminalBtn.ToolTip = 'Launch the classic interactive menu (DevKit.bat)'
    $terminalBtn.Add_Click({ Start-Process (Join-Path $ScriptDir 'DevKit.bat') -WorkingDirectory $ScriptDir })
    $links.Children.Add($terminalBtn) | Out-Null
    $widgetBtn = New-DevKitGuiButton 'Launch companion widget' 'GhostButton'
    $widgetBtn.Margin = '8,0,0,0'
    $widgetBtn.ToolTip = 'Metrics, node processes, and MCP status on your desktop - keeps running in the system tray'
    $widgetBtn.Add_Click({ Start-DevKitCompanionWidget -SourceButton $widgetBtn }.GetNewClosure())
    $links.Children.Add($widgetBtn) | Out-Null
    $heroText.Children.Add($links) | Out-Null
    [Windows.Controls.Grid]::SetColumn($heroText, 1)
    $heroGrid.Children.Add($heroText) | Out-Null
    $hero.Child = $heroGrid
    $ui.ContentPanel.Children.Add($hero) | Out-Null

    $howCard = New-Object Windows.Controls.Border
    $howCard.Style = Get-DevKitGuiResource 'ToolCard'
    $howStack = New-Object Windows.Controls.StackPanel
    $howStack.Children.Add((New-DevKitGuiText 'HOW IT WORKS' 'GroupTitle')) | Out-Null
    $bullets = @(
        'Pick a category on the left, then press Run on any tool card.',
        "Tools open in their own terminal window ($($script:TerminalProbe.Terminal) when available) with the same menus, colors, and confirmations as the classic terminal UI - nothing is re-implemented or dumbed down.",
        'Tools marked PROJECT run against your Active Project automatically. Link projects from the Projects page; the choice is shared with the terminal UI.',
        'Tools marked CAUTION change real system state - read the tooltip on the card before running them. Their terminal window always asks for confirmation first.',
        'The classic terminal UI is unchanged: run DevKit.bat any time.',
        'The companion widget (gauge icon, top right) keeps system metrics, node processes, and MCP status on your desktop after DevKit closes - it lives in the system tray.'
    )
    foreach ($bullet in $bullets) {
        $b = New-DevKitGuiText $bullet 'PageDescriptionText'
        $b.Margin = '0,8,0,0'
        $howStack.Children.Add($b) | Out-Null
    }
    if (-not (Test-DevKitAdmin)) {
        $adminNote = New-DevKitGuiText 'Some maintenance tools need an elevated session.' 'PageDescriptionText'
        $adminNote.Margin = '0,12,0,0'
        $howStack.Children.Add($adminNote) | Out-Null
        $elevateBtn = New-DevKitGuiButton 'Restart as Administrator' 'DangerButton'
        $elevateBtn.HorizontalAlignment = 'Left'
        $elevateBtn.Margin = '0,8,0,0'
        $elevateBtn.Add_Click({
            $shellExe = "$($script:TerminalProbe.Shell).exe"
            $guiScript = Join-Path $GuiDir 'DevKit-GUI.ps1'
            $argList = "-NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File `"$guiScript`""
            if ($NoWindowsTerminal) { $argList += ' -NoWindowsTerminal' }
            try {
                Start-Process $shellExe -Verb RunAs -ArgumentList $argList
                $window.Close()
            } catch { }
        })
        $howStack.Children.Add($elevateBtn) | Out-Null
    }
    $howCard.Child = $howStack
    $ui.ContentPanel.Children.Add($howCard) | Out-Null

    $script:CurrentRender = { Show-DevKitGuiAboutPage }
}

# ==================== STATUS BAR ====================

function Update-DevKitGuiStatus {
    $active = Get-DevKitActiveProject
    $ui.StatusProjectText.Inlines.Clear()
    if ($active -and -not $active.Missing) {
        $run1 = New-Object Windows.Documents.Run 'Active project:  '
        $run1.Foreground = Get-DevKitGuiResource 'BrushTextDim'
        $run2 = New-Object Windows.Documents.Run $active.name
        $run2.Foreground = Get-DevKitGuiResource 'BrushAccentBlue'
        $run2.FontWeight = 'SemiBold'
        $ui.StatusProjectText.Inlines.Add($run1) | Out-Null
        $ui.StatusProjectText.Inlines.Add($run2) | Out-Null
    } elseif ($active -and $active.Missing) {
        $run1 = New-Object Windows.Documents.Run 'Active project:  '
        $run1.Foreground = Get-DevKitGuiResource 'BrushTextDim'
        $run2 = New-Object Windows.Documents.Run "$($active.name) (path missing - relink it)"
        $run2.Foreground = Get-DevKitGuiResource 'BrushAccentEmber'
        $ui.StatusProjectText.Inlines.Add($run1) | Out-Null
        $ui.StatusProjectText.Inlines.Add($run2) | Out-Null
    } else {
        $run1 = New-Object Windows.Documents.Run 'No active project - link one'
        $run1.Foreground = Get-DevKitGuiResource 'BrushTextDim'
        $ui.StatusProjectText.Inlines.Add($run1) | Out-Null
    }

    $terminalLabel = if ($script:TerminalProbe.Terminal -eq 'WindowsTerminal') { 'Windows Terminal' } else { 'Console host' }
    $ui.StatusTerminalText.Text = "$terminalLabel + $($script:TerminalProbe.Shell)"
    $ui.AdminBadge.Visibility = if (Test-DevKitAdmin) { 'Visible' } else { 'Collapsed' }
}

# ==================== NAVIGATION ====================

$script:NavRadios = @()

function Add-DevKitGuiNavItem {
    param([string]$Label, $Tag)
    $rb = New-Object Windows.Controls.RadioButton
    $rb.Style = Get-DevKitGuiResource 'NavRadioButton'
    $rb.Content = $Label
    $rb.Tag = $Tag
    $rb.GroupName = 'DevKitNav'
    # Module tags carry the manifest's description; string tags (Projects /
    # Getting Started) have none to show.
    if ($Tag -isnot [string] -and $Tag.Description) { $rb.ToolTip = [string]$Tag.Description }
    $rb.Add_Checked({
        param($s, $e)
        if ($script:NavSuspend) { return }
        # Clear any in-progress search without re-triggering the search page.
        $script:SuppressSearch = $true
        $ui.SearchBox.Text = ''
        $ui.SearchWatermark.Visibility = 'Visible'
        $script:SuppressSearch = $false
        $script:SearchActive = $false
        $script:PreSearchRender = $null
        $tag = $s.Tag
        if ($tag -is [string] -and $tag -eq 'projects') { Show-DevKitGuiProjectsPage }
        elseif ($tag -is [string] -and $tag -eq 'about') { Show-DevKitGuiAboutPage }
        else { Show-DevKitGuiCategoryPage -Module $tag }
    })
    $ui.NavList.Children.Add($rb) | Out-Null
    $script:NavRadios += $rb
    return $rb
}

foreach ($group in $script:Catalog) {
    $header = New-DevKitGuiText $group.Group.ToUpper() 'NavHeader'
    $ui.NavList.Children.Add($header) | Out-Null
    foreach ($module in $group.Modules) {
        Add-DevKitGuiNavItem -Label $module.Name -Tag $module | Out-Null
    }
}
$separator = New-Object Windows.Controls.Border
$separator.Style = Get-DevKitGuiResource 'ThinSeparator'
$ui.NavList.Children.Add($separator) | Out-Null
$projectsNav = Add-DevKitGuiNavItem -Label 'Projects' -Tag 'projects'
$aboutNav = Add-DevKitGuiNavItem -Label 'Getting Started' -Tag 'about'

# Status-bar project button jumps to the Projects page.
$ui.StatusProjectButton.Add_Click({
    $script:NavSuspend = $true
    foreach ($rb in $script:NavRadios) { $rb.IsChecked = $false }
    $script:NavSuspend = $false
    $projectsNav.IsChecked = $true
})

# ==================== SEARCH ====================

# Debounce: re-rendering the results page on every keystroke is expensive, so
# TextChanged only does the cheap watermark toggle inline and restarts this
# one-shot ~150ms timer; the actual search/restore render runs in its Tick
# once typing pauses. The Tick re-reads the box, so it always renders the
# latest text (a stale pending Tick after a SuppressSearch clear sees an
# empty query with SearchActive already false and does nothing).
$script:SearchDebounceTimer = New-Object Windows.Threading.DispatcherTimer
$script:SearchDebounceTimer.Interval = [TimeSpan]::FromMilliseconds(150)
$script:SearchDebounceTimer.Add_Tick({
    $script:SearchDebounceTimer.Stop()
    $query = $ui.SearchBox.Text.Trim()
    if ($query.Length -ge 2) {
        # First keystrokes of a search: remember the page to go back to, so
        # clearing (or shrinking) the box restores it instead of replaying a
        # stale search render (CurrentRender points at the search page now).
        if (-not $script:SearchActive) {
            $script:PreSearchRender = $script:CurrentRender
            $script:PreSearchNav = @($script:NavRadios) + @($script:AboutNav) | Where-Object { $_.IsChecked } | Select-Object -First 1
            $script:SearchActive = $true
        }
        $script:NavSuspend = $true
        foreach ($rb in $script:NavRadios) { $rb.IsChecked = $false }
        $script:NavSuspend = $false
        Show-DevKitGuiSearchPage -Keyword $query
    } elseif ($script:SearchActive) {
        $script:SearchActive = $false
        if ($script:PreSearchRender) {
            & $script:PreSearchRender
            $script:PreSearchRender = $null
        }
        # Restore the nav highlight for the page we just went back to.
        if ($script:PreSearchNav) {
            $script:NavSuspend = $true
            $script:PreSearchNav.IsChecked = $true
            $script:NavSuspend = $false
            $script:PreSearchNav = $null
        }
    }
})

$ui.SearchBox.Add_TextChanged({
    if ($script:SuppressSearch) { return }
    $query = $ui.SearchBox.Text.Trim()
    $ui.SearchWatermark.Visibility = if ($query.Length -eq 0) { 'Visible' } else { 'Collapsed' }
    $script:SearchDebounceTimer.Stop()
    $script:SearchDebounceTimer.Start()
})

$ui.SearchBox.Add_KeyDown({
    param($s, $e)
    if ($e.Key -eq 'Escape') {
        $ui.SearchBox.Text = ''
        $e.Handled = $true
    }
})

$window.Add_PreviewKeyDown({
    param($s, $e)
    if ($e.Key -eq 'F' -and ([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control)) {
        $ui.SearchBox.Focus() | Out-Null
        $e.Handled = $true
    }
})

# ==================== WINDOW CHROME ====================

function Set-DevKitGuiMaximized([bool]$Maximized) {
    if ($Maximized) {
        $window.WindowState = 'Maximized'
    } else {
        $window.WindowState = 'Normal'
    }
}

$ui.TitleBar.Add_MouseLeftButtonDown({
    param($s, $e)
    if ($e.ClickCount -eq 2) {
        Set-DevKitGuiMaximized ($window.WindowState -ne 'Maximized')
    } else {
        try { $window.DragMove() } catch { }
    }
})

# Edge resize: with WindowStyle=None there are no OS resize handles, so the
# transparent thumbs in the XAML start a resize by posting WM_NCLBUTTONDOWN
# (0xA1) with the edge's HT* code (HTLEFT=10 .. HTBOTTOMRIGHT=17) as wParam.
# (DevKitGuiNative is compiled in the merged Add-Type near the top of the file.)
foreach ($edgeName in @('ResizeTop', 'ResizeBottom', 'ResizeLeft', 'ResizeRight',
                       'ResizeTopLeft', 'ResizeTopRight', 'ResizeBottomLeft', 'ResizeBottomRight')) {
    $edge = $window.FindName($edgeName)
    if ($null -eq $edge) { continue }
    $edge.Add_MouseLeftButtonDown({
        param($s, $e)
        $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $window).Handle
        if ($hwnd -ne [IntPtr]::Zero) {
            [DevKitGuiNative]::SendMessage($hwnd, 0xA1, [IntPtr]::new([int]$s.Tag), [IntPtr]::Zero) | Out-Null
        }
        $e.Handled = $true
    })
}

$ui.BtnMinimize.Add_Click({ $window.WindowState = 'Minimized' })
$ui.BtnMaximize.Add_Click({ Set-DevKitGuiMaximized ($window.WindowState -ne 'Maximized') })
$ui.BtnClose.Add_Click({ $window.Close() })

# The companion widget runs detached, so it keeps living in the system tray
# after this window closes.
function Start-DevKitCompanionWidget {
    param([Windows.Controls.Button]$SourceButton)
    $widgetPath = Join-Path $GuiDir 'DevKit-Widget.ps1'
    $shellExe = "$($script:TerminalProbe.Shell).exe"
    try {
        Start-Process $shellExe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File `"$widgetPath`"" -WorkingDirectory $ScriptDir
        $ui.StatusTerminalText.Text = 'Companion widget launched - it lives in the system tray.'
        Register-DevKitGuiLaunchFeedback -Button $SourceButton
    } catch {
        Show-DevKitGuiMessage -Title 'Cannot launch widget' -Message "Failed to start the companion widget: $_" -IsError
    }
}
$ui.BtnWidget.Add_Click({ Start-DevKitCompanionWidget })

$window.Add_StateChanged({
    if ($window.WindowState -eq 'Maximized') {
        # Keep the custom-chrome window off the taskbar area when maximized.
        $wa = [Windows.SystemParameters]::WorkArea
        $window.MaxWidth = $wa.Width
        $window.MaxHeight = $wa.Height
        $ui.RootBorder.Margin = [Windows.Thickness]::new(0)
        $ui.RootBorder.CornerRadius = [Windows.CornerRadius]::new(0)
        $ui.RootBorder.Effect = $null
        $ui.BtnMaximize.Content = [char]0xE923   # restore glyph
        $ui.BtnMaximize.ToolTip = 'Restore down'
    } else {
        $window.MaxWidth = [double]::PositiveInfinity
        $window.MaxHeight = [double]::PositiveInfinity
        $ui.RootBorder.Margin = [Windows.Thickness]::new(12)
        $ui.RootBorder.CornerRadius = [Windows.CornerRadius]::new(10)
        # Effect was nulled locally while maximized; clear the local value so
        # the style's drop shadow comes back (re-assigning .Style would not).
        $ui.RootBorder.ClearValue([Windows.Controls.Border]::EffectProperty)
        $ui.BtnMaximize.Content = [char]0xE922   # maximize glyph
        $ui.BtnMaximize.ToolTip = 'Maximize'
    }
})

# ==================== START ====================

Update-DevKitGuiStatus

# Land on the Getting Started page (not the first tool category) with the
# nav in sync. The Application itself was created before the XAML load above
# (app-wide theme resources); ShowDialog runs the message loop.
$script:NavSuspend = $false
$aboutNav.IsChecked = $true

$window.ShowDialog() | Out-Null
