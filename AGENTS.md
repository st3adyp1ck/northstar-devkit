# Northstar DevKit - Agent Documentation

## Project Overview

**Northstar DevKit** is a comprehensive PowerShell-based Windows toolkit for web developers. It provides utilities for port management, Node.js/Next.js/Vite cache clearing, Git repository management, Docker container cleanup, system environment management, and WiFi network optimization.

- **Created by:** Northstar Software Development
- **Website:** https://www.northstarcoding.com
- **License:** MIT
- **Language:** English (all comments and documentation)
- **Version:** 3.8.0

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
├── DevKit-GUI.bat          # Desktop GUI launcher (batch wrapper for gui/DevKit-GUI.ps1)
├── Install.ps1 / .bat      # Portable installer: copies DevKit to a permanent per-user
│                           # location, adds it to PATH, offers Start Menu/Desktop
│                           # shortcuts and the two opt-in system/ integrations below.
│                           # Runs unmodified from either a git clone or a USB/ build.
├── Build-UsbPortable.ps1 / .bat  # Maintainer tool: mirrors the repo into USB/
│                           # (gitignored, regenerated on demand) with dev-only
│                           # clutter stripped (.git/.kimi/.github/tests/editor
│                           # folders) - the result is what you copy to a flash
│                           # drive and run Install.ps1 from on another machine.
├── VERSION                 # Single source of truth for the version number
├── CHANGELOG.md            # Release history
├── RELEASING.md            # Maintainer release checklist
├── README.md               # User documentation
├── LICENSE                 # MIT License
├── AGENTS.md               # This file
├── .gitignore              # Git ignore rules
│
├── lib/                    # Shared PowerShell helpers
│   ├── DevKit-Common.ps1   # Common functions: path/package-manager helpers, the
│   │                       # project-linking picker, the manifest menu dispatcher,
│   │                       # settings, and the shared confirmation gate
│   ├── DevKit-UI.ps1       # Animation/color engine: capability probe, gradient
│   │                       # text, startup banner, spinner-wrapped scriptblocks
│   ├── DevKit-McpCatalog.ps1  # Curated MCP server catalog + 'claude mcp add' builder
│   ├── DevKit-McpList.ps1     # Parses 'claude mcp list' output, incl. user/project scope split
│   └── DevKit-McpAddFlow.ps1  # Shared interactive add-from-catalog prompt flow
│
├── gui/                    # Desktop GUI (WPF front-end - see "Desktop GUI" below)
│   ├── DevKit-GUI.ps1      # Entry point + code-behind: XAML load, nav/pages,
│   │                       # dialogs, project registry UI, terminal launcher
│   ├── DevKit-GUI.xaml     # Main window layout (loose XAML, parsed by XamlReader)
│   ├── Theme.xaml          # Brand resource dictionary (palette/gradients/styles
│   │                       # from the compass-rose logo); parsed into
│   │                       # Application.Resources before any window XAML loads
│   ├── DevKit-GuiCore.ps1  # Pure logic (Pester-tested): manifest catalog,
│   │                       # search, argument resolution, terminal command builder
│   ├── DevKit-Widget.ps1   # Companion widget: persistent metrics/MCP/status
│   │                       # window + system-tray app (own process, survives
│   │                       # DevKit closing; single-instance + summon event)
│   ├── DevKit-Widget.xaml  # Widget window layout (same loose-XAML pattern)
│   ├── DevKit-WidgetCore.ps1 # Widget pure logic (Pester-tested): system
│   │                       # metrics sensors, node/port snapshot, Claude +
│   │                       # Kimi MCP status collectors and parsers, git log
│   │                       # parsing + graph lane layout, .env drift diff
│   ├── Build-Assets.ps1    # Regenerates Assets/* from Assets/logo.png (dev-time
│   │                       # only; outputs are committed)
│   └── Assets/             # logo.png (master), logo-256.png, logo.ico
│
├── tests/
│   └── Unit/               # Pester tests for pure-logic parsers/converters
│
├── ports/                  # Port management tools (+ _module.psd1)
│   ├── Scan-Ports.ps1      # Scan common dev ports (3000, 5173, etc.)
│   ├── Scan-Ports.bat      # Batch wrapper
│   ├── Kill-Port.ps1       # Kill process by port or PID
│   ├── Kill-AllNode.ps1    # Kill all Node.js processes
│   ├── Show-ExcludedPortRanges.ps1  # Hyper-V/winnat reserved ranges (EACCES/10013)
│   ├── Test-DevEndpoint.ps1  # HTTP health check: status, latency, cert days
│   └── *.bat               # Batch wrapper per script
│
├── node/                   # Node.js utilities (+ _module.psd1)
│   ├── Clear-NpmCache.ps1  # Clear NPM cache
│   ├── Remove-NodeModules.ps1  # Delete node_modules
│   ├── Nuke-And-Reinstall.ps1  # Full reset + reinstall
│   ├── Nuke-And-Reinstall.bat  # Batch wrapper
│   ├── Check-NpmCacheSize.ps1  # Read-only cache-size report per package manager
│   ├── Start-PackageScript.ps1  # Arrow-key picker for package.json scripts
│   ├── Find-StaleNodeModules.ps1  # Size/age report + gated cleanup across projects
│   └── *.bat                   # Batch wrapper per script
│
├── nextjs/                 # Next.js specific tools (+ _module.psd1)
│   ├── Clear-NextCache.ps1     # Clear .next build cache
│   ├── Clear-NextCache.bat     # Batch wrapper
│   ├── Clear-TurboCache.ps1    # Clear Turbopack cache
│   ├── Clear-TurboCache.bat    # Batch wrapper
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
│   ├── Git-SyncFork.bat
│   ├── Get-GitStandup.ps1      # Your recent commits across repos (standup notes)
│   └── Get-GitStandup.bat
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
│   ├── Install-ShellIntegration.ps1    # Opt-in: add "Open Northstar DevKit Here" to Explorer's right-click menu
│   ├── Uninstall-ShellIntegration.ps1  # Opt-in: remove that right-click entry
│   ├── Register-DevKitTerminalProfile.ps1   # Opt-in: register a Windows Terminal profile
│   ├── Unregister-DevKitTerminalProfile.ps1 # Opt-in: remove that Windows Terminal profile
│   ├── Edit-HostsFile.ps1      # View/add/remove/toggle hosts entries (backup + DNS flush)
│   └── *.bat
│
├── workflow/               # Developer workflow tools (+ _module.psd1)
│   ├── Code-Here.ps1           # Open VS Code/Cursor
│   ├── Code-Here.bat
│   ├── Open-Repo.ps1           # Open repo in browser
│   ├── Open-Repo.bat
│   ├── Copy-EnvTemplate.ps1    # Copy .env template
│   ├── Copy-EnvTemplate.bat
│   ├── Compare-EnvFiles.ps1    # .env vs template drift check (keys only, masked)
│   ├── Convert-DevText.ps1     # Base64/URL/timestamp/GUID/SHA-256/JWT converters
│   └── *.bat                   # Batch wrapper per script
│
├── diagnostics/            # Health check tools (+ _module.psd1)
│   ├── DevKit-Doctor.ps1       # Environment health check
│   ├── DevKit-Doctor.bat
│   ├── System-DevInfo.ps1      # System info summary
│   ├── System-DevInfo.bat
│   ├── Test-DevKitUpdate.ps1   # Check for DevKit updates (GitHub Releases)
│   └── Test-DevKitUpdate.bat
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
└── agents/                 # AI CLI & MCP management (+ _module.psd1, 7 items)
    ├── Get-InstalledAiClis.ps1     # Detect 11 tracked CLIs: claude/gh/codex/gemini/
    │                               # cursor-agent/aider/supabase/vercel/railway/kimi/auggie
    ├── Update-AiClis.ps1           # Per-tool channel update (npm/npm+builtin/scoop/manual)
    ├── Get-McpServers.ps1          # claude mcp list, with a real user/global vs project/local -Scope split
    ├── Add-McpServer.ps1           # claude mcp add wrapper (local stdio, or -Transport http remote)
    ├── Remove-McpServer.ps1        # claude mcp remove wrapper
    ├── Add-McpServerFromCatalog.ps1 # Browsable picker over lib/DevKit-McpCatalog.ps1's 10 curated servers
    ├── Scan-McpServers.ps1         # Cross-references configured servers against the catalog, offers to fill gaps
    └── *.bat                       # Batch wrapper per script
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
- Auto-detects package manager (npm/yarn/pnpm/bun) from lock files - both
  bun's legacy binary `bun.lockb` and the modern (>= 1.2) text `bun.lock`
- Executes the correct cache clean command for the detected package manager
- Recursively removes `node_modules` directories using long-path-safe deletion
- Supports `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, and `bun.lockb` cleanup

### Next.js Tools (`nextjs/`)
- Auto-detects package manager (npm/yarn/pnpm/bun) from lock files - both
  bun's legacy binary `bun.lockb` and the modern (>= 1.2) text `bun.lock`
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
  and only changes anything behind `Confirm-DevKitDestructiveAction`. Report-mode tools
  additionally end with an interactive "apply now?" prompt (so batch-file users who can't
  pass flags can still act) - the prompt only collects input and sets the same variables
  the flags would have set, then falls into the existing flag code path unchanged. The
  prompt is guarded by `-not [Console]::IsInputRedirected` so piped/automated runs keep
  the old report-then-exit behavior; keep that guard on any future tool of this shape
- Admin-gated actions check `Test-DevKitAdmin` and fail with a clear message rather than a
  stack trace when not elevated
- Startup-entry disable/enable is reversible by design (registry value rename / shortcut
  moved to a sibling folder), not a best-effort delete

### Agents & MCP (`agents/`)
- Tracks 11 AI/dev CLIs (claude, gh, codex, gemini, cursor-agent, aider, supabase, vercel,
  railway, kimi, auggie) via `Get-DevKitWindowsExecutable` (see below) rather than a bare
  `Get-Command`/`&` invocation; each tool carries its own update "channel" (npm / npm+builtin
  / scoop / manual) instead of assuming everything is an npm package - e.g. Supabase updates
  via Scoop (its CLI can't be installed globally via npm at all), Vercel/Railway prefer their
  own builtin `upgrade` subcommand, and Kimi is manual-only because the `kimi` command name is
  shared by two unrelated real-world tools
- Wraps `claude mcp list/add/remove`; `Add-McpServer.ps1` supports both local stdio commands
  and remote HTTP servers (`-Transport http -Url -Headers`); project-scoped operations resolve
  the active project via `Get-DevKitActiveProject` (read-only) and `Push-Location`/
  `Pop-Location` around the `claude` call, never via `Select-DevKitProject` (which can
  prompt/mutate the active project); `Get-McpServers.ps1 -Scope` diffs a listing run from a
  neutral directory against one run from the project directory to give a real user/global vs.
  project/local split
- `lib\DevKit-McpCatalog.ps1` ships a 10-entry curated catalog of well-known MCP servers
  (Supabase, Sequential Thinking, Context7, GitHub, Filesystem, Notion, Jira/Atlassian, Linear,
  Stripe, Plaid); `Add-McpServerFromCatalog.ps1` is a browsable picker over it and
  `Scan-McpServers.ps1` cross-references what's already configured (per scope) against the
  catalog and offers to add anything missing

### Desktop GUI (`gui/`)
- WPF front-end (`DevKit-GUI.bat` → `gui/DevKit-GUI.ps1`) themed on the company
  compass-rose logo (gunmetal/silver UI, sapphire + ember accents), running on
  both pwsh 7 and Windows PowerShell 5.1 with no external dependencies
- **Purely additive architecture:** no leaf script, manifest, or the TUI is
  modified. The GUI reuses `Get-DevKitModule` to load the same twelve
  `_module.psd1` manifests and re-implements `Invoke-DevKitTool`'s argument
  resolution with dialogs (`gui/DevKit-GuiCore.ps1`'s
  `ConvertTo-DevKitToolArguments` mirrors its semantics exactly - project via
  `ProjectArgName`/`Path`, YesNo-true-only, Optional, StaticArgs last). Adding
  a tool to a manifest makes it appear in the GUI with zero GUI changes.
- Tools **run in a real terminal window** (Windows Terminal via `wt.exe` when
  installed, classic conhost otherwise; pwsh preferred, powershell fallback)
  launched by `Get-DevKitTerminalCommand` with `-NoExit` so quick tools' output
  stays readable. This is deliberate: the scripts' interactive features
  (arrow-key menus via `[Console]::ReadKey`, the runspace spinner, Console API
  probe) bypass PowerShell's host interface and would degrade under an embedded
  PSHost. Never "embed a console" into the GUI at the cost of those features.
- XAML is loose (no x:Class/compiled resources): a `Windows.Application` is
  created FIRST and `Theme.xaml` is parsed into `Application.Resources`
  before the window XAML is loaded - NOT string-merged into the window.
  Application-scope is what lets the keyless styles (ScrollBar, ToolTip,
  CheckBox) reach template-generated elements (every ScrollViewer's
  scrollbars, ComboBox popups) and dialog windows; merging into
  Window.Resources left them in stock light Windows chrome. All dynamic
  content (nav, cards, dialogs) is built in code against `x:Name` handles +
  theme style keys. WPF gotchas already handled:
  STA self-relaunch, `GetNewClosure()` on every event handler that captures
  locals, AllowsTransparency maximize/work-area fix, logo loaded from absolute
  URIs. Keep markup compatible with .NET Framework 4.x WPF (PS 5.1) - nothing
  newer-only.
- `gui/DevKit-GuiCore.ps1` is UI-free and Pester-covered
  (`tests/Unit/GuiCore.Tests.ps1`); keep any new pure logic there so it stays
  testable.

### Companion Widget (`gui/DevKit-Widget.ps1`)
- Persistent desktop/tray app launched (detached, own process) from the GUI's
  gauge button or `gui/DevKit-Widget.ps1` directly - it keeps running after
  DevKit closes. Single-instance via a named mutex; a second launch signals a
  named event that makes the running instance surface its window, so the
  gauge button always brings it up even where the shell hides new tray icons.
- Shows CPU/memory/GPU load with best-effort temperatures (ACPI thermal-zone
  counter, MSAcpi WMI, driver-bundled nvidia-smi - every sensor degrades to
  "n/a", never a fake number), a reboot-pending / long-uptime hint line
  (documented registry sentinels + Win32_OperatingSystem.LastBootUpTime), a
  System Junk radial dial (reclaimable temp + Windows Update cache + Recycle
  Bin bytes, 100% arc = 10 GB, re-scanned in the background every 5 minutes)
  with a safe in-widget clean (temp folder contents + `Clear-RecycleBin` only
  - no service stop/start, no WU cache, no DISM - behind a styled Yes/No
  confirm; the full tool opens via "Cleanup Tool..."), a Disk Free dial next
  to it (`System.IO.DriveInfo` on the system drive; arc = used space, number
  = free, ember under 10% free), a columnar node-process table (NAME / PID /
  MEM / AGE / PORTS, aligned via WPF SharedSizeGroups; each port is a
  click-to-open `http://localhost:<port>` link, each row a confirmed per-pid
  kill button, plus other processes on the common dev ports and a warning
  when common dev ports sit inside Hyper-V/winnat-reserved ranges - parsed
  from `netsh show excludedportrange` via lib's
  `ConvertFrom-DevKitExcludedPortRanges`, cached 30 minutes), two rows of
  quick actions that launch real DevKit tools in terminal windows (cache/port/
  node/doctor + Editor/Explorer/Terminal/Run Script... for the active
  project), and a project selector bound to the same Active Project the
  GUI/TUI share (projects.json is watched for external changes) whose
  permanent last row "+ Add new project..." links a folder via a
  FolderBrowserDialog. Under the selector an ambient git badge shows the
  active project's branch + dirty/ahead/behind/stash counts (refreshed every
  2 minutes via the work runspace), and an ember hint appears when the
  project's `.env` drifts from its template (key-name diff only - values are
  secrets; "Fix..." opens the real Copy-EnvTemplate tool).
- The window is ALWAYS work-area full height, docked or free - the mode only
  sets horizontal placement (Left/Right/Free, persisted as
  `preferences.widgetDockMode`). Invisible 6px grips on the content edges
  drag-resize the width (clamped 340-700, persisted as
  `preferences.widgetWidth`); a title-bar drag always moves the window, and
  dropping it within 24 DIPs of a screen edge docks there while dropping a
  docked widget anywhere else undocks it to Free. The Settings expander sits
  in its own bottom grid row and expands upward over the content. Position
  math uses WPF DIP work-area units, never WinForms pixels.
- A title-bar GIT button opens the GitHub flyout for the active project
  (greyed out when none is selected): a 300px panel that grows the window
  INTO the screen (a docked-right window shifts left first, restored on
  close) showing branch + ahead/behind, a DRAWN commit graph (not text:
  `Get-DevKitRepoOverview` parses `git log --all --topo-order -n 40` with
  record/unit separators, `ConvertTo-DevKitGitGraphLayout` assigns lanes -
  the first-parent trunk stays a straight vertical, side branches bend into
  it - and `Render-DevKitGitGraph` draws gradient S-curve links, bright lane
  nodes with a HEAD ring, and branch/tag pills on a Canvas), fetch/pull/push
  buttons (last output line lands in a status line, ember on failure),
  open-on-GitHub/Actions (origin URL run through Open-Repo's
  `ConvertTo-DevKitBrowsableUrl`, never the raw value), and a Git Cleanup
  tool shortcut. All git and junk work shares a third MTA runspace with a
  busy flag + 30s timeout; a job declined while busy re-fires on completion
  (project switches never leave stale graphs), and a result collected for a
  since-switched project is discarded rather than rendered. The collectors
  (`Get-DevKitSystemJunk`, `Clear-DevKitSystemJunk`, `Get-DevKitRepoOverview`,
  `Invoke-DevKitGitAction`) live in `DevKit-WidgetCore.ps1` and degrade to
  honest notes ("Not a git repository", "git not found"), never fake data.
- Claude Code MCP status uses the documented `claude mcp list` health output
  via `lib/DevKit-McpList.ps1` (never Claude's internal JSON); Kimi Code has
  no headless status command, so its badges come from the documented
  `~/.kimi-code/mcp.json` / `<project>/.kimi-code/mcp.json` files and say
  CONFIGURED/DISABLED/REQUIRES AUTH (missing bearer-token env var) rather
  than claiming live connection state. Both agents nest under one AGENTS
  expander, and each panel's "Manage..." dialog summarizes the last report
  and offers Connect / Re-check (the honest "connect": Claude's real
  `claude mcp list` health check, Kimi's config re-read), Sign In /
  Authenticate (launches the CLI in a terminal window), Scan & Fix MCP Gaps
  and Add Server from Catalog (the real agents/ tools), Claude-only
  Disconnect a Server, and Kimi-only Open Config File. MCP checks run in a
  background runspace with a 45s timeout so the widget never freezes.
- Tray: WinForms `NotifyIcon` + dark-rendered context menu (Show/Hide, Open
  DevKit, reversible "Start with Windows" HKCU Run-key toggle, Exit), balloon
  hints, and a `TaskbarCreated` broadcast hook that re-registers the icon
  after an Explorer restart. Closing the widget window only hides it; Exit
  lives in the tray menu.
- `gui/DevKit-WidgetCore.ps1` is the UI-free, Pester-covered core
  (`tests/Unit/WidgetCore.Tests.ps1`) - same separation as the GUI core.
- WPF/WinForms pitfalls already handled here: STA relaunch, `GetNewClosure()`,
  WPF DIP units for positioning (NOT WinForms pixel units - breaks on
  DPI-scaled displays), and off-screen-aware UI behavior.

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
template parser, the git-remote-to-browsable-URL converter, the WiFi
scan parser, the GUI/widget cores (argument rendering, MCP/Kimi parsers,
nvidia-smi parser, git log parser + graph lane layout, .env key diff),
the winnat excluded-port-ranges parser, the .env key extractor, and the
Convert-DevText converters. Run locally with:

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
`diagnostics/`, `wifi/`, `maintenance/`, `agents/`) is a manifest edit, not a `DevKit.ps1` edit:

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
- Version 3.5 (see `CHANGELOG.md`) added a gradient animation/color engine (`lib\DevKit-UI.ps1`: a fail-closed capability probe, a startup banner shown once per session, and a Runspace-backed spinner for long-running scriptblocks) plus in-menu help (`Description`/`Help` keys in every `_module.psd1`, a `?` entry per category, and a Main Menu "Getting Started" entry); expanded AI-CLI tracking from 6 to 11 tools with a real per-tool update channel (npm/npm+builtin/scoop/manual) instead of assuming npm everywhere; and added a 10-entry curated MCP server catalog (`lib\DevKit-McpCatalog.ps1`) with a browsable add-from-catalog flow and a scan-and-fill-gaps tool, alongside real HTTP/remote MCP server support and a genuinely-scoped `Get-McpServers.ps1 -Scope`
- Version 3.6 (see `CHANGELOG.md`) added the branded desktop GUI (`gui/` + root `DevKit-GUI.bat`): a dependency-free WPF shell themed on the company compass-rose logo that renders the same twelve `_module.psd1` manifests as navigable tool cards with search, linked-project management, and validated input dialogs, and launches tools in a real terminal window (Windows Terminal or conhost) so every script's existing interactivity keeps working byte-for-byte unchanged. Pure logic lives in `gui/DevKit-GuiCore.ps1` with Pester coverage; brand assets are generated from `gui/Assets/logo.png` by `gui/Build-Assets.ps1`.
- Version 3.7 (see `CHANGELOG.md`) added the companion widget (`gui/DevKit-Widget.ps1`, launched from the GUI's gauge button): a persistent desktop + system-tray app with live CPU/memory/GPU metrics and best-effort temperatures, a node-process/port watch, quick-action buttons that launch real DevKit tools, an Active Project selector, and expandable Claude Code / Kimi Code CLI + MCP status boxes with Connected/Disconnected/Requires Auth badges (Claude via `claude mcp list` health output, Kimi via its documented `mcp.json` files) - single-instance with a summon event, TaskbarCreated re-registration, and a reversible Start-with-Windows toggle.
- Version 3.8 (see `CHANGELOG.md`) turned the widget into the primary surface: a drawn commit graph (lane layout + gradient S-curves + ref pills) replaced the monospace `git log --graph` text, and the widget gained a Disk Free dial, process ages + per-pid kill + click-to-open ports in the node table, an ambient git badge and .env-drift hint under the project selector, a reboot-pending hint, winnat reserved-port warnings, and four project launchers (Editor/Explorer/Terminal/Run Script...). Both WPF apps moved the theme from a Window.Resources string-merge to Application.Resources created before XAML load (fixes unthemed scrollbars/dialogs). Eight new tools shipped: Show-ExcludedPortRanges + Test-DevEndpoint (ports/), Get-GitStandup (git/), Start-PackageScript + Find-StaleNodeModules (node/), Edit-HostsFile (system/), Compare-EnvFiles + Convert-DevText (workflow/). It also fixed two long-standing HIGH bugs: the Agents "Manage..." dialog never attached its content (invisible modal), and the MCP libs' `$global:` load-guards crashed every second menu use in one session; plus Env-Restore no longer overwrites live secrets with the `***REDACTED***` marker, and bun >= 1.2's `bun.lock` is detected everywhere.
