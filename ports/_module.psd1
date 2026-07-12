@{
    Name        = "Port Tools"
    Description = "Detect what's listening on common local dev ports (3000, 5173, 8080, etc.) via Get-NetTCPConnection, and kill a process by port or PID - either a single target or every running Node.js process at once."
    Items       = @(
        @{
            Key    = '1'
            Label  = 'Scan Common Dev Ports'
            Script = 'Scan-Ports.ps1'
            Help   = "Scans the fixed list of common dev ports (3000, 3001, 3002, 3003, 5173, 5174, 8000, 8080, 8081, 9000, 4200, 5000, 5500, 1337, 5432, 3306, 6379, 27017) via Get-NetTCPConnection and reports the PID and process name listening on each. Read-only from this menu entry - the script's own -Kill switch (interactive kill-while-scanning) is not passed by this menu item. Use this first to see what's currently running before deciding whether to kill anything."
        }
        @{
            Key     = '2'
            Label   = 'Scan Specific Port (Read-Only)'
            Script  = 'Kill-Port.ps1'
            Help    = "Looks up the process currently listening on one port you enter and displays its PID, name, path, and start time. Read-only - runs Kill-Port.ps1 with -InfoOnly, which never calls Stop-Process. Use this to identify a process before deciding whether to kill it with one of the Kill Process options below."
            Prompts = @(
                @{ Name = 'Port'; Type = 'Int'; Prompt = 'Enter port number'; Min = 1; Max = 65535; InvalidMessage = 'Invalid port number.' }
            )
            StaticArgs = @{ InfoOnly = $true }
        }
        @{
            Key     = '3'
            Label   = 'Kill Process by PID'
            Script  = 'Kill-Port.ps1'
            Help    = "Kills a specific process by PID that you enter directly, with no port lookup. Refuses PID 0 and 4 (reserved system processes) and the current DevKit process's own PID. Safety note: mutates real system state - prompts 'Kill process NAME (PID: X)? (y/n)' before stopping it (a plain y/n prompt, not the shared Confirm-DevKitDestructiveAction gate), and re-verifies the process's identity immediately before killing to guard against the PID being reused while you were confirming."
            Prompts = @(
                @{ Name = 'ProcessId'; Type = 'Int'; Prompt = 'Enter PID to kill'; Min = 1; Max = 2147483647; InvalidMessage = 'Invalid PID.' }
            )
        }
        @{
            Key    = '4'
            Label  = 'Kill All Node Processes'
            Script = 'Kill-AllNode.ps1'
            Help   = "Finds every running process named 'node' and kills them all. Lists each one (PID, CPU, start time) before acting. Safety note: mutates real system state - prompts 'Kill all N process(es)? (y/n)' before stopping any of them (a plain y/n prompt, not the shared Confirm-DevKitDestructiveAction gate), and re-verifies each process's identity immediately before killing it to guard against a PID being reused while you were confirming. This menu item does not pass -Force, so you'll always see the prompt; the script supports -Force directly for automation."
        }
        @{
            Key     = '5'
            Label   = 'Kill Process by Port Number (Force, No Confirm)'
            Script  = 'Kill-Port.ps1'
            Help    = "Finds the process listening on a port you enter and kills it immediately with no confirmation prompt (Kill-Port.ps1 -Port X -Force). Still refuses PID 0/4 and the current DevKit process's own PID, and still re-verifies the process's identity immediately before killing it. Safety note: mutates real system state with no y/n gate - use only when you're sure, e.g. clearing a stuck dev server."
            Prompts = @(
                @{ Name = 'Port'; Type = 'Int'; Prompt = 'Enter port number'; Min = 1; Max = 65535; InvalidMessage = 'Invalid port number.' }
            )
            StaticArgs = @{ Force = $true }
        }
        @{
            Key     = '6'
            Label   = 'Kill Process by Port Number (With Confirmation)'
            Script  = 'Kill-Port.ps1'
            Help    = "Finds the process listening on a port you enter, shows its PID/name/path, and asks for confirmation before killing it (Kill-Port.ps1 -Port X, no -Force). Safety note: mutates real system state - prompts 'Kill process NAME (PID: X)? (y/n)' before stopping it (a plain y/n prompt, not the shared Confirm-DevKitDestructiveAction gate), and re-verifies the process's identity immediately before killing to guard against the PID being reused while you were confirming."
            Prompts = @(
                @{ Name = 'Port'; Type = 'Int'; Prompt = 'Enter port number'; Min = 1; Max = 65535; InvalidMessage = 'Invalid port number.' }
            )
        }
    )
}
