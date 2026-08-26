#!/usr/bin/env pwsh
<#
.SYNOPSIS
    The RPC method table: maps a "namespace.verb" method name to a call
    into DevKit.Core (tools/lib/* + core/DevKit-WidgetCore.ps1 +
    core/DevKit-GuiCore.ps1 - all logic untouched, this file only adapts
    JSON params <-> PowerShell calls). Dot-sourced independently inside
    each lane runspace in Invoke-DevKitRpc.ps1 after DevKit.Core is
    imported there.
.NOTES
    Adding a new panel/feature almost always means adding one case here,
    not touching Rust or the lane/writer plumbing - see
    Invoke-DevKitRpc.ps1's header comment for why.
#>

if ($global:DevKitRpcMethodsLoaded) { return }
$global:DevKitRpcMethodsLoaded = $true

# Methods whose TOP-LEVEL result is an array. PowerShell unrolls arrays at
# every function boundary, so `return @(...)` from Invoke-DevKitRpcMethod
# hands the lane worker a bare object for one element and $null for zero -
# and the JSON envelope then carries {"result":{...}} or null instead of
# [...], crashing typed consumers (the CLI's Vec<LinkedProject> parse, the
# widget's .map calls) precisely on the fresh-install / first-project /
# first-note states no dev machine ever exhibits. The lane worker consults
# this set after every call and re-wraps (see Invoke-DevKitRpc.ps1) - keep
# it in sync when adding a method that returns a bare array.
$script:DevKitRpcArrayMethods = @{
    'projects.list'      = $true
    'projects.remove'    = $true
    'projects.rename'    = $true
    'projects.setPinned' = $true
    'projects.repair'    = $true
    'notes.get'          = $true
    'notes.save'         = $true
    'ondeck.get'         = $true
    'ondeck.add'         = $true
    'ondeck.remove'      = $true
    'ondeck.setStatus'   = $true
    'ondeck.clearDone'   = $true
    'process.topCpu'     = $true
    'metrics.excludedPorts' = $true
}

function Test-DevKitRpcArrayMethod {
    param([Parameter(Mandatory)][string]$Method)
    return $script:DevKitRpcArrayMethods.ContainsKey($Method)
}

function Get-DevKitRpcParam {
    <# Safe property read off a params PSCustomObject (JSON-parsed) - never throws on a missing property. #>
    param($Params, [Parameter(Mandatory)][string]$Name, $Default = $null)
    if ($null -eq $Params) { return $Default }
    $prop = $Params.PSObject.Properties[$Name]
    if ($null -eq $prop -or $null -eq $prop.Value) { return $Default }
    return $prop.Value
}

function ConvertTo-DevKitQuotedArgument {
    <#
    .SYNOPSIS
        Quotes ONE argument for a raw Win32 command line, per the C
        runtime's parsing rules (the same rules ArgumentList implements):
        backslashes are literal except when they precede a double quote,
        where N backslashes + quote must become 2N+1 backslashes + quote;
        a trailing run of N backslashes inside quotes must double to 2N.
        Needed only on Windows PowerShell 5.1, where
        ProcessStartInfo.ArgumentList (a .NET Core 2.1+ API) does not
        exist and arguments must go through the single .Arguments string.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('"')
    $backslashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\') {
            $backslashes++
        } elseif ($ch -eq '"') {
            [void]$sb.Append('\' * ($backslashes * 2 + 1))
            [void]$sb.Append('"')
            $backslashes = 0
        } else {
            if ($backslashes -gt 0) { [void]$sb.Append('\' * $backslashes); $backslashes = 0 }
            [void]$sb.Append($ch)
        }
    }
    if ($backslashes -gt 0) { [void]$sb.Append('\' * ($backslashes * 2)) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Get-DevKitCatalogPayload {
    <#
    .SYNOPSIS
        Flattens the manifest-driven tool catalog (Get-DevKitGuiCatalog) plus
        a computed `Caution` flag (every manifest Help string that documents
        a destructive action prefixes it "Safety note:" - see AGENTS.md's
        Code Style Guidelines) into the shape the frontend renders directly.
    #>
    param([Parameter(Mandatory)][string]$RootPath)

    $groups = @(Get-DevKitGuiCatalog -RootPath $RootPath)
    $modules = @()
    foreach ($group in $groups) {
        foreach ($module in @($group.Modules)) {
            $items = @()
            foreach ($item in @($module.Items)) {
                $help = [string]$item.Help
                $items += [ordered]@{
                    key             = [string]$item.Key
                    label           = [string]$item.Label
                    script          = [string]$item.Script
                    help            = $help
                    caution         = ($help -match 'Safety note:')
                    requiresProject = [bool]$item.RequiresProject
                    projectArgName  = if ($item.ProjectArgName) { [string]$item.ProjectArgName } else { $null }
                    requiresFile    = $item.RequiresFile
                    prompts         = $item.Prompts
                    staticArgs      = $item.StaticArgs
                }
            }
            $modules += [ordered]@{
                group       = [string]$group.Group
                folder      = [string]$module.Folder
                name        = [string]$module.Name
                description = [string]$module.Description
                items       = $items
            }
        }
    }
    return [ordered]@{ modules = $modules }
}

function Invoke-DevKitRpcMethod {
    param(
        [Parameter(Mandatory)][string]$Method,
        $Params,
        [Parameter(Mandatory)][scriptblock]$EmitEvent
    )

    switch ($Method) {
        # ---------- catalog / settings ----------
        'catalog.get' {
            return Get-DevKitCatalogPayload -RootPath $RepoRoot
        }
        'settings.get' {
            return Get-DevKitSettings
        }
        'settings.set' {
            $settings = Get-DevKitRpcParam $Params 'settings'
            Set-DevKitSettings -Settings $settings
            return (Get-DevKitSettings)
        }

        # ---------- metrics (polled by the widget gauges) ----------
        'metrics.system' {
            return Get-DevKitSystemMetrics
        }
        'metrics.node' {
            return Get-DevKitNodeSnapshot
        }
        'metrics.junk' {
            return Get-DevKitSystemJunk
        }
        'metrics.excludedPorts' {
            return Get-DevKitExcludedPortRanges
        }
        'metrics.gpuProcesses' {
            $count = [int](Get-DevKitRpcParam $Params 'count' 15)
            return Get-DevKitGpuProcessUsage -Count $count
        }

        # ---------- process management (gauge click-through) ----------
        'process.topCpu' {
            $count = [int](Get-DevKitRpcParam $Params 'count' 15)
            return Get-DevKitTopCpuProcesses -Count $count
        }
        'process.topMemory' {
            $count = [int](Get-DevKitRpcParam $Params 'count' 15)
            return Get-DevKitTopMemoryProcesses -Count $count
        }
        'process.kill' {
            $pid_ = [int](Get-DevKitRpcParam $Params 'pid')
            return Stop-DevKitProcessById -ProcessId $pid_
        }
        'process.freeMemory' {
            return Invoke-DevKitFreeMemory
        }
        'junk.clear' {
            return Clear-DevKitSystemJunk
        }

        # ---------- git ----------
        'git.overview' {
            $path = [string](Get-DevKitRpcParam $Params 'path' '')
            $includeGraph = [bool](Get-DevKitRpcParam $Params 'includeGraph' $true)
            return Get-DevKitRepoOverview -Path $path -IncludeGraph $includeGraph
        }
        'git.commitDetails' {
            $path = [string](Get-DevKitRpcParam $Params 'path' '')
            $hash = [string](Get-DevKitRpcParam $Params 'hash' '')
            return Get-DevKitCommitDetails -Path $path -Hash $hash
        }
        'git.action' {
            $path = [string](Get-DevKitRpcParam $Params 'path' '')
            $action = [string](Get-DevKitRpcParam $Params 'action' '')
            return Invoke-DevKitGitAction -Path $path -Action $action
        }

        # ---------- github (via gh CLI) ----------
        'github.prs' {
            $path = [string](Get-DevKitRpcParam $Params 'path' '')
            return Get-DevKitGitHubPullRequests -Path $path
        }
        'github.issues' {
            $path = [string](Get-DevKitRpcParam $Params 'path' '')
            return Get-DevKitGitHubIssues -Path $path
        }

        # ---------- MCP status ----------
        'mcp.report' {
            $projectPath = [string](Get-DevKitRpcParam $Params 'projectPath' '')
            return Get-DevKitMcpWidgetReport -ProjectPath $projectPath
        }

        # ---------- notes ----------
        'notes.get' {
            $projectPath = [string](Get-DevKitRpcParam $Params 'projectPath' '')
            return @(Get-DevKitProjectNotes -ProjectPath $projectPath)
        }
        'notes.save' {
            $projectPath = [string](Get-DevKitRpcParam $Params 'projectPath' '')
            $notes = @(Get-DevKitRpcParam $Params 'notes' @())
            Save-DevKitProjectNotes -ProjectPath $projectPath -Notes $notes
            return @(Get-DevKitProjectNotes -ProjectPath $projectPath)
        }

        # ---------- on-deck ----------
        'ondeck.get' {
            $projectPath = [string](Get-DevKitRpcParam $Params 'projectPath' '')
            return @(Get-DevKitProjectOnDeck -ProjectPath $projectPath)
        }
        'ondeck.add' {
            $projectPath = [string](Get-DevKitRpcParam $Params 'projectPath' '')
            $text = [string](Get-DevKitRpcParam $Params 'text' '')
            $items = @(Get-DevKitProjectOnDeck -ProjectPath $projectPath)
            $items = @(Add-DevKitOnDeckItem -Items $items -Text $text)
            Save-DevKitProjectOnDeck -ProjectPath $projectPath -Items $items
            return $items
        }
        'ondeck.remove' {
            $projectPath = [string](Get-DevKitRpcParam $Params 'projectPath' '')
            $id = [string](Get-DevKitRpcParam $Params 'id' '')
            $items = @(Get-DevKitProjectOnDeck -ProjectPath $projectPath)
            $items = @(Remove-DevKitOnDeckItem -Items $items -Id $id)
            Save-DevKitProjectOnDeck -ProjectPath $projectPath -Items $items
            return $items
        }
        'ondeck.setStatus' {
            $projectPath = [string](Get-DevKitRpcParam $Params 'projectPath' '')
            $id = [string](Get-DevKitRpcParam $Params 'id' '')
            $status = [string](Get-DevKitRpcParam $Params 'status' '')
            $items = @(Get-DevKitProjectOnDeck -ProjectPath $projectPath)
            $items = @(Set-DevKitOnDeckItemStatus -Items $items -Id $id -Status $status)
            Save-DevKitProjectOnDeck -ProjectPath $projectPath -Items $items
            return $items
        }
        'ondeck.clearDone' {
            $projectPath = [string](Get-DevKitRpcParam $Params 'projectPath' '')
            $items = @(Get-DevKitProjectOnDeck -ProjectPath $projectPath)
            $items = @(Clear-DevKitOnDeckDone -Items $items)
            Save-DevKitProjectOnDeck -ProjectPath $projectPath -Items $items
            return $items
        }

        # ---------- env drift ----------
        'env.drift' {
            $path = [string](Get-DevKitRpcParam $Params 'path' '')
            return Get-DevKitEnvDrift -Path $path
        }

        # ---------- files flyout ----------
        'files.children' {
            $path = [string](Get-DevKitRpcParam $Params 'path' '')
            return Get-DevKitDirChildren -Path $path
        }

        # ---------- linked projects ----------
        'projects.list' {
            return @(Get-DevKitLinkedProjects)
        }
        'projects.add' {
            $path = [string](Get-DevKitRpcParam $Params 'path' '')
            $name = Get-DevKitRpcParam $Params 'name' $null
            return Add-DevKitLinkedProject -Path $path -Name $name
        }
        'projects.remove' {
            $id = [string](Get-DevKitRpcParam $Params 'id' '')
            Remove-DevKitLinkedProject -Id $id
            return @(Get-DevKitLinkedProjects)
        }
        'projects.rename' {
            $id = [string](Get-DevKitRpcParam $Params 'id' '')
            $name = [string](Get-DevKitRpcParam $Params 'name' '')
            Rename-DevKitLinkedProject -Id $id -NewName $name
            return @(Get-DevKitLinkedProjects)
        }
        'projects.setPinned' {
            $id = [string](Get-DevKitRpcParam $Params 'id' '')
            $pinned = [bool](Get-DevKitRpcParam $Params 'pinned' $false)
            Set-DevKitProjectPinned -Id $id -Pinned $pinned
            return @(Get-DevKitLinkedProjects)
        }
        'projects.repair' {
            $id = [string](Get-DevKitRpcParam $Params 'id' '')
            $newPath = [string](Get-DevKitRpcParam $Params 'newPath' '')
            Repair-DevKitLinkedProject -Id $id -NewPath $newPath
            return @(Get-DevKitLinkedProjects)
        }
        'projects.getActive' {
            return Get-DevKitActiveProject
        }
        'projects.setActive' {
            $id = [string](Get-DevKitRpcParam $Params 'id' '')
            Set-DevKitActiveProject -Id $id
            return Get-DevKitActiveProject
        }
        'projects.clearActive' {
            Clear-DevKitActiveProject
            return $null
        }

        # ---------- tool execution (Control Center "Run") ----------
        'tool.run' {
            $folder = [string](Get-DevKitRpcParam $Params 'folder' '')
            $script = [string](Get-DevKitRpcParam $Params 'script' '')
            $toolArgs = @(Get-DevKitRpcParam $Params 'args' @())
            $runId = [string](Get-DevKitRpcParam $Params 'runId' ([guid]::NewGuid().ToString('N')))

            $scriptPath = Join-Path (Join-Path $RepoRoot 'tools') (Join-Path $folder $script)
            if (-not (Test-Path -LiteralPath $scriptPath)) {
                throw "Tool script not found: $scriptPath"
            }

            $pwshExe = (Get-Process -Id $PID).Path
            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName = $pwshExe
            $allArgs = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath) + @($toolArgs | ForEach-Object { [string]$_ })
            # ProcessStartInfo.ArgumentList is .NET Core 2.1+ only - on a
            # machine with no pwsh 7 the sidecar runs under Windows
            # PowerShell 5.1 (.NET Framework), where the property doesn't
            # exist and .Add() dies with a null-method error, silently
            # breaking every tool run. Branch: use ArgumentList when
            # available (it quotes correctly for us), else build the single
            # .Arguments string with the same C-runtime quoting rules via
            # ConvertTo-DevKitQuotedArgument.
            if ($null -ne $psi.PSObject.Properties['ArgumentList'] -and $null -ne $psi.ArgumentList) {
                foreach ($a in $allArgs) { [void]$psi.ArgumentList.Add($a) }
            } else {
                $psi.Arguments = ($allArgs | ForEach-Object { ConvertTo-DevKitQuotedArgument -Value $_ }) -join ' '
            }
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.RedirectStandardInput = $true
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true

            $proc = [System.Diagnostics.Process]::new()
            $proc.StartInfo = $psi
            [void]$proc.Start()
            $proc.StandardInput.Close()  # non-interactive: never let a tool block waiting on stdin

            & $EmitEvent 'tool.started' $runId @{ pid = $proc.Id }

            # Drain stderr concurrently via an async Task so a chatty stderr
            # stream can never fill its pipe buffer and deadlock the child
            # while we're synchronously draining stdout below.
            $stderrTask = $proc.StandardError.ReadToEndAsync()

            while (-not $proc.StandardOutput.EndOfStream) {
                $outLine = $proc.StandardOutput.ReadLine()
                if ($null -ne $outLine) {
                    & $EmitEvent 'tool.output' $runId @{ stream = 'stdout'; line = $outLine }
                }
            }
            $proc.WaitForExit()
            $stderrText = $stderrTask.GetAwaiter().GetResult()
            if ($stderrText) {
                foreach ($errLine in ($stderrText -split "`r?`n")) {
                    if ($errLine) { & $EmitEvent 'tool.output' $runId @{ stream = 'stderr'; line = $errLine } }
                }
            }

            $exitCode = $proc.ExitCode
            & $EmitEvent 'tool.finished' $runId @{ exitCode = $exitCode }
            return [ordered]@{ runId = $runId; exitCode = $exitCode }
        }

        default {
            throw "Unknown RPC method: $Method"
        }
    }
}
