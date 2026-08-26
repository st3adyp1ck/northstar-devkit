#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Close Out Session - Northstar DevKit
.DESCRIPTION
    One end-of-day pass that leaves the machine ready for the next session:
    stops the dev processes still running, frees the common dev ports,
    empties disposable temp/junk, and trims every process's working set back
    to the OS. It composes the same logic the individual tools use
    (Kill-AllNode / Kill-Port / Clear-NpmCache / Clear-DiskJunk /
    Docker-Cleanup / the widget's Free Memory) instead of reimplementing it.

    WHAT A DEFAULT RUN TOUCHES
      - node.exe processes: stopped (SIGKILL-equivalent Stop-Process -Force).
      - Listeners on the common dev ports (1337, 3000-3003, 4200, 5000,
        5173/5174, 5500, 8000, 8080/8081, 9000): stopped, but ONLY when the
        listening process is a recognized dev runtime (node, bun, deno,
        python, dotnet, java, php, ruby, go, ...). Anything else is left
        running and reported by name.
      - The CONTENTS of your user TEMP folder ($env:TEMP).
      - Windows\Temp and the Windows Update download cache - only when the
        session is elevated; skipped with a notice otherwise.
      - Every accessible process's working set, via psapi's EmptyWorkingSet.
        That is a trim, not a kill: pageable pages go back to the OS and
        nothing loses state.

    WHAT IT NEVER TOUCHES
      - Source files, git working trees, uncommitted changes, .env files,
        node_modules, or build output. Nothing under a project is deleted
        unless you pass -ProjectPath, and even then only regenerable
        framework caches (.next, node_modules\.cache, node_modules\.vite,
        .turbo) - never dist, never node_modules itself.
      - The Recycle Bin, unless you pass -IncludeRecycleBin. A file you
        deleted but might still want back is not junk.
      - Docker, unless you pass -IncludeDocker - and even then only stopped
        containers, dangling images, and build cache. Never volumes (a
        volume is usually somebody's database) and never tagged images.
      - Database ports (3306/5432/6379/27017) unless you pass
        -IncludeDatabasePorts. Stopping a local database engine mid-write is
        exactly the kind of surprise this tool exists to avoid.
      - DevKit's own process tree. This process, the sidecar that launched
        it, and every ancestor above them are protected - which is what
        keeps a `pnpm tauri dev` harness alive when its node parent would
        otherwise match the "kill all node" rule.

    Run it twice in a row and the second run reports "nothing to do" for
    almost every step: every step re-measures live state instead of assuming
    the first run's result.
.PARAMETER DryRun
    Report exactly what WOULD happen and change nothing. Dry run wins over
    every other switch, -Force included, so this is always safe to click.
.PARAMETER SkipNode
    Leave running node.exe processes alone.
.PARAMETER SkipPorts
    Do not free any dev port.
.PARAMETER SkipJunk
    Do not delete any temp/junk file.
.PARAMETER SkipMemory
    Do not trim process working sets.
.PARAMETER Port
    Additional ports to free, on top of the built-in dev-port list.
.PARAMETER IncludeDatabasePorts
    Also free the common local database ports (3306, 5432, 6379, 27017).
.PARAMETER KillAnyPortOwner
    Stop whatever holds a targeted port, not just recognized dev runtimes.
    Protected system processes and DevKit's own process tree are still
    never touched.
.PARAMETER IncludeRecycleBin
    Also empty the Recycle Bin (permanent - opt-in for that reason).
.PARAMETER IncludeDocker
    Also prune stopped containers, dangling images, and Docker build cache.
    Never volumes, never tagged images.
.PARAMETER IncludePackageCache
    Also clean the package manager's global cache (npm cache clean --force /
    pnpm store prune / yarn cache clean --all / bun pm cache rm). Safe, but
    it makes the next install slower, so it is opt-in.
.PARAMETER ProjectPath
    A project folder whose regenerable framework caches (.next,
    node_modules\.cache, node_modules\.vite, .turbo) should also be cleared.
    Omit it and no project folder is touched at all.
.PARAMETER Force
    Skip the destructive-action confirmation. The Control Center passes this
    automatically once you confirm in its caution dialog.
.EXAMPLE
    .\Close-OutSession.ps1 -DryRun
    .\Close-OutSession.ps1
    .\Close-OutSession.ps1 -IncludeDocker -IncludeRecycleBin -Force
    .\Close-OutSession.ps1 -ProjectPath "C:\dev\my-app" -Port 4000,4001
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$SkipNode,
    [switch]$SkipPorts,
    [switch]$SkipJunk,
    [switch]$SkipMemory,
    [ValidateRange(1, 65535)]
    [int[]]$Port = @(),
    [switch]$IncludeDatabasePorts,
    [switch]$KillAnyPortOwner,
    [switch]$IncludeRecycleBin,
    [switch]$IncludeDocker,
    [switch]$IncludePackageCache,
    [string]$ProjectPath,
    [switch]$Force
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) {
    . $CommonModule
} else {
    Write-Host "ERROR: Required module not found: $CommonModule" -ForegroundColor Red
    exit 1
}

# ==================== STATIC SETS ====================

# The dev-server ports Scan-Ports.ps1 already treats as "common", minus the
# database ports - those move behind -IncludeDatabasePorts because killing a
# database engine is a different class of surprise than killing a dev server.
$script:DevKitCloseOutDevPorts = @(1337, 3000, 3001, 3002, 3003, 4200, 5000, 5173, 5174, 5500, 8000, 8080, 8081, 9000)
$script:DevKitCloseOutDatabasePorts = @(3306, 5432, 6379, 27017)

# An ALLOWLIST, not a denylist, gates the port step: a dev port can just as
# easily be held by svchost (Windows' own services squat on 5000), by SQL
# Server, or by Docker's port proxy, and "free the port" must never mean
# "kill whatever that is". Anything not named here is reported and left
# alone unless the user explicitly passes -KillAnyPortOwner.
$script:DevKitCloseOutDevRuntimeNames = @(
    'node', 'npm', 'npx', 'pnpm', 'yarn', 'bun', 'deno', 'esbuild', 'vite',
    'next', 'nodemon', 'ts-node', 'tsserver', 'webpack', 'parcel', 'rollup',
    'turbo', 'astro', 'nuxt', 'ng', 'expo', 'metro', 'serve', 'http-server',
    'python', 'python3', 'pythonw', 'uvicorn', 'gunicorn', 'flask',
    'dotnet', 'iisexpress', 'java', 'gradle', 'maven', 'mvn',
    'php', 'ruby', 'rails', 'puma', 'go', 'air', 'cargo', 'hugo', 'jekyll'
)

# Belt-and-braces on top of the allowlist: even with -KillAnyPortOwner these
# are never stopped. Same list Get-DevKitProcessClassification calls 'System'
# in core/DevKit-WidgetCore.ps1 - Windows misbehaves or dies without them.
$script:DevKitCloseOutNeverKillNames = @(
    'system', 'idle', 'registry', 'secure system', 'memory compression',
    'smss', 'csrss', 'wininit', 'winlogon', 'services', 'svchost', 'lsass',
    'lsaiso', 'fontdrvhost', 'dwm', 'werfault', 'sihost', 'taskhostw',
    'runtimebroker', 'msmpeng', 'nissrv', 'searchindexer', 'spoolsv'
)

# ==================== PURE HELPERS (unit-tested) ====================

function Format-DevKitCloseOutSize {
    <#
    .SYNOPSIS
        Byte count as a human-readable size string.
    .DESCRIPTION
        Script-local on purpose: Clear-DiskJunk.ps1 and
        Find-StaleNodeModules.ps1 each carry the same private copy because
        tools/lib has never exported one, and adding a shared helper is a
        change to a file this tool does not own.
    #>
    param([Parameter(Mandatory = $true)][double]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Get-DevKitCloseOutPortList {
    <#
    .SYNOPSIS
        The ports this run will check, sorted and de-duplicated.
    .PARAMETER IncludeDatabasePorts
        Append the common local database ports.
    .PARAMETER ExtraPort
        Caller-supplied extras (already range-validated at parameter bind
        time; re-checked here so the function is safe to call directly).
    .OUTPUTS
        [int[]] - always a real array, including at count 1.
    #>
    param(
        [switch]$IncludeDatabasePorts,
        [int[]]$ExtraPort = @()
    )

    $ports = @($script:DevKitCloseOutDevPorts)
    if ($IncludeDatabasePorts) { $ports += $script:DevKitCloseOutDatabasePorts }
    foreach ($p in @($ExtraPort)) {
        if ($p -ge 1 -and $p -le 65535) { $ports += [int]$p }
    }
    return @($ports | Sort-Object -Unique)
}

function Get-DevKitCloseOutAncestry {
    <#
    .SYNOPSIS
        This process's pid plus every ancestor pid above it.
    .DESCRIPTION
        Pure - it reads only $Processes - so the walk is unit-testable
        against a synthetic process table.

        Win32_Process.ParentProcessId is a number RECORDED at creation, so a
        recycled pid can make a stranger look like an ancestor. That is the
        harmless direction here: the only thing this list does is EXCLUDE
        pids from being killed, so a false positive costs one un-freed port
        while a false negative could kill the dev harness that launched us.
        The visited set makes a pid-reuse cycle (A parents B, B parents A)
        terminate instead of spinning.
    .PARAMETER ProcessId
        The pid to walk up from (included in the result).
    .PARAMETER Processes
        Rows exposing ProcessId and ParentProcessId, e.g. from
        Get-CimInstance Win32_Process. Empty is valid: the result is then
        just $ProcessId itself.
    .OUTPUTS
        [int[]] - self first, then each ancestor, nearest first.
    #>
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [object[]]$Processes = @()
    )

    $byId = @{}
    foreach ($row in @($Processes)) {
        if ($null -eq $row) { continue }
        $rowId = 0
        if (-not [int]::TryParse([string]$row.ProcessId, [ref]$rowId)) { continue }
        if (-not $byId.ContainsKey($rowId)) { $byId[$rowId] = $row }
    }

    $chain = @()
    $seen = @{}
    $current = $ProcessId
    while ($current -gt 0 -and -not $seen.ContainsKey($current)) {
        $chain += $current
        $seen[$current] = $true
        if (-not $byId.ContainsKey($current)) { break }
        $parent = 0
        if (-not [int]::TryParse([string]$byId[$current].ParentProcessId, [ref]$parent)) { break }
        $current = $parent
    }
    return , @($chain)
}

function Get-DevKitCloseOutProtectReason {
    <#
    .SYNOPSIS
        Why a process must NOT be stopped, or $null when stopping it is fine.
    .DESCRIPTION
        One predicate for both the node step and the port step, so the two
        can never drift apart on what counts as untouchable. Order matters:
        reserved pids and DevKit's own tree are refused before any name rule,
        and the never-kill name list is refused even under -AllowAnyOwner.
    .PARAMETER ProcessId
        The candidate's pid.
    .PARAMETER Name
        The candidate's process name, with or without a .exe suffix.
    .PARAMETER ProtectedPids
        Pids that must survive (this process and its ancestors).
    .PARAMETER AllowAnyOwner
        Skip the dev-runtime allowlist check (the -KillAnyPortOwner escape
        hatch). The reserved-pid, own-tree, and never-kill-name rules still
        apply.
    .OUTPUTS
        [string] reason, or $null when the process may be stopped.
    #>
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [AllowEmptyString()][string]$Name = '',
        [int[]]$ProtectedPids = @(),
        [switch]$AllowAnyOwner
    )

    if ($ProcessId -le 0 -or $ProcessId -eq 4) { return 'reserved system process' }
    if (@($ProtectedPids) -contains $ProcessId) { return "DevKit's own process tree" }

    $normalized = ([string]$Name).Trim()
    if ($normalized.ToLowerInvariant().EndsWith('.exe')) {
        $normalized = $normalized.Substring(0, $normalized.Length - 4)
    }
    $normalized = $normalized.ToLowerInvariant()

    if ($script:DevKitCloseOutNeverKillNames -contains $normalized) {
        return "protected system process '$normalized'"
    }
    if (-not $AllowAnyOwner -and -not ($script:DevKitCloseOutDevRuntimeNames -contains $normalized)) {
        return "'$normalized' is not a recognized dev runtime (use -KillAnyPortOwner to stop it anyway)"
    }
    return $null
}

function New-DevKitCloseOutPlan {
    <#
    .SYNOPSIS
        The ordered step plan for one run, with each step already resolved
        to enabled/disabled plus the reason it is disabled.
    .DESCRIPTION
        Pure, and the single source of truth for BOTH the plan the run
        prints up front and the steps it then executes - a dry run that
        printed one plan and a real run that did something else would defeat
        the entire point of having a dry run.

        Step order is deliberate: processes stop first so their file handles
        release before anything measures or deletes; the working-set trim
        runs last so it sees the memory everything else just gave back.
    .OUTPUTS
        PSCustomObject[] with Key, Title, Enabled, Destructive, Detail,
        SkipReason. Returned unwrapped (no `,@()`) because the plan always
        holds every step, so it cannot unroll to a bare object, and callers
        pipe it into Where-Object.
    #>
    param(
        [switch]$SkipNode,
        [switch]$SkipPorts,
        [switch]$SkipJunk,
        [switch]$SkipMemory,
        [switch]$IncludeDocker,
        [switch]$IncludePackageCache,
        [switch]$IncludeRecycleBin,
        [string]$ProjectPath = '',
        [int]$PortCount = 0
    )

    $junkDetail = 'delete the contents of the user TEMP folder (plus Windows\Temp and the Windows Update cache when elevated)'
    if ($IncludeRecycleBin) { $junkDetail += ', and empty the Recycle Bin' }

    $plan = @()

    $plan += [PSCustomObject]@{
        Key         = 'node'
        Title       = 'Node processes'
        Enabled     = (-not $SkipNode)
        Destructive = $true
        Detail      = "stop every running node.exe (DevKit's own process tree is never touched)"
        SkipReason  = if ($SkipNode) { '-SkipNode was passed' } else { '' }
    }
    $plan += [PSCustomObject]@{
        Key         = 'ports'
        Title       = 'Dev ports'
        Enabled     = (-not $SkipPorts)
        Destructive = $true
        Detail      = "free $PortCount dev port(s) still held by a recognized dev runtime"
        SkipReason  = if ($SkipPorts) { '-SkipPorts was passed' } else { '' }
    }
    $plan += [PSCustomObject]@{
        Key         = 'projectcache'
        Title       = 'Project caches'
        Enabled     = (-not [string]::IsNullOrWhiteSpace($ProjectPath))
        Destructive = $true
        Detail      = "clear regenerable framework caches under $ProjectPath (never node_modules, never dist)"
        SkipReason  = if ([string]::IsNullOrWhiteSpace($ProjectPath)) { 'no -ProjectPath given' } else { '' }
    }
    $plan += [PSCustomObject]@{
        Key         = 'packagecache'
        Title       = 'Package cache'
        Enabled     = [bool]$IncludePackageCache
        Destructive = $true
        Detail      = 'clean the package manager global cache'
        SkipReason  = if ($IncludePackageCache) { '' } else { '-IncludePackageCache not passed' }
    }
    $plan += [PSCustomObject]@{
        Key         = 'docker'
        Title       = 'Docker'
        Enabled     = [bool]$IncludeDocker
        Destructive = $true
        Detail      = 'prune stopped containers, dangling images, and build cache (never volumes)'
        SkipReason  = if ($IncludeDocker) { '' } else { '-IncludeDocker not passed' }
    }
    $plan += [PSCustomObject]@{
        Key         = 'junk'
        Title       = 'Temp and junk'
        Enabled     = (-not $SkipJunk)
        Destructive = $true
        Detail      = $junkDetail
        SkipReason  = if ($SkipJunk) { '-SkipJunk was passed' } else { '' }
    }
    $plan += [PSCustomObject]@{
        Key         = 'memory'
        Title       = 'Memory'
        Enabled     = (-not $SkipMemory)
        Destructive = $false
        Detail      = 'trim every accessible process working set back to the OS (nothing is killed)'
        SkipReason  = if ($SkipMemory) { '-SkipMemory was passed' } else { '' }
    }

    return $plan
}

function New-DevKitCloseOutResult {
    <#
    .SYNOPSIS
        One step's outcome, in the shape Format-DevKitCloseOutSummary reads.
    .PARAMETER Status
        'done' (it did something), 'nothing' (there was nothing to do),
        'preview' (dry run - what it would have done), 'skipped' (step was
        off, or could not run), or 'error'.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)]
        [ValidateSet('done', 'nothing', 'preview', 'skipped', 'error')]
        [string]$Status,
        [AllowEmptyString()][string]$Detail = '',
        [double]$FreedBytes = 0,
        [double]$FreedMemoryMB = 0
    )
    return [PSCustomObject]@{
        Key           = $Key
        Title         = $Title
        Status        = $Status
        Detail        = $Detail
        FreedBytes    = $FreedBytes
        FreedMemoryMB = $FreedMemoryMB
    }
}

function Format-DevKitCloseOutSummary {
    <#
    .SYNOPSIS
        The final SUMMARY block, as plain lines.
    .DESCRIPTION
        Pure, so the wording of the one part of the output people actually
        read is unit-tested rather than eyeballed. Every step appears -
        including the skipped ones and why - because a cleanup tool that
        quietly omits what it did not do is how you end up trusting a run
        that never happened.
    .PARAMETER Steps
        Step results from New-DevKitCloseOutResult.
    .PARAMETER Preview
        Format for a dry run: totals are replaced by an explicit
        "nothing was changed" line.
    .OUTPUTS
        [string[]] - always at least a header line and one more, so it is
        returned unwrapped and pipes/assigns the way a caller expects.
    #>
    param(
        [object[]]$Steps = @(),
        [switch]$Preview
    )

    $lines = @()
    $lines += '  SUMMARY'

    $stepList = @($Steps)
    if ($stepList.Count -eq 0) {
        $lines += '    (no steps ran)'
        return $lines
    }

    $totalBytes = 0.0
    $totalMemoryMB = 0.0
    $changed = 0

    foreach ($step in $stepList) {
        $status = [string]$step.Status
        $detail = [string]$step.Detail
        switch ($status) {
            'done' {
                $text = if ($detail) { $detail } else { 'done' }
                $changed++
            }
            'preview' {
                $text = if ($detail) { "would $detail" } else { 'would run' }
            }
            'nothing' {
                $text = if ($detail) { "nothing to do - $detail" } else { 'nothing to do' }
            }
            'skipped' {
                $text = if ($detail) { "skipped - $detail" } else { 'skipped' }
            }
            'error' {
                $text = if ($detail) { "ERROR - $detail" } else { 'ERROR' }
            }
            default {
                $text = $detail
            }
        }
        $lines += ("    {0,-16} {1}" -f [string]$step.Title, $text)

        $bytes = 0.0
        if ($null -ne $step.FreedBytes) { $bytes = [double]$step.FreedBytes }
        if ($bytes -gt 0) { $totalBytes += $bytes }

        $memory = 0.0
        if ($null -ne $step.FreedMemoryMB) { $memory = [double]$step.FreedMemoryMB }
        if ($memory -gt 0) { $totalMemoryMB += $memory }
    }

    $lines += '    ----------------------------------------'
    if ($Preview) {
        $lines += '    Dry run - nothing was stopped, deleted, or changed.'
        return $lines
    }

    $lines += ("    {0,-16} {1}" -f 'Disk reclaimed', (Format-DevKitCloseOutSize $totalBytes))
    # The trim reports megabytes, but a real end-of-day run reclaims tens of
    # gigabytes - "16,966.7 MB" is a number nobody can read at a glance.
    $lines += ("    {0,-16} {1}" -f 'Memory reclaimed', (Format-DevKitCloseOutSize ($totalMemoryMB * 1MB)))
    if ($changed -eq 0) {
        $lines += '    Already clean - nothing needed doing.'
    }
    return $lines
}

function ConvertFrom-DevKitCloseOutDockerReclaim {
    <#
    .SYNOPSIS
        The byte count out of a `docker ... prune` "Total reclaimed space"
        line, or $null when the text has none.
    .DESCRIPTION
        docker formats sizes with go-units, which is DECIMAL: 1kB is 1000
        bytes, not 1024. Converting with 1KB/1MB here would overstate every
        docker figure in the summary by 2-10%.
    .PARAMETER Text
        Raw prune output (one string, may be multi-line).
    .OUTPUTS
        [double] bytes, or $null.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    if ($Text -notmatch '(?im)Total\s+reclaimed\s+space:\s*([\d\.]+)\s*([kmgt]?b)\b') { return $null }

    # Invariant culture, not the current one: docker always prints "1.5GB"
    # with a dot, and a machine running in a comma-decimal locale would
    # otherwise fail to parse it and silently report nothing reclaimed.
    $value = 0.0
    $parsed = [double]::TryParse(
        $Matches[1],
        [System.Globalization.NumberStyles]::Float,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref]$value)
    if (-not $parsed) { return $null }
    switch ($Matches[2]) {
        'b'  { return $value }
        'kb' { return $value * 1000 }
        'mb' { return $value * 1000000 }
        'gb' { return $value * 1000000000 }
        'tb' { return $value * 1000000000000 }
    }
    return $null
}

function Get-DevKitCloseOutPathSize {
    <#
    .SYNOPSIS
        Total bytes under a path, or 0 when it is missing or unreadable.
    .DESCRIPTION
        Same shape as Clear-DiskJunk.ps1's private scanner: an unreadable
        root (broken reparse point, permission wall) counts as 0 rather than
        aborting the scan, because a junk measurement failing is never a
        reason for a cleanup run to fail.
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return 0 }
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $total = 0
    try {
        foreach ($item in (Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue)) {
            $total += $item.Length
        }
    } catch { }
    return $total
}

function Get-DevKitCloseOutRecycleBinSize {
    <#
    .SYNOPSIS
        Total bytes in the Recycle Bin, or 0 when the shell COM call fails.
    #>
    $shell = $null
    try {
        $shell = New-Object -ComObject Shell.Application
        $bin = $shell.Namespace(10)
        if (-not $bin) { return 0 }
        $total = 0
        foreach ($item in $bin.Items()) { $total += $item.Size }
        return $total
    } catch {
        return 0
    } finally {
        if ($shell) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
    }
}

# Dot-sourcing this file (tests/Unit/CloseOutSession.Tests.ps1 does exactly
# that, to unit test the pure helpers above) must never stop a process,
# delete a file, or prompt. Everything below this line is the real run.
if ($MyInvocation.InvocationName -eq '.') {
    return
}

# ==================== RUN ====================

Write-DevKitHeader "Close Out Session"

$projectDir = ''
if (-not [string]::IsNullOrWhiteSpace($ProjectPath)) {
    try {
        $projectDir = Resolve-DevKitDirectory -Path $ProjectPath
    } catch {
        Write-DevKitError $_
        exit 1
    }
}

$portList = Get-DevKitCloseOutPortList -IncludeDatabasePorts:$IncludeDatabasePorts -ExtraPort $Port
$plan = New-DevKitCloseOutPlan -SkipNode:$SkipNode -SkipPorts:$SkipPorts -SkipJunk:$SkipJunk `
    -SkipMemory:$SkipMemory -IncludeDocker:$IncludeDocker -IncludePackageCache:$IncludePackageCache `
    -IncludeRecycleBin:$IncludeRecycleBin -ProjectPath $projectDir -PortCount $portList.Count

if ($DryRun) {
    Write-Host "  DRY RUN - nothing will be stopped, deleted, or changed." -ForegroundColor Magenta
    Write-Host ""
}

Write-Host "  Plan:" -ForegroundColor Magenta
foreach ($step in $plan) {
    if ($step.Enabled) {
        Write-Host ("    [x] {0}: {1}" -f $step.Title, $step.Detail) -ForegroundColor Gray
    } else {
        Write-Host ("    [ ] {0}: skipped - {1}" -f $step.Title, $step.SkipReason) -ForegroundColor DarkGray
    }
}
Write-Host ""

# Every ancestor of this process is off-limits for the rest of the run. In a
# `pnpm tauri dev` session the node process running Vite IS an ancestor, and
# "stop every node.exe" would otherwise take down the harness that started
# DevKit - taking this tool's own output with it.
$protectedPids = @($PID)
try {
    $snapshot = @(Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId -ErrorAction Stop)
    $protectedPids = Get-DevKitCloseOutAncestry -ProcessId $PID -Processes $snapshot
} catch {
    Write-DevKitInfo "Could not read the process table - only this process (PID $PID) is protected."
}

$destructiveSteps = @($plan | Where-Object { $_.Enabled -and $_.Destructive })
if (-not $DryRun -and $destructiveSteps.Count -gt 0) {
    $affected = @()
    if (-not $SkipJunk) {
        $affected += "$env:TEMP (contents)"
        if ($IncludeRecycleBin) { $affected += 'Recycle Bin (permanent)' }
    }
    if ($projectDir) { $affected += "$projectDir (framework caches only)" }

    $action = "close out this session: " + (($destructiveSteps | ForEach-Object { $_.Title.ToLowerInvariant() }) -join ', ')
    $proceed = Confirm-DevKitDestructiveAction -Action $action -AffectedPaths $affected -Force:$Force
    if (-not $proceed) {
        Write-Host ""
        Write-DevKitInfo "Cancelled - nothing was changed."
        exit 0
    }
    Write-Host ""
}

$results = @()
$hadErrors = $false
$enabledSteps = @($plan | Where-Object { $_.Enabled })
$stepNumber = 0

foreach ($step in $plan) {

    if (-not $step.Enabled) {
        $results += New-DevKitCloseOutResult -Key $step.Key -Title $step.Title -Status 'skipped' -Detail $step.SkipReason
        continue
    }

    $stepNumber++
    Write-Host ("  [{0}/{1}] {2}" -f $stepNumber, $enabledSteps.Count, $step.Title) -ForegroundColor Magenta

    switch ($step.Key) {

        'node' {
            $nodeProcesses = @(Get-Process -Name 'node' -ErrorAction SilentlyContinue)
            if ($nodeProcesses.Count -eq 0) {
                Write-DevKitInfo "No node processes are running."
                $results += New-DevKitCloseOutResult -Key 'node' -Title $step.Title -Status 'nothing' -Detail 'no node processes were running'
            } else {
                $stopped = 0
                $protectedCount = 0
                $failed = 0
                foreach ($proc in $nodeProcesses) {
                    $reason = Get-DevKitCloseOutProtectReason -ProcessId $proc.Id -Name $proc.ProcessName -ProtectedPids $protectedPids
                    if ($reason) {
                        Write-Host "    LEFT RUNNING  PID $($proc.Id) node - $reason" -ForegroundColor Yellow
                        $protectedCount++
                        continue
                    }

                    $started = try { $proc.StartTime } catch { $null }
                    $workingSet = try { $proc.WorkingSet64 } catch { 0 }
                    $describe = "PID $($proc.Id) node ($(Format-DevKitCloseOutSize $workingSet)"
                    if ($started) { $describe += ", started $($started.ToString('HH:mm'))" }
                    $describe += ")"

                    if ($DryRun) {
                        Write-Host "    WOULD STOP    $describe" -ForegroundColor Gray
                        $stopped++
                        continue
                    }

                    # TOCTOU guard, same rule Kill-AllNode.ps1 uses: the scan
                    # above and this kill are not atomic, and Windows can hand
                    # a dead process's pid to something unrelated in between.
                    $current = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
                    if (-not $current) {
                        Write-Host "    GONE          PID $($proc.Id) exited on its own" -ForegroundColor Gray
                        continue
                    }
                    $currentStart = try { $current.StartTime } catch { $null }
                    if ($current.ProcessName -ne $proc.ProcessName -or $currentStart -ne $started) {
                        Write-Host "    LEFT RUNNING  PID $($proc.Id) - identity changed since the scan (now '$($current.ProcessName)')" -ForegroundColor Yellow
                        $protectedCount++
                        continue
                    }

                    try {
                        Stop-Process -Id $proc.Id -Force -ErrorAction Stop
                        Write-Host "    STOPPED       $describe" -ForegroundColor Green
                        $stopped++
                    } catch {
                        Write-Host "    FAILED        PID $($proc.Id): $($_.Exception.Message)" -ForegroundColor Red
                        $failed++
                        $hadErrors = $true
                    }
                }

                $detail = "stopped $stopped node process(es)"
                if ($DryRun) { $detail = "stop $stopped node process(es)" }
                if ($protectedCount -gt 0) { $detail += ", left $protectedCount running (protected)" }
                if ($failed -gt 0) { $detail += ", $failed failed" }
                $status = if ($DryRun) { 'preview' } elseif ($stopped -gt 0 -or $failed -gt 0) { 'done' } else { 'nothing' }
                $results += New-DevKitCloseOutResult -Key 'node' -Title $step.Title -Status $status -Detail $detail
            }
        }

        'ports' {
            Write-DevKitInfo "Checking $($portList.Count) port(s): $($portList -join ', ')"
            $freed = 0
            $left = 0
            $failed = 0
            foreach ($portNumber in $portList) {
                $owner = $null
                try {
                    $owner = Get-DevKitProcessByPort -Port $portNumber
                } catch {
                    $owner = $null
                }
                if (-not $owner) { continue }
                # A port with no live listener can still return a stale row
                # (TIME_WAIT) whose owning pid is 0. There is no process to
                # stop, and the port is already free - say nothing about it.
                if ([int]$owner.PID -le 0) { continue }

                $ownerName = if ($owner.Name) { [string]$owner.Name } else { 'Unknown' }
                $reason = Get-DevKitCloseOutProtectReason -ProcessId ([int]$owner.PID) -Name $ownerName `
                    -ProtectedPids $protectedPids -AllowAnyOwner:$KillAnyPortOwner
                if ($reason) {
                    Write-Host "    LEFT RUNNING  port $portNumber -> $ownerName (PID $($owner.PID)) - $reason" -ForegroundColor Yellow
                    $left++
                    continue
                }

                if ($DryRun) {
                    Write-Host "    WOULD FREE    port $portNumber -> $ownerName (PID $($owner.PID))" -ForegroundColor Gray
                    $freed++
                    continue
                }

                # Re-verify identity before killing (see the node step) - the
                # port lookup and this kill are separated by a real interval.
                $target = Get-Process -Id ([int]$owner.PID) -ErrorAction SilentlyContinue
                if (-not $target -or $target.ProcessName -ne $ownerName) {
                    Write-Host "    SKIPPED       port $portNumber - owner changed since the lookup" -ForegroundColor Yellow
                    $left++
                    continue
                }
                try {
                    Stop-Process -Id $target.Id -Force -ErrorAction Stop
                    Write-Host "    FREED         port $portNumber -> $ownerName (PID $($target.Id))" -ForegroundColor Green
                    $freed++
                } catch {
                    Write-Host "    FAILED        port $portNumber -> $ownerName (PID $($target.Id)): $($_.Exception.Message)" -ForegroundColor Red
                    $failed++
                    $hadErrors = $true
                }
            }

            if ($freed -eq 0 -and $left -eq 0 -and $failed -eq 0) {
                Write-DevKitInfo "All checked ports are already free."
                $results += New-DevKitCloseOutResult -Key 'ports' -Title $step.Title -Status 'nothing' `
                    -Detail "all $($portList.Count) checked port(s) already free"
            } else {
                $detail = if ($DryRun) { "free $freed of $($portList.Count) checked port(s)" } else { "freed $freed of $($portList.Count) checked port(s)" }
                if ($left -gt 0) { $detail += ", left $left held (not a dev runtime, or protected)" }
                if ($failed -gt 0) { $detail += ", $failed failed" }
                $status = if ($DryRun) { 'preview' } elseif ($freed -gt 0 -or $failed -gt 0) { 'done' } else { 'nothing' }
                $results += New-DevKitCloseOutResult -Key 'ports' -Title $step.Title -Status $status -Detail $detail
            }
        }

        'projectcache' {
            # Mirrors Clear-DevKitNodeCaches's own base + -IncludeTurbo list
            # so the sizes reported here are the sizes that call deletes.
            # Build output (dist, .vite at the root) is deliberately absent:
            # it is exactly the kind of thing somebody still needs tomorrow.
            $cachePaths = @(
                (Join-Path $projectDir '.next'),
                (Join-Path (Join-Path $projectDir 'node_modules') '.cache'),
                (Join-Path (Join-Path $projectDir 'node_modules') '.vite'),
                (Join-Path $projectDir '.turbo')
            )
            $existing = @($cachePaths | Where-Object { Test-Path -LiteralPath $_ })
            if ($existing.Count -eq 0) {
                Write-DevKitInfo "No framework caches found under $projectDir."
                $results += New-DevKitCloseOutResult -Key 'projectcache' -Title $step.Title -Status 'nothing' -Detail 'no framework caches present'
            } else {
                $cacheBytes = 0
                foreach ($path in $existing) {
                    $size = Get-DevKitCloseOutPathSize -Path $path
                    $cacheBytes += $size
                    Write-Host ("    {0,-12} {1}" -f (Format-DevKitCloseOutSize $size), $path) -ForegroundColor Gray
                }
                if ($DryRun) {
                    $results += New-DevKitCloseOutResult -Key 'projectcache' -Title $step.Title -Status 'preview' `
                        -Detail "clear $($existing.Count) cache folder(s), about $(Format-DevKitCloseOutSize $cacheBytes)"
                } else {
                    Write-DevKitStep "Clearing framework caches"
                    try {
                        [void](Clear-DevKitNodeCaches -Path $projectDir -IncludeTurbo)
                        Write-DevKitDone
                        $remaining = 0
                        foreach ($path in $existing) { $remaining += Get-DevKitCloseOutPathSize -Path $path }
                        $reclaimed = [math]::Max(0, $cacheBytes - $remaining)
                        $results += New-DevKitCloseOutResult -Key 'projectcache' -Title $step.Title -Status 'done' `
                            -Detail "cleared $($existing.Count) cache folder(s), $(Format-DevKitCloseOutSize $reclaimed)" -FreedBytes $reclaimed
                    } catch {
                        Write-DevKitError $_.Exception.Message
                        $hadErrors = $true
                        $results += New-DevKitCloseOutResult -Key 'projectcache' -Title $step.Title -Status 'error' -Detail $_.Exception.Message
                    }
                }
            }
        }

        'packagecache' {
            $managerPath = if ($projectDir) { $projectDir } else { (Get-Location).Path }
            $manager = Get-DevKitPackageManager -Path $managerPath
            Write-DevKitInfo "Package manager: $($manager.Command) (detected from $managerPath)"
            if (-not (Test-DevKitCommand $manager.Command)) {
                Write-Host "    SKIP  $($manager.Command) is not installed or not on PATH." -ForegroundColor Yellow
                $results += New-DevKitCloseOutResult -Key 'packagecache' -Title $step.Title -Status 'skipped' `
                    -Detail "$($manager.Command) is not on PATH"
            } elseif ($DryRun) {
                $results += New-DevKitCloseOutResult -Key 'packagecache' -Title $step.Title -Status 'preview' `
                    -Detail "clean the $($manager.Command) global cache"
            } else {
                Write-DevKitStep "Cleaning the $($manager.Command) cache"
                try {
                    Invoke-DevKitPackageCacheClean -Path $managerPath -Manager $manager
                    Write-DevKitDone
                    # No FreedBytes: none of the four package managers report
                    # how much their cache clean actually reclaimed, and
                    # inventing a number here would make the summary a liar.
                    $results += New-DevKitCloseOutResult -Key 'packagecache' -Title $step.Title -Status 'done' `
                        -Detail "cleaned the $($manager.Command) cache (size not reported by $($manager.Command))"
                } catch {
                    Write-DevKitError $_.Exception.Message
                    $hadErrors = $true
                    $results += New-DevKitCloseOutResult -Key 'packagecache' -Title $step.Title -Status 'error' -Detail $_.Exception.Message
                }
            }
        }

        'docker' {
            $dockerReady = $false
            if (Test-DevKitCommand 'docker') {
                $null = docker info 2>$null
                $dockerReady = ($LASTEXITCODE -eq 0)
            }

            if (-not $dockerReady) {
                Write-Host "    SKIP  Docker is not installed or its daemon is not running." -ForegroundColor Yellow
                $results += New-DevKitCloseOutResult -Key 'docker' -Title $step.Title -Status 'skipped' `
                    -Detail 'Docker not installed or daemon not running'
            } elseif ($DryRun) {
                foreach ($line in @(docker system df 2>$null)) {
                    Write-Host "    $line" -ForegroundColor Gray
                }
                # docker's own table lists reclaimable volume space, and this
                # tool never prunes volumes - say so, so nobody reads that row
                # as a promise.
                Write-DevKitInfo "Local Volumes are listed by Docker but are never pruned by this tool."
                $results += New-DevKitCloseOutResult -Key 'docker' -Title $step.Title -Status 'preview' `
                    -Detail 'prune stopped containers, dangling images, and build cache'
            } else {
                $dockerBytes = 0.0
                $dockerFailed = $false
                # Deliberately three narrow prunes rather than `docker system
                # prune`: system prune takes networks and (with -a) tagged
                # images too, and one flag away is volume deletion. Nothing
                # here can remove a volume even by accident.
                $prunes = @(
                    @{ Label = 'stopped containers'; Args = @('container', 'prune', '-f') },
                    @{ Label = 'dangling images'; Args = @('image', 'prune', '-f') },
                    @{ Label = 'build cache'; Args = @('builder', 'prune', '-f') }
                )
                foreach ($prune in $prunes) {
                    Write-DevKitStep "Pruning $($prune.Label)"
                    $pruneArgs = @($prune.Args)
                    $output = @(& docker @pruneArgs 2>&1) -join "`n"
                    if ($LASTEXITCODE -ne 0) {
                        Write-DevKitError "docker $($pruneArgs -join ' ') exited with $LASTEXITCODE"
                        $dockerFailed = $true
                        $hadErrors = $true
                        continue
                    }
                    Write-DevKitDone
                    $reclaimed = ConvertFrom-DevKitCloseOutDockerReclaim -Text $output
                    if ($null -ne $reclaimed) { $dockerBytes += [double]$reclaimed }
                }

                if ($dockerFailed) {
                    $results += New-DevKitCloseOutResult -Key 'docker' -Title $step.Title -Status 'error' `
                        -Detail 'one or more prunes failed - see above' -FreedBytes $dockerBytes
                } elseif ($dockerBytes -gt 0) {
                    $results += New-DevKitCloseOutResult -Key 'docker' -Title $step.Title -Status 'done' `
                        -Detail "pruned containers, dangling images, and build cache ($(Format-DevKitCloseOutSize $dockerBytes))" -FreedBytes $dockerBytes
                } else {
                    $results += New-DevKitCloseOutResult -Key 'docker' -Title $step.Title -Status 'nothing' `
                        -Detail 'nothing prunable'
                }
            }
        }

        'junk' {
            $isAdmin = Test-DevKitAdmin
            $junkPaths = @($env:TEMP)
            $adminOnlyPaths = @(
                (Join-Path $env:SystemRoot 'Temp'),
                (Join-Path (Join-Path $env:SystemRoot 'SoftwareDistribution') 'Download')
            )
            if ($isAdmin) {
                $junkPaths += $adminOnlyPaths
            } else {
                Write-Host "    SKIP  Windows\Temp and the Windows Update cache need an elevated session." -ForegroundColor Yellow
            }
            $junkPaths = @($junkPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)

            Write-DevKitInfo "Measuring (a large TEMP folder can take a moment)..."
            $beforeBytes = 0
            foreach ($path in $junkPaths) {
                $size = Get-DevKitCloseOutPathSize -Path $path
                $beforeBytes += $size
                Write-Host ("    {0,-12} {1}" -f (Format-DevKitCloseOutSize $size), $path) -ForegroundColor Gray
            }
            $recycleBefore = 0
            if ($IncludeRecycleBin) {
                $recycleBefore = Get-DevKitCloseOutRecycleBinSize
                Write-Host ("    {0,-12} {1}" -f (Format-DevKitCloseOutSize $recycleBefore), 'Recycle Bin') -ForegroundColor Gray
            }
            $totalBefore = $beforeBytes + $recycleBefore

            if ($DryRun) {
                $results += New-DevKitCloseOutResult -Key 'junk' -Title $step.Title -Status 'preview' `
                    -Detail "delete about $(Format-DevKitCloseOutSize $totalBefore) of temp/junk"
            } elseif ($totalBefore -eq 0) {
                Write-DevKitInfo "Nothing to delete - the temp locations hold no reclaimable bytes."
                $results += New-DevKitCloseOutResult -Key 'junk' -Title $step.Title -Status 'nothing' -Detail 'no reclaimable bytes in the temp locations'
            } else {
                foreach ($path in $junkPaths) {
                    if (-not (Test-Path -LiteralPath $path)) { continue }
                    Write-DevKitStep "Clearing $path"
                    # SilentlyContinue on purpose: files an app still has open
                    # are locked, and skipping them is correct - the count of
                    # what survived is reported below rather than hidden.
                    Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue | ForEach-Object {
                        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                    }
                    Write-DevKitDone
                }
                if ($IncludeRecycleBin) {
                    Write-DevKitStep "Emptying the Recycle Bin"
                    try {
                        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
                        Write-DevKitDone
                    } catch {
                        Write-DevKitError $_.Exception.Message
                    }
                }

                $afterBytes = 0
                foreach ($path in $junkPaths) { $afterBytes += Get-DevKitCloseOutPathSize -Path $path }
                if ($IncludeRecycleBin) { $afterBytes += Get-DevKitCloseOutRecycleBinSize }
                $reclaimed = [math]::Max(0, $totalBefore - $afterBytes)

                # A run that freed nothing because every remaining file is
                # locked is "nothing to do", not "done" - otherwise a second
                # back-to-back run reports work it did not actually do.
                if ($reclaimed -gt 0) {
                    $status = 'done'
                    $detail = "reclaimed $(Format-DevKitCloseOutSize $reclaimed)"
                    if ($afterBytes -gt 0) {
                        $detail += ", $(Format-DevKitCloseOutSize $afterBytes) left behind (files still in use)"
                    }
                } else {
                    $status = 'nothing'
                    $detail = "$(Format-DevKitCloseOutSize $afterBytes) is held by files still in use"
                }
                if (-not $isAdmin) {
                    $detail += '; Windows\Temp and the Windows Update cache need elevation'
                }
                $results += New-DevKitCloseOutResult -Key 'junk' -Title $step.Title -Status $status -Detail $detail -FreedBytes $reclaimed
            }
        }

        'memory' {
            if ($DryRun) {
                $processCount = @(Get-Process -ErrorAction SilentlyContinue).Count
                Write-DevKitInfo "Would trim working sets across roughly $processCount process(es) - a trim, not a kill."
                $results += New-DevKitCloseOutResult -Key 'memory' -Title $step.Title -Status 'preview' `
                    -Detail "trim working sets across roughly $processCount process(es)"
            } else {
                # Loaded here rather than at the top of the file: this is the
                # one thing in the run that lives outside tools/ (psapi
                # EmptyWorkingSet interop, plus the per-runspace type guard
                # and System-process skip that make it safe), and a tool that
                # never reaches this step should not pay to parse it - nor
                # should the Pester file that dot-sources this script.
                $widgetCore = Join-Path (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'core') 'DevKit-WidgetCore.ps1'
                if (-not (Test-Path -LiteralPath $widgetCore)) {
                    Write-Host "    SKIP  Working-set trim unavailable ($widgetCore not found)." -ForegroundColor Yellow
                    $results += New-DevKitCloseOutResult -Key 'memory' -Title $step.Title -Status 'skipped' `
                        -Detail 'DevKit widget core not found'
                } else {
                    Write-DevKitStep "Trimming process working sets"
                    try {
                        . $widgetCore
                        $trim = Invoke-DevKitFreeMemory
                        Write-DevKitDone
                        $freedMB = [double]$trim.FreedMB
                        if ($freedMB -gt 0) {
                            $results += New-DevKitCloseOutResult -Key 'memory' -Title $step.Title -Status 'done' `
                                -Detail ("trimmed {0} across {1} process(es)" -f (Format-DevKitCloseOutSize ($freedMB * 1MB)), $trim.TrimmedProcesses) -FreedMemoryMB $freedMB
                        } else {
                            $results += New-DevKitCloseOutResult -Key 'memory' -Title $step.Title -Status 'nothing' `
                                -Detail "working sets were already trimmed ($($trim.TrimmedProcesses) process(es) checked)"
                        }
                    } catch {
                        Write-DevKitError $_.Exception.Message
                        $hadErrors = $true
                        $results += New-DevKitCloseOutResult -Key 'memory' -Title $step.Title -Status 'error' -Detail $_.Exception.Message
                    }
                }
            }
        }
    }

    Write-Host ""
}

$summaryLines = Format-DevKitCloseOutSummary -Steps $results -Preview:$DryRun
Write-Host $summaryLines[0] -ForegroundColor Cyan
foreach ($line in ($summaryLines | Select-Object -Skip 1)) {
    Write-Host $line -ForegroundColor Gray
}
Write-Host ""

if ($DryRun) {
    Write-DevKitInfo "Re-run without -DryRun to actually close out the session."
    Write-Host ""
    exit 0
}

if ($hadErrors) { exit 1 }
exit 0
