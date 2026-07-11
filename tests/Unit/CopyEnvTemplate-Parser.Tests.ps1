#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pester tests for the .env template parser (workflow/Copy-EnvTemplate.ps1)
.DESCRIPTION
    Exercises Get-DevKitEnvValueInfo and Get-DevKitEnvVariables against a
    small sample .env.example fixture string covering: a trailing inline
    comment (# and //), a multi-line comment block above a variable, and a
    multi-line quoted value (a PEM-style private key spanning several
    lines) - confirming it is tracked as a single atomic block rather than
    corrupted/split across lines.

    Dot-sourcing Copy-EnvTemplate.ps1 here is safe: the script detects when
    it is being dot-sourced (`$MyInvocation.InvocationName -eq '.'`) and
    returns immediately after defining the parser functions, without
    touching any files on disk.
.NOTES
    Pester 5 syntax (dashed `Should -Be`).
    Run with:
        Invoke-Pester -Path .\tests\Unit\CopyEnvTemplate-Parser.Tests.ps1
#>

Describe "Get-DevKitEnvValueInfo" {

    BeforeAll {
        $script:ScriptPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "workflow\Copy-EnvTemplate.ps1"
        . $script:ScriptPath
    }

    It "strips a trailing '# ...' comment that isn't inside quotes" {
        $result = Get-DevKitEnvValueInfo -RawValue "3000 # default dev server port"
        $result.Value | Should -Be "3000"
        $result.IsMultiline | Should -Be $false
    }

    It "strips a trailing '// ...' comment that isn't inside quotes" {
        $result = Get-DevKitEnvValueInfo -RawValue "false // toggle verbose logging"
        $result.Value | Should -Be "false"
    }

    It "does NOT strip a '#' that appears inside a quoted value" {
        $result = Get-DevKitEnvValueInfo -RawValue '"a value with a # hash inside"'
        $result.Value | Should -Be '"a value with a # hash inside"'
    }

    It "leaves a value with no comment marker untouched" {
        $result = Get-DevKitEnvValueInfo -RawValue "http://localhost:5432/db"
        $result.Value | Should -Be "http://localhost:5432/db"
    }

    It "detects an opened-but-unclosed quote as the start of a multi-line value" {
        $result = Get-DevKitEnvValueInfo -RawValue '"-----BEGIN PRIVATE KEY-----'
        $result.IsMultiline | Should -Be $true
        $result.OpenQuote | Should -Be '"'
    }

    It "does not flag a fully-closed quoted value as multi-line" {
        $result = Get-DevKitEnvValueInfo -RawValue '"single line quoted value"'
        $result.IsMultiline | Should -Be $false
    }
}

Describe "Get-DevKitEnvVariables" {

    BeforeAll {
        $script:ScriptPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "workflow\Copy-EnvTemplate.ps1"
        . $script:ScriptPath

        # Sample .env.example fixture covering:
        #   - PORT: a trailing '#' inline comment
        #   - DEBUG: a trailing '//' inline comment
        #   - API_KEY: a multi-line (3-line) comment block above it
        #   - PRIVATE_KEY: a multi-line quoted value (PEM-style key)
        #   - AFTER_KEY: a plain variable right after the multi-line block,
        #     used to confirm parsing resumes correctly and isn't corrupted
        $fixture = @'
# App configuration
# Used for the HTTP listener
PORT=3000 # default dev server port
DEBUG=false // toggle verbose logging

# Multi line comment line one
# Multi line comment line two
# Multi line comment line three
API_KEY=

# A multiline PEM private key
PRIVATE_KEY="-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBg
lotsofbase64charshere
-----END PRIVATE KEY-----"
AFTER_KEY=stillworks
'@

        $script:Lines = $fixture -split "`r?`n"
        $script:Variables = Get-DevKitEnvVariables -Lines $script:Lines
    }

    It "parses exactly the expected number of variables" {
        $script:Variables.Count | Should -Be 5
    }

    It "strips the trailing '#' inline comment from PORT's default" {
        ($script:Variables | Where-Object { $_.Name -eq "PORT" }).Default | Should -Be "3000"
    }

    It "strips the trailing '//' inline comment from DEBUG's default" {
        ($script:Variables | Where-Object { $_.Name -eq "DEBUG" }).Default | Should -Be "false"
    }

    It "accumulates a multi-line comment block instead of keeping only the last line" {
        $comment = ($script:Variables | Where-Object { $_.Name -eq "API_KEY" }).Comment
        $comment | Should -Match "Multi line comment line one"
        $comment | Should -Match "Multi line comment line two"
        $comment | Should -Match "Multi line comment line three"
    }

    It "flags PRIVATE_KEY as a multi-line quoted value" {
        $pk = $script:Variables | Where-Object { $_.Name -eq "PRIVATE_KEY" }
        $pk.IsMultiline | Should -Be $true
    }

    It "spans the full multi-line quoted block as a single atomic unit (StartIndex to EndIndex)" {
        $pk = $script:Variables | Where-Object { $_.Name -eq "PRIVATE_KEY" }
        # The block is 4 raw lines: the opening line through the closing
        # "-----END PRIVATE KEY-----"" line.
        ($pk.EndIndex - $pk.StartIndex) | Should -Be 3
        $script:Lines[$pk.EndIndex] | Should -Match "END PRIVATE KEY"
    }

    It "resumes correct parsing immediately after the multi-line block (no corruption)" {
        ($script:Variables | Where-Object { $_.Name -eq "AFTER_KEY" }).Default | Should -Be "stillworks"
    }
}
