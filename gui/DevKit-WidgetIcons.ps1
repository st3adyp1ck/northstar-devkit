#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Built-in vector icon set for the companion widget - Northstar DevKit
.DESCRIPTION
    Dot-sourced ONCE by gui/DevKit-Widget.ps1 (UI side only - the background
    runspaces never load this file; they have no PresentationFramework).

    A Material-Icon-Theme-style catalog of small glyphs drawn as WPF path
    mini-language geometry on a 16x16 grid. Every icon is built ONCE per key
    (Get-DevKitIconDrawing), Frozen, and cached - tree rows and git-graph ref
    pills then share the frozen DrawingImage, so icons add zero per-expand /
    per-render geometry allocations (the same invariant the gauge arcs keep
    via Get-DevKitGaugeGeometry). Only the lightweight Image ELEMENT wrapping
    a frozen source is allocated per use, which is unavoidable and cheap.

    The pure name -> key + color mapping lives in gui/DevKit-WidgetCore.ps1
    (Get-DevKitFileIconInfo) so it stays Pester-testable; this file only owns
    the WPF drawings. Every Key the mapper can return has an entry in
    $script:DevKitIconShapes below.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
#>

# Prevent double-loading
if ($global:DevKitWidgetIconsLoaded) { return }
$global:DevKitWidgetIconsLoaded = $true

# key -> frozen DrawingImage
$script:DevKitIconCache = @{}

function ConvertTo-DevKitIconShade {
    # Lightens (positive $Amount) or darkens (negative) a '#RRGGBB' hex by
    # moving each channel that fraction toward 255 / 0. Build-time only.
    param(
        [Parameter(Mandatory = $true)][string]$Hex,
        [Parameter(Mandatory = $true)][double]$Amount
    )
    $c = [Windows.Media.ColorConverter]::ConvertFromString($Hex)
    $ch = {
        param([double]$v)
        $n = if ($Amount -ge 0) { $v + (255.0 - $v) * $Amount } else { $v * (1.0 + $Amount) }
        return [int][Math]::Min(255, [Math]::Max(0, [Math]::Round($n)))
    }
    return ('#{0:X2}{1:X2}{2:X2}' -f (& $ch $c.R), (& $ch $c.G), (& $ch $c.B))
}

# ---------------------------------------------------------------------------
# Shape catalog (16x16 grid, path mini-language).
# Each part: @{ D = <path data>; L = <0..1 lighten>; K = <0..1 darken> }.
# L/K shade the key's canonical color (from WidgetCore's DevKitIconColors);
# parts without either use the canonical color as-is.
# ---------------------------------------------------------------------------

# Shared building blocks: a file page with a folded corner, and the git
# branch glyph (used by both the 'git' file icon and the graph's 'git-branch'
# pill adornment - the color difference comes from each key's canonical hex).
$script:DevKitIconPage = 'M3.5,1.5 H9 L12.5,5 V14.5 H3.5 Z'
$script:DevKitIconFold = 'M9,1.5 L12.5,5 H9 Z'
$script:DevKitIconBranchParts = @(
    @{ D = 'M4.5,3.5 m-2,0 a2,2 0 1 0 4,0 a2,2 0 1 0 -4,0 Z' }          # top commit
    @{ D = 'M4.5,12.5 m-2,0 a2,2 0 1 0 4,0 a2,2 0 1 0 -4,0 Z' }         # bottom commit
    @{ D = 'M11.5,5.5 m-2,0 a2,2 0 1 0 4,0 a2,2 0 1 0 -4,0 Z' }         # side commit
    @{ D = 'M3.9,5.2 H5.1 V10.8 H3.9 Z' }                               # trunk
    @{ D = 'M9.6,6.3 C7.2,6.3 5.1,7.1 5.1,9.2 V10.8 H3.9 V9.2 C3.9,6.6 6.4,5.1 9.6,5.1 Z' }  # branch link
)

$script:DevKitIconShapes = @{
    'folder' = @(
        @{ D = 'M1.5,3 H6.5 L8.5,5 H14.5 A0.5,0.5 0 0 1 15,5.5 V12.5 A0.5,0.5 0 0 1 14.5,13 H1.5 A0.5,0.5 0 0 1 1,12.5 V3.5 A0.5,0.5 0 0 1 1.5,3 Z' }
    )
    'folder-open' = @(
        @{ D = 'M1.5,3 H6.5 L8.5,5 H14.5 V7 H4.4 L1.8,12.6 A0.5,0.5 0 0 1 1,12.5 V3.5 A0.5,0.5 0 0 1 1.5,3 Z'; K = 0.22 }
        @{ D = 'M4.2,7.6 H15.8 L13.2,13.4 H1.6 Z'; L = 0.18 }
    )
    'image' = @(
        @{ D = 'M1.5,3 H14.5 A0.5,0.5 0 0 1 15,3.5 V12.5 A0.5,0.5 0 0 1 14.5,13 H1.5 A0.5,0.5 0 0 1 1,12.5 V3.5 A0.5,0.5 0 0 1 1.5,3 Z' }
        @{ D = 'M5,5.8 m-1.3,0 a1.3,1.3 0 1 0 2.6,0 a1.3,1.3 0 1 0 -2.6,0 Z'; L = 0.55 }
        @{ D = 'M2,12 L6,7.4 L8.5,10.2 L10.8,8.1 L14,12 Z'; K = 0.35 }
    )
    'archive' = @(
        @{ D = 'M2.5,5 H13.5 V13.5 H2.5 Z' }
        @{ D = 'M1,1.5 H15 V5 H1 Z'; L = 0.25 }
        @{ D = 'M7.2,5 H8.8 V8.5 H7.2 Z'; K = 0.4 }
    )
    'sql' = @(
        @{ D = 'M8,2.5 C4.7,2.5 2,3.8 2,5.2 V10.8 C2,12.2 4.7,13.5 8,13.5 C11.3,13.5 14,12.2 14,10.8 V5.2 C14,3.8 11.3,2.5 8,2.5 Z' }
        @{ D = 'M2,10.8 C2,12.2 4.7,13.5 8,13.5 C11.3,13.5 14,12.2 14,10.8 V9.5 C14,10.9 11.3,12.2 8,12.2 C4.7,12.2 2,10.9 2,9.5 Z'; K = 0.35 }
    )
    'config' = @(
        @{ D = 'M2,4.4 H14 V5.6 H2 Z' }
        @{ D = 'M4.8,3.1 H7.8 V6.9 H4.8 Z' }
        @{ D = 'M2,7.4 H14 V8.6 H2 Z' }
        @{ D = 'M8.5,6.1 H11.5 V9.9 H8.5 Z' }
        @{ D = 'M2,10.4 H14 V11.6 H2 Z' }
        @{ D = 'M3.5,9.1 H6.5 V12.9 H3.5 Z' }
    )
    'env' = @(
        @{ D = 'M7.1,2 H8.9 V14 H7.1 Z' }
        @{ D = 'M3.3,5.3 L4.2,3.7 L12.7,10.7 L11.8,12.3 Z' }
        @{ D = 'M11.8,3.7 L12.7,5.3 L4.2,12.3 L3.3,10.7 Z' }
    )
    'docker' = @(
        @{ D = 'M1.6,10 H14.4 L13.2,13.6 H2.8 Z' }
        @{ D = 'M3.2,6.5 H6 V9.3 H3.2 Z'; L = 0.18 }
        @{ D = 'M6.6,6.5 H9.4 V9.3 H6.6 Z'; L = 0.18 }
        @{ D = 'M10,6.5 H12.8 V9.3 H10 Z'; L = 0.18 }
        @{ D = 'M6.6,3.2 H9.4 V6 H6.6 Z'; L = 0.18 }
    )
    'git' = $script:DevKitIconBranchParts
    'git-branch' = $script:DevKitIconBranchParts
    'git-tag' = @(
        @{ D = 'M8.6,1.5 H13.5 A1,1 0 0 1 14.5,2.5 V7.4 L7.9,14 A1,1 0 0 1 6.5,14 L2,9.5 A1,1 0 0 1 2,8.1 Z' }
        @{ D = 'M11.2,3.8 m-1.3,0 a1.3,1.3 0 1 0 2.6,0 a1.3,1.3 0 1 0 -2.6,0 Z'; K = 0.55 }
    )
    'git-head' = @(
        @{ D = 'M4,2.5 L12.5,8 L4,13.5 Z' }
    )
    'lock' = @(
        @{ D = 'M3.5,7 H12.5 A0.5,0.5 0 0 1 13,7.5 V13.5 A0.5,0.5 0 0 1 12.5,14 H3.5 A0.5,0.5 0 0 1 3,13.5 V7.5 A0.5,0.5 0 0 1 3.5,7 Z' }
        @{ D = 'M5.5,8 V5 A2.5,2.5 0 0 1 10.5,5 V8 H9.3 V5 A1.3,1.3 0 0 0 6.7,5 V8 Z'; K = 0.3 }
        @{ D = 'M8,10.2 m-1.1,0 a1.1,1.1 0 1 0 2.2,0 a1.1,1.1 0 1 0 -2.2,0 Z'; K = 0.45 }
    )
    'bat' = @(
        @{ D = 'M2,3 H14 V13 H2 Z' }
        @{ D = 'M2,3 H14 V5 H2 Z'; K = 0.4 }
        @{ D = 'M4,6.5 L5.6,8 L4,9.5 L4.9,10.2 L7.1,8 L4.9,5.8 Z'; K = 0.55 }
        @{ D = 'M7.6,9.3 H10.2 V10.1 H7.6 Z'; K = 0.55 }
    )
    'exe' = @(
        @{ D = 'M2,3.5 H14 A0.5,0.5 0 0 1 14.5,4 V12 A0.5,0.5 0 0 1 14,12.5 H2 A0.5,0.5 0 0 1 1.5,12 V4 A0.5,0.5 0 0 1 2,3.5 Z' }
        @{ D = 'M1.5,4 A0.5,0.5 0 0 1 2,3.5 H14 A0.5,0.5 0 0 1 14.5,4 V5.8 H1.5 Z'; K = 0.4 }
        @{ D = 'M4,7 L5.6,8.5 L4,10 L4.9,10.7 L7.1,8.5 L4.9,6.3 Z'; K = 0.55 }
    )
    'txt' = @(
        @{ D = $script:DevKitIconPage }
        @{ D = $script:DevKitIconFold; L = 0.35 }
        @{ D = 'M5.2,6.5 H10.8 V7.4 H5.2 Z'; K = 0.45 }
        @{ D = 'M5.2,8.7 H10.8 V9.6 H5.2 Z'; K = 0.45 }
        @{ D = 'M5.2,10.9 H8.8 V11.8 H5.2 Z'; K = 0.45 }
    )
    'html' = @(
        @{ D = $script:DevKitIconPage }
        @{ D = $script:DevKitIconFold; L = 0.35 }
        @{ D = 'M5.6,6.2 L4.2,8 L5.6,9.8 L4.8,10.5 L3.2,8 L4.8,5.5 Z'; K = 0.5 }
        @{ D = 'M10.4,6.2 L11.8,8 L10.4,9.8 L11.2,10.5 L12.8,8 L11.2,5.5 Z'; K = 0.5 }
    )
    'xml' = @(
        @{ D = $script:DevKitIconPage }
        @{ D = $script:DevKitIconFold; L = 0.35 }
        @{ D = 'M5.6,6.2 L4.2,8 L5.6,9.8 L4.8,10.5 L3.2,8 L4.8,5.5 Z'; K = 0.5 }
        @{ D = 'M10.4,6.2 L11.8,8 L10.4,9.8 L11.2,10.5 L12.8,8 L11.2,5.5 Z'; K = 0.5 }
    )
    'ps1' = @(
        @{ D = $script:DevKitIconPage }
        @{ D = $script:DevKitIconFold; L = 0.35 }
        @{ D = 'M5,6.2 L6.4,8 L5,9.8 L5.8,10.5 L7.8,8 L5.8,5.5 Z'; K = 0.5 }
        @{ D = 'M8.4,9.7 H11 V10.5 H8.4 Z'; K = 0.5 }
    )
    'vue' = @(
        @{ D = $script:DevKitIconPage }
        @{ D = $script:DevKitIconFold; L = 0.35 }
        @{ D = 'M4.6,5.6 L8,11.2 L11.4,5.6 H10.1 L8,8.7 L5.9,5.6 Z'; K = 0.45 }
    )
}

# Every file type not listed above renders as the colored page + folded
# corner - type recognition comes from the Material-palette color.
foreach ($pageKey in @('file', 'js', 'jsx', 'ts', 'tsx', 'json', 'md', 'css', 'scss',
        'svelte', 'py', 'cs', 'c', 'cpp', 'java', 'go', 'rs', 'php', 'rb',
        'yml', 'toml', 'pdf')) {
    if (-not $script:DevKitIconShapes.ContainsKey($pageKey)) {
        $script:DevKitIconShapes[$pageKey] = @(
            @{ D = $script:DevKitIconPage }
            @{ D = $script:DevKitIconFold; L = 0.35 }
        )
    }
}

function Get-DevKitIconDrawing {
    <#
    .SYNOPSIS
        Returns the FROZEN, CACHED DrawingImage for an icon key, building it
        on first use. Unknown keys fall back to 'file'.
    .DESCRIPTION
        The returned DrawingImage (and every geometry/brush inside it) is
        frozen, so any number of Image elements can share it as their Source
        with zero further geometry allocations. Keys come from
        Get-DevKitFileIconInfo (DevKit-WidgetCore.ps1) plus the git
        adornments 'git-branch'/'git-tag'/'git-head'.
    #>
    param([Parameter(Mandatory = $true)][string]$Key)

    $useKey = $Key
    if (-not $script:DevKitIconShapes.ContainsKey($useKey)) { $useKey = 'file' }
    $cached = $script:DevKitIconCache[$useKey]
    if ($null -ne $cached) { return $cached }

    $baseColor = $script:DevKitIconColors[$useKey]
    if (-not $baseColor) { $baseColor = '#8A93A6' }

    $group = New-Object Windows.Media.DrawingGroup
    foreach ($part in $script:DevKitIconShapes[$useKey]) {
        $hex = $baseColor
        if ($part.ContainsKey('L')) { $hex = ConvertTo-DevKitIconShade -Hex $hex -Amount ([double]$part['L']) }
        if ($part.ContainsKey('K')) { $hex = ConvertTo-DevKitIconShade -Hex $hex -Amount (-[double]$part['K']) }
        $brush = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($hex))
        $brush.Freeze()
        $geometry = [Windows.Media.Geometry]::Parse([string]$part['D'])
        $geometry.Freeze()
        $drawing = New-Object Windows.Media.GeometryDrawing ($brush, $null, $geometry)
        $drawing.Freeze()
        $group.Children.Add($drawing) | Out-Null
    }
    $group.Freeze()
    $image = New-Object Windows.Media.DrawingImage ($group)
    $image.Freeze()
    $script:DevKitIconCache[$useKey] = $image
    return $image
}

function New-DevKitIconImage {
    <#
    .SYNOPSIS
        A lightweight Image element displaying key's frozen DrawingImage at
        $Size px. The ELEMENT is per-use (WPF elements cannot be shared), the
        geometry behind it is the shared frozen instance.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [double]$Size = 14
    )
    $img = New-Object Windows.Controls.Image
    $img.Source = Get-DevKitIconDrawing -Key $Key
    $img.Width = $Size
    $img.Height = $Size
    $img.Stretch = [Windows.Media.Stretch]::Uniform
    $img.VerticalAlignment = [Windows.VerticalAlignment]::Center
    return $img
}
