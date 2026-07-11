@{
    Name  = "Docker Tools"
    Items = @(
        @{
            Key    = '1'
            Label  = 'Docker Nuke (remove all)'
            Script = 'Docker-Nuke.ps1'
        }
        @{
            Key    = '2'
            Label  = 'Docker Cleanup (selective)'
            Script = 'Docker-Cleanup.ps1'
        }
        @{
            Key    = '3'
            Label  = 'Quick Logs (multi-container)'
            Script = 'Docker-QuickLogs.ps1'
        }
    )
}
