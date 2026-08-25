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

$script:RepoRoot = $PSScriptRoot | Split-Path -Parent
$script:CoreModulePath = Join-Path $PSScriptRoot 'DevKit.Core.psm1'
$script:MethodsScriptPath = Join-Path $PSScriptRoot 'RpcMethods.ps1'
$script:ProtocolScriptPath = Join-Path $PSScriptRoot 'RpcProtocol.ps1'

. $script:ProtocolScriptPath

function Write-DevKitRpcDiag {
    param([string]$Message)
    if ($VerboseRpc) {
        [Console]::Error.WriteLine("[devkit-rpc] $Message")
    }
}

# ==================== SHARED QUEUES ====================

$script:OutQueue = [System.Collections.Concurrent.BlockingCollection[string]]::new()
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

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        $ErrorActionPreference = 'Stop'
        . $ProtocolScriptPath
        Import-Module $CoreModulePath -Force -Global
        . $MethodsScriptPath

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
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                $result = Invoke-DevKitRpcMethod -Method $request.method -Params $request.params -EmitEvent $emitEvent
                $sw.Stop()
                $line = ConvertTo-DevKitRpcLine (New-DevKitRpcSuccess -Id $request.id -Result $result -Ms $sw.Elapsed.TotalMilliseconds)
            } catch {
                $sw.Stop()
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
