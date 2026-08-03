#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Edit Hosts File - Northstar DevKit
.DESCRIPTION
    View, add, remove, and comment-toggle entries in the Windows hosts
    file (%windir%\System32\drivers\etc\hosts).

    Run with no flags for an interactive menu ([A]dd / [R]emove /
    [T]oggle / [Q]uit), or use -Add / -Remove / -Toggle for scripted
    changes. -Show (or the default listing) is fully read-only.

    Every mutation requires Administrator privileges (the script offers
    to relaunch itself elevated), creates a timestamped backup under
    %LOCALAPPDATA%\NorthstarDevKit\hosts-backups\ before the first write
    of a session, confirms via the shared confirmation gate, and clears
    the DNS client cache afterward.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Show
    Just display hosts entries without editing (read-only, no admin needed).
.PARAMETER Add
    Add an entry, e.g. -Add "127.0.0.1 mysite.local www.mysite.local".
.PARAMETER Remove
    Remove an entry by its listing index or a hostname pattern.
.PARAMETER Toggle
    Comment/uncomment an entry by its listing index or a hostname pattern.
.PARAMETER Force
    Skip confirmation prompts before mutating the hosts file.
.EXAMPLE
    .\Edit-HostsFile.ps1
    .\Edit-HostsFile.ps1 -Show
    .\Edit-HostsFile.ps1 -Add "127.0.0.1 mysite.local"
    .\Edit-HostsFile.ps1 -Remove 3
    .\Edit-HostsFile.ps1 -Toggle "mysite"
#>
[CmdletBinding()]
param(
    [switch]$Show,
    [string]$Add,
    [string]$Remove,
    [string]$Toggle,
    [switch]$Force
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

$script:HostsPath = Join-Path $env:windir "System32\drivers\etc\hosts"
$script:HostsBackupCreated = $false

function Get-DevKitHostsEntries {
    <#
    .SYNOPSIS
        Parses hosts-file lines into entry objects.
    .DESCRIPTION
        An "entry" is a line whose first token looks like an IP address
        (IPv4 dotted quad, or anything containing ':' for IPv6) followed
        by at least one hostname. A leading '#' marks the entry as
        commented out. Pure comment lines and blank lines are skipped.
        LineIndex records the raw line position so callers can edit the
        original line array without disturbing anything else.
    .PARAMETER Lines
        The hosts file content split into an array of lines.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Lines
    )

    $entries = @()
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $work = $Lines[$i].Trim()
        $commented = $false
        if ($work.StartsWith('#')) {
            $commented = $true
            $work = $work.TrimStart('#').Trim()
        }
        # Inline trailing comments are not hostnames ("127.0.0.1 x # note").
        $hashIdx = $work.IndexOf('#')
        if ($hashIdx -ge 0) { $work = $work.Substring(0, $hashIdx).Trim() }
        if ([string]::IsNullOrWhiteSpace($work)) { continue }

        $tokens = @($work -split '\s+' | Where-Object { $_ -ne '' })
        if ($tokens.Count -lt 2) { continue }

        $ip = $tokens[0]
        $isIpv4 = $ip -match '^\d{1,3}(\.\d{1,3}){3}$'
        $isIpv6 = $ip.Contains(':')
        if (-not $isIpv4 -and -not $isIpv6) { continue }

        $entries += [PSCustomObject]@{
            LineIndex = $i
            Commented = $commented
            Ip        = $ip
            HostNames = ($tokens[1..($tokens.Count - 1)] -join ' ')
        }
    }
    return $entries
}

function ConvertTo-DevKitHostsEntry {
    <#
    .SYNOPSIS
        Parses "ip hostname [hostname...]" text (e.g. the -Add value) into
        an Ip/HostNames pair. Returns $null when the text is not a valid
        entry shape.
    #>
    param([Parameter(Mandatory = $true)][string]$Text)

    $tokens = @($Text.Trim() -split '\s+' | Where-Object { $_ -ne '' })
    if ($tokens.Count -lt 2) { return $null }

    $ip = $tokens[0]
    if ($ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -and -not $ip.Contains(':')) { return $null }

    return [PSCustomObject]@{
        Ip        = $ip
        HostNames = ($tokens[1..($tokens.Count - 1)] -join ' ')
    }
}

function Resolve-DevKitHostsEntry {
    <#
    .SYNOPSIS
        Resolves a -Remove/-Toggle selector (a listing index or a hostname
        pattern) to a single parsed entry. Returns $null when nothing
        matches; returns multiple entries when a pattern is ambiguous so
        the caller can refuse instead of guessing.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Entries,
        [Parameter(Mandatory = $true)]
        [string]$Selector
    )

    $index = 0
    if ([int]::TryParse($Selector, [ref]$index)) {
        if ($index -lt 0 -or $index -ge $Entries.Count) { return $null }
        return $Entries[$index]
    }

    $matching = @($Entries | Where-Object { $_.HostNames -like "*$Selector*" })
    if ($matching.Count -eq 0) { return $null }
    return $matching
}

function Show-DevKitHostsEntries {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Entries,
        # Real listing indices (into the full entries list) to print instead
        # of each item's position within $Entries - needed when $Entries is
        # a filtered subset, so the printed [i] still matches what -Remove/
        # -Toggle and the interactive menu expect. Must line up 1:1 with
        # $Entries when supplied.
        [AllowNull()]
        [int[]]$Indices
    )

    if ($Entries.Count -eq 0) {
        Write-DevKitInfo "No entries found in the hosts file."
        return
    }

    for ($i = 0; $i -lt $Entries.Count; $i++) {
        $entry = $Entries[$i]
        $displayIndex = if ($Indices -and $i -lt $Indices.Count) { $Indices[$i] } else { $i }
        $marker = if ($entry.Commented) { "#" } else { " " }
        $color = if ($entry.Commented) { "Gray" } else { "White" }
        Write-Host ("  [{0}] {1} {2,-15} {3}" -f $displayIndex.ToString().PadLeft(2), $marker, $entry.Ip, $entry.HostNames) -ForegroundColor $color
    }
}

function Backup-DevKitHostsFile {
    <#
    .SYNOPSIS
        Copies the hosts file to a timestamped backup under
        %LOCALAPPDATA%\NorthstarDevKit\hosts-backups\ - once per session,
        immediately before the first write.
    #>
    if ($script:HostsBackupCreated) { return }

    $backupDir = Join-Path $env:LOCALAPPDATA "NorthstarDevKit\hosts-backups"
    if (-not (Test-Path $backupDir)) {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    }
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $dest = Join-Path $backupDir "hosts-$stamp.bak"
    Copy-Item -LiteralPath $script:HostsPath -Destination $dest -Force
    $script:HostsBackupCreated = $true
    Write-DevKitInfo "Backup created: $dest"
}

function Save-DevKitHostsFile {
    <#
    .SYNOPSIS
        Writes hosts lines back as ASCII with no BOM (the encoding
        convention Windows hosts files have always used).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Lines
    )
    $ascii = New-Object System.Text.ASCIIEncoding
    [System.IO.File]::WriteAllLines($script:HostsPath, $Lines, $ascii)
}

function Invoke-DevKitHostsMutation {
    <#
    .SYNOPSIS
        Shared mutation pipeline: confirm (unless -Force), back up before
        the first write of the session, apply the change, then flush the
        DNS client cache. Returns $true when the change was applied.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][scriptblock]$Change,
        [switch]$Force
    )

    if (-not (Confirm-DevKitDestructiveAction -Action $Action -Force:$Force)) {
        Write-DevKitInfo "Cancelled - no changes made."
        return $false
    }

    Backup-DevKitHostsFile
    & $Change
    try {
        Clear-DnsClientCache -ErrorAction Stop
        Write-DevKitInfo "DNS client cache cleared."
    } catch {
        Write-DevKitInfo "Could not clear the DNS client cache: $_"
    }
    return $true
}

function Request-DevKitElevation {
    <#
        Relaunches this script elevated with the given extra arguments.
        Returns $true if the relaunch was kicked off successfully.
    #>
    param(
        [string[]]$ExtraArgs = @()
    )
    $psExe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
    $scriptArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath) + $ExtraArgs
    try {
        Start-Process -FilePath $psExe -ArgumentList $scriptArgs -Verb RunAs | Out-Null
        return $true
    } catch {
        Write-Host "  ERROR: Failed to relaunch elevated: $_`n" -ForegroundColor Red
        return $false
    }
}

Write-DevKitHeader "Edit Hosts File"
Write-DevKitInfo "File: $script:HostsPath"

if (-not (Test-Path $script:HostsPath)) {
    Write-DevKitError "Hosts file not found at '$script:HostsPath'."
    exit 1
}

$isAdmin = Test-DevKitAdmin

# Everything except -Show mutates (or offers to), so require admin up
# front with the same relaunch-elevated offer Edit-Path uses.
if (-not $Show -and -not $isAdmin) {
    Write-Host "  ERROR: Editing the hosts file requires Administrator privileges.`n" -ForegroundColor Red

    $elevate = Read-Host "  Relaunch this script elevated now? (y/n)"
    if ($elevate -eq 'y') {
        $relaunchArgs = @()
        if ($Add) { $relaunchArgs += @('-Add', $Add) }
        if ($Remove) { $relaunchArgs += @('-Remove', $Remove) }
        if ($Toggle) { $relaunchArgs += @('-Toggle', $Toggle) }
        if ($Force) { $relaunchArgs += '-Force' }

        if (Request-DevKitElevation -ExtraArgs $relaunchArgs) {
            Write-Host "  Relaunched elevated. You can close this window.`n" -ForegroundColor Green
        }
    } else {
        Write-Host "  Please run PowerShell as Administrator.`n" -ForegroundColor Yellow
    }
    exit 1
}

# Show mode (read-only)
if ($Show) {
    $lines = @([System.IO.File]::ReadAllLines($script:HostsPath))
    $entries = @(Get-DevKitHostsEntries -Lines $lines)
    Write-Host "  Hosts entries ($($entries.Count)):" -ForegroundColor Cyan
    Write-Host ""
    Show-DevKitHostsEntries -Entries $entries
    Write-Host ""
    exit 0
}

# Add mode
if ($Add) {
    $newEntry = ConvertTo-DevKitHostsEntry -Text $Add
    if (-not $newEntry) {
        Write-DevKitError "Invalid entry '$Add'. Expected: <ip> <hostname> [more hostnames], e.g. ""127.0.0.1 mysite.local""."
        exit 1
    }

    $lines = @([System.IO.File]::ReadAllLines($script:HostsPath))
    $entries = @(Get-DevKitHostsEntries -Lines $lines)

    $newHostTokens = @($newEntry.HostNames -split '\s+')
    $duplicate = $entries | Where-Object {
        -not $_.Commented -and
        $_.Ip -eq $newEntry.Ip -and
        (@($_.HostNames -split '\s+') | Where-Object { $newHostTokens -contains $_ })
    } | Select-Object -First 1
    if ($duplicate) {
        Write-Host "  WARNING: An active entry for $($duplicate.Ip) $($duplicate.HostNames) already exists.`n" -ForegroundColor Yellow
        exit 0
    }

    $newLine = "$($newEntry.Ip) $($newEntry.HostNames)"
    $applied = Invoke-DevKitHostsMutation -Action "add '$newLine' to the hosts file ($script:HostsPath)" -Force:$Force -Change {
        $updated = @($lines) + $newLine
        Save-DevKitHostsFile -Lines $updated
    }
    if ($applied) {
        Write-Host "  DONE: Added '$newLine'." -ForegroundColor Green
        Write-Host ""
    }
    exit 0
}

# Remove mode
if ($Remove) {
    $lines = @([System.IO.File]::ReadAllLines($script:HostsPath))
    $entries = @(Get-DevKitHostsEntries -Lines $lines)
    $resolved = Resolve-DevKitHostsEntry -Entries $entries -Selector $Remove

    if ($null -eq $resolved) {
        Write-DevKitError "No hosts entry matches '$Remove'. Use -Show to see valid indices."
        exit 1
    }
    if (@($resolved).Count -gt 1) {
        Write-DevKitError "'$Remove' matches multiple entries - re-run with a listing index instead:"
        $resolvedLineIndexes = @($resolved | ForEach-Object { $_.LineIndex })
        $realIndices = @(for ($i = 0; $i -lt $entries.Count; $i++) { if ($resolvedLineIndexes -contains $entries[$i].LineIndex) { $i } })
        Show-DevKitHostsEntries -Entries @($resolved) -Indices $realIndices
        Write-Host ""
        exit 1
    }

    $target = $resolved
    $applied = Invoke-DevKitHostsMutation -Action "remove hosts entry '$($target.Ip) $($target.HostNames)'" -Force:$Force -Change {
        $updated = @(for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($i -ne $target.LineIndex) { $lines[$i] }
        })
        Save-DevKitHostsFile -Lines $updated
    }
    if ($applied) {
        Write-Host "  DONE: Removed '$($target.Ip) $($target.HostNames)'." -ForegroundColor Green
        Write-Host ""
    }
    exit 0
}

# Toggle mode
if ($Toggle) {
    $lines = @([System.IO.File]::ReadAllLines($script:HostsPath))
    $entries = @(Get-DevKitHostsEntries -Lines $lines)
    $resolved = Resolve-DevKitHostsEntry -Entries $entries -Selector $Toggle

    if ($null -eq $resolved) {
        Write-DevKitError "No hosts entry matches '$Toggle'. Use -Show to see valid indices."
        exit 1
    }
    if (@($resolved).Count -gt 1) {
        Write-DevKitError "'$Toggle' matches multiple entries - re-run with a listing index instead:"
        $resolvedLineIndexes = @($resolved | ForEach-Object { $_.LineIndex })
        $realIndices = @(for ($i = 0; $i -lt $entries.Count; $i++) { if ($resolvedLineIndexes -contains $entries[$i].LineIndex) { $i } })
        Show-DevKitHostsEntries -Entries @($resolved) -Indices $realIndices
        Write-Host ""
        exit 1
    }

    $target = $resolved
    $verb = if ($target.Commented) { "uncomment (enable)" } else { "comment out (disable)" }
    $applied = Invoke-DevKitHostsMutation -Action "$verb hosts entry '$($target.Ip) $($target.HostNames)'" -Force:$Force -Change {
        $rawLine = $lines[$target.LineIndex]
        if ($target.Commented) {
            $newLine = $rawLine -replace '^(\s*)#\s?', '$1'
        } else {
            $newLine = '# ' + $rawLine
        }
        $updated = @(for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($i -eq $target.LineIndex) { $newLine } else { $lines[$i] }
        })
        Save-DevKitHostsFile -Lines $updated
    }
    if ($applied) {
        Write-Host "  DONE: Entry $verb." -ForegroundColor Green
        Write-Host ""
    }
    exit 0
}

# Interactive mode
Write-Host "  Administrator: $(if($isAdmin){'Yes'}else{'No'})" -ForegroundColor Gray
Write-Host ""

while ($true) {
    $lines = @([System.IO.File]::ReadAllLines($script:HostsPath))
    $entries = @(Get-DevKitHostsEntries -Lines $lines)

    Write-Host "  Current entries: $($entries.Count)" -ForegroundColor Cyan
    Write-Host ""
    Show-DevKitHostsEntries -Entries $entries

    Write-Host ""
    Write-Host "  Options:" -ForegroundColor Yellow
    Write-Host "    [A] Add new entry" -ForegroundColor Cyan
    Write-Host "    [R] Remove by index" -ForegroundColor Cyan
    Write-Host "    [T] Toggle comment by index" -ForegroundColor Cyan
    Write-Host "    [Q] Quit" -ForegroundColor Cyan
    Write-Host ""

    $choice = Read-Host "  Select option"
    if ($null -eq $choice) { Write-Host ""; break }   # stdin EOF (redirected input exhausted): leave cleanly
    $choice = $choice.Trim()

    switch ($choice.ToUpper()) {
        'A' {
            $inputText = Read-Host "  Enter IP and hostname(s) (e.g. 127.0.0.1 mysite.local)"
            if ($null -eq $inputText) { break }
            $newEntry = ConvertTo-DevKitHostsEntry -Text $inputText
            if (-not $newEntry) {
                Write-Host "  ERROR: Invalid entry - expected <ip> <hostname> [more hostnames].`n" -ForegroundColor Red
            } else {
                $newLine = "$($newEntry.Ip) $($newEntry.HostNames)"
                $applied = Invoke-DevKitHostsMutation -Action "add '$newLine' to the hosts file" -Force:$Force -Change {
                    $updated = @($lines) + $newLine
                    Save-DevKitHostsFile -Lines $updated
                }
                if ($applied) { Write-Host "  DONE: Entry added.`n" -ForegroundColor Green }
            }
        }
        'R' {
            $idx = Read-Host "  Enter index to remove"
            if ($null -eq $idx) { break }
            [int]$parsedIdx = 0
            if ([int]::TryParse($idx, [ref]$parsedIdx) -and $parsedIdx -ge 0 -and $parsedIdx -lt $entries.Count) {
                $target = $entries[$parsedIdx]
                $applied = Invoke-DevKitHostsMutation -Action "remove hosts entry '$($target.Ip) $($target.HostNames)'" -Force:$Force -Change {
                    $updated = @(for ($i = 0; $i -lt $lines.Count; $i++) {
                        if ($i -ne $target.LineIndex) { $lines[$i] }
                    })
                    Save-DevKitHostsFile -Lines $updated
                }
                if ($applied) { Write-Host "  DONE: Entry removed.`n" -ForegroundColor Green }
            } else {
                Write-Host "  ERROR: Invalid index.`n" -ForegroundColor Red
            }
        }
        'T' {
            $idx = Read-Host "  Enter index to toggle"
            if ($null -eq $idx) { break }
            [int]$parsedIdx = 0
            if ([int]::TryParse($idx, [ref]$parsedIdx) -and $parsedIdx -ge 0 -and $parsedIdx -lt $entries.Count) {
                $target = $entries[$parsedIdx]
                $verb = if ($target.Commented) { "uncomment (enable)" } else { "comment out (disable)" }
                $applied = Invoke-DevKitHostsMutation -Action "$verb hosts entry '$($target.Ip) $($target.HostNames)'" -Force:$Force -Change {
                    $rawLine = $lines[$target.LineIndex]
                    if ($target.Commented) {
                        $newLine = $rawLine -replace '^(\s*)#\s?', '$1'
                    } else {
                        $newLine = '# ' + $rawLine
                    }
                    $updated = @(for ($i = 0; $i -lt $lines.Count; $i++) {
                        if ($i -eq $target.LineIndex) { $newLine } else { $lines[$i] }
                    })
                    Save-DevKitHostsFile -Lines $updated
                }
                if ($applied) { Write-Host "  DONE: Entry $verb.`n" -ForegroundColor Green }
            } else {
                Write-Host "  ERROR: Invalid index.`n" -ForegroundColor Red
            }
        }
        'Q' {
            Write-Host "`n  Done.`n" -ForegroundColor Gray
            exit 0
        }
    }
}
