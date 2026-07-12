#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Vite Preview Build - Northstar DevKit
.DESCRIPTION
    Build the Vite project and preview the production build locally.
    Backs up the previous build before rebuilding (auto-restored if the new
    build fails), creates a fresh production build, and starts the preview
    server. Auto-detects package manager (npm/pnpm/yarn/bun).

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Path
    Path to Vite project. Defaults to current directory.
.PARAMETER Port
    Port for preview server. Default: 4173
.PARAMETER OutDir
    Output directory for build. Default: "dist". Must resolve to a location
    inside the project directory - relative paths that escape it (e.g. "..")
    or absolute paths elsewhere on disk are rejected.
.PARAMETER SkipBuild
    Skip build step (just preview existing build).
.PARAMETER Analyze
    Run bundle analysis after build (if @rollup/plugin-visualizer is installed).
.PARAMETER Force
    Skip the confirmation prompt before replacing an existing build.
.EXAMPLE
    .\Vite-PreviewBuild.ps1
    .\Vite-PreviewBuild.ps1 -Port 8080
    .\Vite-PreviewBuild.ps1 -Analyze
    .\Vite-PreviewBuild.ps1 -Force
#>
[CmdletBinding()]
param(
    [string]$Path = ".",
    [int]$Port = 4173,
    [string]$OutDir = "dist",
    [switch]$SkipBuild,
    [switch]$Analyze,
    [switch]$Force
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

try {
    $targetPath = Resolve-DevKitDirectory -Path $Path
} catch {
    Write-DevKitHeader "Vite Preview Build"
    Write-DevKitError $_
    exit 1
}

Write-DevKitHeader "Vite Preview Build"
Write-DevKitInfo "Path: $targetPath"
Write-Host ""

# Resolve OutDir to an absolute path and make sure it can't escape the
# project directory (e.g. via ".." segments or an absolute path elsewhere
# on disk) before anything is ever renamed/deleted.
$outDirFull = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($targetPath, $OutDir))
$projectRoot = $targetPath.TrimEnd('\', '/')
$isOutDirInsideProject = $outDirFull.TrimEnd('\', '/').StartsWith(
    $projectRoot + [System.IO.Path]::DirectorySeparatorChar,
    [System.StringComparison]::OrdinalIgnoreCase)

if (-not $isOutDirInsideProject) {
    Write-DevKitError "OutDir '$OutDir' resolves outside the project directory ($outDirFull). Refusing to proceed."
    exit 1
}

try {
    Push-Location $targetPath

    # Verify project
    if (-not (Test-Path "package.json")) {
        Write-DevKitError "No package.json found."
        exit 1
    }

    # Verify this looks like a Vite project (same check as Vite-DevFresh.ps1)
    # so a build output directory that merely happens to also be named
    # "dist" (webpack, CRA, tsup, ...) doesn't get built/served as if it
    # were a Vite project.
    $packageJson = Get-Content "package.json" | ConvertFrom-Json
    $hasVite = ($packageJson.devDependencies.PSObject.Properties.Name -contains "vite") -or
               ($packageJson.dependencies.PSObject.Properties.Name -contains "vite")

    if (-not $hasVite) {
        Write-Host "  WARNING: Vite not found in package.json" -ForegroundColor Yellow
        $continue = Read-Host "  Continue anyway? (y/n)"
        if ($continue -ne 'y') {
            Write-DevKitInfo "Cancelled."
            exit 0
        }
    }

    $manager = Get-DevKitPackageManager -Path $targetPath
    Write-DevKitInfo "Package manager: $($manager.Command)"

    # Build step
    if (-not $SkipBuild) {
        $backupPath = $null

        if (Test-Path $outDirFull) {
            if (-not $Force) {
                $confirm = Read-Host "  Replace previous build in '$OutDir'? (y/n)"
                if ($confirm -ne 'y') {
                    Write-DevKitInfo "Cancelled."
                    exit 0
                }
            }

            # Back up the existing build instead of deleting it outright, so
            # a failed build never leaves the project without a working
            # production build. The backup is only removed once the new
            # build's exit code confirms success (further down).
            $backupPath = "$outDirFull.bak"
            if (Test-Path $backupPath) {
                Remove-Item -Path $backupPath -Recurse -Force -ErrorAction SilentlyContinue
            }
            Write-DevKitStep "Backing up previous build"
            Rename-Item -Path $outDirFull -NewName (Split-Path $backupPath -Leaf)
            Write-DevKitDone
        }

        # Clear Vite cache for clean build
        $cachePaths = @(".vite", "node_modules/.vite")
        foreach ($cachePath in $cachePaths) {
            if (Test-Path $cachePath) {
                Remove-Item -Path $cachePath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        Write-Host "`n  Building for production..." -ForegroundColor Cyan
        Write-Host "  This may take a moment...`n" -ForegroundColor Gray

        switch ($manager.Command) {
            "pnpm" { $buildArgs = @("build") }
            "yarn" { $buildArgs = @("build") }
            default { $buildArgs = @("run", "build") }
        }

        $buildOutput = & $manager.Command @buildArgs 2>&1
        $buildExitCode = $LASTEXITCODE

        # Show build output with formatting
        $buildOutput | ForEach-Object {
            if ($_ -match "\berror\b|ERR!") {
                Write-Host "  $_" -ForegroundColor Red
            } elseif ($_ -match "\b(warning)\b") {
                Write-Host "  $_" -ForegroundColor Yellow
            } elseif ($_ -match "\b(built|success)\b") {
                Write-Host "  $_" -ForegroundColor Green
            } else {
                Write-Host "  $_" -ForegroundColor Gray
            }
        }

        if ($buildExitCode -ne 0) {
            Write-Host "`n  ERROR: Build failed with exit code $buildExitCode`n" -ForegroundColor Red

            if ($backupPath -and (Test-Path $backupPath)) {
                Write-DevKitStep "Restoring previous build from backup"
                if (Test-Path $outDirFull) {
                    Remove-Item -Path $outDirFull -Recurse -Force -ErrorAction SilentlyContinue
                }
                Rename-Item -Path $backupPath -NewName (Split-Path $outDirFull -Leaf)
                Write-DevKitDone
            }

            exit 1
        }

        Write-Host "`n  DONE: Build completed successfully." -ForegroundColor Green

        # Build succeeded - the backup is no longer needed.
        if ($backupPath -and (Test-Path $backupPath)) {
            Remove-Item -Path $backupPath -Recurse -Force -ErrorAction SilentlyContinue
        }

        # Show build stats - one recursive scan, reused for both the
        # size/count totals and (non-recursively) the top-file listing.
        if (Test-Path $outDirFull) {
            $outFiles = Get-ChildItem $outDirFull -Recurse -File
            $stats = $outFiles | Measure-Object -Property Length -Sum
            $buildSizeMB = [math]::Round($stats.Sum / 1MB, 2)
            $fileCount = $stats.Count

            Write-Host "`n  Build Statistics:" -ForegroundColor Cyan
            Write-Host "    Output: $OutDir" -ForegroundColor Gray
            Write-Host "    Files:  $fileCount" -ForegroundColor Gray
            Write-Host "    Size:   $buildSizeMB MB" -ForegroundColor Gray

            # List main (top-level) output files
            Write-Host "`n  Main output files:" -ForegroundColor Cyan
            Get-ChildItem $outDirFull | Select-Object -First 10 | ForEach-Object {
                $size = if ($_.PSIsContainer) { "<dir>" } else { "{0:N0} KB" -f ($_.Length / 1KB) }
                Write-Host "    $($_.Name.PadRight(30)) $size" -ForegroundColor Gray
            }
        }
    } else {
        Write-Host "  Skipping build (using existing $OutDir)" -ForegroundColor Gray
        if (-not (Test-Path $outDirFull)) {
            Write-Host "`n  ERROR: No existing build found at $OutDir`n" -ForegroundColor Red
            exit 1
        }
    }

    # Bundle analysis
    if ($Analyze) {
        Write-Host "`n  Analyzing bundle..." -ForegroundColor Cyan

        $statsFile = Join-Path $outDirFull "stats.html"
        if (-not (Test-Path $statsFile)) {
            # @rollup/plugin-visualizer's output filename/location is
            # configurable per-project - best-effort: look for any
            # stats-like html file anywhere inside OutDir before giving up.
            $foundStats = Get-ChildItem -Path $outDirFull -Recurse -Filter "*stats*.html" -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($foundStats) { $statsFile = $foundStats.FullName }
        }

        if (Test-Path $statsFile) {
            Write-Host "  Opening bundle analyzer..." -ForegroundColor Green
            Start-Process $statsFile
        } else {
            Write-Host "  WARNING: No bundle analysis file found." -ForegroundColor Yellow
            Write-Host "  @rollup/plugin-visualizer's output filename/location is configurable -" -ForegroundColor Gray
            Write-Host "  check the visualizer() plugin options in vite.config for the actual path." -ForegroundColor Gray
        }
    }

    # Warn (but do not block) if the preview port is already occupied - Vite
    # will fall back to the next free port on its own.
    $portOwner = Get-DevKitProcessByPort -Port $Port
    if ($portOwner) {
        Write-Host "  WARNING: Port $Port is already in use by $($portOwner.Name) (PID $($portOwner.PID)). Vite will try the next available port." -ForegroundColor Yellow
    }

    # Start preview
    Write-Host "`n  ===================================" -ForegroundColor Cyan
    Write-Host "  Starting preview server on port $Port..." -ForegroundColor Green
    Write-Host "  Press Ctrl+C to stop" -ForegroundColor Gray
    Write-Host "  ===================================`n" -ForegroundColor Cyan

    switch ($manager.Command) {
        "pnpm" { & pnpm exec vite preview --port $Port }
        "yarn" { & yarn vite preview --port $Port }
        "bun"  { & bunx vite preview --port $Port }
        default { & npx vite preview --port $Port }
    }
} catch {
    Write-DevKitError $_
    exit 1
} finally {
    Pop-Location
}
