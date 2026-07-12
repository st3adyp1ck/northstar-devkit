#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Update AI CLIs - Northstar DevKit
.DESCRIPTION
    Updates AI coding-agent CLIs that are installed AND known to be
    distributed through an automatable channel. Each of the 11 tracked
    tools carries its own "channel" (npm / npm+builtin / scoop / manual) so
    this script never assumes every tool is a plain npm package - it
    branches per channel instead:

      npm          - "npm view PACKAGE version" to compare, then
                     "npm install -g PACKAGE@latest" to update (output
                     captured and wrapped in Invoke-DevKitWithSpinner from
                     lib/DevKit-UI.ps1).
      npm+builtin  - same comparison line as npm, but the update prefers
                     running the tool's own upgrade subcommand (e.g.
                     "vercel upgrade") when the command exists, falling
                     back to the npm install above only if that fails.
      scoop        - compares against the latest GitHub release tag; the
                     update runs "scoop update NAME" only when Scoop is on
                     PATH and the tool appears to have been installed
                     through it, otherwise this reports "update manually"
                     with an install hint instead of guessing.
      manual       - reported only, never touched (a Go binary, pip/pipx
                     package, or shell installer with no safe update path
                     this script can drive).

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Only
    Restrict to these tool name(s) (matches each tool's Command), e.g.
    -Only claude,gemini.
.PARAMETER DryRun
    Show current/latest versions and what would update. No changes made.
.PARAMETER Force
    Skip the confirmation prompt before updating.
.EXAMPLE
    .\Update-AiClis.ps1
    .\Update-AiClis.ps1 -DryRun
    .\Update-AiClis.ps1 -Only claude -Force
#>
[CmdletBinding()]
param(
    [string[]]$Only,
    [switch]$DryRun,
    [switch]$Force
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

# Per-tool descriptor. Channel drives which comparison/update logic below
# applies; Package/GithubRepo/BuiltinUpgradeArgs/ScoopName are only ever
# populated for the channel(s) that actually use them. Caveat is a standing
# note printed whenever the tool is found (e.g. Supabase's npm caveat);
# NotFoundCaveat replaces the generic "not installed" line with tool-specific
# context (e.g. Augment Code CLI's Windows/WSL caveat).
$tools = @(
    [PSCustomObject]@{
        Name = 'claude'; Command = 'claude'; Channel = 'npm'
        Package = '@anthropic-ai/claude-code'; GithubRepo = $null
        BuiltinUpgradeArgs = $null; ScoopName = $null
        Caveat = $null; NotFoundCaveat = $null
    },
    [PSCustomObject]@{
        Name = 'gh'; Command = 'gh'; Channel = 'manual'
        Package = $null; GithubRepo = $null
        BuiltinUpgradeArgs = $null; ScoopName = $null
        Caveat = $null; NotFoundCaveat = $null
    },
    [PSCustomObject]@{
        Name = 'codex'; Command = 'codex'; Channel = 'npm'
        Package = '@openai/codex'; GithubRepo = $null
        BuiltinUpgradeArgs = $null; ScoopName = $null
        Caveat = $null; NotFoundCaveat = $null
    },
    [PSCustomObject]@{
        Name = 'gemini'; Command = 'gemini'; Channel = 'npm'
        Package = '@google/gemini-cli'; GithubRepo = $null
        BuiltinUpgradeArgs = $null; ScoopName = $null
        Caveat = $null; NotFoundCaveat = $null
    },
    [PSCustomObject]@{
        Name = 'cursor-agent'; Command = 'cursor-agent'; Channel = 'manual'
        Package = $null; GithubRepo = $null
        BuiltinUpgradeArgs = $null; ScoopName = $null
        Caveat = $null; NotFoundCaveat = $null
    },
    [PSCustomObject]@{
        Name = 'aider'; Command = 'aider'; Channel = 'manual'
        Package = $null; GithubRepo = $null
        BuiltinUpgradeArgs = $null; ScoopName = $null
        Caveat = $null; NotFoundCaveat = $null
    },
    [PSCustomObject]@{
        Name = 'supabase'; Command = 'supabase'; Channel = 'scoop'
        Package = $null; GithubRepo = 'supabase/cli'
        BuiltinUpgradeArgs = $null; ScoopName = 'supabase'
        Caveat = "'npm install -g supabase' is unsupported upstream (supabase/cli #4496) - install/update via Scoop: scoop bucket add supabase https://github.com/supabase/scoop-bucket.git ; scoop install supabase -- see supabase.com/docs"
        NotFoundCaveat = $null
    },
    [PSCustomObject]@{
        Name = 'vercel'; Command = 'vercel'; Channel = 'npm+builtin'
        Package = 'vercel'; GithubRepo = $null
        BuiltinUpgradeArgs = @('upgrade'); ScoopName = $null
        Caveat = $null; NotFoundCaveat = $null
    },
    [PSCustomObject]@{
        Name = 'railway'; Command = 'railway'; Channel = 'npm+builtin'
        Package = '@railway/cli'; GithubRepo = 'railwayapp/cli'
        BuiltinUpgradeArgs = @('upgrade'); ScoopName = $null
        Caveat = $null; NotFoundCaveat = $null
    },
    [PSCustomObject]@{
        # Deliberately 'manual', not 'npm+builtin': two unrelated CLIs share
        # the 'kimi' command name (Moonshot AI's npm-based Kimi Code CLI,
        # @moonshot-ai/kimi-code, and an older Python-based kimi-cli
        # distributed via pip/pipx/uv). There is no reliable way from here
        # to tell which one is actually installed, and guessing wrong would
        # mean "npm install -g @moonshot-ai/kimi-code@latest" silently
        # installing an unrelated package over/alongside a real tool the
        # user already has. Report-only until there's a safe way to
        # distinguish them.
        Name = 'kimi'; Command = 'kimi'; Channel = 'manual'
        Package = $null; GithubRepo = $null
        BuiltinUpgradeArgs = $null; ScoopName = $null
        Caveat = $null; NotFoundCaveat = $null
    },
    [PSCustomObject]@{
        Name = 'auggie'; Command = 'auggie'; Channel = 'npm'
        Package = '@augmentcode/auggie'; GithubRepo = $null
        BuiltinUpgradeArgs = $null; ScoopName = $null
        Caveat = $null
        NotFoundCaveat = "not found on native Windows PATH -- Augment Code CLI officially supports Windows only via WSL, see docs.augmentcode.com"
    }
)

$candidates = $tools
if ($Only -and $Only.Count -gt 0) {
    $candidates = @($tools | Where-Object { $Only -contains $_.Name })
    if ($candidates.Count -eq 0) {
        $knownNames = ($tools | ForEach-Object { $_.Name }) -join ', '
        Write-DevKitError "None of the names in -Only match a known tool ($knownNames)."
        exit 1
    }
}

function Get-AiCliLocalVersion {
    param([string]$CommandPath)
    try {
        $output = & $CommandPath --version 2>&1
        $exitCode = $LASTEXITCODE
    } catch {
        return $null
    }
    if ($null -ne $exitCode -and $exitCode -ne 0) { return $null }
    $firstLine = [string](@($output) | Select-Object -First 1)
    if ($firstLine -match '(\d+\.\d+(\.\d+)?(-[A-Za-z0-9.]+)?)') { return $matches[1] }
    return $null
}

function Get-NpmLatestVersion {
    param([string]$Package)
    try {
        $output = npm view $Package version 2>&1
        $exitCode = $LASTEXITCODE
    } catch {
        return $null
    }
    if ($exitCode -ne 0) { return $null }
    $line = [string](@($output) | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($line)) { return $null }
    return $line.Trim()
}

function Get-GithubLatestReleaseVersion {
    <#
    .SYNOPSIS
        Latest release tag (v-prefix stripped) for a GitHub repo, via the
        public Releases API. Used for tools whose channel isn't plain npm
        (Supabase/Scoop) or as a fallback when "npm view" doesn't resolve.
    #>
    param([Parameter(Mandatory = $true)][string]$Repo)
    try {
        $uri = "https://api.github.com/repos/$Repo/releases/latest"
        $response = Invoke-RestMethod -Uri $uri -Headers @{ 'User-Agent' = 'NorthstarDevKit' } -TimeoutSec 10 -ErrorAction Stop
        if ($response -and $response.tag_name) {
            return ($response.tag_name -replace '^v', '')
        }
        return $null
    } catch {
        return $null
    }
}

function Get-AiCliLatestVersion {
    <# Dispatches to the right "latest version" source for a tool's channel. #>
    param([Parameter(Mandatory = $true)]$Tool)

    switch ($Tool.Channel) {
        'npm' { return Get-NpmLatestVersion -Package $Tool.Package }
        'npm+builtin' {
            $version = Get-NpmLatestVersion -Package $Tool.Package
            if (-not $version -and $Tool.GithubRepo) {
                $version = Get-GithubLatestReleaseVersion -Repo $Tool.GithubRepo
            }
            return $version
        }
        'scoop' { return Get-GithubLatestReleaseVersion -Repo $Tool.GithubRepo }
        default { return $null }
    }
}

function Invoke-DevKitAiCliNpmInstall {
    <#
    .SYNOPSIS
        Runs "npm install -g PACKAGE@latest", output captured via 2>&1 into
        a variable exactly as before, wrapped in Invoke-DevKitWithSpinner
        (lib/DevKit-UI.ps1) so a capable console shows an animated spinner
        instead of a silent blocking pause. Rethrows on failure; callers
        just need to catch and count.
    .DESCRIPTION
        Invoke-DevKitWithSpinner's animated path runs the scriptblock on a
        brand-new PowerShell Runspace via AddScript() - confirmed by
        direct test that this does NOT preserve a closure over this
        function's own variables (AddScript(ScriptBlock) is implicitly
        coerced to AddScript(string), which loses lexical scope entirely).
        So $Package is baked into the scriptblock's own source text via
        [scriptblock]::Create() rather than captured from an outer
        variable, and failure detail (exit code + captured npm output) is
        folded into the thrown exception's message rather than a
        script-scope variable, so it survives the trip through EndInvoke()
        and is still shown by Invoke-DevKitWithSpinner's own
        Write-DevKitError line.
    .PARAMETER Package
        npm package name, e.g. "@anthropic-ai/claude-code".
    .PARAMETER StepLabel
        Message shown next to the spinner / step chrome.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Package,
        [Parameter(Mandatory = $true)][string]$StepLabel
    )

    $template = @'
$out = npm install -g "{0}@latest" 2>&1
if ($LASTEXITCODE -ne 0) {{
    $joined = ($out | Out-String).Trim()
    throw "npm install -g {0}@latest failed with exit code $LASTEXITCODE.`n$joined"
}}
$out
'@
    $scriptText = $template -f $Package
    $installScriptBlock = [scriptblock]::Create($scriptText)

    Invoke-DevKitWithSpinner -Message $StepLabel -ScriptBlock $installScriptBlock | Out-Null
}

function Test-DevKitAiCliVersionMismatch {
    <#
    .SYNOPSIS
        Detects when an "update available" comparison is more likely a
        different tool sharing the same command name than a genuine update.
    .DESCRIPTION
        A wildly higher installed major version than this channel's own
        "latest" (e.g. local v1.44.0 vs. a package whose latest is v0.23.6)
        is a strong signal the resolved command isn't actually built from
        the package/repo this tool entry points at - more likely a
        different CLI that happens to share a command name (e.g. a Python
        kimi-cli install vs. the npm @moonshot-ai/kimi-code package tracked
        here) than something out of date. Flags when the installed major
        version is at least 2 higher than latest's major version, e.g.
        current=3.0.0/latest=0.5.0 (diff 3) is flagged, but a real
        one-major-version bump like current=2.0.0/latest=1.9.0 (diff 1) is
        NOT flagged, matching this script's original inline threshold.
    .PARAMETER Current
        Installed version string, e.g. "1.44.0".
    .PARAMETER Latest
        Latest version string for the tool's channel, e.g. "0.23.6".
    .OUTPUTS
        [bool] - $true when the versions look inconsistent enough to skip
        an automatic update; $false (including when either version string
        has no leading numeric major component) otherwise.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Current,
        [Parameter(Mandatory = $true)][string]$Latest
    )

    $currentMajorMatch = [regex]::Match($Current, '^(\d+)')
    $latestMajorMatch = [regex]::Match($Latest, '^(\d+)')
    if (-not ($currentMajorMatch.Success -and $latestMajorMatch.Success)) { return $false }

    $currentMajor = [int]$currentMajorMatch.Groups[1].Value
    $latestMajor = [int]$latestMajorMatch.Groups[1].Value
    return ($currentMajor -ge ($latestMajor + 2))
}

# Skip the DETECT/COMPARE/UPDATE flow when this script is dot-sourced (e.g.
# tests/Unit/UpdateAiClis-VersionCompare.Tests.ps1, which dot-sources this
# file purely to unit test Test-DevKitAiCliVersionMismatch) so tests never
# enumerate real installed CLIs or shell out to npm/GitHub.
if ($MyInvocation.InvocationName -eq '.') {
    return
}

Write-DevKitHeader "Update AI CLIs"

# ==================== DETECT ====================

$installed = @()
foreach ($tool in $candidates) {
    if ($tool.Channel -eq 'manual') {
        $cmd = Get-DevKitWindowsExecutable -Name $tool.Command
        if ($cmd) {
            Write-Host "  $($tool.Name) -- no known automatic update path - update manually" -ForegroundColor Gray
        } else {
            Write-Host "  $($tool.Name) -- not installed, skipping" -ForegroundColor Gray
        }
        continue
    }

    $cmd = Get-DevKitWindowsExecutable -Name $tool.Command
    if (-not $cmd) {
        if ($tool.NotFoundCaveat) {
            Write-Host "  $($tool.Name) -- $($tool.NotFoundCaveat)" -ForegroundColor Gray
        } else {
            Write-Host "  $($tool.Name) -- not installed, skipping" -ForegroundColor Gray
        }
        continue
    }

    $tool | Add-Member -NotePropertyName CommandPath -NotePropertyValue $cmd.Source -Force
    $installed += $tool
}

if ($installed.Count -eq 0) {
    Write-DevKitInfo "No installed, automatically-updatable AI CLIs found."
    exit 0
}

# ==================== COMPARE ====================

Write-Host ""
$updatable = @()
foreach ($tool in $installed) {
    $current = Get-AiCliLocalVersion -CommandPath $tool.CommandPath
    $latest = Get-AiCliLatestVersion -Tool $tool

    $currentDisplay = if ($current) { $current } else { 'unknown' }
    $latestDisplay = if ($latest) { $latest } else { 'unavailable (network?)' }
    $updateAvailable = ($current -and $latest -and $current -ne $latest)

    # Defensive check (Test-DevKitAiCliVersionMismatch, above): treating a
    # version mismatch as a genuine "update" would risk npm-installing an
    # unrelated package over a real tool the user already has, so it's
    # reported as a mismatch instead and never added to $updatable.
    $possibleMismatch = $false
    if ($updateAvailable) {
        $possibleMismatch = Test-DevKitAiCliVersionMismatch -Current $current -Latest $latest
    }

    $sourceLabel = if ($tool.Package) { $tool.Package } else { $tool.GithubRepo }
    $line = "  $($tool.Name) ($sourceLabel): current=$currentDisplay latest=$latestDisplay"
    if ($possibleMismatch) {
        Write-Host "$line -- version looks inconsistent with this package; this may be a different tool sharing the '$($tool.Command)' command name -- skipping automatic update, verify manually" -ForegroundColor Yellow
    } elseif ($updateAvailable) {
        Write-Host "$line -- update available" -ForegroundColor Yellow
        $updatable += $tool
    } else {
        Write-Host $line -ForegroundColor Gray
    }

    if ($tool.Caveat) {
        Write-Host "    note: $($tool.Caveat)" -ForegroundColor Gray
    }
}

if ($DryRun) {
    Write-Host ""
    Write-DevKitInfo "[DRY RUN] No changes made."
    exit 0
}

if ($updatable.Count -eq 0) {
    Write-Host ""
    Write-Host "  Everything is already up to date." -ForegroundColor Green
    exit 0
}

Write-Host ""
if (-not (Confirm-DevKitDestructiveAction -Action "update $($updatable.Count) AI CLI tool(s)" -Force:$Force)) {
    Write-DevKitInfo "Cancelled."
    exit 0
}

# ==================== UPDATE ====================

Write-Host ""
$failures = 0
$manualSkipped = 0

foreach ($tool in $updatable) {
    switch ($tool.Channel) {
        'npm' {
            try {
                Invoke-DevKitAiCliNpmInstall -Package $tool.Package -StepLabel "Updating $($tool.Name) ($($tool.Package))"
            } catch {
                $failures++
            }
        }

        'npm+builtin' {
            $handled = $false
            if ($tool.BuiltinUpgradeArgs -and $tool.CommandPath) {
                Write-Host "  Updating $($tool.Name) via its built-in upgrade command ($($tool.Command) $($tool.BuiltinUpgradeArgs -join ' '))..." -ForegroundColor Cyan
                try {
                    & $tool.CommandPath @($tool.BuiltinUpgradeArgs)
                    $builtinExit = $LASTEXITCODE
                    if ($null -eq $builtinExit -or $builtinExit -eq 0) {
                        Write-Host "  $($tool.Name): built-in upgrade finished." -ForegroundColor Green
                        $handled = $true
                    } else {
                        Write-Host "  $($tool.Name): built-in upgrade exited with code $builtinExit -- falling back to npm install." -ForegroundColor Yellow
                    }
                } catch {
                    Write-Host "  $($tool.Name): built-in upgrade failed ($_) -- falling back to npm install." -ForegroundColor Yellow
                }
            }

            if (-not $handled) {
                try {
                    Invoke-DevKitAiCliNpmInstall -Package $tool.Package -StepLabel "Updating $($tool.Name) ($($tool.Package)) via npm"
                } catch {
                    $failures++
                }
            }
        }

        'scoop' {
            $scoopAvailable = [bool](Get-Command scoop -ErrorAction SilentlyContinue)
            $installedViaScoop = $tool.CommandPath -and ($tool.CommandPath -match '\\scoop\\')

            if ($scoopAvailable -and $installedViaScoop) {
                Write-Host "  Updating $($tool.Name) via scoop ($($tool.ScoopName))..." -ForegroundColor Cyan
                try {
                    scoop update $tool.ScoopName
                    if ($null -eq $LASTEXITCODE -or $LASTEXITCODE -eq 0) {
                        Write-Host "  $($tool.Name): scoop update finished." -ForegroundColor Green
                    } else {
                        Write-Host "  $($tool.Name): scoop update exited with code $LASTEXITCODE" -ForegroundColor Red
                        $failures++
                    }
                } catch {
                    Write-Host "  $($tool.Name): scoop update failed: $_" -ForegroundColor Red
                    $failures++
                }
            } else {
                $hint = if ($tool.Caveat) { $tool.Caveat } else { "install/update it manually." }
                Write-Host "  $($tool.Name) -- update manually: $hint" -ForegroundColor Gray
                $manualSkipped++
            }
        }
    }
}

Write-Host ""
if ($failures -gt 0) {
    Write-DevKitError "$failures of $($updatable.Count) update(s) failed."
    if ($manualSkipped -gt 0) {
        Write-DevKitInfo "$manualSkipped tool(s) could not be automated - see the manual-update notes above."
    }
    exit 1
}

if ($manualSkipped -gt 0) {
    Write-DevKitInfo "$manualSkipped of $($updatable.Count) tool(s) could not be automated - see the manual-update notes above."
    exit 0
}

Write-Host "  DONE: All $($updatable.Count) AI CLI tool(s) updated." -ForegroundColor Green
exit 0
