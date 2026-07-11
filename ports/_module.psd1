@{
    Name  = "Port Tools"
    Items = @(
        @{
            Key    = '1'
            Label  = 'Scan Common Dev Ports'
            Script = 'Scan-Ports.ps1'
        }
        @{
            Key     = '2'
            Label   = 'Scan Specific Port (Read-Only)'
            Script  = 'Kill-Port.ps1'
            Prompts = @(
                @{ Name = 'Port'; Type = 'Int'; Prompt = 'Enter port number'; Min = 1; Max = 65535; InvalidMessage = 'Invalid port number.' }
            )
            StaticArgs = @{ InfoOnly = $true }
        }
        @{
            Key     = '3'
            Label   = 'Kill Process by PID'
            Script  = 'Kill-Port.ps1'
            Prompts = @(
                @{ Name = 'ProcessId'; Type = 'Int'; Prompt = 'Enter PID to kill'; Min = 1; Max = 2147483647; InvalidMessage = 'Invalid PID.' }
            )
        }
        @{
            Key    = '4'
            Label  = 'Kill All Node Processes'
            Script = 'Kill-AllNode.ps1'
        }
        @{
            Key     = '5'
            Label   = 'Kill Process by Port Number (Force, No Confirm)'
            Script  = 'Kill-Port.ps1'
            Prompts = @(
                @{ Name = 'Port'; Type = 'Int'; Prompt = 'Enter port number'; Min = 1; Max = 65535; InvalidMessage = 'Invalid port number.' }
            )
            StaticArgs = @{ Force = $true }
        }
        @{
            Key     = '6'
            Label   = 'Kill Process by Port Number (With Confirmation)'
            Script  = 'Kill-Port.ps1'
            Prompts = @(
                @{ Name = 'Port'; Type = 'Int'; Prompt = 'Enter port number'; Min = 1; Max = 65535; InvalidMessage = 'Invalid port number.' }
            )
        }
    )
}
