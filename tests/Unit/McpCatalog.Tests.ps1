#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pester tests for Get-DevKitMcpCatalog and
    Resolve-DevKitMcpCatalogPlaceholder (lib/DevKit-McpCatalog.ps1)
.DESCRIPTION
    Get-DevKitMcpCatalog is pure static data - these tests verify its shape
    (10 entries, every entry has a non-empty Name/Description, every
    Variants is an array with Plaid's empty and everyone else's non-empty,
    every non-empty Variant has a valid Type with the right shape-specific
    properties).

    Resolve-DevKitMcpCatalogPlaceholder's no-token fast path ("<...>-free
    template returned unchanged, no prompting") is tested directly. Its
    token-prompting path calls Read-Host, so it is tested via Pester's
    `Mock Read-Host` rather than actually blocking on real console input -
    both the required-value path and the -AllowBlank path are covered this
    way, since Mock works fine here even though the function was
    dot-sourced rather than imported from a module (PowerShell resolves
    Read-Host dynamically at call time, which is exactly what Mock patches
    for the duration of the test).

    Dot-sourcing lib/DevKit-McpCatalog.ps1 here is safe: it only defines
    Get-DevKitMcpCatalog, Resolve-DevKitMcpCatalogPlaceholder, and
    Invoke-DevKitMcpAdd, guarded by its own
    $global:DevKitMcpCatalogLoaded "load once per process" flag. It never
    calls 'claude' or prompts at dot-source time - only
    Resolve-DevKitMcpCatalogPlaceholder/Invoke-DevKitMcpAdd do that, and
    this file only calls the former (and only with Read-Host mocked).
.NOTES
    Pester 5 syntax (dashed `Should -Be`).
    Run with:
        Invoke-Pester -Path .\tests\Unit\McpCatalog.Tests.ps1
#>

BeforeAll {
    $script:CatalogScript = (Resolve-Path (Join-Path $PSScriptRoot "..\..\tools\lib\DevKit-McpCatalog.ps1")).Path

    # See McpEntryMap-Parser.Tests.ps1 for why this reset is required: an
    # earlier test file in the same Pester process may have already set this
    # flag, which would otherwise silently no-op this dot-source and leave
    # these functions undefined in THIS file's scope.
    $global:DevKitMcpCatalogLoaded = $false
    . $script:CatalogScript
}

Describe "Get-DevKitMcpCatalog" {

    BeforeAll {
        $script:Catalog = @(Get-DevKitMcpCatalog)
    }

    It "returns exactly 10 entries" {
        $script:Catalog.Count | Should -Be 10
    }

    It "includes the expected 10 server names" {
        $names = $script:Catalog | ForEach-Object { $_.Name }
        foreach ($expected in @(
            'Supabase', 'Sequential Thinking', 'Context7', 'GitHub', 'Filesystem',
            'Notion', 'Jira / Atlassian', 'Linear', 'Stripe', 'Plaid'
        )) {
            $names | Should -Contain $expected
        }
    }

    It "gives every entry a non-empty Name and Description" {
        foreach ($entry in $script:Catalog) {
            $entry.Name | Should -Not -BeNullOrEmpty
            $entry.Description | Should -Not -BeNullOrEmpty
        }
    }

    It "gives every entry a Variants property that is an array (never a bare scalar)" {
        foreach ($entry in $script:Catalog) {
            , $entry.Variants | Should -BeOfType [System.Array]
        }
    }

    It "gives Plaid zero Variants (the one catalog entry with no automatable registration)" {
        $plaid = $script:Catalog | Where-Object { $_.Name -eq 'Plaid' }
        @($plaid.Variants).Count | Should -Be 0
    }

    It "gives every non-Plaid entry at least one Variant" {
        foreach ($entry in ($script:Catalog | Where-Object { $_.Name -ne 'Plaid' })) {
            @($entry.Variants).Count | Should -BeGreaterThan 0
        }
    }

    It "gives every Variant a Type of either 'Remote' or 'Local'" {
        foreach ($entry in $script:Catalog) {
            foreach ($variant in @($entry.Variants)) {
                $variant.Type | Should -BeIn @('Remote', 'Local')
            }
        }
    }

    It "gives every 'Remote' Variant a non-empty Transport and Url" {
        foreach ($entry in $script:Catalog) {
            foreach ($variant in (@($entry.Variants) | Where-Object { $_.Type -eq 'Remote' })) {
                $variant.Transport | Should -Not -BeNullOrEmpty
                $variant.Url | Should -Not -BeNullOrEmpty
                $variant.Url | Should -Match '^https?://'
            }
        }
    }

    It "gives every 'Local' Variant a non-empty Command and a non-null Args array" {
        foreach ($entry in $script:Catalog) {
            foreach ($variant in (@($entry.Variants) | Where-Object { $_.Type -eq 'Local' })) {
                $variant.Command | Should -Not -BeNullOrEmpty
                , $variant.Args | Should -Not -BeNullOrEmpty
            }
        }
    }

    It "gives every Variant a human-readable Kind label" {
        foreach ($entry in $script:Catalog) {
            foreach ($variant in @($entry.Variants)) {
                $variant.Kind | Should -Not -BeNullOrEmpty
            }
        }
    }

    It "gives Supabase two Variants: a recommended Remote and a Local fallback" {
        $supabase = $script:Catalog | Where-Object { $_.Name -eq 'Supabase' }
        @($supabase.Variants).Count | Should -Be 2
        ($supabase.Variants | Where-Object { $_.Type -eq 'Remote' }) | Should -Not -BeNullOrEmpty
        ($supabase.Variants | Where-Object { $_.Type -eq 'Local' }) | Should -Not -BeNullOrEmpty
    }
}

Describe "Resolve-DevKitMcpCatalogPlaceholder" {

    Context "no-token fast path (no prompting)" {

        It "returns a template with no placeholder token unchanged" {
            Resolve-DevKitMcpCatalogPlaceholder -Template "-y @modelcontextprotocol/server-sequential-thinking" |
                Should -Be "-y @modelcontextprotocol/server-sequential-thinking"
        }

        It "returns a plain flag-style arg unchanged" {
            Resolve-DevKitMcpCatalogPlaceholder -Template "--read-only" | Should -Be "--read-only"
        }
    }

    Context "token prompting (Read-Host mocked)" {

        It "splices the typed value back into the template in place of the placeholder token" {
            Mock Read-Host { return "my-project-ref" }
            Resolve-DevKitMcpCatalogPlaceholder -Template "--project-ref=<your Supabase project ref>" |
                Should -Be "--project-ref=my-project-ref"
            Should -Invoke Read-Host -Times 1
        }

        It "re-prompts (does not return) when a required value is left blank, then accepts the next answer" {
            $script:callCount = 0
            Mock Read-Host {
                $script:callCount++
                if ($script:callCount -eq 1) { return "" }
                return "abc123"
            }
            Resolve-DevKitMcpCatalogPlaceholder -Template "Authorization: Bearer <your GitHub PAT>" |
                Should -Be "Authorization: Bearer abc123"
            Should -Invoke Read-Host -Times 2
        }

        It "returns `$null for a blank answer when -AllowBlank is set" {
            Mock Read-Host { return "" }
            Resolve-DevKitMcpCatalogPlaceholder -Template "Authorization: Bearer <token or leave blank for OAuth>" -AllowBlank |
                Should -BeNullOrEmpty
            Should -Invoke Read-Host -Times 1
        }

        It "trims whitespace from the typed value before splicing it in" {
            Mock Read-Host { return "  spaced-value  " }
            Resolve-DevKitMcpCatalogPlaceholder -Template "CONTEXT7_API_KEY: <key>" |
                Should -Be "CONTEXT7_API_KEY: spaced-value"
        }
    }
}
