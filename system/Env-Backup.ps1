#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Environment Backup - Northstar DevKit
.DESCRIPTION
    Backup environment variables to a JSON file for later restoration.
    Backs up both User and Machine environment variables.
    
    WARNING: Backup files may contain secrets or tokens. Store them securely.
    
    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER OutputPath
    Directory to save backup file. Defaults to current directory.
.PARAMETER Name
    Optional name for this backup.
.PARAMETER IncludePath
    Include PATH variable in backup (default: true).
.PARAMETER Redact
    Mask the value of secret-like variables (TOKEN/KEY/SECRET/PASSWORD/
    CREDENTIAL/CONNECTIONSTRING/API_KEY) in the backup file. Enabled by
    default; pass -Redact:$false or -IncludeSecrets to store raw values.
.PARAMETER IncludeSecrets
    Store raw, unredacted values even for secret-like variable names.
    Equivalent to -Redact:$false.
.EXAMPLE
    .\Env-Backup.ps1
    .\Env-Backup.ps1 -OutputPath "C:\Backups"
    .\Env-Backup.ps1 -Name "BeforeProjectX"
    .\Env-Backup.ps1 -IncludeSecrets
#>
[CmdletBinding()]
param(
    [string]$OutputPath = ".",
    [string]$Name = "",
    [switch]$IncludePath = $true,
    [switch]$Redact = $true,
    [switch]$IncludeSecrets,
    [switch]$Force
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

Write-DevKitHeader "Environment Backup"

Write-Host "  WARNING: Backup files may contain secrets, API keys, or tokens." -ForegroundColor Yellow
Write-Host "  Store the output file in a secure location and keep it out of Git." -ForegroundColor Yellow
Write-Host ""

if (-not $Force) {
    $confirm = Read-Host "  Continue? (y/n)"
    if ($confirm -ne 'y') {
        Write-DevKitInfo "Cancelled."
        exit 0
    }
}

# Resolve output path (must be an existing or creatable directory, not a file)
try {
    if (-not (Test-Path -LiteralPath $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }
    $backupDir = Resolve-DevKitDirectory -Path $OutputPath
} catch {
    Write-DevKitError "Invalid output path '$OutputPath': $_"
    exit 1
}

# Generate backup filename (sanitize -Name against filesystem-invalid characters)
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$safeName = if ($Name) { $Name -replace '[\\/:*?"<>|]', '_' } else { '' }
$backupName = if ($safeName) { "$safeName-$timestamp" } else { "env-backup-$timestamp" }
$backupFile = Join-Path $backupDir "$backupName.json"

$effectiveRedact = $Redact -and -not $IncludeSecrets
$secretPattern = '(TOKEN|KEY|SECRET|PASSWORD|CREDENTIAL|CONN(ECTION)?STRING|API_?KEY)'

function Get-DevKitBackupValue {
    param(
        [string]$VarName,
        [string]$VarValue
    )
    if ($effectiveRedact -and $VarName -match $secretPattern) {
        return "***REDACTED***"
    }
    return $VarValue
}

Write-DevKitInfo "Target: $backupFile"
Write-DevKitInfo "Redaction: $(if ($effectiveRedact) { 'ON (secret-like values masked)' } else { 'OFF (raw values included)' })"
Write-DevKitStep "Creating backup"

# Collect environment variables
$backup = @{
    Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Computer = $env:COMPUTERNAME
    User = $env:USERNAME
    Variables = @{
        User = @{}
        Machine = @{}
    }
}

# Backup User variables
Write-DevKitInfo "Backing up User environment variables"
$userVars = [Environment]::GetEnvironmentVariables("User")
foreach ($var in $userVars.GetEnumerator()) {
    if ($var.Key -eq "PATH" -and -not $IncludePath) { continue }
    $backup.Variables.User[$var.Key] = Get-DevKitBackupValue -VarName $var.Key -VarValue $var.Value
}

# Backup Machine variables (if admin)
if (Test-DevKitAdmin) {
    Write-DevKitInfo "Backing up Machine environment variables"
    $machineVars = [Environment]::GetEnvironmentVariables("Machine")
    foreach ($var in $machineVars.GetEnumerator()) {
        if ($var.Key -eq "PATH" -and -not $IncludePath) { continue }
        $backup.Variables.Machine[$var.Key] = Get-DevKitBackupValue -VarName $var.Key -VarValue $var.Value
    }
} else {
    Write-Host "  Skipping Machine variables (requires Admin)" -ForegroundColor Yellow
}

# Save to JSON
try {
    $backup | ConvertTo-Json -Depth 10 | Out-File -FilePath $backupFile -Encoding UTF8 -ErrorAction Stop
    Write-DevKitDone
} catch {
    Write-DevKitError "Failed to write backup file: $_"
    exit 1
}

# Summary
$userCount = $backup.Variables.User.Count
$machineCount = if (Test-DevKitAdmin) { $backup.Variables.Machine.Count } else { 0 }

Write-Host "`n  ===================================" -ForegroundColor Cyan
Write-Host "  DONE: Backup created successfully!" -ForegroundColor Green
Write-Host "  User variables:     $userCount" -ForegroundColor Gray
Write-Host "  Machine variables:  $machineCount" -ForegroundColor Gray
Write-Host "  File: $backupFile" -ForegroundColor Gray
Write-Host "  ===================================`n" -ForegroundColor Cyan

# Return backup file path for piping
$backupFile
