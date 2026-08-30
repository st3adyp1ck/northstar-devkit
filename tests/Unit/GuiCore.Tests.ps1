#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pester tests for the DevKit GUI pure-logic core (core/DevKit-GuiCore.ps1)
.DESCRIPTION
    Covers the GUI's argument resolution (which must mirror Invoke-DevKitTool
    semantics exactly), the shell-quoting helpers, the terminal launch
    command builder, and catalog loading against the real manifests - the
    last of which doubles as a manifest/script integrity check for the repo.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:CommonModule = Join-Path (Join-Path $script:RepoRoot "tools\lib") "DevKit-Common.ps1"
    # See Get-DevKitPackageManager.Tests.ps1 for why this flag reset matters
    # when several test files run in one Pester process.
    $global:DevKitCommonLoaded = $false
    . $script:CommonModule
    . (Join-Path (Join-Path $script:RepoRoot "core") "DevKit-GuiCore.ps1")
}

Describe "ConvertTo-DevKitToolArguments" {

    It "maps RequiresProject to the default 'Path' argument" {
        $item = @{ Label = 'X'; RequiresProject = $true; Script = 'x.ps1' }
        $args = ConvertTo-DevKitToolArguments -Item $item -Values @{ Path = 'C:\proj' }
        $args['Path'] | Should -Be 'C:\proj'
    }

    It "honors a custom ProjectArgName" {
        $item = @{ Label = 'X'; RequiresProject = $true; ProjectArgName = 'ProjectPath'; Script = 'x.ps1' }
        $args = ConvertTo-DevKitToolArguments -Item $item -Values @{ ProjectPath = 'C:\proj' }
        $args['ProjectPath'] | Should -Be 'C:\proj'
        $args.Contains('Path') | Should -BeFalse
    }

    It "throws when a required project path is missing" {
        $item = @{ Label = 'X'; RequiresProject = $true; Script = 'x.ps1' }
        { ConvertTo-DevKitToolArguments -Item $item -Values @{} } | Should -Throw
    }

    It "maps RequiresFile to the manifest's ParamName" {
        $item = @{ Label = 'X'; RequiresFile = @{ ParamName = 'EnvFile'; Filter = '*.env' }; Script = 'x.ps1' }
        $args = ConvertTo-DevKitToolArguments -Item $item -Values @{ EnvFile = 'C:\a\.env' }
        $args['EnvFile'] | Should -Be 'C:\a\.env'
    }

    It "parses Int prompts and enforces Min/Max" {
        $item = @{
            Label = 'X'; Script = 'x.ps1'
            Prompts = @(@{ Name = 'Port'; Type = 'Int'; Prompt = 'port'; Min = 1; Max = 65535; InvalidMessage = 'Invalid port number.' })
        }
        (ConvertTo-DevKitToolArguments -Item $item -Values @{ Port = '3000' })['Port'] | Should -Be 3000
        { ConvertTo-DevKitToolArguments -Item $item -Values @{ Port = '70000' } } | Should -Throw 'Invalid port number.'
        { ConvertTo-DevKitToolArguments -Item $item -Values @{ Port = '0' } } | Should -Throw 'Invalid port number.'
        { ConvertTo-DevKitToolArguments -Item $item -Values @{ Port = 'abc' } } | Should -Throw 'Invalid port number.'
    }

    It "adds a YesNo prompt only when true" {
        $item = @{
            Label = 'X'; Script = 'x.ps1'
            Prompts = @(@{ Name = 'Recurse'; Type = 'YesNo'; Prompt = 'recurse?' })
        }
        (ConvertTo-DevKitToolArguments -Item $item -Values @{ Recurse = $true })['Recurse'] | Should -BeTrue
        (ConvertTo-DevKitToolArguments -Item $item -Values @{ Recurse = $false }).Contains('Recurse') | Should -BeFalse
    }

    It "skips blank Optional prompts but rejects blank required ones" {
        $item = @{
            Label = 'X'; Script = 'x.ps1'
            Prompts = @(
                @{ Name = 'Note'; Type = 'String'; Prompt = 'note'; Optional = $true }
                @{ Name = 'Name'; Type = 'String'; Prompt = 'name' }
            )
        }
        $args = ConvertTo-DevKitToolArguments -Item $item -Values @{ Note = ''; Name = 'ok' }
        $args.Contains('Note') | Should -BeFalse
        { ConvertTo-DevKitToolArguments -Item $item -Values @{ Name = '' } } | Should -Throw
    }

    It "merges StaticArgs last so they win" {
        $item = @{
            Label = 'X'; Script = 'x.ps1'
            Prompts = @(@{ Name = 'Force'; Type = 'YesNo'; Prompt = 'force?' })
            StaticArgs = @{ Force = $true; InfoOnly = $true }
        }
        $args = ConvertTo-DevKitToolArguments -Item $item -Values @{ Force = $false }
        $args['Force'] | Should -BeTrue
        $args['InfoOnly'] | Should -BeTrue
    }
}

Describe "Shell argument rendering" {

    It "Format-DevKitShellArgument quotes only when needed" {
        Format-DevKitShellArgument -Value 'plain' | Should -Be 'plain'
        Format-DevKitShellArgument -Value 'C:\No Spaces' | Should -Be '"C:\No Spaces"'
        Format-DevKitShellArgument -Value 'say "hi"' | Should -Be '"say \"hi\""'
    }

    It "ConvertTo-DevKitArgumentString renders switches, numbers, and strings" {
        $result = ConvertTo-DevKitArgumentString -Arguments ([ordered]@{
            Force    = $true
            Skip     = $false
            Port     = 3000
            Path     = 'C:\My Project'
            Nothing  = $null
        })
        $result | Should -Be '-Force -Port 3000 -Path "C:\My Project"'
    }

    It "ConvertTo-DevKitArgumentString renders Int 1 by value, not as a bare switch" {
        # [int]1 -eq $true in PowerShell - a type-first branch must win over
        # the switch test or the launched command gets a valueless '-Port'.
        $result = ConvertTo-DevKitArgumentString -Arguments ([ordered]@{ Port = 1 })
        $result | Should -Be '-Port 1'
    }

    It "ConvertTo-DevKitArgumentString renders Int 0 by value instead of dropping it" {
        # 0 -eq $false in PowerShell - it must not be treated as "switch off".
        $result = ConvertTo-DevKitArgumentString -Arguments ([ordered]@{ Port = 0 })
        $result | Should -Be '-Port 0'
    }
}

Describe "Get-DevKitTerminalCommand" {

    BeforeEach {
        $script:scriptPath = Join-Path $script:RepoRoot 'tools\ports\Scan-Ports.ps1'
    }

    It "uses Windows Terminal with pwsh when both exist" {
        Mock Get-Command { return @{ Source = 'x' } } -ParameterFilter { $true }
        $launch = Get-DevKitTerminalCommand -ScriptPath $script:scriptPath -WorkingDirectory $script:RepoRoot -Title 'Scan Ports'
        $launch.FilePath | Should -Be 'wt.exe'
        $launch.Terminal | Should -Be 'WindowsTerminal'
        $launch.Shell | Should -Be 'pwsh'
        $launch.Arguments | Should -Match '--title "Scan Ports"'
        $launch.Arguments | Should -Match '-NoExit'
        $launch.Arguments | Should -Match '-File'
    }

    It "falls back to the console host when wt is missing" {
        Mock Get-Command {
            param($Name, $ErrorAction)
            if ($Name -eq 'pwsh') { return @{ Source = 'x' } }
            return $null
        }
        $launch = Get-DevKitTerminalCommand -ScriptPath $script:scriptPath -WorkingDirectory $script:RepoRoot
        $launch.FilePath | Should -Be 'pwsh.exe'
        $launch.Terminal | Should -Be 'ConsoleHost'
    }

    It "honors -NoWindowsTerminal even when wt exists" {
        Mock Get-Command { return @{ Source = 'x' } }
        $launch = Get-DevKitTerminalCommand -ScriptPath $script:scriptPath -WorkingDirectory $script:RepoRoot -NoWindowsTerminal
        $launch.FilePath | Should -Be 'pwsh.exe'
    }

    It "falls back to Windows PowerShell when pwsh is missing" {
        Mock Get-Command {
            param($Name, $ErrorAction)
            if ($Name -eq 'powershell') { return @{ Source = 'x' } }
            return $null
        }
        $launch = Get-DevKitTerminalCommand -ScriptPath $script:scriptPath -WorkingDirectory $script:RepoRoot
        $launch.Shell | Should -Be 'powershell'
    }

    It "reports a null FilePath when no shell exists at all" {
        Mock Get-Command { return $null }
        $launch = Get-DevKitTerminalCommand -ScriptPath $script:scriptPath -WorkingDirectory $script:RepoRoot
        $launch.FilePath | Should -BeNullOrEmpty
    }
}

Describe "Get-DevKitGuiCatalog (against the real manifests)" {

    BeforeAll {
        $script:catalog = Get-DevKitGuiCatalog -RootPath $script:RepoRoot
    }

    It "loads all 12 tool categories in 5 groups" {
        $script:catalog.Count | Should -Be 5
        $moduleCount = ($script:catalog | ForEach-Object { $_.Modules.Count } | Measure-Object -Sum).Sum
        $moduleCount | Should -Be 12
    }

    It "every manifest item references a script that exists on disk" {
        foreach ($group in $script:catalog) {
            foreach ($module in $group.Modules) {
                foreach ($item in $module.Items) {
                    $item.Key | Should -Not -BeNullOrEmpty
                    $item.Label | Should -Not -BeNullOrEmpty
                    $item.Script | Should -Not -BeNullOrEmpty
                    Test-Path (Join-Path $module.FolderPath $item.Script) | Should -BeTrue -Because "$($module.Name) -> $($item.Label)"
                }
            }
        }
    }

    It "Search-DevKitGuiTools finds tools by label and help text" {
        # @() matters: without it a single hashtable result would report its
        # KEY count (3), not the number of matching tools.
        $hits = @(Search-DevKitGuiTools -Catalog $script:catalog -Keyword 'port')
        $hits.Count | Should -BeGreaterThan 0
        @($hits | Where-Object { $_.Item.Label -eq 'Scan Common Dev Ports' }).Count | Should -Be 1

        $none = @(Search-DevKitGuiTools -Catalog $script:catalog -Keyword 'zzz-no-such-tool-zzz')
        $none.Count | Should -Be 0
    }

    It "workflow manifest's Deep Close-Out entry carries its two opt-in switches" {
        $workflow = @($script:catalog | ForEach-Object { $_.Modules } | Where-Object { $_.Folder -eq 'workflow' })[0]
        $deep = @($workflow.Items | Where-Object { $_.Script -eq 'Close-OutSession.ps1' -and $_.StaticArgs -and $_.StaticArgs['IncludeRecycleBin'] })
        $deep.Count | Should -Be 1
        $deep[0].StaticArgs['IncludePackageCache'] | Should -BeTrue
        # And the static args survive argument resolution as the switches the
        # script itself declares (StaticArgs merge last and win).
        $rendered = ConvertTo-DevKitToolArguments -Item $deep[0] -Values @{}
        $rendered['IncludeRecycleBin'] | Should -BeTrue
        $rendered['IncludePackageCache'] | Should -BeTrue
        # The dry-run preview entry must NOT have grown the deep switches.
        $preview = @($workflow.Items | Where-Object { $_.Script -eq 'Close-OutSession.ps1' -and $_.StaticArgs -and $_.StaticArgs['DryRun'] })
        $preview.Count | Should -Be 1
        $preview[0].StaticArgs.Contains('IncludeRecycleBin') | Should -BeFalse
    }
}
