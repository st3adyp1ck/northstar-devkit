#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Vite Preview Build - Northstar DevKit
.DESCRIPTION
    Build the Vite project and preview the production build locally.
    Clears previous build, creates fresh production build, and starts
    the preview server.
    
    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Path
    Path to Vite project. Defaults to current directory.
.PARAMETER Port
    Port for preview server. Default: 4173
.PARAMETER OutDir
    Output directory for build. Default: "dist"
.PARAMETER SkipBuild
    Skip build step (just preview existing build).
.PARAMETER Analyze
    Run bundle analysis after build (if @rollup/plugin-visualizer is installed).
.EXAMPLE
    .\Vite-PreviewBuild.ps1
    .\Vite-PreviewBuild.ps1 -Port 8080
    .\Vite-PreviewBuild.ps1 -Analyze
#>
[CmdletBinding()]
param(
    [string]$Path = ".",
    [int]$Port = 4173,
    [string]$OutDir = "dist",
    [switch]$SkipBuild,
    [switch]$Analyze
)

$targetPath = Resolve-Path $Path

Write-Host "`nNorthstar DevKit - Vite Preview Build`n" -ForegroundColor Cyan
Write-Host "  Path: $targetPath" -ForegroundColor Gray
Write-Host ""

Push-Location $targetPath

# Verify project
if (-not (Test-Path "package.json")) {
    Write-Host "  ERROR: No package.json found.`n" -ForegroundColor Red
    Pop-Location
    exit 1
}

# Build step
if (-not $SkipBuild) {
    Write-Host "  Cleaning previous build..." -ForegroundColor Yellow
    if (Test-Path $OutDir) {
        Remove-Item -Path $OutDir -Recurse -Force
        Write-Host "    Deleted: $OutDir" -ForegroundColor Green
    }
    
    # Clear Vite cache for clean build
    $cachePaths = @(".vite", "node_modules/.vite")
    foreach ($cachePath in $cachePaths) {
        if (Test-Path $cachePath) {
            Remove-Item -Path $cachePath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    
    Write-Host "`n  Building for production..." -ForegroundColor Yellow
    Write-Host "  This may take a moment...`n" -ForegroundColor Gray
    
    $buildOutput = npm run build 2>&1
    $buildExitCode = $LASTEXITCODE
    
    # Show build output with formatting
    $buildOutput | ForEach-Object {
        if ($_ -match "error|Error|ERR!") {
            Write-Host "  $_" -ForegroundColor Red
        } elseif ($_ -match "warning|Warning") {
            Write-Host "  $_" -ForegroundColor Yellow
        } elseif ($_ -match "success|Success|built|dist/") {
            Write-Host "  $_" -ForegroundColor Green
        } else {
            Write-Host "  $_" -ForegroundColor Gray
        }
    }
    
    if ($buildExitCode -ne 0) {
        Write-Host "`n  ERROR: Build failed with exit code $buildExitCode`n" -ForegroundColor Red
        Pop-Location
        exit 1
    }
    
    Write-Host "`n  DONE: Build completed successfully." -ForegroundColor Green
    
    # Show build stats
    if (Test-Path $OutDir) {
        $buildSize = (Get-ChildItem $OutDir -Recurse -File | Measure-Object -Property Length -Sum).Sum
        $buildSizeMB = [math]::Round($buildSize / 1MB, 2)
        $fileCount = (Get-ChildItem $OutDir -Recurse -File | Measure-Object).Count
        
        Write-Host "`n  Build Statistics:" -ForegroundColor Cyan
        Write-Host "    Output: $OutDir" -ForegroundColor Gray
        Write-Host "    Files:  $fileCount" -ForegroundColor Gray
        Write-Host "    Size:   $buildSizeMB MB" -ForegroundColor Gray
        
        # List main files
        Write-Host "`n  Main output files:" -ForegroundColor Cyan
        Get-ChildItem $OutDir | Select-Object -First 10 | ForEach-Object {
            $size = if ($_.PSIsContainer) { "<dir>" } else { "{0:N0} KB" -f ($_.Length / 1KB) }
            Write-Host "    $($_.Name.PadRight(30)) $size" -ForegroundColor Gray
        }
    }
} else {
    Write-Host "  Skipping build (using existing $OutDir)" -ForegroundColor Yellow
    if (-not (Test-Path $OutDir)) {
        Write-Host "`n  ERROR: No existing build found at $OutDir`n" -ForegroundColor Red
        Pop-Location
        exit 1
    }
}

# Bundle analysis
if ($Analyze) {
    Write-Host "`n  Analyzing bundle..." -ForegroundColor Yellow
    
    $statsFile = Join-Path $OutDir "stats.html"
    if (Test-Path $statsFile) {
        Write-Host "  Opening bundle analyzer..." -ForegroundColor Green
        Start-Process $statsFile
    } else {
        Write-Host "  WARNING: stats.html not found." -ForegroundColor Yellow
        Write-Host "  Install @rollup/plugin-visualizer for bundle analysis." -ForegroundColor Gray
    }
}

# Start preview
Write-Host "`n  ===================================" -ForegroundColor Cyan
Write-Host "  Starting preview server on port $Port..." -ForegroundColor Green
Write-Host "  Press Ctrl+C to stop" -ForegroundColor Gray
Write-Host "  ===================================`n" -ForegroundColor Cyan

$previewCommand = "npx vite preview --port $Port"
& cmd /c $previewCommand

Pop-Location
