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
        Directory to run from (Push-Location'd into first, then popped).
        If omitted, runs from the current directory as-is.
    .OUTPUTS
        PSCustomObject: Success [bool], ExitCode [int or $null],
        ErrorMessage [string or $null], Output [string[]] (raw
        stdout+stderr lines, always an array, possibly empty).
    #>
    [CmdletBinding()]
    param([string]$Path)

    $pushedLocation = $false
    if ($Path) {
        try {
            Push-Location -LiteralPath $Path
            $pushedLocation = $true
        } catch {
            return [PSCustomObject]@{
                Success      = $false
                ExitCode     = $null
                ErrorMessage = "Failed to enter directory '$Path': $_"
                Output       = @()
            }
        }
    }

    $listFailed = $false
    $listErrorMessage = $null
    $listExitCode = $null
    $rawOutput = $null
    try {
        $rawOutput = claude mcp list 2>&1
        $listExitCode = $LASTEXITCODE
    } catch {
        $listFailed = $true
        $listErrorMessage = $_
    } finally {
        if ($pushedLocation) { Pop-Location }
    }

    $outputLines = @($rawOutput | ForEach-Object { $_.ToString() })

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
