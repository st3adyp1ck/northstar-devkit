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

function Get-DevKitRpcParam {
    <# Safe property read off a params PSCustomObject (JSON-parsed) - never throws on a missing property. #>
    param($Params, [Parameter(Mandatory)][string]$Name, $Default = $null)
    if ($null -eq $Params) { return $Default }
    $prop = $Params.PSObject.Properties[$Name]
    if ($null -eq $prop -or $null -eq $prop.Value) { return $Default }
    return $prop.Value
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
            foreach ($a in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath)) {
                [void]$psi.ArgumentList.Add($a)
            }
            foreach ($a in $toolArgs) { [void]$psi.ArgumentList.Add([string]$a) }
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
