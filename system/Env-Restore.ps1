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
    Skip confirmation prompts. Also skips the PATH diff/merge prompt and
    restores PATH via a straight overwrite (the pre-3.0 behavior).
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

begin {
    # This dot-source must live inside begin{} rather than as loose top-level
    # code between param() and begin{}: PowerShell only recognizes bare
    # begin/process/end as pipeline blocks when they are the ENTIRE script
    # body immediately following param()/dynamicparam(). Any other top-level
    # statement in between (as this used to be) makes the parser treat the
    # literal token "begin" as a command name instead - which throws "The
    # term 'begin' is not recognized ..." on every single invocation. This
    # was a real, pre-existing bug: the script could not run at all.
    $CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
    if (Test-Path $CommonModule) { . $CommonModule }

    Write-DevKitHeader "Environment Restore"

    function Resolve-DevKitPathRestoreValue {
        <#
            Compares a backed-up PATH value for the given scope against the
            CURRENT live PATH for that scope, shows the diff, and lets the
            user choose Overwrite / Merge / Skip. Returns the PATH string to
            write, or $null if the user chose to skip restoring PATH.
        #>
        param(
            [Parameter(Mandatory = $true)]
            [string]$Scope,

            [Parameter(Mandatory = $true)]
            [AllowEmptyString()]
            [string]$BackupPathValue
        )

        $currentPathValue = [Environment]::GetEnvironmentVariable("PATH", $Scope)
        $currentEntries = @($currentPathValue -split ';' | Where-Object { $_ -ne '' })
        $backupEntries = @($BackupPathValue -split ';' | Where-Object { $_ -ne '' })

        $added = @($backupEntries | Where-Object { $currentEntries -notcontains $_ })
        $removed = @($currentEntries | Where-Object { $backupEntries -notcontains $_ })

        Write-Host "`n  PATH ($Scope) differs from the current live PATH:" -ForegroundColor Magenta
        if ($added.Count -gt 0) {
            Write-Host "    Would ADD (in backup, missing now):" -ForegroundColor Green
            $added | ForEach-Object { Write-Host "      + $_" -ForegroundColor Green }
        }
        if ($removed.Count -gt 0) {
            Write-Host "    Would REMOVE (present now, not in backup):" -ForegroundColor Red
            $removed | ForEach-Object { Write-Host "      - $_" -ForegroundColor Red }
        }
        if ($added.Count -eq 0 -and $removed.Count -eq 0) {
            Write-Host "    No differences detected." -ForegroundColor Gray
        }

        Write-Host ""
        Write-Host "    [O] Overwrite - replace current $Scope PATH with the backed-up value" -ForegroundColor Cyan
        Write-Host "    [M] Merge     - union of current + backed-up entries (keeps both)" -ForegroundColor Cyan
        Write-Host "    [S] Skip      - leave $Scope PATH untouched (default)" -ForegroundColor Cyan
        $pathChoice = Read-Host "  Restore $Scope PATH - choose (O/M/S)"

        switch ($pathChoice.ToUpper()) {
            'O' {
                Write-Host "  $Scope PATH will be overwritten." -ForegroundColor Yellow
                return $BackupPathValue
            }
            'M' {
                $seen = @{}
                $merged = @()
                foreach ($entry in (@($currentEntries) + @($backupEntries))) {
                    $key = $entry.ToLower()
                    if (-not $seen.ContainsKey($key)) {
                        $seen[$key] = $true
                        $merged += $entry
                    }
                }
                Write-Host "  $Scope PATH will be merged." -ForegroundColor Yellow
                return ($merged -join ';')
            }
            default {
                Write-Host "  Skipped $Scope PATH restore.`n" -ForegroundColor Gray
                return $null
            }
        }
    }
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

    # Validate this is actually a DevKit environment backup, not just any
    # syntactically-valid JSON file
    if (-not $backup.Variables -or
        (-not $backup.Variables.PSObject.Properties['User'] -and
         -not $backup.Variables.PSObject.Properties['Machine'])) {
        Write-DevKitError "Not a recognized DevKit backup file: $backupPath"
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
        Write-Host "`n  WARNING: This will overwrite current environment variables!" -ForegroundColor Yellow
        $confirm = Read-Host "  Continue with restore? (y/n)"
        if ($confirm -ne 'y') {
            Write-Host "  Cancelled.`n" -ForegroundColor Gray
            return
        }
    }
    
    # Check admin for machine variables
    $isAdmin = Test-DevKitAdmin

    # Restore User variables
    Write-Host "`n  Restoring User environment variables..." -ForegroundColor Yellow
    $userRestored = 0
    $backup.Variables.User.PSObject.Properties | ForEach-Object {
        try {
            if ($_.Name -eq "PATH") {
                if ($Force) {
                    [Environment]::SetEnvironmentVariable($_.Name, $_.Value, "User")
                    $userRestored++
                } else {
                    $mergedPath = Resolve-DevKitPathRestoreValue -Scope "User" -BackupPathValue $_.Value
                    if ($null -ne $mergedPath) {
                        [Environment]::SetEnvironmentVariable("PATH", $mergedPath, "User")
                        $userRestored++
                    }
                }
            } else {
                [Environment]::SetEnvironmentVariable($_.Name, $_.Value, "User")
                $userRestored++
            }
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
                    if ($_.Name -eq "PATH") {
                        if ($Force) {
                            [Environment]::SetEnvironmentVariable($_.Name, $_.Value, "Machine")
                            $machineRestored++
                        } else {
                            $mergedPath = Resolve-DevKitPathRestoreValue -Scope "Machine" -BackupPathValue $_.Value
                            if ($null -ne $mergedPath) {
                                [Environment]::SetEnvironmentVariable("PATH", $mergedPath, "Machine")
                                $machineRestored++
                            }
                        }
                    } else {
                        [Environment]::SetEnvironmentVariable($_.Name, $_.Value, "Machine")
                        $machineRestored++
                    }
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
