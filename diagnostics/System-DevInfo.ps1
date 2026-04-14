#!/usr/bin/env pwsh
<#
.SYNOPSIS
    System Dev Info - Northstar DevKit
.DESCRIPTION
    Quick system summary relevant to developers. Shows versions of
    installed tools, available ports, disk space, and environment info.
    
    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Export
    Export the information to a JSON file.
.PARAMETER Clipboard
    Copy the summary to clipboard.
.EXAMPLE
    .\System-DevInfo.ps1
    .\System-DevInfo.ps1 -Export
    .\System-DevInfo.ps1 -Clipboard
#>
[CmdletBinding()]
param(
    [switch]$Export,
    [switch]$Clipboard
)

Write-Host "`nNorthstar DevKit - System Dev Info`n" -ForegroundColor Cyan

$info = @{
    Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    System = @{}
    Tools = @()
    Network = @{}
    Resources = @{}
}

# System Info
Write-Host "  System Information:" -ForegroundColor Yellow
$os = Get-CimInstance Win32_OperatingSystem
$computerSystem = Get-CimInstance Win32_ComputerSystem

$info.System = @{
    OS = $os.Caption
    Version = [System.Environment]::OSVersion.Version.ToString()
    Architecture = $os.OSArchitecture
    ComputerName = $env:COMPUTERNAME
    Username = $env:USERNAME
}

Write-Host "    OS:        $($info.System.OS)" -ForegroundColor Gray
Write-Host "    Version:   $($info.System.Version)" -ForegroundColor Gray
Write-Host "    Arch:      $($info.System.Architecture)" -ForegroundColor Gray
Write-Host "    Computer:  $($info.System.ComputerName)" -ForegroundColor Gray
Write-Host "    User:      $($info.System.Username)" -ForegroundColor Gray

# Tools Info
Write-Host "`n  Development Tools:" -ForegroundColor Yellow

$tools = @(
    @{ Name = "PowerShell"; Cmd = "pwsh"; Args = "--version"; Pattern = '(\d+\.\d+\.\d+)' }
    @{ Name = "Node.js"; Cmd = "node"; Args = "--version"; Pattern = 'v(\d+\.\d+\.\d+)' }
    @{ Name = "NPM"; Cmd = "npm"; Args = "--version"; Pattern = '(\d+\.\d+\.\d+)' }
    @{ Name = "Git"; Cmd = "git"; Args = "--version"; Pattern = '(\d+\.\d+\.\d+)' }
    @{ Name = "Docker"; Cmd = "docker"; Args = "--version"; Pattern = '(\d+\.\d+\.\d+)' }
    @{ Name = "Python"; Cmd = "python"; Args = "--version"; Pattern = '(\d+\.\d+\.\d+)' }
    @{ Name = "VS Code"; Cmd = "code"; Args = "--version"; Pattern = '(^[\d\.]+)' }
)

foreach ($tool in $tools) {
    try {
        $output = & $tool.Cmd $tool.Args.Split(' ') 2>&1 | Select-Object -First 1
        if ($LASTEXITCODE -eq 0 -or $output -match $tool.Pattern) {
            if ($output -match $tool.Pattern) {
                $version = $matches[1]
                $info.Tools += @{ Name = $tool.Name; Version = $version; Installed = $true }
                Write-Host "    $($tool.Name.PadRight(12)) v$version" -ForegroundColor Green
            } else {
                $info.Tools += @{ Name = $tool.Name; Version = "Unknown"; Installed = $true }
                Write-Host "    $($tool.Name.PadRight(12)) Installed" -ForegroundColor Green
            }
        } else {
            throw "Not installed"
        }
    } catch {
        $info.Tools += @{ Name = $tool.Name; Version = $null; Installed = $false }
        Write-Host "    $($tool.Name.PadRight(12)) Not installed" -ForegroundColor Gray
    }
}

# Network Info
Write-Host "`n  Network:" -ForegroundColor Yellow

try {
    $ipConfig = Get-NetIPConfiguration | Where-Object { $_.NetAdapter.Status -eq 'Up' } | Select-Object -First 1
    if ($ipConfig) {
        $ip = $ipConfig.IPv4Address.IPAddress
        $gateway = $ipConfig.IPv4DefaultGateway.NextHop
        Write-Host "    IP Address: $ip" -ForegroundColor Gray
        Write-Host "    Gateway:    $gateway" -ForegroundColor Gray
        $info.Network.IPAddress = $ip
        $info.Network.Gateway = $gateway
    }
} catch {
    Write-Host "    Could not retrieve network info" -ForegroundColor Gray
}

# Common dev ports
$commonPorts = @(3000, 3001, 5173, 8000, 8080, 9000, 4200, 5000, 5500)
$usedPorts = @()

foreach ($port in $commonPorts) {
    $connection = Get-NetTCPConnection -LocalPort $port -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($connection) {
        try {
            $process = Get-Process -Id $connection.OwningProcess -ErrorAction SilentlyContinue
            $procName = if ($process) { $process.ProcessName } else { "Unknown" }
            $usedPorts += @{ Port = $port; Process = $procName }
        } catch {
            $usedPorts += @{ Port = $port; Process = "Unknown" }
        }
    }
}

if ($usedPorts.Count -gt 0) {
    Write-Host "    Used Ports: " -NoNewline -ForegroundColor Gray
    $portList = $usedPorts | ForEach-Object { "$($_.Port)($($_.Process))" }
    Write-Host ($portList -join ', ') -ForegroundColor Yellow
} else {
    Write-Host "    Common dev ports: All free" -ForegroundColor Green
}

$info.Network.UsedPorts = $usedPorts

# Resources
Write-Host "`n  Resources:" -ForegroundColor Yellow

$disks = Get-CimInstance Win32_LogicalDisk | Where-Object { $_.DriveType -eq 3 }
foreach ($disk in $disks) {
    $freeGB = [math]::Round($disk.FreeSpace / 1GB, 1)
    $totalGB = [math]::Round($disk.Size / 1GB, 1)
    $usedPercent = [math]::Round((($disk.Size - $disk.FreeSpace) / $disk.Size) * 100, 0)
    $color = if ($usedPercent -gt 90) { "Red" } elseif ($usedPercent -gt 70) { "Yellow" } else { "Green" }
    
    Write-Host "    Disk $($disk.DeviceID) " -NoNewline -ForegroundColor Gray
    Write-Host "$freeGB GB free / $totalGB GB total ($usedPercent% used)" -ForegroundColor $color
    
    $info.Resources["Disk$($disk.DeviceID)"] = @{
        FreeGB = $freeGB
        TotalGB = $totalGB
        UsedPercent = $usedPercent
    }
}

# Memory
$totalRAM = [math]::Round($computerSystem.TotalPhysicalMemory / 1GB, 1)
Write-Host "    RAM:        $totalRAM GB total" -ForegroundColor Gray
$info.Resources.RAM_GB = $totalRAM

# Environment
Write-Host "`n  Environment:" -ForegroundColor Yellow

$pathCount = ($env:PATH -split ';' | Where-Object { $_ }).Count
Write-Host "    PATH entries: $pathCount" -ForegroundColor Gray
$info.Resources.PATHEntries = $pathCount

try {
    $execPolicy = Get-ExecutionPolicy
} catch {
    $execPolicy = "Unknown"
}
Write-Host "    Execution Policy: $execPolicy" -ForegroundColor Gray
$info.Resources.ExecutionPolicy = $execPolicy

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Host "    Admin Rights: $(if($isAdmin){'Yes'}else{'No'})" -ForegroundColor Gray
$info.Resources.IsAdmin = $isAdmin

# Export
if ($Export) {
    $exportFile = "devinfo-$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
    $info | ConvertTo-Json -Depth 5 | Out-File $exportFile
    Write-Host "`n  Exported to: $exportFile" -ForegroundColor Green
}

# Clipboard
if ($Clipboard) {
    $clipboardText = @"
System Dev Info - $(Get-Date -Format 'yyyy-MM-dd')

OS: $($info.System.OS) $($info.System.Version)
Tools:
$(($info.Tools | Where-Object Installed | ForEach-Object { "- $($_.Name): v$($_.Version)" }) -join "`n")

Disk: $($info.Resources.DiskC_.FreeGB)GB free / $($info.Resources.DiskC_.TotalGB)GB total
RAM: $($info.Resources.RAM_GB) GB
"@
    $clipboardText | Set-Clipboard
    Write-Host "`n  Copied to clipboard!" -ForegroundColor Green
}

Write-Host "`n  ===================================" -ForegroundColor Cyan
Write-Host "  Done!" -ForegroundColor Green
Write-Host "  ===================================`n" -ForegroundColor Cyan
