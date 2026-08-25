#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Long-lived NDJSON-RPC sidecar for Northstar DevKit's Tauri app and CLI.
.DESCRIPTION
    Speaks one JSON object per line on stdin/stdout (see
    crates/devkit-host/src/protocol.rs for the Rust-side types). Spawned
    once by the Rust host and kept alive for the app's lifetime rather than
    per-call - a cold `pwsh -File` costs 300-800ms, which would make even
    a metrics poll slower than the WPF widget this replaces.

    THREADING MODEL (the part worth reading before changing this file):
    stdout in PowerShell is not thread-safe against concurrent writers, and
    a corrupted/interleaved line breaks the framing for every request after
    it. To make "only one thing ever writes a line" true by construction
    rather than by convention:

      - ONE dedicated writer runspace owns [Console]::Out. It drains a
        single BlockingCollection[string] ($script:OutQueue) and is the
        only code in the whole process that calls WriteLine/Flush.
      - Three dedicated LANE runspaces (metrics / slow / work) each own a
        persistent PowerShell runspace with DevKit.Core imported once, and
        each drains its own BlockingCollection[object] of requests,
        processing one at a time, pushing its JSON response line onto
        $script:OutQueue when done. This mirrors the old WPF widget's
        MetricsRunspace/McpRunspace/WorkRunspace split (gui/DevKit-Widget.ps1)
        so a slow `gh pr list` can never stall a metrics tick.
      - The MAIN thread just reads stdin line-by-line (blocking - that's
        fine, it's the only thing on this thread) and routes each request
        to a lane queue by method prefix ("metrics.*" -> metrics lane,
        "git.*"/"github.*"/"tool.*"/"maintenance.*" -> slow lane, everything
        else -> work lane). `ping`/`shutdown` are handled inline with no
        lane hop.

    If this proves fragile in practice, the documented fallback is to split
    the three lanes into three separate pwsh processes instead of three
    runspaces in one - simpler, more RAM, but no shared-process invariants
    to get right. Keep that in mind if this file gets hard to reason about.
#>

param(
    [switch]$VerboseRpc
)

$ErrorActionPreference = 'Stop'
# Deliberately no Set-StrictMode: the libraries this sidecar loads (DevKit.Core
# and everything it dot-sources) predate strict mode and rely on the
# `if ($global:XLoaded)` guard pattern reading an unset variable as falsy.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = [System.Text.Encoding]::UTF8

# Defense in depth against Win32 verbatim ("\\?\"-prefixed) paths: pwsh will
# RUN a script invoked via a verbatim path (so $PSScriptRoot inherits the
# prefix), but its own providers reject the prefix - Test-Path returns FALSE
# for files that exist (reproduced on pwsh 7.6.5), which killed every lane at
# init when the Tauri release build passed its canonicalized resource_dir
# here. The Rust host now strips the prefix itself (app/src-tauri/src/
# paths.rs), but normalize again here so no other/future host can reintroduce
# the same silent breakage.
$script:ScriptRoot = $PSScriptRoot
if ($script:ScriptRoot.StartsWith('\\?\UNC\')) {
    $script:ScriptRoot = '\\' + $script:ScriptRoot.Substring(8)
} elseif ($script:ScriptRoot.StartsWith('\\?\')) {
    $script:ScriptRoot = $script:ScriptRoot.Substring(4)
}

$script:RepoRoot = $script:ScriptRoot | Split-Path -Parent
$script:CoreModulePath = Join-Path $script:ScriptRoot 'DevKit.Core.psm1'
$script:MethodsScriptPath = Join-Path $script:ScriptRoot 'RpcMethods.ps1'
$script:ProtocolScriptPath = Join-Path $script:ScriptRoot 'RpcProtocol.ps1'

. $script:ProtocolScriptPath

function Write-DevKitRpcDiag {
    <#
    .SYNOPSIS
        Startup/shutdown/malformed-input diagnostics to stderr - always on
        (the -VerboseRpc switch used to gate this, but nothing ever passed
        it, so this whole trail was silently never emitted in production).
        The Rust host forwards every sidecar stderr line into its own
        tracing output, which now goes to a real log file
        (%LOCALAPPDATA%\NorthstarDevKit\logs\devkit.log) - this is the
        PowerShell-side half of that trail, cheap enough to always run.
    #>
    param([string]$Message)
    [Console]::Error.WriteLine("[devkit-rpc] $Message")
}

# ==================== SHARED QUEUES ====================

$script:OutQueue = [System.Collections.Concurrent.BlockingCollection[string]]::new()

# Shared across the three lane runspaces (passed by live reference, like the
# queues) to SERIALIZE their DevKit.Core imports. PowerShell's script/
# attribute compilation caches are process-wide statics with known
# thread-safety holes - three runspaces importing the same module chain at
# the same instant can nondeterministically die with "An item with the same
# key has already been added. Key: AllowEmptyString" (observed on a real
# install: metrics lane lost the race while work/slow booted fine). Costing
# ~2x/3x a single ~180ms import on background threads at startup is nothing;
# a lane that never comes up is everything.
$script:ImportLock = [System.Object]::new()
$script:LaneQueues = @{
    metrics = [System.Collections.Concurrent.BlockingCollection[object]]::new()
    slow    = [System.Collections.Concurrent.BlockingCollection[object]]::new()
    work    = [System.Collections.Concurrent.BlockingCollection[object]]::new()
}

# ==================== WRITER RUNSPACE ====================
# The only code in this process allowed to touch [Console]::Out.

function Start-DevKitRpcWriter {
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('OutQueue', $script:OutQueue)

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        $stdout = [Console]::Out
        foreach ($line in $OutQueue.GetConsumingEnumerable()) {
            $stdout.WriteLine($line)
            $stdout.Flush()
        }
    })
    $handle = $ps.BeginInvoke()
    return [pscustomobject]@{ PS = $ps; Runspace = $rs; Handle = $handle }
}

# ==================== LANE WORKER RUNSPACES ====================

function Start-DevKitRpcLane {
    param([Parameter(Mandatory)][string]$LaneName)

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('InQueue', $script:LaneQueues[$LaneName])
    $rs.SessionStateProxy.SetVariable('OutQueue', $script:OutQueue)
    $rs.SessionStateProxy.SetVariable('LaneName', $LaneName)
    $rs.SessionStateProxy.SetVariable('CoreModulePath', $script:CoreModulePath)
    $rs.SessionStateProxy.SetVariable('MethodsScriptPath', $script:MethodsScriptPath)
    $rs.SessionStateProxy.SetVariable('ProtocolScriptPath', $script:ProtocolScriptPath)
    $rs.SessionStateProxy.SetVariable('RepoRoot', $script:RepoRoot)
    $rs.SessionStateProxy.SetVariable('ImportLock', $script:ImportLock)

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        $ErrorActionPreference = 'Stop'
        . $ProtocolScriptPath

        # If Import-Module/dot-sourcing itself throws (a PS-version
        # incompatibility, a missing dependency, anything environment-
        # specific that doesn't reproduce on every machine), this lane's
        # runspace thread would otherwise just die here silently - nothing
        # else in this script is watching $ps.BeginInvoke()'s handle, so
        # every request later routed to this lane would sit in
        # $InQueue.GetConsumingEnumerable() forever with NOTHING consuming
        # it, hanging until each caller's own timeout with zero diagnostic
        # trail. Catch it, log it loudly (always - not gated behind
        # -VerboseRpc, this is exactly the failure mode that needs to be
        # visible by default), and keep draining the queue anyway so every
        # request gets an honest, immediate error instead of a silent hang.
        $importError = $null
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        # Hold $ImportLock (one live object shared by all three lanes) across
        # the whole import: pwsh's compilation caches are process-wide
        # statics that concurrent same-module imports can corrupt - see the
        # lock's declaration comment. Monitor over lock{} since this is a
        # plain scriptblock, and Exit in finally so an import that THROWS
        # can't leave the other two lanes deadlocked behind it.
        [System.Threading.Monitor]::Enter($ImportLock)
        try {
            Import-Module $CoreModulePath -Force -Global
            . $MethodsScriptPath
        } catch {
            $importError = $_
        } finally {
            [System.Threading.Monitor]::Exit($ImportLock)
        }
        $sw.Stop()

        if ($importError) {
            [Console]::Error.WriteLine("[devkit-rpc][$LaneName] FAILED to initialize after $($sw.Elapsed.TotalMilliseconds)ms: $($importError.Exception.Message)")
            [Console]::Error.WriteLine($importError.ScriptStackTrace)
            foreach ($request in $InQueue.GetConsumingEnumerable()) {
                $line = ConvertTo-DevKitRpcLine (New-DevKitRpcFailure -Id $request.id -Kind 'LaneInitFailed' -Message "The '$LaneName' lane failed to initialize: $($importError.Exception.Message)")
                $OutQueue.Add($line)
            }
            return
        }
        [Console]::Error.WriteLine("[devkit-rpc][$LaneName] ready after $($sw.Elapsed.TotalMilliseconds)ms")

        # Per-lane event emitter: lets a long-running method (e.g. a tool
        # run streaming stdout) push unsolicited "event" lines onto the same
        # single-writer queue without waiting for its own response.
        $emitEvent = {
            param($EventName, $RunId, [hashtable]$Extra = @{})
            $evt = [ordered]@{ event = $EventName }
            if ($RunId) { $evt.runId = $RunId }
            foreach ($key in $Extra.Keys) { $evt[$key] = $Extra[$key] }
            $OutQueue.Add((ConvertTo-DevKitRpcLine $evt))
        }.GetNewClosure()

        foreach ($request in $InQueue.GetConsumingEnumerable()) {
            $reqSw = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                $result = Invoke-DevKitRpcMethod -Method $request.method -Params $request.params -EmitEvent $emitEvent
                $reqSw.Stop()
                $line = ConvertTo-DevKitRpcLine (New-DevKitRpcSuccess -Id $request.id -Result $result -Ms $reqSw.Elapsed.TotalMilliseconds)
            } catch {
                $reqSw.Stop()
                $line = ConvertTo-DevKitRpcLine (New-DevKitRpcFailure -Id $request.id -Message $_.Exception.Message -Detail $_.ScriptStackTrace)
            }
            $OutQueue.Add($line)
        }
    })
    $handle = $ps.BeginInvoke()
    return [pscustomobject]@{ PS = $ps; Runspace = $rs; Handle = $handle; Name = $LaneName }
}

# ==================== LANE ROUTING ====================

function Get-DevKitRpcLaneForMethod {
    param([Parameter(Mandatory)][string]$Method)
    if ($Method -like 'metrics.*') { return 'metrics' }
    if ($Method -like 'git.*' -or $Method -like 'github.*' -or $Method -like 'tool.*' -or $Method -like 'maintenance.*') { return 'slow' }
    return 'work'
}

# ==================== BOOT ====================

Write-DevKitRpcDiag "booting - repo root: $script:RepoRoot"

$writer = Start-DevKitRpcWriter
$lanes = @{
    metrics = Start-DevKitRpcLane -LaneName 'metrics'
    slow    = Start-DevKitRpcLane -LaneName 'slow'
    work    = Start-DevKitRpcLane -LaneName 'work'
}

Write-DevKitRpcDiag "lanes started, entering read loop"

# ==================== MAIN READ LOOP ====================

$stdin = [Console]::In
$shuttingDown = $false

while (-not $shuttingDown) {
    $rawLine = $stdin.ReadLine()
    if ($null -eq $rawLine) {
        # EOF on stdin (parent process closed the pipe / died) - exit clean.
        Write-DevKitRpcDiag "stdin EOF, shutting down"
        break
    }
    if ([string]::IsNullOrWhiteSpace($rawLine)) { continue }

    try {
        $request = $rawLine | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-DevKitRpcDiag "malformed request line, ignored: $rawLine"
        continue
    }

    if (-not $request.id -or -not $request.method) {
        Write-DevKitRpcDiag "request missing id/method, ignored: $rawLine"
        continue
    }

    switch ($request.method) {
        'ping' {
            $script:OutQueue.Add((ConvertTo-DevKitRpcLine (New-DevKitRpcSuccess -Id $request.id -Result 'pong')))
        }
        'shutdown' {
            $script:OutQueue.Add((ConvertTo-DevKitRpcLine (New-DevKitRpcSuccess -Id $request.id -Result $true)))
            $shuttingDown = $true
        }
        default {
            $lane = Get-DevKitRpcLaneForMethod -Method $request.method
            $script:LaneQueues[$lane].Add($request)
        }
    }
}

# ==================== SHUTDOWN ====================
# Signal no-more-work on each lane, let in-flight/queued requests finish
# naturally (CompleteAdding lets GetConsumingEnumerable drain before it
# returns - no Stop() race with a request that's mid-write), THEN close
# the output queue once every lane has actually finished writing.

Write-DevKitRpcDiag "draining lanes"
foreach ($lane in $lanes.Values) { $script:LaneQueues[$lane.Name].CompleteAdding() }

$deadline = (Get-Date).AddSeconds(5)
foreach ($lane in $lanes.Values) {
    while (-not $lane.Handle.IsCompleted -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 25
    }
}

$script:OutQueue.CompleteAdding()
$writerDeadline = (Get-Date).AddSeconds(2)
while (-not $writer.Handle.IsCompleted -and (Get-Date) -lt $writerDeadline) {
    Start-Sleep -Milliseconds 25
}

foreach ($lane in $lanes.Values) {
    try { $lane.PS.Dispose() } catch {}
    try { $lane.Runspace.Close() } catch {}
}
try { $writer.PS.Dispose() } catch {}
try { $writer.Runspace.Close() } catch {}
Write-DevKitRpcDiag "shutdown complete"
exit 0
