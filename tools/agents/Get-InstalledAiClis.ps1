#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Get Installed AI CLIs - Northstar DevKit
.DESCRIPTION
    Detects which AI coding-agent CLIs are installed on this machine
    (Claude Code, GitHub Copilot CLI via the gh extension, Codex, Gemini,
    Cursor, Aider, Supabase CLI, Vercel CLI, Railway CLI, Kimi Code CLI, and
    Augment Code CLI) and reports each one's version. Read-only - makes no
    changes to the system.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.EXAMPLE
    .\Get-InstalledAiClis.ps1
#>
[CmdletBinding()]
param(
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

Write-DevKitHeader "Installed AI CLIs"

function Test-AiCliVersion {
    <#
    .SYNOPSIS
        Best-effort version probe for an AI CLI.
    .DESCRIPTION
        Runs "<path> <VersionArg>" and only reports Responding=$true when
        BOTH the process exits cleanly (0 or $null - some hosts never set
        $LASTEXITCODE for a process that never really started) AND the
        first line of output actually contains something that looks like a
        version number. A clean exit code alone isn't proof the flag was
        even understood - some tools print usage/help and still exit 0.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$CommandPath,
        [string]$VersionArg = '--version'
    )

    $result = [PSCustomObject]@{
        Responding = $false
        Version    = $null
    }

    try {
        $output = & $CommandPath $VersionArg 2>&1
        $exitCode = $LASTEXITCODE
    } catch {
        return $result
    }

    if ($null -ne $exitCode -and $exitCode -ne 0) { return $result }

    $firstLine = [string](@($output) | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($firstLine)) { return $result }

    if ($firstLine -match '(\d+\.\d+(\.\d+)?(-[A-Za-z0-9.]+)?)') {
        $result.Version = $matches[1]
        $result.Responding = $true
    }

    return $result
}

# Each entry's Note (if set) is always printed as an extra indented line once
# the tool is found - used for a channel/update caveat worth surfacing even
# when the tool itself is working fine (e.g. Supabase's npm caveat).
# NotInstalledMessage (if set) replaces the generic "not installed" line with
# tool-specific context for why it isn't found (e.g. Augment's WSL-only
# support on Windows), per the same idea Kill-Port-style tools use elsewhere
# in this repo for "don't just say no, say why".
$tools = @(
    @{ Label = 'claude (Claude Code)'; Command = 'claude'; Fallback = $null; VersionArg = '--version' },
    @{ Label = 'gh (GitHub CLI)'; Command = 'gh'; Fallback = $null; VersionArg = '--version' },
    @{ Label = 'codex'; Command = 'codex'; Fallback = $null; VersionArg = '--version' },
    @{ Label = 'gemini'; Command = 'gemini'; Fallback = $null; VersionArg = '--version' },
    # cursor-agent has shipped under two different binary names across
    # releases - fall back to "cursor" before reporting it as not installed.
    @{ Label = 'cursor-agent'; Command = 'cursor-agent'; Fallback = 'cursor'; VersionArg = '--version' },
    @{ Label = 'aider'; Command = 'aider'; Fallback = $null; VersionArg = '--version' },
    @{
        Label      = 'supabase (Supabase CLI)'
        Command    = 'supabase'
        Fallback   = $null
        VersionArg = '--version'
        Note       = "update channel: Scoop, not npm -- 'npm install -g supabase' is unsupported upstream (supabase/cli #4496); see supabase.com/docs"
    },
    @{ Label = 'vercel (Vercel CLI)'; Command = 'vercel'; Fallback = $null; VersionArg = '--version' },
    @{ Label = 'railway (Railway CLI)'; Command = 'railway'; Fallback = $null; VersionArg = '--version' },
    @{
        Label      = 'kimi (Kimi Code CLI)'
        Command    = 'kimi'
        Fallback   = $null
        VersionArg = '--version'
        Note       = "two unrelated CLIs share the 'kimi' command name (Moonshot AI's npm-based Kimi Code CLI and an older Python-based kimi-cli) -- DevKit can't reliably tell which one this is, so Update AI CLIs treats it as manual-update-only"
    },
    @{
        Label               = 'auggie (Augment Code CLI)'
        Command             = 'auggie'
        Fallback            = $null
        VersionArg          = '--version'
        NotInstalledMessage = "not found on native Windows PATH -- Augment Code CLI officially supports Windows only via WSL, see docs.augmentcode.com"
    }
)

foreach ($tool in $tools) {
    $cmd = Get-DevKitWindowsExecutable -Name $tool.Command
    if (-not $cmd -and $tool.Fallback) {
        $cmd = Get-DevKitWindowsExecutable -Name $tool.Fallback
    }

    if (-not $cmd) {
        $presentButUnsafe = (Get-Command $tool.Command -ErrorAction SilentlyContinue) -or
            ($tool.Fallback -and (Get-Command $tool.Fallback -ErrorAction SilentlyContinue))
        if ($presentButUnsafe) {
            Write-Host "  $($tool.Label): found, but not a directly runnable Windows executable (version check skipped)" -ForegroundColor Yellow
        } elseif ($tool.NotInstalledMessage) {
            Write-Host "  $($tool.Label): $($tool.NotInstalledMessage)" -ForegroundColor Gray
        } else {
            Write-Host "  $($tool.Label): not installed" -ForegroundColor Gray
        }
        if ($tool.Note) {
            Write-Host "    $($tool.Note)" -ForegroundColor Gray
        }
        continue
    }

    $cmdPath = $cmd.Source
    $probe = Test-AiCliVersion -CommandPath $cmdPath -VersionArg $tool.VersionArg

    if ($probe.Responding) {
        Write-Host "  $($tool.Label): " -NoNewline
        Write-Host $probe.Version -ForegroundColor Green
    } else {
        Write-Host "  $($tool.Label): " -NoNewline
        Write-Host "found but not responding" -ForegroundColor Yellow
    }

    if ($tool.Note) {
        Write-Host "    $($tool.Note)" -ForegroundColor Gray
    }

    if ($tool.Command -eq 'gh') {
        try {
            $extensions = @(& $cmdPath extension list 2>&1)
            $ghExit = $LASTEXITCODE
            if ($ghExit -eq 0 -and ($extensions | Select-String -Pattern 'copilot' -Quiet)) {
                Write-Host "    gh extension 'copilot': installed" -ForegroundColor Green
            } else {
                Write-Host "    gh extension 'copilot': not installed" -ForegroundColor Gray
            }
        } catch {
            Write-Host "    gh extension 'copilot': could not check ($_)" -ForegroundColor Gray
        }
    }
}

exit 0
