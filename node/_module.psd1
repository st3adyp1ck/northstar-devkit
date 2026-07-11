@{
    Name  = "Node.js Tools"
    Items = @(
        @{
            Key    = '1'
            Label  = 'Clear NPM Cache'
            Script = 'Clear-NpmCache.ps1'
        }
        @{
            Key             = '2'
            Label           = 'Delete node_modules'
            Script          = 'Remove-NodeModules.ps1'
            RequiresProject = $true
        }
        @{
            Key             = '3'
            Label           = 'Delete node_modules + Lock + Reinstall'
            Script          = 'Nuke-And-Reinstall.ps1'
            RequiresProject = $true
        }
        @{
            Key    = '4'
            Label  = 'Check NPM Cache Size'
            Script = 'Check-NpmCacheSize.ps1'
        }
    )
}
