#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Northstar DevKit - MCP Server Catalog
.DESCRIPTION
    A static, hand-vetted catalog of popular MCP (Model Context Protocol)
    servers - what each one does and exactly how to register it with
    'claude mcp add' - plus the shared helper that actually builds a
    'claude mcp add' argument array and invokes it. This is pure data and
    a thin CLI-invocation wrapper: it never parses Claude Code's internal
    JSON config files directly, matching this module's existing philosophy
    (see AGENTS.md's "Agents & MCP" section).

    Get-DevKitMcpCatalog is consumed by Add-McpServerFromCatalog.ps1 (a
    browsable picker) and Invoke-DevKitMcpAdd is the single place in this
    codebase that builds the 'claude mcp add' argument array and shells
    out to claude - shared by Add-McpServer.ps1's own local/remote
    parameter sets and by Add-McpServerFromCatalog.ps1, so there is
    exactly one implementation of that logic.

    Catalog data was fact-checked against each server's official docs and
    the modelcontextprotocol/servers reference repo at the time this file
    was written. Server URLs/flags can change without notice - re-verify
    before editing an entry.

    This file is dot-sourced by scripts; it does not produce output when
    loaded.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
#>

# Prevent double-loading. Scope-aware on purpose: a $global: bool would
# incorrectly skip loading for a sibling script invoked via `&` in the same
# process (a distinct child scope that never inherits functions defined by
# another sibling's dot-source), leaving it with the flag set but none of
# the functions actually defined. Checking for the function itself detects
# "already loaded in a scope this one can see" instead.
if (Get-Command Get-DevKitMcpCatalog -ErrorAction SilentlyContinue) { return }
$global:DevKitMcpCatalogLoaded = $true

function Get-DevKitMcpCatalog {
    <#
    .SYNOPSIS
        Returns the static catalog of known MCP servers.
    .DESCRIPTION
        An ordered list of PSCustomObjects, one per MCP server:
          - Name: display name.
          - Description: one line (Plaid's doubles as its docs pointer,
            since it ships with zero Variants - see below).
          - Variants: one or more ways to register the server, or an
            empty array (Plaid) when no automatable registration exists.

        Each Variant is one of two shapes:
          REMOTE  - Type='Remote', Transport='http', Url, and optionally
                    HeaderTemplate (a 'Key: <placeholder text>' string -
                    resolve with Resolve-DevKitMcpCatalogPlaceholder) and
                    HeaderOptional (bool - if set, a blank answer to the
                    header prompt is valid and means "skip this header",
                    e.g. Jira's token-or-OAuth choice).
          LOCAL   - Type='Local', Command, Args (string[] - any element
                    may itself contain a '<placeholder text>' token to
                    resolve the same way, e.g. '--project-ref=<...>'),
                    optionally RequiresDirectoryArg (bool - caller must
                    prompt for one or more directories and append them to
                    Args) and EnvVarPrompts (string[] of env var NAMEs the
                    caller must prompt a value for and pass as
                    '-e NAME=value').

        Every Variant also carries a human-readable Kind label (e.g.
        'Remote (recommended)', 'Local (alternate)') for use in a picker
        when a server has more than one Variant.
    .OUTPUTS
        [PSCustomObject[]]
    #>
    [CmdletBinding()]
    param()

    return @(
        [PSCustomObject]@{
            Name        = 'Supabase'
            Description = 'Query and manage Supabase projects (tables, migrations, edge functions, logs) from Claude.'
            Variants    = @(
                [PSCustomObject]@{
                    Kind      = 'Remote (recommended)'
                    Type      = 'Remote'
                    Transport = 'http'
                    Url       = 'https://mcp.supabase.com/mcp'
                },
                [PSCustomObject]@{
                    Kind          = 'Local (read-only, via access token)'
                    Type          = 'Local'
                    Command       = 'npx'
                    Args          = @('-y', '@supabase/mcp-server-supabase@latest', '--read-only', '--project-ref=<your Supabase project ref>')
                    EnvVarPrompts = @('SUPABASE_ACCESS_TOKEN')
                }
            )
        },
        [PSCustomObject]@{
            Name        = 'Sequential Thinking'
            Description = 'Adds a structured, step-by-step reasoning tool Claude can call while working through complex problems.'
            Variants    = @(
                [PSCustomObject]@{
                    Kind    = 'Local'
                    Type    = 'Local'
                    Command = 'npx'
                    Args    = @('-y', '@modelcontextprotocol/server-sequential-thinking')
                }
            )
        },
        [PSCustomObject]@{
            Name        = 'Context7'
            Description = 'Fetches current library/framework documentation on demand instead of relying on training-data knowledge.'
            Variants    = @(
                [PSCustomObject]@{
                    Kind    = 'Local (default)'
                    Type    = 'Local'
                    Command = 'npx'
                    Args    = @('-y', '@upstash/context7-mcp')
                },
                [PSCustomObject]@{
                    Kind           = 'Remote (alternate)'
                    Type           = 'Remote'
                    Transport      = 'http'
                    Url            = 'https://mcp.context7.com/mcp'
                    HeaderTemplate = 'CONTEXT7_API_KEY: <key>'
                    HeaderOptional = $true
                }
            )
        },
        [PSCustomObject]@{
            Name        = 'GitHub'
            Description = 'Work with GitHub repos, issues, pull requests, and Actions directly from Claude.'
            Variants    = @(
                [PSCustomObject]@{
                    Kind           = 'Remote (only supported option - the local option requires Docker)'
                    Type           = 'Remote'
                    Transport      = 'http'
                    Url            = 'https://api.githubcopilot.com/mcp'
                    HeaderTemplate = 'Authorization: Bearer <your GitHub PAT>'
                }
            )
        },
        [PSCustomObject]@{
            Name        = 'Filesystem'
            Description = 'Gives Claude read/write access to one or more local directories you choose.'
            Variants    = @(
                [PSCustomObject]@{
                    Kind                 = 'Local'
                    Type                 = 'Local'
                    Command              = 'npx'
                    Args                 = @('-y', '@modelcontextprotocol/server-filesystem')
                    RequiresDirectoryArg = $true
                }
            )
        },
        [PSCustomObject]@{
            Name        = 'Notion'
            Description = 'Search, read, and edit Notion pages and databases from Claude.'
            Variants    = @(
                [PSCustomObject]@{
                    Kind      = 'Remote (only supported option - the old local package is deprecated)'
                    Type      = 'Remote'
                    Transport = 'http'
                    Url       = 'https://mcp.notion.com/mcp'
                }
            )
        },
        [PSCustomObject]@{
            Name        = 'Jira / Atlassian'
            Description = 'Work with Jira issues and Confluence pages from Claude.'
            Variants    = @(
                [PSCustomObject]@{
                    Kind           = 'Remote (only supported option)'
                    Type           = 'Remote'
                    Transport      = 'http'
                    Url            = 'https://mcp.atlassian.com/v1/mcp/authv2'
                    HeaderTemplate = 'Authorization: Bearer <token or leave blank for OAuth>'
                    HeaderOptional = $true
                }
            )
        },
        [PSCustomObject]@{
            Name        = 'Linear'
            Description = 'Read and manage Linear issues, projects, and comments from Claude.'
            Variants    = @(
                [PSCustomObject]@{
                    Kind      = 'Remote (only supported option)'
                    Type      = 'Remote'
                    Transport = 'http'
                    Url       = 'https://mcp.linear.app/mcp'
                }
            )
        },
        [PSCustomObject]@{
            Name        = 'Stripe'
            Description = 'Look up and manage Stripe customers, payments, and subscriptions from Claude.'
            Variants    = @(
                [PSCustomObject]@{
                    Kind           = 'Remote (recommended)'
                    Type           = 'Remote'
                    Transport      = 'http'
                    Url            = 'https://mcp.stripe.com'
                    HeaderTemplate = 'Authorization: Bearer <your Stripe restricted API key>'
                },
                [PSCustomObject]@{
                    Kind    = 'Local (alternate)'
                    Type    = 'Local'
                    Command = 'npx'
                    Args    = @('-y', '@stripe/mcp', '--api-key=<your Stripe secret key>')
                }
            )
        },
        [PSCustomObject]@{
            Name        = 'Plaid'
            Description = "Experimental - Plaid's MCP server needs a short-lived OAuth token refresh that a one-time registration cannot sustain; see plaid.com/docs/resources/mcp for manual setup."
            Variants    = @()
        }
    )
}

function Resolve-DevKitMcpCatalogPlaceholder {
    <#
    .SYNOPSIS
        Resolves one catalog template string containing a '<placeholder
        text>' token by prompting the user to fill it in.
    .DESCRIPTION
        Catalog Args entries and HeaderTemplate values embed a
        human-readable placeholder in angle brackets, e.g.
        '--project-ref=<your Supabase project ref>' or
        'Authorization: Bearer <your GitHub PAT>'. The bracketed text is
        already a good prompt label, so it's reused directly rather than
        asking catalog entries to carry a separate label field. The typed
        value is spliced back into the template in place of the
        '<...>' token (a plain string replace, so no regex-escaping
        surprises from special characters the user types).

        If the template has no '<...>' token at all, it's returned
        unchanged with no prompting - this lets callers run every Args
        entry / HeaderTemplate through this function unconditionally
        instead of checking for a token first.
    .PARAMETER Template
        The full string, containing at most one '<...>' placeholder.
    .PARAMETER AllowBlank
        If set, an empty answer is accepted and returned as $null instead
        of re-prompting - used for optional values like Jira's "leave
        blank for OAuth" header.
    .OUTPUTS
        [string] the resolved value, or $null only when -AllowBlank was
        set and the user left the prompt blank.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Template,
        [switch]$AllowBlank
    )

    if (-not ($Template -match '<[^>]+>')) { return $Template }
    $fullMatch = $Matches[0]
    $placeholderText = $fullMatch.Substring(1, $fullMatch.Length - 2)

    while ($true) {
        $typed = Read-Host "  Enter $placeholderText"
        if ([string]::IsNullOrWhiteSpace($typed)) {
            if ($AllowBlank) { return $null }
            Write-Host "  This value is required." -ForegroundColor Yellow
            continue
        }
        return $Template.Replace($fullMatch, $typed.Trim())
    }
}

function Invoke-DevKitMcpAdd {
    <#
    .SYNOPSIS
        Builds the 'claude mcp add' argument array for a local (stdio) or
        remote (http) MCP server and runs it - the single place in this
        codebase that does so. Both Add-McpServer.ps1's own local/remote
        parameter sets and Add-McpServerFromCatalog.ps1 call this instead
        of each re-implementing argument-array-building and invocation.
    .DESCRIPTION
        Does not confirm and does not validate -Name/-Scope/-ProjectPath
        existence - callers are expected to have already run
        Confirm-DevKitDestructiveAction and their own input validation,
        matching the pre-refactor inline logic this replaces.
    .PARAMETER Name
        Name to register the MCP server under.
    .PARAMETER Scope
        'local', 'project', or 'user'.
    .PARAMETER ProjectPath
        For scope local/project: directory to Push-Location into before
        calling claude, so project/local-scope config lands there. Pass
        $null/omit for scope user or when no project context applies.
    .PARAMETER Command
        (Local only) the stdio command to run.
    .PARAMETER CommandArgs
        (Local only) arguments passed through to Command, in order.
    .PARAMETER EnvVars
        (Local only) zero or more KEY=VALUE entries, passed as
        '-e KEY=VALUE'.
    .PARAMETER Url
        (Remote only) the http MCP endpoint URL.
    .PARAMETER Headers
        (Remote only) zero or more 'Key: Value' entries, passed as
        '-H "Key: Value"'.
    .OUTPUTS
        PSCustomObject: Success [bool], ExitCode [int or $null],
        ErrorMessage [string or $null - already formatted for display,
        e.g. via Write-DevKitError, when Success is $false].
    #>
    [CmdletBinding(DefaultParameterSetName = 'Local')]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]
        [ValidateSet('local', 'project', 'user')]
        [string]$Scope,
        [string]$ProjectPath,

        [Parameter(Mandatory = $true, ParameterSetName = 'Local')][string]$Command,
        [Parameter(ParameterSetName = 'Local')][string[]]$CommandArgs,
        [Parameter(ParameterSetName = 'Local')][string[]]$EnvVars,

        [Parameter(Mandatory = $true, ParameterSetName = 'Remote')][string]$Url,
        [Parameter(ParameterSetName = 'Remote')][string[]]$Headers
    )

    $argsArray = @('mcp', 'add', '--scope', $Scope)

    if ($PSCmdlet.ParameterSetName -eq 'Remote') {
        $argsArray += '--transport'
        $argsArray += 'http'
        foreach ($h in $Headers) {
            $argsArray += '-H'
            $argsArray += $h
        }
        $argsArray += $Name
        $argsArray += $Url
    } else {
        foreach ($kv in $EnvVars) {
            $argsArray += '-e'
            $argsArray += $kv
        }
        $argsArray += $Name
        $argsArray += '--'
        $argsArray += $Command
        foreach ($a in $CommandArgs) {
            $argsArray += $a
        }
    }

    $pushedLocation = $false
    if ($ProjectPath) {
        try {
            Push-Location -LiteralPath $ProjectPath
            $pushedLocation = $true
        } catch {
            return [PSCustomObject]@{
                Success      = $false
                ExitCode     = $null
                ErrorMessage = "Failed to enter project path '$ProjectPath': $_"
            }
        }
    }

    $addFailed = $false
    $addErrorMessage = $null
    $addExitCode = $null
    try {
        & claude @argsArray
        $addExitCode = $LASTEXITCODE
    } catch {
        $addFailed = $true
        $addErrorMessage = $_
    } finally {
        if ($pushedLocation) { Pop-Location }
    }

    if ($addFailed) {
        return [PSCustomObject]@{
            Success      = $false
            ExitCode     = $null
            ErrorMessage = "Failed to run 'claude mcp add': $addErrorMessage"
        }
    }

    if ($null -ne $addExitCode -and $addExitCode -ne 0) {
        return [PSCustomObject]@{
            Success      = $false
            ExitCode     = $addExitCode
            ErrorMessage = "'claude mcp add' exited with code $addExitCode."
        }
    }

    return [PSCustomObject]@{
        Success      = $true
        ExitCode     = $addExitCode
        ErrorMessage = $null
    }
}
