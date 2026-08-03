#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Builds the DevKit GUI image assets - Northstar DevKit
.DESCRIPTION
    Generates the derived brand assets for the desktop GUI from the master
    logo (gui/Assets/logo.png):

      - logo-256.png  256x256 downscale used by the in-app title bar/nav
      - logo.ico      multi-size icon (16..256, PNG-compressed entries) used
                      for the window icon, taskbar, and alt-tab

    The outputs are committed to the repo, so end users never run this - it
    only needs re-running when the master logo changes. Uses System.Drawing,
    which is in-box on Windows PowerShell 5.1; under pwsh 7 on Windows it
    loads from the shared desktop runtime.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Source
    Path to the master logo PNG. Defaults to gui/Assets/logo.png next to
    this script.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\gui\Build-Assets.ps1
#>
[CmdletBinding()]
param(
    [string]$Source = ""
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Source)) {
    $Source = Join-Path $PSScriptRoot "Assets\logo.png"
}

if (-not (Test-Path $Source)) {
    Write-Host "  ERROR: Source logo not found: $Source" -ForegroundColor Red
    exit 1
}

Add-Type -AssemblyName System.Drawing

$assetsDir = Split-Path -Parent $Source

function Resize-DevKitLogo {
    param(
        [Parameter(Mandatory = $true)][System.Drawing.Image]$Image,
        [Parameter(Mandatory = $true)][int]$Size
    )
    $bmp = New-Object System.Drawing.Bitmap $Size, $Size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.Clear([System.Drawing.Color]::Transparent)
        $g.DrawImage($Image, 0, 0, $Size, $Size)
    } finally {
        $g.Dispose()
    }
    return $bmp
}

$sourceImage = [System.Drawing.Image]::FromFile($Source)
try {
    Write-Host "  Source: $Source ($($sourceImage.Width)x$($sourceImage.Height))" -ForegroundColor Cyan

    # --- logo-256.png -----------------------------------------------------
    $png256Path = Join-Path $assetsDir "logo-256.png"
    $bmp256 = Resize-DevKitLogo -Image $sourceImage -Size 256
    try {
        $bmp256.Save($png256Path, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $bmp256.Dispose()
    }
    Write-Host "  DONE: $png256Path" -ForegroundColor Green

    # --- logo.ico (multi-size, PNG-compressed entries) ---------------------
    # ICO container written by hand: ICONDIR header + one ICONDIRENTRY per
    # size, with each image stored as a PNG payload (supported since Vista
    # and the standard for modern .ico files). 20 and 40 are the tray/
    # taskbar sizes Windows asks for at 125% and 250% display scaling - if
    # they are missing the shell scales a neighbor and the icon goes soft.
    $sizes = @(16, 20, 24, 32, 40, 48, 64, 128, 256)
    $pngPayloads = @()
    foreach ($size in $sizes) {
        $bmp = Resize-DevKitLogo -Image $sourceImage -Size $size
        try {
            $ms = New-Object System.IO.MemoryStream
            $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
            $pngPayloads += ,@{ Size = $size; Bytes = $ms.ToArray() }
            $ms.Dispose()
        } finally {
            $bmp.Dispose()
        }
    }

    $icoPath = Join-Path $assetsDir "logo.ico"
    $fs = [System.IO.File]::Create($icoPath)
    $writer = New-Object System.IO.BinaryWriter $fs
    try {
        # ICONDIR: reserved(2)=0, type(2)=1 (icon), count(2)
        $writer.Write([uint16]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]$pngPayloads.Count)

        $offset = 6 + (16 * $pngPayloads.Count)
        foreach ($entry in $pngPayloads) {
            # Width/height bytes: 0 means 256 in the ICO format.
            $dimension = if ($entry.Size -ge 256) { [byte]0 } else { [byte]$entry.Size }
            $writer.Write($dimension)          # width
            $writer.Write($dimension)          # height
            $writer.Write([byte]0)             # color count (0 = >=8bpp)
            $writer.Write([byte]0)             # reserved
            $writer.Write([uint16]1)           # color planes
            $writer.Write([uint16]32)          # bits per pixel
            $writer.Write([uint32]$entry.Bytes.Length)
            $writer.Write([uint32]$offset)
            $offset += $entry.Bytes.Length
        }
        foreach ($entry in $pngPayloads) {
            $writer.Write($entry.Bytes)
        }
    } finally {
        $writer.Dispose()
        $fs.Dispose()
    }
    Write-Host "  DONE: $icoPath ($($sizes -join ', ') px)" -ForegroundColor Green
} finally {
    $sourceImage.Dispose()
}
