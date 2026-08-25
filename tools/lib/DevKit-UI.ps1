#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Northstar DevKit - Animation & Color Engine
.DESCRIPTION
    Terminal-capability probing, a brand color palette, gradient text
    rendering, a startup banner, and a spinner wrapper for long-running
    scriptblocks. Dot-sourced by lib/DevKit-Common.ps1.

    Every function here fails closed: on any console that cannot prove it
    supports 24-bit ANSI truecolor (NO_COLOR set, animations disabled in
    settings, redirected output, or a real Windows Console API probe that
    can't enable virtual terminal processing), output falls straight back
    to today's plain Write-Host style - no escape codes, no crash.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.VERSION
    3.8.0
#>

# Prevent double-loading
if ($global:DevKitUiLoaded) { return }
$global:DevKitUiLoaded = $true

# One-time native interop for a real Windows Console API probe (GetStdHandle
# + GetConsoleMode + SetConsoleMode) confirming ENABLE_VIRTUAL_TERMINAL_
# PROCESSING can actually be turned on for the current stdout handle, rather
# than assuming truecolor support from the PowerShell version alone. The
# compile moved INTO Test-DevKitAnimationSupport: it's needed only when the
# probe actually runs (the banner/gradient/spinner path), so tool runs that
# never touch animation no longer pay the C# compile cost at dot-source time.

# ==================== BRAND PALETTE ====================

# The logo's duality: deep sapphire ramping through its glowing core blues
# into the ember-orange rim (the same stops as gui/Theme.xaml's button and
# accent gradients). Plain ordered array of hex strings so
# Write-DevKitGradientText can interpolate between adjacent stops.
$script:DevKitBrandPalette = @('#2E7DD1', '#4FA3FF', '#79C0FF', '#FF6B3D')

# Cached result of Test-DevKitAnimationSupport, computed at most once per
# session ($null = not yet computed; caching a real $false is done via a
# separate "has run" flag since $false itself is a legitimate cached value).
$script:DevKitAnimationSupportCache = $null
$script:DevKitAnimationSupportProbed = $false

# ==================== CAPABILITY PROBE ====================

function Test-DevKitAnimationSupport {
    <#
    .SYNOPSIS
        Determines whether the current console session can render 24-bit
        ANSI truecolor / animated output, caching the result for the rest
        of the process.
    .DESCRIPTION
        Returns $true only if ALL of the following hold:
          - The NO_COLOR environment variable is not set.
          - (Get-DevKitSettings).preferences.enableAnimations is $true.
          - [Console]::IsOutputRedirected is $false.
          - A real Windows Console API probe (GetStdHandle + GetConsoleMode
            + SetConsoleMode) confirms ENABLE_VIRTUAL_TERMINAL_PROCESSING
            can actually be enabled on the stdout handle.

        Any exception anywhere in this check - a redirected/CI host, a
        non-Windows-console host, a missing/corrupt settings file, anything
        - makes this return $false rather than throw, mirroring
        Show-DevKitInteractiveMenu's own fail-closed capability probe. The
        settings read and console-mode probe only happen once per session;
        the result (true or false) is cached in a script-scoped variable.
    .OUTPUTS
        [bool]
    #>
    if ($script:DevKitAnimationSupportProbed) {
        return $script:DevKitAnimationSupportCache
    }

    $supported = $false
    try {
        if ($null -eq $env:NO_COLOR) {
            $settings = Get-DevKitSettings
            if ($settings.preferences.enableAnimations -and (-not [Console]::IsOutputRedirected)) {
                $STD_OUTPUT_HANDLE = -11
                $ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004

                # Compiled here, not at dot-source time: only the animation
                # path needs this type (guarded - one compile per process).
                if (-not ('DevKit.ConsoleInterop' -as [type])) {
                    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace DevKit {
    public static class ConsoleInterop {
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr GetStdHandle(int nStdHandle);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out int lpMode);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool SetConsoleMode(IntPtr hConsoleHandle, int dwMode);
    }
}
'@ -ErrorAction SilentlyContinue
                }

                $handle = [DevKit.ConsoleInterop]::GetStdHandle($STD_OUTPUT_HANDLE)
                $handleValid = ($handle -ne [IntPtr]::Zero) -and ($handle.ToInt64() -ne -1)
                if ($handleValid) {
                    $mode = 0
                    if ([DevKit.ConsoleInterop]::GetConsoleMode($handle, [ref]$mode)) {
                        $newMode = $mode -bor $ENABLE_VIRTUAL_TERMINAL_PROCESSING
                        if ([DevKit.ConsoleInterop]::SetConsoleMode($handle, $newMode)) {
                            $supported = $true
                        }
                    }
                }
            }
        }
    } catch {
        $supported = $false
    }

    $script:DevKitAnimationSupportCache = $supported
    $script:DevKitAnimationSupportProbed = $true
    return $supported
}

# ==================== GRADIENT TEXT ====================

function Write-DevKitGradientText {
    <#
    .SYNOPSIS
        Prints text with color interpolated left-to-right across the brand
        palette, using 24-bit ANSI truecolor foreground escape codes.
    .DESCRIPTION
        Builds one "ESC[38;2;R;G;Bm" segment per character (ESC constructed
        via [char]27, never a literal escape byte in this file), resetting
        once with "ESC[0m" at the end. Falls back to plain
        Write-Host $Text -ForegroundColor Cyan (no escape codes at all)
        whenever Test-DevKitAnimationSupport is $false, so an unsupported
        console sees output identical to today's plain style.
    .PARAMETER Text
        The text to print.
    .EXAMPLE
        Write-DevKitGradientText -Text "Northstar DevKit v3.8.0"
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    if (-not (Test-DevKitAnimationSupport)) {
        Write-Host $Text -ForegroundColor Cyan
        return
    }

    try {
        if ([string]::IsNullOrEmpty($Text)) {
            Write-Host ""
            return
        }

        $esc = [char]27

        $stops = @()
        foreach ($hex in $script:DevKitBrandPalette) {
            $h = $hex.TrimStart('#')
            $stops += [PSCustomObject]@{
                R = [Convert]::ToInt32($h.Substring(0, 2), 16)
                G = [Convert]::ToInt32($h.Substring(2, 2), 16)
                B = [Convert]::ToInt32($h.Substring(4, 2), 16)
            }
        }

        $len = $Text.Length
        $segSpan = [Math]::Max($stops.Count - 1, 1)
        $sb = New-Object System.Text.StringBuilder

        for ($i = 0; $i -lt $len; $i++) {
            $t = if ($len -eq 1) { 0.0 } else { $i / [double]($len - 1) }
            $segPos = $t * $segSpan
            $segIndex = [Math]::Min([int][Math]::Floor($segPos), $segSpan - 1)
            if ($segIndex -lt 0) { $segIndex = 0 }
            $localT = $segPos - $segIndex

            $c0 = $stops[$segIndex]
            $c1 = $stops[[Math]::Min($segIndex + 1, $stops.Count - 1)]

            $r = [int][Math]::Round($c0.R + (($c1.R - $c0.R) * $localT))
            $g = [int][Math]::Round($c0.G + (($c1.G - $c0.G) * $localT))
            $b = [int][Math]::Round($c0.B + (($c1.B - $c0.B) * $localT))

            [void]$sb.Append("$esc[38;2;$r;$g;${b}m")
            [void]$sb.Append($Text[$i])
        }
        [void]$sb.Append("$esc[0m")

        Write-Host $sb.ToString()
    } catch {
        Write-Host $Text -ForegroundColor Cyan
    }
}

# ==================== STARTUP BANNER ====================

function Show-DevKitStartupBanner {
    <#
    .SYNOPSIS
        Prints a short gradient "Northstar DevKit vX.Y.Z" banner, intended
        to be called exactly once per session by a separate caller.
    .DESCRIPTION
        Reads the version dynamically from the repo-root VERSION file,
        resolved relative to this file's own location via $PSScriptRoot
        (lib/ -> repo root). Falls back to plain Write-Host output - no
        escape codes, no crash - reasonably close to today's banner style,
        whenever animation isn't supported or the VERSION file can't be
        read.
    .EXAMPLE
        Show-DevKitStartupBanner
    #>
    $version = '3.8.0'
    try {
        $versionFile = Join-Path (Split-Path -Parent $PSScriptRoot) "VERSION"
        if (Test-Path $versionFile) {
            $raw = (Get-Content -Path $versionFile -Raw -ErrorAction Stop).Trim()
            if (-not [string]::IsNullOrWhiteSpace($raw)) { $version = $raw }
        }
    } catch {
        # Keep the hardcoded fallback version above.
    }

    $banner = "Northstar DevKit v$version"
    $rule = "============================================="

    if (-not (Test-DevKitAnimationSupport)) {
        Write-Host ""
        Write-Host $rule -ForegroundColor Cyan
        Write-Host "  $banner" -ForegroundColor Cyan
        Write-Host "    Developer Toolkit by northstarcoding.com" -ForegroundColor Cyan
        Write-Host $rule -ForegroundColor Cyan
        return
    }

    try {
        Write-Host ""
        Write-DevKitGradientText -Text $rule
        Write-DevKitGradientText -Text "  $banner"
        Write-Host "    Developer Toolkit by northstarcoding.com" -ForegroundColor Gray
        Write-DevKitGradientText -Text $rule
    } catch {
        Write-Host ""
        Write-Host $rule -ForegroundColor Cyan
        Write-Host "  $banner" -ForegroundColor Cyan
        Write-Host "    Developer Toolkit by northstarcoding.com" -ForegroundColor Cyan
        Write-Host $rule -ForegroundColor Cyan
    }
}

# ==================== SPINNER ====================

function Invoke-DevKitWithSpinner {
    <#
    .SYNOPSIS
        Runs a scriptblock as a drop-in replacement for "& $ScriptBlock",
        showing plain Write-DevKitStep/-Done/-Error chrome or an animated
        braille spinner, depending on console capability.
    .DESCRIPTION
        Always returns whatever $ScriptBlock returns, or rethrows whatever
        it throws, so callers' existing try/catch blocks keep working
        unchanged.

        When Test-DevKitAnimationSupport is $false, this does exactly
        today's plain sequence: Write-DevKitStep, invoke the scriptblock,
        Write-DevKitDone and return on success, or Write-DevKitError with
        the exception message and rethrow on failure.

        When animation IS supported, the entire animated path runs inside
        its own outer try/catch. The scriptblock is started on a dedicated
        Runspace via BeginInvoke() (never Start-Job/Start-ThreadJob, which
        isn't available on stock PowerShell 5.1) while this thread redraws
        a braille spinner frame in place, only once elapsed time reaches
        -MinDurationMs. If anything about runspace/animation setup throws
        BEFORE the scriptblock starts running, this falls back to the exact
        same plain sequence above - the scriptblock is invoked exactly once
        total, never twice. Once the scriptblock has started running
        asynchronously, any failure (including one surfaced by EndInvoke)
        is reported with a Write-DevKitError-styled line and the original
        exception is rethrown - it is never re-invoked. The PowerShell
        instance and Runspace are always disposed/closed in a finally
        block.
    .PARAMETER Message
        Step description, matching Write-DevKitStep's usual phrasing.
    .PARAMETER ScriptBlock
        The work to run. Its own console output should already be fully
        captured/suppressed by the caller (e.g. npm install's output
        captured via 2>&1 into a variable, or robocopy piped to Out-Null)
        since it runs off-thread while a spinner owns the console line.
    .PARAMETER MinDurationMs
        Only start drawing spinner frames once this many milliseconds have
        elapsed, so fast operations look identical to the plain sequence.
    .OUTPUTS
        Whatever $ScriptBlock returns.
    .EXAMPLE
        Invoke-DevKitWithSpinner -Message "Installing dependencies" -ScriptBlock { npm install }
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [int]$MinDurationMs = 350
    )

    if (-not (Test-DevKitAnimationSupport)) {
        Write-DevKitStep $Message
        try {
            $result = & $ScriptBlock
            Write-DevKitDone
            return $result
        } catch {
            Write-DevKitError $_.Exception.Message
            throw
        }
    }

    $runspace = $null
    $ps = $null
    $started = $false

    try {
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.Open()
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.Runspace = $runspace
        [void]$ps.AddScript($ScriptBlock)

        $asyncResult = $ps.BeginInvoke()
        # From here on the scriptblock is genuinely running - a failure
        # below must never trigger the plain-path fallback (that would
        # invoke it a second time).
        $started = $true

        # Braille "dots" spinner frames, built from code points (not literal
        # Unicode glyphs in this file's bytes) - same reasoning as building
        # ESC via [char]27 below: robust regardless of file encoding.
        $frameCodes = @(0x280B, 0x2819, 0x2839, 0x2838, 0x283C, 0x2834, 0x2826, 0x2827, 0x2807, 0x280F)
        $frames = @($frameCodes | ForEach-Object { [char]$_ })

        $esc = [char]27
        # Solid sapphire-glow color (#79C0FF - the logo's core blue) for the
        # spinner itself.
        $colorOn = "$esc[38;2;121;192;255m"
        $colorOff = "$esc[0m"

        $consoleWidth = 80
        try { $consoleWidth = [Console]::BufferWidth } catch { $consoleWidth = 80 }
        $padLen = [Math]::Max($consoleWidth - 1, 20)

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $frameIndex = 0
        $spinnerStarted = $false

        while (-not $asyncResult.IsCompleted) {
            if ($stopwatch.ElapsedMilliseconds -ge $MinDurationMs) {
                $spinnerStarted = $true
                $frame = $frames[$frameIndex % $frames.Count]
                $line = "  $frame $Message..."
                # Surface elapsed time once an op has run a couple of
                # seconds, so a genuinely long operation doesn't look hung.
                $elapsedSeconds = [int][Math]::Floor($stopwatch.Elapsed.TotalSeconds)
                if ($elapsedSeconds -ge 2) { $line += " (${elapsedSeconds}s)" }
                if ($line.Length -gt $padLen) { $line = $line.Substring(0, $padLen) }
                Write-Host ([string][char]13 + $colorOn + $line.PadRight($padLen) + $colorOff) -NoNewline
                $frameIndex++
            }
            Start-Sleep -Milliseconds 80
        }

        if ($spinnerStarted) {
            # Erase leftover spinner text with a carriage return, not
            # Clear-Host, so we redraw only this one line in place.
            Write-Host ([string][char]13 + ''.PadRight($padLen) + [string][char]13) -NoNewline
        }

        $result = $ps.EndInvoke($asyncResult)
        Write-DevKitStep $Message
        Write-DevKitDone
        return $result
    } catch {
        if (-not $started) {
            # Setup failed before the scriptblock ever ran - safe to fall
            # back to the exact plain sequence, invoking it exactly once
            # total.
            Write-DevKitStep $Message
            try {
                $result = & $ScriptBlock
                Write-DevKitDone
                return $result
            } catch {
                Write-DevKitError $_.Exception.Message
                throw
            }
        }

        # The scriptblock already started (or its own failure is what we're
        # handling here, via EndInvoke) - never invoke it again. Report the
        # real failure and rethrow the same exception.
        Write-DevKitStep $Message
        Write-DevKitError $_.Exception.Message
        throw
    } finally {
        if ($ps) { $ps.Dispose() }
        if ($runspace) {
            try { $runspace.Close() } catch {}
            $runspace.Dispose()
        }
    }
}
