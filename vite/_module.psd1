@{
    Name  = "Vite Tools"
    Items = @(
        @{
            Key             = '1'
            Label           = 'Vite Dev Server (Fresh Start)'
            Script          = 'Vite-DevFresh.ps1'
            RequiresProject = $true
        }
        @{
            Key             = '2'
            Label           = 'Build and Preview'
            Script          = 'Vite-PreviewBuild.ps1'
            RequiresProject = $true
        }
    )
}
