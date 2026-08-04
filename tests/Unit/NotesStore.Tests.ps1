#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pester tests for the widget's per-project sticky-notes store
    (Get/Save-DevKitProjectNotes in gui/DevKit-WidgetCore.ps1)
.DESCRIPTION
    Exercises the JSON round-trip against a temp store file: array-shape
    guarantees (including the single-note member-unroll trap), project key
    canonicalization, cross-project isolation on save, empty-list pruning,
    and the corrupt-store recovery posture.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    # See Get-DevKitPackageManager.Tests.ps1 for why these load-once flags
    # get reset when several test files share one Pester process.
    $global:DevKitCommonLoaded = $false
    . (Join-Path $script:RepoRoot 'lib\DevKit-Common.ps1')
    $global:DevKitWidgetCoreLoaded = $false
    . (Join-Path $script:RepoRoot 'gui\DevKit-WidgetCore.ps1')

    function New-TestNote {
        param([string]$Text, [string]$Color = 'amber')
        return [PSCustomObject]@{
            Id        = [guid]::NewGuid().ToString('N')
            Text      = $Text
            Color     = $Color
            UpdatedAt = [DateTime]::UtcNow.ToString('o')
        }
    }
}

Describe "Get-DevKitNotesProjectKey" {

    It "canonicalizes trailing separators and casing to one key" {
        $a = Get-DevKitNotesProjectKey -ProjectPath 'D:\Work\MyApp\'
        $b = Get-DevKitNotesProjectKey -ProjectPath 'd:\work\myapp'
        $a | Should -Be $b
    }
}

Describe "Get-DevKitProjectNotes" {

    BeforeEach {
        $script:StoreFile = Join-Path $TestDrive "notes-$([guid]::NewGuid().ToString('N')).json"
    }

    It "returns an empty array when the store file does not exist" {
        $r = @(Get-DevKitProjectNotes -ProjectPath 'D:\Work\MyApp' -NotesFile $script:StoreFile)
        $r.Count | Should -Be 0
    }

    It "returns an empty array for a project with no saved notes" {
        Save-DevKitProjectNotes -ProjectPath 'D:\Other' -Notes @((New-TestNote 'x')) -NotesFile $script:StoreFile
        $r = @(Get-DevKitProjectNotes -ProjectPath 'D:\Work\MyApp' -NotesFile $script:StoreFile)
        $r.Count | Should -Be 0
    }

    It "returns an empty array (not a crash) for a corrupt store file" {
        Set-Content -LiteralPath $script:StoreFile -Value '{ not valid json !!'
        $r = @(Get-DevKitProjectNotes -ProjectPath 'D:\Work\MyApp' -NotesFile $script:StoreFile)
        $r.Count | Should -Be 0
    }
}

Describe "Save-DevKitProjectNotes round-trip" {

    BeforeEach {
        $script:StoreFile = Join-Path $TestDrive "notes-$([guid]::NewGuid().ToString('N')).json"
    }

    It "round-trips notes preserving order, ids, colors, and text" {
        $notes = @((New-TestNote 'first' 'amber'), (New-TestNote "second`nmultiline" 'blue'))
        Save-DevKitProjectNotes -ProjectPath 'D:\Work\MyApp' -Notes $notes -NotesFile $script:StoreFile
        $r = @(Get-DevKitProjectNotes -ProjectPath 'D:\Work\MyApp' -NotesFile $script:StoreFile)
        $r.Count | Should -Be 2
        $r[0].Id | Should -Be $notes[0].Id
        $r[0].Text | Should -Be 'first'
        $r[0].Color | Should -Be 'amber'
        $r[1].Text | Should -Be "second`nmultiline"
        $r[1].Color | Should -Be 'blue'
    }

    It "keeps a SINGLE saved note as an array through a second save cycle" {
        # ConvertFrom-Json member access unrolls one-element arrays; a lone
        # note must not round-trip into a bare object when an unrelated
        # project's save rewrites the store around it.
        Save-DevKitProjectNotes -ProjectPath 'D:\Solo' -Notes @((New-TestNote 'only note')) -NotesFile $script:StoreFile
        Save-DevKitProjectNotes -ProjectPath 'D:\Other' -Notes @((New-TestNote 'elsewhere')) -NotesFile $script:StoreFile
        $r = @(Get-DevKitProjectNotes -ProjectPath 'D:\Solo' -NotesFile $script:StoreFile)
        $r.Count | Should -Be 1
        $r[0].Text | Should -Be 'only note'
    }

    It "does not disturb other projects' notes when saving one project" {
        Save-DevKitProjectNotes -ProjectPath 'D:\A' -Notes @((New-TestNote 'a-note')) -NotesFile $script:StoreFile
        Save-DevKitProjectNotes -ProjectPath 'D:\B' -Notes @((New-TestNote 'b-note')) -NotesFile $script:StoreFile
        Save-DevKitProjectNotes -ProjectPath 'D:\A' -Notes @((New-TestNote 'a-rewritten')) -NotesFile $script:StoreFile
        $b = @(Get-DevKitProjectNotes -ProjectPath 'D:\B' -NotesFile $script:StoreFile)
        $b.Count | Should -Be 1
        $b[0].Text | Should -Be 'b-note'
        $a = @(Get-DevKitProjectNotes -ProjectPath 'D:\A' -NotesFile $script:StoreFile)
        $a.Count | Should -Be 1
        $a[0].Text | Should -Be 'a-rewritten'
    }

    It "reads back through a differently-cased path with a trailing slash" {
        Save-DevKitProjectNotes -ProjectPath 'D:\Work\MyApp' -Notes @((New-TestNote 'hello')) -NotesFile $script:StoreFile
        $r = @(Get-DevKitProjectNotes -ProjectPath 'd:\WORK\myapp\' -NotesFile $script:StoreFile)
        $r.Count | Should -Be 1
        $r[0].Text | Should -Be 'hello'
    }

    It "removes a project's entry entirely when saved with an empty list" {
        Save-DevKitProjectNotes -ProjectPath 'D:\Work\MyApp' -Notes @((New-TestNote 'temp')) -NotesFile $script:StoreFile
        Save-DevKitProjectNotes -ProjectPath 'D:\Work\MyApp' -Notes @() -NotesFile $script:StoreFile
        $raw = Get-Content -LiteralPath $script:StoreFile -Raw | ConvertFrom-Json
        @($raw.projects.PSObject.Properties).Count | Should -Be 0
    }

    It "recovers from a corrupt store by rebuilding it around the new save" {
        Set-Content -LiteralPath $script:StoreFile -Value 'garbage {{{{'
        Save-DevKitProjectNotes -ProjectPath 'D:\Work\MyApp' -Notes @((New-TestNote 'fresh')) -NotesFile $script:StoreFile
        $r = @(Get-DevKitProjectNotes -ProjectPath 'D:\Work\MyApp' -NotesFile $script:StoreFile)
        $r.Count | Should -Be 1
        $r[0].Text | Should -Be 'fresh'
    }

    It "creates the parent directory when missing" {
        $nested = Join-Path $TestDrive "sub\dir\notes.json"
        Save-DevKitProjectNotes -ProjectPath 'D:\Work\MyApp' -Notes @((New-TestNote 'deep')) -NotesFile $nested
        Test-Path -LiteralPath $nested | Should -BeTrue
    }
}
