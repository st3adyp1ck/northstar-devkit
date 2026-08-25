#!/usr/bin/env pwsh
<#
.SYNOPSIS
    PATH De-duplication Agreement - Northstar DevKit Unit Tests
.DESCRIPTION
    Verifies that Edit-Path.ps1's Get-DevKitDedupedPathEntries function and
    Shell-Reload.ps1's Get-DevKitDedupedPathEntries function agree on how
    PATH entries are normalized and deduplicated: trimmed whitespace, a
    single trailing backslash stripped, and compared case-insensitively.

    This test extracts ONLY the dedup function's source via the PowerShell
    AST from each script and defines it under a distinct name - it never
    dot-sources or executes Edit-Path.ps1 / Shell-Reload.ps1 themselves,
    since those scripts mutate real PATH/environment state.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.EXAMPLE
    Invoke-Pester -Path .\tests\Unit\PathDedup.Tests.ps1
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:EditPathScript = Join-Path (Join-Path $script:RepoRoot "tools\system") "Edit-Path.ps1"
    $script:ShellReloadScript = Join-Path (Join-Path $script:RepoRoot "tools\system") "Shell-Reload.ps1"

    function Get-DevKitFunctionSource {
        <#
            Extracts a single function definition's source text from a
            script file via the PowerShell AST, without executing anything
            in that file.
        #>
        param(
            [Parameter(Mandatory = $true)]
            [string]$ScriptPath,

            [Parameter(Mandatory = $true)]
            [string]$FunctionName
        )

        if (-not (Test-Path -LiteralPath $ScriptPath)) {
            throw "Script not found: $ScriptPath"
        }

        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$parseErrors)

        $funcAst = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $FunctionName
        }, $true)

        if (-not $funcAst) {
            throw "Function '$FunctionName' not found in $ScriptPath"
        }

        return $funcAst.Extent.Text
    }

    # Pull ONLY the dedup function out of each script and define each copy
    # under a distinct name so both can be exercised side by side in the
    # same test process.
    $editPathSource = Get-DevKitFunctionSource -ScriptPath $script:EditPathScript -FunctionName 'Get-DevKitDedupedPathEntries'
    $editPathSource = $editPathSource -replace 'function\s+Get-DevKitDedupedPathEntries', 'function Get-EditPathDedupedEntries'
    . ([scriptblock]::Create($editPathSource))

    $shellReloadSource = Get-DevKitFunctionSource -ScriptPath $script:ShellReloadScript -FunctionName 'Get-DevKitDedupedPathEntries'
    $shellReloadSource = $shellReloadSource -replace 'function\s+Get-DevKitDedupedPathEntries', 'function Get-ShellReloadDedupedEntries'
    . ([scriptblock]::Create($shellReloadSource))

    # Sample PATH entries: case-variant duplicates ("C:\Windows" / "c:\windows"),
    # a trailing-backslash variant ("C:\Windows\"), and a whitespace variant.
    $script:SampleEntries = @(
        'C:\Windows',
        'C:\Windows\System32',
        'c:\windows',
        'C:\Windows\',
        'C:\Program Files\Git\cmd',
        '  C:\Tools  ',
        'C:\Tools\',
        'C:\Users\Test\AppData\Local\Programs\Python\Python312'
    )
}

Describe "PATH de-duplication agreement between Edit-Path.ps1 and Shell-Reload.ps1" {

    It "both scripts' dedup functions produce identical results for the same input" {
        $editPathResult = @(Get-EditPathDedupedEntries -Entries $script:SampleEntries)
        $shellReloadResult = @(Get-ShellReloadDedupedEntries -Entries $script:SampleEntries)

        $shellReloadResult.Count | Should -Be $editPathResult.Count
        for ($i = 0; $i -lt $editPathResult.Count; $i++) {
            $shellReloadResult[$i] | Should -Be $editPathResult[$i]
        }
    }

    It "collapses 'C:\Windows', 'c:\windows', and 'C:\Windows\' into a single entry (Edit-Path)" {
        $result = @(Get-EditPathDedupedEntries -Entries $script:SampleEntries)
        $matches = @($result | Where-Object { $_.Trim().TrimEnd('\').ToLowerInvariant() -eq 'c:\windows' })
        $matches.Count | Should -Be 1
    }

    It "collapses 'C:\Windows', 'c:\windows', and 'C:\Windows\' into a single entry (Shell-Reload)" {
        $result = @(Get-ShellReloadDedupedEntries -Entries $script:SampleEntries)
        $matches = @($result | Where-Object { $_.Trim().TrimEnd('\').ToLowerInvariant() -eq 'c:\windows' })
        $matches.Count | Should -Be 1
    }

    It "collapses '  C:\Tools  ' and 'C:\Tools\' into a single entry" {
        $result = @(Get-EditPathDedupedEntries -Entries $script:SampleEntries)
        $matches = @($result | Where-Object { $_.Trim().TrimEnd('\').ToLowerInvariant() -eq 'c:\tools' })
        $matches.Count | Should -Be 1
    }

    It "keeps distinct entries that are not duplicates of anything" {
        $result = @(Get-EditPathDedupedEntries -Entries $script:SampleEntries)
        $result | Should -Contain 'C:\Windows\System32'
        $result | Should -Contain 'C:\Program Files\Git\cmd'
        $result | Should -Contain 'C:\Users\Test\AppData\Local\Programs\Python\Python312'
    }

    It "reduces the 8 sample entries down to 5 unique normalized entries" {
        $result = @(Get-EditPathDedupedEntries -Entries $script:SampleEntries)
        $result.Count | Should -Be 5
    }

    It "handles an empty entry list without error" {
        { Get-EditPathDedupedEntries -Entries @() } | Should -Not -Throw
        { Get-ShellReloadDedupedEntries -Entries @() } | Should -Not -Throw
        @(Get-EditPathDedupedEntries -Entries @()).Count | Should -Be 0
    }
}
