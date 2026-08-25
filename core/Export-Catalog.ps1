#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Writes core/catalog.json - a static snapshot of the tool catalog for
    build-time TS type generation / offline inspection. The live app never
    reads this file; it always calls the "catalog.get" RPC method so the
    catalog reflects the manifests on disk exactly. Re-run this after
    editing any tools/*/_module.psd1.
#>

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

Import-Module (Join-Path $PSScriptRoot 'DevKit.Core.psm1') -Force
. (Join-Path $PSScriptRoot 'RpcMethods.ps1')

$payload = Get-DevKitCatalogPayload -RootPath $repoRoot
$outPath = Join-Path $PSScriptRoot 'catalog.json'
$payload | ConvertTo-Json -Depth 12 | Set-Content -Path $outPath -Encoding UTF8

$moduleCount = @($payload.modules).Count
$itemCount = (@($payload.modules) | ForEach-Object { @($_.items).Count } | Measure-Object -Sum).Sum
Write-Host "Wrote $outPath - $moduleCount modules, $itemCount tools." -ForegroundColor Green
