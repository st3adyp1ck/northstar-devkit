#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Edit Path - Northstar DevKit
.DESCRIPTION
    Interactive editor for the Windows PATH environment variable.
    Allows viewing, adding, removing, and reordering PATH entries
    with duplicate detection and validation.
    
    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER User
    Edit user PATH (default).
.PARAMETER Machine
    Edit system/machine PATH (requires admin).
.PARAMETER Show
    Just display PATH entries without editing.
.PARAMETER Add
    Add a new path entry.
.PARAMETER Remove
    Remove a path entry by index or pattern.
.PARAMETER Clean
    Remove duplicate and non-existent paths.
.PARAMETER Force
    Skip confirmation prompts before removing/cleaning PATH entries.
.EXAMPLE
    .\Edit-Path.ps1
    .\Edit-Path.ps1 -Machine
    .\Edit-Path.ps1 -Show
    .\Edit-Path.ps1 -Add "C:\MyTools"
    .\Edit-Path.ps1 -Clean
#>[CmdletBinding()]
param(
    [switch]$User,
    [switch]$Machine,
    [switch]$Show,
    [string]$Add,
    [string]$Remove,
    [switch]$Clean,
    [switch]$Force
)


$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

function Get-DevKitDedupedPathEntries {
    <#
        Normalizes and deduplicates a list of PATH entries.
        Normalization: trim whitespace, strip a single trailing backslash,
        and compare case-insensitively. Preserves the first-seen original
        (non-normalized) entry for each unique normalized key, in order.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Entries
    )

    $seen = @{}
    $result = @()
    foreach ($entry in $Entries) {
        if ($null -eq $entry) { continue }
        $normalized = $entry.Trim()
        if ($normalized.EndsWith('\')) {
            $normalized = $normalized.Substring(0, $normalized.Length - 1)
        }
        $key = $normalized.ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $result += $entry
        }
    }
    return $result
}

Write-DevKitHeader "Edit PATH"

# Determine target
$target = if ($Machine) { "Machine" } else { "User" }
$isAdmin = Test-DevKitAdmin

function Request-DevKitElevation {
    <#
        Relaunches this script elevated with the given extra arguments.
        Returns $true if the relaunch was kicked off successfully.
    #>
    param(
        [string[]]$ExtraArgs = @()
    )
    $psExe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
    $scriptArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath) + $ExtraArgs
    try {
        Start-Process -FilePath $psExe -ArgumentList $scriptArgs -Verb RunAs | Out-Null
        return $true
    } catch {
        Write-Host "  ERROR: Failed to relaunch elevated: $_`n" -ForegroundColor Red
        return $false
    }
}

if ($Machine -and -not $isAdmin) {
    Write-Host "  ERROR: Editing system PATH requires Administrator privileges.`n" -ForegroundColor Red

    $elevate = Read-Host "  Relaunch this script elevated now? (y/n)"
    if ($elevate -eq 'y') {
        $relaunchArgs = @('-Machine')
        if ($Show) { $relaunchArgs += '-Show' }
        if ($Add) { $relaunchArgs += @('-Add', $Add) }
        if ($Remove) { $relaunchArgs += @('-Remove', $Remove) }
        if ($Clean) { $relaunchArgs += '-Clean' }
        if ($Force) { $relaunchArgs += '-Force' }

        if (Request-DevKitElevation -ExtraArgs $relaunchArgs) {
            Write-Host "  Relaunched elevated. You can close this window.`n" -ForegroundColor Green
        }
    } else {
        Write-Host "  Please run PowerShell as Administrator.`n" -ForegroundColor Yellow
    }
    exit 1
}

# Get current PATH
$currentPath = [Environment]::GetEnvironmentVariable("PATH", $target)
$pathEntries = $currentPath -split ';' | Where-Object { $_ -ne '' }

# Show mode
if ($Show) {
    Write-Host "  Current $target PATH entries:" -ForegroundColor Yellow
    Write-Host "  Total entries: $($pathEntries.Count)" -ForegroundColor Gray
    Write-Host ""
    
    for ($i = 0; $i -lt $pathEntries.Count; $i++) {
        $entry = $pathEntries[$i]
        $exists = Test-Path -LiteralPath $entry
        $status = if ($exists) { " " } else { "×" }
        $color = if ($exists) { "White" } else { "Red" }

        Write-Host "  [$($i.ToString().PadLeft(2))] $status " -NoNewline
        Write-Host $entry -ForegroundColor $color
    }

    # Show duplicates
    $duplicates = $pathEntries | Group-Object | Where-Object { $_.Count -gt 1 }
    if ($duplicates) {
        Write-Host "`n  WARNING: Duplicate entries found:" -ForegroundColor Yellow
        $duplicates | ForEach-Object {
            Write-Host "    - $($_.Name) ($($_.Count) times)" -ForegroundColor Red
        }
    }
    
    Write-Host ""
    exit 0
}

# Add mode
if ($Add) {
    $newPath = Resolve-Path -LiteralPath $Add -ErrorAction SilentlyContinue
    if (-not $newPath) {
        Write-Host "  ERROR: Path does not exist: $Add`n" -ForegroundColor Red
        exit 1
    }
    
    $fullPath = $newPath.Path
    if ($pathEntries -contains $fullPath) {
        Write-Host "  WARNING: Path already exists in PATH.`n" -ForegroundColor Yellow
        exit 0
    }
    
    $newPathString = $currentPath + ";" + $fullPath
    [Environment]::SetEnvironmentVariable("PATH", $newPathString, $target)
    
    Write-Host "  DONE: Added to $target PATH" -ForegroundColor Green
    Write-Host "  $fullPath" -ForegroundColor Gray
    Write-Host "`n  Note: Restart your terminal to see changes.`n" -ForegroundColor Yellow
    exit 0
}

# Remove mode
if ($Remove) {
    $index = 0
    if ([int]::TryParse($Remove, [ref]$index)) {
        if ($index -lt 0 -or $index -ge $pathEntries.Count) {
            Write-Host "  ERROR: Invalid index. Use -Show to see valid indices.`n" -ForegroundColor Red
            exit 1
        }
        $removed = $pathEntries[$index]
        $newEntries = $pathEntries | Where-Object { $_ -ne $removed }
    } else {
        # Treat as pattern
        $pattern = $Remove
        $matching = $pathEntries | Where-Object { $_ -like "*$pattern*" }
        if (-not $matching) {
            Write-Host "  ERROR: No paths matching '$pattern' found.`n" -ForegroundColor Red
            exit 1
        }
        $newEntries = $pathEntries | Where-Object { $_ -notlike "*$pattern*" }
        $removed = $matching -join ', '
    }

    Write-Host "`n  This will remove from $target PATH:" -ForegroundColor Yellow
    Write-Host "    $removed" -ForegroundColor Gray

    if (-not $Force) {
        $confirmRemove = Read-Host "  Continue? (y/n)"
        if ($confirmRemove -ne 'y') {
            Write-Host "  Cancelled.`n" -ForegroundColor Gray
            exit 0
        }
    }

    $newPathString = $newEntries -join ';'
    [Environment]::SetEnvironmentVariable("PATH", $newPathString, $target)

    Write-Host "  DONE: Removed from $target PATH" -ForegroundColor Green
    Write-Host "  $removed" -ForegroundColor Gray
    Write-Host "`n  Note: Restart your terminal to see changes.`n" -ForegroundColor Yellow
    exit 0
}

# Clean mode
if ($Clean) {
    Write-Host "  Cleaning $target PATH..." -ForegroundColor Yellow
    
    # Remove duplicates while preserving order
    $uniqueEntries = Get-DevKitDedupedPathEntries -Entries $pathEntries

    # Filter non-existent paths
    $validEntries = $uniqueEntries | Where-Object {
        $exists = Test-Path -LiteralPath $_
        if (-not $exists) {
            Write-Host "    Removing missing: $_" -ForegroundColor Red
        }
        $exists
    }

    $removedCount = $pathEntries.Count - $validEntries.Count

    Write-Host "`n  Summary: entries before $($pathEntries.Count), after cleanup $($validEntries.Count) ($removedCount to remove)." -ForegroundColor Yellow

    if (-not $Force) {
        $confirmClean = Read-Host "  Apply cleanup to $target PATH? (y/n)"
        if ($confirmClean -ne 'y') {
            Write-Host "  Cancelled.`n" -ForegroundColor Gray
            exit 0
        }
    }

    $newPathString = $validEntries -join ';'
    [Environment]::SetEnvironmentVariable("PATH", $newPathString, $target)

    Write-Host "`n  DONE: Removed $removedCount invalid/duplicate entries." -ForegroundColor Green
    Write-Host "  Entries before: $($pathEntries.Count), after: $($validEntries.Count)" -ForegroundColor Gray
    Write-Host "`n  Note: Restart your terminal to see changes.`n" -ForegroundColor Yellow
    exit 0
}

# Interactive mode
Write-Host "  Editing $target PATH" -ForegroundColor Yellow
Write-Host "  Administrator: $(if($isAdmin){'Yes'}else{'No'})" -ForegroundColor Gray
Write-Host ""

while ($true) {
    # Refresh PATH
    $currentPath = [Environment]::GetEnvironmentVariable("PATH", $target)
    $pathEntries = $currentPath -split ';' | Where-Object { $_ -ne '' }
    
    Write-Host "  Current entries: $($pathEntries.Count)" -ForegroundColor Cyan
    Write-Host ""
    
    # Show entries
    for ($i = 0; $i -lt $pathEntries.Count; $i++) {
        $entry = $pathEntries[$i]
        $exists = Test-Path -LiteralPath $entry
        $status = if ($exists) { " " } else { "×" }
        $color = if ($exists) { "White" } else { "Red" }
        
        Write-Host "  [$($i.ToString().PadLeft(2))] $status " -NoNewline
        Write-Host $entry -ForegroundColor $color
    }
    
    Write-Host ""
    Write-Host "  Options:" -ForegroundColor Yellow
    Write-Host "    [A] Add new path" -ForegroundColor Cyan
    Write-Host "    [R] Remove by index" -ForegroundColor Cyan
    Write-Host "    [C] Clean duplicates/invalid" -ForegroundColor Cyan
    Write-Host "    [S] Switch target ($(if($target -eq 'User'){'Machine'}else{'User'}))" -ForegroundColor Cyan
    Write-Host "    [Q] Quit" -ForegroundColor Cyan
    Write-Host ""
    
    $choice = Read-Host "  Select option"
    
    switch ($choice.ToUpper()) {
        'A' {
            $newPath = Read-Host "  Enter path to add"
            $resolved = Resolve-Path -LiteralPath $newPath -ErrorAction SilentlyContinue
            if (-not $resolved) {
                Write-Host "  ERROR: Path does not exist.`n" -ForegroundColor Red
            } elseif ($pathEntries -contains $resolved.Path) {
                Write-Host "  WARNING: Path already exists.`n" -ForegroundColor Yellow
            } else {
                $newPathString = $currentPath + ";" + $resolved.Path
                [Environment]::SetEnvironmentVariable("PATH", $newPathString, $target)
                Write-Host "  DONE: Path added.`n" -ForegroundColor Green
            }
        }
        'R' {
            $idx = Read-Host "  Enter index to remove"
            [int]$parsedIdx = 0
            if ([int]::TryParse($idx, [ref]$parsedIdx) -and $parsedIdx -ge 0 -and $parsedIdx -lt $pathEntries.Count) {
                $entryToRemove = $pathEntries[$parsedIdx]
                Write-Host "`n  This will remove:" -ForegroundColor Yellow
                Write-Host "    [$parsedIdx] $entryToRemove" -ForegroundColor Gray

                $confirmRemove = if ($Force) { 'y' } else { Read-Host "  Remove this entry from $target PATH? (y/n)" }
                if ($confirmRemove -eq 'y') {
                    $newEntries = $pathEntries | Where-Object { $_ -ne $entryToRemove }
                    $newPathString = $newEntries -join ';'
                    [Environment]::SetEnvironmentVariable("PATH", $newPathString, $target)
                    Write-Host "  DONE: Entry removed.`n" -ForegroundColor Green
                } else {
                    Write-Host "  Cancelled.`n" -ForegroundColor Gray
                }
            } else {
                Write-Host "  ERROR: Invalid index.`n" -ForegroundColor Red
            }
        }
        'C' {
            # Remove duplicates and non-existent
            $uniqueEntries = Get-DevKitDedupedPathEntries -Entries $pathEntries
            $dupCount = $pathEntries.Count - $uniqueEntries.Count
            $missingEntries = @($uniqueEntries | Where-Object { -not (Test-Path -LiteralPath $_) })
            $validEntries = @($uniqueEntries | Where-Object { Test-Path -LiteralPath $_ })

            Write-Host "`n  This will clean the $target PATH:" -ForegroundColor Yellow
            Write-Host "    Duplicate entries to drop: $dupCount" -ForegroundColor Gray
            Write-Host "    Missing/invalid entries to drop: $($missingEntries.Count)" -ForegroundColor Gray
            if ($missingEntries.Count -gt 0) {
                $missingEntries | ForEach-Object { Write-Host "      - $_" -ForegroundColor Gray }
            }
            Write-Host "    Entries remaining after cleanup: $($validEntries.Count) (currently $($pathEntries.Count))" -ForegroundColor Gray

            $confirmClean = if ($Force) { 'y' } else { Read-Host "  Apply cleanup to $target PATH? (y/n)" }
            if ($confirmClean -eq 'y') {
                $newPathString = $validEntries -join ';'
                [Environment]::SetEnvironmentVariable("PATH", $newPathString, $target)
                Write-Host "  DONE: PATH cleaned.`n" -ForegroundColor Green
            } else {
                Write-Host "  Cancelled.`n" -ForegroundColor Gray
            }
        }
        'S' {
            $newTarget = if ($target -eq 'User') { 'Machine' } else { 'User' }
            if ($newTarget -eq 'Machine' -and -not $isAdmin) {
                Write-Host "  ERROR: Admin required for Machine PATH.`n" -ForegroundColor Red
                $elevate = Read-Host "  Relaunch this editor elevated now? (y/n)"
                if ($elevate -eq 'y') {
                    if (Request-DevKitElevation -ExtraArgs @('-Machine')) {
                        Write-Host "  Relaunched elevated. Exiting this session.`n" -ForegroundColor Green
                        exit 0
                    }
                }
            } else {
                $target = $newTarget
                Write-Host "  Switched to $target PATH.`n" -ForegroundColor Green
            }
        }
        'Q' {
            Write-Host "`n  Changes saved. Restart your terminal to see changes.`n" -ForegroundColor Yellow
            exit 0
        }
    }
}
