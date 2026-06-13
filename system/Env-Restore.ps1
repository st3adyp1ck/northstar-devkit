#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Environment Restore - Northstar DevKit
.DESCRIPTION
    Restore environment variables from a JSON backup file.
    Restores both User and Machine environment variables.
    
    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER BackupFile
    Path to the backup JSON file to restore from.
.PARAMETER WhatIf
    Show what would be restored without making changes.
.PARAMETER Force
    Skip confirmation prompts.
.EXAMPLE
    .\Env-Restore.ps1 -BackupFile "env-backup-20240101_120000.json"
    .\Env-Restore.ps1 -BackupFile "backup.json" -WhatIf
    Get-ChildItem *.json | .\Env-Restore.ps1
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
    [string]$BackupFile,
    [switch]$WhatIf,
    [switch]$Force
)

$CommonModule = Join-Path $PSScriptRoot ".." "lib" "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

begin {
    Write-Host "`nNorthstar DevKit - Environment Restore`n" -ForegroundColor Cyan
}

process {
    # Resolve backup file path
    $backupPath = Resolve-Path $BackupFile -ErrorAction SilentlyContinue
    if (-not $backupPath) {
        Write-Host "  ERROR: Backup file not found: $BackupFile`n" -ForegroundColor Red
        return
    }
    
    Write-Host "  Loading backup: $backupPath" -ForegroundColor Gray
    
    # Load backup
    try {
        $backup = Get-Content $backupPath | ConvertFrom-Json
    } catch {
        Write-Host "  ERROR: Failed to parse backup file: $_`n" -ForegroundColor Red
        return
    }
    
    # Show backup info
    Write-Host "`n  Backup Information:" -ForegroundColor Yellow
    Write-Host "    Created:  $($backup.Timestamp)" -ForegroundColor Gray
    Write-Host "    Computer: $($backup.Computer)" -ForegroundColor Gray
    Write-Host "    User:     $($backup.User)" -ForegroundColor Gray
    
    $userVarsCount = ($backup.Variables.User.PSObject.Properties | Measure-Object).Count
    $machineVarsCount = ($backup.Variables.Machine.PSObject.Properties | Measure-Object).Count
    
    Write-Host "`n  Variables to restore:" -ForegroundColor Yellow
    Write-Host "    User:    $userVarsCount variables" -ForegroundColor Gray
    Write-Host "    Machine: $machineVarsCount variables" -ForegroundColor Gray
    
    # WhatIf mode
    if ($WhatIf) {
        Write-Host "`n  [WHATIF] Would restore the following variables:" -ForegroundColor Magenta
        
        Write-Host "`n  User Variables:" -ForegroundColor Cyan
        $backup.Variables.User.PSObject.Properties | ForEach-Object {
            $value = if ($_.Value.Length -gt 50) { $_.Value.Substring(0, 50) + "..." } else { $_.Value }
            Write-Host "    $($_.Name) = $value" -ForegroundColor Gray
        }
        
        Write-Host "`n  Machine Variables:" -ForegroundColor Cyan
        $backup.Variables.Machine.PSObject.Properties | ForEach-Object {
            $value = if ($_.Value.Length -gt 50) { $_.Value.Substring(0, 50) + "..." } else { $_.Value }
            Write-Host "    $($_.Name) = $value" -ForegroundColor Gray
        }
        Write-Host ""
        return
    }
    
    # Confirm
    if (-not $Force) {
        Write-Host "`n  WARNING: This will overwrite current environment variables!" -ForegroundColor Red
        $confirm = Read-Host "  Continue with restore? (y/n)"
        if ($confirm -ne 'y') {
            Write-Host "  Cancelled.`n" -ForegroundColor Gray
            return
        }
    }
    
    # Check admin for machine variables
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    
    # Restore User variables
    Write-Host "`n  Restoring User environment variables..." -ForegroundColor Yellow
    $userRestored = 0
    $backup.Variables.User.PSObject.Properties | ForEach-Object {
        try {
            [Environment]::SetEnvironmentVariable($_.Name, $_.Value, "User")
            $userRestored++
        } catch {
            Write-Host "    ERROR restoring $($_.Name): $_" -ForegroundColor Red
        }
    }
    Write-Host "  DONE: Restored $userRestored User variables." -ForegroundColor Green
    
    # Restore Machine variables
    if ($machineVarsCount -gt 0) {
        if (-not $isAdmin) {
            Write-Host "  SKIPPED: Machine variables require Administrator privileges." -ForegroundColor Yellow
        } else {
            Write-Host "`n  Restoring Machine environment variables..." -ForegroundColor Yellow
            $machineRestored = 0
            $backup.Variables.Machine.PSObject.Properties | ForEach-Object {
                try {
                    [Environment]::SetEnvironmentVariable($_.Name, $_.Value, "Machine")
                    $machineRestored++
                } catch {
                    Write-Host "    ERROR restoring $($_.Name): $_" -ForegroundColor Red
                }
            }
            Write-Host "  DONE: Restored $machineRestored Machine variables." -ForegroundColor Green
        }
    }
    
    Write-Host "`n  ===================================" -ForegroundColor Cyan
    Write-Host "  Restore complete!" -ForegroundColor Green
    Write-Host "  Restart your terminal to see all changes." -ForegroundColor Yellow
    Write-Host "  ===================================`n" -ForegroundColor Cyan
}
