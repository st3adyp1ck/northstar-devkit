#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Code Here - Northstar DevKit
.DESCRIPTION
    Open VS Code (or Cursor) in the current directory or with
    a recent projects picker. Auto-detects available editors.
    
    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Path
    Directory to open. Default: current directory.
.PARAMETER Recent
    Show recent projects picker instead.
.PARAMETER Cursor
    Use Cursor IDE instead of VS Code.
.PARAMETER Wait
    Wait for editor to close before returning.
.EXAMPLE
    .\Code-Here.ps1
    .\Code-Here.ps1 -Recent
    .\Code-Here.ps1 -Path "C:\MyProject"
    .\Code-Here.ps1 -Cursor
#>[CmdletBinding()]
param(
    [string]$Path = ".",
    [switch]$Recent,
    [switch]$Cursor,
    [switch]$Wait
)


$CommonModule = Join-Path $PSScriptRoot ".." "lib" "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }


Write-Host "`nNorthstar DevKit - Code Here`n" -ForegroundColor Cyan

# Detect available editors
$vsCodePath = Get-Command code -ErrorAction SilentlyContinue
$cursorPath = Get-Command cursor -ErrorAction SilentlyContinue

if ($Cursor -and $cursorPath) {
    $editorName = "Cursor"
    $editorCmd = "cursor"
} elseif ($vsCodePath) {
    $editorName = "VS Code"
    $editorCmd = "code"
} elseif ($cursorPath) {
    $editorName = "Cursor"
    $editorCmd = "cursor"
} else {
    Write-Host "  ERROR: Neither VS Code nor Cursor found in PATH.`n" -ForegroundColor Red
    Write-Host "  Please install VS Code or Cursor and ensure it's in your PATH.`n" -ForegroundColor Yellow
    exit 1
}

Write-Host "  Editor: $editorName" -ForegroundColor Gray

# Recent projects mode
if ($Recent) {
    Write-Host "  Loading recent projects..." -ForegroundColor Yellow
    
    # Get recent folders from VS Code/Cursor storage
    $recentPaths = @()
    
    if ($editorCmd -eq "code") {
        $workspaceStorage = Join-Path $env:APPDATA "Code\User\workspaceStorage"
        if (Test-Path $workspaceStorage) {
            Get-ChildItem $workspaceStorage -Directory | ForEach-Object {
                $workspaceFile = Join-Path $_.FullName "workspace.json"
                if (Test-Path $workspaceFile) {
                    try {
                        $workspace = Get-Content $workspaceFile | ConvertFrom-Json
                        if ($workspace.folder) {
                            $folderPath = $workspace.folder -replace '^file:///', '' -replace '%3A', ':'
                            $folderPath = [System.Uri]::UnescapeDataString($folderPath)
                            if (Test-Path $folderPath) {
                                $recentPaths += $folderPath
                            }
                        }
                    } catch {}
                }
            }
        }
    }
    
    # Also check common project locations
    $commonPaths = @(
        (Join-Path $env:USERPROFILE "Projects"),
        (Join-Path $env:USERPROFILE "source"),
        (Join-Path $env:USERPROFILE "dev"),
        (Join-Path $env:USERPROFILE "workspace"),
        (Join-Path $env:USERPROFILE "Documents\Projects"),
        (Join-Path $env:USERPROFILE "Documents\GitHub")
    )
    
    foreach ($commonPath in $commonPaths) {
        if (Test-Path $commonPath) {
            Get-ChildItem $commonPath -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                if ($recentPaths -notcontains $_.FullName) {
                    $recentPaths += $_.FullName
                }
            }
        }
    }
    
    # Limit and display
    $recentPaths = $recentPaths | Select-Object -First 20
    
    if (-not $recentPaths) {
        Write-Host "  No recent projects found.`n" -ForegroundColor Yellow
        exit 0
    }
    
    Write-Host "  Recent Projects:`n" -ForegroundColor Yellow
    for ($i = 0; $i -lt $recentPaths.Count; $i++) {
        $name = Split-Path $recentPaths[$i] -Leaf
        Write-Host "  [$($i + 1)] $name" -ForegroundColor Cyan
        Write-Host "      $($recentPaths[$i])" -ForegroundColor DarkGray
    }
    
    Write-Host ""
    $choice = Read-Host "  Select project number (or press Enter to cancel)"
    
    if ($choice -match '^\d+$') {
        $index = [int]$choice - 1
        if ($index -ge 0 -and $index -lt $recentPaths.Count) {
            $Path = $recentPaths[$index]
        } else {
            Write-Host "  Invalid selection.`n" -ForegroundColor Red
            exit 1
        }
    } else {
        Write-Host "  Cancelled.`n" -ForegroundColor Gray
        exit 0
    }
}

# Resolve and validate path
if (-not (Test-Path $Path)) {
    Write-Host "  ERROR: Path not found: $Path`n" -ForegroundColor Red
    exit 1
}
$targetPath = (Resolve-Path $Path).Path

Write-Host "  Opening: $targetPath" -ForegroundColor Gray
Write-Host ""

# Open editor
$editorArgs = @($targetPath)
if ($Wait) { $editorArgs += "--wait" }

& $editorCmd @editorArgs

Write-Host "  Launched $editorName.`n" -ForegroundColor Green
