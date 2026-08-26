#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pure-logic error/diagnostics collectors - Northstar DevKit
.DESCRIPTION
    Backs the three `errors.*` RPC methods (see core/RpcMethods.ps1) that
    feed the app's Error Center:

      - errors.system      Windows Event Log Critical/Error entries. Same
                           Get-WinEvent FilterHashtable approach - and the
                           same defensive posture about "No events were
                           found" being a NORMAL outcome - as
                           tools/maintenance/Get-RecentEventErrors.ps1.
      - errors.app         DevKit's OWN failures, parsed out of the rolling
                           tracing log under
                           %LOCALAPPDATA%\NorthstarDevKit\logs\devkit.log*.
      - errors.clearAppLogs  Empties those log files.

    THE ENTRY SHAPE IS A CONTRACT. app/src/stores/useErrorStore.ts consumes
    these hashtables directly, so the keys are exactly:

        source     'system' | 'app'
        severity   'critical' | 'error' | 'warning'
        timestamp  ISO 8601 string, UTC, in JS toISOString() shape
        title      one line, already collapsed and capped
        detail     full text (event message / log message + continuations)
        origin     event provider name, or the tracing target
        meta       hashtable of source-specific extras

    id / count / dedupeKey are deliberately NOT emitted - the store computes
    those (identical faults collapse into one row with count=N).

    NOTHING HERE THROWS. Every collector degrades to an empty array or to a
    single synthetic "note" entry explaining why it is empty, because the
    Error Center is precisely the surface a user opens when something is
    already broken - it must not be the next thing that breaks.

    The pure halves (line parser, severity mapping, entry mapping, the
    active-log-file test) are split out from the I/O so they can be covered
    by Pester without a real Event Log or a real log directory - see
    tests/Unit/ErrorsCore.Tests.ps1.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
#>

# Prevent double-loading (same guard pattern as every other core/tools lib -
# DevKit.Core.psm1 is imported once per lane runspace with -Force).
if ($global:DevKitErrorsLoaded) { return }
$global:DevKitErrorsLoaded = $true

# ==================== SHARED SHAPE HELPERS ====================

# Titles are one line in a fixed-height list row; the untruncated text always
# survives in `detail`, so capping here costs nothing.
$script:DevKitErrorTitleMax = 160

function ConvertTo-DevKitErrorTitle {
    <#
    .SYNOPSIS
        Collapses a possibly-multiline, possibly-enormous message into the
        one-line title the Error Center list renders.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Message, [string]$Fallback = '(no message)')

    if ([string]::IsNullOrWhiteSpace($Message)) { return $Fallback }
    $line = ($Message -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($line)) { return $Fallback }
    $line = ($line -replace '\s+', ' ').Trim()
    if ($line.Length -gt $script:DevKitErrorTitleMax) {
        $line = $line.Substring(0, $script:DevKitErrorTitleMax) + '...'
    }
    return $line
}

# Exactly what JavaScript's Date.prototype.toISOString() produces, which is
# the one shape the ECMAScript grammar guarantees `new Date(s)` parses
# without falling back to an implementation-defined lenient parser. NOT the
# .NET 'o' round-trip format: on a DateTimeOffset that renders the offset as
# "+00:00" with SEVEN fractional digits, both of which push the string
# outside the spec'd format.
$script:DevKitErrorTimestampFormat = "yyyy-MM-ddTHH:mm:ss.fff'Z'"

function ConvertTo-DevKitErrorTimestamp {
    <#
    .SYNOPSIS
        Normalizes anything date-ish to the UTC ISO 8601 string the JS side
        can hand straight to `new Date(...)`. Unparsable input is returned
        verbatim rather than dropped - a slightly odd timestamp in the UI
        beats losing the entry.
    #>
    param($Value)

    $invariant = [System.Globalization.CultureInfo]::InvariantCulture

    if ($null -eq $Value) {
        return ([DateTimeOffset]::UtcNow.UtcDateTime.ToString($script:DevKitErrorTimestampFormat, $invariant))
    }
    if ($Value -is [DateTime]) {
        return (([DateTime]$Value).ToUniversalTime().ToString($script:DevKitErrorTimestampFormat, $invariant))
    }
    if ($Value -is [DateTimeOffset]) {
        return (([DateTimeOffset]$Value).UtcDateTime.ToString($script:DevKitErrorTimestampFormat, $invariant))
    }

    $text = [string]$Value
    $parsed = [DateTimeOffset]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::RoundtripKind -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
    if ([DateTimeOffset]::TryParse($text, $invariant, $styles, [ref]$parsed)) {
        return ($parsed.UtcDateTime.ToString($script:DevKitErrorTimestampFormat, $invariant))
    }
    return $text
}

function New-DevKitErrorEntry {
    <#
    .SYNOPSIS
        The one place an Error Center entry is constructed, so the key names
        the frontend store depends on are written exactly once.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('system', 'app')][string]$Source,
        [Parameter(Mandatory)][ValidateSet('critical', 'error', 'warning')][string]$Severity,
        $Timestamp,
        [AllowEmptyString()][string]$Title,
        [AllowNull()][AllowEmptyString()][string]$Detail = '',
        [AllowNull()][AllowEmptyString()][string]$Origin = '',
        [hashtable]$Meta = @{}
    )

    # Plain locals, not inline `if` expressions inside the literal: a
    # statement-as-value in a hashtable literal is not valid on Windows
    # PowerShell 5.1, which the sidecar still falls back to when pwsh 7 is
    # absent (see RpcMethods.ps1's ArgumentList branch for the same concern).
    $detailText = ''
    if ($null -ne $Detail) { $detailText = $Detail }
    $originText = ''
    if ($null -ne $Origin) { $originText = $Origin }

    return [ordered]@{
        source    = $Source
        severity  = $Severity
        timestamp = (ConvertTo-DevKitErrorTimestamp $Timestamp)
        title     = $Title
        detail    = $detailText
        origin    = $originText
        meta      = $Meta
    }
}

function New-DevKitErrorNote {
    <#
    .SYNOPSIS
        A synthetic entry standing in for "the collector itself failed".
    .DESCRIPTION
        errors.system / errors.app must always return an ARRAY of entries
        (they are registered in RpcMethods.ps1's $DevKitRpcArrayMethods), so
        there is nowhere to put a side-channel error string. Reporting the
        failure AS an entry is also the friendlier outcome: instead of an
        Error Center that is silently and inexplicably empty, the user sees
        one row saying "the event log could not be read, here's why".
    #>
    param(
        [Parameter(Mandatory)][string]$Origin,
        [Parameter(Mandatory)][string]$Title,
        [AllowEmptyString()][string]$Detail = '',
        [ValidateSet('critical', 'error', 'warning')][string]$Severity = 'warning'
    )

    return (New-DevKitErrorEntry -Source 'app' -Severity $Severity -Timestamp ([DateTimeOffset]::UtcNow) `
        -Title $Title -Detail $Detail -Origin $Origin -Meta @{ collectorFailure = $true })
}

# ==================== WINDOWS EVENT LOG ====================

function Get-DevKitEventSeverity {
    <#
    .SYNOPSIS
        Maps a Windows event Level to the store's severity vocabulary.
        1 = Critical, 2 = Error, 3 = Warning (0 = LogAlways, which the
        System log uses for a handful of provider-defined criticals).
    #>
    param($Level)

    $n = 0
    if (-not [int]::TryParse([string]$Level, [ref]$n)) { return 'error' }
    switch ($n) {
        1 { return 'critical' }
        2 { return 'error' }
        3 { return 'warning' }
        default { return 'error' }
    }
}

function ConvertTo-DevKitSystemErrorEntry {
    <#
    .SYNOPSIS
        Maps ONE Get-WinEvent record onto the Error Center entry shape.
    .DESCRIPTION
        Takes anything with the EventLogRecord property surface
        (TimeCreated / Level / Id / ProviderName / LogName / Message /
        RecordId), so tests can feed a plain PSCustomObject instead of
        needing a real Event Log.

        A record whose Message is $null is normal, not an error: the
        provider's message DLL may be missing or unregistered. Those still
        get an entry, titled from the log/provider/id triple.
    #>
    param([Parameter(Mandatory)]$EventRecord)

    $message = $null
    try { $message = [string]$EventRecord.Message } catch { $message = $null }

    $provider = ''
    try { $provider = [string]$EventRecord.ProviderName } catch { $provider = '' }
    if ([string]::IsNullOrWhiteSpace($provider)) { $provider = 'Unknown' }

    $logName = ''
    try { $logName = [string]$EventRecord.LogName } catch { $logName = '' }

    $eventId = $null
    try { $eventId = $EventRecord.Id } catch { $eventId = $null }

    $recordId = $null
    try { $recordId = $EventRecord.RecordId } catch { $recordId = $null }

    $level = $null
    try { $level = $EventRecord.Level } catch { $level = $null }

    $levelName = ''
    try { $levelName = [string]$EventRecord.LevelDisplayName } catch { $levelName = '' }

    $timeCreated = $null
    try { $timeCreated = $EventRecord.TimeCreated } catch { $timeCreated = $null }

    $fallbackTitle = "$logName event $eventId from $provider".Trim()
    $title = ConvertTo-DevKitErrorTitle -Message $message -Fallback $fallbackTitle

    $detail = $message
    if ([string]::IsNullOrWhiteSpace($detail)) {
        $detail = "(no message text - the provider's message resource is missing or unregistered)"
    }

    return (New-DevKitErrorEntry -Source 'system' -Severity (Get-DevKitEventSeverity $level) `
            -Timestamp $timeCreated -Title $title -Detail $detail -Origin $provider -Meta @{
            eventId   = $eventId
            logName   = $logName
            recordId  = $recordId
            level     = $level
            levelName = $levelName
        })
}

function Get-DevKitSystemErrors {
    <#
    .SYNOPSIS
        Critical + Error events from the System and Application logs.
    .PARAMETER Hours
        How far back to look. Clamped to 1..720 (30 days).
    .PARAMETER Max
        Ceiling on returned entries. Clamped to 1..1000.
    .OUTPUTS
        An array of Error Center entries, newest first. NEVER throws:
        - no matching events        -> empty array
        - access denied / bad query -> a single synthetic note entry
    #>
    [CmdletBinding()]
    param(
        [int]$Hours = 24,
        [int]$Max = 100
    )

    if ($Hours -lt 1) { $Hours = 1 }
    if ($Hours -gt 720) { $Hours = 720 }
    if ($Max -lt 1) { $Max = 1 }
    if ($Max -gt 1000) { $Max = 1000 }

    $events = @()
    try {
        $events = @(Get-WinEvent -FilterHashtable @{
                LogName   = 'System', 'Application'
                Level     = 1, 2
                StartTime = (Get-Date).AddHours(-$Hours)
            } -MaxEvents $Max -ErrorAction Stop)
    } catch {
        # Get-WinEvent THROWS (rather than returning an empty collection)
        # when the filter matches nothing - that is the normal quiet-machine
        # outcome, not a failure. Everything else genuinely failed.
        if ($_.Exception.Message -match 'No events were found') { return @() }
        return @(New-DevKitErrorNote -Origin 'errors.system' `
                -Title 'Could not read the Windows Event Log' `
                -Detail "Get-WinEvent failed: $($_.Exception.Message)")
    }

    if ($events.Count -eq 0) { return @() }

    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($evt in $events) {
        try { $entries.Add((ConvertTo-DevKitSystemErrorEntry -EventRecord $evt)) } catch { }
    }
    # Get-WinEvent already returns newest-first; sort defensively anyway so
    # the contract holds regardless of provider ordering quirks.
    return @($entries | Sort-Object -Property timestamp -Descending)
}

# ==================== DEVKIT'S OWN TRACING LOG ====================
#
# app/src-tauri/src/lib.rs sets up tracing_appender::rolling::daily into
# %LOCALAPPDATA%\NorthstarDevKit\logs\, so the files are named
# devkit.log.YYYY-MM-DD (UTC-dated) and the default fmt layer writes:
#
#   2026-08-26T00:19:50.510068Z  INFO devkit_lib: sidecar spawned elapsed_ms=21
#   <-------- timestamp -------> <lvl> <-target-> <----- message ----->
#
# crates/devkit-host/src/host.rs forwards EVERY sidecar stderr line through
# `warn!(target: "devkit_sidecar_stderr", ...)`, so the PowerShell side's
# routine boot diagnostics ("lanes started", "[work] ready after 338ms")
# arrive as WARN too. Surfacing those as warnings would bury real faults
# under a dozen rows of startup noise on every launch, so a small allowlist
# of known-benign sidecar diagnostics is dropped - see
# Test-DevKitBenignSidecarLine, which is deliberately an exact-prefix
# allowlist rather than a heuristic.

# 'LEVEL target: message' - target allows Rust module paths (devkit_lib::commands).
# Anything after the target's colon (including a tracing span prefix like
# `span{field=1}:`) stays in the message.
$script:DevKitLogLinePattern = '^(?<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2}))\s+(?<level>TRACE|DEBUG|INFO|WARN|ERROR)\s+(?<target>[A-Za-z0-9_.:\-]+):\s?(?<message>.*)$'

# Sidecar stderr lines that are normal lifecycle chatter, not faults. Matched
# against the message only when the target is devkit_sidecar_stderr.
$script:DevKitBenignSidecarPatterns = @(
    '^\[devkit-rpc\] booting\b'
    '^\[devkit-rpc\] lanes started\b'
    '^\[devkit-rpc\] entering read loop\b'
    '^\[devkit-rpc\] draining lanes\b'
    '^\[devkit-rpc\] shutdown complete\b'
    '^\[devkit-rpc\] stdin EOF\b'
    '^\[devkit-rpc\]\[[a-z]+\] ready after\b'
)

# Messages that are worse than their level says. The sidecar's lane-init
# failure and a Rust panic both arrive at WARN (the former because it is a
# sidecar stderr line, the latter because a panic hook may log below ERROR);
# both are unambiguously critical.
$script:DevKitCriticalMessagePatterns = @(
    'panicked at'
    'FAILED to initialize'
    'LaneInitFailed'
)

# The sidecar writes a PowerShell ScriptStackTrace to stderr ONE LINE AT A
# TIME (Invoke-DevKitRpc.ps1's lane-init catch does
# `[Console]::Error.WriteLine($importError.ScriptStackTrace)`), and the Rust
# host wraps each of those in its own timestamped WARN record. So the normal
# continuation fold - which only catches lines that are not entry headers -
# does not apply: every stack frame arrives as a fully-formed log entry.
# Verified against the real devkit.log: ONE lane-init failure produced one
# useful row followed by four "at <ScriptBlock>, <No file>: line 20" rows,
# and with all five lanes failing that is the whole Error Center.
#
# These patterns identify a sidecar stderr line that is CONTINUING the
# sidecar line above it rather than reporting a new fault. They are matched
# only when both that line and its predecessor came from
# devkit_sidecar_stderr.
$script:DevKitSidecarContinuationPatterns = @(
    '^\s*at\s+\S.*,\s.*:\s*line\s+\d+\s*$'   # PowerShell stack frame
    '^\s*\+\s+CategoryInfo\s*:'              # Write-Error record tail
    '^\s*\+\s+FullyQualifiedErrorId\s*:'
    '^\s*\+\s*~+\s*$'                        # the squiggle under an error line
)

function Test-DevKitBenignSidecarLine {
    <#
    .SYNOPSIS
        $true for a sidecar stderr line that is routine lifecycle chatter
        rather than a fault. Exact-prefix allowlist only - anything the
        allowlist does not recognize is treated as a real diagnostic.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) { return $false }
    $text = $Message.Trim()
    foreach ($pattern in $script:DevKitBenignSidecarPatterns) {
        if ($text -match $pattern) { return $true }
    }
    return $false
}

function Test-DevKitSidecarContinuationLine {
    <#
    .SYNOPSIS
        $true for a sidecar stderr line that is the tail of the sidecar line
        above it (a stack frame, an error-record footer) rather than a fault
        of its own - see the pattern list's comment for why these arrive as
        separate log entries.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) { return $false }
    foreach ($pattern in $script:DevKitSidecarContinuationPatterns) {
        if ($Message -match $pattern) { return $true }
    }
    return $false
}

function Get-DevKitLogSeverity {
    <#
    .SYNOPSIS
        Maps a tracing level (+ the message text) onto the store's severity
        vocabulary, or $null for "below the Error Center's threshold".
    .DESCRIPTION
        WARN and above only. A message matching a critical marker is
        promoted regardless of its level - see the note above about the
        sidecar's stderr being logged wholesale at WARN.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Level,
        [AllowNull()][AllowEmptyString()][string]$Message
    )

    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        foreach ($pattern in $script:DevKitCriticalMessagePatterns) {
            if ($Message -match $pattern) { return 'critical' }
        }
    }
    switch (([string]$Level).ToUpperInvariant()) {
        'ERROR' { return 'error' }
        'FATAL' { return 'critical' }
        'WARN' { return 'warning' }
        default { return $null }
    }
}

function ConvertFrom-DevKitLogLine {
    <#
    .SYNOPSIS
        Parses ONE tracing-formatted log line into its parts, or returns
        $null when the line is not an entry header (a blank line, or a
        continuation line belonging to the previous entry - a stack trace,
        a wrapped panic payload).
    .OUTPUTS
        [pscustomobject] Timestamp / Level / Target / Message
    #>
    param([AllowNull()][AllowEmptyString()][string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }
    $m = [regex]::Match($Line.TrimEnd(), $script:DevKitLogLinePattern)
    if (-not $m.Success) { return $null }

    return [pscustomobject]@{
        Timestamp = $m.Groups['ts'].Value
        Level     = $m.Groups['level'].Value.ToUpperInvariant()
        Target    = $m.Groups['target'].Value
        Message   = $m.Groups['message'].Value
    }
}

function ConvertFrom-DevKitAppLogText {
    <#
    .SYNOPSIS
        Parses a whole (or tail of a) tracing log into Error Center entries.
    .DESCRIPTION
        Two-pass by design:
          1. Fold the text into records, attaching every non-header line to
             the record above it (stack traces, wrapped panics). This pass
             keeps records of ALL levels - a continuation line under an
             INFO record must not be misattributed to the last WARN.
          2. Filter to WARN-and-above, drop benign sidecar chatter, and map
             what survives onto entries.

        Leading continuation lines with no header above them are dropped,
        which is exactly what a mid-entry tail read produces.
    .PARAMETER FileName
        Recorded in meta.file so the Error Center can say which rotated log
        an entry came from.
    .OUTPUTS
        Entries in FILE order (oldest first). Callers that want newest-first
        reverse afterwards - see Get-DevKitAppErrors.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [string]$FileName = ''
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }

    $records = [System.Collections.Generic.List[object]]::new()
    $current = $null
    $lineNumber = 0
    foreach ($line in ($Text -split "`r?`n")) {
        $lineNumber++
        $parsed = ConvertFrom-DevKitLogLine -Line $line
        if ($null -ne $parsed) {
            # A sidecar stack frame is a fully-formed log entry that is
            # nonetheless a continuation - fold it into the sidecar record
            # above rather than letting it become its own row.
            if ($null -ne $current -and
                $parsed.Target -eq 'devkit_sidecar_stderr' -and
                $current.Target -eq 'devkit_sidecar_stderr' -and
                (Test-DevKitSidecarContinuationLine -Message $parsed.Message)) {
                $current.Extra.Add($parsed.Message)
                continue
            }
            $current = [pscustomobject]@{
                Timestamp = $parsed.Timestamp
                Level     = $parsed.Level
                Target    = $parsed.Target
                Message   = $parsed.Message
                Extra     = [System.Collections.Generic.List[string]]::new()
                Line      = $lineNumber
            }
            $records.Add($current)
        } elseif ($null -ne $current -and -not [string]::IsNullOrWhiteSpace($line)) {
            $current.Extra.Add($line.TrimEnd())
        }
    }

    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($record in $records) {
        $severity = Get-DevKitLogSeverity -Level $record.Level -Message $record.Message
        if ($null -eq $severity) { continue }
        if ($record.Target -eq 'devkit_sidecar_stderr' -and (Test-DevKitBenignSidecarLine -Message $record.Message)) {
            continue
        }

        $detail = $record.Message
        if ($record.Extra.Count -gt 0) {
            $detail = (@($record.Message) + @($record.Extra)) -join "`n"
        }

        $entries.Add((New-DevKitErrorEntry -Source 'app' -Severity $severity -Timestamp $record.Timestamp `
                    -Title (ConvertTo-DevKitErrorTitle -Message $record.Message -Fallback $record.Target) `
                    -Detail $detail -Origin $record.Target -Meta @{
                    level = $record.Level
                    file  = $FileName
                    line  = $record.Line
                }))
    }

    return @($entries)
}

function Get-DevKitAppLogDirectory {
    <#
    .SYNOPSIS
        %LOCALAPPDATA%\NorthstarDevKit\logs - the directory
        app/src-tauri/src/lib.rs's init_logging() writes into. $null when
        LOCALAPPDATA is unset (which would also have stopped logging).
    #>
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { return $null }
    return (Join-Path $env:LOCALAPPDATA 'NorthstarDevKit\logs')
}

function Get-DevKitAppLogFiles {
    <#
    .SYNOPSIS
        The rolling devkit.log* files, NEWEST FIRST. Empty array when the
        directory does not exist yet (a fresh install that has never
        logged) or cannot be enumerated.
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$LogDirectory)

    if ([string]::IsNullOrWhiteSpace($LogDirectory)) { return @() }
    if (-not (Test-Path -LiteralPath $LogDirectory -PathType Container)) { return @() }
    try {
        # Name is the tiebreak because the daily roller's dated suffixes sort
        # chronologically, which matters when several files share an mtime.
        return @(Get-ChildItem -LiteralPath $LogDirectory -Filter 'devkit.log*' -File -ErrorAction Stop |
                Sort-Object -Property @{ Expression = 'LastWriteTimeUtc'; Descending = $true }, @{ Expression = 'Name'; Descending = $true })
    } catch {
        return @()
    }
}

function Read-DevKitLogTail {
    <#
    .SYNOPSIS
        Reads at most the last $MaxBytes of a file, sharing the handle with
        whoever else has it open.
    .DESCRIPTION
        Two hazards this exists for:

        1. The running app HOLDS devkit.log.<today> open through
           tracing_appender's non-blocking writer. A plain read must
           therefore pass FileShare ReadWrite|Delete - anything narrower
           fails with "the process cannot access the file".
        2. A long-lived install's log can reach hundreds of megabytes.
           Get-Content -Raw would slurp all of it into memory inside a lane
           runspace; seeking to the tail keeps this bounded no matter how
           big the file gets.

        When the file is larger than $MaxBytes the read starts mid-line, so
        the first (partial) line is discarded.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$MaxBytes = 524288
    )

    if ($MaxBytes -lt 1024) { $MaxBytes = 1024 }

    $stream = $null
    $reader = $null
    $text = ''
    $startedMidLine = $false
    try {
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
        if ($stream.Length -gt $MaxBytes) {
            [void]$stream.Seek([int64](-1 * $MaxBytes), [System.IO.SeekOrigin]::End)
            $startedMidLine = $true
        }
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.UTF8Encoding]::new($false), $true)
        $text = $reader.ReadToEnd()
    } finally {
        if ($null -ne $reader) { $reader.Dispose() } elseif ($null -ne $stream) { $stream.Dispose() }
    }

    if ($startedMidLine) {
        $break = $text.IndexOf("`n")
        if ($break -ge 0) { $text = $text.Substring($break + 1) } else { $text = '' }
    }
    return $text
}

function Get-DevKitAppErrors {
    <#
    .SYNOPSIS
        DevKit's own WARN-and-above failures, newest first.
    .PARAMETER Max
        Ceiling on returned entries. Clamped to 1..1000.
    .PARAMETER LogDirectory
        Override for tests; defaults to Get-DevKitAppLogDirectory.
    .PARAMETER MaxTailBytes
        Per-file tail budget - see Read-DevKitLogTail.
    .PARAMETER MaxFiles
        How many rotated files back to look. Older ones are almost never
        useful and each one costs a tail read.
    .OUTPUTS
        An array of entries. NEVER throws: a missing log directory is an
        empty array, and a file that cannot be read contributes a synthetic
        note entry instead of aborting the whole collection.
    #>
    [CmdletBinding()]
    param(
        [int]$Max = 200,
        [AllowNull()][string]$LogDirectory,
        [int]$MaxTailBytes = 524288,
        [int]$MaxFiles = 5
    )

    if ($Max -lt 1) { $Max = 1 }
    if ($Max -gt 1000) { $Max = 1000 }
    if ($MaxFiles -lt 1) { $MaxFiles = 1 }

    if ([string]::IsNullOrWhiteSpace($LogDirectory)) { $LogDirectory = Get-DevKitAppLogDirectory }
    $files = @(Get-DevKitAppLogFiles -LogDirectory $LogDirectory)
    if ($files.Count -eq 0) { return @() }

    $collected = [System.Collections.Generic.List[object]]::new()
    foreach ($file in ($files | Select-Object -First $MaxFiles)) {
        if ($collected.Count -ge $Max) { break }
        try {
            $text = Read-DevKitLogTail -Path $file.FullName -MaxBytes $MaxTailBytes
        } catch {
            $collected.Add((New-DevKitErrorNote -Origin 'errors.app' `
                        -Title "Could not read log file $($file.Name)" `
                        -Detail $_.Exception.Message))
            continue
        }
        # Newest-first within the file: the parser returns file order.
        $fileEntries = @(ConvertFrom-DevKitAppLogText -Text $text -FileName $file.Name)
        for ($i = $fileEntries.Count - 1; $i -ge 0; $i--) {
            if ($collected.Count -ge $Max) { break }
            $collected.Add($fileEntries[$i])
        }
    }

    return @($collected)
}

function Test-DevKitActiveLogFile {
    <#
    .SYNOPSIS
        $true when a log file name is one the RUNNING app is (or may be)
        currently writing to, and therefore must be truncated rather than
        deleted.
    .DESCRIPTION
        tracing_appender::rolling::daily names its current file
        devkit.log.<UTC date>. There is no portable way to ask "does another
        process hold this open" - Rust opens the file with full share flags,
        so a successful open proves nothing - so this is decided by name,
        which is deterministic and testable. Both today's UTC date and
        today's local date count as active, so a machine whose local day has
        already rolled over never deletes the live file.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [datetime]$Now = ([datetime]::Now)
    )

    if ($Name -eq 'devkit.log') { return $true }
    $utcDate = $Now.ToUniversalTime().ToString('yyyy-MM-dd')
    $localDate = $Now.ToString('yyyy-MM-dd')
    return ($Name -eq "devkit.log.$utcDate" -or $Name -eq "devkit.log.$localDate")
}

function Clear-DevKitAppLogs {
    <#
    .SYNOPSIS
        Empties DevKit's own rolling log files.
    .DESCRIPTION
        Rotated (older) files are DELETED. The file the running app is
        currently appending to is TRUNCATED instead - deleting it would
        leave tracing_appender writing into an unlinked handle until the
        next daily roll, silently losing every log line in between.

        Truncating under the live writer is safe: Rust opens the file in
        append mode (FILE_APPEND_DATA), so the OS always positions writes at
        the current end of file - after truncation the next line lands at
        offset 0 rather than leaving a NUL-padded hole.

        A delete that fails (the file is locked by something without delete
        sharing) falls back to a truncate rather than failing the call.
    .OUTPUTS
        [ordered] cleared / deleted / truncated / skipped / directory
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$LogDirectory)

    if ([string]::IsNullOrWhiteSpace($LogDirectory)) { $LogDirectory = Get-DevKitAppLogDirectory }

    $deleted = [System.Collections.Generic.List[string]]::new()
    $truncated = [System.Collections.Generic.List[string]]::new()
    $skipped = [System.Collections.Generic.List[object]]::new()

    foreach ($file in @(Get-DevKitAppLogFiles -LogDirectory $LogDirectory)) {
        if (Test-DevKitActiveLogFile -Name $file.Name) {
            if (Clear-DevKitLogFileContent -Path $file.FullName) {
                $truncated.Add($file.Name)
            } else {
                $skipped.Add([ordered]@{ file = $file.Name; reason = 'in use and could not be truncated' })
            }
            continue
        }
        try {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            $deleted.Add($file.Name)
        } catch {
            if (Clear-DevKitLogFileContent -Path $file.FullName) {
                $truncated.Add($file.Name)
            } else {
                $skipped.Add([ordered]@{ file = $file.Name; reason = $_.Exception.Message })
            }
        }
    }

    $directoryText = ''
    if ($LogDirectory) { $directoryText = $LogDirectory }

    return [ordered]@{
        cleared   = ($deleted.Count + $truncated.Count)
        deleted   = @($deleted)
        truncated = @($truncated)
        skipped   = @($skipped)
        directory = $directoryText
    }
}

function Clear-DevKitLogFileContent {
    <#
    .SYNOPSIS
        Truncates a file to zero bytes while another process may hold it
        open for appending. $true on success, $false on failure - never
        throws.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $stream = $null
    try {
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Truncate,
            [System.IO.FileAccess]::Write,
            ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
        return $true
    } catch {
        return $false
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}
