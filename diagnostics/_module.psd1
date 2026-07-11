@{
    Name  = "Diagnostics"
    Items = @(
        @{
            Key    = '1'
            Label  = 'DevKit Doctor (health check)'
            Script = 'DevKit-Doctor.ps1'
        }
        @{
            Key    = '2'
            Label  = 'System Dev Info'
            Script = 'System-DevInfo.ps1'
        }
        @{
            Key    = '3'
            Label  = 'Check for Updates'
            Script = 'Test-DevKitUpdate.ps1'
        }
    )
}
