@{
    Name        = "Agents & MCP"
    Description = "Track and update installed AI/dev CLI tools (claude, gh, codex, gemini, cursor-agent, aider, supabase, vercel, railway, kimi, auggie), and manage Claude Code's MCP (Model Context Protocol) server configuration - list, add (by hand or from a built-in catalog), remove, and scan servers across both user/global and per-project scope."
    Items       = @(
        @{
            Key    = '1'
            Label  = 'List Installed AI CLIs'
            Script = 'Get-InstalledAiClis.ps1'
            Help   = "Detects which AI coding-agent CLIs (claude, gh, codex, gemini, cursor-agent, aider, supabase, vercel, railway, kimi, auggie) are installed and on PATH, and reports their versions. Read-only - makes no changes. Use this first to see what's available on this machine before updating or configuring anything."
        }
        @{
            Key    = '2'
            Label  = 'Update AI CLIs'
            Script = 'Update-AiClis.ps1'
            Help   = "Updates installed AI/dev CLIs (of the 11 tracked - claude, gh, codex, gemini, cursor-agent, aider, supabase, vercel, railway, kimi, auggie) that are on an automatable update channel: npm ('npm install -g PACKAGE@latest'), npm+builtin (tries the tool's own upgrade subcommand first, e.g. 'vercel upgrade', falling back to npm), or scoop ('scoop update NAME', only when installed via Scoop). Tools on a manual channel (gh, cursor-agent, aider, and kimi -- two unrelated CLIs share the 'kimi' command name, so it's report-only until there's a safe way to tell them apart) are reported only, never touched. Supports -Only <name(s)> to restrict which tools are considered, -DryRun to show current/latest versions and what would update with no changes made, and -Force to skip the confirmation prompt. Safety note: without -DryRun, confirming runs real update commands (npm install/scoop update/builtin upgrade) against globally installed packages - review the detected list before confirming."
        }
        @{
            Key    = '3'
            Label  = 'List MCP Servers'
            Script = 'Get-McpServers.ps1'
            Help   = "Lists Claude Code's configured MCP servers via 'claude mcp list'. Read-only. With an active project set, splits the list into user/global scope versus project/local scope by diffing the list run from a neutral directory against the list run from the project. Use this to see what's currently configured before adding or removing anything."
        }
        @{
            Key    = '4'
            Label  = 'Add MCP Server'
            Script = 'Add-McpServer.ps1'
            Help   = "Registers one MCP server by hand - you supply the name and either a local (stdio) command or a remote http URL/headers, plus the scope to register it at. Use this when you already know the exact server details. Safety note: mutates real Claude Code MCP configuration (runs 'claude mcp add') - always confirms first unless -Force is passed."
        }
        @{
            Key    = '5'
            Label  = 'Remove MCP Server'
            Script = 'Remove-McpServer.ps1'
            Help   = "Removes one MCP server by name via 'claude mcp remove'. Use this to clean up a server you no longer need. Safety note: mutates real Claude Code MCP configuration - always confirms first unless -Force is passed."
        }
        @{
            Key    = '6'
            Label  = 'Add MCP Server (From Catalog)'
            Script = 'Add-McpServerFromCatalog.ps1'
            Help   = "Browsable picker over a curated catalog of popular MCP servers (Supabase, GitHub, Notion, Linear, Stripe, and more) - pick one, choose a variant if it offers more than one, and answer a few prompts (name, scope, API keys/headers, directories) instead of typing the full 'claude mcp add' command yourself. Use this when you want to add a well-known server without looking up its exact invocation. Safety note: mutates real Claude Code MCP configuration - always confirms first unless -Force is passed."
        }
        @{
            Key    = '7'
            Label  = 'Scan MCP Setup (Global + Project)'
            Script = 'Scan-McpServers.ps1'
            Help   = "Checks which catalog servers are already configured, both globally/user-scope and (if an active project is set) at project scope, and reports what's missing. For each missing entry with an automatable registration, asks whether to add it now, reusing the same catalog add flow as 'Add MCP Server (From Catalog)'. Use this periodically to make sure a project (or this machine) has the MCP servers you expect. Safety note: the scan itself is read-only, but accepting a prompt to add a missing server mutates real Claude Code MCP configuration - always confirms first unless -Force is passed."
        }
    )
}
