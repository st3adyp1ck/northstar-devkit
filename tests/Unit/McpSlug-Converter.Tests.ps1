#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pester tests for ConvertTo-DevKitMcpSlug (lib/DevKit-McpAddFlow.ps1)
.DESCRIPTION
    Exercises the catalog-display-name-to-'claude mcp add'-server-name slug
    conversion in isolation against representative and edge-case input
    strings - no interactive prompt, catalog lookup, or 'claude' process is
    involved.

    Dot-sourcing lib/DevKit-McpAddFlow.ps1 here is safe: at dot-source time
    it only defines ConvertTo-DevKitMcpSlug and
    Add-DevKitMcpServerFromCatalogEntry (guarded by its own
    $global:DevKitMcpAddFlowLoaded "load once per process" flag), plus
    defensively dot-sources lib/DevKit-Common.ps1 and
    lib/DevKit-McpCatalog.ps1 if they are not already loaded - both of which
    are themselves function-definitions-only at dot-source time (see
    McpCatalog.Tests.ps1 / Get-DevKitPackageManager.Tests.ps1). Nothing here
    calls Add-DevKitMcpServerFromCatalogEntry, which is the only function in
    this file that prompts/mutates real MCP config.
.NOTES
    Pester 5 syntax (dashed `Should -Be`).
    Run with:
        Invoke-Pester -Path .\tests\Unit\McpSlug-Converter.Tests.ps1
#>

BeforeAll {
    $script:AddFlowScript = (Resolve-Path (Join-Path $PSScriptRoot "..\..\tools\lib\DevKit-McpAddFlow.ps1")).Path

    # Reset every "load once per process" flag this file's dot-source chain
    # touches, so this file always gets a real, fresh load of
    # ConvertTo-DevKitMcpSlug in THIS file's scope regardless of what an
    # earlier test file in the same Pester process already loaded (see
    # McpEntryMap-Parser.Tests.ps1 / Get-DevKitPackageManager.Tests.ps1 for
    # why this matters).
    $global:DevKitMcpAddFlowLoaded = $false
    $global:DevKitCommonLoaded = $false
    $global:DevKitMcpCatalogLoaded = $false
    . $script:AddFlowScript
}

Describe "ConvertTo-DevKitMcpSlug" {

    It "converts 'Jira / Atlassian' to 'jira-atlassian'" {
        ConvertTo-DevKitMcpSlug -Text "Jira / Atlassian" | Should -Be "jira-atlassian"
    }

    It "converts 'GitHub' to 'github' (lowercased, no separators needed)" {
        ConvertTo-DevKitMcpSlug -Text "GitHub" | Should -Be "github"
    }

    It "converts 'Sequential Thinking' to 'sequential-thinking'" {
        ConvertTo-DevKitMcpSlug -Text "Sequential Thinking" | Should -Be "sequential-thinking"
    }

    It "keeps digits, e.g. 'Context7' stays 'context7'" {
        ConvertTo-DevKitMcpSlug -Text "Context7" | Should -Be "context7"
    }

    It "collapses a run of punctuation/whitespace into a single hyphen and trims leading/trailing hyphens" {
        ConvertTo-DevKitMcpSlug -Text "  Foo   Bar!!  " | Should -Be "foo-bar"
    }

    It "falls back to 'mcp-server' for all-punctuation input that slugs to empty" {
        ConvertTo-DevKitMcpSlug -Text "!!!" | Should -Be "mcp-server"
    }

    It "throws a parameter-binding error for a call-site empty string (verified real behavior: Mandatory [string] parameters reject '' before the function body ever runs, so the empty-input fallback is only reachable via whitespace-only input, not a literal empty string)" {
        { ConvertTo-DevKitMcpSlug -Text "" } | Should -Throw
    }

    It "falls back to 'mcp-server' for a whitespace-only string" {
        ConvertTo-DevKitMcpSlug -Text "   " | Should -Be "mcp-server"
    }

    It "handles a name that is already a valid slug unchanged" {
        ConvertTo-DevKitMcpSlug -Text "my-custom-server" | Should -Be "my-custom-server"
    }
}
