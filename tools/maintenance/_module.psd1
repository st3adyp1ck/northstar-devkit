@{
    Name        = "Maintenance"
    Description = "Real Windows maintenance and tuning: disk/storage cleanup, startup and service management, system file repair (SFC/DISM), Windows Update cache reset, scheduled tasks and event log review, power and visual-effects tuning, and hardware health reporting - distinct from diagnostics/, which checks dev-tool health rather than the OS itself. Most mutating tools default to a safe, non-mutating report, then offer to apply their changes right there (interactive runs only; explicit flags do the same for automation) - always behind a confirmation prompt. A few (system file repair, Windows Update reset, memory diagnostic) attempt their real action by default behind just a confirmation prompt, so check an item's Help below before running it unattended."
    Items       = @(
        @{
            Key    = '1'
            Label  = 'Clear Disk Junk (temp/WU cache/Recycle Bin)'
            Script = 'Clear-DiskJunk.ps1'
            Help   = "Scans user/system temp folders, the Windows Update download cache, and the Recycle Bin, and reports how much space each is holding. Use this to see how much junk is reclaimable before deciding whether to clean it. Safety note: bare invocation reports, then (interactive runs only) asks whether to clean up right away; -Apply skips that first prompt. Either way, deleting requires typing 'CLEAN' to confirm (or -Force to skip). Cleaning also stops/restarts the Windows Update services around clearing its cache. -IncludeWinSxS additionally runs 'Dism.exe /Online /Cleanup-Image /StartComponentCleanup' and requires an elevated session."
        }
        @{
            Key    = '2'
            Label  = 'Disk Usage Report (top folders by size)'
            Script = 'Show-DiskUsageReport.ps1'
            Help   = "Measures the immediate subfolders under a path (defaults to the system drive root) and lists the largest ones by size, descending. Use this to find what's eating disk space before deciding what to clean up manually or with Clear Disk Junk. Fully read-only - never prompts, deletes, or modifies anything, even with custom -Path/-Top values."
        }
        @{
            Key    = '3'
            Label  = 'Manage Startup Programs'
            Script = 'Manage-StartupPrograms.ps1'
            Help   = "Reports startup entries from the current-user and all-users Run registry keys plus both Startup folders (shortcuts), and can disable or re-enable one by its visible name. Use this to see what launches at sign-in and trim entries you don't want. Safety note: bare invocation reports, then (interactive runs only) offers to disable/re-enable an entry by name; -Disable/-Enable do the same for automation. Toggling mutates (a Run value is renamed to 'DevKitDisabled_<original>'; a Startup-folder shortcut is moved to a sibling 'Disabled' folder - both fully reversible, never a delete) and requires confirmation unless -Force is passed. Disabling/enabling an all-users (HKLM) entry additionally requires an elevated (Administrator) session."
        }
        @{
            Key    = '4'
            Label  = 'Manage Services'
            Script = 'Manage-Services.ps1'
            Help   = "Reports the current startup type and status for a curated list of commonly-tuned, non-critical Windows services (e.g. SysMain, Windows Search, Remote Registry), and can change one service's startup type by name (not limited to the curated list). Use this to see what's currently set before deciding whether to change anything - the report itself makes no recommendation. Safety note: bare invocation reports, then (interactive runs only) offers to change a service's startup type right away; -SetStartType plus -StartTypeValue does the same for automation. Changing a startup type mutates, requires an elevated (Administrator) session, and requires confirmation unless -Force is passed."
        }
        @{
            Key    = '5'
            Label  = 'Repair System Files (SFC + DISM)'
            Script = 'Repair-SystemFiles.ps1'
            Help   = "Runs System File Checker (sfc /scannow) followed by DISM's component-store repair (DISM /Online /Cleanup-Image /RestoreHealth) to find and fix corrupted system files, streaming both tools' output live. Can take 10-30+ minutes. Use this when Windows itself seems unstable or corrupted. Safety note: unlike most tools in this category, bare invocation is NOT a report - it requires an elevated (Administrator) session and a y/N confirmation (skippable with -Force), then runs the real repair. Use -DryRun to only see the command plan with no execution and no admin check."
        }
        @{
            Key    = '6'
            Label  = 'Reset Windows Update Cache'
            Script = 'Reset-WindowsUpdate.ps1'
            Help   = "Classic fix for a stuck Windows Update: stops the Windows Update-related services, renames the SoftwareDistribution and catroot2 cache folders (Windows rebuilds both automatically), then restarts the services. Use this when Windows Update is failing or hanging. Safety note: unlike most tools in this category, bare invocation is NOT a report - it requires an elevated (Administrator) session and typing 'RESET' to confirm (skippable with -Force), then performs the real reset. Use -DryRun to only see the step plan with no execution and no admin check."
        }
        @{
            Key    = '7'
            Label  = 'Scheduled Tasks Report'
            Script = 'Get-ScheduledTasksReport.ps1'
            Help   = "Lists Windows scheduled tasks with their state, last run time, and last result, flagging any nonzero result code, and can disable a single named task. Use -NonMicrosoftOnly to filter out the \Microsoft\ task-folder tree and focus on third-party tasks. Safety note: listing is read-only (no admin rights needed); after the list, an interactive run offers to disable a task by name, and -Disable does the same for automation. Disabling mutates - it requires confirmation unless -Force is passed, and may itself require an elevated session depending on the task's owning scope."
        }
        @{
            Key    = '8'
            Label  = 'Recent Event Errors'
            Script = 'Get-RecentEventErrors.ps1'
            Help   = "Reports Critical and Error level events from the System and Application Windows event logs within a recent time window (-Hours, default 24; -MaxEvents, default 50). Use this to spot what's been going wrong on the machine recently before digging further. Fully read-only - never modifies anything, and has no mutating parameters at all."
        }
        @{
            Key    = '9'
            Label  = 'Power Plan Manager'
            Script = 'Set-PowerPlan.ps1'
            Help   = "Lists Windows power plans (via powercfg /list) with the active one marked - this is also the bare/default behavior - switches the active plan by name via -SetPlan, and can unlock the hidden 'Ultimate Performance' plan via -UnlockUltimate. Use this to see or change which power plan is active, or to make Ultimate Performance available to switch to. Safety note: bare invocation and -List show the table, then (interactive runs only) offer to switch plans by number or name. Switching requires confirmation unless -Force is passed. -UnlockUltimate requires an elevated (Administrator) session plus confirmation unless -Force is passed."
        }
        @{
            Key    = '10'
            Label  = 'Visual Effects Manager'
            Script = 'Set-VisualEffects.ps1'
            Help   = "Reports or sets the Windows 'adjust for best performance/appearance' visual effects mode (Performance, Appearance, Auto, or Custom) - the setting behind Advanced System Settings -> Performance. Use this to quickly trade visual polish for responsiveness or vice versa. Safety note: bare invocation and -Show report the current mode, then (interactive runs only) offer to change it right away; -SetMode does the same for automation. Setting mutates the current user's own HKCU registry hive (no admin rights needed) and requires confirmation unless -Force is passed; a sign-out or Explorer restart may be needed for all effects to visibly update."
        }
        @{
            Key    = '11'
            Label  = 'Page File Configuration Report'
            Script = 'Test-PageFileConfig.ps1'
            Help   = "Reports current page file usage, whether Windows is managing the page file automatically, and total physical RAM, then gives a plain-language read of whether the current setup looks reasonable. Use this if you suspect memory-pressure issues or just want a sanity check on page file config. Intentionally read-only with no parameters at all - resizing a page file programmatically is finicky and reboot-dependent, so this tool only reports and recommends, never changes anything."
        }
        @{
            Key    = '12'
            Label  = 'Disk Health Report'
            Script = 'Get-DiskHealthReport.ps1'
            Help   = "Reads per-physical-disk wear, temperature, and read/write error counters via Storage Reliability Counters, and separately reports classic SMART failure-prediction data where the driver stack exposes it (each section is skipped gracefully, not treated as an error, when unsupported on a given disk/system). Use this periodically to catch a failing drive before it takes data with it. Fully read-only - never modifies anything, and has no parameters at all."
        }
        @{
            Key    = '13'
            Label  = 'Battery Report'
            Script = 'Get-BatteryReport.ps1'
            Help   = "Generates a Windows battery health report (powercfg /batteryreport) for laptop/tablet systems; a desktop with no battery is reported as a benign no-op, not an error. Use this to check battery wear/capacity over time. Non-destructive - it only ever writes the HTML report file, defaulting to a devkit-battery-report.html file under the Temp folder unless -OutputPath is given; -Open launches it with its default handler when done. No confirmation prompt - it never touches system configuration."
        }
        @{
            Key    = '14'
            Label  = 'Memory Diagnostic'
            Script = 'Invoke-MemoryDiagnostic.ps1'
            Help   = "Launches the built-in Windows Memory Diagnostic tool (mdsched.exe), which then prompts to restart the PC now or at the next boot to run a memory test. Use this if you suspect faulty RAM and are ready to accept a restart prompt. Safety note: bare invocation actually launches mdsched.exe (the ONE tool in this category whose default is not a report) - it is gated by typing 'RESTART' to confirm, skippable with -Force. Use -DryRun to only see what would happen with nothing launched."
        }
    )
}
