# Northstar DevKit - Agent Documentation

## Project Overview

**Northstar DevKit** is a Windows desktop toolkit for web developers. It
provides utilities for port management, Node.js/Next.js/Vite cache
clearing, Git repository management, Docker container cleanup, system
environment management, AI-CLI/MCP management, and WiFi network
optimization.

As of the Tauri v2 rewrite (this branch), the toolkit is fronted by a real
desktop app - Rust + Tauri v2 with a React 19 + TypeScript UI - and a
terminal CLI (ratatui), instead of the pure-PowerShell/WPF app it used to
be. The ~65 tool scripts themselves (`tools/`) are still 100% PowerShell,
unchanged in logic, and are the actual implementation both new surfaces
run - see "Technology Stack" below and the "App Architecture" section
under Key Features by Module for how the pieces fit together. If you find
a reference to `gui/`, `DevKit.ps1`, `DevKit.bat`, `DevKit-GUI.bat`,
`Widget.bat`, `Install.ps1`, or XAML anywhere in this repo outside
`CHANGELOG.md`'s historical entries, it's stale - that app was deleted.

- **Created by:** Northstar Software Development
- **Website:** https://www.northstarcoding.com
- **License:** MIT
- **Language:** English (all comments and documentation)
- **Version:** 4.0.0 (`VERSION` at repo root; kept in sync by hand with
  the Cargo workspace's `[workspace.package].version` and
  `app/src-tauri/tauri.conf.json`'s `"version"` field - see
  `dev/RELEASING.md`)

## Technology Stack

- **App/CLI shell:** Rust (2021 edition) + Tauri v2 for the desktop app,
  ratatui + crossterm for the CLI's terminal UI. Windows-only (ConPTY via
  `portable-pty`, NSIS bundling, WebView2).
- **App frontend:** React 19 + TypeScript, built with Vite 7. Zustand for
  small global client stores, TanStack Query (via a thin
  `usePolledRpc` wrapper) for server-state polling, Framer Motion for
  animation, `@xterm/xterm` for the embedded terminal view.
- **Bridge:** a long-lived NDJSON-RPC PowerShell sidecar
  (`core/Invoke-DevKitRpc.ps1`) plus a shared Rust client crate
  (`crates/devkit-host`) that both the Tauri app and the CLI depend on -
  see "App Architecture" below for the full picture.
- **Tool implementation:** PowerShell 5.1+ or PowerShell 7+ (pwsh
  preferred) - unchanged from before the rewrite. `tools/` (the ~65 leaf
  scripts across 12 categories, plus `tools/lib/` shared helpers) has no
  external PowerShell dependencies and is not a "legacy" layer - it is
  the thing both the CLI and the Control Center execute.
- **Build tooling:** pnpm for the frontend (`app/`), Cargo for Rust (root
  `Cargo.toml` workspace covers `app/src-tauri`, `cli/`,
  `crates/devkit-host`). `tools/` itself has no package manager (no
  `package.json`/`requirements.txt` at that layer) - it remains a
  dependency-free PowerShell toolkit.

## Project Structure

```
DevKit/
├── AGENTS.md                 # This file
├── CHANGELOG.md               # Release history - includes the retired WPF
│                              # app's entries; that's normal, don't rewrite them
├── CODE_OF_CONDUCT.md
├── CONTRIBUTING.md
├── LICENSE                    # MIT
├── README.md                  # User documentation
├── VERSION                    # Single source of truth for the version number
├── Cargo.toml / Cargo.lock    # Rust workspace: app/src-tauri, cli, crates/devkit-host
├── .gitignore
├── desktop.ini                 # Explorer folder icon - NOTE: still points at
│                              # gui\Assets\logo.ico, a path deleted along with
│                              # the WPF app; stale, not yet repointed
│
├── .github/
│   ├── workflows/ci.yml           # PSScriptAnalyzer + PS syntax check + Pester,
│   │                              # on every push/PR to main - PowerShell only
│   │                              # today, see "App Architecture" > CI below
│   ├── workflows/release.yml      # vX.Y.Z tag -> builds+signs the Tauri app ->
│   │                              # opens a DRAFT GitHub Release
│   ├── ISSUE_TEMPLATE/
│   └── PULL_REQUEST_TEMPLATE.md
│
├── app/                        # The Tauri v2 desktop app
│   ├── src/                        # React 19 + TypeScript frontend
│   │   ├── windows/widget/             # WidgetApp.tsx + panels/ (Gauges,
│   │   │                              # NodePorts, Git, GitHub, Mcp,
│   │   │                              # NotesOnDeck, Files, QuickActions, Terminal)
│   │   ├── windows/control-center/     # ControlCenterApp.tsx + ToolRunDialog.tsx
│   │   ├── components/                 # Shared chrome: TitleBar, ProjectPicker,
│   │   │   │                          # ConfirmDialog(Host), TerminalView, Gauge...
│   │   │   └── primitives/                 # Button/Badge/Expander/GlassPanel -
│   │   │                              # small style-only atoms, no app logic
│   │   ├── hooks/                      # usePolledRpc, useVisibility,
│   │   │                              # useConfirmDestructive, useUpdateCheck...
│   │   ├── stores/                     # zustand: useSettingsStore,
│   │   │                              # useProjectStore, useUpdaterStore
│   │   └── lib/                        # ipc.ts (rpcCall + typed events), types.ts
│   ├── src-tauri/                   # Rust backend
│   │   ├── src/lib.rs                  # Builder setup: plugins, window/tray
│   │   │                              # wiring, sidecar spawn, event forwarding
│   │   ├── src/commands.rs             # rpc_call + window show/hide/toggle
│   │   ├── src/terminal.rs             # ConPTY terminal sessions
│   │   ├── src/tray.rs                 # System tray icon + menu
│   │   ├── src/paths.rs                # Resolves pwsh + Invoke-DevKitRpc.ps1
│   │   │                              # (dev checkout vs. bundled install)
│   │   └── tauri.conf.json             # Two windows, NSIS bundle, updater config
│   └── package.json / pnpm-lock.yaml / vite.config.ts / tsconfig*.json
│
├── cli/                        # `devkit` - the ratatui terminal CLI (no
│   │                          # installer yet - source-built only)
│   └── src/                        # main.rs, menu.rs, catalog.rs, sidecar_paths.rs
│
├── core/                       # The RPC sidecar + the pure-logic files it
│   │                          # (and the CLI, via the sidecar) load
│   ├── Invoke-DevKitRpc.ps1        # The sidecar process entry point
│   ├── RpcMethods.ps1              # The ~40-method dispatch table
│   ├── RpcProtocol.ps1             # NDJSON line-encoding helpers
│   ├── DevKit.Core.psm1            # Dot-sources tools/lib/* + the two files
│   │                              # below into one flat module
│   ├── DevKit-WidgetCore.ps1       # Pure logic, moved here from gui/: metrics,
│   │                              # git overview, notes/on-deck, files, MCP status
│   ├── DevKit-GuiCore.ps1          # Pure logic, moved here from gui/: catalog
│   │                              # loading, category grouping, arg resolution
│   ├── Export-Catalog.ps1          # Dev-time: (re)writes core/catalog.json -
│   │                              # the live app never reads that file itself
│   └── catalog.json                # Committed static snapshot (offline
│                                  # inspection / type generation only)
│
├── crates/devkit-host/         # Rust NDJSON-RPC client crate - owns the
│   │                          # sidecar process, shared by app/ and cli/
│   └── src/                        # host.rs, protocol.rs, lib.rs
│
├── tools/                      # ALL tool categories + the shared lib -
│   │                          # UNCHANGED, still 100% PowerShell, still the
│   │                          # real implementation (both the CLI and the
│   │                          # Control Center run these same scripts - see
│   │                          # "App Architecture" below)
│   ├── lib/                        # DevKit-Common.ps1, DevKit-UI.ps1,
│   │                              # DevKit-McpCatalog.ps1, DevKit-McpList.ps1,
│   │                              # DevKit-McpAddFlow.ps1
│   ├── ports/ node/ nextjs/ vite/ git/ docker/ system/ workflow/
│   │   diagnostics/ wifi/ maintenance/ agents/   # each: script+.bat pairs
│   │                              # plus one _module.psd1 manifest
│   │                              # (per-category details: see "Key Features
│   │                              # by Module")
│
├── tests/
│   └── Unit/                   # Pester tests - unchanged coverage; two files'
│                              # dot-source paths were updated (gui\ -> core\)
│                              # when WidgetCore/GuiCore moved
│
├── dev/                         # Maintainer-only tooling
│   └── RELEASING.md                # Version-bump + local-test + tag + publish
│                                  # checklist for cutting a Tauri release. The
│                                  # portable-USB-build script that used to live
│                                  # here (mirroring a WPF install to USB/) was
│                                  # retired with the WPF app; the /USB/ entry
│                                  # still in .gitignore is a leftover of that.
│
└── target/, app/node_modules/, app/dist/   # Rust/Node build output - gitignored
```

Linked projects (`projects.json`) and settings (`settings.json`) live outside
the repo at `%LOCALAPPDATA%\NorthstarDevKit\`, same as before the rewrite.

## Code Style Guidelines

### PowerShell (`tools/`, `core/`)

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

#### Naming Conventions

- **Scripts:** PascalCase with hyphens (e.g., `Kill-Port.ps1`, `WiFi-Optimize.ps1`)
- **Functions:** PascalCase with approved PowerShell verbs (e.g., `Write-Header`, `Invoke-PortScan`)
- **Variables:** camelCase or descriptive names
- **Parameters:** PascalCase with sensible defaults
- **Avoid reserved words:** Do not use `$Host` as a parameter name (use `$ExposeHost` instead)

#### Output Styling

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

#### Error Handling

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

### TypeScript / React (`app/src`)

- Two window entry points (`windows/widget/`, `windows/control-center/`),
  each a single top-level `*App.tsx` composing self-contained panel/section
  components. `GaugesPanel.tsx`'s own header comment calls it the
  "reference panel implementation" - follow its shape for a new widget
  panel: self-contained, no required props, owns its own polling via
  `usePolledRpc`, owns its own loading/error/n-a states. Each component
  ships its own plain `.css` file (BEM-ish class names like
  `gauges-panel__row`, not CSS modules or a utility framework).
- `components/primitives/` holds small style-only atoms (`Button`,
  `Badge`, `Expander`, `GlassPanel`) with no app logic - reach for one of
  these before hand-rolling a button/badge/panel shell.
- All server-derived state goes through `hooks/usePolledRpc.ts` (a thin
  TanStack Query `useQuery` wrapper) rather than ad hoc
  `useEffect`+`fetch`: it polls one RPC method on an interval AND stops
  polling while the window is hidden (`useVisibility.ts`, driven by the
  `devkit://visibility` event `commands.rs` emits), so a tray-hidden
  widget doesn't keep hitting the sidecar for nothing. Pass its `enabled`
  flag explicitly for "nothing to ask about yet" (e.g. no project
  selected) rather than inferring it from `params === undefined` - some
  panels legitimately poll param-less methods.
- Global client state (settings, active project, updater status) lives in
  `stores/` as small zustand stores, not React context - see
  `useSettingsStore.ts` for the pattern: state plus async actions that
  call `rpcCall` and set state from the result or a caught
  `RpcClientError`.
- Every RPC call goes through `lib/ipc.ts`'s typed `rpcCall<T>(method,
  params)` - never call the raw `invoke("rpc_call", ...)` Tauri API
  directly from a component. Streamed events (`tool.run` output) go
  through `onDevKitEvent`/`onToolRun`, keyed by `runId`.
- Destructive actions (kill a process, run a "caution" tool, clear system
  junk) go through `useConfirmDestructive()`, which mirrors
  `Confirm-DevKitDestructiveAction`'s `preferences.confirmDestructive`
  gate on the PowerShell side - see Security Considerations below.
- Framer Motion for animation, gated by `<MotionConfig reducedMotion=...>`
  derived from both the OS `prefers-reduced-motion` media query and the
  in-app `preferences.enableAnimations` setting
  (`useSyncAnimationsAttribute.ts`) - a new animated element should
  respect both, not just the OS one.

### Rust (`app/src-tauri`, `cli/`, `crates/devkit-host`)

- Small, single-purpose modules with a `//!` doc comment at the top
  explaining what the module owns and, where it's not obvious, why it's
  separate from its neighbors (see `commands.rs`, `paths.rs`,
  `terminal.rs`, `tray.rs`, `host.rs` for the pattern) - follow it for any
  new module rather than growing an existing file past its stated scope.
- `app/src-tauri/src/commands.rs` is deliberately thin: `rpc_call` is the
  one generic passthrough to the sidecar. **Do not add a new
  `#[tauri::command]` for a new panel/feature** - add a case to
  `core/RpcMethods.ps1` and call it from the frontend through `rpcCall`
  instead. New Rust commands are for things that genuinely are not
  PowerShell's job: window/tray management, the ConPTY terminal, other
  OS-level integration.
- Error types are `thiserror` enums (see `HostError` in `host.rs`); Tauri
  commands return `Result<T, String>` (the IPC boundary needs a
  `Serialize` error type, so map at the command boundary, not deeper in
  the call stack).
- `crates/devkit-host` is the one shared RPC client - both
  `app/src-tauri` and `cli/` depend on it (`devkit-host = { path = ... }`
  in their `Cargo.toml`s). Keep sidecar-process concerns (spawn, respawn,
  NDJSON framing) there rather than duplicating them in either consumer.
- `cargo clippy --workspace --all-targets` and `cargo test --workspace`
  are expected to pass clean (see Testing below); `devkit-host` carries
  its own unit tests over the protocol/framing layer
  (`crates/devkit-host/Cargo.toml`'s `[dev-dependencies]`).

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
- **Admin Mode** (`Set-DevKitAdminMode.ps1`/`.bat`, manifest items 6-7):
  opt-in, one-time setup that registers a `NorthstarDevKit-Admin` scheduled
  task (RunLevel Highest) so the app launches elevated with no per-launch
  UAC prompt - started through a tiny hidden wscript launcher and
  'DevKit (Admin)' Desktop/Start-Menu shortcuts. If Start-with-Windows is
  on it is MOVED from the HKCU Run key onto the task as a logon trigger
  (Windows will not auto-start elevated apps from the Run key), and every
  change is recorded in `%LOCALAPPDATA%\NorthstarDevKit\admin-mode.json` so
  `-Off` reverses it exactly. When not elevated the script re-launches
  itself once via `Start-Process -Verb RunAs -Wait` and reads the child's
  JSON result file (ShellExecute streams nothing back), so it also works
  from the Control Center's headless Run dialog; `-DryRun` prints the plan.
  The app surfaces the result through the `system.isElevated` RPC as an
  amber ADMIN badge in the shared TitleBar (`ElevationIndicator` in
  `app/src/components/TitleBar.tsx`).

### Workflow Tools (`tools/workflow/`)
- Detects VS Code and Cursor installations
- Opens repositories in browser (GitHub, GitLab, Bitbucket, Azure DevOps)
- Parses `.env.example` templates for variable extraction
- Converts SSH URLs to HTTPS for browser opening
- Close Out Session (`Close-OutSession.ps1`): the one-action end-of-day
  cleanup (stops node.exe, frees dev ports held by recognized dev runtimes,
  clears temp/junk, trims every accessible working set). The manifest
  registers it three ways - default (item 6), dry-run preview (item 7,
  `StaticArgs DryRun`), and Deep (item 8, `StaticArgs IncludeRecycleBin` +
  `IncludePackageCache`) - and the widget's Quick Actions panel mirrors all
  three, adding `-ProjectPath <active project>` to its own Deep run.

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

### App Architecture (`core/`, `crates/devkit-host`, `app/`, `cli/`)

This replaces the old WPF Desktop GUI / Companion Widget sections - read
this before touching anything UI-related. The short version: a
long-lived PowerShell sidecar does all the real work behind one generic
Rust command; the Tauri app and the ratatui CLI are both thin clients of
the same RPC surface, both reading the same manifest-driven catalog.

#### The RPC sidecar (`core/Invoke-DevKitRpc.ps1`)

A single long-lived `pwsh` process, spawned once by the Rust host and
kept alive for the app's/CLI's lifetime (a cold `pwsh -File` costs
300-800ms - too slow for a per-call model). It speaks one JSON object per
line on stdin/stdout (NDJSON) - see `crates/devkit-host/src/protocol.rs`
for the matching Rust-side types.

**Threading model** - worth reading before changing this file, since the
reason isn't obvious from the code alone: `[Console]::Out` is not
thread-safe against concurrent writers in PowerShell, and one
interleaved/corrupted line would break the framing for every request
after it. Rather than rely on convention, the file makes "only one thing
ever writes a line" true by construction:

- **One writer runspace** owns `[Console]::Out` exclusively. It drains a
  single `BlockingCollection<string>` queue and is the only code in the
  whole process calling `WriteLine`/`Flush`.
- **Three lane runspaces** (`metrics`, `slow`, `work`), each one
  persistent runspace with `DevKit.Core` imported once, each draining its
  own request queue and processing one request at a time, pushing its
  response onto the writer's queue when done. (These are plain runspaces,
  not `RunspacePool`s, despite sometimes being described that way - each
  lane is exactly one worker.) This mirrors the old WPF widget's
  `MetricsRunspace`/`McpRunspace`/`WorkRunspace` split, for the same
  reason: a slow `gh pr list` call must never stall a metrics poll.
- The **main thread** just reads stdin line-by-line and routes each
  request to a lane by method-name prefix: `metrics.*` -> metrics lane;
  `git.*`/`github.*`/`tool.*`/`maintenance.*` -> slow lane; everything
  else -> work lane. `ping`/`shutdown` are handled inline with no lane
  hop.

If this ever proves fragile in practice, the file's own header comment
documents the fallback: split the three lanes into three separate `pwsh`
processes instead of three runspaces in one - simpler, more RAM, no
shared-process invariants to get right.

#### The method table (`core/RpcMethods.ps1`)

Maps each `"namespace.verb"` method name (~40 of them today - e.g.
`metrics.system`, `git.overview`, `notes.save`, `tool.run`) to a call
into `DevKit.Core`: `tools/lib/*` plus `core/DevKit-WidgetCore.ps1` and
`core/DevKit-GuiCore.ps1`. This file only adapts JSON params to
PowerShell calls - it contains no tool logic of its own. **Adding a new
panel or feature almost always means adding one `case` here** (the
file's own header comment says the same) - not touching Rust, not
touching the lane/writer plumbing.

`catalog.get` (`Get-DevKitCatalogPayload`) is the method every UI depends
on: it flattens `Get-DevKitGuiCatalog`'s manifest-driven groups (from
`core/DevKit-GuiCore.ps1`) into the flat `{ modules: [...] }` shape both
the Control Center and the CLI render directly, and computes a `caution`
flag from each item's Help text containing `"Safety note:"`.

`tool.run` is the Control Center's "Run" button: it spawns the target
`tools/<folder>/<script>.ps1` as a **non-interactive** child process
(`-NonInteractive`, stdin closed immediately) and streams its
stdout/stderr back as `tool.output` events keyed by a `runId`, finishing
with `tool.finished`. See "Two ways a tool actually runs" below - this is
deliberately different from how the CLI runs the same script.

`core/DevKit.Core.psm1` is what makes all of this possible without
touching library code: it dot-sources `tools/lib/*` and the two
ex-`gui/` files in a fixed order and re-exports everything as one flat
module, imported once per lane runspace. Every file it loads still guards
itself with a `$global:*Loaded` flag, so importing it multiple times
(once per lane, plus again inside `Export-Catalog.ps1`) is safe.

#### The Rust host client (`crates/devkit-host`)

`PsHost` (in `host.rs`) owns the sidecar's `Child` process and
multiplexes concurrent calls over its one stdout stream by request id.
From the Rust side, the three PowerShell lanes are invisible - this
client just sees one stream and demuxes.

Two things worth knowing if you touch this file:

- **Respawn with backoff**: `ensure_alive()` is idempotent and serializes
  concurrent respawn attempts via the same mutex that guards the running
  process; each failed attempt increases an exponential backoff (200ms
  doubling, capped at 10s) before the next.
- **Per-generation pending maps**: each spawn of the sidecar gets its own
  `HashMap<id, oneshot::Sender>` (owned by that generation's
  `RunningSidecar`, not shared on `Inner`). This closes a real race: a
  dying generation's reader task can still be mid-drain (its EOF cleanup)
  after a respawn has already started handing out new ids - a shared map
  would let the old generation's cleanup wipe out the new generation's
  in-flight entry. Giving each generation its own map makes that
  impossible by construction - the same "correct by construction, not by
  convention" philosophy as the PowerShell side's single writer runspace.

`call()` transparently respawns a dead sidecar before retrying.
`shutdown()` sends the RPC `shutdown` call, then waits up to 8s for the
child to actually exit (covering the sidecar's own ~7s worst case: a 5s
lane-drain deadline plus a 2s writer-drain deadline) before force-killing.

#### The Tauri app (`app/`)

Two windows, both created hidden and shown via `set_window_visible` (see
`commands.rs` for why - `WebviewWindow::hide()`/`show()` alone don't
reliably drive `document.visibilityState`, which the frontend's
`useVisibility` hook needs to be able to trust):

- **`widget`** (`app/src/windows/widget/WidgetApp.tsx`) - the always-on
  companion, DevKit's main face. Panels top to bottom: Gauges
  (CPU/Mem/GPU/Disk), Node/Ports (collapsed by default, like the
  embedded terminal - `lazyMount`, so its polls cost nothing until first
  opened), Git (a gradient-lane commit graph with
  open-PR pills on the head commits they point at and ribbons tracing each
  PR's commits on hover - PR identity lives IN the chart, never in a
  separate legend/band above it; matching is hash-exact via gh's
  `headRefOid` with a branch-name fallback, see `git/prLanes.ts`; and the
  overview auto-fetches origin - throttled to one prompt-free attempt per
  minute per repo, `Invoke-DevKitGitAutoFetch` - so bot-pushed branches
  like dependabot's reach the log without a manual Fetch, and the log
  window grows from 40 up to 400 commits until every open-PR head fits
  (`-ExtraTips` from the gh poll), so a busy trunk can't push PRs out of
  the chart),
  GitHub (PRs/Issues), MCP status, Notes/On-Deck, Files, Quick Actions,
  and a collapsed-by-default embedded terminal (see below). Single-
  instance via `tauri-plugin-single-instance` (a second launch surfaces
  the existing window instead of spawning a duplicate) and a system tray
  (`tray.rs`) with Show/Hide, Open Control Center, a Start-with-Windows
  toggle (`tauri-plugin-autostart`), and Exit. Closing the window via its
  titlebar hides it to the tray rather than quitting (`lib.rs`'s
  `CloseRequested` handler) - only the tray's Exit item, or
  `tauri-plugin-process`, actually ends the process. When Admin Mode is
  enabled, the Run-key Start-with-Windows entry is superseded by the
  elevation task's logon trigger - `Set-DevKitAdminMode.ps1` moves it there
  on enable and restores it on `-Off`, so the two never fight over the same
  mechanism (see System Tools above).
- **`control-center`** (`app/src/windows/control-center/ControlCenterApp.tsx`)
  - the full catalog-driven tool browser. Renders the `catalog.get`
  payload as a searchable, grouped card grid; clicking a card opens
  `ToolRunDialog.tsx`, which builds a dynamic form from the item's
  `prompts`/`requiresProject`/`staticArgs` (mirroring
  `Read-DevKitTypedValue`'s validation contract exactly - see its own
  code comments) and runs the tool via the headless `tool.run` path,
  streaming its output live. The SAME component also mounts inside the
  docked widget as a slide-out flyout tray via
  `<ControlCenterApp embedded />` (`WidgetApp.tsx`'s `flyoutPanes`): the
  rail's DEVKIT brand plate is its tab, embedded mode drops the TitleBar
  (a pane has no window chrome), the ProjectPicker (the widget's own
  picker shares the store), and the `PALETTE_TOOL_EVENT` listener (the
  standalone window stays the command palette's tool-run target - two
  mounted instances consuming one event would open the same dialog
  twice). On open the tray fills the REST of the screen (the sidebar's
  base width off `screen.availWidth`; Rust's `derive_rect` clips the
  request to the work area, so it can never overshoot), and its drag
  ceiling is the screen itself rather than the 900px panel cap. A
  resize drag persists `controlCenterFlyoutWidth` (null = fill,
  beside `gitFlyoutWidth`/`notesFlyoutWidth`/`flyoutWidth`).

Both windows go through the **single generic `rpc_call` Tauri command**
(`commands.rs`) for everything sidecar-related - `host.call(&method,
params)`. Adding a new RPC-backed feature never needs a new Tauri
command: add the case to `core/RpcMethods.ps1`, add a typed call in
`app/src/lib/ipc.ts` (or call `rpcCall` directly from a component), done.
The only Rust commands outside `rpc_call` are window show/hide/toggle and
the four ConPTY terminal commands below - things that are genuinely
OS-level, not sidecar work.

#### The embedded terminal (`app/src-tauri/src/terminal.rs`)

A separate capability from the RPC sidecar entirely: `terminal_spawn`
opens a real pseudo-console (`portable_pty`, ConPTY) running an
interactive `pwsh.exe`, wired to an `@xterm/xterm` instance in the
frontend (`components/TerminalView.tsx`) via `devkit://terminal` events
(raw UTF-8 chunks, not base64 - `from_utf8_lossy` handles a chunk
boundary splitting a multi-byte character rather than panicking). It
replaces the old widget's "launch an external Windows Terminal window and
glue it over the panel" approach with a PTY that actually lives inside
the app. Sessions are tracked in a `TerminalRegistry` Tauri-managed
state, keyed by session id; `terminal_write`/`terminal_resize`/
`terminal_kill` round out the four commands. The widget's Terminal panel
starts collapsed by default (`lazyMount` on its `<Expander>`), so it
costs nothing until a viewer opens it.

#### The CLI (`cli/`, binary `devkit`)

`devkit` (package `devkit-cli`, binary `devkit.exe`) is a ratatui
terminal menu that replaces the old `DevKit.ps1` TUI, driven by the exact
same `catalog.get` payload the GUI renders (`cli/src/menu.rs`,
`catalog.rs`). Arrow-key navigation, `/` search, `p` to switch the active
project, a digit-accumulator jump (type a number then Enter to jump
straight to that row - a generous 5-digit cap guards against a stuck
key), and a native Windows file picker (shells out to a hidden `pwsh`
process running `System.Windows.Forms.OpenFileDialog`, with
`CREATE_NO_WINDOW` so it doesn't flash a console) for `RequiresFile`
prompts. `devkit catalog` prints the parsed catalog as JSON; `devkit
doctor` pings the sidecar and confirms it's alive.

**There is no installer for the CLI yet** - it's built from source only
(`cargo build --release -p devkit-cli`, producing
`target/release/devkit.exe`); only the GUI app (`devkit-app.exe`) ships
via the NSIS installer today.

#### Two ways a tool actually runs - know this before adding one

The Control Center and the CLI both execute the same
`tools/<folder>/<script>.ps1` scripts, but NOT the same way:

- **Control Center -> `tool.run` RPC**: the sidecar spawns the script
  `-NonInteractive` with stdin closed immediately, and streams
  stdout/stderr back as events. This is a deliberate, documented
  trade-off - `ToolRunDialog.tsx`'s own comment calls it "the headless
  execution path... most tools run headlessly with streamed output
  instead of bouncing you to a terminal." It means a tool that genuinely
  needs interactive keyboard input (`[Console]::ReadKey` menus, a live
  y/n read from the console, `git rebase -i`, launching `claude`/`kimi`
  interactively) will **not** work correctly through this path.
- **CLI -> direct spawn**: `run_tool_flow` (`cli/src/menu.rs`) suspends
  the ratatui alternate screen and spawns the script with
  `Stdio::inherit()` on all three streams - a real interactive child
  process, the same model the old `DevKit.ps1` TUI used.

So: a script that needs real interactive stdin still works fine via the
CLI, via its `.bat` wrapper, or via the embedded ConPTY terminal - just
not via the Control Center's Run dialog. Keep this in mind when designing
a new tool's interactivity, and don't assume working from one surface
means it'll work from the other.

#### Settings, auto-update, installer, CI

- **Settings** (`preferences.confirmDestructive`, `enableAnimations`,
  `updateCheckEnabled`, `lastUpdateCheckUtc`, dock/width prefs, ...)
  persist through the same `%LOCALAPPDATA%\NorthstarDevKit\settings.json`
  file the old app used (`Get-/Set-DevKitSettings` in
  `tools/lib/DevKit-Common.ps1`, unchanged), read/written via the
  `settings.get`/`settings.set` RPC methods and `stores/useSettingsStore.ts`.
- **Auto-update**: a minisign keypair signs updater artifacts
  (`tauri-plugin-updater`); the app checks
  `https://github.com/st3adyp1ck/northstar-devkit/releases/latest/download/latest.json`
  on launch (throttled to once per 24h via `preferences.lastUpdateCheckUtc`
  - see `useUpdateCheck.ts`) and via a manual "Check for Updates" button
  in Quick Actions, with a real download-progress -> install -> relaunch
  flow (`useUpdaterStore.ts`, `UpdateDialog.tsx`).
- **Installer**: `app/src-tauri/tauri.conf.json` configures an NSIS
  installer - Windows-only, per-user (`installMode: currentUser`, no
  admin needed) - built via `pnpm tauri build` from `app/`.
  `tauri.conf.json`'s `bundle.resources` maps `../../core` and
  `../../tools` into the installed app's resource directory; `paths.rs`
  resolves the sidecar script there in a release build, versus walking up
  from `CARGO_MANIFEST_DIR` to the repo checkout in a dev build. There is
  no custom `Uninstall.ps1` any more - NSIS generates its own uninstaller
  as part of the bundle.
- **CI** (`.github/workflows/release.yml`): pushing a `vX.Y.Z` tag builds
  and signs the app on `windows-latest` and opens a **draft** GitHub
  Release - a human must click "Publish release" before the updater
  endpoint goes live. `.github/workflows/ci.yml` currently runs only the
  PowerShell side (PSScriptAnalyzer, a syntax check, Pester) on every
  push/PR to `main`; the Rust and frontend checks in `dev/RELEASING.md`'s
  checklist (`cargo clippy`/`cargo test`, `tsc`/`vite build`) are run
  manually before cutting a release rather than in CI today - see
  Testing below.

## Usage Patterns

### Launching the app

The installed app's Start Menu/Desktop shortcut and tray icon open the
**widget** window directly - it's DevKit's main face. The Control Center
opens from the widget's title-bar "DEVKIT" button, its Quick Actions
panel, or the tray menu.

From a source checkout, for development:
```powershell
cd app
pnpm install
pnpm tauri dev      # spawns the sidecar from the repo root, opens both windows
```

### The CLI
```powershell
cargo build --release -p devkit-cli
.\target\release\devkit.exe            # interactive ratatui menu
.\target\release\devkit.exe catalog    # print the tool catalog as JSON
.\target\release\devkit.exe doctor     # ping the sidecar
```

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
- Batch wrappers use `-NoProfile -ExecutionPolicy Bypass` for fast,
  predictable launches; the RPC sidecar is launched the same way, plus
  `-NoLogo -NonInteractive` (`crates/devkit-host/src/host.rs`), and
  `tool.run` spawns each script identically (`core/RpcMethods.ps1`).
- All scripts use `ErrorAction SilentlyContinue` where appropriate to prevent unnecessary failures
- Force flags (`-Force`) are available to skip confirmation prompts for automation
- Docker Nuke requires explicit, case-sensitive confirmation (type `NUKE`)
  to prevent accidents - implemented via the shared
  `Confirm-DevKitDestructiveAction` helper in `tools/lib/DevKit-Common.ps1`,
  which any new destructive script should call rather than hand-rolling
  its own y/n or typed-phrase prompt. The app UI has a parallel gate for
  RPC-driven destructive actions (process kill, junk clear, running a
  "caution"-flagged tool from the Control Center):
  `useConfirmDestructive()` (`app/src/hooks/useConfirmDestructive.ts`),
  which reads the same setting described next.
- `%LOCALAPPDATA%\NorthstarDevKit\settings.json`'s
  `preferences.confirmDestructive` (default `true`) gates both of the
  helpers above globally; it does not gate any script's own bespoke
  confirmation logic that predates `Confirm-DevKitDestructiveAction`.
- **Admin Mode** (`tools/system/Set-DevKitAdminMode.ps1`) is a deliberate,
  opt-in weakening of the least-privilege default: the scheduled task it
  registers elevates whatever its registered exe path points at with NO
  prompt, and the per-user install folder is writable by anything running
  as the user, so replacing `DevKit.exe` afterwards is a silent elevation
  path. While elevated, every DevKit surface (all tools, the embedded
  terminal) runs as Administrator. It requires one interactive UAC consent
  to enable, is gated by `Confirm-DevKitDestructiveAction`, announces the
  trade-off in its own help text and output, supports a read-only
  `-DryRun`, and `-Off` removes every trace (task, launcher, shortcuts,
  restored Run key, state marker).
- **Never execute a destructive/mutating script's real path to "test" it
  - only its documented read-only/`-DryRun`/`-WhatIf` invocation.** Every
  script under `tools/maintenance/` and `tools/agents/` that mutates the
  system (deletes files, renames system folders, stops/starts services,
  writes the registry, runs SFC/DISM, mutates external CLI config)
  supports a safe, non-mutating invocation - use that one, whether you're
  invoking it directly, through the CLI, or through the Control Center's
  Run dialog (its prompt form fields include the same `-DryRun`/`-WhatIf`
  switches). This applies to a human tester and an AI agent equally: a
  2026-07-11 incident had a build-time agent run
  `Reset-WindowsUpdate.ps1` for real (not `-DryRun`) while self-testing
  its own work; the safety system blocked it before any actual change
  landed, but it should never have been attempted in the first place.

## Testing

`tests/Unit` (Pester 5, wired into CI) covers pure-logic parsers and
converters where this project has actually had real bugs: package-manager
detection (`Get-DevKitPackageManager`), PATH de-duplication, the `.env`
template parser, the git-remote-to-browsable-URL converter, the WiFi
scan parser, the GUI/widget cores (`core/DevKit-GuiCore.ps1` /
`core/DevKit-WidgetCore.ps1` - argument rendering, MCP/Kimi parsers,
nvidia-smi parser, git log parser + graph lane layout, .env key diff, the
file-name -> icon-key/color mapping), the winnat excluded-port-ranges
parser, the .env key extractor, the Convert-DevText converters, and the
Admin Mode pure helpers (exe-candidate resolution, launcher/shortcut/
child-argument rendering, the Run-key autostart matcher). Run
locally with:

```powershell
Invoke-Pester -Path tests/Unit
```

Rust workspace (`app/src-tauri`, `cli`, `crates/devkit-host`):
```powershell
cargo check --workspace
cargo clippy --workspace --all-targets
cargo test --workspace        # devkit-host has unit tests over its NDJSON protocol/framing layer
```

Frontend (`app/`):
```powershell
cd app
npx tsc --noEmit
npx vite build
```

The Pester suite runs automatically in CI (`.github/workflows/ci.yml`) on
every push/PR to `main`. The Rust and frontend checks above do not run in
CI yet - they're run manually before cutting a release, per
`dev/RELEASING.md`'s checklist.

Everything else - anything that shells out to git/docker/npm, mutates
PATH/env vars/DNS, kills processes, or drives the real desktop UI - is
**not** covered by automated tests by design (a hosted CI runner
shouldn't have its real PATH mutated or its containers destroyed), and is
verified manually:

1. Run scripts in a PowerShell window to observe output
2. Verify colored output displays correctly (see the color convention above)
3. Test both success and error paths
4. Confirm batch wrappers launch PowerShell correctly
5. Test DryRun/-WhatIf modes where available (Docker, Git cleanup)
6. Verify error handling with invalid inputs
7. When changing a `_module.psd1` manifest, `core/RpcMethods.ps1`'s
   `catalog.get`, or `Get-DevKitGuiCategories`
   (`core/DevKit-GuiCore.ps1`), confirm the catalog still parses via
   `devkit catalog` (prints it as JSON) and/or
   `tests/Unit/GuiCore.Tests.ps1`'s catalog-loading test, then spot-check
   both the CLI and the Control Center actually render the change.

## Adding New Tools

Adding a tool to an **existing** category (`tools/ports/`, `tools/node/`,
`tools/nextjs/`, `tools/vite/`, `tools/git/`, `tools/docker/`, `tools/system/`,
`tools/workflow/`, `tools/diagnostics/`, `tools/wifi/`, `tools/maintenance/`,
`tools/agents/`) is still a manifest edit only - the CLI and the Control
Center both read `_module.psd1` manifests through the same `catalog.get`
RPC method (`core/RpcMethods.ps1` -> `Get-DevKitCatalogPayload` ->
`Get-DevKitGuiCatalog` in `core/DevKit-GuiCore.ps1`), so there's no UI
code to touch for this case:

1. Create the PowerShell script in the appropriate subdirectory under `tools/`
2. Dot-source `tools/lib/DevKit-Common.ps1` for shared helpers (admin checks, path validation, safe deletion, etc.)
3. Include proper comment-based help (SYNOPSIS, DESCRIPTION, PARAMETERS, EXAMPLES)
4. Add a batch wrapper for double-click execution
5. Add an entry to that category's `_module.psd1` (see any existing one,
   e.g. `tools/ports/_module.psd1`, for the schema - `Key`/`Label`/`Script`,
   plus `RequiresProject`, `RequiresFile`, `Prompts`, or `StaticArgs` as
   needed - unchanged from before the rewrite). Nothing else needs
   editing: `catalog.get` picks up the new entry automatically for both
   the CLI and the Control Center.
6. If the tool's Help text documents a destructive action, prefix it
   `"Safety note:"` - `Get-DevKitCatalogPayload` turns that into the
   `caution` flag automatically, which badges the tool and routes its Run
   button through the confirm dialog in the Control Center. No extra
   wiring needed.
7. **If the tool needs real interactive stdin** (arrow-key menus, a live
   y/n read from the console, launching another interactive CLI like
   `claude`/`kimi`), it will work correctly via the CLI and via the
   embedded terminal, but **not** via the Control Center's headless
   `tool.run` path - see "Two ways a tool actually runs" above. Design
   accordingly, or document the limitation in the tool's own help text.
8. Update `README.md` with documentation
9. Update `AGENTS.md` with module details
10. Follow existing naming conventions and output styling
11. Test the tool thoroughly: via its `.bat` wrapper, via `devkit` (the
    CLI), and via the Control Center's Run dialog.

## Common Development Tasks

### Adding a new top-level tool category
1. Create a new subdirectory under `tools/` (e.g., `tools/docker/`, `tools/git/`)
2. Add PowerShell scripts and batch wrappers
3. Add a `_module.psd1` manifest listing the category's menu items (copy
   the shape of an existing one, e.g. `tools/node/_module.psd1`)
4. Add the folder to a group in `Get-DevKitGuiCategories`
   (`core/DevKit-GuiCore.ps1`). This is now the **only** place category
   grouping lives - both the CLI (`cli/src/catalog.rs`'s `ordered_groups`)
   and the Control Center (`ControlCenterApp.tsx`) derive their nav
   groups from the `catalog.get` payload itself, so there's no separate
   menu file or search-category list to keep in sync any more (the old
   `DevKit.ps1` main-menu entry + `Get-DevKitSearchableCategories`
   two-places-at-once pattern is gone along with `DevKit.ps1` itself).
5. Optional/cosmetic: add a matching entry to `GROUP_ICON` in
   `app/src/windows/control-center/ControlCenterApp.tsx` for a specific
   glyph - an unmapped group still renders fine (falls back to a default
   icon).
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
- `tools/` itself has no package management (no `package.json`,
  `requirements.txt`, etc.) and remains a dependency-free PowerShell
  toolkit at that layer; `app/` (pnpm) and the Rust workspace (Cargo) are
  the app shell's own build tooling, not something `tools/` scripts rely on
- Scripts use consistent header format with Northstar branding
- Version 2.1 unified the toolkit under a shared helper module (`lib/DevKit-Common.ps1`), added package-manager auto-detection, completed batch-wrapper coverage, and fixed PowerShell 7 / path-validation / process-killing bugs
- Version 3.0 (see `CHANGELOG.md` for full detail) added browsable project linking (`Select-DevKitProject`, the linked-projects registry, `[10] Projects` menu), rewrote all ten tool-category submenus as a manifest-driven dispatcher (`_module.psd1` + `Start-DevKitModuleTools`) instead of ten hand-written function pairs, added `/` search-and-jump, added a Pester test suite, and fixed roughly 150 confirmed bugs from a full-repo review - including one (`system/Env-Restore.ps1`) that had been completely broken (could not run at all) since before 3.0 existed
- Version 3.1 (see `CHANGELOG.md`) added arrow-key navigation (`Show-DevKitInteractiveMenu`) with automatic fallback to the classic typed-number flow, two new manifest-driven categories (`[12] Maintenance`, `[13] Agents & MCP`), and `Get-DevKitWindowsExecutable` - a defensive CLI-resolution helper added after a real bug where an ambiguously-resolved `gh` on PATH triggered a Windows ShellExecute "Select an app to open" dialog instead of failing cleanly
- Version 3.5 (see `CHANGELOG.md`) added a gradient animation/color engine (`lib\DevKit-UI.ps1`: a fail-closed capability probe, a startup banner shown once per session, and a Runspace-backed spinner for long-running scriptblocks) plus in-menu help (`Description`/`Help` keys in every `_module.psd1`, a `?` entry per category, and a Main Menu "Getting Started" entry); expanded AI-CLI tracking from 6 to 11 tools with a real per-tool update channel (npm/npm+builtin/scoop/manual) instead of assuming npm everywhere; and added a 10-entry curated MCP server catalog (`lib\DevKit-McpCatalog.ps1`) with a browsable add-from-catalog flow and a scan-and-fill-gaps tool, alongside real HTTP/remote MCP server support and a genuinely-scoped `Get-McpServers.ps1 -Scope`
- Version 3.6 (see `CHANGELOG.md`) added the branded desktop GUI (`gui/` + root `DevKit-GUI.bat`): a dependency-free WPF shell themed on the company compass-rose logo that renders the same twelve `_module.psd1` manifests as navigable tool cards with search, linked-project management, and validated input dialogs, and launches tools in a real terminal window (Windows Terminal or conhost) so every script's existing interactivity keeps working byte-for-byte unchanged. Pure logic lives in `gui/DevKit-GuiCore.ps1` with Pester coverage; brand assets are generated from `gui/Assets/logo.png` by `gui/Build-Assets.ps1`.
- Version 3.7 (see `CHANGELOG.md`) added the companion widget (`gui/DevKit-Widget.ps1`, launched from the GUI's gauge button): a persistent desktop + system-tray app with live CPU/memory/GPU metrics and best-effort temperatures, a node-process/port watch, quick-action buttons that launch real DevKit tools, an Active Project selector, and expandable Claude Code / Kimi Code CLI + MCP status boxes with Connected/Disconnected/Requires Auth badges (Claude via `claude mcp list` health output, Kimi via its documented `mcp.json` files) - single-instance with a summon event, TaskbarCreated re-registration, and a reversible Start-with-Windows toggle.
- Version 3.8 (see `CHANGELOG.md`) turned the widget into the primary surface: a drawn commit graph (lane layout + gradient S-curves + ref pills) replaced the monospace `git log --graph` text, and the widget gained a Disk Free dial, process ages + per-pid kill + click-to-open ports in the node table, an ambient git badge and .env-drift hint under the project selector, a reboot-pending hint, winnat reserved-port warnings, and four project launchers (Editor/Explorer/Terminal/Run Script...). Both WPF apps moved the theme from a Window.Resources string-merge to Application.Resources created before XAML load (fixes unthemed scrollbars/dialogs). Eight new tools shipped: Show-ExcludedPortRanges + Test-DevEndpoint (ports/), Get-GitStandup (git/), Start-PackageScript + Find-StaleNodeModules (node/), Edit-HostsFile (system/), Compare-EnvFiles + Convert-DevText (workflow/). It also fixed two long-standing HIGH bugs: the Agents "Manage..." dialog never attached its content (invisible modal), and the MCP libs' `$global:` load-guards crashed every second menu use in one session; plus Env-Restore no longer overwrites live secrets with the `***REDACTED***` marker, and bun >= 1.2's `bun.lock` is detected everywhere.
- Version 4.0 (see `CHANGELOG.md`) made the widget the app's main face and the toolkit a real installed app: root `Widget.bat` + installer-created shortcuts open the widget directly (the DEVKIT title-bar button opens the Control Center GUI); `Install.ps1` became a stepped per-user installer that registers the app in Settings > Apps (HKCU Uninstall key), and new `Uninstall.ps1` removes every trace (widget process, integrations, Run key, PATH, shortcuts, ARP entry, install dir guarded by the `.northstar-installed` marker, and app data unless kept). All twelve tool categories plus `lib/` moved under `tools/` (leaf scripts unchanged - they resolve lib relative to themselves), maintainer tooling moved to `dev/`, and `Setup-Path.bat` was deleted (the installer covers it). It also shipped the lightweight/performance pass: runspaces bootstrap the shared libs once instead of re-parsing ~150KB per cycle (which had also been wiping WidgetCore's sensor caches every cycle), gauge arcs render from a frozen cached geometry table with no easing timer and no DropShadowEffects, the ToolCard hover lost its transform storyboard (the reported gauges-hover CPU/GPU spike), the node table rebuilds only on bucketed changes, junk scans dropped to a 30-minute cadence, and ALL refresh timers now stop while the widget is hidden to the tray.
- The **Tauri v2 rewrite** (this branch, `feat/tauri-v2`, 2026-08) replaced
  the entire `gui/` WPF app - `DevKit-GUI.ps1`/`.xaml`,
  `DevKit-Widget.ps1`/`.xaml`, `Theme.xaml`, `Install.ps1`/`Uninstall.ps1`,
  and the `DevKit.ps1`/`DevKit.bat`/`DevKit-GUI.bat`/`Widget.bat` entry
  points, all deleted - with a Tauri v2 desktop app (Rust + React 19 +
  TypeScript, two windows: widget and control-center) plus a new ratatui
  CLI (`cli/`, binary `devkit`), bridged to the unchanged `tools/` scripts
  by a long-lived NDJSON-RPC PowerShell sidecar
  (`core/Invoke-DevKitRpc.ps1`) and a Rust client crate
  (`crates/devkit-host`). The two pure-logic files the WPF app depended on
  (`DevKit-WidgetCore.ps1`, `DevKit-GuiCore.ps1`) moved from `gui/` to
  `core/` and are otherwise unchanged; every `tools/*` script and manifest
  is unchanged. It shipped alongside a real NSIS installer, a
  minisign-signed auto-updater against GitHub Releases, and a GitHub
  Actions release pipeline (`.github/workflows/release.yml`). See the
  "App Architecture" section above for the full picture, and
  `CHANGELOG.md` for the authoritative dated record once this branch
  lands.
