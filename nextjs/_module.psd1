@{
    Name  = "Next.js Tools"
    Items = @(
        @{
            Key             = '1'
            Label           = 'Clear .next Build Cache'
            Script          = 'Clear-NextCache.ps1'
            RequiresProject = $true
        }
        @{
            Key             = '2'
            Label           = 'Clear Turbopack Cache'
            Script          = 'Clear-TurboCache.ps1'
            RequiresProject = $true
        }
        @{
            Key             = '3'
            Label           = 'Full Clean (.next + node_modules + reinstall)'
            Script          = 'Next-FullClean.ps1'
            RequiresProject = $true
        }
        @{
            Key             = '4'
            Label           = 'Dev Server (Fresh Start)'
            Script          = 'Next-DevFresh.ps1'
            RequiresProject = $true
            Prompts         = @(
                @{ Name = 'Turbo'; Type = 'YesNo'; Prompt = 'Clear Turbopack cache too?'; Optional = $true }
                @{ Name = 'Port'; Type = 'Int'; Prompt = 'Port (press Enter for default)'; Optional = $true; Min = 1; Max = 65535 }
            )
        }
    )
}
