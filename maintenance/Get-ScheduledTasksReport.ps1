#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Scheduled Tasks Report - Northstar DevKit
.DESCRIPTION
    Lists Windows scheduled tasks with their state, last run time, and last
    result, flagging any nonzero result code. Reading the list requires no
    admin rights. Optionally disables a single named task (which may require
    admin rights depending on the task's owning scope).

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER NonMicrosoftOnly
    Only list tasks outside the \Microsoft\ task folder tree.
.PARAMETER Disable
    Name of a task to disable instead of running the report. If more than
    one task shares this name (in different task folders), you'll be asked
    which one to disable.
.PARAMETER Force
    Skip the confirmation prompt when disabling a task.
.EXAMPLE
    .\Get-ScheduledTasksReport.ps1
    .\Get-ScheduledTasksReport.ps1 -NonMicrosoftOnly
    .\Get-ScheduledTasksReport.ps1 -Disable "MyOldTask"
    .\Get-ScheduledTasksReport.ps1 -Disable "MyOldTask" -Force
#>
[CmdletBinding()]
param(
    [switch]$NonMicrosoftOnly,
    [string]$Disable,
    [switch]$Force
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path $CommonModule) { . $CommonModule }

Write-DevKitHeader "Scheduled Tasks Report"

if (-not $Disable) {
    Write-DevKitStep "Querying scheduled tasks"
    try {
        $tasks = @(Get-ScheduledTask -ErrorAction Stop)
        Write-DevKitDone
    } catch {
        Write-DevKitError "Failed to query scheduled tasks: $_"
        exit 1
    }

    if ($NonMicrosoftOnly) {
        $tasks = @($tasks | Where-Object { $_.TaskPath -notlike '\Microsoft\*' })
    }

    if ($tasks.Count -eq 0) {
        Write-DevKitInfo "No scheduled tasks found."
        exit 0
    }

    $tasks = $tasks | Sort-Object TaskPath, TaskName

    Write-Host ""
    Write-Host ("  {0,-4} {1,-11} {2,-17} {3,-11} {4}" -f "#", "State", "LastRun", "Result", "Task") -ForegroundColor Magenta
    Write-Host ("  {0,-4} {1,-11} {2,-17} {3,-11} {4}" -f "---", "-----", "-------", "------", "----") -ForegroundColor Magenta

    $i = 0
    foreach ($task in $tasks) {
        $i++
        $info = $null
        try {
            $info = Get-ScheduledTaskInfo -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Stop
        } catch {
            # Some protected system tasks refuse Get-ScheduledTaskInfo even
            # though the task itself was enumerable - not a script failure.
        }

        # Task Scheduler uses 11/30/1999 as the "never run" sentinel rather
        # than a null LastRunTime.
        $lastRun = "Never"
        if ($info -and $info.LastRunTime -and $info.LastRunTime.Year -gt 1999) {
            $lastRun = $info.LastRunTime.ToString('yyyy-MM-dd HH:mm')
        }

        $resultCode = if ($info) { $info.LastTaskResult } else { $null }
        $taskDisplay = "$($task.TaskPath)$($task.TaskName)"

        Write-Host ("  {0,-4} {1,-11} {2,-17} " -f $i, $task.State, $lastRun) -NoNewline -ForegroundColor Gray
        if ($null -eq $resultCode) {
            Write-Host ("{0,-11}" -f "N/A") -NoNewline -ForegroundColor Gray
        } elseif ($resultCode -eq 0) {
            Write-Host ("{0,-11}" -f "OK") -NoNewline -ForegroundColor Green
        } else {
            Write-Host ("{0,-11}" -f ("0x{0:X8}" -f $resultCode)) -NoNewline -ForegroundColor Yellow
        }
        Write-Host $taskDisplay -ForegroundColor Gray
    }

    Write-Host ""
    Write-DevKitInfo "$($tasks.Count) task(s) listed. Use -Disable <TaskName> to disable one."
    exit 0
}

Write-DevKitStep "Looking up scheduled task '$Disable'"
try {
    $found = @(Get-ScheduledTask -TaskName $Disable -ErrorAction Stop)
} catch {
    # Get-ScheduledTask throws when the name matches nothing - that's a
    # normal "not found" outcome here, not a script failure.
    $found = @()
}
Write-DevKitDone

if ($found.Count -eq 0) {
    Write-DevKitError "No scheduled task found with name '$Disable'."
    exit 1
}

$target = $found[0]
if ($found.Count -gt 1) {
    Write-Host ""
    Write-Host "  Multiple tasks named '$Disable' were found:" -ForegroundColor Magenta
    for ($i = 0; $i -lt $found.Count; $i++) {
        Write-Host ("    [{0}] {1}{2}  (State: {3})" -f ($i + 1), $found[$i].TaskPath, $found[$i].TaskName, $found[$i].State)
    }
    Write-Host ""
    $choice = Read-Host "  Which one do you want to disable? (1-$($found.Count), or 0 to cancel)"
    if ($choice -notmatch '^\d+$' -or [int]$choice -lt 1 -or [int]$choice -gt $found.Count) {
        Write-DevKitInfo "Cancelled."
        exit 0
    }
    $target = $found[[int]$choice - 1]
}

$fullName = "$($target.TaskPath)$($target.TaskName)"

if (-not (Confirm-DevKitDestructiveAction -Action "disable scheduled task '$fullName'" -Force:$Force)) {
    Write-DevKitInfo "Cancelled."
    exit 0
}

Write-DevKitStep "Disabling '$fullName'"
try {
    $target | Disable-ScheduledTask -ErrorAction Stop | Out-Null
    Write-DevKitDone
} catch {
    $msg = $_.Exception.Message
    if ($msg -match 'denied|Access is denied|0x80070005') {
        Write-DevKitError "Access denied disabling '$fullName'. This task's scope requires an elevated (Administrator) session."
    } else {
        Write-DevKitError "Failed to disable '$fullName': $msg"
    }
    exit 1
}

exit 0
