#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pester tests for Get-DevKitEnvKeyNames (workflow/Compare-EnvFiles.ps1)
.DESCRIPTION
    Exercises the .env key-name extractor in isolation against in-memory
    line arrays - no real files are read. Covers plain KEY=value lines,
    comment and blank lines, the `export ` prefix, leading whitespace,
    keys with no value, deduplication with first-seen order preserved,
    and rejection of lines without a valid shell-style identifier.

    Dot-sourcing Compare-EnvFiles.ps1 here is safe: the script detects
    when it is being dot-sourced (`$MyInvocation.InvocationName -eq '.'`)
    and returns immediately after defining Get-DevKitEnvKeyNames, without
    touching the current directory or reading any .env file.
.NOTES
    Pester 5 syntax (dashed `Should -Be`).
    Run with:
        Invoke-Pester -Path .\tests\Unit\CompareEnvFiles.Tests.ps1
#>

Describe "Get-DevKitEnvKeyNames" {

    BeforeAll {
        $script:ScriptPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "workflow\Compare-EnvFiles.ps1"
        . $script:ScriptPath
    }

    Context "Basic key capture" {

        It "captures key names from plain KEY=value lines" {
            Get-DevKitEnvKeyNames -Lines @("FOO=bar", "BAZ=qux") | Should -Be @("FOO", "BAZ")
        }

        It "captures a key with an empty value (KEY=)" {
            Get-DevKitEnvKeyNames -Lines @("EMPTY=") | Should -Be @("EMPTY")
        }

        It "captures keys containing digits and underscores" {
            Get-DevKitEnvKeyNames -Lines @("API_KEY_V2=x") | Should -Be @("API_KEY_V2")
        }

        It "handles leading whitespace before the key" {
            Get-DevKitEnvKeyNames -Lines @("   SPACED=value") | Should -Be @("SPACED")
        }

        It "does not include the value in the result" {
            $result = Get-DevKitEnvKeyNames -Lines @("SECRET=hunter2")
            $result | Should -Be @("SECRET")
            "$result" | Should -Not -Match "hunter2"
        }
    }

    Context "Comments, blanks, and invalid lines are ignored" {

        It "ignores comment lines" {
            Get-DevKitEnvKeyNames -Lines @("# comment", "#FOO=bar", "REAL=1") | Should -Be @("REAL")
        }

        It "ignores blank and whitespace-only lines" {
            Get-DevKitEnvKeyNames -Lines @("", "   ", "KEY=1") | Should -Be @("KEY")
        }

        It "ignores lines whose 'key' starts with a digit" {
            Get-DevKitEnvKeyNames -Lines @("1FOO=bar") | Should -BeNullOrEmpty
        }

        It "ignores free text with no assignment" {
            Get-DevKitEnvKeyNames -Lines @("just some words") | Should -BeNullOrEmpty
        }

        It "returns nothing for an empty file" {
            Get-DevKitEnvKeyNames -Lines @() | Should -BeNullOrEmpty
        }
    }

    Context "export prefix" {

        It "captures export-prefixed keys" {
            Get-DevKitEnvKeyNames -Lines @("export API_KEY=x") | Should -Be @("API_KEY")
        }

        It "captures export-prefixed keys with leading whitespace" {
            Get-DevKitEnvKeyNames -Lines @("  export TOKEN=abc") | Should -Be @("TOKEN")
        }

        It "treats 'exportFOO' as a normal key (no whitespace after export)" {
            Get-DevKitEnvKeyNames -Lines @("exportFOO=bar") | Should -Be @("exportFOO")
        }
    }

    Context "Deduplication" {

        It "dedupes repeated keys, keeping first-seen order" {
            Get-DevKitEnvKeyNames -Lines @("A=1", "B=2", "A=3") | Should -Be @("A", "B")
        }

        It "dedupes across the export prefix" {
            Get-DevKitEnvKeyNames -Lines @("KEY=1", "export KEY=2") | Should -Be @("KEY")
        }
    }
}
