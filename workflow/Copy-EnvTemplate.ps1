#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Copy Env Template - Northstar DevKit
.DESCRIPTION
    Copy .env.example (or .env.template) to .env and optionally
    fill in values interactively. Supports common env file patterns.
    
    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Path
    Project directory. Default: current directory.
.PARAMETER Template
    Template file name. Default: auto-detect (.env.example, .env.template, etc.)
.PARAMETER Interactive
    Interactively prompt for each variable value.
.PARAMETER Force
    Overwrite existing .env file.
.PARAMETER DryRun
    Show what would be created without making changes.
.EXAMPLE
    .\Copy-EnvTemplate.ps1
    .\Copy-EnvTemplate.ps1 -Interactive
    .\Copy-EnvTemplate.ps1 -Force
    .\Copy-EnvTemplate.ps1 -Template ".env.local.example"
#>
[CmdletBinding()]
param(
    [string]$Path = ".",
    [string]$Template = "",
    [switch]$Interactive,
    [switch]$Force,
    [switch]$DryRun
)

Write-Host "`nNorthstar DevKit - Copy Env Template`n" -ForegroundColor Cyan

Push-Location $Path

# Look for template files if not specified
$templateFiles = @(
    ".env.example",
    ".env.template",
    ".env.sample",
    ".env.local.example",
    ".env.development.example",
    ".env.production.example",
    "env.example"
)

$templateFile = $null

if ($Template) {
    if (Test-Path $Template) {
        $templateFile = $Template
    } else {
        Write-Host "  ERROR: Template file not found: $Template`n" -ForegroundColor Red
        Pop-Location
        exit 1
    }
} else {
    foreach ($file in $templateFiles) {
        if (Test-Path $file) {
            $templateFile = $file
            break
        }
    }
}

if (-not $templateFile) {
    Write-Host "  ERROR: No env template file found.`n" -ForegroundColor Red
    Write-Host "  Searched for: $($templateFiles -join ', ')`n" -ForegroundColor Gray
    Write-Host "  Create one or specify with -Template`n" -ForegroundColor Yellow
    Pop-Location
    exit 1
}

Write-Host "  Template: $templateFile" -ForegroundColor Gray

# Check for existing .env
$envFile = ".env"
if ((Test-Path $envFile) -and -not $Force -and -not $DryRun) {
    Write-Host "  WARNING: .env file already exists!" -ForegroundColor Yellow
    $overwrite = Read-Host "  Overwrite? (y/n)"
    if ($overwrite -ne 'y') {
        Write-Host "  Cancelled.`n" -ForegroundColor Gray
        Pop-Location
        exit 0
    }
}

# Parse template
$templateContent = Get-Content $templateFile -Raw
$lines = $templateContent -split "`r?`n"

# Extract variables (lines with KEY=VALUE or KEY=)
$variables = @()
$comments = @{}
$currentComment = ""

foreach ($line in $lines) {
    if ($line -match '^\s*#\s*(.+)$') {
        $currentComment = $matches[1]
    } elseif ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
        $varName = $matches[1]
        $varDefault = $matches[2]
        
        $variables += [PSCustomObject]@{
            Name = $varName
            Default = $varDefault
            Comment = $currentComment
        }
        $currentComment = ""
    }
}

Write-Host "  Found $($variables.Count) variables" -ForegroundColor Gray

# Interactive mode
$envContent = $templateContent

if ($Interactive -and -not $DryRun) {
    Write-Host "`n  Interactive Mode - Enter values (press Enter to keep default):`n" -ForegroundColor Yellow
    
    $newLines = @()
    
    foreach ($line in $lines) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
            $varName = $matches[1]
            $varDefault = $matches[2]
            $varInfo = $variables | Where-Object { $_.Name -eq $varName } | Select-Object -First 1
            
            Write-Host "  $varName" -ForegroundColor Cyan -NoNewline
            if ($varInfo.Comment) {
                Write-Host " ($varInfo.Comment)" -ForegroundColor DarkGray
            } else {
                Write-Host ""
            }
            if ($varDefault) {
                Write-Host "  Default: $varDefault" -ForegroundColor Gray
            }
            
            $value = Read-Host "  Value"
            if ([string]::IsNullOrWhiteSpace($value)) {
                $value = $varDefault
            }
            
            $newLines += "$varName=$value"
        } else {
            $newLines += $line
        }
    }
    
    $envContent = $newLines -join "`r`n"
}

# Dry run
if ($DryRun) {
    Write-Host "`n  [DRY RUN] Would create .env with content:`n" -ForegroundColor Magenta
    Write-Host "  ---" -ForegroundColor Gray
    $previewLines = $envContent -split "`r?`n" | Select-Object -First 30
    $previewLines | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
    if (($envContent -split "`r?`n").Count -gt 30) {
        Write-Host "  ... ($(($envContent -split "`r?`n").Count - 30) more lines)" -ForegroundColor Gray
    }
    Write-Host "  ---`n" -ForegroundColor Gray
    Pop-Location
    exit 0
}

# Write .env file
$envContent | Out-File -FilePath $envFile -Encoding UTF8 -NoNewline

Write-Host "`n  ===================================" -ForegroundColor Cyan
Write-Host "  DONE: .env file created!" -ForegroundColor Green
Write-Host "  From: $templateFile" -ForegroundColor Gray
Write-Host "  To:   $envFile" -ForegroundColor Gray
Write-Host "  Variables: $($variables.Count)" -ForegroundColor Gray
Write-Host "  ===================================`n" -ForegroundColor Cyan

# Show warning about .env in git
if ($templateFile -eq ".env.example" -or $templateFile -eq ".env.template") {
    Write-Host "  REMINDER: Keep .env out of Git!" -ForegroundColor Yellow
    Write-Host "  Ensure .env is in your .gitignore file.`n" -ForegroundColor Gray
}

Pop-Location
