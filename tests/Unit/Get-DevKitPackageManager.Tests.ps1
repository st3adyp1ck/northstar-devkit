#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pester tests for Get-DevKitPackageManager (lib/DevKit-Common.ps1)
.DESCRIPTION
    Verifies package manager detection from lock files (bun.lockb,
    pnpm-lock.yaml, yarn.lock, package-lock.json) and, when no lock file is
    present, from package.json's corepack "packageManager" field.
#>

BeforeAll {
    $script:CommonModule = Join-Path (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "lib") "DevKit-Common.ps1"
    # lib/DevKit-Common.ps1 guards itself with a $global:DevKitCommonLoaded
    # "load once per process" flag. That's correct for the real app, but
    # when Pester runs multiple test files in one process, an earlier file
    # (e.g. one that dot-sources a script which itself dot-sources this lib)
    # can set the flag first, silently no-op'ing this dot-source and leaving
    # Get-DevKitPackageManager undefined in THIS file's scope. Reset the
    # flag so this file always gets a real, fresh load regardless of run order.
    $global:DevKitCommonLoaded = $false
    . $script:CommonModule

    $script:TestRoot = Join-Path $env:TEMP "devkit_pkgmgr_tests_$(Get-Random)"
    New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null
}

AfterAll {
    if ($script:TestRoot -and (Test-Path $script:TestRoot)) {
        Remove-Item -Path $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe "Get-DevKitPackageManager" {

    Context "Lock-file detection" {

        It "detects npm from package-lock.json" {
            $dir = Join-Path $script:TestRoot "npm-project"
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path $dir "package-lock.json") -Force | Out-Null

            $result = Get-DevKitPackageManager -Path $dir
            $result.Command | Should -Be "npm"
        }

        It "detects yarn from yarn.lock" {
            $dir = Join-Path $script:TestRoot "yarn-project"
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path $dir "yarn.lock") -Force | Out-Null

            $result = Get-DevKitPackageManager -Path $dir
            $result.Command | Should -Be "yarn"
        }

        It "detects pnpm from pnpm-lock.yaml" {
            $dir = Join-Path $script:TestRoot "pnpm-project"
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path $dir "pnpm-lock.yaml") -Force | Out-Null

            $result = Get-DevKitPackageManager -Path $dir
            $result.Command | Should -Be "pnpm"
        }

        It "detects bun from bun.lockb" {
            $dir = Join-Path $script:TestRoot "bun-project"
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path $dir "bun.lockb") -Force | Out-Null

            $result = Get-DevKitPackageManager -Path $dir
            $result.Command | Should -Be "bun"
        }

        It "prioritizes bun.lockb over other lock files when multiple are present" {
            $dir = Join-Path $script:TestRoot "multi-lock-project"
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path $dir "bun.lockb") -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path $dir "package-lock.json") -Force | Out-Null

            $result = Get-DevKitPackageManager -Path $dir
            $result.Command | Should -Be "bun"
        }
    }

    Context "packageManager field fallback (no lock file)" {

        It "detects pnpm from package.json's packageManager field when no lock file exists" {
            $dir = Join-Path $script:TestRoot "corepack-pnpm-project"
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $packageJson = @{ name = "corepack-pnpm-project"; version = "1.0.0"; packageManager = "pnpm@8.15.0" } | ConvertTo-Json
            Set-Content -Path (Join-Path $dir "package.json") -Value $packageJson

            $result = Get-DevKitPackageManager -Path $dir
            $result.Command | Should -Be "pnpm"
        }

        It "detects yarn from package.json's packageManager field when no lock file exists" {
            $dir = Join-Path $script:TestRoot "corepack-yarn-project"
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $packageJson = @{ name = "corepack-yarn-project"; version = "1.0.0"; packageManager = "yarn@4.1.0" } | ConvertTo-Json
            Set-Content -Path (Join-Path $dir "package.json") -Value $packageJson

            $result = Get-DevKitPackageManager -Path $dir
            $result.Command | Should -Be "yarn"
        }

        It "falls back to npm when package.json has no packageManager field and no lock file" {
            $dir = Join-Path $script:TestRoot "no-lock-no-field-project"
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $packageJson = @{ name = "no-lock-no-field-project"; version = "1.0.0" } | ConvertTo-Json
            Set-Content -Path (Join-Path $dir "package.json") -Value $packageJson

            $result = Get-DevKitPackageManager -Path $dir
            $result.Command | Should -Be "npm"
        }

        It "falls back to npm when there is no package.json and no lock file" {
            $dir = Join-Path $script:TestRoot "empty-project"
            New-Item -ItemType Directory -Path $dir -Force | Out-Null

            $result = Get-DevKitPackageManager -Path $dir
            $result.Command | Should -Be "npm"
        }
    }
}
