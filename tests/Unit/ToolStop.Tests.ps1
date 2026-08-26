#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pester tests for tool.stop - the RPC that cancels a running catalog tool
    (core/RpcMethods.ps1) and its lane routing (core/Invoke-DevKitRpc.ps1).
.DESCRIPTION
    Covers the parts that are pure functions of their inputs, concentrating
    on the two ways a process-tree kill can be catastrophically wrong:

      - Killing the WRONG process. Win32_Process.ParentProcessId is a number
        recorded at creation and never updated, so once Windows recycles a
        pid, unrelated long-lived processes start claiming a brand-new
        process as their parent. Since tool.stop kills whole TREES, believing
        one of those claims means killing a stranger and everything under it.
        Get-DevKitProcessDescendants' creation-time guard is the defence, and
        most of this file exercises it.
      - Killing TOO LITTLE. A tool's own children (sfc.exe, DISM.exe, docker,
        the node behind a dev server) inherit the child's stdout pipe, so
        leaving one alive means the tool lane's drain never sees EOF and the
        lane stays wedged - strictly worse than not offering a stop at all.

    Everything here is spawn-free except one deliberately paranoid test that
    points Stop-DevKitProcessTreeMember at this very test process with a
    wrong start time: the assertion is that the suite keeps running.

    Dot-sources RpcMethods.ps1 directly (it only defines functions and the
    method registry at load time) and lifts Get-DevKitRpcLaneForMethod out of
    Invoke-DevKitRpc.ps1 by AST, since dot-sourcing THAT file would boot a
    whole sidecar - six runspaces and a blocking stdin read loop.
.EXAMPLE
    Invoke-Pester -Path .\tests\Unit\ToolStop.Tests.ps1
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    # See Get-DevKitPackageManager.Tests.ps1 for why these load-once flags
    # get reset when several test files share one Pester process.
    $global:DevKitRpcMethodsLoaded = $false
    . (Join-Path $script:RepoRoot 'core\RpcMethods.ps1')

    # Lift just the routing function out of the sidecar script.
    $script:RpcScriptPath = Join-Path $script:RepoRoot 'core\Invoke-DevKitRpc.ps1'
    $tokens = $null
    $parseErrors = $null
    $rpcAst = [System.Management.Automation.Language.Parser]::ParseFile($script:RpcScriptPath, [ref]$tokens, [ref]$parseErrors)
    $laneFn = $rpcAst.Find(
        { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-DevKitRpcLaneForMethod' },
        $true)
    . ([scriptblock]::Create($laneFn.Extent.Text))

    $script:Base = [datetime]'2026-08-26T10:00:00'

    function New-ProcRow {
        param(
            [Parameter(Mandatory)][int]$ProcessId,
            [Parameter(Mandatory)][int]$ParentProcessId,
            $CreationDate = $script:Base,
            [string]$Name = 'test.exe'
        )
        return [pscustomobject]@{
            ProcessId       = $ProcessId
            ParentProcessId = $ParentProcessId
            CreationDate    = $CreationDate
            Name            = $Name
        }
    }
}

Describe "Get-DevKitProcessDescendants" {

    It "walks the whole tree, not just the immediate children" {
        # The bug this exists to prevent: Stop-Process on the child alone
        # leaves `npm run dev`'s node - and the stdout pipe it inherited -
        # very much alive.
        $rows = @(
            New-ProcRow -ProcessId 100 -ParentProcessId 10 -CreationDate $script:Base
            New-ProcRow -ProcessId 200 -ParentProcessId 100 -CreationDate $script:Base.AddSeconds(1) -Name 'npm.exe'
            New-ProcRow -ProcessId 300 -ParentProcessId 200 -CreationDate $script:Base.AddSeconds(2) -Name 'node.exe'
        )
        $found = @(Get-DevKitProcessDescendants -RootProcessId 100 -RootStartTime $script:Base -Processes $rows)
        $found.ProcessId | Should -Be @(200, 300)
        $found[1].Depth | Should -Be 2
    }

    It "returns parents before their own children so a caller can kill top-down" {
        $rows = @(
            New-ProcRow -ProcessId 200 -ParentProcessId 100 -CreationDate $script:Base.AddSeconds(1)
            New-ProcRow -ProcessId 400 -ParentProcessId 200 -CreationDate $script:Base.AddSeconds(3)
            New-ProcRow -ProcessId 300 -ParentProcessId 100 -CreationDate $script:Base.AddSeconds(2)
        )
        $found = @(Get-DevKitProcessDescendants -RootProcessId 100 -RootStartTime $script:Base -Processes $rows)
        $found.ProcessId | Should -Be @(200, 300, 400)
    }

    It "never excludes the root itself" {
        $rows = @(New-ProcRow -ProcessId 100 -ParentProcessId 100 -CreationDate $script:Base)
        @(Get-DevKitProcessDescendants -RootProcessId 100 -RootStartTime $script:Base -Processes $rows) | Should -HaveCount 0
    }

    It "ignores a process that predates its claimed parent - the pid-reuse trap" {
        # 900 is some long-lived process whose real parent died hours ago and
        # whose pid Windows then handed to our tool. Its ParentProcessId
        # still says 100, so a naive walk would kill it and its children.
        $rows = @(
            New-ProcRow -ProcessId 900 -ParentProcessId 100 -CreationDate $script:Base.AddHours(-3) -Name 'innocent.exe'
            New-ProcRow -ProcessId 901 -ParentProcessId 900 -CreationDate $script:Base.AddHours(-2) -Name 'innocent-child.exe'
            New-ProcRow -ProcessId 200 -ParentProcessId 100 -CreationDate $script:Base.AddSeconds(1) -Name 'real-child.exe'
        )
        $found = @(Get-DevKitProcessDescendants -RootProcessId 100 -RootStartTime $script:Base -Processes $rows)
        $found.ProcessId | Should -Be @(200)
    }

    It "tolerates a sub-tolerance clock wobble between parent and child timestamps" {
        $rows = @(New-ProcRow -ProcessId 200 -ParentProcessId 100 -CreationDate $script:Base.AddMilliseconds(-20))
        $found = @(Get-DevKitProcessDescendants -RootProcessId 100 -RootStartTime $script:Base -Processes $rows -ToleranceMs 250)
        $found.ProcessId | Should -Be @(200)
    }

    It "skips a process whose creation date is unknown, and everything under it" {
        # An unreadable CreationDate means a protected process. Unverifiable
        # is treated as untouchable rather than assumed innocent.
        $rows = @(
            New-ProcRow -ProcessId 200 -ParentProcessId 100 -CreationDate $null -Name 'protected.exe'
            New-ProcRow -ProcessId 300 -ParentProcessId 200 -CreationDate $script:Base.AddSeconds(2)
        )
        @(Get-DevKitProcessDescendants -RootProcessId 100 -RootStartTime $script:Base -Processes $rows) | Should -HaveCount 0
    }

    It "terminates on a parent/child cycle instead of looping forever" {
        # A stale snapshot plus pid reuse can genuinely produce "A parents B,
        # B parents A".
        $rows = @(
            New-ProcRow -ProcessId 200 -ParentProcessId 100 -CreationDate $script:Base.AddSeconds(1)
            New-ProcRow -ProcessId 300 -ParentProcessId 200 -CreationDate $script:Base.AddSeconds(2)
            New-ProcRow -ProcessId 200 -ParentProcessId 300 -CreationDate $script:Base.AddSeconds(3)
        )
        $found = @(Get-DevKitProcessDescendants -RootProcessId 100 -RootStartTime $script:Base -Processes $rows)
        $found.ProcessId | Should -Be @(200, 300)
    }

    It "drops self-parenting rows" {
        $rows = @(New-ProcRow -ProcessId 200 -ParentProcessId 200 -CreationDate $script:Base.AddSeconds(1))
        @(Get-DevKitProcessDescendants -RootProcessId 200 -RootStartTime $script:Base -Processes $rows) | Should -HaveCount 0
    }

    It "ignores processes belonging to some other tree" {
        $rows = @(
            New-ProcRow -ProcessId 700 -ParentProcessId 600 -CreationDate $script:Base.AddSeconds(1)
            New-ProcRow -ProcessId 800 -ParentProcessId 700 -CreationDate $script:Base.AddSeconds(2)
        )
        @(Get-DevKitProcessDescendants -RootProcessId 100 -RootStartTime $script:Base -Processes $rows) | Should -HaveCount 0
    }

    It "refuses pids 0 and 4 as a root - Idle and System are never a tool run" {
        # A zeroed pid would otherwise match every process whose parent has
        # exited, i.e. most of the machine.
        $rows = @(New-ProcRow -ProcessId 200 -ParentProcessId 0 -CreationDate $script:Base.AddSeconds(1))
        @(Get-DevKitProcessDescendants -RootProcessId 0 -RootStartTime $script:Base -Processes $rows) | Should -HaveCount 0
        @(Get-DevKitProcessDescendants -RootProcessId 4 -RootStartTime $script:Base -Processes $rows) | Should -HaveCount 0
    }

    It "returns nothing when the root's start time is unknown" {
        $rows = @(New-ProcRow -ProcessId 200 -ParentProcessId 100 -CreationDate $script:Base.AddSeconds(1))
        @(Get-DevKitProcessDescendants -RootProcessId 100 -RootStartTime $null -Processes $rows) | Should -HaveCount 0
    }

    It "handles an empty process table" {
        @(Get-DevKitProcessDescendants -RootProcessId 100 -RootStartTime $script:Base -Processes @()) | Should -HaveCount 0
    }

    It "stops at MaxNodes" {
        $rows = 1..40 | ForEach-Object { New-ProcRow -ProcessId (1000 + $_) -ParentProcessId 100 -CreationDate $script:Base.AddSeconds($_) }
        @(Get-DevKitProcessDescendants -RootProcessId 100 -RootStartTime $script:Base -Processes @($rows) -MaxNodes 5) | Should -HaveCount 5
    }
}

Describe "Test-DevKitProcessStartTimeMatch" {

    It "accepts the same instant and a sub-tolerance difference" {
        # Win32_Process.CreationDate and Process.StartTime derive from the
        # same kernel timestamp but round differently - measured here they
        # agree to 0.0004ms.
        Test-DevKitProcessStartTimeMatch -Expected $script:Base -Actual $script:Base | Should -BeTrue
        Test-DevKitProcessStartTimeMatch -Expected $script:Base -Actual $script:Base.AddMilliseconds(30) | Should -BeTrue
        Test-DevKitProcessStartTimeMatch -Expected $script:Base -Actual $script:Base.AddMilliseconds(-30) | Should -BeTrue
    }

    It "rejects a difference outside the tolerance - that pid is a different process now" {
        Test-DevKitProcessStartTimeMatch -Expected $script:Base -Actual $script:Base.AddSeconds(1) | Should -BeFalse
        Test-DevKitProcessStartTimeMatch -Expected $script:Base -Actual $script:Base.AddHours(-4) | Should -BeFalse
    }

    It "answers false, never true, when either timestamp is unknown" {
        Test-DevKitProcessStartTimeMatch -Expected $null -Actual $script:Base | Should -BeFalse
        Test-DevKitProcessStartTimeMatch -Expected $script:Base -Actual $null | Should -BeFalse
        Test-DevKitProcessStartTimeMatch -Expected $null -Actual $null | Should -BeFalse
    }

    It "answers false on junk rather than throwing" {
        Test-DevKitProcessStartTimeMatch -Expected 'not a date' -Actual $script:Base | Should -BeFalse
    }
}

Describe "Stop-DevKitProcessTreeMember" {

    It "reports 'gone' for a pid that cannot exist" {
        # Windows pids are multiples of 4, so int32 max is never a real one.
        Stop-DevKitProcessTreeMember -ProcessId 2147483647 -ExpectedStartTime $script:Base | Should -Be 'gone'
    }

    It "refuses to kill a live pid whose start time does not match" {
        # Aimed at the Pester process itself with a deliberately wrong
        # timestamp: the assertion is really that this suite is still running
        # on the next line.
        $verdict = Stop-DevKitProcessTreeMember -ProcessId $PID -ExpectedStartTime $script:Base.AddYears(-5)
        $verdict | Should -Be 'mismatch'
        (Get-Process -Id $PID).HasExited | Should -BeFalse
    }
}

Describe "New-DevKitToolStopResult" {

    It "returns the shape the dialog consumes" {
        $result = New-DevKitToolStopResult -RunId 'r1' -Reason 'stopped' -ProcessId 4242 -KilledProcessIds @(4242, 99)
        $result.runId | Should -Be 'r1'
        $result.stopped | Should -BeTrue
        $result.reason | Should -Be 'stopped'
        $result.processId | Should -Be 4242
        $result.killedCount | Should -Be 2
        @($result.killedProcessIds) | Should -Be @(4242, 99)
        $result.laneReleased | Should -BeTrue
        $result.message | Should -Not -BeNullOrEmpty
    }

    It "counts children as the killed pids minus the root" {
        $result = New-DevKitToolStopResult -RunId 'r1' -Reason 'stopped' -ProcessId 4242 -KilledProcessIds @(4242, 99, 100)
        $result.message | Should -BeLike '*2 child process(es)*'
    }

    It "keeps killedProcessIds an array even when a single pid was killed" {
        # The unrolling that bites $DevKitRpcArrayMethods only happens at
        # function-return boundaries; nested in the result object the array
        # survives, and the frontend's typed field depends on that.
        $result = New-DevKitToolStopResult -RunId 'r1' -Reason 'stopped' -ProcessId 4242 -KilledProcessIds @(4242)
        , $result.killedProcessIds | Should -BeOfType [array]
        $result.killedCount | Should -Be 1
    }

    It "marks only 'stopped' as stopped - the races are successes, not kills" {
        (New-DevKitToolStopResult -RunId 'r1' -Reason 'notFound').stopped | Should -BeFalse
        (New-DevKitToolStopResult -RunId 'r1' -Reason 'alreadyExited').stopped | Should -BeFalse
        (New-DevKitToolStopResult -RunId 'r1' -Reason 'failed').stopped | Should -BeFalse
    }

    It "gives every reason plain-English wording the dialog can print verbatim" {
        foreach ($reason in @('stopped', 'notFound', 'alreadyExited', 'failed')) {
            (New-DevKitToolStopResult -RunId 'r1' -Reason $reason -ProcessId 7).message | Should -Not -BeNullOrEmpty
        }
        (New-DevKitToolStopResult -RunId 'r1' -Reason 'notFound').message | Should -Not -BeLike '*rror*'
    }

    It "says so when the kill landed but the run has not reported completion" {
        $result = New-DevKitToolStopResult -RunId 'r1' -Reason 'stopped' -ProcessId 7 -KilledProcessIds @(7) -LaneReleased $false
        $result.laneReleased | Should -BeFalse
        $result.message | Should -BeLike '*not reported completion*'
    }

    It "rejects a reason outside the contract" {
        { New-DevKitToolStopResult -RunId 'r1' -Reason 'whatever' } | Should -Throw
    }
}

Describe "Test-DevKitToolRunCancelled" {

    It "is false for a run nobody asked to stop" {
        $entry = Register-DevKitToolRun -Registry $null -RunId 'r1' -Process (Get-Process -Id $PID)
        Test-DevKitToolRunCancelled -Entry $entry | Should -BeFalse
    }

    It "is true once the stop lane has marked the entry" {
        $entry = Register-DevKitToolRun -Registry $null -RunId 'r1' -Process (Get-Process -Id $PID)
        $entry['Stopped'] = $true
        Test-DevKitToolRunCancelled -Entry $entry | Should -BeTrue
    }

    It "is false, not an error, for a missing entry" {
        Test-DevKitToolRunCancelled -Entry $null | Should -BeFalse
    }
}

Describe "the tool-run registry" {

    BeforeEach {
        $script:Registry = [System.Collections.Concurrent.ConcurrentDictionary[string, object]]::new()
    }

    It "publishes a run under its runId with the identity a stop needs" {
        $me = Get-Process -Id $PID
        $entry = Register-DevKitToolRun -Registry $script:Registry -RunId 'run-1' -Process $me -Label 'system/Repair-SystemFiles.ps1'
        $script:Registry.ContainsKey('run-1') | Should -BeTrue
        $entry['ProcessId'] | Should -Be $PID
        $entry['StartTime'] | Should -Be $me.StartTime
        $entry['Label'] | Should -Be 'system/Repair-SystemFiles.ps1'
        $entry['Stopped'] | Should -BeFalse
    }

    It "hands back an entry both lanes can safely share" {
        # Synchronized, because the stop lane writes Stopped while the tool
        # lane reads it.
        $entry = Register-DevKitToolRun -Registry $script:Registry -RunId 'run-1' -Process (Get-Process -Id $PID)
        $entry.IsSynchronized | Should -BeTrue
    }

    It "replaces a reused runId rather than leaving the dead process behind" {
        $first = Register-DevKitToolRun -Registry $script:Registry -RunId 'run-1' -Process (Get-Process -Id $PID)
        $first['Stopped'] = $true
        $second = Register-DevKitToolRun -Registry $script:Registry -RunId 'run-1' -Process (Get-Process -Id $PID)
        $script:Registry['run-1'] | Should -Be $second
        $script:Registry['run-1']['Stopped'] | Should -BeFalse
    }

    It "unregisters, which is what tells a stop the tool lane is free again" {
        [void](Register-DevKitToolRun -Registry $script:Registry -RunId 'run-1' -Process (Get-Process -Id $PID))
        Unregister-DevKitToolRun -Registry $script:Registry -RunId 'run-1'
        $script:Registry.ContainsKey('run-1') | Should -BeFalse
    }

    It "tolerates a missing registry so this file stays runnable outside a lane" {
        { Register-DevKitToolRun -Registry $null -RunId 'run-1' -Process (Get-Process -Id $PID) } | Should -Not -Throw
        { Unregister-DevKitToolRun -Registry $null -RunId 'run-1' } | Should -Not -Throw
    }

    It "reports a released lane immediately once the entry is gone" {
        Wait-DevKitToolRunReleased -Registry $script:Registry -RunId 'never-ran' -TimeoutMs 200 | Should -BeTrue
    }

    It "reports an unreleased lane when the entry outlives the timeout" {
        [void](Register-DevKitToolRun -Registry $script:Registry -RunId 'run-1' -Process (Get-Process -Id $PID))
        Wait-DevKitToolRunReleased -Registry $script:Registry -RunId 'run-1' -TimeoutMs 120 | Should -BeFalse
    }
}

Describe "Stop-DevKitToolRun" {

    It "treats an unknown runId as a race, not an error" {
        # The user clicking Stop a heartbeat after the run finished must not
        # produce an error flash in the dialog.
        $registry = [System.Collections.Concurrent.ConcurrentDictionary[string, object]]::new()
        $result = Stop-DevKitToolRun -Registry $registry -RunId 'gone'
        $result.reason | Should -Be 'notFound'
        $result.stopped | Should -BeFalse
    }

    It "answers notFound rather than throwing when there is no registry at all" {
        (Stop-DevKitToolRun -Registry $null -RunId 'gone').reason | Should -Be 'notFound'
    }

    It "fails cleanly when an entry has no process attached" {
        $registry = [System.Collections.Concurrent.ConcurrentDictionary[string, object]]::new()
        $registry['run-1'] = [hashtable]::Synchronized(@{ RunId = 'run-1'; Process = $null; ProcessId = 0; Stopped = $false })
        $result = Stop-DevKitToolRun -Registry $registry -RunId 'run-1'
        $result.reason | Should -Be 'failed'
        $result.stopped | Should -BeFalse
    }

    It "marks the entry stopped before anything else, so a run ending mid-stop still reports cancelled" {
        $registry = [System.Collections.Concurrent.ConcurrentDictionary[string, object]]::new()
        $entry = [hashtable]::Synchronized(@{ RunId = 'run-1'; Process = $null; ProcessId = 0; Stopped = $false })
        $registry['run-1'] = $entry
        [void](Stop-DevKitToolRun -Registry $registry -RunId 'run-1')
        Test-DevKitToolRunCancelled -Entry $entry | Should -BeTrue
    }
}

Describe "tool.stop registration" {

    It "is NOT an array method - its result is an object" {
        Test-DevKitRpcArrayMethod -Method 'tool.stop' | Should -BeFalse
    }
}

Describe "Get-DevKitRpcLaneForMethod (lifted from Invoke-DevKitRpc.ps1)" {

    It "keeps tool.stop OFF the tool lane" {
        # The whole feature turns on this line. The tool lane is blocked
        # inside the run being cancelled, so a stop routed there would only
        # be delivered after the thing it was meant to kill had finished.
        Get-DevKitRpcLaneForMethod -Method 'tool.stop' | Should -Be 'work'
        Get-DevKitRpcLaneForMethod -Method 'tool.stop' | Should -Not -Be 'tool'
    }

    It "still routes every other tool.* method to the tool lane" {
        Get-DevKitRpcLaneForMethod -Method 'tool.run' | Should -Be 'tool'
        Get-DevKitRpcLaneForMethod -Method 'tool.somethingNew' | Should -Be 'tool'
    }

    It "leaves the other lanes exactly as they were" {
        Get-DevKitRpcLaneForMethod -Method 'metrics.system' | Should -Be 'metrics'
        Get-DevKitRpcLaneForMethod -Method 'mcp.report' | Should -Be 'mcp'
        Get-DevKitRpcLaneForMethod -Method 'errors.system' | Should -Be 'errors'
        Get-DevKitRpcLaneForMethod -Method 'git.overview' | Should -Be 'slow'
        Get-DevKitRpcLaneForMethod -Method 'github.prs' | Should -Be 'slow'
        Get-DevKitRpcLaneForMethod -Method 'settings.get' | Should -Be 'work'
    }
}
