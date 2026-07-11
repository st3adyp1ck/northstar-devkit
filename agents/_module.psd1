@{
    Name  = "Agents & MCP"
    Items = @(
        @{
            Key    = '1'
            Label  = 'List Installed AI CLIs'
            Script = 'Get-InstalledAiClis.ps1'
        }
        @{
            Key    = '2'
            Label  = 'Update AI CLIs (npm-based)'
            Script = 'Update-AiClis.ps1'
        }
        @{
            Key    = '3'
            Label  = 'List MCP Servers'
            Script = 'Get-McpServers.ps1'
        }
        @{
            Key    = '4'
            Label  = 'Add MCP Server'
            Script = 'Add-McpServer.ps1'
        }
        @{
            Key    = '5'
            Label  = 'Remove MCP Server'
            Script = 'Remove-McpServer.ps1'
        }
    )
}
