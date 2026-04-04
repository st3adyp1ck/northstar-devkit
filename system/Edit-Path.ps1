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
.EXAMPLE
    .\Edit-Path.ps1
    .\Edit-Path.ps1 -Machine
    .\Edit-Path.ps1 -Show
    .\Edit-Path.ps1 -Add "C:\MyTools"
    .\Edit-Path.ps1 -Clean
#>
[CmdletBinding()]
param(
    [switch]$User,
    [switch]$Machine,
    [switch]$Show,
    [string]$Add,
    [string]$Remove,
    [switch]$Clean
)

Write-Host "`nNorthstar DevKit - Edit PATH`n" -ForegroundColor Cyan

# Determine target
$target = if ($Machine) { "Machine" } else { "User" }
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($Machine -and -not $isAdmin) {
    Write-Host "  ERROR: Editing system PATH requires Administrator privileges.`n" -ForegroundColor Red
    Write-Host "  Please run PowerShell as Administrator.`n" -ForegroundColor Yellow
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
        $exists = Test-Path $entry
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
    $newPath = Resolve-Path $Add -ErrorAction SilentlyContinue
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
    $seen = @{}
    $uniqueEntries = $pathEntries | Where-Object {
        $lower = $_.ToLower()
        if ($seen.ContainsKey($lower)) {
            $false
        } else {
            $seen[$lower] = $true
            $true
        }
    }
    
    # Filter non-existent paths
    $validEntries = $uniqueEntries | Where-Object { 
        $exists = Test-Path $_
        if (-not $exists) {
            Write-Host "    Removing missing: $_" -ForegroundColor Red
        }
        $exists
    }
    
    $removedCount = $pathEntries.Count - $validEntries.Count
    
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
        $exists = Test-Path $entry
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
            $resolved = Resolve-Path $newPath -ErrorAction SilentlyContinue
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
            if ([int]::TryParse($idx, [ref]$null) -and $idx -ge 0 -and $idx -lt $pathEntries.Count) {
                $newEntries = $pathEntries | Where-Object { $_ -ne $pathEntries[$idx] }
                $newPathString = $newEntries -join ';'
                [Environment]::SetEnvironmentVariable("PATH", $newPathString, $target)
                Write-Host "  DONE: Entry removed.`n" -ForegroundColor Green
            } else {
                Write-Host "  ERROR: Invalid index.`n" -ForegroundColor Red
            }
        }
        'C' {
            # Remove duplicates and non-existent
            $seen = @{}
            $uniqueEntries = $pathEntries | Where-Object {
                $lower = $_.ToLower()
                if ($seen.ContainsKey($lower)) { $false } else { $seen[$lower] = $true; $true }
            }
            $validEntries = $uniqueEntries | Where-Object { Test-Path $_ }
            $newPathString = $validEntries -join ';'
            [Environment]::SetEnvironmentVariable("PATH", $newPathString, $target)
            Write-Host "  DONE: PATH cleaned.`n" -ForegroundColor Green
        }
        'S' {
            $newTarget = if ($target -eq 'User') { 'Machine' } else { 'User' }
            if ($newTarget -eq 'Machine' -and -not $isAdmin) {
                Write-Host "  ERROR: Admin required for Machine PATH.`n" -ForegroundColor Red
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
