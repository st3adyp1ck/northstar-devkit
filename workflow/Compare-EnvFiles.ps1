#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Compare Env Files - Northstar DevKit
.DESCRIPTION
    Checks a project's .env against its env template (.env.example etc.)
    and reports configuration drift by KEY NAME ONLY - values are never
    printed, so the report is safe to read in a shared terminal.

    Reports three things: template keys missing from .env, keys present
    in .env but with an empty value, and keys that exist only in .env
    (informational - usually local overrides). Fully read-only.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Path
    Project directory. Default: current directory.
.PARAMETER Template
    Template file name. Default: auto-detect (.env.example, .env.template,
    .env.sample, .env.local.example, .env.development.example,
    .env.production.example, env.example - checked in that order).
.PARAMETER EnvFile
    The env file to check. Default: .env
.EXAMPLE
    .\Compare-EnvFiles.ps1
    .\Compare-EnvFiles.ps1 -Path "C:\my-project"
    .\Compare-EnvFiles.ps1 -Template ".env.production.example" -EnvFile ".env.production"
#>
[CmdletBinding()]
param(
    [string]$Path = ".",
    [string]$Template = "",
    [string]$EnvFile = ".env"
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

function Get-DevKitEnvKeyNames {
    <#
    .SYNOPSIS
        Extracts the variable KEY names from .env-style lines.
    .DESCRIPTION
        Matches `KEY=...` lines (optionally prefixed with `export ` and/or
        leading whitespace) and returns each unique key name in first-seen
        order. Comment lines (# ...), blank lines, and anything without a
        valid shell-style identifier before the '=' are ignored. Values
        are never captured - keys only, by design.
    .PARAMETER Lines
        The file content split into an array of lines.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Lines
    )

    $seen = @{}
    $keys = @()
    foreach ($line in $Lines) {
        if ($null -eq $line) { continue }
        if ($line -match '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=') {
            $name = $matches[1]
            if (-not $seen.ContainsKey($name)) {
                $seen[$name] = $true
                $keys += $name
            }
        }
    }
    return $keys
}

# When this file is dot-sourced (e.g. by Pester tests that only need
# Get-DevKitEnvKeyNames), stop here - do not run the script body or touch
# any files.
if ($MyInvocation.InvocationName -eq '.') {
    return
}

try {
    $targetPath = Resolve-DevKitDirectory -Path $Path
} catch {
    Write-DevKitHeader "Compare .env vs Template"
    Write-DevKitError $_
    exit 1
}

Write-DevKitHeader "Compare .env vs Template"
Write-DevKitInfo "Path: $targetPath"

Invoke-DevKitInDirectory -Path $targetPath -ScriptBlock {
    # Same ordered candidate list Copy-EnvTemplate.ps1 auto-detects from.
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
        exit 1
    }

    if (-not (Test-Path $EnvFile)) {
        Write-DevKitError "Env file not found: $EnvFile"
        Write-DevKitInfo "Copy one from the template first (Copy .env Template in the Workflow menu)."
        exit 1
    }

    Write-DevKitInfo "Template: $templateFile"
    Write-DevKitInfo "Env file: $EnvFile"
    Write-Host ""

    $templateLines = @(Get-Content $templateFile -ErrorAction Stop)
    $envLines = @(Get-Content $EnvFile -ErrorAction Stop)

    $templateKeys = @(Get-DevKitEnvKeyNames -Lines $templateLines)
    $envKeys = @(Get-DevKitEnvKeyNames -Lines $envLines)

    $missing = @($templateKeys | Where-Object { $envKeys -notcontains $_ })
    $extra = @($envKeys | Where-Object { $templateKeys -notcontains $_ })

    # Keys present in .env but with an empty value (quoted-empty counts too,
    # matching the widget's Compare-DevKitEnvKeys). Values are inspected
    # only to test emptiness - never stored beyond that flag, never printed.
    $empty = @()
    foreach ($line in $envLines) {
        if ($line -match '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$') {
            $keyName = $matches[1]
            $rawValue = $matches[2]
            # Strip a trailing "# comment" before testing emptiness (e.g.
            # 'API_KEY= # TODO: fill in' should count as empty), but leave a
            # '#' alone when the value is quoted - it may be literal content.
            if ($rawValue -notmatch '^\s*["'']') {
                $commentMatch = [regex]::Match($rawValue, '\s#.*$')
                if ($commentMatch.Success) {
                    $rawValue = $rawValue.Substring(0, $commentMatch.Index)
                }
            }
            $bareValue = $rawValue.Trim().Trim('"', "'")
            if ($bareValue -eq '') {
                $empty += $keyName
            }
        }
    }
    $empty = @($empty | Select-Object -Unique)

    if ($missing.Count -gt 0) {
        Write-Host "  MISSING from $EnvFile ($($missing.Count)):" -ForegroundColor Yellow
        foreach ($k in $missing) { Write-Host "    - $k" -ForegroundColor Yellow }
        Write-Host ""
    }

    if ($empty.Count -gt 0) {
        Write-Host "  Present but EMPTY in $EnvFile ($($empty.Count)):" -ForegroundColor Cyan
        foreach ($k in $empty) { Write-Host "    - $k" -ForegroundColor Cyan }
        Write-Host ""
    }

    if ($extra.Count -gt 0) {
        Write-Host "  Only in $EnvFile (not in template) ($($extra.Count)):" -ForegroundColor Gray
        foreach ($k in $extra) { Write-Host "    - $k" -ForegroundColor Gray }
        Write-Host ""
    }

    if ($missing.Count -eq 0 -and $empty.Count -eq 0 -and $extra.Count -eq 0) {
        Write-Host "  OK: $EnvFile matches $templateFile - all $($templateKeys.Count) template keys present and set, no extras." -ForegroundColor Green
        Write-Host ""
    } elseif ($missing.Count -eq 0 -and $empty.Count -eq 0) {
        Write-Host "  OK: all $($templateKeys.Count) template keys present and set ($($extra.Count) extra key(s) in $EnvFile)." -ForegroundColor Green
        Write-Host ""
    }

    Write-DevKitInfo "Values are never displayed - key names only."
}
