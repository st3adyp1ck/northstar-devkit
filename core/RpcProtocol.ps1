#!/usr/bin/env pwsh
<#
.SYNOPSIS
    NDJSON-RPC line-encoding helpers shared by Invoke-DevKitRpc.ps1's main
    thread and its lane worker runspaces (each dot-sources this file
    independently since runspaces don't share function definitions).
#>

if ($global:DevKitRpcProtocolLoaded) { return }
$global:DevKitRpcProtocolLoaded = $true

function ConvertTo-DevKitRpcLine {
    param([Parameter(Mandatory)]$Object)
    # Depth 12 covers nested tool results (e.g. git graph lane arrays of
    # objects) without needing a per-call override; Compress keeps each
    # response to exactly one line, which the framing depends on.
    return ($Object | ConvertTo-Json -Depth 12 -Compress)
}

function New-DevKitRpcSuccess {
    param([Parameter(Mandatory)]$Id, $Result, [double]$Ms = 0)
    return [ordered]@{ id = $Id; ok = $true; result = $Result; ms = [math]::Round($Ms, 2) }
}

function New-DevKitRpcFailure {
    param([Parameter(Mandatory)]$Id, [string]$Kind = 'ToolFailed', [string]$Message, $Detail)
    $err = [ordered]@{ kind = $Kind; message = $Message }
    if ($null -ne $Detail) { $err.detail = $Detail }
    return [ordered]@{ id = $Id; ok = $false; error = $err }
}
