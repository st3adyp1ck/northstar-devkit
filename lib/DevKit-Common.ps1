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
    3.0.0
#>

# Prevent double-loading
if ($global:DevKitCommonLoaded) { return }
$global:DevKitCommonLoaded = $true

# ==================== SETTINGS ====================

function Get-DevKitSettingsFile {
    $dir = Join-Path $env:LOCALAPPDATA "NorthstarDevKit"
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
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
        foreach ($prop in $defaults.preferences.PSObject.Properties.Name) {
            if (-not $data.preferences.PSObject.Properties.Name.Contains($prop)) {
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
        $Settings | ConvertTo-Json -Depth 6 | Set-Content -Path $tempPath -Encoding UTF8
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

    if ($TypedPhrase) {
        $typed = Read-Host "  Type '$TypedPhrase' to confirm"
        return ($typed -ceq $TypedPhrase)
    }
    $answer = Read-Host "  Continue? (y/N)"
    return ($answer -eq 'y')
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
            if ($Spec.Min -and $val -lt [int64]$Spec.Min) { return $null }
            if ($Spec.Max -and $val -gt [int64]$Spec.Max) { return $null }
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

function Show-DevKitModuleMenu {
    param([Parameter(Mandatory = $true)]$Module)
    Show-Header $Module.Name
    foreach ($item in $Module.Items) {
        Write-Host "  [$($item.Key)] $($item.Label)"
    }
    Write-Host ""
    Write-Host "  [0] Back"
    Write-Host ""
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
        $choice = Read-Host "Select option"
        $trimmed = $choice.Trim()

        if ($trimmed -eq '0') { return }

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
        Checks lock files first (bun.lockb, pnpm-lock.yaml, yarn.lock,
        package-lock.json, in that priority order). If none are found, falls
        back to package.json's corepack "packageManager" field (e.g.
        "pnpm@8.15.0") so freshly-scaffolded projects that don't yet have a
        lock file are still detected correctly. Defaults to npm if nothing
        matches.
    .PARAMETER Path
        The project directory to inspect.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $resolved = Resolve-DevKitDirectory -Path $Path

    $managers = @(
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

    $connection = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1
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

# ==================== FOLDER / FILE BROWSER ====================

# One-time native interop for a real console-window owner (so a dialog
# z-orders correctly above the console instead of floating globally topmost).
# Guarded by -as [type] (Add-Type -TypeDefinition throws "type already
# exists" on a second compile in the same process) combined with the file's
# own $global:DevKitCommonLoaded guard above.
if (-not ('DevKit.NativeMethods' -as [type])) {
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
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return Join-Path $dir "projects.json"
}

function Save-DevKitProjectRegistry {
    param([Parameter(Mandatory = $true)]$Registry)

    $path = Get-DevKitProjectsFile
    $tempPath = "$path.tmp.$PID"
    try {
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

    if (-not (Test-Path $path)) { return $empty }

    try {
        $raw = Get-Content -Path $path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $empty }
        $data = $raw | ConvertFrom-Json -ErrorAction Stop
        # ConvertFrom-Json returns a bare PSCustomObject (not a 1-item array)
        # when "projects" has exactly one element - always wrap with @().
        $projects = @($data.projects)
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
}

function Rename-DevKitLinkedProject {
    param([Parameter(Mandatory = $true)][string]$Id, [Parameter(Mandatory = $true)][string]$NewName)
    $registry = Get-DevKitProjectRegistry
    foreach ($p in $registry.projects) { if ($p.id -eq $Id) { $p.name = $NewName } }
    Save-DevKitProjectRegistry -Registry $registry
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
            Write-Host "  Linked Projects (most recently used first):" -ForegroundColor Magenta
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
