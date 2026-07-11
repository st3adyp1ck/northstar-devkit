# Northstar DevKit - Agent Documentation

## Project Overview

**Northstar DevKit** is a comprehensive PowerShell-based Windows toolkit for web developers. It provides utilities for port management, Node.js/Next.js/Vite cache clearing, Git repository management, Docker container cleanup, system environment management, and WiFi network optimization.

- **Created by:** Northstar Software Development
- **Website:** https://www.northstarcoding.com
- **License:** MIT
- **Language:** English (all comments and documentation)
- **Version:** 3.1.0

## Technology Stack

- **Primary Language:** PowerShell 5.1+ or PowerShell 7+ (pwsh)
- **Secondary:** Batch files (.bat) as wrappers for GUI/click execution
- **Platform:** Windows 10/11
- **No external dependencies:** Uses built-in Windows PowerShell cmdlets and system utilities

## Project Structure

```
DevKit/
├── DevKit.bat              # Main launcher (batch wrapper)
├── DevKit.ps1              # Main interactive menu - Main Menu + Projects menu are
│                           # hand-written; the ten tool-category submenus below are
│                           # generic, driven by each folder's _module.psd1
├── Setup-Path.bat          # Adds DevKit to PATH for global access
├── VERSION                 # Single source of truth for the version number
├── CHANGELOG.md            # Release history
├── RELEASING.md            # Maintainer release checklist
├── README.md               # User documentation
├── LICENSE                 # MIT License
├── AGENTS.md               # This file
├── .gitignore              # Git ignore rules
│
├── lib/                    # Shared PowerShell helpers
│   └── DevKit-Common.ps1   # Common functions: path/package-manager helpers, the
│                           # project-linking picker, the manifest menu dispatcher,
│                           # settings, and the shared confirmation gate
│
├── tests/
│   └── Unit/               # Pester tests for pure-logic parsers/converters
│
├── ports/                  # Port management tools (+ _module.psd1)
│   ├── Scan-Ports.ps1      # Scan common dev ports (3000, 5173, etc.)
│   ├── Scan-Ports.bat      # Batch wrapper
│   ├── Kill-Port.ps1       # Kill process by port or PID
│   └── Kill-AllNode.ps1    # Kill all Node.js processes
│
├── node/                   # Node.js utilities (+ _module.psd1)
│   ├── Clear-NpmCache.ps1  # Clear NPM cache
│   ├── Remove-NodeModules.ps1  # Delete node_modules
│   ├── Nuke-And-Reinstall.ps1  # Full reset + reinstall
│   └── Nuke-And-Reinstall.bat  # Batch wrapper
│
├── nextjs/                 # Next.js specific tools (+ _module.psd1)
│   ├── Clear-NextCache.ps1     # Clear .next build cache
│   ├── Clear-TurboCache.ps1    # Clear Turbopack cache
│   ├── Next-DevFresh.ps1       # Clear cache + start dev server
│   ├── Next-DevFresh.bat       # Batch wrapper
│   ├── Next-FullClean.ps1      # Full clean + reinstall
│   └── Next-FullClean.bat      # Batch wrapper
│
├── vite/                   # Vite tools (+ _module.psd1)
│   ├── Vite-DevFresh.ps1       # Fresh dev server start
│   ├── Vite-DevFresh.bat
│   ├── Vite-PreviewBuild.ps1   # Build and preview
│   └── Vite-PreviewBuild.bat
│
├── git/                    # Git tools (+ _module.psd1)
│   ├── Git-Cleanup.ps1         # Prune branches, gc, cleanup
│   ├── Git-Cleanup.bat
│   ├── Git-StatusAll.ps1       # Status across multiple repos
│   ├── Git-StatusAll.bat
│   ├── Git-SyncFork.ps1        # Sync fork with upstream
│   └── Git-SyncFork.bat
│
├── docker/                 # Docker tools (+ _module.psd1)
│   ├── Docker-Nuke.ps1         # Remove all Docker resources
│   ├── Docker-Nuke.bat
│   ├── Docker-Cleanup.ps1      # Selective cleanup
│   ├── Docker-Cleanup.bat
│   ├── Docker-QuickLogs.ps1    # Multi-container log tailing
│   └── Docker-QuickLogs.bat
│
├── system/                 # System environment tools (+ _module.psd1)
│   ├── Edit-Path.ps1           # PATH variable editor
│   ├── Edit-Path.bat
│   ├── Env-Backup.ps1          # Backup env variables
│   ├── Env-Restore.ps1         # Restore env variables
│   ├── Shell-Reload.ps1        # Reload shell environment
│   └── *.bat
│
├── workflow/               # Developer workflow tools (+ _module.psd1)
│   ├── Code-Here.ps1           # Open VS Code/Cursor
│   ├── Code-Here.bat
│   ├── Open-Repo.ps1           # Open repo in browser
│   ├── Open-Repo.bat
│   ├── Copy-EnvTemplate.ps1    # Copy .env template
│   └── Copy-EnvTemplate.bat
│
├── diagnostics/            # Health check tools (+ _module.psd1)
│   ├── DevKit-Doctor.ps1       # Environment health check
│   ├── DevKit-Doctor.bat
│   ├── System-DevInfo.ps1      # System info summary
│   └── System-DevInfo.bat
│
├── wifi/                   # WiFi optimization tools (+ _module.psd1)
│   ├── WiFi-Optimize.ps1   # Full optimization (DNS, TCP/IP, speed test)
│   ├── WiFi-Optimize.bat   # Batch wrapper
│   ├── WiFi-FastMode.ps1   # Quick optimization (no speed test)
│   ├── WiFi-FastMode.bat   # Batch wrapper
│   ├── WiFi-Scan.ps1       # Network scanner with signal analysis
│   └── WiFi-Scan.bat       # Batch wrapper
│
├── maintenance/            # Windows maintenance/tuning (+ _module.psd1)
│   ├── Clear-DiskJunk.ps1          # Report/-Apply: temp, WU cache, Recycle Bin, WinSxS
│   ├── Show-DiskUsageReport.ps1    # Largest subfolders by size
│   ├── Manage-StartupPrograms.ps1  # List/disable/enable Run-key + Startup-folder entries
│   ├── Manage-Services.ps1         # Report/set StartType for a curated service list
│   ├── Repair-SystemFiles.ps1      # SFC /scannow + DISM /RestoreHealth
│   ├── Reset-WindowsUpdate.ps1     # Classic WU cache/catalog reset
│   ├── Get-ScheduledTasksReport.ps1 # List/disable scheduled tasks
│   ├── Get-RecentEventErrors.ps1   # Recent Critical/Error events (System+Application)
│   ├── Set-PowerPlan.ps1           # List/switch power plans, unlock Ultimate Performance
│   ├── Set-VisualEffects.ps1       # Report/set VisualFXSetting (perf vs appearance)
│   ├── Test-PageFileConfig.ps1     # Page file size/config report (read-only)
│   ├── Get-DiskHealthReport.ps1    # SMART/StorageReliabilityCounter per physical disk
│   ├── Get-BatteryReport.ps1       # powercfg /batteryreport wrapper
│   ├── Invoke-MemoryDiagnostic.ps1 # Launches mdsched.exe (schedules a restart)
│   └── *.bat                       # Batch wrapper per script
│
└── agents/                 # AI CLI & MCP management (+ _module.psd1)
    ├── Get-InstalledAiClis.ps1  # Detect claude/gh/codex/gemini/cursor-agent/aider
    ├── Update-AiClis.ps1        # Best-effort npm-based CLI updates
    ├── Get-McpServers.ps1       # claude mcp list, optionally scoped to the active project
    ├── Add-McpServer.ps1        # claude mcp add wrapper (local/project/user scope)
    ├── Remove-McpServer.ps1     # claude mcp remove wrapper
    └── *.bat                    # Batch wrapper per script
```

Linked projects (`projects.json`) and settings (`settings.json`) live outside
the repo at `%LOCALAPPDATA%\NorthstarDevKit\`, not in any of the folders above.

## Code Style Guidelines

### PowerShell Script Structure

All PowerShell scripts follow this standardized structure:

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Brief description - Northstar DevKit
.DESCRIPTION
    Detailed description of what the script does.
    
    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER ParamName
    Parameter description
.EXAMPLE
    .\Script-Name.ps1
    .\Script-Name.ps1 -ParamName value
#>
[CmdletBinding()]
param(
    [string]$Path = ".",
    [switch]$Force
)

# Script body with Write-Host for colored output
```

### Naming Conventions

- **Scripts:** PascalCase with hyphens (e.g., `Kill-Port.ps1`, `WiFi-Optimize.ps1`)
- **Functions:** PascalCase with approved PowerShell verbs (e.g., `Write-Header`, `Invoke-PortScan`)
- **Variables:** camelCase or descriptive names
- **Parameters:** PascalCase with sensible defaults
- **Avoid reserved words:** Do not use `$Host` as a parameter name (use `$ExposeHost` instead)

### Output Styling

Use consistent color coding for output:

```powershell
Write-Host "Success message" -ForegroundColor Green
Write-Host "Warning message" -ForegroundColor Yellow
Write-Host "Error message" -ForegroundColor Red
Write-Host "Info message / routine progress" -ForegroundColor Cyan
Write-Host "Secondary info" -ForegroundColor Gray
Write-Host "Highlight" -ForegroundColor Magenta
```

**Yellow is reserved for real warnings** - a message the user should pay
attention to before an action proceeds, not routine step/progress chrome
(use Cyan for that, matching `Write-DevKitStep`) and not a condition that
actually halts the script (use Red + "ERROR:", even if it reads like a
warning in plain English - e.g. "a rebase is already in progress" is an
error because the script exits, not a warning the user can proceed past).

### Error Handling

Always use try-catch blocks for operations that may fail:

```powershell
try {
    Remove-Item -Path $path -Recurse -Force
    Write-Host "  DONE: Message" -ForegroundColor Green
} catch {
    Write-Host "  ERROR: $_" -ForegroundColor Red
    exit 1
}
```

## Key Features by Module

### Port Tools (`ports/`)
- **Common ports scanned:** 3000, 3001, 3002, 3003, 5173, 5174, 8000, 8080, 8081, 9000, 4200, 5000, 5500, 1337, 5432, 3306, 6379, 27017
- Uses `Get-NetTCPConnection` for port detection
- Uses `Get-Process` and `Stop-Process` for process management

### Node.js Tools (`node/`)
- Auto-detects package manager (npm/yarn/pnpm/bun) from lock files
- Executes the correct cache clean command for the detected package manager
- Recursively removes `node_modules` directories using long-path-safe deletion
- Supports `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, and `bun.lockb` cleanup

### Next.js Tools (`nextjs/`)
- Auto-detects package manager (npm/yarn/pnpm/bun) from lock files
- Removes `.next/` build cache directory
- Clears Turbopack cache from `.next/cache`, `node_modules/.cache`, `.turbo`
- Runs the detected package manager's dev command after cache clearing
- Disables Next.js telemetry: `$env:NEXT_TELEMETRY_DISABLED = "1"`

### Vite Tools (`vite/`)
- Clears `.vite/` cache directory and build artifacts
- Supports custom port configuration
- Build and preview production builds

### Git Tools (`git/`)
- Prunes merged branches with `git branch -d`
- Runs garbage collection with `git gc --aggressive`
- Optionally clears reflog
- Scans multiple repositories for status
- Syncs forks with upstream using merge or rebase

### Docker Tools (`docker/`)
- Uses `docker ps`, `docker rm`, `docker rmi`, `docker volume rm` for cleanup
- Supports dry-run mode for safety
- Multi-container log tailing with color coding
- Selective cleanup of dangling images and unused volumes

### System Tools (`system/`)
- Uses `[Environment]::GetEnvironmentVariable` and `SetEnvironmentVariable`
- Supports both User and Machine environment scopes
- Interactive PATH editor with duplicate detection
- JSON backup/restore for environment variables

### Workflow Tools (`workflow/`)
- Detects VS Code and Cursor installations
- Opens repositories in browser (GitHub, GitLab, Bitbucket, Azure DevOps)
- Parses `.env.example` templates for variable extraction
- Converts SSH URLs to HTTPS for browser opening

### Diagnostics (`diagnostics/`)
- Checks tool installations and versions
- Validates Git configuration
- Detects Docker daemon status
- Reports disk space and memory
- Exports system info to JSON

### WiFi Tools (`wifi/`)
- Uses `netsh` commands for network operations
- Uses `Get-NetAdapter` and `Set-DnsClientServerAddress` for DNS management
- Cloudflare DNS (1.1.1.1 / 2606:4700:4700::1111) and Google DNS (8.8.8.8 / 2001:4860:4860::8888) testing
- Speed test via Cloudflare's speed endpoint
- Requires administrator privileges; warns about required reboot after TCP/IP reset

### Maintenance (`maintenance/`)
- Real Windows maintenance/tuning, distinct from `diagnostics/`'s dev-tool health check
- Every mutating tool (disk cleanup, service/startup changes, SFC/DISM, Windows Update
  reset, power plan, visual effects, memory diagnostic) defaults to a safe report/`-DryRun`
  and requires an explicit flag plus `Confirm-DevKitDestructiveAction` to change anything
- Admin-gated actions check `Test-DevKitAdmin` and fail with a clear message rather than a
  stack trace when not elevated
- Startup-entry disable/enable is reversible by design (registry value rename / shortcut
  moved to a sibling folder), not a best-effort delete

### Agents & MCP (`agents/`)
- Detects AI coding-agent CLIs (claude, gh, codex, gemini, cursor-agent, aider) via
  `Get-DevKitWindowsExecutable` (see below) rather than a bare `Get-Command`/`&` invocation
- Wraps `claude mcp list/add/remove`; project-scoped operations resolve the active project
  via `Get-DevKitActiveProject` (read-only) and `Push-Location`/`Pop-Location` around the
  `claude` call, never via `Select-DevKitProject` (which can prompt/mutate the active project)

## Usage Patterns

### Interactive Menu Mode
```batch
.\DevKit.bat
```
Launches the main interactive menu for navigation via keyboard input.

### Direct PowerShell Execution
```powershell
.\ports\Kill-Port.ps1 -Port 3000
.\node\Nuke-And-Reinstall.ps1 -Path "C:\my-project"
.\nextjs\Next-DevFresh.ps1 -Port 3001
.\vite\Vite-DevFresh.ps1
.\git\Git-Cleanup.ps1 -DryRun
.\docker\Docker-Nuke.ps1 -DryRun
.\system\Edit-Path.ps1 -Show
.\diagnostics\DevKit-Doctor.ps1
.\wifi\WiFi-Optimize.ps1 -Fast
```

### Batch Wrapper Execution
```batch
.\ports\Scan-Ports.bat
.\git\Git-Cleanup.bat
.\docker\Docker-Nuke.bat
.\diagnostics\DevKit-Doctor.bat
.\wifi\WiFi-Optimize.bat
```

## Security Considerations

- **Administrator privileges** are required for:
  - WiFi optimization features (script checks and warns if not admin)
  - Editing system (Machine) PATH
  - Restoring Machine environment variables
- Batch wrappers use `-NoProfile -ExecutionPolicy Bypass` for fast, predictable launches
- All scripts use `ErrorAction SilentlyContinue` where appropriate to prevent unnecessary failures
- Force flags (`-Force`) are available to skip confirmation prompts for automation
- Docker Nuke requires explicit, case-sensitive confirmation (type `NUKE`) to prevent accidents - implemented via the shared `Confirm-DevKitDestructiveAction` helper in `lib/DevKit-Common.ps1`, which any new destructive script should call rather than hand-rolling its own y/n or typed-phrase prompt
- `%LOCALAPPDATA%\NorthstarDevKit\settings.json`'s `preferences.confirmDestructive` (default `true`) gates that shared helper globally; it does not currently gate any script's own bespoke confirmation logic that predates the helper
- **Never execute a destructive/mutating script's real path to "test" it - only its documented read-only/-DryRun/-WhatIf invocation.** Every script under `maintenance/` and `agents/` that mutates the system (deletes files, renames system folders, stops/starts services, writes the registry, runs SFC/DISM, mutates external CLI config) supports a safe, non-mutating invocation - use that one. This applies to a human tester and an AI agent equally: a 2026-07-11 incident had a build-time agent run `Reset-WindowsUpdate.ps1` for real (not `-DryRun`) while self-testing its own work; the safety system blocked it before any actual change landed, but it should never have been attempted in the first place.

## Testing

`tests/Unit` (Pester 5, wired into CI) covers pure-logic parsers and
converters where this project has actually had real bugs: package-manager
detection (`Get-DevKitPackageManager`), PATH de-duplication, the `.env`
template parser, the git-remote-to-browsable-URL converter, and the WiFi
scan parser. Run locally with:

```powershell
Invoke-Pester -Path tests/Unit
```

Everything else - anything that shells out to git/docker/npm, mutates
PATH/env vars/DNS, or kills processes - is **not** covered by automated
tests by design (a hosted CI runner shouldn't have its real PATH mutated
or its containers destroyed), and is verified manually:

1. Run scripts in a PowerShell window to observe output
2. Verify colored output displays correctly (see the color convention above)
3. Test both success and error paths
4. Confirm batch wrappers launch PowerShell correctly
5. Test DryRun/-WhatIf modes where available (Docker, Git cleanup)
6. Verify error handling with invalid inputs
7. When changing `DevKit.ps1` or `lib/DevKit-Common.ps1`'s menu dispatcher,
   do a scripted pass through the interactive menu (pipe a sequence of
   menu choices to `pwsh -File DevKit.ps1`) to confirm every category still
   renders and dispatches correctly - this is how the 3.0 rewrite verified
   menu parity across all ten tool categories.

## Adding New Tools

Since 3.0, adding a tool to an **existing** category (`ports/`, `node/`,
`nextjs/`, `vite/`, `git/`, `docker/`, `system/`, `workflow/`,
`diagnostics/`, `wifi/`) is a manifest edit, not a `DevKit.ps1` edit:

1. Create the PowerShell script in the appropriate subdirectory
2. Dot-source `lib/DevKit-Common.ps1` for shared helpers (admin checks, path validation, safe deletion, etc.)
3. Include proper comment-based help (SYNOPSIS, DESCRIPTION, PARAMETERS, EXAMPLES)
4. Add a batch wrapper for double-click execution
5. Add an entry to that category's `_module.psd1` (see any existing one,
   e.g. `ports/_module.psd1`, for the schema - `Key`/`Label`/`Script`,
   plus `RequiresProject`, `RequiresFile`, `Prompts`, or `StaticArgs` as
   needed). **Do not edit `DevKit.ps1`** for this - the generic dispatcher
   in `lib/DevKit-Common.ps1` (`Start-DevKitModuleTools`) picks up the new
   manifest entry automatically.
6. Update `README.md` with documentation
7. Update `AGENTS.md` with module details
8. Follow existing naming conventions and output styling
9. Test the tool thoroughly, including via the interactive menu (confirm
   the new manifest entry parses and dispatches correctly)

## Common Development Tasks

### Adding a new module category
1. Create a new subdirectory (e.g., `docker/`, `git/`)
2. Add PowerShell scripts and batch wrappers
3. Add a `_module.psd1` manifest listing the category's menu items (copy
   the shape of an existing one, e.g. `node/_module.psd1`)
4. Add exactly two lines to `DevKit.ps1`: a line in `Show-MainMenu`'s
   `Write-Host` list for the new `[N]` option, and a
   `'N' { Start-DevKitModuleTools -FolderPath (Join-Path $ScriptDir "yourfolder") }`
   case in the entry-point switch at the bottom of the file. That's the
   entire integration - no new menu function needed.
5. Add the new category to `Get-DevKitSearchableCategories` in `DevKit.ps1`
   (a `Folder`/`MainMenuKey` pair) so `/` search picks it up too
6. Update documentation files

### Modifying existing tools
- Keep backward compatibility with existing parameters
- Add new parameters as optional with sensible defaults
- Maintain consistent output styling
- Update documentation if behavior changes

## Notes

- Scripts assume PowerShell 7 (`pwsh.exe`) is preferred but fall back to Windows PowerShell (batch wrappers implement this fallback chain)
- All paths use `Join-Path` or `Resolve-Path` for cross-platform compatibility
- Scripts use `Push-Location` and `Pop-Location` wrapped in `try/finally` to maintain working directory context
- Batch wrappers use `%~dp0` to locate `.ps1` files without changing the caller's working directory
- No package management (no package.json, requirements.txt, etc.) - this is a standalone toolkit
- Scripts use consistent header format with Northstar branding
- Version 2.1 unified the toolkit under a shared helper module (`lib/DevKit-Common.ps1`), added package-manager auto-detection, completed batch-wrapper coverage, and fixed PowerShell 7 / path-validation / process-killing bugs
- Version 3.0 (see `CHANGELOG.md` for full detail) added browsable project linking (`Select-DevKitProject`, the linked-projects registry, `[10] Projects` menu), rewrote all ten tool-category submenus as a manifest-driven dispatcher (`_module.psd1` + `Start-DevKitModuleTools`) instead of ten hand-written function pairs, added `/` search-and-jump, added a Pester test suite, and fixed roughly 150 confirmed bugs from a full-repo review - including one (`system/Env-Restore.ps1`) that had been completely broken (could not run at all) since before 3.0 existed
- Version 3.1 (see `CHANGELOG.md`) added arrow-key navigation (`Show-DevKitInteractiveMenu`) with automatic fallback to the classic typed-number flow, two new manifest-driven categories (`[12] Maintenance`, `[13] Agents & MCP`), and `Get-DevKitWindowsExecutable` - a defensive CLI-resolution helper added after a real bug where an ambiguously-resolved `gh` on PATH triggered a Windows ShellExecute "Select an app to open" dialog instead of failing cleanly
