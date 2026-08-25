# Northstar DevKit - Agent Documentation

## Project Overview

**Northstar DevKit** is a comprehensive PowerShell-based Windows toolkit for web developers. It provides utilities for port management, Node.js/Next.js/Vite cache clearing, Git repository management, Docker container cleanup, system environment management, and WiFi network optimization.

- **Created by:** Northstar Software Development
- **Website:** https://www.northstarcoding.com
- **License:** MIT
- **Language:** English (all comments and documentation)
- **Version:** 4.0.0

## Technology Stack

- **Primary Language:** PowerShell 5.1+ or PowerShell 7+ (pwsh)
- **Secondary:** Batch files (.bat) as wrappers for GUI/click execution
- **Platform:** Windows 10/11
- **No external dependencies:** Uses built-in Windows PowerShell cmdlets and system utilities

## Project Structure

```
DevKit/
├── Widget.bat              # MAIN ENTRY POINT: launches the companion widget
│                           # windowlessly via gui/Start-Widget-Startup.vbs
│                           # (delay arg 0). The widget IS the app's main face
│                           # since 4.0 - installed shortcuts point here too.
├── DevKit.bat              # Terminal menu launcher (secondary surface)
├── DevKit.ps1              # Interactive menu - Main Menu + Projects menu are
│                           # hand-written; the twelve tool-category submenus are
│                           # generic, driven by each folder's tools/<cat>/_module.psd1
├── DevKit-GUI.bat          # Control Center launcher (batch wrapper for
│                           # gui/DevKit-GUI.ps1) - the full toolkit GUI,
│                           # opened from the widget's DEVKIT title-bar button
├── Install.ps1 / .bat      # Real stepped installer: per-user (no admin),
│                           # copies to %LOCALAPPDATA%\Programs\NorthstarDevKit,
│                           # registers Apps & Features (HKCU Uninstall key),
│                           # widget-first shortcuts, PATH, optional
│                           # start-with-Windows + opt-in integrations.
│                           # Re-running over an install is the upgrade path.
├── Uninstall.ps1           # Full uninstaller (the Apps & Features entry runs
│                           # this): stops the widget, removes integrations/
│                           # Run-key/PATH/shortcuts/ARP entry/install dir
│                           # (guarded by the .northstar-installed marker so a
│                           # source checkout can never be deleted) + app data.
├── VERSION                 # Single source of truth for the version number
├── CHANGELOG.md            # Release history
├── README.md               # User documentation
├── LICENSE                 # MIT License
├── AGENTS.md               # This file
├── .gitignore              # Git ignore rules
├── desktop.ini             # Explorer folder icon (gui/Assets/logo.ico)
│
├── gui/                    # Desktop apps (WPF front-ends - see below)
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
│   │                       # parsing + graph lane layout, .env drift diff,
│   │                       # the per-project notes/on-deck JSON stores, the
│   │                       # Files flyout's enumeration/path helpers, and the
│   │                       # file-name -> icon-key/color mapping
│   ├── DevKit-WidgetIcons.ps1 # Built-in vector icon set (UI-side ONLY, never
│   │                       # in the background runspaces): frozen cached
│   │                       # DrawingImages for the Files flyout + git graph pills
│   ├── Build-Assets.ps1    # Regenerates Assets/* from Assets/logo.png (dev-time
│   │                       # only; outputs are committed)
│   └── Assets/             # logo.png (master), logo-256.png, logo.ico
│
├── tools/                  # ALL tool categories + the shared lib (4.0 layout -
│                           # repo root stays clean; leaf scripts resolve lib as
│                           # ..\lib relative to themselves, so they are unchanged)
│   ├── lib/                    # Shared PowerShell helpers
│   │   ├── DevKit-Common.ps1   # Common functions: path/package-manager helpers, the
│   │   │                       # project-linking picker, the manifest menu dispatcher,
│   │   │                       # settings, and the shared confirmation gate
│   │   ├── DevKit-UI.ps1       # Animation/color engine: capability probe, gradient
│   │   │                       # text, startup banner, spinner-wrapped scriptblocks
│   │   ├── DevKit-McpCatalog.ps1  # Curated MCP server catalog + 'claude mcp add' builder
│   │   ├── DevKit-McpList.ps1     # Parses 'claude mcp list' output, incl. user/project scope split
│   │   └── DevKit-McpAddFlow.ps1  # Shared interactive add-from-catalog prompt flow
│   │
│   ├── ports/                  # Port management tools (+ _module.psd1)
│   ├── node/                   # Node.js utilities (+ _module.psd1)
│   ├── nextjs/                 # Next.js specific tools (+ _module.psd1)
│   ├── vite/                   # Vite tools (+ _module.psd1)
│   ├── git/                    # Git tools (+ _module.psd1)
│   ├── docker/                 # Docker tools (+ _module.psd1)
│   ├── system/                 # System environment tools (+ _module.psd1)
│   ├── workflow/               # Developer workflow tools (+ _module.psd1)
│   ├── diagnostics/            # Health check tools (+ _module.psd1)
│   ├── wifi/                   # WiFi optimization tools (+ _module.psd1)
│   ├── maintenance/            # Windows maintenance/tuning (+ _module.psd1)
│   └── agents/                 # AI CLI & MCP management (+ _module.psd1)
│                               # (per-script details: see "Key Features by Module")
│
├── tests/
│   └── Unit/               # Pester tests for pure-logic parsers/converters
│
└── dev/                    # Maintainer-only tooling (excluded from installs
    │                       # and USB builds)
    ├── Build-UsbPortable.ps1 / .bat  # Mirrors the repo into USB/ (gitignored,
    │                       # regenerated on demand) with dev-only clutter
    │                       # stripped (.git/.kimi/.github/tests/dev/editor
    │                       # folders) - the result is what you copy to a flash
    │                       # drive and run Install.ps1 from on another machine.
    └── RELEASING.md        # Maintainer release checklist
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

### Port Tools (`tools/ports/`)
- **Common ports scanned:** 3000, 3001, 3002, 3003, 5173, 5174, 8000, 8080, 8081, 9000, 4200, 5000, 5500, 1337, 5432, 3306, 6379, 27017
- Uses `Get-NetTCPConnection` for port detection
- Uses `Get-Process` and `Stop-Process` for process management

### Node.js Tools (`tools/node/`)
- Auto-detects package manager (npm/yarn/pnpm/bun) from lock files - both
  bun's legacy binary `bun.lockb` and the modern (>= 1.2) text `bun.lock`
- Executes the correct cache clean command for the detected package manager
- Recursively removes `node_modules` directories using long-path-safe deletion
- Supports `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, and `bun.lockb` cleanup

### Next.js Tools (`tools/nextjs/`)
- Auto-detects package manager (npm/yarn/pnpm/bun) from lock files - both
  bun's legacy binary `bun.lockb` and the modern (>= 1.2) text `bun.lock`
- Removes `.next/` build cache directory
- Clears Turbopack cache from `.next/cache`, `node_modules/.cache`, `.turbo`
- Runs the detected package manager's dev command after cache clearing
- Disables Next.js telemetry: `$env:NEXT_TELEMETRY_DISABLED = "1"`

### Vite Tools (`tools/vite/`)
- Clears `.vite/` cache directory and build artifacts
- Supports custom port configuration
- Build and preview production builds

### Git Tools (`tools/git/`)
- Prunes merged branches with `git branch -d`
- Runs garbage collection with `git gc --aggressive`
- Optionally clears reflog
- Scans multiple repositories for status
- Syncs forks with upstream using merge or rebase

### Docker Tools (`tools/docker/`)
- Uses `docker ps`, `docker rm`, `docker rmi`, `docker volume rm` for cleanup
- Supports dry-run mode for safety
- Multi-container log tailing with color coding
- Selective cleanup of dangling images and unused volumes

### System Tools (`tools/system/`)
- Uses `[Environment]::GetEnvironmentVariable` and `SetEnvironmentVariable`
- Supports both User and Machine environment scopes
- Interactive PATH editor with duplicate detection
- JSON backup/restore for environment variables

### Workflow Tools (`tools/workflow/`)
- Detects VS Code and Cursor installations
- Opens repositories in browser (GitHub, GitLab, Bitbucket, Azure DevOps)
- Parses `.env.example` templates for variable extraction
- Converts SSH URLs to HTTPS for browser opening

### Diagnostics (`tools/diagnostics/`)
- Checks tool installations and versions
- Validates Git configuration
- Detects Docker daemon status
- Reports disk space and memory
- Exports system info to JSON

### WiFi Tools (`tools/wifi/`)
- Uses `netsh` commands for network operations
- Uses `Get-NetAdapter` and `Set-DnsClientServerAddress` for DNS management
- Cloudflare DNS (1.1.1.1 / 2606:4700:4700::1111) and Google DNS (8.8.8.8 / 2001:4860:4860::8888) testing
- Speed test via Cloudflare's speed endpoint
- Requires administrator privileges; warns about required reboot after TCP/IP reset

### Maintenance (`tools/maintenance/`)
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

### Agents & MCP (`tools/agents/`)
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
- `tools\lib\DevKit-McpCatalog.ps1` ships a 10-entry curated catalog of well-known MCP servers
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
- **Since 4.0 the widget is the app's MAIN FACE.** Root `Widget.bat` and every
  installed shortcut open it (windowlessly, via `gui/Start-Widget-Startup.vbs`);
  the full toolkit GUI ("Control Center", `DevKit-GUI.bat`) opens from the
  widget's title-bar DEVKIT button, the Quick Actions "Open DevKit Control
  Center" button, or the tray menu. It is also launchable (detached, own
  process) from the GUI's gauge button or `gui/DevKit-Widget.ps1` directly -
  it keeps running after DevKit closes. Single-instance via a named mutex; a
  second launch signals a named event that makes the running instance surface
  its window, so the app icon always brings it up even where the shell hides
  new tray icons.
- **Performance architecture (4.0 lightweight pass - keep these invariants):**
  the three background runspaces dot-source `tools\lib` + `DevKit-WidgetCore.ps1`
  ONCE at creation via `New-DevKitWidgetRunspace` (jobs are bare collector
  calls), which also keeps WidgetCore's `$script:` sensor caches alive between
  jobs - never go back to per-job dot-sourcing (it re-parses ~150KB every
  cycle AND wipes the caches). Gauge arcs are assigned from a frozen cached
  0-100% geometry table (`Get-DevKitGaugeGeometry`) - never allocate geometry
  per frame, and there is deliberately no easing/animation timer. The Files/
  git-graph icons keep the same discipline: `Get-DevKitIconDrawing`
  (DevKit-WidgetIcons.ps1) builds each glyph ONCE per key, freezes the whole
  DrawingImage, and hands the shared instance to every tree row and pill -
  per-use cost is one lightweight Image element, never new geometry. Gauge arcs
  carry NO DropShadowEffect, and the ToolCard hover is an instant brush swap
  with NO storyboard/transform animation (animating transforms over
  effect-bearing children inside these AllowsTransparency windows forced a
  full-window recomposite per frame - that was the "hover the gauges, CPU/GPU
  spikes" bug). FastTimer/SlowTimer STOP when the window hides to the tray
  (`Hide-DevKitWidget`) and resume + refresh on `Show-DevKitWidget` - a hidden
  widget must cost ~nothing (only the trivial 750ms SummonTimer wait keeps
  running, since it's the wake-up path). The node table's rebuild signature
  uses bucketed values (25MB memory / 5-minute age) so a rebuild only happens
  on real structural change.
- Shows CPU/memory/GPU load with best-effort temperatures (ACPI thermal-zone
  counter, MSAcpi WMI, driver-bundled nvidia-smi - every sensor degrades to
  "n/a", never a fake number), a reboot-pending / long-uptime hint line
  (documented registry sentinels + Win32_OperatingSystem.LastBootUpTime). The
  three gauges are CLICKABLE (hand cursor, "Click to manage") - each slides
  out a themed management PANEL (the shared `ProcFlyout`, re-titled per kind;
  `Show-DevKitProcessDialog -Kind Cpu|Mem|Gpu` is now a toggle) that joins
  the single-flyout carousel: CPU lists the top processes by usage with SAFE
  TO CLOSE / CAUTION / LEAVE ALONE badges (`Get-DevKitProcessClassification`
  in WidgetCore) and per-row kills (`Stop-DevKitProcessById` refuses
  System-classified pids server-side too), MEM adds the used/total summary
  and a "Free Memory" button (`Invoke-DevKitFreeMemory` - psapi
  EmptyWorkingSet across non-System processes, reports freed MB), GPU shows
  the adapter summary (nvidia-smi name/util/temp/VRAM when present) plus
  per-process GPU usage parsed from the '\GPU Engine(*)' counters
  (`ConvertFrom-DevKitGpuEngineInstance`). A proc panel refreshes every 3s
  while open only (timer created per open, stopped on close), via the
  Start-DevKitWorkJob kinds ProcCpu/ProcMem/ProcGpu/FreeMem/ProcKill, and
  Hide-DevKitWidget closes any open panel since its result polls ride the
  FastTimer.
  Below the gauges: a System Junk radial dial (reclaimable temp + Windows
  Update cache + Recycle Bin bytes, 100% arc = 10 GB, re-scanned in the
  background every 30 minutes) with a FULLY in-widget clean behind a styled
  Yes/No confirm - user temp + Recycle Bin always, Windows\Temp and the WU
  download cache when elevated (per-category freed breakdown in the status
  line, ember hint naming the admin-only areas it had to skip; only
  DISM/WinSxS and service stop/start remain exclusive to the terminal
  Clear-DiskJunk tool) - and a "Details..." dialog showing the per-category
  scan breakdown. NO cleanup path opens a terminal or asks for typed input
  anymore. A Disk Free dial next
  to it (`System.IO.DriveInfo` on the system drive; arc = used space, number
  = free, ember under 10% free), a columnar node-process table (NAME / PID /
  MEM / AGE / PORTS, aligned via a shared pixel-width dictionary that the
  header's always-visible 2px drag bars resize (sapphire on hover, session-
  only widths); the list caps at 6 rows with a clickable "+N more"/"Show
  less" footer that re-renders on click from the last snapshot; each port is
  a click-to-open `http://localhost:<port>` link, each row a confirmed
  per-pid kill button, plus other processes on the common dev ports and a
  warning
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
- Side panels (4.0 panel architecture): the root grid is SEVEN columns -
  TermWest | TabWest | FlyoutWest | Main(FIXED px) | FlyoutEast | TabEast |
  TermEast. The vertical side-tab strip is SECTION-ANCHORED, not a centered
  stack: the tabs sit on a full-height Canvas (SideTabCanvas) as two groups -
  FILES+GIT, and NOTES+ON DECK (the small separators ride inside their
  groups, the tall one at the NOTES+ON DECK group's top) - plus the TERMINAL
  tab below them, and Update-DevKitSideTabLayout places each group ACROSS
  FROM its body section in the UN-SCROLLED layout (FILES/GIT centered on the
  CPU/MEM/GPU gauges card, NOTES/ON DECK on the SYSTEM JUNK/drives card,
  TERMINAL on QUICK ACTIONS). Positions are FIXED while the body scrolls:
  Get-DevKitAnchorCenterY reads each anchor with ContentScroll's live
  VerticalOffset added back (scroll-offset-zero reading), there is NO
  ScrollChanged hook and no timer, and recomputes happen only on structural
  changes (window SizeChanged, BodyContent LayoutUpdated, ContentRendered).
  Resolve-DevKitSideTabTops clamps: fixed stack order, a minimum gap between
  groups (never overlap), never above/below the strip, and on very short
  windows the gaps give first, then the stack compresses - never off-screen.
  The math is Y-only, so both dock sides behave identically. A full-height
  2px brand-gradient hairline (SideTabDivider, BrushAccentGradientVertical at
  50% opacity) marks the strip's widget-facing edge; its alignment flips
  with the dock side along with the strip (Set-DevKitWidgetDock), and the
  strip column is 26px (24 tabs + 2 divider) - WidgetChromeWidth accounts
  for it. The carousel rule:
  at most one of GIT/NOTES/FILES/ON DECK/proc-panel is open at a time
  (opening one instant-closes the others). The TERMINAL panel is the ONE
  exception - fully independent, always outermost (its own dedicated
  columns), so e.g. GIT and the terminal can be open side by side.
  Geometry invariant: every Set-DevKit*Flyout sets its open flag BEFORE
  computing targets and derives window width/left from the flags
  (`Get-DevKitWidgetPanelExtra`), never from live animated values - that is
  what lets an independent terminal slide and a carousel slide overlap and
  still converge; do not regress to reading live geometry. Panel widths
  persist as `preferences.filesFlyoutWidth` / `onDeckFlyoutWidth` /
  `gitFlyoutWidth` / `procFlyoutWidth` / `terminalFlyoutWidth` via the
  grip-drag machinery (Kinds Files/OnDeck/Git/Proc/Terminal).
- The TERMINAL side tab (cyan `TerminalTabButtonWest/East` styles in
  Theme.xaml, anchored across from the QUICK ACTIONS section below the
  carousel groups - its panel is the independent one) hosts a REAL terminal
  inside the panel (it replaced the old
  embedded runspace REPL): opening the tab launches Windows Terminal
  (`wt.exe -w new`, with the registered "Northstar DevKit" fragment profile
  when present, else the default profile) when available, else a classic
  pwsh/powershell console window (pwsh preferred), starting in the active
  project's folder (DevKit root + dim note when none). The launched window's
  chrome is stripped and the WIDGET BECOMES ITS OWNER (`GWL_HWNDPARENT`) -
  deliberately NOT a SetParent'd HwndHost child, because a child HWND can
  never render inside the widget's AllowsTransparency layered window - and a
  40ms DispatcherTimer (TermSyncTimer, running ONLY while a session is
  hosted and the widget is visible) glues it over the panel's
  TermHostSurface via live PointToScreen rects, so slides/dock flips/grip
  resizes/drags all track; interactive CLIs (kimi, claude) work because it
  IS a normal terminal with real Win32 focus. The hosted window's
  WS_EX_TOPMOST is kept identical to the widget's pin state (set on attach,
  re-asserted every sync tick): an owned window that is not itself topmost
  sinks BELOW a topmost owner - that was the "terminal invisible while
  pinned" bug. Window discovery is a before/after EnumWindows diff on BOTH
  CASCADIA and ConsoleWindowClass - never Process.MainWindowHandle, which
  stays 0 when the machine's default-terminal delegation routes a bare shell
  launch into Windows Terminal (the conhost fallback then hosts that WT
  window and treats it as wt-kind). Lifecycle: the session belongs
  to the panel - closing the panel closes it (WM_CLOSE, then a one-shot
  kill-timer backstop: process-tree kill for the conhost shell; for WT only
  after re-verifying owner+pid and only when its PID owns no other window),
  a project switch while open RESTARTS
  the session in the new root (Set-DevKitTermLocation), widget hide only
  hides the window (the session survives), widget exit closes it. The sync
  timer is also the watchdog (a session whose window vanished = "terminal
  session ended" note + Restart button) and un-minimizes the window (WT's
  own title-bar buttons survive the chrome strip). Honest limitations
  (documented in the section comment): WT keeps its own tab strip; a
  just-launched window can flash at its default position for ~0.2-1s before
  the HWND poll glues it; a hard-KILLED widget (not tray Exit) can leave the
  hosted window behind unowned; when neither wt.exe nor a PowerShell
  executable exists (or no window appears within 15s) the panel shows an
  honest "could not host a terminal here" note instead of a fake console.
- The GIT side tab opens the GitHub flyout for the active project
  (greyed out when none is selected): a 300px panel that grows the window
  INTO the screen (a docked-right window shifts left first, restored on
  close) showing branch + ahead/behind, a DRAWN commit graph (not text:
  `Get-DevKitRepoOverview` parses `git log --all --topo-order -n 40` with
  record/unit separators, `ConvertTo-DevKitGitGraphLayout` assigns lanes -
  the first-parent trunk stays a straight vertical, side branches bend into
  it - and `Render-DevKitGitGraph` draws gradient S-curve links, bright lane
  nodes with a HEAD ring, and branch/tag pills on a Canvas - each pill now
  leading with a small glyph from the built-in icon set: git-branch / git-tag
  / git-head (frozen shared DrawingImages, so pills add no per-render geometry
  allocations; lane/layout math is untouched), fetch/pull/push
  buttons (last output line lands in a status line, ember on failure),
  open-on-GitHub/Actions (origin URL run through Open-Repo's
  `ConvertTo-DevKitBrowsableUrl`, never the raw value), and a Git Cleanup
  tool shortcut. The content area is a Commits | PRs | Issues tab strip
  (`Set-DevKitGitActiveTab`, lazy `gh`-backed fetches with per-tab staleness
  tracking), and every section expands/collapses with the same header-click
  + chevron treatment (the shared Expander template in Theme.xaml): the
  Commits tab's UNCOMMITTED CHANGES and COMMIT GRAPH expanders carry live
  count badges and are EXPANDED by default on every flyout open (the whole
  tab scrolls; the graph's own ScrollViewer is horizontal-only). The default-
  expansion is applied in code in `Set-DevKitGitFlyout`'s open path, NOT as
  markup `IsExpanded="True"`: the theme's Expander template reveals content
  via the Expanded EVENT's storyboard (ExpandSite starts Collapsed/ScaleY 0),
  so markup-initial expansion never fires the event and the content stays
  hidden forever. Clicking a commit row on the graph toggles an inline
  details card under that row (full hash, author/date, FULL message, and a
  `git show --numstat --shortstat` files summary): per-row transparent hit
  rects on the canvas call `Show-DevKitCommitDetails`, which fetches via a
  `CommitDetails` work-runspace job (`Get-DevKitCommitDetails` +
  `ConvertFrom-DevKitGitShow` in WidgetCore, Pester-covered), re-rendering
  the canvas with lower rows shifted down by the card's measured height.
  Selection survives graph refreshes (re-injected on every render while the
  hash is in the 40-commit window) and resets on project switch. Each open
  PR/issue is a
  collapsed-by-default accordion (`Add-DevKitPrRow`/`Add-DevKitIssueAccordion`)
  whose body carries the meta line + an Open-on-GitHub button. All git and
  junk work shares a third MTA runspace with a
  busy flag + 30s timeout; a job declined while busy re-fires on completion
  (project switches never leave stale graphs), and a result collected for a
  since-switched project is discarded rather than rendered. The collectors
  (`Get-DevKitSystemJunk`, `Clear-DevKitSystemJunk`, `Get-DevKitRepoOverview`,
  `Invoke-DevKitGitAction`) live in `DevKit-WidgetCore.ps1` and degrade to
  honest notes ("Not a git repository", "git not found"), never fake data.
- A FILES side tab (beside GIT/NOTES/ON DECK in the same SideTabStack) opens
  the Files flyout - a mini VS Code-style explorer of the active project's
  root folder (greyed out when no project is selected). The dark TreeView
  (FilesTreeView/FilesTreeViewItem + FilesContextMenu styles in Theme.xaml)
  lazy-loads one directory level per expansion via `Get-DevKitDirChildren`
  (folders first, then files, case-insensitive alpha; a dummy child keeps the
  closed expander arrow, enumeration errors degrade to a greyed "access
  denied" node, nothing ever auto-recurses), caches loaded children, and
  restores expanded folders across a rebuild (the expansion set is live
  root-relative paths maintained by the Expanded/Collapsed handlers). EVERY
  open of the panel re-enumerates from disk through that same rebuild (the
  Refresh button's exact path), so a reopened panel never shows a stale tree
  cached from before it was closed.
  Every row leads with a type icon from the built-in icon set
  (`Get-DevKitFileIconInfo`'s pure name -> key/color mapping in
  DevKit-WidgetCore.ps1 -> `Get-DevKitIconDrawing`'s frozen cached
  DrawingImage in DevKit-WidgetIcons.ps1 - 40+ Material-style glyphs:
  folder/folder-open, per-language pages in Material-palette colors, and
  drawn specials for image/archive/sql/config/env/docker/git/lock/bat/exe/
  txt/html/xml/ps1/vue). The icon Image is always header.Children[0]; the
  Expanded/Collapsed handlers swap its Source between the frozen
  'folder'/'folder-open' instances - a pointer swap, zero allocation.
  Double-click toggles folders / shell-opens files; the toolbar offers New
  File / New Folder / Refresh / Collapse All (acting on the selection, or
  the root), and every node has a right-click menu (Open, Open in Explorer
  via `explorer.exe /select`, Open in Editor - folders go through the real
  Code-Here tool, files launch code/cursor directly, Copy/Cut/Paste, New
  File/Folder Here, Rename..., Delete, Copy Full/Relative Path) with a
  project-level menu on the empty background. Cut/Copy/Paste are an
  INTERNAL clipboard (no Windows file-clipboard interop): collisions get
  Explorer's " - Copy" suffix via `Get-DevKitCopyName`, cut dims the item
  until pasted or Esc-cancelled, and a folder can never be pasted into
  itself. Safety: every mutating op re-validates containment with
  `Test-DevKitPathWithinRoot` (full-path normalized, so `..` escapes fail),
  names are validated in-dialog by `Get-DevKitSafeChildName`, Delete goes to
  the RECYCLE BIN (Microsoft.VisualBasic FileIO, SendToRecycleBin) behind
  the styled Yes/No confirm, and failures land in the flyout's status line
  (ember on error), never a crash. The panel shares the Git/Notes flyout
  machinery wholesale - same slide animation and anim token, same dock-side
  column/style/grip flips, same grip-drag resize (Kind 'Files', width
  persisted as `preferences.filesFlyoutWidth`). Only one CAROUSEL flyout is
  open at a time (the TERMINAL panel is the independent exception). The pure
  logic (`Get-DevKitDirChildren`,
  `Test-DevKitPathWithinRoot`, `Get-DevKitSafeChildName`,
  `Get-DevKitCopyName`, `Get-DevKitRelativePath`, `Get-DevKitFileIconInfo`)
  lives in `DevKit-WidgetCore.ps1` with Pester coverage; all WPF tree building stays
  in `DevKit-Widget.ps1`.
- The NOTES side tab opens the per-project sticky-notes flyout (notes.json
  in `%LOCALAPPDATA%\NorthstarDevKit`, keyed by a canonical project path).
  Notes render as COLLAPSED title cards by default - one line, ellipsis,
  the title derived from the body's first line by `Get-DevKitNoteTitle`,
  with the same two-step delete the editor has. Clicking a card expands it
  into the full editor (borderless multiline TextBox with the debounced
  autosave); saving via the editor's Done button or clicking/focusing away
  (a LostFocus check plus a flyout-level PreviewMouseLeftButtonDown,
  guarded by the `Test-DevKitWidgetWithin` visual-tree ancestry walk so
  clicking the card's own buttons never counts as "away") collapses it
  back, flushing pending edits first. Only one note is expanded at a time.
  The notes.json schema is unchanged - no title field on disk, nothing
  migrates, older widget builds read the same file.
- A fourth ON DECK side tab (violet accent, OnDeckTabButtonWest/East in
  Theme.xaml) opens a per-project to-do list (ondeck.json beside
  notes.json, same canonical project keying, same corrupt/missing-file =
  start-empty posture, saved on every mutation). An add-row (Add button or
  Enter) lands new items at the top of NOT STARTED; three fixed sections
  (NOT STARTED / IN PROGRESS / DONE) show live counts and a subtle "No
  items" hint when empty. Each row has a status cycle button (glyph colored
  by state) and a right-click status menu in the FilesContextMenu styling
  (current status disabled) - the stored list is always kept section-
  grouped by `Group-DevKitOnDeckItems`, so a status change moves the item
  to its new section on the re-render with no manual reordering. Done rows
  are dimmed + strikethrough, and the DONE header has a "Clear Done"
  button. Delete is a single deliberate click on the row's small x (or the
  context menu), never a plain row click. The panel reuses the same flyout
  machinery (Kind 'OnDeck', width persisted as
  `preferences.onDeckFlyoutWidth`) and reloads on project switch like the
  other flyouts. The pure logic (`Get/Save-DevKitProjectOnDeck`,
  `Add-DevKitOnDeckItem`, `Remove-DevKitOnDeckItem`,
  `Set-DevKitOnDeckItemStatus`, `Clear-DevKitOnDeckDone`,
  `Group-DevKitOnDeckItems`) lives in `DevKit-WidgetCore.ps1` with Pester
  coverage in `tests/Unit/WidgetCore.Tests.ps1`.
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
  DevKit Control Center, reversible "Start with Windows" HKCU Run-key toggle,
  Exit), balloon
  hints, and a `TaskbarCreated` broadcast hook that re-registers the icon
  after an Explorer restart. The Run entry points at
  `gui/Start-Widget-Startup.vbs`, which launches non-blocking and confirms
  success via a pid-file handshake (the widget writes
  `%LOCALAPPDATA%\NorthstarDevKit\widget.pid` once its window is up),
  retrying up to 3 times with a backoff instead of waiting on a process that
  may be stuck behind a loader-error dialog; the widget self-heals the Run
  value at startup when it points at a moved/deleted .vbs (registration
  failures surface via balloon tip), and Install.ps1 repairs it after a
  reinstall. Closing the widget window only hides it; Exit
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
.\tools\ports\Kill-Port.ps1 -Port 3000
.\tools\node\Nuke-And-Reinstall.ps1 -Path "C:\my-project"
.\tools\nextjs\Next-DevFresh.ps1 -Port 3001
.\tools\vite\Vite-DevFresh.ps1
.\tools\git\Git-Cleanup.ps1 -DryRun
.\tools\docker\Docker-Nuke.ps1 -DryRun
.\tools\system\Edit-Path.ps1 -Show
.\tools\diagnostics\DevKit-Doctor.ps1
.\tools\wifi\WiFi-Optimize.ps1 -Fast
```

### Batch Wrapper Execution
```batch
.\tools\ports\Scan-Ports.bat
.\tools\git\Git-Cleanup.bat
.\tools\docker\Docker-Nuke.bat
.\tools\diagnostics\DevKit-Doctor.bat
.\tools\wifi\WiFi-Optimize.bat
```

## Security Considerations

- **Administrator privileges** are required for:
  - WiFi optimization features (script checks and warns if not admin)
  - Editing system (Machine) PATH
  - Restoring Machine environment variables
- Batch wrappers use `-NoProfile -ExecutionPolicy Bypass` for fast, predictable launches
- All scripts use `ErrorAction SilentlyContinue` where appropriate to prevent unnecessary failures
- Force flags (`-Force`) are available to skip confirmation prompts for automation
- Docker Nuke requires explicit, case-sensitive confirmation (type `NUKE`) to prevent accidents - implemented via the shared `Confirm-DevKitDestructiveAction` helper in `tools/lib/DevKit-Common.ps1`, which any new destructive script should call rather than hand-rolling its own y/n or typed-phrase prompt
- `%LOCALAPPDATA%\NorthstarDevKit\settings.json`'s `preferences.confirmDestructive` (default `true`) gates that shared helper globally; it does not currently gate any script's own bespoke confirmation logic that predates the helper
- **Never execute a destructive/mutating script's real path to "test" it - only its documented read-only/-DryRun/-WhatIf invocation.** Every script under `tools/maintenance/` and `tools/agents/` that mutates the system (deletes files, renames system folders, stops/starts services, writes the registry, runs SFC/DISM, mutates external CLI config) supports a safe, non-mutating invocation - use that one. This applies to a human tester and an AI agent equally: a 2026-07-11 incident had a build-time agent run `Reset-WindowsUpdate.ps1` for real (not `-DryRun`) while self-testing its own work; the safety system blocked it before any actual change landed, but it should never have been attempted in the first place. `Uninstall.ps1` is destructive by design - test it ONLY against a throwaway `-Destination`/`InstallDir` (plus a test `-ArpKeyName`), never against a real install or this repo (its `.northstar-installed` marker check exists exactly for that).

## Testing

`tests/Unit` (Pester 5, wired into CI) covers pure-logic parsers and
converters where this project has actually had real bugs: package-manager
detection (`Get-DevKitPackageManager`), PATH de-duplication, the `.env`
template parser, the git-remote-to-browsable-URL converter, the WiFi
scan parser, the GUI/widget cores (argument rendering, MCP/Kimi parsers,
nvidia-smi parser, git log parser + graph lane layout, .env key diff, the
file-name -> icon-key/color mapping),
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
7. When changing `DevKit.ps1` or `tools/lib/DevKit-Common.ps1`'s menu dispatcher,
   do a scripted pass through the interactive menu (pipe a sequence of
   menu choices to `pwsh -File DevKit.ps1`) to confirm every category still
   renders and dispatches correctly - this is how the 3.0 rewrite verified
   menu parity across all twelve tool categories.

## Adding New Tools

Since 3.0, adding a tool to an **existing** category (`tools/ports/`, `tools/node/`,
`tools/nextjs/`, `tools/vite/`, `tools/git/`, `tools/docker/`, `tools/system/`,
`tools/workflow/`, `tools/diagnostics/`, `tools/wifi/`, `tools/maintenance/`,
`tools/agents/`) is a manifest edit, not a `DevKit.ps1` edit:

1. Create the PowerShell script in the appropriate subdirectory under `tools/`
2. Dot-source `tools/lib/DevKit-Common.ps1` for shared helpers (admin checks, path validation, safe deletion, etc.)
3. Include proper comment-based help (SYNOPSIS, DESCRIPTION, PARAMETERS, EXAMPLES)
4. Add a batch wrapper for double-click execution
5. Add an entry to that category's `_module.psd1` (see any existing one,
   e.g. `tools/ports/_module.psd1`, for the schema - `Key`/`Label`/`Script`,
   plus `RequiresProject`, `RequiresFile`, `Prompts`, or `StaticArgs` as
   needed). **Do not edit `DevKit.ps1`** for this - the generic dispatcher
   in `tools/lib/DevKit-Common.ps1` (`Start-DevKitModuleTools`) picks up the new
   manifest entry automatically.
6. Update `README.md` with documentation
7. Update `AGENTS.md` with module details
8. Follow existing naming conventions and output styling
9. Test the tool thoroughly, including via the interactive menu (confirm
   the new manifest entry parses and dispatches correctly)

## Common Development Tasks

### Adding a new module category
1. Create a new subdirectory under `tools/` (e.g., `tools/docker/`, `tools/git/`)
2. Add PowerShell scripts and batch wrappers
3. Add a `_module.psd1` manifest listing the category's menu items (copy
   the shape of an existing one, e.g. `tools/node/_module.psd1`)
4. Add exactly two lines to `DevKit.ps1`: a line in `Get-DevKitMainMenuEntries`
   for the new `[N]` option, and a
   `'N' { Start-DevKitModuleTools -FolderPath (Join-Path $ToolsDir "yourfolder") }`
   case in the entry-point switch at the bottom of the file. That's the
   entire integration - no new menu function needed.
5. Add the new category to `Get-DevKitSearchableCategories` in `DevKit.ps1`
   (a `Folder`/`MainMenuKey` pair) so `/` search picks it up too, and to
   `Get-DevKitGuiCategories` in `gui/DevKit-GuiCore.ps1` so the Control
   Center lists it
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
- Version 4.0 (see `CHANGELOG.md`) made the widget the app's main face and the toolkit a real installed app: root `Widget.bat` + installer-created shortcuts open the widget directly (the DEVKIT title-bar button opens the Control Center GUI); `Install.ps1` became a stepped per-user installer that registers the app in Settings > Apps (HKCU Uninstall key), and new `Uninstall.ps1` removes every trace (widget process, integrations, Run key, PATH, shortcuts, ARP entry, install dir guarded by the `.northstar-installed` marker, and app data unless kept). All twelve tool categories plus `lib/` moved under `tools/` (leaf scripts unchanged - they resolve lib relative to themselves), maintainer tooling moved to `dev/`, and `Setup-Path.bat` was deleted (the installer covers it). It also shipped the lightweight/performance pass: runspaces bootstrap the shared libs once instead of re-parsing ~150KB per cycle (which had also been wiping WidgetCore's sensor caches every cycle), gauge arcs render from a frozen cached geometry table with no easing timer and no DropShadowEffects, the ToolCard hover lost its transform storyboard (the reported gauges-hover CPU/GPU spike), the node table rebuilds only on bucketed changes, junk scans dropped to a 30-minute cadence, and ALL refresh timers now stop while the widget is hidden to the tray.
