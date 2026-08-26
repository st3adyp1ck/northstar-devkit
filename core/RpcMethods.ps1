#!/usr/bin/env pwsh
<#
.SYNOPSIS
    The RPC method table: maps a "namespace.verb" method name to a call
    into DevKit.Core (tools/lib/* + core/DevKit-WidgetCore.ps1 +
    core/DevKit-GuiCore.ps1 - all logic untouched, this file only adapts
    JSON params <-> PowerShell calls). Dot-sourced independently inside
    each lane runspace in Invoke-DevKitRpc.ps1 after DevKit.Core is
    imported there.
.NOTES
    Adding a new panel/feature almost always means adding one case here,
    not touching Rust or the lane/writer plumbing - see
    Invoke-DevKitRpc.ps1's header comment for why.
#>

if ($global:DevKitRpcMethodsLoaded) { return }
$global:DevKitRpcMethodsLoaded = $true

# Methods whose TOP-LEVEL result is an array. PowerShell unrolls arrays at
# every function boundary, so `return @(...)` from Invoke-DevKitRpcMethod
# hands the lane worker a bare object for one element and $null for zero -
# and the JSON envelope then carries {"result":{...}} or null instead of
# [...], crashing typed consumers (the CLI's Vec<LinkedProject> parse, the
# widget's .map calls) precisely on the fresh-install / first-project /
# first-note states no dev machine ever exhibits. The lane worker consults
# this set after every call and re-wraps (see Invoke-DevKitRpc.ps1) - keep
# it in sync when adding a method that returns a bare array.
$script:DevKitRpcArrayMethods = @{
    'projects.list'      = $true
    'projects.remove'    = $true
    'projects.rename'    = $true
    'projects.setPinned' = $true
    'projects.repair'    = $true
    'notes.get'          = $true
    'notes.save'         = $true
    'ondeck.get'         = $true
    'ondeck.add'         = $true
    'ondeck.remove'      = $true
    'ondeck.setStatus'   = $true
    'ondeck.clearDone'   = $true
    'process.topCpu'     = $true
    'metrics.excludedPorts' = $true
    'errors.system'      = $true
    'errors.app'         = $true
}

function Test-DevKitRpcArrayMethod {
    param([Parameter(Mandatory)][string]$Method)
    return $script:DevKitRpcArrayMethods.ContainsKey($Method)
}

function Get-DevKitRpcParam {
    <# Safe property read off a params PSCustomObject (JSON-parsed) - never throws on a missing property. #>
    param($Params, [Parameter(Mandatory)][string]$Name, $Default = $null)
    if ($null -eq $Params) { return $Default }
    $prop = $Params.PSObject.Properties[$Name]
    if ($null -eq $prop -or $null -eq $prop.Value) { return $Default }
    return $prop.Value
}

function ConvertTo-DevKitQuotedArgument {
    <#
    .SYNOPSIS
        Quotes ONE argument for a raw Win32 command line, per the C
        runtime's parsing rules (the same rules ArgumentList implements):
        backslashes are literal except when they precede a double quote,
        where N backslashes + quote must become 2N+1 backslashes + quote;
        a trailing run of N backslashes inside quotes must double to 2N.
        Needed only on Windows PowerShell 5.1, where
        ProcessStartInfo.ArgumentList (a .NET Core 2.1+ API) does not
        exist and arguments must go through the single .Arguments string.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('"')
    $backslashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\') {
            $backslashes++
        } elseif ($ch -eq '"') {
            [void]$sb.Append('\' * ($backslashes * 2 + 1))
            [void]$sb.Append('"')
            $backslashes = 0
        } else {
            if ($backslashes -gt 0) { [void]$sb.Append('\' * $backslashes); $backslashes = 0 }
            [void]$sb.Append($ch)
        }
    }
    if ($backslashes -gt 0) { [void]$sb.Append('\' * ($backslashes * 2)) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Test-DevKitScriptDeclaresParameter {
    <#
    .SYNOPSIS
        $true when a .ps1 declares a parameter of the given name in its
        top-level param() block.
    .DESCRIPTION
        Used by tool.run to decide whether appending -Force is even legal
        for a given catalog script (see the confirmed-run comment there).

        AST parse rather than Get-Command: Get-Command on a script path
        COMPILES the script (and can be tripped by #requires directives or
        a module-scope side effect), whereas Parser::ParseFile only reads
        it. A script with syntax errors still yields a usable AST here, and
        a parse that fails outright answers $false - "don't touch it" - so
        a broken script is left exactly as the caller wrote it.
    #>
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$Name
    )

    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) { return $false }
    $tokens = $null
    $parseErrors = $null
    try {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$parseErrors)
    } catch {
        return $false
    }
    if ($null -eq $ast -or $null -eq $ast.ParamBlock) { return $false }
    foreach ($parameter in $ast.ParamBlock.Parameters) {
        if ($parameter.Name.VariablePath.UserPath -ieq $Name) { return $true }
    }
    return $false
}

function Test-DevKitRpcConfirmedFlag {
    <#
    .SYNOPSIS
        Strict truthiness for tool.run's `confirmed` param.
    .DESCRIPTION
        A plain [bool] cast is wrong here, and wrong in the dangerous
        direction: PowerShell casts ANY non-empty string to $true, so a
        caller that sent "confirmed": "false" as a JSON STRING rather than a
        JSON boolean would silently acquire -Force on a destructive tool.
        Only a real boolean $true or the exact text "true" counts; anything
        else - including a missing param, a number, or junk - is $false, and
        the tool runs exactly as it does today.
    #>
    param($Value)

    if ($Value -is [bool]) { return [bool]$Value }
    if ($null -eq $Value) { return $false }
    return (([string]$Value).Trim() -ieq 'true')
}

function Add-DevKitForceArgument {
    <#
    .SYNOPSIS
        Returns $Arguments with -Force appended, if and only if the target
        script actually declares a -Force parameter and the caller has not
        already passed one.
    .DESCRIPTION
        THE BUG THIS FIXES: tool.run spawns every catalog script with
        -NonInteractive and closes its stdin immediately (it must - a tool
        blocking on stdin would hang its lane forever). But ~20 catalog
        tools gate themselves behind Confirm-DevKitDestructiveAction
        (tools/lib/DevKit-Common.ps1), which calls Read-Host unless -Force
        was passed or the confirmDestructive setting is off - and a child
        with no readable stdin cannot answer a prompt.

        Read-Host's exact failure mode there is context-dependent and both
        halves have been observed on this machine: in an isolated
        -NonInteractive child with stdin closed it throws
        PSInvalidOperationException ("PowerShell is in NonInteractive
        mode"), while inside a script's own menu loop it has been seen to
        return $null and let execution continue. Do not rely on either -
        the only safe assumption is that the answer never arrives. That is
        why the gate is Test-DevKitCanPrompt (which declines up front)
        rather than a try/catch, and why a `while ($true)` menu MUST break
        on a $null read (see tools/system/Edit-Path.ps1, which without that
        guard spun at ~1,800 lines/second and occupied the tool lane
        permanently).

        Either way Docker-Nuke, Docker-Cleanup, Repair-SystemFiles,
        Reset-WindowsUpdate, Clear-DiskJunk, Git-Cleanup, Manage-Services
        and the rest could not proceed when run from the app - immediately
        AFTER the user had already confirmed in the app's own caution
        dialog.

        Appending -Force is only correct when that confirmation genuinely
        happened, so it is opt-in per call (params.confirmed) rather than
        applied to every run: a caller that has not shown a caution dialog
        must not silently acquire nuke-without-asking semantics.

        Scripts that declare no -Force are left untouched - passing an
        undeclared parameter to `pwsh -File` is a hard parameter-binding
        error, which would turn this fix into a new breakage for the ~45
        non-destructive tools.
    #>
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [AllowEmptyCollection()][string[]]$Arguments = @()
    )

    $existing = @($Arguments | Where-Object { $_ -match '^-Force$' })
    if ($existing.Count -gt 0) { return @($Arguments) }
    if (-not (Test-DevKitScriptDeclaresParameter -ScriptPath $ScriptPath -Name 'Force')) { return @($Arguments) }
    return (@($Arguments) + '-Force')
}

# ==================== RUNNING-TOOL REGISTRY (tool.run <-> tool.stop) ====================
#
# WHY THIS EXISTS
#
# tool.run blocks its lane inside the child's stdout drain for the whole of
# a run - minutes for a Docker prune, and forever for the four catalog items
# that end in a dev server (Next-DevFresh, Vite-DevFresh, Vite-PreviewBuild,
# and Start-PackageScript when the script is 'dev'). A stop request
# therefore can NOT be answered on the tool lane, so Invoke-DevKitRpc.ps1
# routes tool.stop to the 'work' lane. That means the thread answering the
# stop is never the thread holding the child's Process object, and the two
# need a rendezvous point. This registry is it: a ConcurrentDictionary
# created once by the main script and handed to every lane runspace by live
# reference, exactly as $OutQueue and $ImportLock already are.
#
# WHY THE KEY IS runId, NOT pid
#
#   - The frontend mints the runId, and every tool.started/output/finished
#     event is stamped with it, so "stop the run this dialog is watching" is
#     expressible without the UI ever learning a pid. (onToolRun in
#     app/src/lib/ipc.ts does not even surface tool.started's pid today.)
#   - A pid is not a stable name for a run. Windows recycles pids
#     aggressively, and this stop kills whole process TREES - naming the
#     wrong pid would mean killing an unrelated process AND its children.
#
# HOW pid REUSE IS MADE IMPOSSIBLE TO GET WRONG
#
#   - The ROOT needs no check at all: the entry holds the live
#     System.Diagnostics.Process object, and an open process handle PINS its
#     pid - Windows cannot hand that number to a new process while any
#     handle to it is open. So while a run sits in this registry its
#     recorded pid denotes exactly one process, which is also what makes it
#     safe for the descendant walk to key off that pid after the root has
#     died.
#   - DESCENDANTS are known only by pid, out of a CIM snapshot, so they get
#     the explicit check: kill a candidate only if the live process at that
#     pid still reports the start time the snapshot recorded
#     (Test-DevKitProcessStartTimeMatch). Measured here, Win32_Process
#     CreationDate and Process.StartTime for the same process agree to
#     0.0004ms - the 250ms tolerance used below is pure slack, and still
#     orders of magnitude tighter than any pid-reuse window.
#
# Entries are [hashtable]::Synchronized rather than PSCustomObject because
# the stop lane writes 'Stopped' while the tool lane reads it: a synchronized
# hashtable's indexer takes a lock, PSObject member access makes no
# thread-safety promise.

function Register-DevKitToolRun {
    <#
    .SYNOPSIS
        Publishes a just-started run so tool.stop (on another lane) can find
        it. Returns the entry, which tool.run keeps to read the Stopped flag.
    .DESCRIPTION
        Uses the set-indexer rather than TryAdd deliberately: a caller that
        reuses a runId must end up with the LIVE process in the registry,
        not silently keep pointing at the previous (dead) one, which is the
        only way TryAdd could fail here.

        A $null registry is tolerated so this file stays dot-sourceable (and
        unit-testable) outside a lane runspace - runs simply become
        un-stoppable rather than un-runnable.
    #>
    param(
        $Registry,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)]$Process,
        [string]$Label = ''
    )

    $startTime = $null
    # A process that exited between Start() and here makes StartTime throw.
    try { $startTime = $Process.StartTime } catch { }

    $entry = [hashtable]::Synchronized(@{
        RunId           = $RunId
        Process         = $Process
        ProcessId       = [int]$Process.Id
        StartTime       = $startTime
        Label           = $Label
        StartedAt       = [datetime]::UtcNow
        Stopped         = $false
        StopRequestedAt = $null
    })

    if ($null -ne $Registry) { $Registry[$RunId] = $entry }
    return $entry
}

function Unregister-DevKitToolRun {
    <#
    .SYNOPSIS
        Removes a finished run. MUST run in tool.run's finally: while an
        entry is present the app believes the run is alive and stoppable,
        and the Process handle it holds keeps that pid pinned.
    #>
    param($Registry, [Parameter(Mandatory)][string]$RunId)
    if ($null -eq $Registry) { return }
    $removed = $null
    try { [void]$Registry.TryRemove($RunId, [ref]$removed) } catch { }
}

function Test-DevKitToolRunCancelled {
    <# $true when tool.stop marked this entry before the run ended - the difference between "cancelled" and "failed" in the UI. #>
    param($Entry)
    if ($null -eq $Entry) { return $false }
    try { return [bool]$Entry['Stopped'] } catch { return $false }
}

function Test-DevKitProcessStartTimeMatch {
    <#
    .SYNOPSIS
        Same-process identity check: two timestamps for one pid describe the
        same process only if they agree within $ToleranceMs.
    .DESCRIPTION
        The tolerance exists because the two timestamps come from different
        APIs - Win32_Process.CreationDate and Process.StartTime - which both
        derive from the same kernel KERNEL_USER_TIMES.CreateTime but round
        differently.

        An unknown timestamp on either side answers $false, never $true: an
        unverifiable process must never be killed. That is deliberately the
        behaviour for protected processes, whose StartTime cannot be read.
    #>
    param($Expected, $Actual, [double]$ToleranceMs = 250)
    if ($null -eq $Expected -or $null -eq $Actual) { return $false }
    try {
        $delta = [math]::Abs((([datetime]$Actual) - ([datetime]$Expected)).TotalMilliseconds)
    } catch {
        return $false
    }
    return ($delta -le $ToleranceMs)
}

function Get-DevKitProcessSnapshot {
    <#
    .SYNOPSIS
        One CIM read of every process's identity and parent link, flattened
        into plain objects so Get-DevKitProcessDescendants stays a pure
        function of its input (and unit-testable without spawning anything).
    .DESCRIPTION
        CIM rather than Get-Process because Win32_Process is the only
        portable source of ParentProcessId: PowerShell 7 bolts a .Parent
        property onto System.Diagnostics.Process, Windows PowerShell 5.1 -
        which this sidecar still supports, see tool.run's ArgumentList
        branch - does not.

        ParentProcessId is RECORDED at creation, not a live link: it keeps
        naming the parent's pid after the parent dies. That is exactly what
        lets tool.stop sweep up orphans a tool left behind, and also why the
        creation-time guard in the walk below is mandatory rather than
        belt-and-braces.

        Returns @() instead of throwing when WMI is unavailable: a stop that
        can still kill the root beats a stop that errors out.
    #>
    try {
        $rows = @(Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId, CreationDate, Name -ErrorAction Stop)
    } catch {
        return @()
    }
    return @($rows | ForEach-Object {
        [pscustomobject]@{
            ProcessId       = [int]$_.ProcessId
            ParentProcessId = [int]$_.ParentProcessId
            CreationDate    = $_.CreationDate
            Name            = [string]$_.Name
        }
    })
}

function Get-DevKitProcessDescendants {
    <#
    .SYNOPSIS
        Every live descendant of $RootProcessId in a process snapshot,
        breadth-first (parents before their own children), root excluded.
    .DESCRIPTION
        Pure - it reads only $Processes - so the pid-reuse and cycle rules
        below are unit-testable against synthetic tables.

        THE RULE THAT MATTERS: a candidate counts as a child only if it was
        created at or after its claimed parent. ParentProcessId is a stale
        recorded number, so a long-lived process whose own parent's pid was
        later recycled onto our tool WILL claim our tool as its parent -
        killing it would mean killing a stranger and everything under it.
        Its creation date gives it away: a real child cannot predate its
        parent.

        A candidate whose CreationDate is unknown is skipped entirely, and
        so therefore is anything below it: unverifiable means untouchable.

        $MaxNodes caps a pathological table; the queue plus the visited set
        already make cycles terminate (A parents B, B parents A - which pid
        reuse can genuinely produce in a stale snapshot).
    #>
    param(
        [Parameter(Mandatory)][int]$RootProcessId,
        [Parameter(Mandatory)][AllowNull()]$RootStartTime,
        [AllowEmptyCollection()][object[]]$Processes = @(),
        [double]$ToleranceMs = 250,
        [int]$MaxNodes = 512
    )

    # pids 0 (Idle) and 4 (System) can never be a tool run, and a bogus 0
    # root would otherwise match every process whose parent has exited.
    if ($RootProcessId -le 4) { return @() }
    if ($null -eq $RootStartTime) { return @() }

    $byParent = @{}
    foreach ($row in $Processes) {
        if ($null -eq $row) { continue }
        $childId = 0
        $parentId = 0
        try {
            $childId = [int]$row.ProcessId
            $parentId = [int]$row.ParentProcessId
        } catch {
            continue
        }
        if ($childId -le 4) { continue }
        if ($childId -eq $parentId) { continue }   # corrupt self-parenting row; would loop
        if (-not $byParent.ContainsKey($parentId)) { $byParent[$parentId] = [System.Collections.Generic.List[object]]::new() }
        $byParent[$parentId].Add($row)
    }

    $found = [System.Collections.Generic.List[object]]::new()
    $seen = @{ $RootProcessId = $true }
    $queue = [System.Collections.Generic.Queue[object]]::new()
    $queue.Enqueue([pscustomobject]@{ Id = $RootProcessId; StartTime = [datetime]$RootStartTime; Depth = 0 })

    while ($queue.Count -gt 0 -and $found.Count -lt $MaxNodes) {
        $node = $queue.Dequeue()
        if (-not $byParent.ContainsKey($node.Id)) { continue }
        foreach ($row in $byParent[$node.Id]) {
            $childId = [int]$row.ProcessId
            if ($seen.ContainsKey($childId)) { continue }
            if ($null -eq $row.CreationDate) { continue }
            $childStart = $null
            try { $childStart = [datetime]$row.CreationDate } catch { continue }
            if ($childStart -lt $node.StartTime.AddMilliseconds(-$ToleranceMs)) { continue }
            $seen[$childId] = $true
            $found.Add([pscustomobject]@{
                ProcessId       = $childId
                ParentProcessId = [int]$row.ParentProcessId
                StartTime       = $childStart
                Name            = [string]$row.Name
                Depth           = $node.Depth + 1
            })
            $queue.Enqueue([pscustomobject]@{ Id = $childId; StartTime = $childStart; Depth = $node.Depth + 1 })
            if ($found.Count -ge $MaxNodes) { break }
        }
    }

    return @($found.ToArray())
}

function Stop-DevKitProcessTreeMember {
    <#
    .SYNOPSIS
        Kills one descendant pid, but only after re-proving its identity.
        Returns 'killed', 'gone', 'mismatch' or 'denied'.
    .DESCRIPTION
        GetProcessById is what makes this safe rather than merely careful:
        it opens a HANDLE, which pins the pid for as long as it is held, so
        the start-time check below and the Kill that follows it are talking
        about the same process by construction. Stop-Process -Id would
        reopen the pid for the kill and reintroduce exactly the race the
        check exists to close.

        'mismatch' means the pid was recycled between the snapshot and now.
        The right answer then is to walk away, not to kill.
    #>
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        $ExpectedStartTime,
        [double]$ToleranceMs = 250
    )

    $proc = $null
    try {
        $proc = [System.Diagnostics.Process]::GetProcessById($ProcessId)
    } catch {
        return 'gone'
    }

    try {
        $actual = $null
        try { $actual = $proc.StartTime } catch { return 'denied' }
        if (-not (Test-DevKitProcessStartTimeMatch -Expected $ExpectedStartTime -Actual $actual -ToleranceMs $ToleranceMs)) {
            return 'mismatch'
        }
        try {
            $proc.Kill()
        } catch {
            # Kill throws once the process has exited on its own, which is a
            # success as far as the caller is concerned.
            $exited = $false
            try { $exited = $proc.HasExited } catch { $exited = $true }
            if ($exited) { return 'gone' }
            return 'denied'
        }
        return 'killed'
    } finally {
        try { $proc.Dispose() } catch { }
    }
}

function New-DevKitToolStopResult {
    <#
    .SYNOPSIS
        The one place tool.stop's response shape and its user-facing wording
        are defined.
    .DESCRIPTION
        'notFound' and 'alreadyExited' are NORMAL outcomes, not errors: a run
        finishing between the user reading the dialog and clicking Stop is a
        race the UI has to render without an error flash, so this returns a
        successful result carrying an explanatory message rather than
        throwing.

        laneReleased answers the question that actually matters after a kill:
        did tool.run's drain unblock and report a terminal result, so the
        single tool lane is usable again? $false means the kill landed but
        something is still holding the child's stdout pipe.

        Deliberately NOT registered in $DevKitRpcArrayMethods - the
        top-level result is an object.
    #>
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][ValidateSet('stopped', 'notFound', 'alreadyExited', 'failed')][string]$Reason,
        [int]$ProcessId = 0,
        [AllowEmptyCollection()][int[]]$KilledProcessIds = @(),
        [bool]$LaneReleased = $true,
        [string]$Message = ''
    )

    $killed = @($KilledProcessIds)
    if ([string]::IsNullOrWhiteSpace($Message)) {
        switch ($Reason) {
            'stopped' {
                $children = [math]::Max(0, $killed.Count - 1)
                $Message = "Cancelled - stopped PID $ProcessId and $children child process(es)."
                if (-not $LaneReleased) {
                    $Message = "$Message The run has not reported completion yet - something is still holding its output pipe."
                }
            }
            'alreadyExited' { $Message = 'That run had already finished - nothing left to stop.' }
            'notFound' { $Message = 'That run is no longer active - it finished on its own.' }
            'failed' { $Message = "Could not stop PID $ProcessId." }
        }
    }

    return [ordered]@{
        runId            = $RunId
        stopped          = ($Reason -eq 'stopped')
        reason           = $Reason
        processId        = $ProcessId
        killedProcessIds = $killed
        killedCount      = $killed.Count
        laneReleased     = $LaneReleased
        message          = $Message
    }
}

function Wait-DevKitToolRunReleased {
    <#
    .SYNOPSIS
        Waits (briefly) for tool.run's finally to drop the registry entry -
        that is, for the tool lane to have genuinely become free again.
    .DESCRIPTION
        This is the only observation the stop lane can make of the tool
        lane's progress, and it is the difference between honestly reporting
        "the run was cancelled" and reporting "the process is dead but the
        run is still wedged". Bounded, because it runs on the shared 'work'
        lane.
    #>
    param($Registry, [Parameter(Mandatory)][string]$RunId, [int]$TimeoutMs = 1500)
    if ($null -eq $Registry) { return $true }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if (-not $Registry.ContainsKey($RunId)) { return $true }
        Start-Sleep -Milliseconds 40
    }
    return (-not $Registry.ContainsKey($RunId))
}

function Stop-DevKitToolRun {
    <#
    .SYNOPSIS
        tool.stop's implementation: cancel the run named by $RunId by killing
        its whole process tree.
    .DESCRIPTION
        KILLING THE TREE IS THE POINT, not a refinement. There is no job
        object anywhere in this sidecar, so killing the child alone leaves
        everything the tool started still running - sfc.exe, DISM.exe, the
        docker CLI, and (the case that motivated all of this) the node
        process behind an npm dev script. Worse, a surviving grandchild
        inherited the child's stdout pipe, so the tool lane's drain never
        sees EOF and the lane stays wedged even though the child is dead.

        ORDER: mark, kill the root, then sweep. The Stopped flag is set
        BEFORE anything dies so tool.run's finally reports "cancelled" even
        if the run happened to end on its own in the same instant. The root
        goes first so it cannot spawn anything new while the sweep runs, and
        the sweep can still find its children afterwards because
        ParentProcessId survives the parent (see Get-DevKitProcessSnapshot).

        TWO SWEEPS: the second catches anything spawned between the first
        snapshot and its kills. Both are safe to key off the root pid even
        though the root is dead by then, because this function holds the
        root's Process handle throughout - so that pid cannot have been
        recycled onto a stranger whose children we would then hunt.

        A root that has ALREADY exited still gets the sweep rather than an
        early return: root-dead-but-orphans-alive is precisely the state in
        which the tool lane is wedged and the user is asking for help.
    #>
    param(
        $Registry,
        [Parameter(Mandatory)][string]$RunId,
        [int]$ExitWaitMs = 2000,
        [int]$ReleaseWaitMs = 1500,
        [double]$ToleranceMs = 250
    )

    if ($null -eq $Registry) { return (New-DevKitToolStopResult -RunId $RunId -Reason 'notFound') }

    $entry = $null
    $found = $false
    try { $found = $Registry.TryGetValue($RunId, [ref]$entry) } catch { $found = $false }
    if (-not $found -or $null -eq $entry) {
        return (New-DevKitToolStopResult -RunId $RunId -Reason 'notFound')
    }

    $entry['Stopped'] = $true
    $entry['StopRequestedAt'] = [datetime]::UtcNow

    $proc = $entry['Process']
    $rootPid = [int]$entry['ProcessId']
    if ($null -eq $proc -or $rootPid -le 4) {
        return (New-DevKitToolStopResult -RunId $RunId -Reason 'failed' -ProcessId $rootPid -Message 'That run has no process attached.')
    }

    $rootStart = $entry['StartTime']
    try { $rootStart = $proc.StartTime } catch { }

    $alreadyExited = $true
    try { $alreadyExited = $proc.HasExited } catch { $alreadyExited = $true }

    $killed = [System.Collections.Generic.List[int]]::new()
    if (-not $alreadyExited) {
        try {
            $proc.Kill()
            $killed.Add($rootPid)
        } catch {
            $stillAlive = $false
            try { $stillAlive = -not $proc.HasExited } catch { $stillAlive = $false }
            if ($stillAlive) {
                return (New-DevKitToolStopResult -RunId $RunId -Reason 'failed' -ProcessId $rootPid -Message "Could not stop PID ${rootPid}: $($_.Exception.Message)")
            }
        }
        try { [void]$proc.WaitForExit($ExitWaitMs) } catch { }
    }

    for ($pass = 1; $pass -le 2; $pass++) {
        $descendants = @(Get-DevKitProcessDescendants -RootProcessId $rootPid -RootStartTime $rootStart -Processes (Get-DevKitProcessSnapshot) -ToleranceMs $ToleranceMs)
        if ($descendants.Count -eq 0) { break }
        foreach ($descendant in $descendants) {
            $status = Stop-DevKitProcessTreeMember -ProcessId $descendant.ProcessId -ExpectedStartTime $descendant.StartTime -ToleranceMs $ToleranceMs
            if ($status -eq 'killed') { $killed.Add([int]$descendant.ProcessId) }
        }
        if ($pass -lt 2) { Start-Sleep -Milliseconds 120 }
    }

    if ($alreadyExited -and $killed.Count -eq 0) {
        return (New-DevKitToolStopResult -RunId $RunId -Reason 'alreadyExited' -ProcessId $rootPid)
    }

    $released = Wait-DevKitToolRunReleased -Registry $Registry -RunId $RunId -TimeoutMs $ReleaseWaitMs
    return (New-DevKitToolStopResult -RunId $RunId -Reason 'stopped' -ProcessId $rootPid -KilledProcessIds @($killed.ToArray()) -LaneReleased $released)
}

function Get-DevKitCatalogPayload {
    <#
    .SYNOPSIS
        Flattens the manifest-driven tool catalog (Get-DevKitGuiCatalog) plus
        a computed `Caution` flag (every manifest Help string that documents
        a destructive action prefixes it "Safety note:" - see AGENTS.md's
        Code Style Guidelines) into the shape the frontend renders directly.
    #>
    param([Parameter(Mandatory)][string]$RootPath)

    $groups = @(Get-DevKitGuiCatalog -RootPath $RootPath)
    $modules = @()
    foreach ($group in $groups) {
        foreach ($module in @($group.Modules)) {
            $items = @()
            foreach ($item in @($module.Items)) {
                $help = [string]$item.Help
                $items += [ordered]@{
                    key             = [string]$item.Key
                    label           = [string]$item.Label
                    script          = [string]$item.Script
                    help            = $help
                    caution         = ($help -match 'Safety note:')
                    requiresProject = [bool]$item.RequiresProject
                    projectArgName  = if ($item.ProjectArgName) { [string]$item.ProjectArgName } else { $null }
                    requiresFile    = $item.RequiresFile
                    prompts         = $item.Prompts
                    staticArgs      = $item.StaticArgs
                }
            }
            $modules += [ordered]@{
                group       = [string]$group.Group
                folder      = [string]$module.Folder
                name        = [string]$module.Name
                description = [string]$module.Description
                items       = $items
            }
        }
    }
    return [ordered]@{ modules = $modules }
}

function Invoke-DevKitRpcMethod {
    param(
        [Parameter(Mandatory)][string]$Method,
        $Params,
        [Parameter(Mandatory)][scriptblock]$EmitEvent
    )

    switch ($Method) {
        # ---------- catalog / settings ----------
        'catalog.get' {
            return Get-DevKitCatalogPayload -RootPath $RepoRoot
        }
        'settings.get' {
            return Get-DevKitSettings
        }
        'settings.set' {
            $settings = Get-DevKitRpcParam $Params 'settings'
            Set-DevKitSettings -Settings $settings
            return (Get-DevKitSettings)
        }

        # ---------- metrics (polled by the widget gauges) ----------
        'metrics.system' {
            return Get-DevKitSystemMetrics
        }
        'metrics.node' {
            return Get-DevKitNodeSnapshot
        }
        'metrics.junk' {
            return Get-DevKitSystemJunk
        }
        'metrics.excludedPorts' {
            return Get-DevKitExcludedPortRanges
        }
        'metrics.gpuProcesses' {
            $count = [int](Get-DevKitRpcParam $Params 'count' 15)
            return Get-DevKitGpuProcessUsage -Count $count
        }

        # ---------- process management (gauge click-through) ----------
        'process.topCpu' {
            $count = [int](Get-DevKitRpcParam $Params 'count' 15)
            return Get-DevKitTopCpuProcesses -Count $count
        }
        'process.topMemory' {
            $count = [int](Get-DevKitRpcParam $Params 'count' 15)
            return Get-DevKitTopMemoryProcesses -Count $count
        }
        'process.kill' {
            $pid_ = [int](Get-DevKitRpcParam $Params 'pid')
            return Stop-DevKitProcessById -ProcessId $pid_
        }
        'process.freeMemory' {
            return Invoke-DevKitFreeMemory
        }
        'junk.clear' {
            return Clear-DevKitSystemJunk
        }

        # ---------- git ----------
        'git.overview' {
            $path = [string](Get-DevKitRpcParam $Params 'path' '')
            $includeGraph = [bool](Get-DevKitRpcParam $Params 'includeGraph' $true)
            return Get-DevKitRepoOverview -Path $path -IncludeGraph $includeGraph
        }
        'git.commitDetails' {
            $path = [string](Get-DevKitRpcParam $Params 'path' '')
            $hash = [string](Get-DevKitRpcParam $Params 'hash' '')
            return Get-DevKitCommitDetails -Path $path -Hash $hash
        }
        'git.action' {
            $path = [string](Get-DevKitRpcParam $Params 'path' '')
            $action = [string](Get-DevKitRpcParam $Params 'action' '')
            return Invoke-DevKitGitAction -Path $path -Action $action
        }

        # ---------- github (via gh CLI) ----------
        'github.prs' {
            $path = [string](Get-DevKitRpcParam $Params 'path' '')
            return Get-DevKitGitHubPullRequests -Path $path
        }
        'github.issues' {
            $path = [string](Get-DevKitRpcParam $Params 'path' '')
            return Get-DevKitGitHubIssues -Path $path
        }

        # ---------- MCP status ----------
        'mcp.report' {
            $projectPath = [string](Get-DevKitRpcParam $Params 'projectPath' '')
            return Get-DevKitMcpWidgetReport -ProjectPath $projectPath
        }

        # ---------- notes ----------
        'notes.get' {
            $projectPath = [string](Get-DevKitRpcParam $Params 'projectPath' '')
            return @(Get-DevKitProjectNotes -ProjectPath $projectPath)
        }
        'notes.save' {
            $projectPath = [string](Get-DevKitRpcParam $Params 'projectPath' '')
            $notes = @(Get-DevKitRpcParam $Params 'notes' @())
            Save-DevKitProjectNotes -ProjectPath $projectPath -Notes $notes
            return @(Get-DevKitProjectNotes -ProjectPath $projectPath)
        }

        # ---------- on-deck ----------
        'ondeck.get' {
            $projectPath = [string](Get-DevKitRpcParam $Params 'projectPath' '')
            return @(Get-DevKitProjectOnDeck -ProjectPath $projectPath)
        }
        'ondeck.add' {
            $projectPath = [string](Get-DevKitRpcParam $Params 'projectPath' '')
            $text = [string](Get-DevKitRpcParam $Params 'text' '')
            $items = @(Get-DevKitProjectOnDeck -ProjectPath $projectPath)
            $items = @(Add-DevKitOnDeckItem -Items $items -Text $text)
            Save-DevKitProjectOnDeck -ProjectPath $projectPath -Items $items
            return $items
        }
        'ondeck.remove' {
            $projectPath = [string](Get-DevKitRpcParam $Params 'projectPath' '')
            $id = [string](Get-DevKitRpcParam $Params 'id' '')
            $items = @(Get-DevKitProjectOnDeck -ProjectPath $projectPath)
            $items = @(Remove-DevKitOnDeckItem -Items $items -Id $id)
            Save-DevKitProjectOnDeck -ProjectPath $projectPath -Items $items
            return $items
        }
        'ondeck.setStatus' {
            $projectPath = [string](Get-DevKitRpcParam $Params 'projectPath' '')
            $id = [string](Get-DevKitRpcParam $Params 'id' '')
            $status = [string](Get-DevKitRpcParam $Params 'status' '')
            $items = @(Get-DevKitProjectOnDeck -ProjectPath $projectPath)
            $items = @(Set-DevKitOnDeckItemStatus -Items $items -Id $id -Status $status)
            Save-DevKitProjectOnDeck -ProjectPath $projectPath -Items $items
            return $items
        }
        'ondeck.clearDone' {
            $projectPath = [string](Get-DevKitRpcParam $Params 'projectPath' '')
            $items = @(Get-DevKitProjectOnDeck -ProjectPath $projectPath)
            $items = @(Clear-DevKitOnDeckDone -Items $items)
            Save-DevKitProjectOnDeck -ProjectPath $projectPath -Items $items
            return $items
        }

        # ---------- env drift ----------
        'env.drift' {
            $path = [string](Get-DevKitRpcParam $Params 'path' '')
            return Get-DevKitEnvDrift -Path $path
        }

        # ---------- error center (core/DevKit-Errors.ps1) ----------
        # Routed to the SLOW lane (Invoke-DevKitRpc.ps1's
        # Get-DevKitRpcLaneForMethod): a Get-WinEvent query across System +
        # Application takes seconds on a busy machine and must never sit in
        # front of a settings save, a process kill, or a note write.
        'errors.system' {
            $hours = [int](Get-DevKitRpcParam $Params 'hours' 24)
            $max = [int](Get-DevKitRpcParam $Params 'max' 100)
            return @(Get-DevKitSystemErrors -Hours $hours -Max $max)
        }
        'errors.app' {
            $max = [int](Get-DevKitRpcParam $Params 'max' 200)
            return @(Get-DevKitAppErrors -Max $max)
        }
        'errors.clearAppLogs' {
            return Clear-DevKitAppLogs
        }

        # ---------- files flyout ----------
        'files.children' {
            $path = [string](Get-DevKitRpcParam $Params 'path' '')
            return Get-DevKitDirChildren -Path $path
        }

        # ---------- linked projects ----------
        'projects.list' {
            return @(Get-DevKitLinkedProjects)
        }
        'projects.add' {
            $path = [string](Get-DevKitRpcParam $Params 'path' '')
            $name = Get-DevKitRpcParam $Params 'name' $null
            return Add-DevKitLinkedProject -Path $path -Name $name
        }
        'projects.remove' {
            $id = [string](Get-DevKitRpcParam $Params 'id' '')
            Remove-DevKitLinkedProject -Id $id
            return @(Get-DevKitLinkedProjects)
        }
        'projects.rename' {
            $id = [string](Get-DevKitRpcParam $Params 'id' '')
            $name = [string](Get-DevKitRpcParam $Params 'name' '')
            Rename-DevKitLinkedProject -Id $id -NewName $name
            return @(Get-DevKitLinkedProjects)
        }
        'projects.setPinned' {
            $id = [string](Get-DevKitRpcParam $Params 'id' '')
            $pinned = [bool](Get-DevKitRpcParam $Params 'pinned' $false)
            Set-DevKitProjectPinned -Id $id -Pinned $pinned
            return @(Get-DevKitLinkedProjects)
        }
        'projects.repair' {
            $id = [string](Get-DevKitRpcParam $Params 'id' '')
            $newPath = [string](Get-DevKitRpcParam $Params 'newPath' '')
            Repair-DevKitLinkedProject -Id $id -NewPath $newPath
            return @(Get-DevKitLinkedProjects)
        }
        'projects.getActive' {
            return Get-DevKitActiveProject
        }
        'projects.setActive' {
            $id = [string](Get-DevKitRpcParam $Params 'id' '')
            Set-DevKitActiveProject -Id $id
            return Get-DevKitActiveProject
        }
        'projects.clearActive' {
            Clear-DevKitActiveProject
            return $null
        }

        # ---------- tool execution (Control Center "Run") ----------
        'tool.run' {
            $folder = [string](Get-DevKitRpcParam $Params 'folder' '')
            $script = [string](Get-DevKitRpcParam $Params 'script' '')
            $toolArgs = @(Get-DevKitRpcParam $Params 'args' @())
            $runId = [string](Get-DevKitRpcParam $Params 'runId' ([guid]::NewGuid().ToString('N')))
            # params.confirmed: "the user already approved this in the app's
            # caution dialog". Defaults to $false - see Add-DevKitForceArgument
            # for why this is opt-in and what it fixes.
            $confirmed = Test-DevKitRpcConfirmedFlag (Get-DevKitRpcParam $Params 'confirmed' $false)

            $scriptPath = Join-Path (Join-Path $RepoRoot 'tools') (Join-Path $folder $script)
            if (-not (Test-Path -LiteralPath $scriptPath)) {
                throw "Tool script not found: $scriptPath"
            }

            $toolArgs = @($toolArgs | ForEach-Object { [string]$_ })
            if ($confirmed) {
                $toolArgs = @(Add-DevKitForceArgument -ScriptPath $scriptPath -Arguments $toolArgs)
            }

            $pwshExe = (Get-Process -Id $PID).Path
            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName = $pwshExe
            $allArgs = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath) + $toolArgs
            # ProcessStartInfo.ArgumentList is .NET Core 2.1+ only - on a
            # machine with no pwsh 7 the sidecar runs under Windows
            # PowerShell 5.1 (.NET Framework), where the property doesn't
            # exist and .Add() dies with a null-method error, silently
            # breaking every tool run. Branch: use ArgumentList when
            # available (it quotes correctly for us), else build the single
            # .Arguments string with the same C-runtime quoting rules via
            # ConvertTo-DevKitQuotedArgument.
            if ($null -ne $psi.PSObject.Properties['ArgumentList'] -and $null -ne $psi.ArgumentList) {
                foreach ($a in $allArgs) { [void]$psi.ArgumentList.Add($a) }
            } else {
                $psi.Arguments = ($allArgs | ForEach-Object { ConvertTo-DevKitQuotedArgument -Value $_ }) -join ' '
            }
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.RedirectStandardInput = $true
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true

            $proc = [System.Diagnostics.Process]::new()
            $proc.StartInfo = $psi
            [void]$proc.Start()
            $proc.StandardInput.Close()  # non-interactive: never let a tool block waiting on stdin

            # Published BEFORE tool.started goes out, so a stop racing the
            # very first event still finds the run. $RunRegistry is the live
            # ConcurrentDictionary Invoke-DevKitRpc.ps1 hands to every lane
            # runspace (see the registry section above); it is $null only
            # when this file is dot-sourced outside a lane, e.g. in Pester.
            $runEntry = Register-DevKitToolRun -Registry $RunRegistry -RunId $runId -Process $proc -Label "$folder/$script"

            & $EmitEvent 'tool.started' $runId @{ pid = $proc.Id }

            $exitCode = -1
            $cancelled = $false
            try {
                # Drain stderr concurrently via an async Task so a chatty stderr
                # stream can never fill its pipe buffer and deadlock the child
                # while we're synchronously draining stdout below.
                $stderrTask = $proc.StandardError.ReadToEndAsync()

                # This is the read that blocks the tool lane for the whole
                # run, and the reason tool.stop cannot be answered here. It
                # unblocks on EOF, which arrives only once EVERY process
                # holding the child's stdout write handle is gone - hence
                # Stop-DevKitToolRun killing the tree rather than the child.
                while (-not $proc.StandardOutput.EndOfStream) {
                    $outLine = $proc.StandardOutput.ReadLine()
                    if ($null -ne $outLine) {
                        & $EmitEvent 'tool.output' $runId @{ stream = 'stdout'; line = $outLine }
                    }
                }
                $proc.WaitForExit()
                $stderrText = $stderrTask.GetAwaiter().GetResult()
                if ($stderrText) {
                    foreach ($errLine in ($stderrText -split "`r?`n")) {
                        if ($errLine) { & $EmitEvent 'tool.output' $runId @{ stream = 'stderr'; line = $errLine } }
                    }
                }
                $exitCode = $proc.ExitCode
            } catch {
                # A tree kill landing mid-read can surface as a broken-pipe
                # IOException instead of a clean EOF. Letting that escape to
                # the lane worker would return an RPC failure and never emit
                # tool.finished, leaving every watching dialog spinning
                # forever - so absorb it and still report a terminal result.
                & $EmitEvent 'tool.output' $runId @{ stream = 'stderr'; line = "Run stream ended abnormally: $($_.Exception.Message)" }
                try { [void]$proc.WaitForExit(5000); $exitCode = $proc.ExitCode } catch { $exitCode = -1 }
            } finally {
                $cancelled = Test-DevKitToolRunCancelled -Entry $runEntry
                # Dropped LAST: tool.stop's Wait-DevKitToolRunReleased watches
                # for exactly this to know the tool lane is free again.
                Unregister-DevKitToolRun -Registry $RunRegistry -RunId $runId
            }

            if ($cancelled) {
                # stdout, not stderr: a cancelled run is not a failed one, and
                # the dialog paints stderr red. This is deliberately the last
                # console line a cancelled run produces, so the app and the
                # recorded run history both end on the plain truth.
                & $EmitEvent 'tool.output' $runId @{ stream = 'stdout'; line = "-- Run cancelled. PID $($proc.Id) and its child processes were terminated by DevKit. --" }
            }
            & $EmitEvent 'tool.finished' $runId @{ exitCode = $exitCode; cancelled = $cancelled }
            return [ordered]@{ runId = $runId; exitCode = $exitCode; cancelled = $cancelled }
        }

        'tool.stop' {
            # Routed to the 'work' lane, NOT 'tool' - see
            # Get-DevKitRpcLaneForMethod in Invoke-DevKitRpc.ps1. The tool
            # lane is by definition blocked inside the run being cancelled.
            $runId = [string](Get-DevKitRpcParam $Params 'runId' '')
            if ([string]::IsNullOrWhiteSpace($runId)) { throw 'tool.stop requires a runId.' }
            return Stop-DevKitToolRun -Registry $RunRegistry -RunId $runId
        }

        default {
            throw "Unknown RPC method: $Method"
        }
    }
}
