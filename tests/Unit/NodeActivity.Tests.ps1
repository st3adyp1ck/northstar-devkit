#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pester tests for the node "last used" / stale derivation
    (core/DevKit-WidgetCore.ps1)
.DESCRIPTION
    Windows exposes no last-used timestamp for a process, so the widget's
    "idle 47m / safe to close" advice is derived across polls from cumulative
    CPU time. That derivation is the part most likely to quietly start lying
    (a fabricated idle time from a single sample, a recycled pid inheriting a
    stranger's CPU baseline, a threshold that flip-flops on a 3s window), and
    it is also the part that is pure: Update-DevKitNodeActivity takes its
    cache, its samples, "now" and the core count as arguments and touches
    neither the OS nor the clock, so every one of those cases is reproducible
    here without a live node process.

    Covers Update-DevKitNodeActivity, Get-DevKitNodeStaleVerdict,
    Test-DevKitNodeNeverStale, Test-DevKitSameProcessStart,
    Format-DevKitNodeCommandLine and Format-DevKitMinutesSpan.

    Run just this file:
        Invoke-Pester -Path .\tests\Unit\NodeActivity.Tests.ps1
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    # See Get-DevKitPackageManager.Tests.ps1 for why these load-once flags
    # get reset when several test files share one Pester process.
    $global:DevKitCommonLoaded = $false
    . (Join-Path $script:RepoRoot 'tools\lib\DevKit-Common.ps1')
    $global:DevKitWidgetCoreLoaded = $false
    . (Join-Path $script:RepoRoot 'core\DevKit-WidgetCore.ps1')

    $script:T0 = [datetime]'2026-01-01T09:00:00'
    $script:Started = [datetime]'2026-01-01T07:00:00'

    function New-Sample {
        param([int]$Pid_, $Cpu, $Start = $script:Started)
        return @{ Pid = $Pid_; CpuSeconds = $Cpu; StartTime = $Start }
    }
}

Describe "Format-DevKitMinutesSpan" {

    It "renders sub-hour spans as minutes" {
        Format-DevKitMinutesSpan -Minutes 0 | Should -Be '0m'
        Format-DevKitMinutesSpan -Minutes 47 | Should -Be '47m'
    }

    It "renders hours, dropping a zero minute remainder" {
        Format-DevKitMinutesSpan -Minutes 60 | Should -Be '1h'
        Format-DevKitMinutesSpan -Minutes 134 | Should -Be '2h 14m'
    }

    It "clamps negatives to 0m" {
        Format-DevKitMinutesSpan -Minutes -5 | Should -Be '0m'
    }
}

Describe "Test-DevKitSameProcessStart" {

    It "matches identical start times" {
        Test-DevKitSameProcessStart -A $script:Started -B $script:Started | Should -BeTrue
    }

    It "rejects different start times - that is a recycled pid" {
        Test-DevKitSameProcessStart -A $script:Started -B $script:Started.AddSeconds(1) | Should -BeFalse
    }

    It "treats two unreadable start times as the same process" {
        # A process this session cannot open reports $null every poll; calling
        # that a new process every time would reset the idle clock forever.
        Test-DevKitSameProcessStart -A $null -B $null | Should -BeTrue
    }

    It "treats a one-sided null as a different process" {
        Test-DevKitSameProcessStart -A $null -B $script:Started | Should -BeFalse
        Test-DevKitSameProcessStart -A $script:Started -B $null | Should -BeFalse
    }
}

Describe "Format-DevKitNodeCommandLine" {

    It "returns $null for absent or blank input" {
        Format-DevKitNodeCommandLine -CommandLine $null | Should -BeNullOrEmpty
        Format-DevKitNodeCommandLine -CommandLine '   ' | Should -BeNullOrEmpty
    }

    It "collapses whitespace runs and newlines to single spaces" {
        Format-DevKitNodeCommandLine -CommandLine "node   app.js`n  --port  3000" |
            Should -Be 'node app.js --port 3000'
    }

    It "leaves a short command line untouched" {
        Format-DevKitNodeCommandLine -CommandLine 'node vite.js' -MaxLength 300 | Should -Be 'node vite.js'
    }

    It "truncates to MaxLength with an ellipsis" {
        $long = 'node ' + ('x' * 500)
        $out = Format-DevKitNodeCommandLine -CommandLine $long -MaxLength 40
        $out.Length | Should -Be 40
        $out[-1] | Should -Be ([char]0x2026)
    }
}

Describe "Update-DevKitNodeActivity" {

    It "reports nothing from a single sample - one observation is not evidence" {
        $cache = @{}
        $r = Update-DevKitNodeActivity -Cache $cache -Samples @((New-Sample -Pid_ 100 -Cpu 12.0)) -Now $script:T0 -CoreCount 8
        $r[100].IdleMinutes | Should -BeNullOrEmpty
        $r[100].CpuPercent | Should -BeNullOrEmpty
        $cache.ContainsKey(100) | Should -BeTrue
    }

    It "reports 0 idle minutes when the second sample lands seconds later" {
        $cache = @{}
        $null = Update-DevKitNodeActivity -Cache $cache -Samples @((New-Sample -Pid_ 100 -Cpu 12.0)) -Now $script:T0 -CoreCount 8
        $r = Update-DevKitNodeActivity -Cache $cache -Samples @((New-Sample -Pid_ 100 -Cpu 12.0)) -Now $script:T0.AddSeconds(3) -CoreCount 8
        $r[100].IdleMinutes | Should -Be 0
    }

    It "grows the idle clock while cumulative CPU stays put" {
        $cache = @{}
        $null = Update-DevKitNodeActivity -Cache $cache -Samples @((New-Sample -Pid_ 100 -Cpu 12.0)) -Now $script:T0 -CoreCount 8
        $r = Update-DevKitNodeActivity -Cache $cache -Samples @((New-Sample -Pid_ 100 -Cpu 12.0)) -Now $script:T0.AddMinutes(47) -CoreCount 8
        $r[100].IdleMinutes | Should -Be 47
    }

    It "resets the idle clock when CPU moves" {
        $cache = @{}
        $null = Update-DevKitNodeActivity -Cache $cache -Samples @((New-Sample -Pid_ 100 -Cpu 12.0)) -Now $script:T0 -CoreCount 8
        $idle = Update-DevKitNodeActivity -Cache $cache -Samples @((New-Sample -Pid_ 100 -Cpu 12.0)) -Now $script:T0.AddMinutes(47) -CoreCount 8
        $idle[100].IdleMinutes | Should -Be 47
        $busy = Update-DevKitNodeActivity -Cache $cache -Samples @((New-Sample -Pid_ 100 -Cpu 14.0)) -Now $script:T0.AddMinutes(48) -CoreCount 8
        $busy[100].IdleMinutes | Should -Be 0
    }

    It "does not reset the idle clock on sub-threshold background chatter" {
        # An idle node process still burns a few milliseconds a poll on timers
        # and GC. If that counted as activity nothing would ever look idle.
        $cache = @{}
        $cpu = 12.0
        $null = Update-DevKitNodeActivity -Cache $cache -Samples @((New-Sample -Pid_ 100 -Cpu $cpu)) -Now $script:T0 -CoreCount 8
        $result = $null
        for ($i = 1; $i -le 40; $i++) {
            $cpu += 0.002   # 2ms of CPU per 3s poll
            $result = Update-DevKitNodeActivity -Cache $cache -Samples @((New-Sample -Pid_ 100 -Cpu $cpu)) -Now $script:T0.AddSeconds(3 * $i) -CoreCount 8
        }
        $result[100].IdleMinutes | Should -Be 2
    }

    It "derives CpuPercent from the delta over the window and the core count" {
        $cache = @{}
        $null = Update-DevKitNodeActivity -Cache $cache -Samples @((New-Sample -Pid_ 100 -Cpu 10.0)) -Now $script:T0 -CoreCount 4
        # 4 CPU-seconds over a 4s window on 4 cores = 25% of the machine.
        $r = Update-DevKitNodeActivity -Cache $cache -Samples @((New-Sample -Pid_ 100 -Cpu 14.0)) -Now $script:T0.AddSeconds(4) -CoreCount 4
        $r[100].CpuPercent | Should -Be 25
    }

    It "caps CpuPercent at 100" {
        $cache = @{}
        $null = Update-DevKitNodeActivity -Cache $cache -Samples @((New-Sample -Pid_ 100 -Cpu 0)) -Now $script:T0 -CoreCount 2
        $r = Update-DevKitNodeActivity -Cache $cache -Samples @((New-Sample -Pid_ 100 -Cpu 99)) -Now $script:T0.AddSeconds(1) -CoreCount 2
        $r[100].CpuPercent | Should -Be 100
    }

    It "treats a pid whose start time changed as a brand-new process" {
        $cache = @{}
        $null = Update-DevKitNodeActivity -Cache $cache -Samples @((New-Sample -Pid_ 100 -Cpu 900.0)) -Now $script:T0 -CoreCount 8
        $recycled = New-Sample -Pid_ 100 -Cpu 0.4 -Start $script:Started.AddHours(3)
        $r = Update-DevKitNodeActivity -Cache $cache -Samples @($recycled) -Now $script:T0.AddMinutes(90) -CoreCount 8
        $r[100].IdleMinutes | Should -BeNullOrEmpty
        $cache[100].CpuSeconds | Should -Be 0.4
        $cache[100].StartTime | Should -Be $script:Started.AddHours(3)
    }

    It "re-baselines on a negative CPU delta - a pid recycled behind our back" {
        # Same pid, same (unreadable) start time, yet cumulative CPU went
        # DOWN, which is impossible for one process.
        $cache = @{}
        $null = Update-DevKitNodeActivity -Cache $cache -Samples @((New-Sample -Pid_ 100 -Cpu 900.0 -Start $null)) -Now $script:T0 -CoreCount 8
        $r = Update-DevKitNodeActivity -Cache $cache -Samples @((New-Sample -Pid_ 100 -Cpu 1.0 -Start $null)) -Now $script:T0.AddMinutes(45) -CoreCount 8
        $r[100].IdleMinutes | Should -BeNullOrEmpty
        $cache[100].CpuSeconds | Should -Be 1.0
    }

    It "reports nothing while CPU time is unreadable, but keeps the idle clock running" {
        $cache = @{}
        $null = Update-DevKitNodeActivity -Cache $cache -Samples @((New-Sample -Pid_ 100 -Cpu 12.0)) -Now $script:T0 -CoreCount 8
        $blind = Update-DevKitNodeActivity -Cache $cache -Samples @((New-Sample -Pid_ 100 -Cpu $null)) -Now $script:T0.AddMinutes(10) -CoreCount 8
        $blind[100].IdleMinutes | Should -BeNullOrEmpty
        $back = Update-DevKitNodeActivity -Cache $cache -Samples @((New-Sample -Pid_ 100 -Cpu 12.0)) -Now $script:T0.AddMinutes(20) -CoreCount 8
        $back[100].IdleMinutes | Should -BeNullOrEmpty   # re-baselined, needs one more sample
        $settled = Update-DevKitNodeActivity -Cache $cache -Samples @((New-Sample -Pid_ 100 -Cpu 12.0)) -Now $script:T0.AddMinutes(30) -CoreCount 8
        $settled[100].IdleMinutes | Should -Be 30        # ChangedAt survived the blind spell
    }

    It "evicts pids that are gone so the cache cannot grow without bound" {
        $cache = @{}
        $null = Update-DevKitNodeActivity -Cache $cache -Samples @(
            (New-Sample -Pid_ 100 -Cpu 1.0), (New-Sample -Pid_ 200 -Cpu 2.0)
        ) -Now $script:T0 -CoreCount 8
        $cache.Count | Should -Be 2
        $null = Update-DevKitNodeActivity -Cache $cache -Samples @((New-Sample -Pid_ 200 -Cpu 2.0)) -Now $script:T0.AddSeconds(3) -CoreCount 8
        $cache.Count | Should -Be 1
        $cache.ContainsKey(200) | Should -BeTrue
    }

    It "empties the cache when every node process is gone" {
        $cache = @{}
        $null = Update-DevKitNodeActivity -Cache $cache -Samples @((New-Sample -Pid_ 100 -Cpu 1.0)) -Now $script:T0 -CoreCount 8
        $r = Update-DevKitNodeActivity -Cache $cache -Samples @() -Now $script:T0.AddSeconds(3) -CoreCount 8
        $cache.Count | Should -Be 0
        $r.Count | Should -Be 0
    }

    It "still counts a genuinely busy process as active after a long polling gap" {
        # Polling stops while the widget is hidden, so the window can reopen
        # hours wide. A purely rate-based threshold would demand minutes of
        # CPU across that gap before conceding the process was working.
        $cache = @{}
        $null = Update-DevKitNodeActivity -Cache $cache -Samples @((New-Sample -Pid_ 100 -Cpu 30.0)) -Now $script:T0 -CoreCount 8
        $r = Update-DevKitNodeActivity -Cache $cache -Samples @((New-Sample -Pid_ 100 -Cpu 35.0)) -Now $script:T0.AddHours(2) -CoreCount 8
        $r[100].IdleMinutes | Should -Be 0
    }
}

Describe "Test-DevKitNodeNeverStale" {

    It "protects a process whose command line could not be read" {
        Test-DevKitNodeNeverStale -CommandLine $null | Should -BeTrue
        Test-DevKitNodeNeverStale -CommandLine '' | Should -BeTrue
    }

    It "protects stdio MCP servers and agent CLIs - idle for hours is normal there" {
        Test-DevKitNodeNeverStale -CommandLine 'node C:\npm\node_modules\@modelcontextprotocol\server-filesystem\dist\index.js' | Should -BeTrue
        Test-DevKitNodeNeverStale -CommandLine '"node" "C:\Users\me\AppData\Roaming\npm\node_modules\@anthropic-ai\claude-code\cli.js"' | Should -BeTrue
    }

    It "protects watchers, test runners and language servers" {
        Test-DevKitNodeNeverStale -CommandLine 'node node_modules/.bin/nodemon server.js' | Should -BeTrue
        Test-DevKitNodeNeverStale -CommandLine 'node ./node_modules/vitest/vitest.mjs --watch' | Should -BeTrue
        Test-DevKitNodeNeverStale -CommandLine 'node C:\tools\typescript\lib\tsserver.js' | Should -BeTrue
    }

    It "protects a process with a debugger port open" {
        Test-DevKitNodeNeverStale -CommandLine 'node --inspect=9229 server.js' | Should -BeTrue
    }

    It "does not protect an ordinary abandoned script" {
        Test-DevKitNodeNeverStale -CommandLine 'node D:\proj\scripts\seed-database.js' | Should -BeFalse
    }
}

Describe "Get-DevKitNodeStaleVerdict" {

    It "flags an old, idle, portless process and explains why" {
        $v = Get-DevKitNodeStaleVerdict -IdleMinutes 47 -PortCount 0 -AgeMinutes 300 -MemoryMB 412 -CommandLine 'node D:\proj\seed.js'
        $v.IsStale | Should -BeTrue
        $v.Reason | Should -Be 'idle 47m, no listening port, holding 412 MB'
    }

    It "omits the memory clause for a small process" {
        $v = Get-DevKitNodeStaleVerdict -IdleMinutes 47 -PortCount 0 -AgeMinutes 300 -MemoryMB 12 -CommandLine 'node D:\proj\seed.js'
        $v.IsStale | Should -BeTrue
        $v.Reason | Should -Be 'idle 47m, no listening port'
    }

    It "never flags a process whose idle time is unknown" {
        $v = Get-DevKitNodeStaleVerdict -IdleMinutes $null -PortCount 0 -AgeMinutes 999 -MemoryMB 900 -CommandLine 'node D:\proj\seed.js'
        $v.IsStale | Should -BeFalse
        $v.Reason | Should -BeNullOrEmpty
    }

    It "never flags a process below the idle threshold" {
        (Get-DevKitNodeStaleVerdict -IdleMinutes 29 -PortCount 0 -AgeMinutes 300 -MemoryMB 900 -CommandLine 'node D:\proj\seed.js').IsStale | Should -BeFalse
        (Get-DevKitNodeStaleVerdict -IdleMinutes 30 -PortCount 0 -AgeMinutes 300 -MemoryMB 900 -CommandLine 'node D:\proj\seed.js').IsStale | Should -BeTrue
    }

    It "never flags a process holding a listening port" {
        # An idle dev server between requests looks exactly like a dead one.
        $v = Get-DevKitNodeStaleVerdict -IdleMinutes 600 -PortCount 1 -AgeMinutes 900 -MemoryMB 900 -CommandLine 'node D:\proj\server.js'
        $v.IsStale | Should -BeFalse
    }

    It "never flags a process whose age is unknown or short" {
        (Get-DevKitNodeStaleVerdict -IdleMinutes 40 -PortCount 0 -AgeMinutes $null -MemoryMB 100 -CommandLine 'node D:\proj\seed.js').IsStale | Should -BeFalse
        (Get-DevKitNodeStaleVerdict -IdleMinutes 40 -PortCount 0 -AgeMinutes 5 -MemoryMB 100 -CommandLine 'node D:\proj\seed.js').IsStale | Should -BeFalse
    }

    It "never flags something that is idle by design, however long it has sat" {
        (Get-DevKitNodeStaleVerdict -IdleMinutes 900 -PortCount 0 -AgeMinutes 900 -MemoryMB 900 -CommandLine 'node cli.js --watch').IsStale | Should -BeFalse
        (Get-DevKitNodeStaleVerdict -IdleMinutes 900 -PortCount 0 -AgeMinutes 900 -MemoryMB 900 -CommandLine $null).IsStale | Should -BeFalse
    }

    It "honours a custom idle threshold" {
        (Get-DevKitNodeStaleVerdict -IdleMinutes 45 -PortCount 0 -AgeMinutes 300 -MemoryMB 10 -CommandLine 'node seed.js' -IdleThresholdMinutes 60).IsStale | Should -BeFalse
    }
}
