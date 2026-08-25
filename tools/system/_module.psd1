@{
    Name        = "System Tools"
    Description = "Edit the PATH environment variable, back up and restore User/Machine environment variables to/from a JSON file, and reload the current shell's environment without restarting the terminal. Most operations here read or write real environment state directly via [Environment]::GetEnvironmentVariable/SetEnvironmentVariable."
    Items = @(
        @{
            Key    = '1'
            Label  = 'Edit PATH Variable'
            Script = 'Edit-Path.ps1'
            Help   = "Interactive and flag-driven editor for the User or Machine PATH environment variable, with duplicate- and missing-path detection. Use -Show for a read-only report of the current PATH; -Add/-Remove/-Clean (or the [A]/[R]/[C] options in the interactive menu you get by running it with no flags) write PATH for real via [Environment]::SetEnvironmentVariable. Editing Machine PATH requires Administrator privileges - the script offers to relaunch itself elevated if it isn't. Safety note: -Remove and -Clean (and their interactive equivalents) each prompt with a y/n confirmation showing exactly what will change before writing, unless -Force is passed; -Add writes immediately (additive, low-risk); -Show never mutates anything."
        }
        @{
            Key             = '2'
            Label           = 'Backup Environment Variables'
            Script          = 'Env-Backup.ps1'
            RequiresProject = $true
            ProjectArgName  = 'OutputPath'
            Help            = "Writes a timestamped JSON snapshot of current User environment variables (and Machine variables too, if run elevated) to disk - additive only, it never changes the live environment. Variable names that look like secrets (TOKEN/KEY/SECRET/PASSWORD/CREDENTIAL/CONNECTIONSTRING/API_KEY) are redacted by default; pass -IncludeSecrets or -Redact:`$false to store raw values instead. From this menu it asks you to pick a linked project first and saves the backup file there. Safety note: shows a warning that the file may contain secrets and asks to continue before writing, unless -Force is passed - low risk overall since it only ever creates a new file, never overwrites or deletes anything."
        }
        @{
            Key           = '3'
            Label         = 'Restore Environment Variables'
            Script        = 'Env-Restore.ps1'
            RequiresFile  = @{
                Description = 'Select an environment backup to restore'
                Filter      = 'DevKit backups (*.json)|*.json|All files (*.*)|*.*'
                TypePrompt  = 'Enter backup file path to restore'
                ParamName   = 'BackupFile'
            }
            Help          = "Restores User (and, if run elevated, Machine) environment variables from a JSON file produced by 'Backup Environment Variables'. Use -WhatIf to preview what would be restored with no changes made at all. For PATH specifically, without -Force it shows an Added/Removed diff against the CURRENT live PATH and lets you choose Overwrite/Merge/Skip per scope rather than blindly replacing it. Safety note: mutates real User/Machine environment variables via [Environment]::SetEnvironmentVariable - always confirms first unless -Force is passed, and -Force also switches PATH restoration to a straight overwrite instead of the diff/merge prompt. Machine variables in the backup are skipped with a message if not run as Administrator."
        }
        @{
            Key    = '4'
            Label  = 'Shell Reload (refresh env)'
            Script = 'Shell-Reload.ps1'
            Help   = "Refreshes this PowerShell session's environment variables from the registry and re-dot-sources your PowerShell profile scripts, without closing the terminal. -Full also merges every current User and Machine variable into the session, not just PATH and a short common list (TEMP/TMP/HOME/USERPROFILE/JAVA_HOME/NODE_PATH/PYTHONPATH/GOPATH); -ProfileOnly skips the environment refresh and only reloads profiles; -ShowDiff prints which variables changed as a result. Only affects this running session's in-memory environment - it never calls SetEnvironmentVariable, so there's nothing to confirm."
        }
        @{
            Key        = '5'
            Label      = 'Edit Hosts File'
            Script     = 'Edit-HostsFile.ps1'
            Help       = "View, add, remove, and comment-toggle entries in the Windows hosts file (%windir%\System32\drivers\etc\hosts). Use -Show (or the menu's default listing) for a read-only numbered report showing each entry's IP, hostnames, and commented state; run with no flags for an interactive [A]dd/[R]emove/[T]oggle/[Q]uit menu, or -Add ""ip hostname..."" / -Remove / -Toggle (by listing index or hostname pattern) for scripted changes. Use this to map local dev domains (e.g. 127.0.0.1 mysite.local) without opening Notepad as admin. Safety note: every mutation requires Administrator privileges (the script offers to relaunch itself elevated), is gated by the shared confirmation prompt unless -Force is passed, creates a timestamped backup under %LOCALAPPDATA%\NorthstarDevKit\hosts-backups\ before the first write of a session, writes the file back as plain ASCII preserving all comments and ordering, and clears the DNS client cache afterward. -Show never mutates anything. This menu item runs with -Show, so opening it from the DevKit menu gives the read-only listing without requiring admin elevation."
            StaticArgs = @{ Show = $true }
        }
    )
}
