@{
    Name        = "WiFi Tools"
    Description = "Scan nearby WiFi networks and optimize a WiFi connection (DNS, Winsock, TCP/IP) using netsh and Windows networking cmdlets. Scanning is read-only; optimization requires administrator privileges and recommends a reboot to fully complete."
    Items       = @(
        @{
            Key    = '1'
            Label  = 'WiFi Optimizer (Full)'
            Script = 'WiFi-Optimize.ps1'
            Help   = "Full network optimization: flushes/re-registers DNS, resets Winsock and TCP/IP, releases and renews the IP, pings Cloudflare (1.1.1.1) and Google (8.8.8.8) to pick the faster public DNS and applies it (IPv4 and IPv6) to the active WiFi adapter, tunes TCP autotuning/RSS, then tests latency and (unless -Fast) runs an ~8-second Cloudflare download speed test. Use this when a WiFi connection feels slow and you want a full diagnose-and-fix pass. Safety note: mutates real network configuration - requires administrator privileges (exits with an error if not elevated), shows a Yellow warning and asks for y/n confirmation before proceeding unless -Force is passed, backs up the adapter's previous DNS settings to a JSON file before changing them (undo with -RestoreDns, which touches nothing else), and recommends a restart afterward to fully complete the TCP/IP reset. -KeepDNS leaves DNS untouched."
        }
        @{
            Key        = '2'
            Label      = 'WiFi Optimizer (Fast Mode)'
            Script     = 'WiFi-FastMode.ps1'
            StaticArgs = @{ Fast = $true }
            Help       = "Same optimization as WiFi Optimizer (Full), but always skips the download speed test for a quicker pass - internally it just calls WiFi-Optimize.ps1 -Fast. Use this when you want the DNS/TCP-IP optimization without waiting on the speed test. Safety note: identical mutations to WiFi Optimizer (Full) - DNS/Winsock/TCP-IP changes, requires administrator privileges, shows the same Yellow warning and y/n confirmation unless -Force is passed, and recommends a restart afterward. Supports -KeepDNS; DNS changes can be undone with WiFi-Optimize.ps1 -RestoreDns."
        }
        @{
            Key    = '3'
            Label  = 'WiFi Scanner'
            Script = 'WiFi-Scan.ps1'
            Help   = "Scans nearby WiFi networks (netsh wlan show networks) and lists them sorted by best signal strength, with security type and channel, plus recommendations - best open network, best secured network, and a congested-channel note. Read-only - makes no changes. Requires a supported wireless adapter; reports cleanly (no crash) if no adapter is present or no networks can be parsed. Use this to see what's nearby, judge signal quality, or spot channel congestion before troubleshooting a connection."
        }
    )
}
