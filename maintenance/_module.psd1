@{
    Name  = "Maintenance"
    Items = @(
        @{
            Key    = '1'
            Label  = 'Clear Disk Junk (temp/WU cache/Recycle Bin)'
            Script = 'Clear-DiskJunk.ps1'
        }
        @{
            Key    = '2'
            Label  = 'Disk Usage Report (top folders by size)'
            Script = 'Show-DiskUsageReport.ps1'
        }
        @{
            Key    = '3'
            Label  = 'Manage Startup Programs'
            Script = 'Manage-StartupPrograms.ps1'
        }
        @{
            Key    = '4'
            Label  = 'Manage Services'
            Script = 'Manage-Services.ps1'
        }
        @{
            Key    = '5'
            Label  = 'Repair System Files (SFC + DISM)'
            Script = 'Repair-SystemFiles.ps1'
        }
        @{
            Key    = '6'
            Label  = 'Reset Windows Update Cache'
            Script = 'Reset-WindowsUpdate.ps1'
        }
        @{
            Key    = '7'
            Label  = 'Scheduled Tasks Report'
            Script = 'Get-ScheduledTasksReport.ps1'
        }
        @{
            Key    = '8'
            Label  = 'Recent Event Errors'
            Script = 'Get-RecentEventErrors.ps1'
        }
        @{
            Key    = '9'
            Label  = 'Power Plan Manager'
            Script = 'Set-PowerPlan.ps1'
        }
        @{
            Key    = '10'
            Label  = 'Visual Effects Manager'
            Script = 'Set-VisualEffects.ps1'
        }
        @{
            Key    = '11'
            Label  = 'Page File Configuration Report'
            Script = 'Test-PageFileConfig.ps1'
        }
        @{
            Key    = '12'
            Label  = 'Disk Health Report'
            Script = 'Get-DiskHealthReport.ps1'
        }
        @{
            Key    = '13'
            Label  = 'Battery Report'
            Script = 'Get-BatteryReport.ps1'
        }
        @{
            Key    = '14'
            Label  = 'Memory Diagnostic'
            Script = 'Invoke-MemoryDiagnostic.ps1'
        }
    )
}
