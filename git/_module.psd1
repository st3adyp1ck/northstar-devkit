@{
    Name  = "Git Tools"
    Items = @(
        @{
            Key             = '1'
            Label           = 'Git Cleanup (prune, gc, etc.)'
            Script          = 'Git-Cleanup.ps1'
            RequiresProject = $true
        }
        @{
            Key             = '2'
            Label           = 'Git Status All (scan repos)'
            Script          = 'Git-StatusAll.ps1'
            RequiresProject = $true
        }
        @{
            Key             = '3'
            Label           = 'Sync Fork with Upstream'
            Script          = 'Git-SyncFork.ps1'
            RequiresProject = $true
        }
    )
}
