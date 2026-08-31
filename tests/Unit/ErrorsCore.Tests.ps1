#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pester tests for the Error Center's collectors (core/DevKit-Errors.ps1)
.DESCRIPTION
    Covers the pure halves fixtures-in/entries-out - the tracing log-line
    parser, the tracing-level and Windows-event-level severity mappings, the
    benign-sidecar allowlist, and the entry-shape mapping the frontend store
    (app/src/stores/useErrorStore.ts) depends on - plus the file-touching
    halves against TestDrive: tail reads (including one under a live writer
    holding the file open the way tracing_appender does), rotated-file
    ordering, and the truncate-vs-delete split in Clear-DevKitAppLogs.

    Nothing here reads the real Windows Event Log or the real
    %LOCALAPPDATA% log directory: ConvertTo-DevKitSystemErrorEntry is fed
    plain PSCustomObjects with the EventLogRecord property surface, and
    every file case passes an explicit -LogDirectory.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    # See Get-DevKitPackageManager.Tests.ps1 for why these load-once flags
    # get reset when several test files share one Pester process.
    $global:DevKitErrorsLoaded = $false
    . (Join-Path $script:RepoRoot 'core\DevKit-Errors.ps1')

    # A fake Get-WinEvent record: only the properties
    # ConvertTo-DevKitSystemErrorEntry actually reads.
    function New-TestEventRecord {
        param(
            [int]$Level = 2,
            [int]$Id = 1000,
            [string]$Provider = 'Test-Provider',
            [string]$LogName = 'System',
            $Message = 'Something went wrong',
            [int64]$RecordId = 42,
            $TimeCreated = ([datetime]::new(2026, 8, 26, 1, 2, 3, [DateTimeKind]::Utc))
        )
        return [PSCustomObject]@{
            Level            = $Level
            LevelDisplayName = @('LogAlways', 'Critical', 'Error', 'Warning')[$Level]
            Id               = $Id
            ProviderName     = $Provider
            LogName          = $LogName
            Message          = $Message
            RecordId         = $RecordId
            TimeCreated      = $TimeCreated
        }
    }

    # One tracing-formatted log line, matching the real file format written
    # by app/src-tauri/src/lib.rs's fmt layer.
    function New-TestLogLine {
        param(
            [string]$Timestamp = '2026-08-26T00:19:50.510068Z',
            [string]$Level = 'WARN',
            [string]$Target = 'devkit_lib',
            [string]$Message = 'something happened'
        )
        $padded = $Level.PadLeft(5)
        return "$Timestamp $padded ${Target}: $Message"
    }
}

Describe "ConvertFrom-DevKitLogLine" {

    It "parses a real INFO line into its four parts" {
        $r = ConvertFrom-DevKitLogLine -Line '2026-08-26T00:19:50.510068Z  INFO devkit_lib: sidecar process spawned elapsed_ms=21'
        $r.Timestamp | Should -Be '2026-08-26T00:19:50.510068Z'
        $r.Level | Should -Be 'INFO'
        $r.Target | Should -Be 'devkit_lib'
        $r.Message | Should -Be 'sidecar process spawned elapsed_ms=21'
    }

    It "parses a sidecar stderr WARN line" {
        $r = ConvertFrom-DevKitLogLine -Line '2026-08-26T00:19:50.755936Z  WARN devkit_sidecar_stderr: [devkit-rpc][work] ready after 338.2145ms'
        $r.Level | Should -Be 'WARN'
        $r.Target | Should -Be 'devkit_sidecar_stderr'
        $r.Message | Should -Be '[devkit-rpc][work] ready after 338.2145ms'
    }

    It "parses a Rust module-path target" {
        $r = ConvertFrom-DevKitLogLine -Line '2026-08-26T00:19:50.510068Z ERROR devkit_lib::commands: rpc_call failed'
        $r.Target | Should -Be 'devkit_lib::commands'
        $r.Message | Should -Be 'rpc_call failed'
    }

    It "leaves a tracing span prefix in the message rather than mistaking it for the target" {
        $r = ConvertFrom-DevKitLogLine -Line '2026-08-26T00:19:50.510068Z ERROR devkit_host: request{id=7}: lane timed out'
        $r.Target | Should -Be 'devkit_host'
        $r.Message | Should -Be 'request{id=7}: lane timed out'
    }

    It "accepts a timestamp with a numeric UTC offset instead of Z" {
        $r = ConvertFrom-DevKitLogLine -Line '2026-08-26T00:19:50.510068-05:00  WARN devkit_lib: offset form'
        $r.Level | Should -Be 'WARN'
        $r.Message | Should -Be 'offset form'
    }

    It "returns `$null for blank lines and for continuation lines" {
        ConvertFrom-DevKitLogLine -Line '' | Should -BeNullOrEmpty
        ConvertFrom-DevKitLogLine -Line '   ' | Should -BeNullOrEmpty
        ConvertFrom-DevKitLogLine -Line '   at devkit_lib::commands::rpc_call' | Should -BeNullOrEmpty
        ConvertFrom-DevKitLogLine -Line 'note: run with RUST_BACKTRACE=1' | Should -BeNullOrEmpty
    }
}

Describe "Get-DevKitLogSeverity" {

    It "maps ERROR and WARN into the store's vocabulary" {
        Get-DevKitLogSeverity -Level 'ERROR' -Message 'boom' | Should -Be 'error'
        Get-DevKitLogSeverity -Level 'WARN' -Message 'careful' | Should -Be 'warning'
    }

    It "returns `$null below the WARN threshold" {
        Get-DevKitLogSeverity -Level 'INFO' -Message 'started' | Should -BeNullOrEmpty
        Get-DevKitLogSeverity -Level 'DEBUG' -Message 'x' | Should -BeNullOrEmpty
        Get-DevKitLogSeverity -Level 'TRACE' -Message 'x' | Should -BeNullOrEmpty
    }

    It "promotes a lane-init failure to critical even though it arrives at WARN" {
        # crates/devkit-host logs EVERY sidecar stderr line at WARN, so the
        # sidecar's own fatal "[work] FAILED to initialize" would otherwise
        # rank below a routine Rust ERROR.
        $msg = '[devkit-rpc][work] FAILED to initialize after 12ms: module not found'
        Get-DevKitLogSeverity -Level 'WARN' -Message $msg | Should -Be 'critical'
    }

    It "promotes a Rust panic to critical" {
        Get-DevKitLogSeverity -Level 'ERROR' -Message "thread 'main' panicked at src/lib.rs:42" | Should -Be 'critical'
    }

    It "is case-insensitive about the level" {
        Get-DevKitLogSeverity -Level 'warn' -Message 'x' | Should -Be 'warning'
    }
}

Describe "Test-DevKitBenignSidecarLine" {

    It "recognizes routine lifecycle chatter" {
        Test-DevKitBenignSidecarLine -Message '[devkit-rpc] booting - repo root: C:\DevKit' | Should -BeTrue
        Test-DevKitBenignSidecarLine -Message '[devkit-rpc] lanes started, entering read loop' | Should -BeTrue
        Test-DevKitBenignSidecarLine -Message '[devkit-rpc][metrics] ready after 150.9871ms' | Should -BeTrue
        Test-DevKitBenignSidecarLine -Message '[devkit-rpc] draining lanes' | Should -BeTrue
        Test-DevKitBenignSidecarLine -Message '[devkit-rpc] shutdown complete' | Should -BeTrue
        Test-DevKitBenignSidecarLine -Message '[devkit-rpc] child stdin detached (STD_INPUT_HANDLE -> inheritable NUL)' | Should -BeTrue
    }

    It "does NOT swallow a real sidecar fault" {
        Test-DevKitBenignSidecarLine -Message '[devkit-rpc][work] FAILED to initialize after 12ms: boom' | Should -BeFalse
        Test-DevKitBenignSidecarLine -Message '[devkit-rpc][mcp] response for request 9 dropped - output queue already closed' | Should -BeFalse
        Test-DevKitBenignSidecarLine -Message '[devkit-rpc] malformed request line, ignored: {' | Should -BeFalse
    }

    It "is false for empty input" {
        Test-DevKitBenignSidecarLine -Message '' | Should -BeFalse
        Test-DevKitBenignSidecarLine -Message $null | Should -BeFalse
    }
}

Describe "Test-DevKitSidecarContinuationLine" {

    It "recognizes a PowerShell stack frame" {
        Test-DevKitSidecarContinuationLine -Message 'at <ScriptBlock>, <No file>: line 20' | Should -BeTrue
        Test-DevKitSidecarContinuationLine -Message 'at Get-DevKitSettings, C:\DevKit\tools\lib\DevKit-Common.ps1: line 42' | Should -BeTrue
    }

    It "recognizes an error-record footer" {
        Test-DevKitSidecarContinuationLine -Message '    + CategoryInfo          : InvalidOperation: (:) [], RuntimeException' | Should -BeTrue
        Test-DevKitSidecarContinuationLine -Message '    + FullyQualifiedErrorId : RuntimeException' | Should -BeTrue
        Test-DevKitSidecarContinuationLine -Message '    + ~~~~~~~~~~~~' | Should -BeTrue
    }

    It "does not claim an ordinary diagnostic line" {
        Test-DevKitSidecarContinuationLine -Message '[devkit-rpc][work] FAILED to initialize after 12ms: boom' | Should -BeFalse
        Test-DevKitSidecarContinuationLine -Message 'at the end of the day it failed' | Should -BeFalse
        Test-DevKitSidecarContinuationLine -Message '' | Should -BeFalse
    }
}

Describe "ConvertFrom-DevKitAppLogText entry shape" {

    It "emits EXACTLY the keys the frontend store expects, and none of the computed ones" {
        $text = New-TestLogLine -Level 'ERROR' -Target 'devkit_lib' -Message 'rpc timed out'
        $entries = @(ConvertFrom-DevKitAppLogText -Text $text -FileName 'devkit.log.2026-08-26')
        $entries.Count | Should -Be 1
        $keys = @($entries[0].Keys)
        $keys | Should -Contain 'source'
        $keys | Should -Contain 'severity'
        $keys | Should -Contain 'timestamp'
        $keys | Should -Contain 'title'
        $keys | Should -Contain 'detail'
        $keys | Should -Contain 'origin'
        $keys | Should -Contain 'meta'
        $keys.Count | Should -Be 7
        # The store computes these; emitting them would fight it.
        $keys | Should -Not -Contain 'id'
        $keys | Should -Not -Contain 'count'
        $keys | Should -Not -Contain 'dedupeKey'
    }

    It "fills the entry from the parsed line" {
        $text = New-TestLogLine -Level 'ERROR' -Target 'devkit_lib::commands' -Message 'rpc timed out'
        $e = @(ConvertFrom-DevKitAppLogText -Text $text -FileName 'devkit.log.2026-08-26')[0]
        $e.source | Should -Be 'app'
        $e.severity | Should -Be 'error'
        $e.title | Should -Be 'rpc timed out'
        $e.detail | Should -Be 'rpc timed out'
        $e.origin | Should -Be 'devkit_lib::commands'
        $e.meta.level | Should -Be 'ERROR'
        $e.meta.file | Should -Be 'devkit.log.2026-08-26'
    }

    It "emits a timestamp JavaScript's Date can parse" {
        $text = New-TestLogLine -Timestamp '2026-08-26T00:19:50.510068Z' -Level 'WARN'
        $e = @(ConvertFrom-DevKitAppLogText -Text $text)[0]
        # Round-trip 'o' format, always UTC.
        $e.timestamp | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$'
        ([datetimeoffset]::Parse($e.timestamp)).Year | Should -Be 2026
    }
}

Describe "ConvertFrom-DevKitAppLogText filtering and folding" {

    It "keeps WARN and above and drops everything below it" {
        $text = @(
            (New-TestLogLine -Level 'INFO' -Message 'devkit starting')
            (New-TestLogLine -Level 'DEBUG' -Message 'noisy')
            (New-TestLogLine -Level 'WARN' -Message 'a warning')
            (New-TestLogLine -Level 'ERROR' -Message 'an error')
        ) -join "`n"
        $entries = @(ConvertFrom-DevKitAppLogText -Text $text)
        $entries.Count | Should -Be 2
        $entries[0].title | Should -Be 'a warning'
        $entries[1].title | Should -Be 'an error'
    }

    It "drops benign sidecar chatter but keeps a real sidecar fault" {
        $text = @(
            (New-TestLogLine -Target 'devkit_sidecar_stderr' -Message '[devkit-rpc] booting - repo root: C:\DevKit')
            (New-TestLogLine -Target 'devkit_sidecar_stderr' -Message '[devkit-rpc][work] ready after 338.2145ms')
            (New-TestLogLine -Target 'devkit_sidecar_stderr' -Message '[devkit-rpc][work] FAILED to initialize after 12ms: boom')
        ) -join "`n"
        $entries = @(ConvertFrom-DevKitAppLogText -Text $text)
        $entries.Count | Should -Be 1
        $entries[0].severity | Should -Be 'critical'
        $entries[0].title | Should -Match 'FAILED to initialize'
    }

    It "does NOT apply the sidecar allowlist to other targets" {
        # The allowlist is scoped to devkit_sidecar_stderr on purpose - an
        # identical message from anywhere else is not vouched for.
        $text = New-TestLogLine -Target 'devkit_lib' -Message '[devkit-rpc] shutdown complete'
        @(ConvertFrom-DevKitAppLogText -Text $text).Count | Should -Be 1
    }

    It "folds continuation lines into the detail but not the title" {
        $text = @(
            (New-TestLogLine -Level 'ERROR' -Message "thread 'main' panicked at src/lib.rs:42")
            '   0: devkit_lib::run'
            '   1: devkit::main'
        ) -join "`n"
        $entries = @(ConvertFrom-DevKitAppLogText -Text $text)
        $entries.Count | Should -Be 1
        $entries[0].title | Should -Be "thread 'main' panicked at src/lib.rs:42"
        $entries[0].detail | Should -Match '0: devkit_lib::run'
        $entries[0].detail | Should -Match '1: devkit::main'
    }

    It "attaches a continuation line to the record above it, even an INFO one" {
        # The fold pass keeps records of ALL levels precisely so a stack
        # trace under an INFO line is not misattributed to the last WARN.
        $text = @(
            (New-TestLogLine -Level 'WARN' -Message 'earlier warning')
            (New-TestLogLine -Level 'INFO' -Message 'unrelated info')
            '   this belongs to the INFO line'
        ) -join "`n"
        $entries = @(ConvertFrom-DevKitAppLogText -Text $text)
        $entries.Count | Should -Be 1
        $entries[0].detail | Should -Be 'earlier warning'
    }

    It "folds a sidecar stack trace into the failure above it, even though each frame is its own log entry" {
        # The sidecar writes ScriptStackTrace to stderr one line at a time,
        # so each frame arrives as a fully-formed timestamped WARN record.
        # Verified against the real devkit.log: without this fold, ONE lane
        # failure produced one useful row plus four "at <ScriptBlock>" rows.
        $text = @(
            (New-TestLogLine -Target 'devkit_sidecar_stderr' -Message '[devkit-rpc][metrics] FAILED to initialize after 88ms: An item with the same key has already been added.')
            (New-TestLogLine -Target 'devkit_sidecar_stderr' -Message 'at <ScriptBlock>, <No file>: line 20')
            (New-TestLogLine -Target 'devkit_sidecar_stderr' -Message 'at <ScriptBlock>, C:\DevKit\core\DevKit.Core.psm1: line 53')
        ) -join "`n"
        $entries = @(ConvertFrom-DevKitAppLogText -Text $text)
        $entries.Count | Should -Be 1
        $entries[0].severity | Should -Be 'critical'
        $entries[0].detail | Should -Match 'DevKit\.Core\.psm1: line 53'
    }

    It "does not fold a stack frame into a record from a different target" {
        $text = @(
            (New-TestLogLine -Target 'devkit_lib' -Message 'something failed')
            (New-TestLogLine -Target 'devkit_sidecar_stderr' -Message 'at <ScriptBlock>, <No file>: line 20')
        ) -join "`n"
        @(ConvertFrom-DevKitAppLogText -Text $text).Count | Should -Be 2
    }

    It "does not mistake an ordinary sidecar diagnostic for a stack frame" {
        $text = @(
            (New-TestLogLine -Target 'devkit_sidecar_stderr' -Message '[devkit-rpc][work] FAILED to initialize after 12ms: boom')
            (New-TestLogLine -Target 'devkit_sidecar_stderr' -Message '[devkit-rpc] malformed request line, ignored: {')
        ) -join "`n"
        @(ConvertFrom-DevKitAppLogText -Text $text).Count | Should -Be 2
    }

    It "drops orphan continuation lines at the start of a mid-entry tail read" {
        $text = @(
            '   0: devkit_lib::run   <- truncated tail begins mid-entry'
            (New-TestLogLine -Level 'ERROR' -Message 'first complete entry')
        ) -join "`n"
        $entries = @(ConvertFrom-DevKitAppLogText -Text $text)
        $entries.Count | Should -Be 1
        $entries[0].title | Should -Be 'first complete entry'
    }

    It "returns an empty array for empty or whitespace input" {
        @(ConvertFrom-DevKitAppLogText -Text '').Count | Should -Be 0
        @(ConvertFrom-DevKitAppLogText -Text "  `n  ").Count | Should -Be 0
        @(ConvertFrom-DevKitAppLogText -Text $null).Count | Should -Be 0
    }

    It "returns entries in FILE order (oldest first)" {
        $text = @(
            (New-TestLogLine -Timestamp '2026-08-26T00:00:01.000000Z' -Level 'WARN' -Message 'first')
            (New-TestLogLine -Timestamp '2026-08-26T00:00:02.000000Z' -Level 'WARN' -Message 'second')
        ) -join "`n"
        $entries = @(ConvertFrom-DevKitAppLogText -Text $text)
        $entries[0].title | Should -Be 'first'
        $entries[1].title | Should -Be 'second'
    }
}

Describe "ConvertTo-DevKitErrorTitle" {

    It "collapses whitespace and takes the first non-blank line" {
        ConvertTo-DevKitErrorTitle -Message "  the   fault  `nsecond line" | Should -Be 'the fault'
    }

    It "caps a very long line" {
        $long = 'x' * 500
        $t = ConvertTo-DevKitErrorTitle -Message $long
        $t.Length | Should -Be 163
        $t | Should -Match '\.\.\.$'
    }

    It "uses the fallback for empty input" {
        ConvertTo-DevKitErrorTitle -Message '' -Fallback 'nothing here' | Should -Be 'nothing here'
        ConvertTo-DevKitErrorTitle -Message $null -Fallback 'nothing here' | Should -Be 'nothing here'
    }
}

Describe "Get-DevKitEventSeverity" {

    It "maps Windows event levels onto the store's vocabulary" {
        Get-DevKitEventSeverity 1 | Should -Be 'critical'
        Get-DevKitEventSeverity 2 | Should -Be 'error'
        Get-DevKitEventSeverity 3 | Should -Be 'warning'
    }

    It "falls back to 'error' for LogAlways and for unparsable input" {
        Get-DevKitEventSeverity 0 | Should -Be 'error'
        Get-DevKitEventSeverity $null | Should -Be 'error'
        Get-DevKitEventSeverity 'nonsense' | Should -Be 'error'
    }
}

Describe "ConvertTo-DevKitSystemErrorEntry" {

    It "maps a Critical event onto a critical entry" {
        $e = ConvertTo-DevKitSystemErrorEntry -EventRecord (New-TestEventRecord -Level 1 -Message 'The system rebooted without cleanly shutting down.')
        $e.source | Should -Be 'system'
        $e.severity | Should -Be 'critical'
        $e.title | Should -Be 'The system rebooted without cleanly shutting down.'
        $e.origin | Should -Be 'Test-Provider'
    }

    It "maps an Error event onto an error entry and carries the identifying meta" {
        $e = ConvertTo-DevKitSystemErrorEntry -EventRecord (New-TestEventRecord -Level 2 -Id 7031 -LogName 'Application' -RecordId 991)
        $e.severity | Should -Be 'error'
        $e.meta.eventId | Should -Be 7031
        $e.meta.logName | Should -Be 'Application'
        $e.meta.recordId | Should -Be 991
        $e.meta.level | Should -Be 2
    }

    It "collapses a multi-line event message into a one-line title, keeping the whole thing in detail" {
        $msg = "The service terminated unexpectedly.`r`n`r`nIt has done this 3 time(s)."
        $e = ConvertTo-DevKitSystemErrorEntry -EventRecord (New-TestEventRecord -Message $msg)
        $e.title | Should -Be 'The service terminated unexpectedly.'
        $e.detail | Should -Be $msg
    }

    It "survives a record with no message text (unregistered provider resource)" {
        $e = ConvertTo-DevKitSystemErrorEntry -EventRecord (New-TestEventRecord -Message $null -Id 4321 -LogName 'System' -Provider 'Ghost')
        $e.title | Should -Be 'System event 4321 from Ghost'
        $e.detail | Should -Match 'no message text'
    }

    It "falls back to 'Unknown' for a record with no provider name" {
        $e = ConvertTo-DevKitSystemErrorEntry -EventRecord (New-TestEventRecord -Provider '')
        $e.origin | Should -Be 'Unknown'
    }

    It "emits a UTC ISO timestamp" {
        $e = ConvertTo-DevKitSystemErrorEntry -EventRecord (New-TestEventRecord)
        $e.timestamp | Should -Match '^2026-08-26T01:02:03'
        $e.timestamp | Should -Match 'Z$'
    }

    It "emits EXACTLY the keys the frontend store expects" {
        $keys = @((ConvertTo-DevKitSystemErrorEntry -EventRecord (New-TestEventRecord)).Keys)
        $keys.Count | Should -Be 7
        $keys | Should -Not -Contain 'dedupeKey'
    }
}

Describe "ConvertTo-DevKitErrorTimestamp" {

    It "normalizes a DateTime to the JS toISOString() shape" {
        # Not .NET's 'o' round-trip format: on a DateTimeOffset that renders
        # as "+00:00" with seven fractional digits, which falls outside the
        # ECMAScript date-time grammar `new Date(s)` is guaranteed to parse.
        $t = ConvertTo-DevKitErrorTimestamp ([datetime]::new(2026, 8, 26, 1, 2, 3, [DateTimeKind]::Utc))
        $t | Should -Be '2026-08-26T01:02:03.000Z'
    }

    It "normalizes a DateTimeOffset to UTC with a Z suffix, never +00:00" {
        $t = ConvertTo-DevKitErrorTimestamp ([datetimeoffset]::new(2026, 8, 26, 1, 2, 3, [timespan]::FromHours(-5)))
        $t | Should -Be '2026-08-26T06:02:03.000Z'
    }

    It "normalizes a tracing timestamp string to UTC" {
        ConvertTo-DevKitErrorTimestamp '2026-08-26T00:19:50.510068Z' | Should -Match '^2026-08-26T00:19:50'
    }

    It "returns unparsable input verbatim rather than dropping the entry" {
        ConvertTo-DevKitErrorTimestamp 'not-a-date' | Should -Be 'not-a-date'
    }
}

Describe "Read-DevKitLogTail" {

    It "reads a small file whole" {
        $p = Join-Path $TestDrive 'small.log'
        Set-Content -LiteralPath $p -Value "alpha`nbravo" -NoNewline
        (Read-DevKitLogTail -Path $p) | Should -Match 'alpha'
    }

    It "reads only the tail of a large file and drops the partial first line" {
        $p = Join-Path $TestDrive 'big.log'
        $lines = 1..2000 | ForEach-Object { "line-$_-" + ('p' * 80) }
        Set-Content -LiteralPath $p -Value ($lines -join "`n") -NoNewline
        $text = Read-DevKitLogTail -Path $p -MaxBytes 4096
        $text.Length | Should -BeLessThan 4096
        $text | Should -Match 'line-2000-'
        $text | Should -Not -Match 'line-1-'
        # The seek lands mid-line; that partial line must not survive as a
        # bogus "line-" prefix.
        ($text -split "`n")[0] | Should -Match '^line-\d+-p+$'
    }

    It "reads a file another process is holding open for appending" {
        # tracing_appender keeps devkit.log.<today> open in append mode for
        # the app's whole lifetime; a reader that does not share ReadWrite
        # fails outright on the ONE file that matters most.
        $p = Join-Path $TestDrive 'held.log'
        Set-Content -LiteralPath $p -Value "held content`n" -NoNewline
        $holder = [System.IO.File]::Open($p, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        try {
            (Read-DevKitLogTail -Path $p) | Should -Match 'held content'
        } finally {
            $holder.Dispose()
        }
    }

    It "throws for a file that does not exist (the caller notes it, see Get-DevKitAppErrors)" {
        { Read-DevKitLogTail -Path (Join-Path $TestDrive 'missing.log') } | Should -Throw
    }
}

Describe "Get-DevKitAppLogFiles" {

    It "returns an empty array when the directory does not exist" {
        @(Get-DevKitAppLogFiles -LogDirectory (Join-Path $TestDrive 'no-such-dir')).Count | Should -Be 0
    }

    It "returns an empty array for a null/empty directory" {
        @(Get-DevKitAppLogFiles -LogDirectory $null).Count | Should -Be 0
        @(Get-DevKitAppLogFiles -LogDirectory '').Count | Should -Be 0
    }

    It "returns devkit.log* newest first and ignores unrelated files" {
        $dir = Join-Path $TestDrive 'logs-order'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        foreach ($n in @('devkit.log.2026-08-24', 'devkit.log.2026-08-25', 'devkit.log.2026-08-26')) {
            $f = Join-Path $dir $n
            Set-Content -LiteralPath $f -Value 'x'
            # Explicit mtimes: TestDrive writes land within the same tick.
            (Get-Item -LiteralPath $f).LastWriteTimeUtc = [datetime]::Parse($n.Substring(11)).ToUniversalTime()
        }
        Set-Content -LiteralPath (Join-Path $dir 'settings.json') -Value '{}'
        $files = @(Get-DevKitAppLogFiles -LogDirectory $dir)
        $files.Count | Should -Be 3
        $files[0].Name | Should -Be 'devkit.log.2026-08-26'
        $files[2].Name | Should -Be 'devkit.log.2026-08-24'
    }
}

Describe "Get-DevKitAppErrors" {

    BeforeEach {
        $script:LogDir = Join-Path $TestDrive "applogs-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
    }

    It "returns an empty array when the log directory does not exist yet" {
        @(Get-DevKitAppErrors -LogDirectory (Join-Path $TestDrive 'never-logged')).Count | Should -Be 0
    }

    It "returns an empty array when the log files contain nothing above INFO" {
        Set-Content -LiteralPath (Join-Path $script:LogDir 'devkit.log.2026-08-26') -Value (New-TestLogLine -Level 'INFO' -Message 'devkit starting')
        @(Get-DevKitAppErrors -LogDirectory $script:LogDir).Count | Should -Be 0
    }

    It "returns entries newest first within a file" {
        $text = @(
            (New-TestLogLine -Timestamp '2026-08-26T00:00:01.000000Z' -Level 'WARN' -Message 'older')
            (New-TestLogLine -Timestamp '2026-08-26T00:00:02.000000Z' -Level 'ERROR' -Message 'newer')
        ) -join "`n"
        Set-Content -LiteralPath (Join-Path $script:LogDir 'devkit.log.2026-08-26') -Value $text
        $entries = @(Get-DevKitAppErrors -LogDirectory $script:LogDir)
        $entries.Count | Should -Be 2
        $entries[0].title | Should -Be 'newer'
        $entries[1].title | Should -Be 'older'
    }

    It "walks rotated files newest first" {
        $older = Join-Path $script:LogDir 'devkit.log.2026-08-25'
        $newer = Join-Path $script:LogDir 'devkit.log.2026-08-26'
        Set-Content -LiteralPath $older -Value (New-TestLogLine -Level 'WARN' -Message 'from yesterday')
        Set-Content -LiteralPath $newer -Value (New-TestLogLine -Level 'WARN' -Message 'from today')
        (Get-Item -LiteralPath $older).LastWriteTimeUtc = [datetime]::Parse('2026-08-25').ToUniversalTime()
        (Get-Item -LiteralPath $newer).LastWriteTimeUtc = [datetime]::Parse('2026-08-26').ToUniversalTime()
        $entries = @(Get-DevKitAppErrors -LogDirectory $script:LogDir)
        $entries[0].title | Should -Be 'from today'
        $entries[0].meta.file | Should -Be 'devkit.log.2026-08-26'
        $entries[1].title | Should -Be 'from yesterday'
    }

    It "honors -Max by keeping the NEWEST entries" {
        $text = (1..10 | ForEach-Object { New-TestLogLine -Level 'WARN' -Message "warning-$_" }) -join "`n"
        Set-Content -LiteralPath (Join-Path $script:LogDir 'devkit.log.2026-08-26') -Value $text
        $entries = @(Get-DevKitAppErrors -LogDirectory $script:LogDir -Max 3)
        $entries.Count | Should -Be 3
        $entries[0].title | Should -Be 'warning-10'
        $entries[2].title | Should -Be 'warning-8'
    }
}

Describe "Test-DevKitActiveLogFile" {

    It "treats the undated base name as active" {
        Test-DevKitActiveLogFile -Name 'devkit.log' | Should -BeTrue
    }

    It "treats today's UTC-dated file as active" {
        $now = [datetime]::new(2026, 8, 26, 12, 0, 0, [DateTimeKind]::Local)
        $utcName = "devkit.log." + $now.ToUniversalTime().ToString('yyyy-MM-dd')
        Test-DevKitActiveLogFile -Name $utcName -Now $now | Should -BeTrue
    }

    It "treats today's LOCAL-dated file as active too (the day may have already rolled in UTC)" {
        $now = [datetime]::new(2026, 8, 26, 23, 30, 0, [DateTimeKind]::Local)
        Test-DevKitActiveLogFile -Name 'devkit.log.2026-08-26' -Now $now | Should -BeTrue
    }

    It "treats an older rotated file as inactive" {
        $now = [datetime]::new(2026, 8, 26, 12, 0, 0, [DateTimeKind]::Local)
        Test-DevKitActiveLogFile -Name 'devkit.log.2026-08-01' -Now $now | Should -BeFalse
    }
}

Describe "Clear-DevKitAppLogs" {

    BeforeEach {
        $script:LogDir = Join-Path $TestDrive "clearlogs-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
    }

    It "reports zero cleared for a directory that does not exist" {
        $r = Clear-DevKitAppLogs -LogDirectory (Join-Path $TestDrive 'never-logged')
        $r.cleared | Should -Be 0
        @($r.deleted).Count | Should -Be 0
        @($r.truncated).Count | Should -Be 0
    }

    It "deletes rotated files and truncates - never deletes - the live one" {
        $todayName = 'devkit.log.' + ([datetime]::UtcNow.ToString('yyyy-MM-dd'))
        $live = Join-Path $script:LogDir $todayName
        $rotated = Join-Path $script:LogDir 'devkit.log.2026-01-01'
        Set-Content -LiteralPath $live -Value 'live content'
        Set-Content -LiteralPath $rotated -Value 'old content'

        $r = Clear-DevKitAppLogs -LogDirectory $script:LogDir
        $r.cleared | Should -Be 2
        @($r.deleted) | Should -Contain 'devkit.log.2026-01-01'
        @($r.truncated) | Should -Contain $todayName
        Test-Path -LiteralPath $rotated | Should -BeFalse
        # Deleting the live file would leave tracing_appender writing into an
        # unlinked handle until the next daily roll.
        Test-Path -LiteralPath $live | Should -BeTrue
        (Get-Item -LiteralPath $live).Length | Should -Be 0
    }

    It "truncates the live file even while a writer holds it open in append mode" {
        $todayName = 'devkit.log.' + ([datetime]::UtcNow.ToString('yyyy-MM-dd'))
        $live = Join-Path $script:LogDir $todayName
        Set-Content -LiteralPath $live -Value 'live content that should go away'
        $holder = [System.IO.File]::Open($live, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        try {
            $r = Clear-DevKitAppLogs -LogDirectory $script:LogDir
            $r.cleared | Should -Be 1
            @($r.truncated) | Should -Contain $todayName
            (Get-Item -LiteralPath $live).Length | Should -Be 0
        } finally {
            $holder.Dispose()
        }
    }

    It "reports the directory it acted on" {
        (Clear-DevKitAppLogs -LogDirectory $script:LogDir).directory | Should -Be $script:LogDir
    }
}

Describe "New-DevKitErrorNote" {

    It "produces a valid app-sourced entry flagged as a collector failure" {
        $n = New-DevKitErrorNote -Origin 'errors.system' -Title 'Could not read the Windows Event Log' -Detail 'Access is denied.'
        $n.source | Should -Be 'app'
        $n.severity | Should -Be 'warning'
        $n.origin | Should -Be 'errors.system'
        $n.meta.collectorFailure | Should -BeTrue
        @($n.Keys).Count | Should -Be 7
    }
}
