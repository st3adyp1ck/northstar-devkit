#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pure-logic core for the DevKit companion widget - Northstar DevKit
.DESCRIPTION
    Dot-sourceable, UI-free functions backing gui/DevKit-Widget.ps1:
    system metrics (CPU/memory/GPU load + best-effort temperatures, disk
    free space, reboot-pending + uptime), a Node-process + listening-port
    snapshot (with process ages and winnat reserved-port detection), Claude
    Code / Kimi Code MCP server status for the user scope and a selected
    project, a system-junk size scan (plus the GUI-driven clean: user temp,
    Recycle Bin, and - when elevated - Windows\Temp and the Windows Update
    download cache), the process-management backend for the clickable CPU/
    MEM/GPU gauges (process classification, top-CPU/top-memory/top-GPU
    collectors, a guarded kill, and a working-set trim), a git repo overview
    (branch, ahead/behind, dirty/stash counts,
    parsed log + graph lane layout) for the GitHub flyout, and a key-name-
    only .env drift diff. Sensors that wait out sampling windows (thermal
    zone, nvidia-smi) and slow-changing values (reboot sentinel, winnat
    ranges) are cached per runspace so the 2s metrics cycle stays cheap.

    Temperature access on Windows without third-party drivers is inherently
    best-effort: the ACPI thermal-zone performance counter and (for NVIDIA
    GPUs) the driver-bundled nvidia-smi.exe are used when present, and every
    collector degrades to $null ("n/a" in the UI) rather than failing.

    Claude status comes from the documented 'claude mcp list' command (via
    lib/DevKit-McpList.ps1 - never by parsing Claude's internal config).
    Kimi Code has no headless status command (its /mcp status view is
    TUI-only), so its servers are read from the documented config files
    (~/.kimi-code/mcp.json and <project>/.kimi-code/mcp.json) and reported
    as Configured/Disabled/RequiresAuth rather than pretending to know live
    connection state.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
#>

# Prevent double-loading
if ($global:DevKitWidgetCoreLoaded) { return }
$global:DevKitWidgetCoreLoaded = $true

# ==================== SYSTEM METRICS ====================

function ConvertFrom-DevKitNvidiaSmiOutput {
    <#
    .SYNOPSIS
        Parses 'nvidia-smi --query-gpu=temperature.gpu,utilization.gpu
        --format=csv,noheader,nounits' output into a typed object.
    .OUTPUTS
        @{ TempC [double]; Percent [double] } or $null when unparsable.
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Output)

    $line = ($Output -split "`n" | Select-Object -First 1)
    if ($null -eq $line) { return $null }
    if ($line.Trim() -match '^\s*(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)\s*$') {
        return @{ TempC = [double]$Matches[1]; Percent = [double]$Matches[2] }
    }
    return $null
}

$script:GpuReadingCache = $null

function Get-DevKitGpuReading {
    <#
    .SYNOPSIS
        GPU load/temperature from the vendor-bundled sensor paths, in
        preference order: nvidia-smi (temp + util in one call), then the
        stock GPU Engine performance counters (util only). $null fields when
        neither works. Cached per runspace for 10 seconds - a process spawn
        every 2s cycle buys nothing at that resolution.
    #>
    if ($null -ne $script:GpuReadingCache -and ((Get-Date) - $script:GpuReadingCache.At).TotalSeconds -lt 10) {
        return $script:GpuReadingCache.Result
    }
    $result = @{ Percent = $null; TempC = $null; Source = 'None' }

    $smi = Get-DevKitWindowsExecutable -Name 'nvidia-smi'
    if ($smi) {
        try {
            $raw = (& $smi.Source '--query-gpu=temperature.gpu,utilization.gpu' '--format=csv,noheader,nounits' 2>$null | Out-String)
            $parsed = ConvertFrom-DevKitNvidiaSmiOutput -Output $raw
            if ($parsed) {
                $result.Percent = $parsed.Percent
                $result.TempC = $parsed.TempC
                $result.Source = 'NvidiaSmi'
                $script:GpuReadingCache = @{ Result = $result; At = Get-Date }
                return $result
            }
        } catch { }
    }

    try {
        $samples = (Get-Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction Stop).CounterSamples
        $total = ($samples | Measure-Object -Property CookedValue -Sum).Sum
        if ($null -ne $total) {
            $result.Percent = [math]::Min(100, [math]::Round($total, 1))
            $result.Source = 'GpuEngineCounters'
        }
    } catch { }
    $script:GpuReadingCache = @{ Result = $result; At = Get-Date }
    return $result
}

$script:CpuTempCache = $null

function Get-DevKitCpuTempReading {
    <#
    .SYNOPSIS
        Best-effort CPU/system temperature in Celsius: the ACPI thermal-zone
        performance counter first (works unelevated on most Win10/11 boxes),
        then the MSAcpi WMI class (usually admin-only). $null when Windows
        exposes nothing - the UI shows "n/a" rather than inventing a number.
        Cached per runspace for 45 seconds: the thermal counter always waits
        out a full ~1s PDH sample interval, and a temperature that moves over
        tens of seconds doesn't need that spent every 2s cycle.
    #>
    if ($null -ne $script:CpuTempCache -and ((Get-Date) - $script:CpuTempCache.At).TotalSeconds -lt 45) {
        return $script:CpuTempCache.Value
    }
    $reading = $null
    try {
        $samples = (Get-Counter '\Thermal Zone Information(*)\Temperature' -ErrorAction Stop).CounterSamples
        $max = ($samples | Measure-Object -Property CookedValue -Maximum).Maximum
        if ($null -ne $max -and $max -gt 200) {   # sanity: values arrive in Kelvin
            $reading = [math]::Round($max - 273.15, 1)
        }
    } catch { }
    if ($null -eq $reading) {
        try {
            $zones = Get-CimInstance -Namespace 'root/wmi' -Class 'MSAcpi_ThermalZoneTemperature' -ErrorAction Stop
            $maxK = ($zones | Measure-Object -Property CurrentTemperature -Maximum).Maximum
            if ($null -ne $maxK -and $maxK -gt 2000) {  # tenths of Kelvin
                $reading = [math]::Round(($maxK / 10) - 273.15, 1)
            }
        } catch { }
    }
    $script:CpuTempCache = @{ Value = $reading; At = Get-Date }
    return $reading
}

function Get-DevKitSystemMetrics {
    <#
    .SYNOPSIS
        One snapshot of the metrics the widget displays. Any individual
        collector may yield $null; callers render "n/a" for those.
    #>
    # CPU load: Win32_Processor.LoadPercentage first - the PDH '% Processor
    # Time' counter needs two samples from the SAME query handle, and this
    # function opens a fresh one per poll, so its first (only) sample reads
    # ~0% forever. LoadPercentage is a ready-made 1-second average.
    $cpuPercent = $null
    try {
        $load = (Get-CimInstance Win32_Processor -ErrorAction Stop | Measure-Object -Property LoadPercentage -Average).Average
        if ($null -ne $load) { $cpuPercent = [math]::Round([double]$load, 1) }
    } catch { }
    if ($null -eq $cpuPercent) {
        try {
            $cpuPercent = [math]::Round((Get-Counter '\Processor(_Total)\% Processor Time' -ErrorAction Stop).CounterSamples[0].CookedValue, 1)
        } catch { }
    }

    $memPercent = $null; $memUsedGB = $null; $memTotalGB = $null; $uptimeDays = $null
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $memTotalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
        $memFreeGB = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
        $memUsedGB = [math]::Round($memTotalGB - $memFreeGB, 1)
        if ($memTotalGB -gt 0) { $memPercent = [math]::Round(($memUsedGB / $memTotalGB) * 100, 1) }
        if ($os.LastBootUpTime) { $uptimeDays = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 1) }
    } catch { }

    # Every READY fixed/removable drive: pure .NET, microseconds. A full disk
    # breaks builds with symptoms that look like everything except disk space,
    # and USB sticks etc. come and go, so this is re-enumerated every cycle
    # rather than cached. CDRom/Network/Ram/Unknown are skipped - a network
    # drive in particular can hang enumeration for seconds on a dropped share.
    $drives = @()
    try {
        foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
            if (-not $d.IsReady) { continue }
            if ($d.DriveType -notin @('Fixed', 'Removable')) { continue }
            try {
                $drives += [PSCustomObject]@{
                    Name       = ($d.Name.TrimEnd('\'))   # "C:\" -> "C:"
                    FreeBytes  = [double]$d.AvailableFreeSpace
                    TotalBytes = [double]$d.TotalSize
                }
            } catch { }   # a drive can go not-ready between IsReady check and read (USB race)
        }
    } catch { }

    # System-drive free space kept as scalar fields too, for backward compat
    # with any other reader of this object - derived from the Drives array
    # above rather than a second DriveInfo lookup.
    $diskFreeBytes = $null; $diskTotalBytes = $null
    $sysDrive = $drives | Where-Object { $_.Name -eq $env:SystemDrive } | Select-Object -First 1
    if ($sysDrive) {
        $diskFreeBytes = $sysDrive.FreeBytes
        $diskTotalBytes = $sysDrive.TotalBytes
    }

    # A pending reboot explains a whole class of phantom weirdness. Both keys
    # are the documented sentinels; cached 10 minutes per runspace - the
    # registry-provider Test-Path pair costs ~50ms a cycle for a value that
    # effectively never changes.
    if ($null -eq $script:RebootPendingCache -or ((Get-Date) - $script:RebootPendingCache.At).TotalMinutes -gt 10) {
        $pending = $false
        try {
            $pending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending' -ErrorAction SilentlyContinue) -or
                       (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired' -ErrorAction SilentlyContinue)
        } catch { }
        $script:RebootPendingCache = @{ Value = [bool]$pending; At = Get-Date }
    }
    $rebootPending = $script:RebootPendingCache.Value

    $gpu = Get-DevKitGpuReading

    return [PSCustomObject]@{
        CpuPercent    = $cpuPercent
        CpuTempC      = (Get-DevKitCpuTempReading)
        MemoryPercent = $memPercent
        MemoryUsedGB  = $memUsedGB
        MemoryTotalGB = $memTotalGB
        GpuPercent    = $gpu.Percent
        GpuTempC      = $gpu.TempC
        GpuSource     = $gpu.Source
        DiskFreeBytes = $diskFreeBytes
        DiskTotalBytes = $diskTotalBytes
        Drives        = $drives
        RebootPending = [bool]$rebootPending
        UptimeDays    = $uptimeDays
    }
}

# ==================== NODE PROCESSES & PORTS ====================

function Get-DevKitCommonDevPorts {
    <# The same 18 ports ports/Scan-Ports.ps1 scans - keep in sync with it. #>
    return @(3000, 3001, 3002, 3003, 5173, 5174, 8000, 8080, 8081, 9000, 4200, 5000, 5500, 1337, 5432, 3306, 6379, 27017)
}

function Group-DevKitPortsByProcess {
    <#
    .SYNOPSIS
        Groups listening TCP rows into a pid -> sorted unique port list map.
        Pure (takes pre-fetched rows) so the grouping logic is unit-testable.
    #>
    param([array]$ListenRows)

    $byPid = @{}
    foreach ($row in $ListenRows) {
        # Normalize to [int]: Get-NetTCPConnection yields OwningProcess as
        # UInt32 while Process.Id is Int32, and Hashtable keys compare with
        # strict Object.Equals - a UInt32 key is invisible to an Int32 lookup.
        $procId = [int]$row.OwningProcess
        if (-not $byPid.ContainsKey($procId)) { $byPid[$procId] = @() }
        if ($byPid[$procId] -notcontains $row.LocalPort) {
            $byPid[$procId] += $row.LocalPort
        }
    }
    foreach ($pidKey in @($byPid.Keys)) {
        $byPid[$pidKey] = @($byPid[$pidKey] | Sort-Object)
    }
    return $byPid
}

$script:ExcludedRangesCache = $null
$script:ExcludedRangesAt = [datetime]::MinValue

function Get-DevKitExcludedPortRanges {
    <#
    .SYNOPSIS
        Hyper-V/winnat-reserved TCP port ranges (the reason a port shows
        nothing in netstat yet refuses to bind with EACCES/WinError 10013).
        netsh 'show' needs no admin. Ranges only change with the NAT/network
        service, so the result is cached for 30 minutes per runspace.
    #>
    if ($null -ne $script:ExcludedRangesCache -and ((Get-Date) - $script:ExcludedRangesAt).TotalMinutes -lt 30) {
        return $script:ExcludedRangesCache
    }
    $ranges = @()
    try {
        $netsh = Get-DevKitWindowsExecutable -Name 'netsh'
        if ($netsh) {
            $out = (& $netsh.Source 'interface' 'ipv4' 'show' 'excludedportrange' 'protocol=tcp' 2>$null | Out-String)
            # Direct assignment: the parser returns its array comma-wrapped,
            # so @() here would nest it one level deep.
            $ranges = ConvertFrom-DevKitExcludedPortRanges -Output $out
        }
    } catch { }
    $script:ExcludedRangesCache = $ranges
    $script:ExcludedRangesAt = Get-Date
    return $ranges
}

function Test-DevKitPortExcluded {
    <# True when <port> sits inside any of the supplied reserved ranges. #>
    param([int]$Port, [array]$Ranges)
    foreach ($r in $Ranges) { if ($Port -ge $r.Start -and $Port -le $r.End) { return $true } }
    return $false
}

function Get-DevKitNodeSnapshot {
    <#
    .SYNOPSIS
        Node.js processes with their listening ports, plus any other process
        listening on a common dev port (so a stray postgres/redis shows up
        too instead of silently looking like "nothing running"). Also flags
        common dev ports that sit inside winnat-reserved ranges (unbindable
        even though nothing listens there).
    #>
    $nodeProcesses = @(Get-Process -Name node -ErrorAction SilentlyContinue)
    $listenRows = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue)
    $portsByPid = Group-DevKitPortsByProcess -ListenRows $listenRows

    $processes = @()
    foreach ($proc in ($nodeProcesses | Sort-Object WorkingSet64 -Descending)) {
        $ports = @()
        if ($portsByPid.ContainsKey($proc.Id)) { $ports = $portsByPid[$proc.Id] }
        $ageMinutes = $null
        try { $ageMinutes = [math]::Round(((Get-Date) - $proc.StartTime).TotalMinutes, 0) } catch { }
        $processes += [PSCustomObject]@{
            Pid        = $proc.Id
            Name       = $proc.ProcessName
            MemoryMB   = [math]::Round($proc.WorkingSet64 / 1MB, 0)
            CpuSeconds = if ($proc.CPU) { [math]::Round($proc.CPU, 1) } else { 0 }
            AgeMinutes = $ageMinutes
            Ports      = $ports
        }
    }

    $nodePids = @($nodeProcesses | ForEach-Object { $_.Id })
    $otherPorts = @()
    $common = Get-DevKitCommonDevPorts
    foreach ($row in $listenRows) {
        if ($row.LocalPort -notin $common) { continue }
        if ($nodePids -contains $row.OwningProcess) { continue }
        if ($otherPorts | Where-Object { $_.Port -eq $row.LocalPort }) { continue }
        $ownerName = ''
        try { $ownerName = (Get-Process -Id $row.OwningProcess -ErrorAction Stop).ProcessName } catch { }
        $otherPorts += [PSCustomObject]@{ Port = $row.LocalPort; ProcessName = $ownerName; Pid = $row.OwningProcess }
    }

    $excludedRanges = @(Get-DevKitExcludedPortRanges)
    $reservedPorts = @($common | Where-Object { Test-DevKitPortExcluded -Port $_ -Ranges $excludedRanges })

    return [PSCustomObject]@{
        Processes     = @($processes | Sort-Object MemoryMB -Descending)
        OtherPorts    = @($otherPorts | Sort-Object Port)
        ReservedPorts = $reservedPorts
    }
}

# ==================== PROCESS MANAGEMENT (CLICKABLE GAUGES) ====================
# Pure-logic backend for the clickable CPU/MEM/GPU gauge windows: process
# classification (what is safe to kill), top-CPU / top-memory / top-GPU
# collectors, a defense-in-depth kill wrapper, and a working-set trim.
# Everything here is safe to run in the background MTA runspace: nothing
# throws, and every collector degrades to an honest empty result.

# Process-name sets for Get-DevKitProcessClassification, kept at script scope
# so the per-process classification loop in the top-N collectors doesn't
# reallocate them hundreds of times a cycle. All entries lowercase, no .exe.
$script:DevKitSystemProcessNames = @(
    # Windows dies or misbehaves without these - never kill.
    'system', 'idle', 'registry', 'secure system', 'memory compression',
    'smss', 'csrss', 'wininit', 'winlogon', 'services', 'svchost', 'lsass',
    'lsaiso', 'fontdrvhost', 'dwm', 'winwer', 'werfault', 'sihost',
    'taskhostw', 'runtimebroker', 'msmpeng', 'nissrv', 'searchindexer',
    'spoolsv'
)
$script:DevKitSafeProcessNames = @(
    # Well-known user/dev apps that close cleanly when killed.
    'node', 'npm', 'npx', 'esbuild', 'vite', 'next', 'deno', 'bun',
    'code', 'cursor', 'chrome', 'msedge', 'firefox', 'brave', 'opera',
    'slack', 'discord', 'teams', 'spotify', 'notepad', 'notepad++',
    'obsidian'
)

function Get-DevKitProcessClassification {
    <#
    .SYNOPSIS
        Classifies a process name for the gauge windows' kill affordances:
        'System' (never kill - Windows dies/misbehaves without it), 'Safe'
        (well-known user/dev app that closes cleanly), or 'Caution'
        (everything else - killable, but the user should think first).
        Matching is case-insensitive and a trailing '.exe' is stripped.
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Name)

    $normalized = $Name.Trim().ToLowerInvariant()
    if ($normalized.EndsWith('.exe')) { $normalized = $normalized.Substring(0, $normalized.Length - 4) }
    if ($script:DevKitSystemProcessNames -contains $normalized) { return 'System' }
    if ($script:DevKitSafeProcessNames -contains $normalized) { return 'Safe' }
    return 'Caution'
}

function Get-DevKitTopCpuProcesses {
    <#
    .SYNOPSIS
        The $Count busiest processes by current CPU usage: two Get-Process
        snapshots $SampleSeconds apart, percent = delta CPU seconds /
        (sample window * logical core count) * 100, capped at 100. Processes
        that exited between the snapshots (or whose PID got recycled, seen
        as a negative delta) are skipped. Never throws - a failed snapshot
        just yields fewer/zero rows.
    #>
    param([int]$Count = 15, [double]$SampleSeconds = 1)

    if ($SampleSeconds -lt 0.2) { $SampleSeconds = 0.2 }
    $cores = [Environment]::ProcessorCount
    if ($cores -lt 1) { $cores = 1 }

    $first = @{}
    try {
        foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
            $cpu = $null
            try { $cpu = $p.CPU } catch { }   # .CPU throws for a few protected processes
            if ($null -ne $cpu) { $first[$p.Id] = [double]$cpu }
        }
    } catch { }

    Start-Sleep -Seconds $SampleSeconds

    $rows = @()
    try {
        foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
            if (-not $first.ContainsKey($p.Id)) { continue }   # started after the first snapshot
            $cpuNow = $null
            try { $cpuNow = $p.CPU } catch { continue }        # exited between snapshots
            if ($null -eq $cpuNow) { continue }
            $delta = [double]$cpuNow - $first[$p.Id]
            if ($delta -lt 0) { continue }                     # PID recycled mid-sample
            $pct = ($delta / ($SampleSeconds * $cores)) * 100
            if ($pct -gt 100) { $pct = 100 }
            $memMB = 0
            try { $memMB = [math]::Round($p.WorkingSet64 / 1MB, 0) } catch { }
            $rows += [PSCustomObject]@{
                Name           = $p.ProcessName
                Pid            = $p.Id
                CpuPercent     = [math]::Round($pct, 1)
                MemoryMB       = $memMB
                Classification = (Get-DevKitProcessClassification -Name $p.ProcessName)
            }
        }
    } catch { }
    return @($rows | Sort-Object CpuPercent -Descending | Select-Object -First $Count)
}

function Get-DevKitTopMemoryProcesses {
    <#
    .SYNOPSIS
        The $Count largest processes by working set, plus the machine-wide
        memory totals (from Win32_OperatingSystem - the same source
        Get-DevKitSystemMetrics uses) for the memory gauge window's header.
        Never throws.
    #>
    param([int]$Count = 15)

    $result = [PSCustomObject]@{ Processes = @(); TotalGB = $null; UsedGB = $null; FreeGB = $null }
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $result.TotalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
        $result.FreeGB = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
        $result.UsedGB = [math]::Round($result.TotalGB - $result.FreeGB, 1)
    } catch { }

    $rows = @()
    try {
        foreach ($p in @(Get-Process -ErrorAction SilentlyContinue | Sort-Object WorkingSet64 -Descending | Select-Object -First $Count)) {
            $rows += [PSCustomObject]@{
                Name           = $p.ProcessName
                Pid            = $p.Id
                MemoryMB       = [math]::Round($p.WorkingSet64 / 1MB, 0)
                Classification = (Get-DevKitProcessClassification -Name $p.ProcessName)
            }
        }
    } catch { }
    $result.Processes = $rows
    return $result
}

function Stop-DevKitProcessById {
    <#
    .SYNOPSIS
        Defense-in-depth kill for the gauge windows' per-row kill buttons:
        re-classifies the process at click time and REFUSES when it is a
        Windows system process or the PID no longer exists - the UI showing
        a kill button is never enough on its own, since the row's snapshot
        may be stale. Never throws; the Note tells the UI what happened.
    #>
    # NOTE: the parameter cannot literally be named $Pid - $PID is a
    # read-only automatic variable, so binding would throw "Cannot overwrite
    # variable Pid". The 'Pid' ALIAS keeps the documented -Pid call syntax
    # the widget codes against.
    param([Parameter(Mandatory = $true)][Alias('Pid')][int]$ProcessId)

    $result = [PSCustomObject]@{ Stopped = $false; Note = '' }
    $proc = $null
    try { $proc = Get-Process -Id $ProcessId -ErrorAction Stop } catch { }
    if (-not $proc) {
        $result.Note = "Process $ProcessId no longer exists."
        return $result
    }
    if ((Get-DevKitProcessClassification -Name $proc.ProcessName) -eq 'System') {
        $result.Note = "Refusing to kill $($proc.ProcessName) (pid $ProcessId): it is a Windows system process."
        return $result
    }
    $name = $proc.ProcessName
    try {
        Stop-Process -Id $ProcessId -Force -ErrorAction Stop
        $result.Stopped = $true
        $result.Note = "Stopped $name (pid $ProcessId)."
    } catch {
        $result.Note = "Could not stop $name (pid $ProcessId): $($_.Exception.Message)"
    }
    return $result
}

function Invoke-DevKitFreeMemory {
    <#
    .SYNOPSIS
        Safe memory reclaim for the memory gauge window's "Free memory"
        button: calls psapi.dll's EmptyWorkingSet on every accessible
        process, which trims pageable working-set pages back to the OS
        WITHOUT killing anything (Windows does this itself under pressure;
        doing it on demand just front-runs it). System-classified processes
        are skipped, and processes that refuse (access denied, exited) are
        skipped silently. Returns how much was trimmed. Never throws.
    #>
    $result = [PSCustomObject]@{ FreedMB = 0; TrimmedProcesses = 0; Note = '' }

    # The P/Invoke type is defined once per runspace (the -as [type] probe
    # survives repeat calls and repeat dot-sources; a bare Add-Type would
    # throw "type already exists" on the second call).
    if (-not ('DevKitWidgetPsApi' -as [type])) {
        try {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DevKitWidgetPsApi {
    [DllImport("psapi.dll", SetLastError = true)]
    public static extern bool EmptyWorkingSet(IntPtr hProcess);
}
'@ -ErrorAction Stop
        } catch { }
    }
    if (-not ('DevKitWidgetPsApi' -as [type])) {
        $result.Note = 'Working-set trim unavailable (psapi interop failed to load).'
        return $result
    }

    $freedBytes = 0L
    $trimmed = 0
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
        if ((Get-DevKitProcessClassification -Name $p.ProcessName) -eq 'System') { continue }
        $wsBefore = 0L; $handle = [IntPtr]::Zero
        try { $wsBefore = $p.WorkingSet64; $handle = $p.Handle } catch { continue }
        if ($handle -eq [IntPtr]::Zero) { continue }
        $ok = $false
        try { $ok = [DevKitWidgetPsApi]::EmptyWorkingSet($handle) } catch { continue }
        if ($ok) {
            $trimmed++
            try {
                $p.Refresh()
                $delta = $wsBefore - $p.WorkingSet64
                if ($delta -gt 0) { $freedBytes += $delta }
            } catch { }
        }
    }
    $result.FreedMB = [math]::Round($freedBytes / 1MB, 1)
    $result.TrimmedProcesses = $trimmed
    $result.Note = "Trimmed working sets on $trimmed processes."
    return $result
}

# ==================== GPU PROCESS USAGE (CLICKABLE GPU GAUGE) ====================

function ConvertFrom-DevKitGpuEngineInstance {
    <#
    .SYNOPSIS
        Parses a '\GPU Engine(*)' performance-counter instance name into its
        owning PID and engine type. Names look like 'pid_4056_engtype_3D' or
        'pid_1234_engtype_Compute_0'; some builds prefix an adapter identity
        ('luid_0x00000000_0x0000974E_phys_0_eng_2_pid_4056_engtype_3D').
        Engine types can themselves contain underscores ('Compute_0'), so the
        engine is everything after 'engtype_' to the end. Anything without a
        usable pid_/engtype_ pair (including luid-only instances with no pid)
        returns $null. Pure - unit-testable.
    .OUTPUTS
        @{ Pid [int]; EngineType [string] } or $null.
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$InstanceName)

    $s = $InstanceName.Trim()
    # Anchor pid_ on a token boundary so a stray 'pid_' inside a luid hex
    # chunk can't produce a bogus match, and require digits after it.
    if ($s -notmatch '(?:^|_)pid_(\d+)(?=_|$)') { return $null }
    $procId = [int]$Matches[1]
    if ($s -notmatch 'engtype_(\S+)\s*$') { return $null }
    $engine = $Matches[1]
    if ([string]::IsNullOrWhiteSpace($engine)) { return $null }
    return @{ Pid = $procId; EngineType = $engine }
}

function ConvertFrom-DevKitNvidiaSmiAdapterOutput {
    <#
    .SYNOPSIS
        Parses 'nvidia-smi --query-gpu=name,temperature.gpu,utilization.gpu,
        memory.used,memory.total --format=csv,noheader,nounits' output into a
        typed object. The name field is free text (it comes first so the
        numeric tail stays anchored); 'N/A' fields make the line unparsable.
    .OUTPUTS
        @{ Name; TempC [double]; Percent [double]; MemUsedMB [double];
           MemTotalMB [double] } or $null when unparsable.
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Output)

    $line = ($Output -split "`n" | Select-Object -First 1)
    if ($null -eq $line) { return $null }
    if ($line.Trim() -match '^\s*(?<name>.+?)\s*,\s*(?<temp>\d+(?:\.\d+)?)\s*,\s*(?<util>\d+(?:\.\d+)?)\s*,\s*(?<used>\d+(?:\.\d+)?)\s*,\s*(?<total>\d+(?:\.\d+)?)\s*$') {
        return @{
            Name       = $Matches.name.Trim()
            TempC      = [double]$Matches.temp
            Percent    = [double]$Matches.util
            MemUsedMB  = [double]$Matches.used
            MemTotalMB = [double]$Matches.total
        }
    }
    return $null
}

$script:GpuAdapterCache = $null

function Get-DevKitGpuAdapterInfo {
    <#
    .SYNOPSIS
        Adapter-level summary for the GPU gauge window: name, utilization,
        temperature, and VRAM used/total. Follows the Get-DevKitGpuReading
        pattern - a single nvidia-smi spawn (all five fields in one query),
        cached per runspace for 10 seconds so the spawn cadence never exceeds
        the metrics cycle's existing one. Without nvidia-smi, util/temp fall
        back to the (itself cached) Get-DevKitGpuReading, whose counter path
        exposes no name or VRAM - those fields stay $null and the UI shows
        "n/a" rather than inventing a number.
    #>
    if ($null -ne $script:GpuAdapterCache -and ((Get-Date) - $script:GpuAdapterCache.At).TotalSeconds -lt 10) {
        return $script:GpuAdapterCache.Result
    }
    $result = @{ Name = $null; UtilPercent = $null; TempC = $null; MemUsedMB = $null; MemTotalMB = $null; Source = 'None' }

    $smi = Get-DevKitWindowsExecutable -Name 'nvidia-smi'
    if ($smi) {
        try {
            $raw = (& $smi.Source '--query-gpu=name,temperature.gpu,utilization.gpu,memory.used,memory.total' '--format=csv,noheader,nounits' 2>$null | Out-String)
            $parsed = ConvertFrom-DevKitNvidiaSmiAdapterOutput -Output $raw
            if ($parsed) {
                $result.Name = $parsed.Name
                $result.UtilPercent = $parsed.Percent
                $result.TempC = $parsed.TempC
                $result.MemUsedMB = $parsed.MemUsedMB
                $result.MemTotalMB = $parsed.MemTotalMB
                $result.Source = 'NvidiaSmi'
                $script:GpuAdapterCache = @{ Result = $result; At = Get-Date }
                return $result
            }
        } catch { }
    }

    $reading = Get-DevKitGpuReading
    if ($reading.Source -ne 'None') {
        $result.UtilPercent = $reading.Percent
        $result.TempC = $reading.TempC
        $result.Source = $reading.Source
    }
    $script:GpuAdapterCache = @{ Result = $result; At = Get-Date }
    return $result
}

function Get-DevKitGpuProcessUsage {
    <#
    .SYNOPSIS
        One snapshot for the clickable GPU gauge window: the adapter summary
        (Get-DevKitGpuAdapterInfo) plus the $Count heaviest per-process GPU
        users. Per-process usage aggregates every '\GPU Engine(*)\Utilization
        Percentage' counter sample by owning PID (via
        ConvertFrom-DevKitGpuEngineInstance), rounds to 1 decimal, drops ~0
        values, and caps at 100 (a process can legitimately spread across
        several engine types). Names come from a single Get-Process pass;
        PIDs that already exited are reported as '(exited)'. Never throws -
        no GPU counters means an empty Processes list, not an error.
    #>
    param([int]$Count = 15)

    $info = Get-DevKitGpuAdapterInfo
    $adapter = [PSCustomObject]@{
        Name        = $info.Name
        UtilPercent = $info.UtilPercent
        TempC       = $info.TempC
        MemUsedMB   = $info.MemUsedMB
        MemTotalMB  = $info.MemTotalMB
        Source      = $info.Source
    }

    $byPid = @{}
    try {
        $samples = @((Get-Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction Stop).CounterSamples)
        foreach ($s in $samples) {
            $parsed = ConvertFrom-DevKitGpuEngineInstance -InstanceName $s.InstanceName
            if (-not $parsed) { continue }
            if (-not $byPid.ContainsKey($parsed.Pid)) { $byPid[$parsed.Pid] = 0.0 }
            $byPid[$parsed.Pid] += [double]$s.CookedValue
        }
    } catch { }

    $processes = @()
    if ($byPid.Count -gt 0) {
        $names = @{}
        foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) { $names[$p.Id] = $p.ProcessName }
        foreach ($procId in @($byPid.Keys)) {
            $pct = [math]::Round([math]::Min(100, $byPid[$procId]), 1)
            if ($pct -le 0) { continue }
            $name = if ($names.ContainsKey($procId)) { $names[$procId] } else { '(exited)' }
            $processes += [PSCustomObject]@{
                Name           = $name
                Pid            = [int]$procId
                GpuPercent     = $pct
                Classification = (Get-DevKitProcessClassification -Name $name)
            }
        }
        $processes = @($processes | Sort-Object GpuPercent -Descending | Select-Object -First $Count)
    }

    return @{ Adapter = $adapter; Processes = $processes }
}

# ==================== CLAUDE CODE MCP STATUS ====================

function ConvertFrom-DevKitClaudeMcpLine {
    <#
    .SYNOPSIS
        Parses one 'claude mcp list' output line into name + health status.
        Lines look like:
          sequential-thinking: cmd /c npx -y @modelcontextprotocol/... - <check> Connected
          claude.ai Stripe: https://mcp.stripe.com - <cross> Failed to connect
          some-server: https://... - <warn> Needs authentication
        The check glyphs vary by CLI version (check/cross/warn marks), so the
        status words are matched rather than the glyphs.
    .OUTPUTS
        @{ Name; Status ('Connected'|'Disconnected'|'RequiresAuth'|'Unknown');
           Target } or $null for non-server lines (headers, blanks).
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Line)

    if ($Line.Trim() -notmatch '^(?<name>\S[^:\r\n]*):\s+(?<rest>\S.*)$') { return $null }
    $name = $Matches.name.Trim()
    $rest = $Matches.rest.Trim()

    $status = 'Unknown'
    if ($rest -match '(?i)connected') { $status = 'Connected' }
    elseif ($rest -match '(?i)needs? authentication|requires? auth|unauthorized') { $status = 'RequiresAuth' }
    elseif ($rest -match '(?i)failed|error|unreachable|timed? ?out') { $status = 'Disconnected' }

    $target = ($rest -split '\s+-\s+')[0]
    return @{ Name = $name; Status = $status; Target = $target }
}

function Get-DevKitClaudeMcpStatus {
    <#
    .SYNOPSIS
        Claude Code CLI presence + MCP servers split into user scope (this
        machine) and project scope, each with a health badge. Uses
        lib/DevKit-McpList.ps1's neutral-vs-project diff - the same source
        the Agents & MCP tools use.
    #>
    param([string]$ProjectPath)

    $result = [PSCustomObject]@{
        CliInstalled = $false
        Version      = $null
        Servers      = @()
        ErrorMessage = $null
    }

    $claude = Get-DevKitWindowsExecutable -Name 'claude'
    if (-not $claude) { return $result }
    $result.CliInstalled = $true
    try {
        $versionOut = (& $claude.Source '--version' 2>$null | Out-String).Trim()
        if ($versionOut) { $result.Version = ($versionOut -split "`n")[0].Trim() }
    } catch { }

    if ([string]::IsNullOrWhiteSpace($ProjectPath) -or -not (Test-Path -LiteralPath $ProjectPath)) {
        $list = Invoke-DevKitMcpList -Path $env:TEMP
        if (-not $list.Success) { $result.ErrorMessage = $list.ErrorMessage; return $result }
        foreach ($line in $list.Output) {
            $parsed = ConvertFrom-DevKitClaudeMcpLine -Line $line
            if ($parsed) {
                $result.Servers += [PSCustomObject]@{ Name = $parsed.Name; Scope = 'User'; Status = $parsed.Status; Target = $parsed.Target }
            }
        }
        return $result
    }

    $diff = Get-DevKitMcpScopeDiff -ProjectPath $ProjectPath
    if (-not $diff.Success) { $result.ErrorMessage = $diff.ErrorMessage; return $result }
    foreach ($name in $diff.UserScope.Keys) {
        $parsed = ConvertFrom-DevKitClaudeMcpLine -Line $diff.UserScope[$name]
        if ($parsed) {
            $result.Servers += [PSCustomObject]@{ Name = $parsed.Name; Scope = 'User'; Status = $parsed.Status; Target = $parsed.Target }
        }
    }
    foreach ($name in $diff.ProjectScope.Keys) {
        $parsed = ConvertFrom-DevKitClaudeMcpLine -Line $diff.ProjectScope[$name]
        if ($parsed) {
            $result.Servers += [PSCustomObject]@{ Name = $parsed.Name; Scope = 'Project'; Status = $parsed.Status; Target = $parsed.Target }
        }
    }
    return $result
}

# ==================== KIMI CODE MCP STATUS ====================

function ConvertFrom-DevKitKimiMcpConfig {
    <#
    .SYNOPSIS
        Turns one parsed mcp.json document (the object under "mcpServers")
        into widget rows. Pure - file reading happens in the caller.
        Per https://www.kimi.com/code/docs/en/kimi-code-cli/customization/mcp.html:
        stdio entries carry "command"; HTTP entries "url"; SSE adds
        transport="sse"; enabled=$false disables; bearerTokenEnvVar names an
        env var holding the token (missing var => RequiresAuth). Live
        connection state is TUI-only, so "Configured" is the honest healthy
        badge here.
    #>
    param(
        $McpServers,                      # PSCustomObject from ConvertFrom-Json (.mcpServers), or $null
        [Parameter(Mandatory = $true)][string]$Scope
    )

    $rows = @()
    if ($null -eq $McpServers) { return $rows }
    foreach ($prop in $McpServers.PSObject.Properties) {
        $entry = $prop.Value
        $transport = 'http'
        if ($entry.transport -eq 'sse') { $transport = 'sse' }
        elseif ($entry.command) { $transport = 'stdio' }

        $status = 'Configured'
        if ($null -ne $entry.enabled -and -not [bool]$entry.enabled) {
            $status = 'Disabled'
        } elseif ($entry.bearerTokenEnvVar) {
            $envName = [string]$entry.bearerTokenEnvVar
            if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($envName))) {
                $status = 'RequiresAuth'
            }
        }

        $target = if ($entry.url) { [string]$entry.url } elseif ($entry.command) { [string]$entry.command } else { '' }
        $rows += [PSCustomObject]@{
            Name      = [string]$prop.Name
            Scope     = $Scope
            Status    = $status
            Transport = $transport
            Target    = $target
        }
    }
    return $rows
}

function Read-DevKitKimiMcpFile {
    <# Returns the parsed mcpServers object of one mcp.json, or $null. Never throws. #>
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $doc = (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop) | ConvertFrom-Json -ErrorAction Stop
        return $doc.mcpServers
    } catch {
        return $null
    }
}

function Get-DevKitKimiMcpStatus {
    <#
    .SYNOPSIS
        Kimi Code CLI presence + MCP servers from the documented config
        files: user level ($KIMI_CODE_HOME/mcp.json or ~/.kimi-code/mcp.json)
        and project level (<project>/.kimi-code/mcp.json, which overrides
        same-named user entries).
    #>
    param([string]$ProjectPath)

    $result = [PSCustomObject]@{
        CliInstalled = $false
        Version      = $null
        Servers      = @()
        ErrorMessage = $null
    }

    $kimi = Get-DevKitWindowsExecutable -Name 'kimi'
    if (-not $kimi) { return $result }
    $result.CliInstalled = $true
    try {
        $versionOut = (& $kimi.Source '--version' 2>$null | Out-String).Trim()
        if ($versionOut) { $result.Version = ($versionOut -split "`n")[0].Trim() }
    } catch { }

    $userRows = @()
    $kimiHome = if ($env:KIMI_CODE_HOME) { $env:KIMI_CODE_HOME } else { Join-Path $HOME '.kimi-code' }
    $userConfig = Read-DevKitKimiMcpFile -Path (Join-Path $kimiHome 'mcp.json')
    if ($userConfig) { $userRows = @(ConvertFrom-DevKitKimiMcpConfig -McpServers $userConfig -Scope 'User') }

    $projectRows = @()
    if (-not [string]::IsNullOrWhiteSpace($ProjectPath) -and (Test-Path -LiteralPath $ProjectPath)) {
        $projectConfig = Read-DevKitKimiMcpFile -Path (Join-Path $ProjectPath '.kimi-code\mcp.json')
        if ($projectConfig) { $projectRows = @(ConvertFrom-DevKitKimiMcpConfig -McpServers $projectConfig -Scope 'Project') }
    }

    # Project entries override same-named user entries (documented behavior).
    $result.Servers = @($userRows | Where-Object { $row = $_; -not ($projectRows | Where-Object { $_.Name -eq $row.Name }) }) + $projectRows
    return $result
}

function Get-DevKitMcpWidgetReport {
    <#
    .SYNOPSIS
        One call producing the full MCP status model for the widget's two
        expandable boxes. Designed to run in the widget's background runspace
        (claude.exe health checks take seconds); returns only plain
        hashtables/arrays/strings so it crosses the runspace boundary cleanly.
    #>
    param([string]$ProjectPath)

    $claude = Get-DevKitClaudeMcpStatus -ProjectPath $ProjectPath
    $kimi = Get-DevKitKimiMcpStatus -ProjectPath $ProjectPath
    return @{
        Claude = @{
            CliInstalled = $claude.CliInstalled
            Version      = $claude.Version
            ErrorMessage = $claude.ErrorMessage
            Servers      = @($claude.Servers | ForEach-Object {
                @{ Name = $_.Name; Scope = $_.Scope; Status = $_.Status; Target = $_.Target }
            })
        }
        Kimi = @{
            CliInstalled = $kimi.CliInstalled
            Version      = $kimi.Version
            ErrorMessage = $kimi.ErrorMessage
            Servers      = @($kimi.Servers | ForEach-Object {
                @{ Name = $_.Name; Scope = $_.Scope; Status = $_.Status; Target = $_.Target; Transport = $_.Transport }
            })
        }
    }
}

# ==================== SYSTEM JUNK ====================
# Size logic mirrors maintenance/Clear-DiskJunk.ps1's scan (same paths, same
# COM recycle-bin read). The clean below is now fully GUI-driven and covers
# everything the widget dials advertise: user temp + Recycle Bin always, and
# Windows\Temp + the Windows Update download cache when elevated (attempted
# silently; non-admin runs report them via SkippedNeedsAdmin instead). What
# still separates this from the real Clear-DiskJunk tool is the admin-heavy
# machinery: DISM/WinSxS and service stop/start stay with the terminal tool,
# which the widget launches via "Cleanup Tool...".

function Get-DevKitJunkPathSize {
    <#
    .SYNOPSIS
        Recursive file-size total of one folder, best-effort: unreadable
        subtrees are skipped via -ErrorAction SilentlyContinue and a broken
        root enumeration counts as 0 rather than aborting the whole scan.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $total = 0
    try {
        $items = Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue
        foreach ($item in $items) { $total += $item.Length }
    } catch { }
    return $total
}

function Get-DevKitRecycleBinSize {
    <# Shell.Application COM, same source Clear-DiskJunk.ps1 uses. Silent: this runs in a background runspace. #>
    $shell = $null
    try {
        $shell = New-Object -ComObject Shell.Application
        $recycleBin = $shell.Namespace(10)
        if (-not $recycleBin) { return 0 }
        $total = 0
        foreach ($item in $recycleBin.Items()) { $total += $item.Size }
        return $total
    } catch {
        return 0
    } finally {
        if ($shell) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
    }
}

function Get-DevKitSystemJunk {
    <#
    .SYNOPSIS
        Total reclaimable junk across the user + Windows temp folders, the
        Windows Update download cache, and the Recycle Bin. Never throws;
        slow (recursive enumeration) - run it in the background runspace.
    #>
    $tempPaths = @($env:TEMP, (Join-Path $env:SystemRoot 'Temp')) | Select-Object -Unique
    $wuCachePath = Join-Path (Join-Path $env:SystemRoot 'SoftwareDistribution') 'Download'
    $tempBytes = 0
    foreach ($p in $tempPaths) { $tempBytes += Get-DevKitJunkPathSize -Path $p }
    $wuBytes = Get-DevKitJunkPathSize -Path $wuCachePath
    $recycleBytes = Get-DevKitRecycleBinSize
    return [PSCustomObject]@{
        TempBytes    = $tempBytes
        WuBytes      = $wuBytes
        RecycleBytes = $recycleBytes
        TotalBytes   = $tempBytes + $wuBytes + $recycleBytes
    }
}

function Clear-DevKitSystemJunk {
    <#
    .SYNOPSIS
        The GUI-driven junk clean behind the widget's junk dial: deletes the
        CONTENTS of the user temp folder and empties the Recycle Bin (always
        works unelevated), and - when elevated - also clears Windows\Temp
        and the Windows Update SoftwareDistribution\Download cache contents.
        Non-admin runs skip those two admin-gated categories and report them
        in SkippedNeedsAdmin so the UI can say why they're untouched. What
        this still does NOT do (vs the real Clear-DiskJunk tool): DISM/
        WinSxS and service stop/start. Every category is measured before/
        after so "freed X" and the per-category breakdown stay honest.
        Never throws; designed for the background runspace.
    .OUTPUTS
        BytesBefore/BytesAfter/FreedBytes (totals, as before), plus
        TempUserFreed/TempWindowsFreed/WuCacheFreed/RecycleFreed per
        category and SkippedNeedsAdmin (category names skipped because the
        process is not elevated: 'Windows Temp', 'Windows Update Cache').
    #>
    $userTempPath = $env:TEMP
    $windowsTempPath = Join-Path $env:SystemRoot 'Temp'
    $wuCachePath = Join-Path (Join-Path $env:SystemRoot 'SoftwareDistribution') 'Download'

    $isAdmin = $false
    try { $isAdmin = Test-DevKitAdmin } catch { }
    $skippedNeedsAdmin = @()
    if (-not $isAdmin) { $skippedNeedsAdmin = @('Windows Temp', 'Windows Update Cache') }

    # Before-snapshot per category (admin categories only when elevated -
    # the delete would silently no-op anyway, so skip the slow enumeration).
    $tempUserBefore = Get-DevKitJunkPathSize -Path $userTempPath
    $recycleBefore = Get-DevKitRecycleBinSize
    $tempWindowsBefore = 0
    $wuBefore = 0
    if ($isAdmin) {
        $tempWindowsBefore = Get-DevKitJunkPathSize -Path $windowsTempPath
        $wuBefore = Get-DevKitJunkPathSize -Path $wuCachePath
    }

    $clearPaths = @($userTempPath)
    if ($isAdmin) { $clearPaths += @($windowsTempPath, $wuCachePath) }
    foreach ($p in ($clearPaths | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        if (-not (Test-Path -LiteralPath $p)) { continue }
        try {
            Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue | ForEach-Object {
                Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
        } catch { }
    }
    try { Clear-RecycleBin -Force -ErrorAction SilentlyContinue } catch { }

    $tempUserAfter = Get-DevKitJunkPathSize -Path $userTempPath
    $recycleAfter = Get-DevKitRecycleBinSize
    $tempWindowsAfter = 0
    $wuAfter = 0
    if ($isAdmin) {
        $tempWindowsAfter = Get-DevKitJunkPathSize -Path $windowsTempPath
        $wuAfter = Get-DevKitJunkPathSize -Path $wuCachePath
    }

    $tempUserFreed = $tempUserBefore - $tempUserAfter
    $tempWindowsFreed = $tempWindowsBefore - $tempWindowsAfter
    $wuFreed = $wuBefore - $wuAfter
    $recycleFreed = $recycleBefore - $recycleAfter
    $before = $tempUserBefore + $tempWindowsBefore + $wuBefore + $recycleBefore
    $after = $tempUserAfter + $tempWindowsAfter + $wuAfter + $recycleAfter
    $freed = $before - $after
    # Files appear in temp between the two measurements all the time; a
    # negative delta means "grew while cleaning", not "freed negative bytes".
    if ($freed -lt 0) { $freed = 0 }
    if ($tempUserFreed -lt 0) { $tempUserFreed = 0 }
    if ($tempWindowsFreed -lt 0) { $tempWindowsFreed = 0 }
    if ($wuFreed -lt 0) { $wuFreed = 0 }
    if ($recycleFreed -lt 0) { $recycleFreed = 0 }
    return [PSCustomObject]@{
        BytesBefore       = $before
        BytesAfter        = $after
        FreedBytes        = $freed
        TempUserFreed     = $tempUserFreed
        TempWindowsFreed  = $tempWindowsFreed
        WuCacheFreed      = $wuFreed
        RecycleFreed      = $recycleFreed
        SkippedNeedsAdmin = $skippedNeedsAdmin
    }
}

# ==================== GIT REPO OVERVIEW ====================
# Shell-out collectors for the GitHub flyout. They never throw and never
# invent state: git missing / not a repo come back as honest Error notes the
# UI renders as dim text.

function Get-DevKitGitLaneColor {
    <#
    .SYNOPSIS
        Bright-on-gunmetal lane palette for the commit graph. Returned as hex
        strings so the value crosses the widget's background runspace boundary
        cleanly; the UI turns them into frozen brushes.
    #>
    param([int]$Lane)
    $palette = @('#4CC2FF', '#3EDD8F', '#B084F5', '#FFB020', '#FF7A72', '#2BD9C7', '#F472B6', '#A3E635')
    return $palette[$Lane % $palette.Count]
}

function ConvertFrom-DevKitGitDecorations {
    <#
    .SYNOPSIS
        Parses git's %d decoration string (' (HEAD -> main, origin/main,
        tag: v1.0)') into a ref list: @{ Name; Kind ('head'|'tag'|'branch') }.
        'HEAD -> x' marks the commit the working tree sits on; bare 'HEAD' is
        a detached checkout. Remote branches stay Kind 'branch' - telling
        origin/x apart from a local feature/x needs the remote list, which the
        caller doesn't collect.
    #>
    param([AllowEmptyString()][string]$Raw)

    $refs = @()
    $text = if ($Raw) { $Raw.Trim() } else { '' }
    if ($text.StartsWith('(') -and $text.EndsWith(')')) { $text = $text.Substring(1, $text.Length - 2) }
    if ([string]::IsNullOrWhiteSpace($text)) { return ,$refs }
    foreach ($part in ($text -split ',\s*')) {
        if ($part -match '^HEAD -> (.+)$') {
            $refs += @{ Name = $Matches[1]; Kind = 'head' }
        } elseif ($part -eq 'HEAD') {
            $refs += @{ Name = 'HEAD'; Kind = 'head' }
        } elseif ($part -match '^tag:\s*(.+)$') {
            $refs += @{ Name = $Matches[1]; Kind = 'tag' }
        } else {
            $refs += @{ Name = $part; Kind = 'branch' }
        }
    }
    return ,$refs
}

function ConvertFrom-DevKitGitLogOutput {
    <#
    .SYNOPSIS
        Parses 'git log --all --topo-order --pretty=format:%x1e%H%x1f%P%x1f
        %an%x1f%ar%x1f%d%x1f%s' output into plain hashtables (one per commit,
        children before parents): Hash, ShortHash, Parents (string[]), Author,
        When (relative), Refs (from ConvertFrom-DevKitGitDecorations), Subject,
        IsHead. Field/record separators are ASCII unit/record separators so
        subjects and author names can never break the parse.
    #>
    param([AllowEmptyString()][string]$Output)

    $commits = @()
    if ([string]::IsNullOrWhiteSpace($Output)) { return ,$commits }
    $rs = [char]0x1e; $us = [char]0x1f
    foreach ($record in ($Output -split $rs)) {
        $rec = $record.TrimStart("`r", "`n")
        if ([string]::IsNullOrWhiteSpace($rec)) { continue }
        $fields = $rec -split $us
        if ($fields.Count -lt 6) { continue }
        $refs = ConvertFrom-DevKitGitDecorations -Raw $fields[4]
        $commits += @{
            Hash      = $fields[0].Trim()
            ShortHash = $fields[0].Substring(0, [Math]::Min(7, $fields[0].Length))
            Parents   = @($fields[1] -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            Author    = $fields[2]
            When      = $fields[3]
            Refs      = $refs
            Subject   = $fields[5].TrimEnd()
            IsHead    = [bool]($refs | Where-Object { $_.Kind -eq 'head' } | Select-Object -First 1)
        }
    }
    return ,$commits
}

function ConvertTo-DevKitGitGraphLayout {
    <#
    .SYNOPSIS
        Lane assignment for a topo-ordered commit list (children before
        parents): each commit gets a lane column, and each child->parent edge
        a link the WPF renderer draws as a straight line (same lane) or a
        smooth S-curve (lane change). A commit expected at several lanes takes
        the leftmost and the extra lanes collapse into it (a fork visually);
        a commit's first parent inherits its lane unless another child already
        claimed one for it (a branch tip joining trunk); every extra parent
        opens a fresh lane (a merge source).
    .OUTPUTS
        @{ Nodes = @(@{ Hash; Row; Lane; Color; Commit }), Links = @(@{
           FromRow; FromLane; ToRow; ToLane; Color; IsMerge }), LaneCount }
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()]$Commits)

    $laneOwners = New-Object 'string[]' 0   # laneOwners[i] = hash expected next at lane i; '' = free
    $nodeByHash = @{}
    $links = New-Object System.Collections.Generic.List[object]
    $row = 0
    foreach ($c in $Commits) {
        $hash = [string]$c.Hash
        $expecting = @()
        for ($i = 0; $i -lt $laneOwners.Count; $i++) { if ($laneOwners[$i] -eq $hash) { $expecting += $i } }
        if ($expecting.Count -gt 0) {
            $lane = ($expecting | Measure-Object -Minimum).Minimum
            foreach ($l in $expecting) { if ($l -ne $lane) { $laneOwners[$l] = '' } }
        } else {
            $lane = -1
            for ($i = 0; $i -lt $laneOwners.Count; $i++) { if ($laneOwners[$i] -eq '') { $lane = $i; break } }
            if ($lane -lt 0) { $lane = $laneOwners.Count; $laneOwners += '' }
        }
        $nodeByHash[$hash] = @{ Hash = $hash; Row = $row; Lane = $lane; Color = (Get-DevKitGitLaneColor -Lane $lane); Commit = $c }

        $parents = @($c.Parents | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($parents.Count -eq 0) {
            $laneOwners[$lane] = ''   # root commit: the lane dies here
        } else {
            $p0 = [string]$parents[0]
            $claimedAt = -1
            for ($i = 0; $i -lt $laneOwners.Count; $i++) { if ($laneOwners[$i] -eq $p0) { $claimedAt = $i; break } }
            if ($claimedAt -lt 0) {
                $laneOwners[$lane] = $p0   # trunk continues down this lane
            } elseif ($lane -lt $claimedAt) {
                # Leftmost lane wins the first-parent line: the trunk stays a
                # straight vertical and the side branch's lane bends into it.
                $laneOwners[$claimedAt] = ''
                $laneOwners[$lane] = $p0
            } else {
                $laneOwners[$lane] = ''   # first parent already owns a lane further left; this one joins it
            }
            foreach ($p in ($parents | Select-Object -Skip 1)) {
                $p = [string]$p
                if ($laneOwners -contains $p) { continue }
                $nl = -1
                for ($i = 0; $i -lt $laneOwners.Count; $i++) { if ($laneOwners[$i] -eq '') { $nl = $i; break } }
                if ($nl -lt 0) { $nl = $laneOwners.Count; $laneOwners += '' }
                $laneOwners[$nl] = $p
            }
        }
        $row++
    }

    $nodes = @($nodeByHash.Values | Sort-Object Row)
    foreach ($n in $nodes) {
        $parents = @($n.Commit.Parents | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $idx = 0
        foreach ($p in $parents) {
            if ($nodeByHash.ContainsKey([string]$p)) {
                $to = $nodeByHash[[string]$p]
                $isMerge = ($idx -gt 0)
                $color = if ($n.Lane -eq $to.Lane) { $n.Color } elseif ($isMerge) { $to.Color } else { $n.Color }
                $links.Add(@{ FromRow = $n.Row; FromLane = $n.Lane; ToRow = $to.Row; ToLane = $to.Lane; Color = $color; FromColor = $n.Color; ToColor = $to.Color; IsMerge = $isMerge })
            }
            $idx++
        }
    }
    $laneCount = 0
    if ($nodes.Count -gt 0) { $laneCount = (($nodes | ForEach-Object Lane | Measure-Object -Maximum).Maximum) + 1 }   # member enumeration: Measure-Object -Property can't see hashtable keys on PS 5.1
    return @{ Nodes = $nodes; Links = $links.ToArray(); LaneCount = $laneCount }
}

function ConvertFrom-DevKitGitStatusOutput {
    <#
    .SYNOPSIS
        Parses 'git status --porcelain' lines into @{ Status; Path } objects.
        Porcelain format is 2 status chars (XY) + one space + the path, except
        rename/copy entries ('R  old/path -> new/path') where we keep the
        destination path (everything after '-> ') as Path since that's the
        file that exists on disk now; nothing downstream needs the old name.
    #>
    param([AllowEmptyString()][string]$Raw)

    $files = @()
    if ([string]::IsNullOrWhiteSpace($Raw)) { return ,$files }
    foreach ($line in ($Raw -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.Length -lt 4) { continue }
        $status = $line.Substring(0, 2)
        $rest = $line.Substring(3)
        $arrow = $rest.IndexOf(' -> ')
        $path = if ($arrow -ge 0) { $rest.Substring($arrow + 4) } else { $rest }
        $files += @{ Status = $status; Path = $path.Trim() }
    }
    return ,$files
}

function Get-DevKitRepoOverview {
    <#
    .SYNOPSIS
        One snapshot of the active project's git state: current branch, ahead/
        behind vs upstream, dirty/stash counts, and - when -IncludeGraph is
        set - a 40-commit parsed log plus its lane layout for the flyout's
        drawn graph. Badge-only refreshes pass -IncludeGraph $false to skip
        the log spawn + parse entirely (GraphSkipped flags that case so the
        UI can tell "not collected" apart from "no commits").
    #>
    param([string]$Path, [bool]$IncludeGraph = $true)

    $result = [PSCustomObject]@{
        IsRepo    = $false
        Branch    = ''
        Ahead     = $null
        Behind    = $null
        DirtyCount = 0
        DirtyFiles = @()
        StashCount = 0
        Commits   = @()
        Graph     = $null
        GraphSkipped = $false
        RemoteUrl = $null
        Error     = $null
    }
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        $result.Error = 'No project selected.'
        return $result
    }
    $git = Get-DevKitWindowsExecutable -Name 'git'
    if (-not $git) {
        $result.Error = 'git not found on PATH.'
        return $result
    }
    try {
        $insideRaw = (& $git.Source '-C' $Path 'rev-parse' '--is-inside-work-tree' 2>&1 | Out-String)
        $inside = $insideRaw.Trim()
        if ($inside -ne 'true') {
            if ($insideRaw -match '(?i)dubious ownership') {
                $result.Error = "git blocked this repo (dubious ownership) - run: git config --global --add safe.directory `"$Path`""
            } else {
                $result.Error = 'Not a git repository.'
            }
            return $result
        }
        $result.IsRepo = $true

        $branch = (& $git.Source '-C' $Path 'branch' '--show-current' 2>$null | Out-String).Trim()
        $result.Branch = if ($branch) { $branch } else { '(detached HEAD)' }

        # Ahead/behind vs upstream (skipped entirely when no upstream is set).
        $ab = (& $git.Source '-C' $Path 'rev-list' '--count' '--left-right' '@{upstream}...HEAD' 2>$null | Out-String).Trim()
        if ($ab -match '^(\d+)\s+(\d+)$') {
            $result.Behind = [int]$Matches[1]
            $result.Ahead = [int]$Matches[2]
        }

        if ($IncludeGraph) {
            $log = (& $git.Source '-C' $Path 'log' '--all' '--topo-order' '-n' '40' '--pretty=format:%x1e%H%x1f%P%x1f%an%x1f%ar%x1f%d%x1f%s' 2>$null | Out-String)
            $commits = ConvertFrom-DevKitGitLogOutput -Output $log
            $result.Commits = $commits
            if ($commits.Count -gt 0) {
                $result.Graph = ConvertTo-DevKitGitGraphLayout -Commits $commits
            }
        } else {
            $result.GraphSkipped = $true
        }

        # Ambient work-in-progress counts for the project badge.
        $dirty = (& $git.Source '-C' $Path 'status' '--porcelain' 2>$null | Out-String)
        $result.DirtyFiles = ConvertFrom-DevKitGitStatusOutput -Raw $dirty
        $result.DirtyCount = @($result.DirtyFiles).Count
        $stashes = (& $git.Source '-C' $Path 'stash' 'list' 2>$null | Out-String)
        $result.StashCount = @($stashes -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count

        $remote = (& $git.Source '-C' $Path 'config' '--get' 'remote.origin.url' 2>$null | Out-String).Trim()
        if ($remote) { $result.RemoteUrl = $remote }
    } catch {
        $result.Error = "$_"
    }
    return $result
}

function Invoke-DevKitGitAction {
    <#
    .SYNOPSIS
        Runs 'git -C <path> fetch|pull|push' and returns the captured output
        plus its last non-empty line (what the flyout's status line shows).
        Never throws.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('fetch', 'pull', 'push')][string]$Action
    )

    $result = [PSCustomObject]@{ Success = $false; LastLine = ''; Output = '' }
    $git = Get-DevKitWindowsExecutable -Name 'git'
    if (-not $git) {
        $result.LastLine = 'git not found on PATH.'
        return $result
    }
    try {
        # git prints normal progress (and 'Already up to date.') to stderr,
        # so 2>&1 is required to see anything at all - not just errors.
        $out = (& $git.Source '-C' $Path $Action 2>&1 | Out-String)
        $exitCode = $LASTEXITCODE
        $result.Output = if ($out) { $out.TrimEnd() } else { '' }
        $lines = @($result.Output -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $result.LastLine = if ($lines.Count -gt 0) { $lines[-1].Trim() } else { "git $Action finished with no output." }
        $result.Success = ($exitCode -eq 0)
    } catch {
        $result.LastLine = "$_"
    }
    return $result
}

# ==================== COMMIT DETAILS (git show) ====================
# Backs the commit graph's click-to-expand: one 'git show --numstat
# --shortstat' per clicked commit, parsed into plain hashtables.

function ConvertFrom-DevKitGitShow {
    <#
    .SYNOPSIS
        Parses 'git show --format=%H%x1f%an%x1f%ae%x1f%aI%x1f%B%x1e --numstat
        --shortstat <hash>' output into a plain hashtable: Hash, Author,
        Email, Date (ISO 8601 strict), Message (the FULL multi-line message,
        subject included), Files (@{ Path; Added; Deleted; IsBinary }),
        FilesChanged, Insertions, Deletions. Unit/record separators keep
        multi-line messages unambiguous; the stat block is everything after
        the record separator. Merge commits (and empty commits) simply have
        no numstat lines - Files is empty and the counts fall back to the
        shortstat summary line (or stay 0 when git prints neither). Returns
        $null when the output doesn't carry the expected field separators -
        the caller maps that to an honest "couldn't read" message, never a
        throw.
    #>
    param([AllowEmptyString()][string]$Output)

    if ([string]::IsNullOrWhiteSpace($Output)) { return $null }
    $rs = [char]0x1e; $us = [char]0x1f
    $rsIdx = $Output.IndexOf($rs)
    # Header + message: everything before the record separator; stat block after.
    $headPart = if ($rsIdx -ge 0) { $Output.Substring(0, $rsIdx) } else { $Output }
    $statPart = if ($rsIdx -ge 0) { $Output.Substring($rsIdx + 1) } else { '' }
    # 5-way split cap: a stray US byte inside the message body lands in the
    # last field instead of shifting the whole parse.
    $fields = $headPart -split "$us", 5
    if ($fields.Count -lt 5) { return $null }

    $files = @()
    $filesChanged = $null; $insertions = 0; $deletions = 0
    foreach ($line in ($statPart -split "`r?`n")) {
        if ($line -match '^(\d+|-)\t(\d+|-)\t(.+)$') {
            $binary = ($Matches[1] -eq '-')
            $files += @{
                Path     = $Matches[3].Trim()
                Added    = if ($binary) { 0 } else { [int]$Matches[1] }
                Deleted  = if ($binary) { 0 } else { [int]$Matches[2] }
                IsBinary = $binary
            }
        } elseif ($line -match '^\s*(\d+)\s+files?\s+changed(?:,\s*(\d+)\s+insertions?\(\+\))?(?:,\s*(\d+)\s+deletions?\(-\))?\s*$') {
            $filesChanged = [int]$Matches[1]
            if ($Matches[2]) { $insertions = [int]$Matches[2] }
            if ($Matches[3]) { $deletions = [int]$Matches[3] }
        }
    }
    # No shortstat summary (e.g. --shortstat unsupported): count what we saw.
    if ($null -eq $filesChanged) {
        $filesChanged = $files.Count
        if ($files.Count -gt 0) {
            $insertions = ($files | ForEach-Object Added | Measure-Object -Sum).Sum
            $deletions = ($files | ForEach-Object Deleted | Measure-Object -Sum).Sum
        }
    }

    return @{
        Hash         = $fields[0].Trim()
        Author       = [string]$fields[1]
        Email        = [string]$fields[2]
        Date         = [string]$fields[3]
        Message      = ([string]$fields[4]).Trim()
        Files        = $files
        FilesChanged = $filesChanged
        Insertions   = $insertions
        Deletions    = $deletions
    }
}

function Get-DevKitCommitDetails {
    <#
    .SYNOPSIS
        'git show' one commit in the project at -Path and return structured
        details for the widget flyout's click-to-expand card (parsed by
        ConvertFrom-DevKitGitShow). Never throws - git missing, an invalid or
        gone hash (rebased away mid-view), and parse failures all come back
        as Found=$false with an honest Error line, since this runs in a
        background runspace where an unhandled exception would silently kill
        the job.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Hash
    )

    $result = [PSCustomObject]@{
        Found        = $false
        Hash         = $Hash
        Error        = $null
        Author       = ''
        Email        = ''
        Date         = ''
        Message      = ''
        Files        = @()
        FilesChanged = 0
        Insertions   = 0
        Deletions    = 0
    }
    # Hex-only guard: the value travels into a git command line, and anything
    # that isn't a hash isn't worth a git spawn.
    if ($Hash -notmatch '^[0-9a-fA-F]{4,64}$') { $result.Error = 'Invalid commit hash.'; return $result }
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        $result.Error = 'No project selected.'
        return $result
    }
    $git = Get-DevKitWindowsExecutable -Name 'git'
    if (-not $git) { $result.Error = 'git not found on PATH.'; return $result }
    try {
        $out = (& $git.Source '-C' $Path 'show' '--format=%H%x1f%an%x1f%ae%x1f%aI%x1f%B%x1e' '--numstat' '--shortstat' $Hash 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) {
            # bad object / unknown revision: the classic "commit vanished
            # after a rebase while the graph still showed it" case.
            $result.Error = 'This commit is no longer available (history may have changed).'
            return $result
        }
        $parsed = ConvertFrom-DevKitGitShow -Output $out
        if (-not $parsed) { $result.Error = 'Could not read this commit.'; return $result }
        $result.Found        = $true
        $result.Author       = $parsed.Author
        $result.Email        = $parsed.Email
        $result.Date         = $parsed.Date
        $result.Message      = $parsed.Message
        $result.Files        = $parsed.Files
        $result.FilesChanged = $parsed.FilesChanged
        $result.Insertions   = $parsed.Insertions
        $result.Deletions    = $parsed.Deletions
    } catch {
        $result.Error = "$_"
    }
    return $result
}

# ==================== GITHUB PULL REQUESTS / ISSUES ====================
# Read-only 'gh' CLI queries for the flyout's future PR/Issues panels. This
# installed gh version has no '-C <path>' flag (only 'gh repo clone -C' takes
# one), so the working directory is switched with Push-Location instead - the
# same effect Get-DevKitRepoOverview gets from git's own -C flag.

function ConvertFrom-DevKitGitHubCliError {
    <#
    .SYNOPSIS
        Maps 'gh' stderr text to a friendly widget message instead of a raw
        CLI dump, distinguishing "no GitHub context here" (not a git repo /
        no remote / remote isn't GitHub) from a genuine CLI failure (auth,
        network, rate limit) whose own message is already short enough to
        surface as-is.
    #>
    param([string]$StdErr, [int]$ExitCode)
    $text = "$StdErr".Trim()
    if ($text -match '(?i)not a git repository') { return 'Not a git repository.' }
    if ($text -match '(?i)no git remotes found') { return 'No git remote configured for this project.' }
    if ($text -match '(?i)none of the git remotes|no known github host') { return 'No GitHub remote found for this project.' }
    if ($text) { return $text }
    return "gh failed (exit $ExitCode)."
}

function Get-DevKitGitHubPullRequests {
    <#
    .SYNOPSIS
        Open GitHub pull requests for a project via 'gh pr list'. Never
        throws - CLI-not-found, no-repo, no-GitHub-remote, and generic gh
        failures (auth/network/rate-limit) all come back as a populated
        result instead of propagating, since this runs in a background
        runspace where an unhandled exception would silently kill the job.
    #>
    param([string]$Path)

    $result = [PSCustomObject]@{
        CliInstalled = $false
        IsRepo       = $false
        ErrorMessage = $null
        PullRequests = @()
        Truncated    = $false
    }

    $gh = Get-DevKitWindowsExecutable -Name 'gh'
    if (-not $gh) { return $result }
    $result.CliInstalled = $true

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        $result.ErrorMessage = 'No project selected.'
        return $result
    }

    # '--limit' is requested one higher than the display cap so a full page
    # can be distinguished from "exactly N results" - if gh returns the extra
    # (N+1)th item, the real count exceeds the cap and the UI must say "N+"
    # instead of silently showing a number that looks exact.
    $prDisplayLimit = 50
    try {
        Push-Location -LiteralPath $Path
        try {
            $out = (& $gh.Source 'pr' 'list' '--json' 'number,title,author,url,isDraft,headRefName,baseRefName,updatedAt,reviewDecision,labels' '--state' 'open' '--limit' ([string]($prDisplayLimit + 1)) 2>&1 | Out-String)
            $exitCode = $LASTEXITCODE
        } finally {
            Pop-Location
        }
        if ($exitCode -eq 0) {
            $result.IsRepo = $true
            $parsed = $out | ConvertFrom-Json
            # Windows PowerShell 5.1 parses '[]' into an empty array; pwsh 7
            # parses it into $null - normalize both to an empty array so the
            # caller never has to special-case "no PRs" vs "not collected".
            # NOTE: this must be a plain if/else assignment, not
            # "$x = if (...) { @() } else { ... }" - an empty array that is
            # the sole output of an if-EXPRESSION branch gets unrolled to
            # zero pipeline objects, which silently reassigns $x to $null.
            if ($null -eq $parsed) {
                $result.PullRequests = @()
            } else {
                $all = @($parsed)
                if ($all.Count -gt $prDisplayLimit) {
                    $result.Truncated = $true
                    $result.PullRequests = @($all[0..($prDisplayLimit - 1)])
                } else {
                    $result.PullRequests = $all
                }
            }
        } else {
            $result.ErrorMessage = ConvertFrom-DevKitGitHubCliError -StdErr $out -ExitCode $exitCode
        }
    } catch {
        $result.ErrorMessage = "$_"
    }
    return $result
}

function Get-DevKitGitHubIssues {
    <#
    .SYNOPSIS
        Open GitHub issues for a project via 'gh issue list'. Same never-
        throws contract as Get-DevKitGitHubPullRequests. Note: the 'comments'
        json field is an ARRAY of comment objects (verified empirically
        against a real repo), not a count - callers wanting a count must use
        its .Count.
    #>
    param([string]$Path)

    $result = [PSCustomObject]@{
        CliInstalled = $false
        IsRepo       = $false
        ErrorMessage = $null
        Issues       = @()
        Truncated    = $false
    }

    $gh = Get-DevKitWindowsExecutable -Name 'gh'
    if (-not $gh) { return $result }
    $result.CliInstalled = $true

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        $result.ErrorMessage = 'No project selected.'
        return $result
    }

    # See the matching comment in Get-DevKitGitHubPullRequests - requesting
    # one past the display cap makes an over-the-cap result set detectable.
    $issueDisplayLimit = 50
    try {
        Push-Location -LiteralPath $Path
        try {
            $out = (& $gh.Source 'issue' 'list' '--json' 'number,title,author,url,labels,body,comments,updatedAt' '--state' 'open' '--limit' ([string]($issueDisplayLimit + 1)) 2>&1 | Out-String)
            $exitCode = $LASTEXITCODE
        } finally {
            Pop-Location
        }
        if ($exitCode -eq 0) {
            $result.IsRepo = $true
            $parsed = $out | ConvertFrom-Json
            # Same PS 5.1 vs pwsh 7 '[]' normalization as the PR fetch above,
            # and the same reason this is a plain if/else assignment rather
            # than an if-EXPRESSION (see the comment in the PR fetch above).
            if ($null -eq $parsed) {
                $result.Issues = @()
            } else {
                $all = @($parsed)
                if ($all.Count -gt $issueDisplayLimit) {
                    $result.Truncated = $true
                    $result.Issues = @($all[0..($issueDisplayLimit - 1)])
                } else {
                    $result.Issues = $all
                }
            }
        } else {
            $result.ErrorMessage = ConvertFrom-DevKitGitHubCliError -StdErr $out -ExitCode $exitCode
        }
    } catch {
        $result.ErrorMessage = "$_"
    }
    return $result
}

# ==================== .ENV DRIFT CHECK ====================
# Compares a project's .env against its template (.env.example et al.) by KEY
# NAME ONLY - values are secrets and are never read beyond the split needed
# to detect an empty one. Powers the widget's ".env missing N keys" hint.

function Get-DevKitEnvKeyNames {
    <#
    .SYNOPSIS
        Extracts variable names from .env-style lines, ignoring comments,
        blank lines, and an optional 'export ' prefix. Pure - unit-testable.
    #>
    param([AllowEmptyCollection()][string[]]$Lines)
    $names = @()
    foreach ($line in $Lines) {
        if ($line -match '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=') {
            if ($names -notcontains $Matches[1]) { $names += $Matches[1] }
        }
    }
    return ,$names
}

function Compare-DevKitEnvKeys {
    <#
    .SYNOPSIS
        Key-set diff of a template vs a live .env (both pre-read line arrays).
        Missing = in template, absent from .env. Empty = present in .env but
        with a blank value. Extra = only in .env (possibly stale).
    #>
    param(
        [AllowEmptyCollection()][string[]]$TemplateLines,
        [AllowEmptyCollection()][string[]]$EnvLines
    )
    # Note: Get-DevKitEnvKeyNames returns its array comma-wrapped (no pipeline
    # unroll), so these are direct assignments - @() would nest the array.
    $templateKeys = Get-DevKitEnvKeyNames -Lines $TemplateLines
    $envKeys = Get-DevKitEnvKeyNames -Lines $EnvLines

    $missing = @($templateKeys | Where-Object { $envKeys -notcontains $_ })
    $extra = @($envKeys | Where-Object { $templateKeys -notcontains $_ })
    $empty = @()
    foreach ($line in $EnvLines) {
        if ($line -match '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
            $value = $Matches[2].Trim().Trim('"', "'")
            if ($value -eq '' -and $templateKeys -contains $Matches[1]) { $empty += $Matches[1] }
        }
    }
    return @{ Missing = $missing; Empty = $empty; Extra = $extra; TemplateKeyCount = $templateKeys.Count }
}

function Get-DevKitEnvDrift {
    <#
    .SYNOPSIS
        The active project's .env drift in one call: which template file was
        used plus the Compare-DevKitEnvKeys result. $null when the project has
        no template (nothing to drift against) - the UI hides the hint then.
    #>
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return $null }
    $templatePath = $null
    foreach ($candidate in @('.env.example', '.env.sample', '.env.template')) {
        $full = Join-Path $Path $candidate
        if (Test-Path -LiteralPath $full) { $templatePath = $full; break }
    }
    if (-not $templatePath) { return $null }
    try {
        $templateLines = @(Get-Content -LiteralPath $templatePath -ErrorAction Stop)
        # .env.local is the actual working file for most modern stacks
        # (Next.js/Vite/etc - it's gitignored and layered over .env); prefer
        # it when present so this never has to open the checked-in/shared
        # .env. Falls back to .env for projects with no .env.local convention.
        $localPath = Join-Path $Path '.env.local'
        $envPath = if (Test-Path -LiteralPath $localPath) { $localPath } else { Join-Path $Path '.env' }
        $envLines = @()
        if (Test-Path -LiteralPath $envPath) { $envLines = @(Get-Content -LiteralPath $envPath -ErrorAction Stop) }
        $diff = Compare-DevKitEnvKeys -TemplateLines $templateLines -EnvLines $envLines
        return @{
            Template   = (Split-Path -Leaf $templatePath)
            EnvFile    = (Split-Path -Leaf $envPath)
            EnvExists  = [bool](Test-Path -LiteralPath $envPath)
            Missing    = $diff.Missing
            Empty      = $diff.Empty
            Extra      = $diff.Extra
        }
    } catch {
        return $null
    }
}

# ==================== PER-PROJECT STICKY NOTES ====================
# Backing store for the widget's Notes flyout: one JSON file holding every
# project's little notes/prompts, keyed by a canonical form of the project
# path. Lives beside settings.json in %LOCALAPPDATA% (user data - survives a
# DevKit reinstall/upgrade in place). Pure file logic only; all rendering
# and autosave timing lives in DevKit-Widget.ps1.

function Get-DevKitNotesFile {
    return Join-Path $env:LOCALAPPDATA 'NorthstarDevKit\notes.json'
}

function Get-DevKitNotesProjectKey {
    # One canonical key per project folder - trailing-separator and casing
    # differences in how the same path was registered must not fork its notes.
    param([Parameter(Mandatory = $true)][string]$ProjectPath)
    return $ProjectPath.TrimEnd('\', '/').ToLowerInvariant()
}

function Get-DevKitProjectNotes {
    <#
    .SYNOPSIS
        Returns one project's saved sticky notes as an array of
        PSCustomObjects (Id, Text, Color, UpdatedAt), newest first as saved.
        Empty for a missing file, an unknown project, or a corrupt store.
        Callers must wrap the call in @(...) - the repo-wide convention -
        since an empty return unrolls to nothing in a pipeline.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [string]$NotesFile
    )
    if (-not $NotesFile) { $NotesFile = Get-DevKitNotesFile }
    if (-not (Test-Path -LiteralPath $NotesFile)) { return @() }
    $key = Get-DevKitNotesProjectKey -ProjectPath $ProjectPath
    try {
        $data = Get-Content -LiteralPath $NotesFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if (-not $data.projects) { return @() }
        $entry = $data.projects.PSObject.Properties[$key]
        if (-not $entry) { return @() }
        $notes = @()
        foreach ($n in @($entry.Value)) {
            if ($null -eq $n) { continue }
            $notes += [PSCustomObject]@{
                Id        = [string]$n.id
                Text      = [string]$n.text
                Color     = [string]$n.color
                UpdatedAt = [string]$n.updatedAt
            }
        }
        return $notes
    } catch { return @() }
}

function Save-DevKitProjectNotes {
    <#
    .SYNOPSIS
        Persists one project's sticky notes - a read-modify-write of the
        whole store, so every other project's notes are untouched. $Notes is
        the full replacement list for this project; an empty list removes
        the project's entry entirely rather than leaving empty stubs behind.
        A corrupt store is silently rebuilt (same forgiving posture as
        Get-DevKitSettings) - the notes being saved right now matter more
        than a file some editor mangled.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Notes,
        [string]$NotesFile
    )
    if (-not $NotesFile) { $NotesFile = Get-DevKitNotesFile }
    $key = Get-DevKitNotesProjectKey -ProjectPath $ProjectPath

    $projects = [ordered]@{}
    if (Test-Path -LiteralPath $NotesFile) {
        try {
            $data = Get-Content -LiteralPath $NotesFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($data.projects) {
                foreach ($p in $data.projects.PSObject.Properties) {
                    # @(...) so a one-note project stays a JSON ARRAY on the
                    # way back out - member access unrolls single-element
                    # arrays, and without this a lone note would round-trip
                    # into a bare object.
                    if ($p.Name -ne $key) { $projects[$p.Name] = @($p.Value) }
                }
            }
        } catch { }
    }

    $list = @()
    foreach ($n in $Notes) {
        if ($null -eq $n) { continue }
        $list += [ordered]@{
            id        = [string]$n.Id
            text      = [string]$n.Text
            color     = [string]$n.Color
            updatedAt = [string]$n.UpdatedAt
        }
    }
    if ($list.Count -gt 0) { $projects[$key] = $list }

    $dir = Split-Path -Parent $NotesFile
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $store = [ordered]@{ schemaVersion = 1; projects = $projects }
    # -InputObject, not pipeline: piping would unroll and serialize only the
    # store's properties one at a time instead of the object itself.
    Set-Content -LiteralPath $NotesFile -Value (ConvertTo-Json -InputObject $store -Depth 6) -Encoding UTF8
}

function Get-DevKitNoteTitle {
    <#
    .SYNOPSIS
        Derives a note's one-line title for the widget's collapsed note card:
        the first non-empty line of the body, trimmed. Notes have no title
        field on disk (the notes.json schema stays exactly what older widget
        versions read and write) - the title is always derived at render
        time, so an existing store needs no migration and no data can be
        lost. Empty/whitespace bodies get a placeholder instead of a blank
        card.
    #>
    param([string]$Text)
    if (-not [string]::IsNullOrWhiteSpace($Text)) {
        foreach ($line in ($Text -split "`r?`n")) {
            $t = $line.Trim()
            if ($t.Length -gt 0) { return $t }
        }
    }
    return '(empty note)'
}

# ==================== PER-PROJECT ON-DECK LIST (TO-DO) ====================
# Backing store for the widget's On-Deck flyout: one JSON file holding every
# project's to-do items, keyed by the same canonical project-path key the
# notes store uses (Get-DevKitNotesProjectKey). Same forgiving posture as the
# notes store: a missing/corrupt file reads as an empty list, and a save is a
# read-modify-write of the whole store so other projects are untouched. Pure
# file/list logic only; all rendering lives in DevKit-Widget.ps1.

function Get-DevKitOnDeckFile {
    return Join-Path $env:LOCALAPPDATA 'NorthstarDevKit\ondeck.json'
}

function Get-DevKitOnDeckStatus {
    <#
    .SYNOPSIS
        Normalizes an on-deck status string to one of the three known values
        ('notStarted' / 'inProgress' / 'done'). Anything unknown - including
        $null, casing drift, or a hand-edited store - becomes 'notStarted',
        so a mangled entry still lands in a real section instead of vanishing.
    #>
    param([string]$Status)
    switch ([string]$Status) {
        'inProgress' { return 'inProgress' }
        'done'       { return 'done' }
        default      { return 'notStarted' }
    }
}

function Get-DevKitProjectOnDeck {
    <#
    .SYNOPSIS
        Returns one project's saved on-deck items as an array of
        PSCustomObjects (Id, Text, Status, UpdatedAt), in stored (section-
        grouped) order. Empty for a missing file, an unknown project, or a
        corrupt store. Callers must wrap the call in @(...) - the repo-wide
        convention - since an empty return unrolls to nothing in a pipeline.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [string]$OnDeckFile
    )
    if (-not $OnDeckFile) { $OnDeckFile = Get-DevKitOnDeckFile }
    if (-not (Test-Path -LiteralPath $OnDeckFile)) { return @() }
    $key = Get-DevKitNotesProjectKey -ProjectPath $ProjectPath
    try {
        $data = Get-Content -LiteralPath $OnDeckFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if (-not $data.projects) { return @() }
        $entry = $data.projects.PSObject.Properties[$key]
        if (-not $entry) { return @() }
        $items = @()
        foreach ($i in @($entry.Value)) {
            if ($null -eq $i) { continue }
            $items += [PSCustomObject]@{
                Id        = [string]$i.id
                Text      = [string]$i.text
                Status    = Get-DevKitOnDeckStatus -Status ([string]$i.status)
                UpdatedAt = [string]$i.updatedAt
            }
        }
        return $items
    } catch { return @() }
}

function Save-DevKitProjectOnDeck {
    <#
    .SYNOPSIS
        Persists one project's on-deck items - a read-modify-write of the
        whole store, so every other project's list is untouched. $Items is
        the full replacement list for this project; an empty list removes
        the project's entry entirely rather than leaving empty stubs behind.
        A corrupt store is silently rebuilt (same forgiving posture as
        Save-DevKitProjectNotes).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Items,
        [string]$OnDeckFile
    )
    if (-not $OnDeckFile) { $OnDeckFile = Get-DevKitOnDeckFile }
    $key = Get-DevKitNotesProjectKey -ProjectPath $ProjectPath

    $projects = [ordered]@{}
    if (Test-Path -LiteralPath $OnDeckFile) {
        try {
            $data = Get-Content -LiteralPath $OnDeckFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($data.projects) {
                foreach ($p in $data.projects.PSObject.Properties) {
                    # @(...) so a one-item project stays a JSON ARRAY on the
                    # way back out - member access unrolls single-element
                    # arrays, and without this a lone item would round-trip
                    # into a bare object.
                    if ($p.Name -ne $key) { $projects[$p.Name] = @($p.Value) }
                }
            }
        } catch { }
    }

    $list = @()
    foreach ($i in $Items) {
        if ($null -eq $i) { continue }
        $list += [ordered]@{
            id        = [string]$i.Id
            text      = [string]$i.Text
            status    = Get-DevKitOnDeckStatus -Status ([string]$i.Status)
            updatedAt = [string]$i.UpdatedAt
        }
    }
    if ($list.Count -gt 0) { $projects[$key] = $list }

    $dir = Split-Path -Parent $OnDeckFile
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $store = [ordered]@{ schemaVersion = 1; projects = $projects }
    # -InputObject, not pipeline: piping would unroll and serialize only the
    # store's properties one at a time instead of the object itself.
    Set-Content -LiteralPath $OnDeckFile -Value (ConvertTo-Json -InputObject $store -Depth 6) -Encoding UTF8
}

function Group-DevKitOnDeckItems {
    <#
    .SYNOPSIS
        Re-sorts an on-deck list into display order - every 'notStarted'
        item, then every 'inProgress', then every 'done' - stably (relative
        order within a section is preserved). The widget keeps the stored
        list in this order at all times, so "the item moves to its new
        section" is just a status change plus this regroup.
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Items)
    $grouped = @()
    foreach ($s in @('notStarted', 'inProgress', 'done')) {
        $grouped += @($Items | Where-Object { $null -ne $_ -and (Get-DevKitOnDeckStatus -Status ([string]$_.Status)) -eq $s })
    }
    return $grouped
}

function Add-DevKitOnDeckItem {
    <#
    .SYNOPSIS
        Returns a new on-deck list with a fresh 'notStarted' item prepended
        (newest on top of its section, like a new note). $Text is trimmed;
        an empty/whitespace text returns the list unchanged. Never mutates
        the input array.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Items,
        [string]$Text
    )
    if ([string]::IsNullOrWhiteSpace($Text)) { return @($Items) }
    $item = [PSCustomObject]@{
        Id        = [guid]::NewGuid().ToString('N')
        Text      = $Text.Trim()
        Status    = 'notStarted'
        UpdatedAt = [DateTime]::UtcNow.ToString('o')
    }
    return @(Group-DevKitOnDeckItems -Items (@($item) + @($Items)))
}

function Remove-DevKitOnDeckItem {
    <#
    .SYNOPSIS
        Returns a new on-deck list without the item whose Id is $Id (a
        missing id returns an equal list). Never mutates the input array.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Items,
        [Parameter(Mandatory = $true)][string]$Id
    )
    return @($Items | Where-Object { $null -ne $_ -and [string]$_.Id -ne $Id })
}

function Set-DevKitOnDeckItemStatus {
    <#
    .SYNOPSIS
        Returns a new on-deck list with one item's status changed and the
        whole list regrouped (Group-DevKitOnDeckItems), so the item lands in
        its new section immediately. Also stamps the item's UpdatedAt. An
        unknown id returns the list unchanged; an unknown status normalizes
        to 'notStarted'. Never mutates the input array (the matched item is
        copied first).
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Items,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Status
    )
    $newStatus = Get-DevKitOnDeckStatus -Status $Status
    $updated = @()
    foreach ($i in @($Items)) {
        if ($null -eq $i) { continue }
        if ([string]$i.Id -eq $Id) {
            $updated += [PSCustomObject]@{
                Id        = [string]$i.Id
                Text      = [string]$i.Text
                Status    = $newStatus
                UpdatedAt = [DateTime]::UtcNow.ToString('o')
            }
        } else {
            $updated += $i
        }
    }
    return @(Group-DevKitOnDeckItems -Items $updated)
}

function Clear-DevKitOnDeckDone {
    <#
    .SYNOPSIS
        Returns a new on-deck list with every 'done' item removed (the Done
        section header's "Clear Done" button). Never mutates the input
        array.
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Items)
    return @($Items | Where-Object { $null -ne $_ -and (Get-DevKitOnDeckStatus -Status ([string]$_.Status)) -ne 'done' })
}

# ==================== PROJECT FILE EXPLORER (FILES FLYOUT) ====================
# Pure file logic behind the widget's Files flyout: one-level directory
# enumeration, path-containment and name validation for the mutating toolbar/
# context-menu operations, and Explorer-style " - Copy" collision naming.
# All tree building/rendering stays in DevKit-Widget.ps1 - nothing here
# touches WPF.

function Get-DevKitDirChildren {
    <#
    .SYNOPSIS
        Enumerates ONE directory level for the Files flyout tree: folders
        first, then files, each alphabetical case-insensitive.
    .DESCRIPTION
        Never recurses (the tree expands lazily, one level per expansion).
        Hidden/system entries are included - the explorer skips nothing
        visually. An enumeration failure (access denied, vanished folder)
        does not throw: the result's Error carries the message and Children
        is empty, so the UI can degrade to a greyed node.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)
    $result = @{ Children = @(); Error = $null }
    try {
        $items = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)
    } catch {
        $result.Error = $_.Exception.Message
        return $result
    }
    # Sort-Object's string comparison is case-insensitive by default; the
    # leading key puts folders (0) before files (1).
    $sorted = @($items | Sort-Object -Property @{ Expression = { [int](-not $_.PSIsContainer) } }, @{ Expression = { $_.Name } })
    $children = @()
    foreach ($item in $sorted) {
        $children += [PSCustomObject]@{
            Name        = $item.Name
            FullName    = $item.FullName
            IsDirectory = [bool]$item.PSIsContainer
        }
    }
    $result.Children = $children
    return $result
}

function Test-DevKitPathWithinRoot {
    <#
    .SYNOPSIS
        True when $Path is the root itself or lives underneath it, after
        full-path normalization (so '..' escapes resolve BEFORE the prefix
        comparison). The safety gate for every mutating Files-flyout op.
    #>
    param([string]$Root, [Parameter(Mandatory = $true)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Root) -or [string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        $r = [IO.Path]::GetFullPath($Root).TrimEnd('\')
        $p = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    } catch { return $false }
    if ($p.Equals($r, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    # The separator in the prefix stops 'C:\proj' from matching 'C:\proj2'.
    return $p.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Get-DevKitSafeChildName {
    <#
    .SYNOPSIS
        Validates a proposed file/folder name for the Files flyout's
        New/Rename operations. Returns the (trimmed) name when usable,
        $null when not: empty/whitespace, any of \/:*?"<>| (via
        GetInvalidFileNameChars), a bare '.'/'..', or a trailing dot/space
        (which Windows silently strips, producing a file that does not
        match what the user typed).
    #>
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    $n = $Name.Trim()
    if ($n -eq '.' -or $n -eq '..') { return $null }
    if ($n.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { return $null }
    if ($n.EndsWith('.') -or $n.EndsWith(' ')) { return $null }
    return $n
}

function Get-DevKitCopyName {
    <#
    .SYNOPSIS
        Explorer-style collision renaming for Paste inside the Files flyout:
        'name' -> 'name - Copy' -> 'name - Copy (2)' -> ... - files keep
        their extension last ('a - Copy.txt'). Returns $Name unchanged when
        nothing collides. Pure check against the target folder on disk.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Folder,
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$IsDirectory
    )
    if (-not (Test-Path -LiteralPath (Join-Path $Folder $Name))) { return $Name }
    $base = $Name
    $ext = ''
    if (-not $IsDirectory) {
        $ext = [IO.Path]::GetExtension($Name)
        $base = [IO.Path]::GetFileNameWithoutExtension($Name)
    }
    $candidate = "$base - Copy$ext"
    $i = 2
    while (Test-Path -LiteralPath (Join-Path $Folder $candidate)) {
        $candidate = "$base - Copy ($i)$ext"
        $i++
    }
    return $candidate
}

function Get-DevKitRelativePath {
    <#
    .SYNOPSIS
        Root-relative path ('src\app\index.ts') for the Files flyout's
        expansion-state keys and Copy Relative Path. Returns '' for the root
        itself and $null when $Path is outside the root. .NET Framework 4.x
        (PS 5.1) has no [IO.Path]::GetRelativePath, hence the manual form.
    #>
    param([string]$Root, [Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-DevKitPathWithinRoot -Root $Root -Path $Path)) { return $null }
    $r = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $p = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($p.Equals($r, [StringComparison]::OrdinalIgnoreCase)) { return '' }
    return $p.Substring($r.Length + 1)
}

# ==================== FILE ICON MAPPING (FILES FLYOUT / GIT GRAPH) ====================
# Pure name -> icon-key + Material-palette color mapping behind the widget's
# built-in vector icon set. No WPF here: gui/DevKit-WidgetIcons.ps1 owns the
# frozen drawings and consumes the Key/Color this returns (every Key below has
# a catalog entry there).

# Special names checked BEFORE the extension table (a name like
# 'package-lock.json' must win over '.json', 'docker-compose.yml' over '.yml').
# Matched case-insensitively against the exact file name.
$script:DevKitIconNameMap = @{
    'dockerfile'           = 'docker'
    '.dockerignore'        = 'docker'
    'docker-compose.yml'   = 'docker'
    'docker-compose.yaml'  = 'docker'
    '.gitignore'           = 'git'
    '.gitattributes'       = 'git'
    '.gitmodules'          = 'git'
    'package-lock.json'    = 'lock'
    'npm-shrinkwrap.json'  = 'lock'
    'yarn.lock'            = 'lock'
    'pnpm-lock.yaml'       = 'lock'
    'bun.lock'             = 'lock'
    'bun.lockb'            = 'lock'
    'composer.lock'        = 'lock'
    'cargo.lock'           = 'lock'
}

# Extension (no dot, lowercase) -> icon key. Anything missing falls back to
# the generic 'file' key.
$script:DevKitIconExtensionMap = @{
    'js' = 'js';  'mjs' = 'js';  'cjs' = 'js'
    'jsx' = 'jsx'
    'ts' = 'ts';  'mts' = 'ts';  'cts' = 'ts'
    'tsx' = 'tsx'
    'json' = 'json'; 'jsonc' = 'json'; 'json5' = 'json'; 'map' = 'json'
    'md' = 'md'; 'markdown' = 'md'; 'mdx' = 'md'
    'ps1' = 'ps1'; 'psm1' = 'ps1'; 'psd1' = 'ps1'
    'bat' = 'bat'; 'cmd' = 'bat'
    'html' = 'html'; 'htm' = 'html'
    'css' = 'css'
    'scss' = 'scss'; 'sass' = 'scss'; 'less' = 'scss'
    'vue' = 'vue'
    'svelte' = 'svelte'
    'py' = 'py'; 'pyw' = 'py'
    'cs' = 'cs'; 'csproj' = 'cs'
    'c' = 'c'; 'h' = 'c'
    'cpp' = 'cpp'; 'cc' = 'cpp'; 'cxx' = 'cpp'; 'hpp' = 'cpp'
    'java' = 'java'; 'class' = 'java'; 'jar' = 'java'
    'go' = 'go'
    'rs' = 'rs'
    'php' = 'php'
    'rb' = 'rb'
    'xml' = 'xml'; 'xaml' = 'xml'; 'svg+xml' = 'xml'
    'yml' = 'yml'; 'yaml' = 'yml'
    'toml' = 'toml'
    'lock' = 'lock'
    'ini' = 'config'; 'cfg' = 'config'; 'conf' = 'config'; 'config' = 'config'; 'editorconfig' = 'config'; 'props' = 'config'; 'targets' = 'config'
    'png' = 'image'; 'jpg' = 'image'; 'jpeg' = 'image'; 'gif' = 'image'; 'svg' = 'image'; 'ico' = 'image'; 'webp' = 'image'; 'bmp' = 'image'
    'zip' = 'archive'; 'tar' = 'archive'; 'gz' = 'archive'; 'tgz' = 'archive'; '7z' = 'archive'; 'rar' = 'archive'; 'bz2' = 'archive'
    'sql' = 'sql'
    'txt' = 'txt'; 'log' = 'txt'
    'pdf' = 'pdf'
    'exe' = 'exe'; 'dll' = 'exe'; 'msi' = 'exe'; 'sys' = 'exe'
}

# Canonical Material-ish color per icon key. Kept here (not in the icons file)
# so the color is part of the tested contract.
$script:DevKitIconColors = @{
    'folder'      = '#E5C07B'  # amber (matches the widget's old folder glyph)
    'folder-open' = '#E5C07B'
    'file'        = '#8A93A6'  # muted steel
    'js'          = '#F7DF1E'  # JS yellow
    'jsx'         = '#61DAFB'  # React cyan
    'ts'          = '#3178C6'  # TS blue
    'tsx'         = '#61DAFB'  # React cyan
    'json'        = '#FBC02D'  # amber
    'md'          = '#78909C'  # slate
    'ps1'         = '#5391FE'  # sapphire
    'bat'         = '#9AA0A6'  # console gray
    'html'        = '#E44D26'  # HTML5 orange
    'css'         = '#42A5F5'  # CSS blue
    'scss'        = '#CD6799'  # Sass pink
    'vue'         = '#41B883'  # Vue green
    'svelte'      = '#FF3E00'  # Svelte orange
    'py'          = '#4B8BBE'  # Python blue
    'cs'          = '#68217A'  # .NET purple
    'c'           = '#5C6BC0'  # indigo
    'cpp'         = '#649AD2'  # C++ blue
    'java'        = '#E76F00'  # Java orange
    'go'          = '#00ADD8'  # Go cyan
    'rs'          = '#DEA584'  # Rust
    'php'         = '#777BB3'  # PHP periwinkle
    'rb'          = '#CC342D'  # Ruby red
    'xml'         = '#E37933'  # XML orange
    'yml'         = '#F0524F'  # YAML red
    'toml'        = '#9C6570'  # TOML mauve
    'env'         = '#ECD53F'  # dotenv yellow
    'lock'        = '#E8B339'  # padlock gold
    'image'       = '#26A69A'  # teal
    'archive'     = '#C0CA33'  # lime
    'git'         = '#F05033'  # git orange-red
    'docker'      = '#0DB7ED'  # Docker blue
    'sql'         = '#FFCA28'  # database amber
    'txt'         = '#9AA0A6'  # gray
    'pdf'         = '#E53935'  # PDF red
    'exe'         = '#7986CB'  # binary indigo
    'config'      = '#6D8086'  # settings slate
    'git-branch'  = '#C8D3E0'  # bright steel (reads on translucent pills)
    'git-tag'     = '#FFB020'  # matches the tag pill's amber
    'git-head'    = '#0A0D12'  # dark glyph on the HEAD pill's bright fill
}

function Get-DevKitFileIconInfo {
    <#
    .SYNOPSIS
        Maps a file/folder name to an icon key + Material-palette color hex
        for the widget's built-in icon set (gui/DevKit-WidgetIcons.ps1).
    .DESCRIPTION
        Pure mapping (no WPF) so it stays Pester-testable. Folders always map
        to the 'folder' key - the open/closed swap is a UI concern (the tree
        swaps the image source between the 'folder' and 'folder-open' frozen
        drawings in its expand/collapse handlers). Files check the special-
        name table first (Dockerfile, .gitignore, package-lock.json, any
        '.env*' name), then the extension table, then fall back to 'file'.
        All matching is case-insensitive.
    .OUTPUTS
        @{ Key = <string>; Color = '#RRGGBB' } - Key is always a valid
        Get-DevKitIconDrawing key.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Name,
        [switch]$IsFolder
    )
    if ($IsFolder) {
        return @{ Key = 'folder'; Color = $script:DevKitIconColors['folder'] }
    }
    $key = $null
    $lower = $Name.ToLowerInvariant()
    if ($script:DevKitIconNameMap.ContainsKey($lower)) {
        $key = $script:DevKitIconNameMap[$lower]
    } elseif ($lower -eq '.env' -or $lower.StartsWith('.env.')) {
        $key = 'env'
    } else {
        $ext = ''
        # Leading-dot names ('.editorconfig') treat the dotless name as the
        # "extension" so they can map too ('.env' was already caught above).
        $dot = $lower.LastIndexOf('.')
        if ($dot -ge 0 -and $dot -lt $lower.Length - 1) { $ext = $lower.Substring($dot + 1) }
        if ($ext -and $script:DevKitIconExtensionMap.ContainsKey($ext)) {
            $key = $script:DevKitIconExtensionMap[$ext]
        }
    }
    if (-not $key) { $key = 'file' }
    return @{ Key = $key; Color = $script:DevKitIconColors[$key] }
}
