#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pester tests for ConvertTo-DevKitMcpEntryMap (lib/DevKit-McpList.ps1)
.DESCRIPTION
    Exercises the 'claude mcp list' plain-text parser in isolation against
    fixture text - no real 'claude' process is invoked. Covers the exact bug
    fixed this sprint (a server name containing a space, e.g. a real
    connector named 'claude.ai Notion', being silently dropped by an
    over-restrictive regex) plus header/blank/non-matching line handling and
    insertion order.

    Dot-sourcing lib/DevKit-McpList.ps1 here is safe: it only defines
    Invoke-DevKitMcpList, ConvertTo-DevKitMcpEntryMap, and
    Get-DevKitMcpScopeDiff, guarded by its own $global:DevKitMcpListLoaded
    "load once per process" flag. It never calls 'claude' or prompts at
    dot-source time - only Invoke-DevKitMcpList/Get-DevKitMcpScopeDiff do
    that, and this file never calls those.
.NOTES
    Pester 5 syntax (dashed `Should -Be`).
    Run with:
        Invoke-Pester -Path .\tests\Unit\McpEntryMap-Parser.Tests.ps1
#>

BeforeAll {
    $script:McpListScript = (Resolve-Path (Join-Path $PSScriptRoot "..\..\tools\lib\DevKit-McpList.ps1")).Path

    # lib/*.ps1 files guard themselves with a $global:...Loaded "load once
    # per process" flag. That's correct for the real app, but when Pester
    # runs multiple test files in one process, an earlier file can set the
    # flag first, silently no-op'ing this dot-source and leaving
    # ConvertTo-DevKitMcpEntryMap undefined in THIS file's scope. Reset the
    # flag so this file always gets a real, fresh load regardless of run
    # order (same pattern as Get-DevKitPackageManager.Tests.ps1).
    $global:DevKitMcpListLoaded = $false
    . $script:McpListScript

    # Realistic sample matching real `claude mcp list` output: a health-check
    # header line, a blank line, several normal 'name: line' entries, and a
    # server name containing a space (the connector-style name this sprint's
    # regex fix specifically targets).
    $script:SampleListOutput = @(
        "Checking MCP server health...",
        "",
        "github: https://api.githubcopilot.com/mcp (HTTP) - Connected",
        "supabase: npx -y @supabase/mcp-server-supabase@latest - Connected",
        "claude.ai Notion: https://mcp.notion.com/mcp - Connected",
        "sequential-thinking: npx -y @modelcontextprotocol/server-sequential-thinking - Connected"
    )
}

Describe "ConvertTo-DevKitMcpEntryMap" {

    It "parses every well-formed 'name: line' entry from realistic multi-line output" {
        $map = ConvertTo-DevKitMcpEntryMap -Output $script:SampleListOutput
        $map.Keys | Should -Contain "github"
        $map.Keys | Should -Contain "supabase"
        $map.Keys | Should -Contain "claude.ai Notion"
        $map.Keys | Should -Contain "sequential-thinking"
    }

    It "returns exactly 4 entries for the 6-line sample (2 non-matching lines ignored)" {
        $map = ConvertTo-DevKitMcpEntryMap -Output $script:SampleListOutput
        $map.Count | Should -Be 4
    }

    It "regression: parses a server name containing a space instead of dropping it (the connector-name bug fixed this sprint)" {
        $map = ConvertTo-DevKitMcpEntryMap -Output $script:SampleListOutput
        $map.Keys | Should -Contain "claude.ai Notion"
        $map["claude.ai Notion"] | Should -Be "claude.ai Notion: https://mcp.notion.com/mcp - Connected"
    }

    It "ignores the non-colon header line ('Checking MCP server health...')" {
        $map = ConvertTo-DevKitMcpEntryMap -Output $script:SampleListOutput
        $map.Keys | Should -Not -Contain "Checking MCP server health..."
    }

    It "ignores blank lines without throwing" {
        { ConvertTo-DevKitMcpEntryMap -Output $script:SampleListOutput } | Should -Not -Throw
    }

    It "splits on the first ': ' rather than a restricted character class (period in the name is preserved)" {
        $map = ConvertTo-DevKitMcpEntryMap -Output $script:SampleListOutput
        $map.Keys | Should -Contain "sequential-thinking"
        $map["sequential-thinking"] | Should -Match "^sequential-thinking: "
    }

    It "preserves insertion order matching the input order" {
        $map = ConvertTo-DevKitMcpEntryMap -Output $script:SampleListOutput
        $keys = @($map.Keys)
        $keys[0] | Should -Be "github"
        $keys[1] | Should -Be "supabase"
        $keys[2] | Should -Be "claude.ai Notion"
        $keys[3] | Should -Be "sequential-thinking"
    }

    It "returns an empty (not null) map for empty input" {
        $map = ConvertTo-DevKitMcpEntryMap -Output @()
        $map.Count | Should -Be 0
    }

    It "does not match a line with a colon but no following space (e.g. a URL-like fragment)" {
        $map = ConvertTo-DevKitMcpEntryMap -Output @("https://example.com/no-space-after-colon")
        $map.Count | Should -Be 0
    }

    It "trims trailing whitespace from the stored line" {
        $map = ConvertTo-DevKitMcpEntryMap -Output @("github: https://api.githubcopilot.com/mcp - Connected   ")
        $map["github"] | Should -Be "github: https://api.githubcopilot.com/mcp - Connected"
    }
}
