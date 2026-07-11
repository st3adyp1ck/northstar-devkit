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

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

function Get-DevKitEnvValueInfo {
    <#
    .SYNOPSIS
        Parse the raw text following `KEY=` on a single .env line.
    .DESCRIPTION
        Strips a trailing, unquoted `# ...` or `// ...` comment from the
        value. The scan tracks quote state character-by-character, so a
        `#` (or `//`) that appears inside a quoted value is never
        mistaken for a comment marker.

        Also reports whether the value opens a quote ( ' or " ) that is
        not closed again on this same line - i.e. this is the first
        line of a multi-line quoted value (e.g. a PEM private key
        spanning several lines).
    .PARAMETER RawValue
        The text after the `=` on a KEY=VALUE line.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$RawValue
    )

    $openQuote = $null
    $cutIndex = -1

    for ($i = 0; $i -lt $RawValue.Length; $i++) {
        $ch = $RawValue[$i]

        if ($openQuote) {
            if ($ch -eq $openQuote) { $openQuote = $null }
            continue
        }

        if ($ch -eq '"' -or $ch -eq "'") {
            $openQuote = $ch
            continue
        }

        $isHash = ($ch -eq '#')
        $isSlashSlash = ($ch -eq '/' -and ($i + 1) -lt $RawValue.Length -and $RawValue[$i + 1] -eq '/')

        if (($isHash -or $isSlashSlash) -and $i -gt 0 -and [char]::IsWhiteSpace($RawValue[$i - 1])) {
            $cutIndex = $i
            break
        }
    }

    if ($cutIndex -ge 0) {
        $value = $RawValue.Substring(0, $cutIndex)
    } else {
        $value = $RawValue
    }

    return [PSCustomObject]@{
        Value       = $value.TrimEnd()
        IsMultiline = [bool]$openQuote
        OpenQuote   = if ($openQuote) { [string]$openQuote } else { $null }
    }
}

function Get-DevKitEnvVariables {
    <#
    .SYNOPSIS
        Parse .env template lines into an ordered list of variables.
    .DESCRIPTION
        Walks the template line by line. Consecutive `#` comment lines
        are accumulated (not overwritten) and attached as the Comment
        of the next variable below them.

        Multi-line quoted values (e.g. a PEM private key spanning
        several lines) are tracked as a single atomic block:
        StartIndex/EndIndex record the full span of raw lines so a
        caller can preserve or replace the whole block as one unit and
        never split it mid-value.
    .PARAMETER Lines
        The template content split into an array of lines.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Lines
    )

    $variables = @()
    $commentBuffer = @()
    $i = 0

    while ($i -lt $Lines.Count) {
        $line = $Lines[$i]

        if ($line -match '^\s*#\s*(.+)$') {
            $commentBuffer += $matches[1]
            $i++
            continue
        }

        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
            $varName = $matches[1]
            $rawValue = $matches[2]
            $valueInfo = Get-DevKitEnvValueInfo -RawValue $rawValue

            $startIndex = $i
            $endIndex = $i

            if ($valueInfo.IsMultiline) {
                $j = $i + 1
                while ($j -lt $Lines.Count) {
                    $endIndex = $j
                    if ($Lines[$j].Contains($valueInfo.OpenQuote)) {
                        break
                    }
                    $j++
                }
            }

            $variables += [PSCustomObject]@{
                Name        = $varName
                Default     = $valueInfo.Value
                Comment     = ($commentBuffer -join " ")
                IsMultiline = $valueInfo.IsMultiline
                StartIndex  = $startIndex
                EndIndex    = $endIndex
            }

            $commentBuffer = @()
            $i = $endIndex + 1
            continue
        }

        $i++
    }

    return $variables
}

# When this file is dot-sourced (e.g. by Pester tests that only need the
# parsing functions above), stop here - do not run the interactive
# script body or touch any files.
if ($MyInvocation.InvocationName -eq '.') {
    return
}

try {
    $targetPath = Resolve-DevKitDirectory -Path $Path
} catch {
    Write-DevKitHeader "Copy Env Template"
    Write-DevKitError $_
    exit 1
}

Write-DevKitHeader "Copy Env Template"

Invoke-DevKitInDirectory -Path $targetPath -ScriptBlock {
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
            Write-DevKitError "Template file not found: $Template"
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
        Write-DevKitError "No env template file found."
        Write-DevKitInfo "Searched for: $($templateFiles -join ', ')"
        Write-Host "  Create one or specify with -Template" -ForegroundColor Yellow
        exit 1
    }

    Write-DevKitInfo "Template: $templateFile"

    # Check for existing .env
    $envFile = ".env"
    if ((Test-Path $envFile) -and -not $Force -and -not $DryRun) {
        Write-Host "  WARNING: .env file already exists!" -ForegroundColor Yellow
        $overwrite = Read-Host "  Overwrite? (y/n)"
        if ($overwrite -ne 'y') {
            Write-DevKitInfo "Cancelled."
            exit 0
        }
    }

    # Parse template
    try {
        $templateContent = Get-Content $templateFile -Raw
    } catch {
        Write-DevKitError $_
        exit 1
    }

    $lines = $templateContent -split "`r?`n"

    # Extract variables (KEY=VALUE / KEY= lines), with accumulated
    # comments, comment-stripped defaults, and multi-line quoted values
    # tracked as a single atomic block.
    $variables = Get-DevKitEnvVariables -Lines $lines

    Write-DevKitInfo "Found $($variables.Count) variables"

    # Interactive mode
    $envContent = $templateContent

    if ($Interactive -and -not $DryRun) {
        Write-Host "`n  Interactive Mode - Enter values (press Enter to keep default):`n" -ForegroundColor Yellow

        $newLines = @()
        $i = 0

        while ($i -lt $lines.Count) {
            $varInfo = $variables | Where-Object { $_.StartIndex -eq $i } | Select-Object -First 1

            if (-not $varInfo) {
                $newLines += $lines[$i]
                $i++
                continue
            }

            Write-Host "  $($varInfo.Name)" -ForegroundColor Cyan -NoNewline
            if ($varInfo.Comment) {
                Write-Host " ($($varInfo.Comment))" -ForegroundColor DarkGray
            } else {
                Write-Host ""
            }

            if ($varInfo.IsMultiline) {
                # A multi-line quoted value (e.g. a PEM private key) must
                # be treated as one atomic unit: either preserved in full
                # or replaced in full, never split mid-value.
                Write-Host "  Default: <multi-line value - press Enter to keep as-is>" -ForegroundColor Gray
                $value = Read-Host "  Value"

                if ([string]::IsNullOrWhiteSpace($value)) {
                    for ($k = $varInfo.StartIndex; $k -le $varInfo.EndIndex; $k++) {
                        $newLines += $lines[$k]
                    }
                } else {
                    $newLines += "$($varInfo.Name)=$value"
                }
            } else {
                if ($varInfo.Default) {
                    Write-Host "  Default: $($varInfo.Default)" -ForegroundColor Gray
                }

                $value = Read-Host "  Value"
                if ([string]::IsNullOrWhiteSpace($value)) {
                    $value = $varInfo.Default
                }

                $newLines += "$($varInfo.Name)=$value"
            }

            $i = $varInfo.EndIndex + 1
        }

        $envContent = $newLines -join "`r`n"
    }

    # Dry run
    if ($DryRun) {
        Write-Host "`n  [DRY RUN] Would create .env with content:`n" -ForegroundColor Magenta
        Write-Host "  ---" -ForegroundColor Gray
        $allLines = $envContent -split "`r?`n"
        $previewLines = $allLines | Select-Object -First 30
        $previewLines | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
        if ($allLines.Count -gt 30) {
            $remaining = $allLines.Count - 30
            Write-Host "  ... ($remaining more lines)" -ForegroundColor Gray
        }
        Write-Host "  ---`n" -ForegroundColor Gray
        exit 0
    }

    # Write .env file without a UTF-8 BOM. Out-File -Encoding UTF8 adds a
    # BOM on Windows PowerShell 5.1 but not on PowerShell 7 - a BOM breaks
    # the first key for many .env parsers, so write the bytes explicitly
    # rather than relying on version-dependent Out-File behavior.
    try {
        $fullEnvPath = Join-Path $PWD.Path $envFile
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($fullEnvPath, $envContent, $utf8NoBom)
    } catch {
        Write-DevKitError $_
        exit 1
    }

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
}
