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
    project, a system-junk size scan (plus the safe temp/Recycle-Bin-only
    clean), a git repo overview (branch, ahead/behind, dirty/stash counts,
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
# COM recycle-bin read). The clean below is deliberately the SAFE subset
# only: temp folder contents + Recycle Bin. No service stop/start, no
# Windows Update cache, no DISM - anything admin-gated belongs to the real
# Clear-DiskJunk tool, which the widget launches in a terminal instead.

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
        The safe subset of Clear-DiskJunk.ps1: deletes the CONTENTS of the
        user temp folder and empties the Recycle Bin - locations that always
        work unelevated. Windows\Temp is deliberately excluded (deletes there
        silently no-op for non-admins), as are service stop/start, the
        Windows Update cache, and DISM - those belong to the real
        Clear-DiskJunk tool (launched via "Cleanup Tool..."). Measures
        before/after on the same subset so "freed X" stays honest.
        Never throws; designed for the background runspace.
    #>
    $tempPaths = @($env:TEMP)

    $before = 0
    foreach ($p in $tempPaths) { $before += Get-DevKitJunkPathSize -Path $p }
    $before += Get-DevKitRecycleBinSize

    foreach ($p in $tempPaths) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        try {
            Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue | ForEach-Object {
                Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
        } catch { }
    }
    try { Clear-RecycleBin -Force -ErrorAction SilentlyContinue } catch { }

    $after = 0
    foreach ($p in $tempPaths) { $after += Get-DevKitJunkPathSize -Path $p }
    $after += Get-DevKitRecycleBinSize

    $freed = $before - $after
    if ($freed -lt 0) { $freed = 0 }
    return [PSCustomObject]@{
        BytesBefore = $before
        BytesAfter  = $after
        FreedBytes  = $freed
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
