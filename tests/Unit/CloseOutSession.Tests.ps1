#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pester tests for the pure logic of workflow/Close-OutSession.ps1
.DESCRIPTION
    Covers the parts of the end-of-day cleanup tool that are pure functions
    of their inputs - the run plan, the port list, the ancestry walk and the
    protect-or-stop predicate that decide what may be killed, the docker
    "Total reclaimed space" parser, and the SUMMARY builder - plus the
    manifest contract (workflow/_module.psd1) that the CLI menu and the
    Control Center both render.

    NOTHING HERE STOPS A PROCESS OR DELETES A REAL FILE. Dot-sourcing
    Close-OutSession.ps1 is safe: the script returns immediately after
    defining its helpers when its InvocationName is '.' (the same guard
    WiFi-Scan.ps1 and Copy-EnvTemplate.ps1 use), so no plan is built, no
    prompt is shown, and no cleanup step runs. The only filesystem test
    measures files this file creates under TestDrive.
.NOTES
    Pester 5 syntax (dashed `Should -Be`).
    Run with:
        Invoke-Pester -Path .\tests\Unit\CloseOutSession.Tests.ps1
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ScriptPath = Join-Path $script:RepoRoot 'tools\workflow\Close-OutSession.ps1'
    $script:ManifestPath = Join-Path $script:RepoRoot 'tools\workflow\_module.psd1'

    # See Get-DevKitPackageManager.Tests.ps1 for why this load-once flag gets
    # reset when several test files share one Pester process.
    $global:DevKitCommonLoaded = $false
    . $script:ScriptPath

    # A synthetic process table in the shape Get-CimInstance Win32_Process
    # returns: 4200 (this tool) <- 3100 (sidecar) <- 2200 (node, e.g. a
    # `pnpm tauri dev` harness) <- 1100 (explorer). 9000 is unrelated.
    $script:SampleProcesses = @(
        [PSCustomObject]@{ ProcessId = 4200; ParentProcessId = 3100; Name = 'pwsh.exe' }
        [PSCustomObject]@{ ProcessId = 3100; ParentProcessId = 2200; Name = 'pwsh.exe' }
        [PSCustomObject]@{ ProcessId = 2200; ParentProcessId = 1100; Name = 'node.exe' }
        [PSCustomObject]@{ ProcessId = 1100; ParentProcessId = 900; Name = 'explorer.exe' }
        [PSCustomObject]@{ ProcessId = 9000; ParentProcessId = 1100; Name = 'node.exe' }
    )
}

Describe "Close-OutSession dot-source guard" {

    It "defines its pure helpers without running any cleanup step" {
        Get-Command Format-DevKitCloseOutSummary -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command New-DevKitCloseOutPlan -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Get-DevKitCloseOutProtectReason -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe "Format-DevKitCloseOutSize" {

    It "reports a raw byte count under 1 KB" {
        Format-DevKitCloseOutSize 512 | Should -Be "512 B"
    }

    It "reports zero as '0 B' rather than an empty or negative-looking value" {
        Format-DevKitCloseOutSize 0 | Should -Be "0 B"
    }

    # The numeric part is culture-formatted (N2), so the separator is matched
    # loosely; the UNIT choice is what these assertions actually pin down.
    It "switches to KB at 1 KB" {
        Format-DevKitCloseOutSize 1536 | Should -Match '^1[.,]50 KB$'
    }

    It "switches to MB at 1 MB" {
        Format-DevKitCloseOutSize (2.5 * 1MB) | Should -Match '^2[.,]50 MB$'
    }

    It "switches to GB at 1 GB" {
        Format-DevKitCloseOutSize (1.5 * 1GB) | Should -Match '^1[.,]50 GB$'
    }
}

Describe "Get-DevKitCloseOutPortList" {

    It "returns the dev ports only, sorted, with no database ports by default" {
        $ports = Get-DevKitCloseOutPortList
        $ports.Count | Should -Be 14
        $ports[0] | Should -Be 1337
        $ports | Should -Not -Contain 5432
        $ports | Should -Not -Contain 27017
        ($ports | Sort-Object) -join ',' | Should -Be ($ports -join ',')
    }

    It "adds the database ports only when asked" {
        $ports = Get-DevKitCloseOutPortList -IncludeDatabasePorts
        $ports.Count | Should -Be 18
        $ports | Should -Contain 3306
        $ports | Should -Contain 5432
        $ports | Should -Contain 6379
        $ports | Should -Contain 27017
    }

    It "merges extra ports in sorted order" {
        $ports = Get-DevKitCloseOutPortList -ExtraPort @(4000, 2)
        $ports | Should -Contain 4000
        $ports[0] | Should -Be 2
        $ports.Count | Should -Be 16
    }

    It "de-duplicates an extra port that is already a default dev port" {
        $ports = Get-DevKitCloseOutPortList -ExtraPort @(3000, 3000)
        $ports.Count | Should -Be 14
        @($ports | Where-Object { $_ -eq 3000 }).Count | Should -Be 1
    }

    It "drops an out-of-range extra port instead of trying to check it" {
        $ports = Get-DevKitCloseOutPortList -ExtraPort @(0, 70000, 4000)
        $ports | Should -Not -Contain 0
        $ports | Should -Not -Contain 70000
        $ports | Should -Contain 4000
    }

    It "still returns a real array when nothing extra is passed" {
        $ports = Get-DevKitCloseOutPortList
        , $ports | Should -BeOfType [System.Object[]]
    }
}

Describe "Get-DevKitCloseOutAncestry" {

    It "returns self first, then each ancestor, nearest first" {
        $chain = Get-DevKitCloseOutAncestry -ProcessId 4200 -Processes $script:SampleProcesses
        $chain[0] | Should -Be 4200
        $chain[1] | Should -Be 3100
        $chain[2] | Should -Be 2200
        $chain[3] | Should -Be 1100
    }

    It "includes an ancestor node process, which is what keeps a dev harness alive" {
        $chain = Get-DevKitCloseOutAncestry -ProcessId 4200 -Processes $script:SampleProcesses
        $chain | Should -Contain 2200
    }

    It "does NOT include an unrelated sibling process" {
        $chain = Get-DevKitCloseOutAncestry -ProcessId 4200 -Processes $script:SampleProcesses
        $chain | Should -Not -Contain 9000
    }

    It "stops at a parent that is not present in the table" {
        $chain = Get-DevKitCloseOutAncestry -ProcessId 1100 -Processes $script:SampleProcesses
        $chain.Count | Should -Be 2
        $chain[1] | Should -Be 900
    }

    It "returns just the pid itself when the process table is empty" {
        $chain = Get-DevKitCloseOutAncestry -ProcessId 4200 -Processes @()
        $chain.Count | Should -Be 1
        $chain[0] | Should -Be 4200
    }

    It "terminates on a pid-reuse cycle instead of spinning forever" {
        $cyclic = @(
            [PSCustomObject]@{ ProcessId = 10; ParentProcessId = 20 }
            [PSCustomObject]@{ ProcessId = 20; ParentProcessId = 10 }
        )
        $chain = Get-DevKitCloseOutAncestry -ProcessId 10 -Processes $cyclic
        $chain.Count | Should -Be 2
        $chain | Should -Contain 20
    }

    It "ignores rows whose ids are not numbers" {
        $junk = @(
            [PSCustomObject]@{ ProcessId = 'not-a-pid'; ParentProcessId = 'nope' }
            [PSCustomObject]@{ ProcessId = 4200; ParentProcessId = 3100 }
            $null
        )
        $chain = Get-DevKitCloseOutAncestry -ProcessId 4200 -Processes $junk
        $chain.Count | Should -Be 2
        $chain[1] | Should -Be 3100
    }

    It "returns a real array even for a single-element chain" {
        $chain = Get-DevKitCloseOutAncestry -ProcessId 4200 -Processes @()
        , $chain | Should -BeOfType [System.Object[]]
    }
}

Describe "Get-DevKitCloseOutProtectReason" {

    It "allows a plain node process" {
        Get-DevKitCloseOutProtectReason -ProcessId 5555 -Name 'node' | Should -BeNullOrEmpty
    }

    It "strips a .exe suffix before matching, case-insensitively" {
        Get-DevKitCloseOutProtectReason -ProcessId 5555 -Name 'Node.EXE' | Should -BeNullOrEmpty
    }

    It "refuses the reserved pids 0 and 4" {
        Get-DevKitCloseOutProtectReason -ProcessId 0 -Name 'node' | Should -Match 'reserved system process'
        Get-DevKitCloseOutProtectReason -ProcessId 4 -Name 'node' | Should -Match 'reserved system process'
    }

    It "refuses a negative pid" {
        Get-DevKitCloseOutProtectReason -ProcessId -1 -Name 'node' | Should -Match 'reserved system process'
    }

    It "refuses any pid in DevKit's own process tree, even a node one" {
        $reason = Get-DevKitCloseOutProtectReason -ProcessId 2200 -Name 'node' -ProtectedPids @(4200, 3100, 2200)
        $reason | Should -Match "DevKit's own process tree"
    }

    It "refuses a protected system process by name" {
        Get-DevKitCloseOutProtectReason -ProcessId 800 -Name 'svchost' | Should -Match 'protected system process'
    }

    It "still refuses a protected system process under -AllowAnyOwner" {
        Get-DevKitCloseOutProtectReason -ProcessId 800 -Name 'svchost' -AllowAnyOwner | Should -Match 'protected system process'
    }

    It "refuses an unrecognized port owner by default and names the escape hatch" {
        $reason = Get-DevKitCloseOutProtectReason -ProcessId 5555 -Name 'sqlservr'
        $reason | Should -Match 'not a recognized dev runtime'
        $reason | Should -Match '-KillAnyPortOwner'
    }

    It "allows an unrecognized port owner once -AllowAnyOwner is passed" {
        Get-DevKitCloseOutProtectReason -ProcessId 5555 -Name 'sqlservr' -AllowAnyOwner | Should -BeNullOrEmpty
    }

    It "refuses an empty/unknown process name rather than guessing" {
        Get-DevKitCloseOutProtectReason -ProcessId 5555 -Name '' | Should -Match 'not a recognized dev runtime'
    }

    It "checks the own-tree rule before the name rules, so no name can override it" {
        $reason = Get-DevKitCloseOutProtectReason -ProcessId 4200 -Name 'node' -ProtectedPids @(4200) -AllowAnyOwner
        $reason | Should -Match "DevKit's own process tree"
    }
}

Describe "New-DevKitCloseOutPlan" {

    It "enables exactly the safe default subset" {
        $plan = New-DevKitCloseOutPlan -PortCount 14
        $enabled = @($plan | Where-Object { $_.Enabled } | ForEach-Object { $_.Key })
        $enabled | Should -Contain 'node'
        $enabled | Should -Contain 'ports'
        $enabled | Should -Contain 'junk'
        $enabled | Should -Contain 'memory'
        $enabled.Count | Should -Be 4
    }

    It "leaves every opt-in step off by default, each with the switch that turns it on" {
        $plan = New-DevKitCloseOutPlan -PortCount 14
        ($plan | Where-Object { $_.Key -eq 'docker' }).Enabled | Should -Be $false
        ($plan | Where-Object { $_.Key -eq 'docker' }).SkipReason | Should -Match '-IncludeDocker'
        ($plan | Where-Object { $_.Key -eq 'packagecache' }).Enabled | Should -Be $false
        ($plan | Where-Object { $_.Key -eq 'packagecache' }).SkipReason | Should -Match '-IncludePackageCache'
        ($plan | Where-Object { $_.Key -eq 'projectcache' }).Enabled | Should -Be $false
        ($plan | Where-Object { $_.Key -eq 'projectcache' }).SkipReason | Should -Match 'no -ProjectPath'
    }

    It "turns off a default step when its Skip switch is passed, and says which one" {
        $plan = New-DevKitCloseOutPlan -SkipNode -SkipPorts -SkipJunk -SkipMemory
        @($plan | Where-Object { $_.Enabled }).Count | Should -Be 0
        ($plan | Where-Object { $_.Key -eq 'node' }).SkipReason | Should -Match '-SkipNode'
        ($plan | Where-Object { $_.Key -eq 'ports' }).SkipReason | Should -Match '-SkipPorts'
        ($plan | Where-Object { $_.Key -eq 'junk' }).SkipReason | Should -Match '-SkipJunk'
        ($plan | Where-Object { $_.Key -eq 'memory' }).SkipReason | Should -Match '-SkipMemory'
    }

    It "enables the project cache step only when a project path is supplied" {
        $plan = New-DevKitCloseOutPlan -ProjectPath 'C:\dev\my-app'
        $step = $plan | Where-Object { $_.Key -eq 'projectcache' }
        $step.Enabled | Should -Be $true
        $step.Detail | Should -Match 'C:\\dev\\my-app'
        $step.Detail | Should -Match 'never node_modules'
    }

    It "treats a whitespace-only project path as no project at all" {
        $plan = New-DevKitCloseOutPlan -ProjectPath '   '
        ($plan | Where-Object { $_.Key -eq 'projectcache' }).Enabled | Should -Be $false
    }

    It "mentions the Recycle Bin in the junk step only when it is opted in" {
        (New-DevKitCloseOutPlan | Where-Object { $_.Key -eq 'junk' }).Detail | Should -Not -Match 'Recycle Bin'
        (New-DevKitCloseOutPlan -IncludeRecycleBin | Where-Object { $_.Key -eq 'junk' }).Detail | Should -Match 'Recycle Bin'
    }

    It "reports the port count it was given, so the plan and the run cannot disagree" {
        (New-DevKitCloseOutPlan -PortCount 18 | Where-Object { $_.Key -eq 'ports' }).Detail | Should -Match '18 dev port'
    }

    It "marks the working-set trim as the only non-destructive step" {
        $plan = New-DevKitCloseOutPlan
        @($plan | Where-Object { -not $_.Destructive } | ForEach-Object { $_.Key }) | Should -Be @('memory')
    }

    It "stops processes before it measures or deletes, and trims memory last" {
        $keys = @(New-DevKitCloseOutPlan | ForEach-Object { $_.Key })
        $keys[0] | Should -Be 'node'
        $keys[1] | Should -Be 'ports'
        $keys[-1] | Should -Be 'memory'
        $keys.IndexOf('junk') | Should -BeLessThan $keys.IndexOf('memory')
    }

    It "gives every step a skip reason when disabled and none when enabled" {
        $plan = New-DevKitCloseOutPlan -SkipNode -IncludeDocker
        foreach ($step in $plan) {
            if ($step.Enabled) {
                $step.SkipReason | Should -BeNullOrEmpty
            } else {
                $step.SkipReason | Should -Not -BeNullOrEmpty
            }
        }
    }
}

Describe "Format-DevKitCloseOutSummary" {

    BeforeAll {
        $script:SampleSteps = @(
            (New-DevKitCloseOutResult -Key 'node' -Title 'Node processes' -Status 'done' -Detail 'stopped 3 node process(es)')
            (New-DevKitCloseOutResult -Key 'ports' -Title 'Dev ports' -Status 'nothing' -Detail 'all 14 checked port(s) already free')
            (New-DevKitCloseOutResult -Key 'docker' -Title 'Docker' -Status 'skipped' -Detail '-IncludeDocker not passed')
            (New-DevKitCloseOutResult -Key 'junk' -Title 'Temp and junk' -Status 'done' -Detail 'reclaimed 1.00 GB' -FreedBytes 1GB)
            (New-DevKitCloseOutResult -Key 'memory' -Title 'Memory' -Status 'done' -Detail 'trimmed 512.0 MB' -FreedMemoryMB 512)
        )
    }

    It "opens with a SUMMARY header" {
        $lines = Format-DevKitCloseOutSummary -Steps $script:SampleSteps
        $lines[0] | Should -Match 'SUMMARY'
    }

    It "lists every step, including the skipped ones and why" {
        $lines = Format-DevKitCloseOutSummary -Steps $script:SampleSteps
        ($lines -join "`n") | Should -Match 'Docker\s+skipped - -IncludeDocker not passed'
    }

    It "renders a 'nothing to do' step as such, which is what a second run looks like" {
        $lines = Format-DevKitCloseOutSummary -Steps $script:SampleSteps
        ($lines -join "`n") | Should -Match 'Dev ports\s+nothing to do - all 14 checked'
    }

    It "totals the disk bytes every step reported" {
        $lines = Format-DevKitCloseOutSummary -Steps $script:SampleSteps
        ($lines -join "`n") | Should -Match 'Disk reclaimed\s+1[.,]00 GB'
    }

    It "totals the memory every step reported, in readable units" {
        $lines = Format-DevKitCloseOutSummary -Steps $script:SampleSteps
        ($lines -join "`n") | Should -Match 'Memory reclaimed\s+512[.,]00 MB'
    }

    It "scales a multi-gigabyte memory total instead of printing five-digit megabytes" {
        $steps = @(New-DevKitCloseOutResult -Key 'memory' -Title 'Memory' -Status 'done' -Detail 'trimmed' -FreedMemoryMB 4096)
        ((Format-DevKitCloseOutSummary -Steps $steps) -join "`n") | Should -Match 'Memory reclaimed\s+4[.,]00 GB'
    }

    It "prefixes a preview step with 'would' and never claims anything changed" {
        $steps = @(New-DevKitCloseOutResult -Key 'node' -Title 'Node processes' -Status 'preview' -Detail 'stop 3 node process(es)')
        $text = (Format-DevKitCloseOutSummary -Steps $steps -Preview) -join "`n"
        $text | Should -Match 'would stop 3 node process'
        $text | Should -Match 'nothing was stopped, deleted, or changed'
        $text | Should -Not -Match 'Disk reclaimed'
    }

    It "says so plainly when a real run had nothing to do" {
        $steps = @(
            (New-DevKitCloseOutResult -Key 'node' -Title 'Node processes' -Status 'nothing' -Detail 'no node processes were running')
            (New-DevKitCloseOutResult -Key 'docker' -Title 'Docker' -Status 'skipped' -Detail '-IncludeDocker not passed')
        )
        ((Format-DevKitCloseOutSummary -Steps $steps) -join "`n") | Should -Match 'Already clean - nothing needed doing'
    }

    It "does NOT claim 'already clean' when a step actually did something" {
        ((Format-DevKitCloseOutSummary -Steps $script:SampleSteps) -join "`n") | Should -Not -Match 'Already clean'
    }

    It "surfaces an errored step as an ERROR line rather than hiding it" {
        $steps = @(New-DevKitCloseOutResult -Key 'docker' -Title 'Docker' -Status 'error' -Detail 'daemon went away')
        ((Format-DevKitCloseOutSummary -Steps $steps) -join "`n") | Should -Match 'Docker\s+ERROR - daemon went away'
    }

    It "handles being handed no steps at all" {
        $lines = Format-DevKitCloseOutSummary -Steps @()
        ($lines -join "`n") | Should -Match 'no steps ran'
    }

    It "ignores a negative freed value instead of subtracting from the total" {
        $steps = @(
            (New-DevKitCloseOutResult -Key 'junk' -Title 'Temp and junk' -Status 'done' -Detail 'x' -FreedBytes -500)
            (New-DevKitCloseOutResult -Key 'docker' -Title 'Docker' -Status 'done' -Detail 'y' -FreedBytes 1000)
        )
        ((Format-DevKitCloseOutSummary -Steps $steps) -join "`n") | Should -Match 'Disk reclaimed\s+1000 B'
    }
}

Describe "New-DevKitCloseOutResult" {

    It "rejects a status the summary builder does not know how to render" {
        { New-DevKitCloseOutResult -Key 'node' -Title 'Node' -Status 'finished-ish' } | Should -Throw
    }

    It "defaults both freed counters to zero" {
        $result = New-DevKitCloseOutResult -Key 'node' -Title 'Node' -Status 'nothing'
        $result.FreedBytes | Should -Be 0
        $result.FreedMemoryMB | Should -Be 0
    }
}

Describe "ConvertFrom-DevKitCloseOutDockerReclaim" {

    It "parses a gigabyte figure using docker's decimal units" {
        ConvertFrom-DevKitCloseOutDockerReclaim -Text 'Total reclaimed space: 1.5GB' | Should -Be 1500000000
    }

    It "parses a megabyte figure" {
        ConvertFrom-DevKitCloseOutDockerReclaim -Text 'Total reclaimed space: 512MB' | Should -Be 512000000
    }

    It "parses a kilobyte figure" {
        ConvertFrom-DevKitCloseOutDockerReclaim -Text 'Total reclaimed space: 12.3kB' | Should -Be 12300
    }

    It "parses a plain byte figure" {
        ConvertFrom-DevKitCloseOutDockerReclaim -Text 'Total reclaimed space: 0B' | Should -Be 0
    }

    It "finds the line inside real multi-line prune output" {
        $output = @"
Deleted Containers:
9f2a1c0b7d3e

Total reclaimed space: 2.25MB
"@
        ConvertFrom-DevKitCloseOutDockerReclaim -Text $output | Should -Be 2250000
    }

    It "returns null when the output has no reclaimed line" {
        ConvertFrom-DevKitCloseOutDockerReclaim -Text 'Nothing to do.' | Should -BeNullOrEmpty
    }

    It "returns null for empty or null input" {
        ConvertFrom-DevKitCloseOutDockerReclaim -Text '' | Should -BeNullOrEmpty
        ConvertFrom-DevKitCloseOutDockerReclaim -Text $null | Should -BeNullOrEmpty
    }
}

Describe "Get-DevKitCloseOutPathSize" {

    BeforeAll {
        $script:SizedDir = Join-Path $TestDrive 'junk'
        $nested = Join-Path $script:SizedDir 'nested'
        New-Item -ItemType Directory -Path $nested -Force | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $script:SizedDir 'a.bin'), (New-Object byte[] 1000))
        [IO.File]::WriteAllBytes((Join-Path $nested 'b.bin'), (New-Object byte[] 2000))
        $script:EmptyDir = Join-Path $TestDrive 'empty'
        New-Item -ItemType Directory -Path $script:EmptyDir -Force | Out-Null
    }

    It "sums every file under the path, recursively" {
        Get-DevKitCloseOutPathSize -Path $script:SizedDir | Should -Be 3000
    }

    It "returns 0 for an empty folder" {
        Get-DevKitCloseOutPathSize -Path $script:EmptyDir | Should -Be 0
    }

    It "returns 0 for a path that does not exist instead of throwing" {
        Get-DevKitCloseOutPathSize -Path (Join-Path $TestDrive 'no-such-folder') | Should -Be 0
    }

    It "returns 0 for an empty path string" {
        Get-DevKitCloseOutPathSize -Path '' | Should -Be 0
    }
}

Describe "workflow/_module.psd1 registration" {

    BeforeAll {
        $script:Manifest = Import-PowerShellDataFile -Path $script:ManifestPath
        $script:CloseOutItems = @($script:Manifest.Items | Where-Object { $_.Script -eq 'Close-OutSession.ps1' })

        $parseErrors = $null
        $tokens = $null
        $script:ScriptAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScriptPath, [ref]$tokens, [ref]$parseErrors)
        $script:ParseErrors = $parseErrors
        $script:ParamNames = @($script:ScriptAst.ParamBlock.Parameters |
            ForEach-Object { $_.Name.VariablePath.UserPath })
    }

    It "parses with no syntax errors" {
        @($script:ParseErrors).Count | Should -Be 0
    }

    It "registers the tool three times: the real run, the dry-run preview, and the deep variant" {
        $script:CloseOutItems.Count | Should -Be 3
    }

    It "gives every item a unique key within the module" {
        $keys = @($script:Manifest.Items | ForEach-Object { $_.Key })
        @($keys | Select-Object -Unique).Count | Should -Be $keys.Count
    }

    It "does not require a project - system cleanup runs with nothing selected" {
        foreach ($item in $script:CloseOutItems) {
            [bool]$item.RequiresProject | Should -Be $false
        }
    }

    It "flags the real run as caution, because it really does stop and delete things" {
        $real = $script:CloseOutItems | Where-Object { -not $_.StaticArgs }
        $real.Help | Should -Match 'Safety note:'
    }

    It "does NOT flag the dry-run preview as caution, because it changes nothing" {
        $preview = $script:CloseOutItems | Where-Object { $_.StaticArgs -and $_.StaticArgs.ContainsKey('DryRun') }
        $preview | Should -Not -BeNullOrEmpty
        $preview.StaticArgs.DryRun | Should -Be $true
        $preview.Help | Should -Not -Match 'Safety note:'
    }

    It "flags the deep variant as caution and turns on exactly its two opt-in switches" {
        $deep = @($script:CloseOutItems | Where-Object { $_.StaticArgs -and $_.StaticArgs.ContainsKey('IncludeRecycleBin') })
        $deep.Count | Should -Be 1
        $deep[0].Help | Should -Match 'Safety note:'
        $deep[0].StaticArgs.IncludeRecycleBin | Should -Be $true
        $deep[0].StaticArgs.IncludePackageCache | Should -Be $true
        # The deep variant must not sneak in the dry-run switch - it is a
        # real run with extra scope, not a second preview.
        $deep[0].StaticArgs.ContainsKey('DryRun') | Should -Be $false
    }

    It "declares -Force, which is what lets the Control Center's confirm dialog run it" {
        $script:ParamNames | Should -Contain 'Force'
    }

    It "declares -DryRun, the parameter the preview item's StaticArgs sets" {
        $script:ParamNames | Should -Contain 'DryRun'
    }

    It "only ever declares StaticArgs the script actually has parameters for" {
        foreach ($item in $script:CloseOutItems) {
            if (-not $item.StaticArgs) { continue }
            foreach ($key in $item.StaticArgs.Keys) {
                $script:ParamNames | Should -Contain $key
            }
        }
    }

    It "only ever declares Prompts the script actually has parameters for" {
        foreach ($item in $script:CloseOutItems) {
            foreach ($prompt in @($item.Prompts)) {
                if (-not $prompt) { continue }
                $script:ParamNames | Should -Contain $prompt.Name
                $prompt.Type | Should -BeIn @('Int', 'String', 'YesNo')
            }
        }
    }

    It "documents each opt-in switch it names in the real run's help" {
        $real = $script:CloseOutItems | Where-Object { -not $_.StaticArgs }
        foreach ($switchName in @('IncludeRecycleBin', 'IncludeDocker', 'IncludePackageCache', 'IncludeDatabasePorts', 'KillAnyPortOwner', 'ProjectPath')) {
            $real.Help | Should -Match "-$switchName"
            $script:ParamNames | Should -Contain $switchName
        }
    }
}
