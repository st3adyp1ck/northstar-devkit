@{
    Name  = "Workflow Tools"
    Items = @(
        @{
            Key             = '1'
            Label           = 'Code Here (open VS Code/Cursor)'
            Script          = 'Code-Here.ps1'
            RequiresProject = $true
        }
        @{
            Key             = '2'
            Label           = 'Open Repo in Browser'
            Script          = 'Open-Repo.ps1'
            RequiresProject = $true
        }
        @{
            Key             = '3'
            Label           = 'Copy .env Template'
            Script          = 'Copy-EnvTemplate.ps1'
            RequiresProject = $true
        }
    )
}
