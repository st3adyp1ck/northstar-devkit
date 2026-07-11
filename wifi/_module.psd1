@{
    Name  = "WiFi Tools"
    Items = @(
        @{
            Key    = '1'
            Label  = 'WiFi Optimizer (Full)'
            Script = 'WiFi-Optimize.ps1'
        }
        @{
            Key        = '2'
            Label      = 'WiFi Optimizer (Fast Mode)'
            Script     = 'WiFi-FastMode.ps1'
            StaticArgs = @{ Fast = $true }
        }
        @{
            Key    = '3'
            Label  = 'WiFi Scanner'
            Script = 'WiFi-Scan.ps1'
        }
    )
}
