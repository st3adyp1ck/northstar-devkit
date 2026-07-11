@{
    Name  = "System Tools"
    Items = @(
        @{
            Key    = '1'
            Label  = 'Edit PATH Variable'
            Script = 'Edit-Path.ps1'
        }
        @{
            Key             = '2'
            Label           = 'Backup Environment Variables'
            Script          = 'Env-Backup.ps1'
            RequiresProject = $true
            ProjectArgName  = 'OutputPath'
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
        }
        @{
            Key    = '4'
            Label  = 'Shell Reload (refresh env)'
            Script = 'Shell-Reload.ps1'
        }
    )
}
