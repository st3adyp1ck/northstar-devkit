#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Convert Dev Text - Northstar DevKit
.DESCRIPTION
    The "google-this" converter box for everyday dev chores, with nothing
    leaving your machine:

      - Base64 encode / decode
      - URL encode / decode
      - Unix timestamp (seconds or milliseconds) to local time
      - Current time to Unix timestamp
      - New GUID
      - SHA-256 hash of a string
      - JWT header/payload decode (base64url only - the signature is
        NEVER verified, so never trust decoded content for auth)

    Run with no -Mode for an interactive picker, or pass -Mode (and
    -Input where the mode needs one) for scripted use. Pure .NET, fully
    read-only - the only side effect is copying the result to the
    clipboard, and only when -Clipboard is passed.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Mode
    One of: b64-encode, b64-decode, url-encode, url-decode, ts-to-date,
    now-to-ts, guid, sha256, jwt-decode. Empty shows the interactive picker.
.PARAMETER Text
    The input text for modes that need one (all except now-to-ts and
    guid). Also bindable as -Input (alias) - note the value must go to a
    parameter alias rather than a literal $Input parameter, because
    PowerShell's automatic $input variable silently swallows script-level
    -Input binding.
.PARAMETER Clipboard
    Copy the result to the clipboard.
.EXAMPLE
    .\Convert-DevText.ps1
    .\Convert-DevText.ps1 -Mode b64-encode -Input "hello world"
    .\Convert-DevText.ps1 -Mode ts-to-date -Input "1700000000000" -Clipboard
    .\Convert-DevText.ps1 -Mode jwt-decode -Input "<token>"
#>
[CmdletBinding()]
param(
    [string]$Mode = "",
    [Alias("Input")]
    [string]$Text = "",
    [switch]$Clipboard
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

function ConvertTo-DevKitBase64 {
    <# Encodes UTF-8 text as a Base64 string. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Text))
}

function ConvertFrom-DevKitBase64 {
    <# Decodes a Base64 string back to UTF-8 text. Throws on malformed input. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Base64)
    return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Base64))
}

function ConvertTo-DevKitUrlEncoded {
    <# Percent-encodes text for safe use inside a URL (query values etc.). #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    return [uri]::EscapeDataString($Text)
}

function ConvertFrom-DevKitUrlEncoded {
    <# Decodes a percent-encoded URL string back to plain text. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    return [uri]::UnescapeDataString($Text)
}

function ConvertFrom-DevKitUnixTime {
    <#
    .SYNOPSIS
        Converts a Unix timestamp to local time.
    .DESCRIPTION
        Heuristic: values with an absolute magnitude of 1e12 or greater are
        treated as milliseconds, anything smaller as seconds. (1e12 seconds
        is the year 33658, while 1e12 ms is 2001-09-09, so the two ranges
        never collide for any realistic timestamp.)
    .OUTPUTS
        [datetime] in local time.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][long]$Timestamp)

    if ([math]::Abs($Timestamp) -ge 1000000000000) {
        return [DateTimeOffset]::FromUnixTimeMilliseconds($Timestamp).LocalDateTime
    }
    return [DateTimeOffset]::FromUnixTimeSeconds($Timestamp).LocalDateTime
}

function Get-DevKitCurrentUnixTime {
    <# Returns the current time as both Unix seconds and milliseconds. #>
    [CmdletBinding()]
    param()

    $now = [DateTimeOffset]::Now
    return [PSCustomObject]@{
        Seconds      = $now.ToUnixTimeSeconds()
        Milliseconds = $now.ToUnixTimeMilliseconds()
    }
}

function New-DevKitGuid {
    <# Returns a new random GUID in the standard dashed lowercase form. #>
    [CmdletBinding()]
    param()
    return [Guid]::NewGuid().ToString()
}

function Get-DevKitSha256Hash {
    <# Returns the lowercase hex SHA-256 digest of a string's UTF-8 bytes. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $sha.ComputeHash($bytes)
        return ($hash | ForEach-Object { $_.ToString("x2") }) -join ""
    } finally {
        $sha.Dispose()
    }
}

function ConvertFrom-DevKitJwt {
    <#
    .SYNOPSIS
        Decodes a JWT's header and payload WITHOUT verifying the signature.
    .DESCRIPTION
        Splits the token on '.', base64url-decodes the first two segments
        (padding restored before [Convert]::FromBase64String), and parses
        each as JSON. The signature segment is ignored entirely - this is a
        debugging aid, never an authentication check.
    .OUTPUTS
        PSCustomObject with .Header and .Payload.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Token)

    $parts = $Token.Trim().Split('.')
    if ($parts.Count -lt 2) {
        throw "Not a JWT: expected base64url segments separated by '.'."
    }

    $decodeSegment = {
        param([string]$Segment)
        $b64 = $Segment.Replace('-', '+').Replace('_', '/')
        switch ($b64.Length % 4) {
            0 { }
            2 { $b64 += "==" }
            3 { $b64 += "=" }
            default { throw "Invalid base64url segment (bad length)." }
        }
        return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
    }

    $headerJson = & $decodeSegment $parts[0]
    $payloadJson = & $decodeSegment $parts[1]

    return [PSCustomObject]@{
        Header  = ($headerJson | ConvertFrom-Json)
        Payload = ($payloadJson | ConvertFrom-Json)
    }
}

# When this file is dot-sourced (e.g. by Pester tests that only need the
# conversion functions above), stop here - do not run the interactive
# script body.
if ($MyInvocation.InvocationName -eq '.') {
    return
}

$modes = @(
    @{ Mode = 'b64-encode';  Label = 'Base64 encode';                                NeedsInput = $true }
    @{ Mode = 'b64-decode';  Label = 'Base64 decode';                                NeedsInput = $true }
    @{ Mode = 'url-encode';  Label = 'URL encode';                                   NeedsInput = $true }
    @{ Mode = 'url-decode';  Label = 'URL decode';                                   NeedsInput = $true }
    @{ Mode = 'ts-to-date';  Label = 'Unix timestamp (s or ms) -> local time';       NeedsInput = $true }
    @{ Mode = 'now-to-ts';   Label = 'Current time -> Unix timestamp';               NeedsInput = $false }
    @{ Mode = 'guid';        Label = 'New GUID';                                     NeedsInput = $false }
    @{ Mode = 'sha256';      Label = 'SHA-256 hash of a string';                     NeedsInput = $true }
    @{ Mode = 'jwt-decode';  Label = 'Decode a JWT (signature NOT verified)';        NeedsInput = $true }
)

Write-DevKitHeader "Dev Text Converter"

$selected = $null
if ([string]::IsNullOrWhiteSpace($Mode)) {
    $entries = @()
    for ($i = 0; $i -lt $modes.Count; $i++) {
        $entries += @{ Key = [string]($i + 1); Label = $modes[$i].Label }
    }
    $entries += @{ Key = '0'; Label = 'Cancel' }

    $choice = (Show-DevKitInteractiveMenu -Entries $entries -PromptLabel 'Select a conversion').Trim()
    if ($choice -eq '0' -or [string]::IsNullOrWhiteSpace($choice)) {
        Write-DevKitInfo "Cancelled."
        exit 0
    }
    if (-not ($choice -match '^\d+$') -or [int]$choice -lt 1 -or [int]$choice -gt $modes.Count) {
        Write-DevKitError "Invalid selection: $choice"
        exit 1
    }
    $selected = $modes[[int]$choice - 1]
} else {
    $selected = $modes | Where-Object { $_.Mode -eq $Mode } | Select-Object -First 1
    if (-not $selected) {
        Write-DevKitError "Unknown mode '$Mode'."
        Write-DevKitInfo "Valid modes: $($modes.Mode -join ', ')"
        exit 1
    }
}

Write-DevKitInfo "Mode: $($selected.Label)"

$inputText = $Text
$inputWasGiven = $PSBoundParameters.ContainsKey('Text')
if ($selected.NeedsInput -and -not $inputWasGiven) {
    # Guarded like the maintenance tools' apply prompts: on redirected
    # input a Read-Host would block forever on input that never arrives,
    # so fail cleanly instead.
    if ([Console]::IsInputRedirected) {
        Write-DevKitError "Mode '$($selected.Mode)' needs input - pass -Input `"<text>`"."
        exit 1
    }
    $inputText = Read-Host "  Enter the input text"
    if ([string]::IsNullOrEmpty($inputText)) {
        Write-DevKitError "No input provided."
        exit 1
    }
}

$resultLines = @()
try {
    switch ($selected.Mode) {
        'b64-encode' { $resultLines += ConvertTo-DevKitBase64 -Text $inputText }
        'b64-decode' { $resultLines += ConvertFrom-DevKitBase64 -Base64 $inputText }
        'url-encode' { $resultLines += ConvertTo-DevKitUrlEncoded -Text $inputText }
        'url-decode' { $resultLines += ConvertFrom-DevKitUrlEncoded -Text $inputText }
        'ts-to-date' {
            $timestamp = 0
            if (-not [long]::TryParse($inputText.Trim(), [ref]$timestamp)) {
                throw "'$inputText' is not a valid Unix timestamp (whole seconds or milliseconds)."
            }
            $kind = if ([math]::Abs($timestamp) -ge 1000000000000) { "milliseconds" } else { "seconds" }
            $local = ConvertFrom-DevKitUnixTime -Timestamp $timestamp
            $resultLines += "$($local.ToString('yyyy-MM-dd HH:mm:ss'))  (local time, from $kind)"
        }
        'now-to-ts' {
            $now = Get-DevKitCurrentUnixTime
            $resultLines += "Seconds:      $($now.Seconds)"
            $resultLines += "Milliseconds: $($now.Milliseconds)"
        }
        'guid' { $resultLines += New-DevKitGuid }
        'sha256' { $resultLines += Get-DevKitSha256Hash -Text $inputText }
        'jwt-decode' {
            $decoded = ConvertFrom-DevKitJwt -Token $inputText
            $resultLines += "Header:"
            $resultLines += ($decoded.Header | ConvertTo-Json -Depth 10)
            $resultLines += "Payload:"
            $resultLines += ($decoded.Payload | ConvertTo-Json -Depth 10)
        }
    }
} catch {
    Write-DevKitError "Conversion failed: $_"
    exit 1
}

Write-Host ""
Write-Host "  Result:" -ForegroundColor Cyan
foreach ($line in $resultLines) { Write-Host "  $line" -ForegroundColor Green }

if ($selected.Mode -eq 'jwt-decode') {
    Write-Host ""
    Write-Host "  NOTE: the signature was NOT verified - never trust decoded JWT content for authentication." -ForegroundColor Gray
}

if ($Clipboard) {
    try {
        ($resultLines -join "`n") | Set-Clipboard
        Write-Host "`n  Copied to clipboard!" -ForegroundColor Green
    } catch {
        Write-Host "`n  ERROR: Failed to copy to clipboard: $_" -ForegroundColor Red
    }
}

Write-Host ""
