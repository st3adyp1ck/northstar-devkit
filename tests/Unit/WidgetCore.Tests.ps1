#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pester tests for the companion widget's pure logic (gui/DevKit-WidgetCore.ps1)
.DESCRIPTION
    Covers the nvidia-smi output parser, the 'claude mcp list' line parser
    (which drives the Connected/Disconnected/Requires Auth badges), the Kimi
    Code mcp.json config mapper (Configured/Disabled/RequiresAuth per the
    documented schema), and the port-by-process grouping used by the node
    snapshot.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    # See Get-DevKitPackageManager.Tests.ps1 for why these load-once flags
    # get reset when several test files share one Pester process.
    $global:DevKitCommonLoaded = $false
    . (Join-Path $script:RepoRoot 'lib\DevKit-Common.ps1')
    $global:DevKitWidgetCoreLoaded = $false
    . (Join-Path $script:RepoRoot 'gui\DevKit-WidgetCore.ps1')
}

Describe "ConvertFrom-DevKitNvidiaSmiOutput" {

    It "parses 'temp, util' output" {
        $r = ConvertFrom-DevKitNvidiaSmiOutput -Output '44, 0'
        $r.TempC | Should -Be 44
        $r.Percent | Should -Be 0
    }

    It "tolerates extra whitespace and trailing lines" {
        $r = ConvertFrom-DevKitNvidiaSmiOutput -Output "  53 ,  12 `nignored"
        $r.TempC | Should -Be 53
        $r.Percent | Should -Be 12
    }

    It "returns $null for unparsable output" {
        ConvertFrom-DevKitNvidiaSmiOutput -Output '' | Should -BeNullOrEmpty
        ConvertFrom-DevKitNvidiaSmiOutput -Output 'N/A' | Should -BeNullOrEmpty
    }
}

Describe "ConvertFrom-DevKitClaudeMcpLine" {

    It "parses a connected stdio server" {
        $r = ConvertFrom-DevKitClaudeMcpLine -Line "sequential-thinking: cmd /c npx -y @modelcontextprotocol/server-sequential-thinking - $([char]0x2714) Connected"
        $r.Name | Should -Be 'sequential-thinking'
        $r.Status | Should -Be 'Connected'
        $r.Target | Should -Be 'cmd /c npx -y @modelcontextprotocol/server-sequential-thinking'
    }

    It "parses a connected remote server whose name contains spaces and periods" {
        $r = ConvertFrom-DevKitClaudeMcpLine -Line "claude.ai Stripe: https://mcp.stripe.com - $([char]0x2714) Connected"
        $r.Name | Should -Be 'claude.ai Stripe'
        $r.Status | Should -Be 'Connected'
        $r.Target | Should -Be 'https://mcp.stripe.com'
    }

    It "maps failures to Disconnected" {
        $r = ConvertFrom-DevKitClaudeMcpLine -Line "broken-server: https://example.com/mcp - $([char]0x2717) Failed to connect"
        $r.Status | Should -Be 'Disconnected'
    }

    It "maps auth-needed to RequiresAuth" {
        $r = ConvertFrom-DevKitClaudeMcpLine -Line "private-api: https://example.com/mcp - Needs authentication"
        $r.Status | Should -Be 'RequiresAuth'
    }

    It "returns $null for header/blank lines" {
        ConvertFrom-DevKitClaudeMcpLine -Line '' | Should -BeNullOrEmpty
        ConvertFrom-DevKitClaudeMcpLine -Line 'Checking MCP server health...' | Should -BeNullOrEmpty
    }
}

Describe "ConvertFrom-DevKitKimiMcpConfig" {

    BeforeAll {
        $script:doc = [PSCustomObject]@{
            filesystem = [PSCustomObject]@{ command = 'npx'; args = @('-y', '@modelcontextprotocol/server-filesystem') }
            linear     = [PSCustomObject]@{ url = 'https://mcp.linear.app/mcp' }
            legacy     = [PSCustomObject]@{ transport = 'sse'; url = 'https://mcp.example.com/sse' }
            switchedOff = [PSCustomObject]@{ command = 'npx'; enabled = $false }
            needsToken = [PSCustomObject]@{ url = 'https://mcp.example.com/api'; bearerTokenEnvVar = 'DEVKIT_TEST_TOKEN_9F8E7D' }
        }
    }

    It "detects transport per documented field rules" {
        $rows = @(ConvertFrom-DevKitKimiMcpConfig -McpServers $script:doc -Scope 'User')
        ($rows | Where-Object Name -eq 'filesystem').Transport | Should -Be 'stdio'
        ($rows | Where-Object Name -eq 'linear').Transport | Should -Be 'http'
        ($rows | Where-Object Name -eq 'legacy').Transport | Should -Be 'sse'
    }

    It "marks enabled=false as Disabled" {
        $rows = @(ConvertFrom-DevKitKimiMcpConfig -McpServers $script:doc -Scope 'User')
        ($rows | Where-Object Name -eq 'switchedOff').Status | Should -Be 'Disabled'
    }

    It "marks a missing bearer-token env var as RequiresAuth, present as Configured" {
        [Environment]::SetEnvironmentVariable('DEVKIT_TEST_TOKEN_9F8E7D', $null)
        $rows = @(ConvertFrom-DevKitKimiMcpConfig -McpServers $script:doc -Scope 'User')
        ($rows | Where-Object Name -eq 'needsToken').Status | Should -Be 'RequiresAuth'

        [Environment]::SetEnvironmentVariable('DEVKIT_TEST_TOKEN_9F8E7D', 'x')
        try {
            $rows = @(ConvertFrom-DevKitKimiMcpConfig -McpServers $script:doc -Scope 'User')
            ($rows | Where-Object Name -eq 'needsToken').Status | Should -Be 'Configured'
        } finally {
            [Environment]::SetEnvironmentVariable('DEVKIT_TEST_TOKEN_9F8E7D', $null)
        }
    }

    It "returns no rows for a missing/empty mcpServers object" {
        @(ConvertFrom-DevKitKimiMcpConfig -McpServers $null -Scope 'User').Count | Should -Be 0
    }
}

Describe "Group-DevKitPortsByProcess" {

    It "groups, de-duplicates, and sorts ports per process" {
        $rows = @(
            [PSCustomObject]@{ OwningProcess = 100; LocalPort = 5173 }
            [PSCustomObject]@{ OwningProcess = 100; LocalPort = 3000 }
            [PSCustomObject]@{ OwningProcess = 100; LocalPort = 3000 }
            [PSCustomObject]@{ OwningProcess = 200; LocalPort = 8080 }
        )
        $map = Group-DevKitPortsByProcess -ListenRows $rows
        $map[100] | Should -Be @(3000, 5173)
        $map[200] | Should -Be @(8080)
    }

    It "keys by [int] so a UInt32 OwningProcess (Get-NetTCPConnection's real type) is still found by an Int32 PID (Get-Process's real type)" {
        $rows = @(
            [PSCustomObject]@{ OwningProcess = [uint32]4242; LocalPort = 5173 }
        )
        $map = Group-DevKitPortsByProcess -ListenRows $rows
        $map.ContainsKey([int]4242) | Should -BeTrue
        $map[[int]4242] | Should -Be @(5173)
    }
}

Describe "Get-DevKitKimiMcpStatus (project scope file handling)" {

    It "reads <project>/.kimi-code/mcp.json and lets project entries override user entries" {
        $projectDir = Join-Path $env:TEMP "devkit_kimi_status_test_$(Get-Random)"
        New-Item -ItemType Directory -Path $projectDir -Force | Out-Null
        try {
            Mock Get-DevKitWindowsExecutable { return @{ Source = 'C:\fake\kimi.exe' } }
            Mock Read-DevKitKimiMcpFile {
                param($Path)
                if ($Path -like "$projectDir*") {
                    # project-level file
                    return [PSCustomObject]@{ shared = [PSCustomObject]@{ url = 'https://project.example.com/mcp' } }
                }
                # user-level file
                return [PSCustomObject]@{
                    shared = [PSCustomObject]@{ url = 'https://user.example.com/mcp' }
                    userOnly = [PSCustomObject]@{ command = 'npx' }
                }
            }

            $status = Get-DevKitKimiMcpStatus -ProjectPath $projectDir
            $status.CliInstalled | Should -BeTrue
            $shared = $status.Servers | Where-Object Name -eq 'shared'
            $shared.Scope | Should -Be 'Project'
            $shared.Target | Should -Be 'https://project.example.com/mcp'
            ($status.Servers | Where-Object Name -eq 'userOnly').Scope | Should -Be 'User'
        } finally {
            Remove-Item -Path $projectDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}


Describe "ConvertFrom-DevKitGitDecorations" {

    It "parses 'HEAD -> branch' as the head ref" {
        $refs = ConvertFrom-DevKitGitDecorations -Raw ' (HEAD -> main, origin/main)'
        $refs.Count | Should -Be 2
        $refs[0].Kind | Should -Be 'head'
        $refs[0].Name | Should -Be 'main'
        $refs[1].Kind | Should -Be 'branch'
    }

    It "parses tags" {
        $refs = ConvertFrom-DevKitGitDecorations -Raw ' (tag: v1.2.0, main)'
        $refs[0].Kind | Should -Be 'tag'
        $refs[0].Name | Should -Be 'v1.2.0'
    }

    It "parses bare HEAD (detached checkout)" {
        $refs = ConvertFrom-DevKitGitDecorations -Raw ' (HEAD)'
        $refs.Count | Should -Be 1
        $refs[0].Kind | Should -Be 'head'
    }

    It "returns empty for empty/undecorated input" {
        ConvertFrom-DevKitGitDecorations -Raw '' | Should -BeNullOrEmpty
        ConvertFrom-DevKitGitDecorations -Raw ' ()' | Should -BeNullOrEmpty
    }
}

Describe "ConvertFrom-DevKitGitLogOutput" {

    BeforeAll {
        $script:rs = [char]0x1e; $script:us = [char]0x1f
        $script:h1 = 'a' * 40; $script:h2 = 'b' * 40
        $script:rec = { param($hash, $parents, $author, $when, $deco, $subject)
            return ('{0}{1}{2}{3}{4}{5}{6}{7}{8}{9}{10}' -f $rs, $hash, $us, $parents, $us, $author, $us, $when, $us, $deco, $us) + $subject
        }
    }

    It "parses a decorated record into all fields" {
        $out = & $rec $h1 $h2 'Jane Dev' '2 days ago' ' (HEAD -> main, tag: v1.0)' 'feat: shiny graph'
        $c = ConvertFrom-DevKitGitLogOutput -Output $out
        $c.Count | Should -Be 1
        $c[0].Hash | Should -Be $h1
        $c[0].ShortHash | Should -Be 'aaaaaaa'
        $c[0].Parents[0] | Should -Be $h2
        $c[0].Author | Should -Be 'Jane Dev'
        $c[0].When | Should -Be '2 days ago'
        $c[0].Subject | Should -Be 'feat: shiny graph'
        $c[0].Refs.Count | Should -Be 2
        $c[0].IsHead | Should -BeTrue
    }

    It "parses multiple records and multiple parents (merge)" {
        $out = ((& $rec $h1 "$h2 $h2" 'A' '1 day ago' '' 'merge') + "`n") + (& $rec $h2 '' 'B' '2 days ago' '' 'root')
        $c = ConvertFrom-DevKitGitLogOutput -Output $out
        $c.Count | Should -Be 2
        $c[0].Parents.Count | Should -Be 2
        $c[1].Parents.Count | Should -Be 0
        $c[1].IsHead | Should -BeFalse
    }

    It "returns empty for empty output" {
        ConvertFrom-DevKitGitLogOutput -Output '' | Should -BeNullOrEmpty
    }

    It "skips malformed records" {
        $out = ('{0}{1}{2}too-few-fields' -f $rs, $h1, $us)
        ConvertFrom-DevKitGitLogOutput -Output $out | Should -BeNullOrEmpty
    }
}

Describe "ConvertTo-DevKitGitGraphLayout" {

    BeforeAll {
        function New-TestCommit([string]$Hash, [string[]]$Parents) {
            return @{ Hash = $Hash; ShortHash = $Hash; Parents = $Parents; Refs = @(); Subject = 's'; Author = 'a'; When = 'w'; IsHead = $false }
        }
    }

    It "keeps linear history on one lane with straight links" {
        $commits = @( (New-TestCommit 'c3' @('c2')), (New-TestCommit 'c2' @('c1')), (New-TestCommit 'c1' @()) )
        $g = ConvertTo-DevKitGitGraphLayout -Commits $commits
        $g.LaneCount | Should -Be 1
        ($g.Nodes | ForEach-Object Lane) | Should -Be @(0, 0, 0)
        $g.Links.Count | Should -Be 2
        foreach ($l in $g.Links) { $l.FromLane | Should -Be $l.ToLane }
    }

    It "opens a lane for a merge's second parent and keeps the trunk straight" {
        # M merges B into A; B and A both descend from C (the fork point).
        $commits = @(
            (New-TestCommit 'M' @('A', 'B')),
            (New-TestCommit 'B' @('C')),
            (New-TestCommit 'A' @('C')),
            (New-TestCommit 'C' @())
        )
        $g = ConvertTo-DevKitGitGraphLayout -Commits $commits
        $g.LaneCount | Should -Be 2
        ($g.Nodes | Where-Object Hash -eq 'M').Lane | Should -Be 0
        ($g.Nodes | Where-Object Hash -eq 'B').Lane | Should -Be 1
        ($g.Nodes | Where-Object Hash -eq 'A').Lane | Should -Be 0
        # The first-parent trunk M -> A -> C never leaves lane 0...
        ($g.Nodes | Where-Object Hash -eq 'C').Lane | Should -Be 0
        # ...so the side branch B bends into it at the fork point C.
        ($g.Links | Where-Object { $_.FromRow -eq 1 -and $_.ToRow -eq 3 }).FromLane | Should -Be 1
        ($g.Links | Where-Object { $_.FromRow -eq 1 -and $_.ToRow -eq 3 }).ToLane | Should -Be 0
        # M -> B is the merge link.
        $mergeLinks = @($g.Links | Where-Object IsMerge)
        $mergeLinks.Count | Should -Be 1
        $mergeLinks[0].ToLane | Should -Be 1
    }

    It "opens one lane per extra parent for an octopus merge" {
        $commits = @(
            (New-TestCommit 'M' @('A', 'B', 'D')),
            (New-TestCommit 'B' @()),
            (New-TestCommit 'D' @()),
            (New-TestCommit 'A' @())
        )
        $g = ConvertTo-DevKitGitGraphLayout -Commits $commits
        $g.LaneCount | Should -Be 3
        (($g.Links | Where-Object IsMerge).Count) | Should -Be 2
    }

    It "skips parents outside the displayed set without inventing links" {
        $commits = @( (New-TestCommit 'c1' @('missing-parent')) )
        $g = ConvertTo-DevKitGitGraphLayout -Commits $commits
        $g.Nodes.Count | Should -Be 1
        $g.Links.Count | Should -Be 0
    }

    It "handles empty input" {
        $g = ConvertTo-DevKitGitGraphLayout -Commits @()
        $g.Nodes.Count | Should -Be 0
        $g.Links.Count | Should -Be 0
        $g.LaneCount | Should -Be 0
    }

    It "colors nodes and links from the lane palette" {
        $commits = @(
            (New-TestCommit 'M' @('A', 'B')),
            (New-TestCommit 'B' @()),
            (New-TestCommit 'A' @())
        )
        $g = ConvertTo-DevKitGitGraphLayout -Commits $commits
        ($g.Nodes | Where-Object Hash -eq 'M').Color | Should -Be (Get-DevKitGitLaneColor -Lane 0)
        ($g.Nodes | Where-Object Hash -eq 'B').Color | Should -Be (Get-DevKitGitLaneColor -Lane 1)
        $merge = $g.Links | Where-Object IsMerge
        $merge.FromColor | Should -Be (Get-DevKitGitLaneColor -Lane 0)
        $merge.ToColor | Should -Be (Get-DevKitGitLaneColor -Lane 1)
    }
}


Describe "Get-DevKitEnvKeyNames" {

    It "extracts names, skipping comments, blanks, and export prefixes" {
        $lines = @('# comment', '', 'API_URL=https://x', 'export LOG_LEVEL=debug', '  SPACED_KEY = 1', 'not a var line')
        $names = Get-DevKitEnvKeyNames -Lines $lines
        $names.Count | Should -Be 3
        $names -contains 'API_URL' | Should -BeTrue
        $names -contains 'LOG_LEVEL' | Should -BeTrue
        $names -contains 'SPACED_KEY' | Should -BeTrue
    }

    It "dedupes repeated keys and returns a true array for one key" {
        $names = Get-DevKitEnvKeyNames -Lines @('A=1', 'A=2')
        $names.Count | Should -Be 1
    }

    It "returns empty for empty input" {
        Get-DevKitEnvKeyNames -Lines @() | Should -BeNullOrEmpty
    }
}

Describe "Compare-DevKitEnvKeys" {

    It "reports missing, empty, and extra keys" {
        $template = @('A=1', 'B=2', 'C=3')
        $env = @('A=1', 'B=', 'D=4')
        $diff = Compare-DevKitEnvKeys -TemplateLines $template -EnvLines $env
        $diff.Missing | Should -Be @('C')
        $diff.Empty | Should -Be @('B')
        $diff.Extra | Should -Be @('D')
        $diff.TemplateKeyCount | Should -Be 3
    }

    It "treats quoted-empty values as empty" {
        $diff = Compare-DevKitEnvKeys -TemplateLines @('A=1') -EnvLines @('A=""')
        $diff.Empty | Should -Be @('A')
    }

    It "reports a missing .env file as all-missing" {
        $diff = Compare-DevKitEnvKeys -TemplateLines @('A=1', 'B=2') -EnvLines @()
        $diff.Missing.Count | Should -Be 2
    }
}

Describe "Test-DevKitPortExcluded" {

    It "finds ports inside ranges and rejects ports outside" {
        $ranges = @(@{ Start = 50000; End = 50059 }, @{ Start = 5357; End = 5357 })
        Test-DevKitPortExcluded -Port 50050 -Ranges $ranges | Should -BeTrue
        Test-DevKitPortExcluded -Port 5357 -Ranges $ranges | Should -BeTrue
        Test-DevKitPortExcluded -Port 3000 -Ranges $ranges | Should -BeFalse
        Test-DevKitPortExcluded -Port 50060 -Ranges $ranges | Should -BeFalse
    }

    It "handles an empty range list" {
        Test-DevKitPortExcluded -Port 3000 -Ranges @() | Should -BeFalse
    }
}
