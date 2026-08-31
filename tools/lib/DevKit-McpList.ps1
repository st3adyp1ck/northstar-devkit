#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Northstar DevKit - MCP Server List Diffing
.DESCRIPTION
    Shared helper for computing which of Claude Code's configured MCP
    servers are user/global scope versus project/local scope. 'claude mcp
    list' has no scope flag of its own, so this runs it twice - once from a
    neutral directory that is very unlikely to itself be a Claude Code
    project (a user/global-scope-only view), and once from a target project
    directory (the merged, effective view) - and diffs the two plain-text
    outputs by server name. This is a pure wrapper around the documented
    'claude mcp list' command: it never parses Claude Code's internal JSON
    config files directly, matching this module's existing philosophy (see
    AGENTS.md's "Agents & MCP" section).

    Used by both Get-McpServers.ps1 (report) and Scan-McpServers.ps1
    (report + catalog cross-reference), so there is exactly one
    implementation of this neutral-vs-project diff logic.

    This file is dot-sourced by scripts; it does not produce output when
    loaded.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
#>

# Prevent double-loading. Scope-aware on purpose: a $global: bool would
# incorrectly skip loading for a sibling script invoked via `&` in the same
# process (a distinct child scope that never inherits functions defined by
# another sibling's dot-source), leaving it with the flag set but none of
# the functions actually defined. Checking for the function itself detects
# "already loaded in a scope this one can see" instead.
if (Get-Command Invoke-DevKitMcpList -ErrorAction SilentlyContinue) { return }
$global:DevKitMcpListLoaded = $true

function Invoke-DevKitMcpList {
    <#
    .SYNOPSIS
        Runs 'claude mcp list' from a given directory and captures its
        output.
    .PARAMETER Path
        Directory to run the child process from. If omitted, runs from the
        current directory as-is.
    .PARAMETER TimeoutSeconds
        Deadline for the whole check. 'claude mcp list' health-checks by
        CONNECTING, which spawns every configured stdio MCP server as a
        real child process - so one wedged server used to wedge this call
        forever, holding the sidecar's mcp lane AND stranding the entire
        spawned fleet as orphans. On timeout the process TREE is killed
        (taskkill /T), so the fleet dies with the check.
    .OUTPUTS
        PSCustomObject: Success [bool], ExitCode [int or $null],
        ErrorMessage [string or $null], Output [string[]] (raw
        stdout+stderr lines, always an array, possibly empty).
    #>
    [CmdletBinding()]
    param(
        [string]$Path,
        # 25, NOT 60: mcp.report's scope diff runs this TWICE sequentially,
        # and the whole RPC has the host's 60s non-tool call budget - two
        # 60s deadlines would let a single wedged server blow the transport
        # timeout anyway. A healthy list is 5-20s; 25 leaves headroom for
        # both runs plus parsing inside one RPC.
        [int]$TimeoutSeconds = 25
    )

    if ($Path -and -not (Test-Path -LiteralPath $Path)) {
        return [PSCustomObject]@{
            Success      = $false
            ExitCode     = $null
            ErrorMessage = "Failed to enter directory '$Path': it does not exist."
            Output       = @()
        }
    }

    # NOT a bare Get-Command: npm installs of Claude Code ship claude.ps1 /
    # claude.cmd / an extension-less POSIX shim side by side, and Get-Command
    # happily returns the .ps1 or the shim - neither of which CreateProcess
    # can launch, so Start-Process below would fail with "not a valid Win32
    # application" on machines where the CLI itself works fine. The repo's
    # safe resolver (tools/lib/DevKit-Common.ps1, loaded before this file by
    # DevKit.Core.psm1 and the tools' dot-source chain) exists for exactly
    # this hazard; fall back to its filter inline if it isn't in scope.
    $claudeCmd = $null
    if (Get-Command Get-DevKitWindowsExecutable -ErrorAction SilentlyContinue) {
        $claudeCmd = Get-DevKitWindowsExecutable -Name 'claude'
    } else {
        $claudeCmd = @(Get-Command claude -All -ErrorAction SilentlyContinue | Where-Object {
            $_.CommandType -eq 'Application' -and $_.Source -match '\.(exe|cmd|bat)$'
        })[0]
        if (-not $claudeCmd) { $claudeCmd = Get-Command claude -ErrorAction SilentlyContinue }
    }
    # Launch plan. A real Windows executable runs directly; a .ps1 shim runs
    # through the current PowerShell host with -File (which is how the old
    # bare `claude mcp list` dispatched it in-process, minus the timeout).
    # Anything else - a profile-defined function or alias - cannot be run in
    # a killable child at all, so say so instead of guessing.
    $launchFile = $null
    $launchArgs = $null
    if ($claudeCmd -and $claudeCmd.CommandType -eq 'Application') {
        $launchFile = $claudeCmd.Source
        $launchArgs = @('mcp', 'list')
    } elseif ($claudeCmd -and $claudeCmd.CommandType -eq 'ExternalScript') {
        $launchFile = (Get-Process -Id $PID).Path
        $launchArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $claudeCmd.Source, 'mcp', 'list')
    }
    if (-not $launchFile) {
        $why = if ($claudeCmd) { "'claude' resolves to a $($claudeCmd.CommandType), which cannot be run with a timeout" } else { "'claude' was not found on PATH" }
        return [PSCustomObject]@{
            Success      = $false
            ExitCode     = $null
            ErrorMessage = "Failed to run 'claude mcp list': $why."
            Output       = @()
        }
    }

    $listFailed = $false
    $listErrorMessage = $null
    $listExitCode = $null
    $outputLines = @()
    # An explicit child process (not bare invocation) so the check can be
    # given the deadline above - a bare `claude mcp list` offers no way to
    # stop it, let alone the servers it spawned.
    $stdoutFile = [System.IO.Path]::GetTempFileName()
    $stderrFile = [System.IO.Path]::GetTempFileName()
    try {
        $startParams = @{
            FilePath               = $launchFile
            ArgumentList           = $launchArgs
            NoNewWindow            = $true
            PassThru               = $true
            RedirectStandardOutput = $stdoutFile
            RedirectStandardError  = $stderrFile
        }
        if ($Path) { $startParams['WorkingDirectory'] = $Path }
        $proc = Start-Process @startParams
        if ($proc.WaitForExit($TimeoutSeconds * 1000)) {
            # A second, untimed wait lets .NET finish wiring ExitCode after
            # the timed wait has already returned true.
            $proc.WaitForExit()
            $listExitCode = $proc.ExitCode
        } else {
            [void](& taskkill /T /F /PID $proc.Id 2>&1)
            # taskkill returns after POSTING terminations; the fleet's
            # inherited redirect handles take a beat to actually close, and
            # deleting the temp files under a still-open handle silently
            # fails. A short settle keeps the cleanup honest.
            Start-Sleep -Milliseconds 400
            $listFailed = $true
            $listErrorMessage = "'claude mcp list' did not finish within ${TimeoutSeconds}s and was stopped, along with the MCP server processes it had spawned."
        }
        $outputLines = @(
            @(Get-Content -LiteralPath $stdoutFile -ErrorAction SilentlyContinue) +
            @(Get-Content -LiteralPath $stderrFile -ErrorAction SilentlyContinue)
        ) | ForEach-Object { [string]$_ }
        $outputLines = @($outputLines)
    } catch {
        $listFailed = $true
        $listErrorMessage = $_
    } finally {
        Remove-Item -LiteralPath $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
    }

    if ($listFailed) {
        return [PSCustomObject]@{
            Success      = $false
            ExitCode     = $null
            ErrorMessage = "Failed to run 'claude mcp list': $listErrorMessage"
            Output       = @()
        }
    }

    if ($null -ne $listExitCode -and $listExitCode -ne 0) {
        return [PSCustomObject]@{
            Success      = $false
            ExitCode     = $listExitCode
            ErrorMessage = "'claude mcp list' exited with code $listExitCode."
            Output       = $outputLines
        }
    }

    return [PSCustomObject]@{
        Success      = $true
        ExitCode     = $listExitCode
        ErrorMessage = $null
        Output       = $outputLines
    }
}

function ConvertTo-DevKitMcpEntryMap {
    <#
    .SYNOPSIS
        Parses 'claude mcp list' plain-text output lines into a map of
        server name -> full display line.
    .DESCRIPTION
        'claude mcp list' prints one line per configured server, starting
        with 'name: ...'. Status/header/blank lines don't match this shape
        and are ignored. Real-world server names can contain spaces and
        periods (e.g. connector-style names like 'claude.ai Notion'), so the
        name is everything on the line up to the first ': ' rather than a
        restricted character set. This parses the documented CLI's
        plain-text output, not Claude Code's internal JSON config.
    .PARAMETER Output
        Raw output lines, as returned by Invoke-DevKitMcpList's .Output.
    .OUTPUTS
        [System.Collections.Specialized.OrderedDictionary] server name ->
        full display line, insertion-ordered.
    #>
    [CmdletBinding()]
    param([string[]]$Output)

    $map = [ordered]@{}
    foreach ($line in $Output) {
        if ($line -match '^(?<name>\S[^:\r\n]*):\s+(?<rest>\S.*)$') {
            $map[$Matches.name.Trim()] = $line.Trim()
        }
    }
    return $map
}

function Get-DevKitMcpScopeDiff {
    <#
    .SYNOPSIS
        Computes the user/global vs project/local MCP server split for a
        target project directory.
    .DESCRIPTION
        Runs 'claude mcp list' from a neutral directory ($env:TEMP - very
        unlikely to itself be a Claude Code project) to get the
        user/global-scope-only view, and again from $ProjectPath to get the
        merged, effective view, then diffs the two by server name. Entries
        present in both listings are user/global scope; entries present
        only in the project-directory listing are project/local scope.
    .PARAMETER ProjectPath
        The project directory to compare against the neutral baseline.
    .OUTPUTS
        PSCustomObject:
          Success        [bool]
          ErrorMessage   [string or $null]
          NeutralResult  the Invoke-DevKitMcpList result for the neutral dir
          ProjectResult  the Invoke-DevKitMcpList result for $ProjectPath
                         ($null if the neutral-directory run itself failed)
          UserScope      ordered map name->line, present in both listings
          ProjectScope   ordered map name->line, present only in the
                         project-directory listing
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ProjectPath)

    $neutralResult = Invoke-DevKitMcpList -Path $env:TEMP
    if (-not $neutralResult.Success) {
        return [PSCustomObject]@{
            Success       = $false
            ErrorMessage  = "Neutral-directory listing failed: $($neutralResult.ErrorMessage)"
            NeutralResult = $neutralResult
            ProjectResult = $null
            UserScope     = [ordered]@{}
            ProjectScope  = [ordered]@{}
        }
    }

    $projectResult = Invoke-DevKitMcpList -Path $ProjectPath
    if (-not $projectResult.Success) {
        return [PSCustomObject]@{
            Success       = $false
            ErrorMessage  = "Project-directory listing failed: $($projectResult.ErrorMessage)"
            NeutralResult = $neutralResult
            ProjectResult = $projectResult
            UserScope     = [ordered]@{}
            ProjectScope  = [ordered]@{}
        }
    }

    $neutralMap = ConvertTo-DevKitMcpEntryMap -Output $neutralResult.Output
    $projectMap = ConvertTo-DevKitMcpEntryMap -Output $projectResult.Output

    $userScope = [ordered]@{}
    $projectScope = [ordered]@{}
    foreach ($name in $projectMap.Keys) {
        if ($neutralMap.Contains($name)) {
            $userScope[$name] = $projectMap[$name]
        } else {
            $projectScope[$name] = $projectMap[$name]
        }
    }

    return [PSCustomObject]@{
        Success       = $true
        ErrorMessage  = $null
        NeutralResult = $neutralResult
        ProjectResult = $projectResult
        UserScope     = $userScope
        ProjectScope  = $projectScope
    }
}
