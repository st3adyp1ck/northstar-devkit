#!/usr/bin/env pwsh
<#
.SYNOPSIS
    DevKit Admin Mode (enable/disable) - Northstar DevKit
.DESCRIPTION
    Makes DevKit launchable with full Administrator rights WITHOUT a UAC
    prompt every time, using Windows' own "scheduled task with highest
    privileges" mechanism - the same technique tools like MSI Afterburner
    use. One UAC consent, given when you run this, is the only prompt the
    setup ever needs; Windows offers no way around that one, by design.

    WHAT ENABLE DOES
      - Registers a scheduled task named 'NorthstarDevKit-Admin' that runs
        the DevKit app exe 'with highest privileges' - elevated, with no
        per-launch prompt.
      - Writes a tiny hidden launcher (DevKit-Admin.vbs) and a
        'DevKit (Admin)' shortcut on your Desktop and in Start Menu >
        Programs. Launching either starts DevKit elevated through the task -
        zero console flash, zero prompts.
      - If 'Start with Windows' is on, MOVES it from the registry Run key
        onto the task as a logon trigger (Windows silently refuses to
        auto-start elevated apps from the Run key), and records the move so
        -Off can put it back exactly.
      - Writes a state marker (%LOCALAPPDATA%\NorthstarDevKit\admin-mode.json)
        recording everything it changed; -Off reads it to reverse all of this.

    WHEN NOT ELEVATED, this script re-launches ITSELF elevated once (that is
    the one UAC prompt), waits for the elevated copy to finish, then reports
    what it did - so it behaves the same from a terminal, its .bat wrapper,
    the CLI, and the Control Center's headless Run dialog.

    THE TRADE-OFF, stated plainly: the task elevates whatever exe its
    registered path points at, with no prompt. The per-user install folder
    (%LOCALAPPDATA%\Programs\DevKit) is writable by anything running as you,
    so replacing DevKit.exe afterwards is a silent elevation path - keep
    Admin Mode only while it earns its keep, and -Off removes all of it.
    While elevated, EVERY DevKit surface runs as Administrator: all ~65
    tools, the Control Center, and the embedded terminal - a tool bug's
    blast radius is the whole machine.

    TO USE AFTER ENABLING: exit the running DevKit from its tray (right-click
    > Exit) FIRST - the app is single-instance, so launching 'DevKit (Admin)'
    while the old one lives just focuses the OLD non-elevated window - then
    start it from the 'DevKit (Admin)' shortcut. The widget's title bar shows
    an ADMIN badge when the app really is elevated.
.PARAMETER Off
    Disable: remove the task, the launcher, and the shortcuts, restore
    Start-with-Windows if Admin Mode moved it, and delete the state marker.
    Same one-time self-elevation flow when not already elevated.
.PARAMETER ExePath
    Explicit path to the DevKit app exe to elevate. Default resolution:
    the per-user install (%LOCALAPPDATA%\Programs\DevKit\DevKit.exe), then
    a repo release build (target\release\devkit-app.exe).
.PARAMETER DryRun
    Report exactly what WOULD be registered or removed, and change nothing.
.PARAMETER Force
    Skip the destructive-action confirmation. The Control Center passes this
    automatically once you confirm in its caution dialog.
.PARAMETER ElevatedChildResultPath
    INTERNAL - do not use. When present, this process IS the elevated child
    the non-elevated parent launched after collecting the one UAC consent:
    it performs the change and writes a JSON result to this path for the
    parent to read back (Start-Process -Verb RunAs cannot stream output).
.EXAMPLE
    .\Set-DevKitAdminMode.ps1 -DryRun
.EXAMPLE
    .\Set-DevKitAdminMode.ps1
.EXAMPLE
    .\Set-DevKitAdminMode.ps1 -Off
#>
[CmdletBinding()]
param(
    [switch]$Off,
    [switch]$DryRun,
    [string]$ExePath,
    [switch]$Force,
    [string]$ElevatedChildResultPath
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) {
    . $CommonModule
} else {
    Write-Host "ERROR: Required module not found: $CommonModule" -ForegroundColor Red
    exit 1
}

# ==================== STATIC SETS ====================

$script:DevKitAdminTaskName = 'NorthstarDevKit-Admin'
$script:DevKitAdminShortcutFileName = 'DevKit (Admin).lnk'
$script:DevKitAdminVbsFileName = 'DevKit-Admin.vbs'
$script:DevKitAdminMarkerFileName = 'admin-mode.json'

# ==================== PURE HELPERS (unit-tested) ====================

function Get-DevKitAppExeCandidates {
    <#
    .SYNOPSIS
        Candidate paths for the DevKit app exe, in preference order.
    .DESCRIPTION
        Pure string composition (testable): the per-user NSIS install first
        (productName 'DevKit' -> DevKit.exe), then a source checkout's
        release build (the Cargo bin is 'devkit-app'). Blank inputs are
        skipped so the result is only ever real candidate strings.
    .OUTPUTS
        [string[]] - always a real array, including at count 1.
    #>
    param(
        [AllowEmptyString()][string]$LocalAppData = $env:LOCALAPPDATA,
        [AllowEmptyString()][string]$RepoRoot = ''
    )

    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($LocalAppData)) {
        $candidates += (Join-Path (Join-Path $LocalAppData 'Programs\DevKit') 'DevKit.exe')
    }
    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) {
        $candidates += (Join-Path (Join-Path $RepoRoot 'target\release') 'devkit-app.exe')
    }
    return @($candidates)
}

function Resolve-DevKitAppExe {
    <#
    .SYNOPSIS
        The exe to elevate: an explicit -ExePath when given, else the first
        candidate that exists. Throws (listing what was checked) when none
        is found - registering an elevation task for a missing exe would be
        a silent broken promise.
    #>
    param(
        [AllowEmptyString()][string]$Explicit = '',
        [string[]]$Candidates = @()
    )
    if (-not [string]::IsNullOrWhiteSpace($Explicit)) {
        if (Test-Path -LiteralPath $Explicit) { return $Explicit }
        throw "The -ExePath given does not exist: $Explicit"
    }
    foreach ($candidate in @($Candidates)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    $checked = if (@($Candidates).Count -gt 0) { ($Candidates -join "`n    ") } else { '(none)' }
    throw "Could not find the DevKit app exe. Checked:`n    $checked`nPass -ExePath with the full path to DevKit.exe (or a dev build's devkit-app.exe)."
}

function Get-DevKitAdminLauncherVbs {
    <#
    .SYNOPSIS
        The one-line WSH shim that starts the scheduled task with no console
        window (wscript + run-minimized-hidden). Pure - the task name is
        embedded with VBScript's doubled-quote escaping.
    #>
    param([Parameter(Mandatory = $true)][string]$TaskName)
    $escaped = $TaskName -replace '"', '""'
    return 'CreateObject("Wscript.Shell").Run "schtasks /run /tn ""' + $escaped + '""", 0, False'
}

function Get-DevKitAdminShortcutPlan {
    <#
    .SYNOPSIS
        The shortcuts to create, as plain records (Path/Target/Arguments/
        IconLocation/Description). Pure. Blank folders are skipped, so a
        machine with a redirected Desktop or no Start Menu still gets the
        other one.
    .OUTPUTS
        PSCustomObject[] - always a real array.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$VbsPath,
        [Parameter(Mandatory = $true)][string]$IconExePath,
        [Parameter(Mandatory = $true)][string]$ShortcutFileName,
        [AllowEmptyString()][string]$DesktopDir = '',
        [AllowEmptyString()][string]$ProgramsDir = ''
    )
    $specs = @()
    foreach ($dir in @($DesktopDir, $ProgramsDir)) {
        if ([string]::IsNullOrWhiteSpace($dir)) { continue }
        $specs += [PSCustomObject]@{
            Path         = Join-Path $dir $ShortcutFileName
            Target       = 'wscript.exe'
            Arguments    = '"' + $VbsPath + '"'
            IconLocation = $IconExePath
            Description  = 'Launch Northstar DevKit with administrator privileges'
        }
    }
    return @($specs)
}

function Find-DevKitAutostartRunValue {
    <#
    .SYNOPSIS
        The name of the HKCU Run value whose target is the app exe, or
        $null. Pure over the injected hashtable so the matching rules
        (quoted or not, case-insensitive, trailing arguments tolerated)
        are unit-testable without touching the registry.
    #>
    param(
        [Parameter(Mandatory = $true)][hashtable]$RunValues,
        [Parameter(Mandatory = $true)][string]$ExePath
    )
    $needle = $ExePath.Trim().Trim('"').ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($needle)) { return $null }
    foreach ($name in $RunValues.Keys) {
        $data = ([string]$RunValues[$name]).Trim().Trim('"').ToLowerInvariant()
        # The value may carry arguments after the exe path - containment of
        # the path itself is the match, not equality of the whole string.
        if ($data.Length -gt 0 -and $data.Contains($needle)) { return [string]$name }
    }
    return $null
}

function ConvertTo-DevKitAdminChildArgs {
    <#
    .SYNOPSIS
        The argument list for the elevated child copy of this script. Pure.
    .DESCRIPTION
        The child runs -Force: the parent already collected consent through
        Confirm-DevKitDestructiveAction AND the UAC prompt, and the child is
        non-interactive, so a third prompt could never be answered. Elements
        containing whitespace are double-quoted here because Start-Process
        -ArgumentList joins an array with spaces and does NOT quote for you -
        a spaced path would otherwise arrive as two arguments.
    .OUTPUTS
        [string[]] - always a real array.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string]$ResultPath,
        [switch]$Off,
        [AllowEmptyString()][string]$ExePath = ''
    )
    $childArgs = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath, '-ElevatedChildResultPath', $ResultPath, '-Force')
    if ($Off) { $childArgs += '-Off' }
    if (-not [string]::IsNullOrWhiteSpace($ExePath)) { $childArgs += @('-ExePath', $ExePath) }
    return @($childArgs | ForEach-Object { if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ } })
}

# ==================== STATE GATHERING + WORK ====================

function Read-DevKitAdminModeMarker {
    <# The state marker written by enable, or $null when absent/unreadable. #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$MarkerPath)
    if ([string]::IsNullOrWhiteSpace($MarkerPath)) { return $null }
    if (-not (Test-Path -LiteralPath $MarkerPath)) { return $null }
    try { return (Get-Content -LiteralPath $MarkerPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
}

function Write-DevKitAdminModeMarker {
    <# Writes the state marker, creating the app-data folder if needed. #>
    param(
        [Parameter(Mandatory = $true)][string]$MarkerPath,
        [Parameter(Mandatory = $true)]$Data
    )
    $dir = Split-Path -Parent $MarkerPath
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    ($Data | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $MarkerPath -Encoding UTF8
}

function Get-DevKitAdminModeContext {
    <#
    .SYNOPSIS
        One snapshot of everything the plan print, the confirm dialog, and
        the work functions need: resolved paths, current task/autostart
        state, and the marker. Read-only - gathering never changes anything.
    #>
    param(
        [switch]$Off,
        [AllowEmptyString()][string]$ExplicitExePath = ''
    )
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $appDataDir = Join-Path $env:LOCALAPPDATA 'NorthstarDevKit'
    $desktopDir = [Environment]::GetFolderPath('Desktop')
    $programsDir = [Environment]::GetFolderPath('Programs')

    $ctx = [ordered]@{
        TaskName            = $script:DevKitAdminTaskName
        AppDataDir          = $appDataDir
        VbsPath             = Join-Path $appDataDir $script:DevKitAdminVbsFileName
        MarkerPath          = Join-Path $appDataDir $script:DevKitAdminMarkerFileName
        ShortcutSpecs       = @()
        ShortcutPaths       = @()
        Exe                 = $null
        ExeResolveError     = $null
        TaskExists          = $false
        TaskHasLogonTrigger = $false
        AutostartRunName    = $null
        AutostartRunData    = $null
        Marker              = $null
        VbsExists           = $false
    }

    # Exe resolution is enable-only: disable works from the marker and never
    # needs the exe (the task it removes knows its own action).
    if (-not $Off) {
        try {
            $ctx.Exe = Resolve-DevKitAppExe -Explicit $ExplicitExePath -Candidates (Get-DevKitAppExeCandidates -RepoRoot $repoRoot)
            $ctx.ShortcutSpecs = @(Get-DevKitAdminShortcutPlan -VbsPath $ctx.VbsPath -IconExePath $ctx.Exe `
                -ShortcutFileName $script:DevKitAdminShortcutFileName -DesktopDir $desktopDir -ProgramsDir $programsDir)
            $ctx.ShortcutPaths = @($ctx.ShortcutSpecs | ForEach-Object { $_.Path })
        } catch {
            $ctx.ExeResolveError = $_.Exception.Message
        }
    }

    try {
        $task = Get-ScheduledTask -TaskName $ctx.TaskName -ErrorAction Stop
        $ctx.TaskExists = $true
        $ctx.TaskHasLogonTrigger = [bool](@($task.Triggers) | Where-Object { $_.CimClass.CimClassName -match 'Logon' })
    } catch { }

    $ctx.VbsExists = Test-Path -LiteralPath $ctx.VbsPath
    $ctx.Marker = Read-DevKitAdminModeMarker -MarkerPath $ctx.MarkerPath

    # Autostart detection (enable only): find the Run value pointing at the
    # exe. Read name AND data now so enable can record the exact pair for
    # -Off to restore.
    if (-not $Off -and $ctx.Exe) {
        try {
            $runKey = Get-Item -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -ErrorAction Stop
            $values = @{}
            foreach ($name in @($runKey.GetValueNames())) { $values[$name] = [string]$runKey.GetValue($name) }
            $ctx.AutostartRunName = Find-DevKitAutostartRunValue -RunValues $values -ExePath $ctx.Exe
            if ($ctx.AutostartRunName) { $ctx.AutostartRunData = $values[$ctx.AutostartRunName] }
        } catch { }
    }
    return [PSCustomObject]$ctx
}

function Register-DevKitAdminMode {
    <#
    .SYNOPSIS
        The enable half of the mutation. Runs only elevated (either the
        script was started that way, or inside the -Verb RunAs child).
        Returns report lines; throws on failure.
    #>
    param([Parameter(Mandatory = $true)]$Context)
    $lines = @()

    $vbsDir = Split-Path -Parent $Context.VbsPath
    if (-not (Test-Path -LiteralPath $vbsDir)) { [void](New-Item -ItemType Directory -Path $vbsDir -Force) }
    (Get-DevKitAdminLauncherVbs -TaskName $Context.TaskName) | Set-Content -LiteralPath $Context.VbsPath -Encoding ASCII
    $lines += "Wrote hidden launcher $($Context.VbsPath)"

    $shell = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        foreach ($spec in @($Context.ShortcutSpecs)) {
            $shortcut = $shell.CreateShortcut($spec.Path)
            $shortcut.TargetPath = $spec.Target
            $shortcut.Arguments = $spec.Arguments
            $shortcut.IconLocation = $spec.IconLocation
            $shortcut.Description = $spec.Description
            $shortcut.Save()
            $lines += "Wrote shortcut $($spec.Path)"
        }
    } finally {
        if ($shell) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
    }

    if ($Context.AutostartRunName) {
        $runKeyPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
        Remove-ItemProperty -Path $runKeyPath -Name $Context.AutostartRunName -ErrorAction Stop
        $lines += "Removed Run key value '$($Context.AutostartRunName)' - Windows will not auto-start an elevated app from the Run key, so Start-with-Windows moves onto the task"
    }

    $userName = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $action = New-ScheduledTaskAction -Execute $Context.Exe
    $principal = New-ScheduledTaskPrincipal -UserId $userName -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
    $registerParams = @{
        TaskName    = $Context.TaskName
        Action      = $action
        Principal   = $principal
        Settings    = $settings
        Description = 'Launches Northstar DevKit with administrator privileges. Created by Set-DevKitAdminMode.ps1; remove it with Set-DevKitAdminMode.ps1 -Off.'
        Force       = $true
    }
    if ($Context.AutostartRunName) {
        $registerParams['Trigger'] = New-ScheduledTaskTrigger -AtLogOn -User $userName
    }
    [void](Register-ScheduledTask @registerParams)
    $lines += "Registered task '$($Context.TaskName)' -> $($Context.Exe) (highest privileges, no per-launch prompt)$(if ($Context.AutostartRunName) { ', with a logon trigger for Start-with-Windows' })"

    Write-DevKitAdminModeMarker -MarkerPath $Context.MarkerPath -Data ([ordered]@{
        exePath        = $Context.Exe
        taskName       = $Context.TaskName
        vbsPath        = $Context.VbsPath
        shortcutPaths  = @($Context.ShortcutPaths)
        autostartMoved = [bool]$Context.AutostartRunName
        runValueName   = $Context.AutostartRunName
        runValueData   = $Context.AutostartRunData
    })
    $lines += "Wrote state marker $($Context.MarkerPath) (what '-Off' reads to undo all of this)"
    return , $lines
}

function Unregister-DevKitAdminMode {
    <#
    .SYNOPSIS
        The disable half of the mutation. Removes the task, the launcher,
        and the shortcuts; restores Start-with-Windows when the marker says
        Admin Mode moved it. Returns report lines; throws on failure.
    #>
    param([Parameter(Mandatory = $true)]$Context)
    $lines = @()

    if ($Context.TaskExists) {
        Unregister-ScheduledTask -TaskName $Context.TaskName -Confirm:$false -ErrorAction Stop
        $lines += "Removed scheduled task '$($Context.TaskName)'"
    } else {
        $lines += "Scheduled task '$($Context.TaskName)' was not registered"
    }

    $targets = @()
    if ($Context.Marker) {
        if ($Context.Marker.vbsPath) { $targets += [string]$Context.Marker.vbsPath }
        foreach ($p in @($Context.Marker.shortcutPaths)) { if ($p) { $targets += [string]$p } }
    }
    # Fallbacks cover a missing or stale marker (or a hand-deleted app-data
    # folder): the planned locations are deterministic, so try them too.
    $targets += $Context.VbsPath
    $targets += $Context.ShortcutPaths
    foreach ($p in @($targets | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $p) {
            Remove-Item -LiteralPath $p -Force -ErrorAction Stop
            $lines += "Deleted $p"
        }
    }

    if ($Context.Marker -and $Context.Marker.autostartMoved -and $Context.Marker.runValueName) {
        Set-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' `
            -Name ([string]$Context.Marker.runValueName) -Value ([string]$Context.Marker.runValueData) -ErrorAction Stop
        $lines += "Restored Start-with-Windows to the Run key ('$($Context.Marker.runValueName)')"
    }

    if (Test-Path -LiteralPath $Context.MarkerPath) {
        Remove-Item -LiteralPath $Context.MarkerPath -Force -ErrorAction Stop
        $lines += "Deleted state marker $($Context.MarkerPath)"
    }
    return , $lines
}

function Invoke-DevKitAdminModeChange {
    <# Gathers a fresh context and applies the requested change. Both the
       already-elevated main flow and the elevated child call this one. #>
    param(
        [switch]$Off,
        [AllowEmptyString()][string]$ExplicitExePath = ''
    )
    $ctx = Get-DevKitAdminModeContext -Off:$Off -ExplicitExePath $ExplicitExePath
    if ($Off) { return @(Unregister-DevKitAdminMode -Context $ctx) }
    if ($ctx.ExeResolveError) { throw $ctx.ExeResolveError }
    return @(Register-DevKitAdminMode -Context $ctx)
}

# Dot-sourcing this file (tests/Unit/AdminMode.Tests.ps1 does exactly that,
# to unit test the pure helpers above) must never register a task, delete a
# file, or prompt. Everything below this line is the real run.
if ($MyInvocation.InvocationName -eq '.') {
    return
}

# ==================== RUN ====================

# --- Elevated-child branch: we are the -Verb RunAs copy. Do the work and
# report ONLY via the result file (ShellExecute gives the parent no output
# stream); never print, never prompt.
if (-not [string]::IsNullOrWhiteSpace($ElevatedChildResultPath)) {
    $childResult = [ordered]@{ ok = $false; lines = @(); error = '' }
    try {
        $childResult.lines = @(Invoke-DevKitAdminModeChange -Off:$Off -ExplicitExePath $ExePath)
        $childResult.ok = $true
    } catch {
        $childResult.error = $_.Exception.Message
    }
    try { ($childResult | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $ElevatedChildResultPath -Encoding UTF8 } catch { }
    exit ($(if ($childResult.ok) { 0 } else { 1 }))
}

Write-DevKitHeader ("DevKit Admin Mode" + $(if ($Off) { ' - Disable' } else { '' }))

$ctx = Get-DevKitAdminModeContext -Off:$Off -ExplicitExePath $ExePath
if (-not $Off -and $ctx.ExeResolveError) {
    Write-DevKitError $ctx.ExeResolveError
    exit 1
}

# Nothing-to-do short-circuit for disable: no task, no launcher, no marker,
# and none of the shortcut files present means there is nothing to reverse.
$existingShortcuts = @($ctx.ShortcutPaths | Where-Object { Test-Path -LiteralPath $_ })
if ($Off -and -not $ctx.TaskExists -and -not $ctx.VbsExists -and -not $ctx.Marker -and $existingShortcuts.Count -eq 0) {
    Write-DevKitInfo "Admin Mode is not enabled - nothing to do."
    exit 0
}

Write-Host "  Plan:" -ForegroundColor Magenta
if ($Off) {
    if ($ctx.TaskExists) {
        Write-Host "    [x] Remove scheduled task '$($ctx.TaskName)'$(if ($ctx.TaskHasLogonTrigger) { ' (it carries the Start-with-Windows logon trigger)' })" -ForegroundColor Gray
    } else {
        Write-Host "    [ ] Scheduled task '$($ctx.TaskName)' is not registered" -ForegroundColor DarkGray
    }
    Write-Host "    [x] Delete the hidden launcher and the 'DevKit (Admin)' shortcuts" -ForegroundColor Gray
    if ($ctx.Marker -and $ctx.Marker.autostartMoved -and $ctx.Marker.runValueName) {
        Write-Host "    [x] Restore Start-with-Windows to the Run key ('$($ctx.Marker.runValueName)')" -ForegroundColor Gray
    }
    Write-Host "    [x] Delete the state marker $($ctx.MarkerPath)" -ForegroundColor Gray
} else {
    Write-Host "    [x] Register scheduled task '$($ctx.TaskName)' to run this exe with highest privileges (no per-launch UAC):" -ForegroundColor Gray
    Write-Host "        $($ctx.Exe)$(if ($ctx.TaskExists) { '  - already registered; will be updated in place' })" -ForegroundColor Gray
    Write-Host "    [x] Write hidden launcher $($ctx.VbsPath)" -ForegroundColor Gray
    foreach ($p in @($ctx.ShortcutPaths)) { Write-Host "    [x] Write shortcut $p" -ForegroundColor Gray }
    if ($ctx.AutostartRunName) {
        Write-Host "    [x] Move Start-with-Windows from Run key value '$($ctx.AutostartRunName)' onto the task as a logon trigger" -ForegroundColor Gray
    } else {
        Write-Host "    [ ] Start-with-Windows is not currently enabled - nothing to move" -ForegroundColor DarkGray
    }
    Write-Host "    [x] Write state marker $($ctx.MarkerPath) (what '-Off' reads to undo all of this)" -ForegroundColor Gray
}
Write-Host ""

if ($DryRun) {
    Write-DevKitInfo "Dry run - nothing was registered, removed, or changed. Re-run without -DryRun to apply."
    exit 0
}

# Confirm BEFORE any UAC prompt: DevKit's own gate comes first, so a decline
# never costs the user a pointless elevation consent.
$affected = @($ctx.VbsPath) + @($ctx.ShortcutPaths) + @($ctx.MarkerPath)
if ($ctx.AutostartRunName) { $affected += "HKCU Run key value '$($ctx.AutostartRunName)' (Start-with-Windows)" }
$action = if ($Off) {
    'disable DevKit Admin Mode (remove the elevation task, launcher, and shortcuts)'
} else {
    'enable DevKit Admin Mode (register a persistent, prompt-free elevation path for the DevKit app)'
}
$proceed = Confirm-DevKitDestructiveAction -Action $action -AffectedPaths $affected -Force:$Force
if (-not $proceed) {
    Write-DevKitInfo "Cancelled - nothing was changed."
    exit 0
}

$isAdmin = Test-DevKitAdmin
if (-not $isAdmin) {
    Write-DevKitInfo "This needs Administrator rights once - Windows will ask now (UAC). Approve it and this step finishes on its own."
    $resultPath = Join-Path $env:TEMP ("devkit-adminmode-" + [guid]::NewGuid().ToString('N') + ".json")
    $childArgs = ConvertTo-DevKitAdminChildArgs -ScriptPath $PSCommandPath -ResultPath $resultPath -Off:$Off -ExePath $ctx.Exe
    $psExe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
    try {
        [void](Start-Process -FilePath $psExe -ArgumentList $childArgs -Verb RunAs -Wait -WindowStyle Hidden)
    } catch {
        Write-DevKitError "Elevation was declined or could not start - nothing was changed. ($($_.Exception.Message))"
        exit 1
    }

    $childResult = $null
    if (Test-Path -LiteralPath $resultPath) {
        try { $childResult = Get-Content -LiteralPath $resultPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { $childResult = $null }
        Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue
    }
    if ($null -eq $childResult) {
        Write-DevKitError "The elevated step did not report back - cannot confirm what happened. Check Task Scheduler for '$($ctx.TaskName)' before re-running."
        exit 1
    }
    foreach ($line in @($childResult.lines)) { Write-Host "    $line" -ForegroundColor Gray }
    if (-not $childResult.ok) {
        Write-DevKitError $childResult.error
        exit 1
    }
} else {
    Write-DevKitStep "Applying changes (already running elevated)"
    try {
        foreach ($line in @(Invoke-DevKitAdminModeChange -Off:$Off -ExplicitExePath $ExePath)) {
            Write-Host "    $line" -ForegroundColor Gray
        }
        Write-DevKitDone
    } catch {
        Write-DevKitError $_.Exception.Message
        exit 1
    }
}

Write-Host ""
if ($Off) {
    Write-Host "  Admin Mode is OFF." -ForegroundColor Green
    Write-DevKitInfo "The task, launcher, and shortcuts are gone. DevKit keeps working normally, just without elevation - re-enable any time by running this again without -Off."
} else {
    Write-Host "  Admin Mode is ON." -ForegroundColor Green
    $running = @(Get-Process -Name 'DevKit', 'devkit-app' -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        Write-Host "  WARNING: DevKit is running right now, non-elevated. Exit it from the tray (right-click > Exit) BEFORE using the new shortcut - DevKit is single-instance, so launching 'DevKit (Admin)' while it lives just focuses the old non-elevated window." -ForegroundColor Yellow
    }
    Write-DevKitInfo "Start DevKit from the 'DevKit (Admin)' shortcut on your Desktop or in Start Menu > Programs. The widget title bar shows an ADMIN badge when it really is elevated."
    Write-DevKitInfo "From then on every DevKit surface runs as Administrator - all tools and the embedded terminal. Undo all of this any time: Set-DevKitAdminMode.ps1 -Off"
}
Write-Host ""
exit 0
