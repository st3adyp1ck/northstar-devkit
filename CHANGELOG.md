# Changelog

All notable changes to Northstar DevKit are documented here.

## [3.1.0] - 2026-07-11

Arrow-key navigation across every menu, and two new tool categories: real
Windows maintenance/tuning tools (not just a dev-environment health check),
and an AI CLI & MCP server manager.

### Added

- **Arrow-key navigation** (`Show-DevKitInteractiveMenu` in
  `lib\DevKit-Common.ps1`). Every menu - Main Menu, each tool category,
  Projects, and Search results - now supports Up/Down + Enter to move and
  select, Escape to go back, while typing a number (and the `p` suffix for
  a one-off project override) still works exactly as before. On a console
  that can't do raw key reads (redirected input, CI, some non-interactive
  hosts), it transparently falls back to the classic `Read-Host` prompt -
  every existing scripted/piped-input workflow keeps working unchanged.
- **`[12] Maintenance`** - 14 real Windows maintenance/tuning tools across
  six areas: disk & storage cleanup (`Clear-DiskJunk.ps1`,
  `Show-DiskUsageReport.ps1`), startup & services tuning
  (`Manage-StartupPrograms.ps1`, `Manage-Services.ps1`), system repair
  (`Repair-SystemFiles.ps1` for SFC/DISM, `Reset-WindowsUpdate.ps1`),
  scheduled tasks & event log triage (`Get-ScheduledTasksReport.ps1`,
  `Get-RecentEventErrors.ps1`), power & performance tuning
  (`Set-PowerPlan.ps1`, `Set-VisualEffects.ps1`, `Test-PageFileConfig.ps1`),
  and hardware health (`Get-DiskHealthReport.ps1`, `Get-BatteryReport.ps1`,
  `Invoke-MemoryDiagnostic.ps1`). Every mutating tool defaults to a safe
  read-only report and requires an explicit flag plus confirmation
  (`Confirm-DevKitDestructiveAction`) to actually change anything.
- **`[13] Agents & MCP`** - manage AI coding-agent CLIs and Claude Code's
  MCP servers, both globally and per linked project:
  `Get-InstalledAiClis.ps1` (detect claude/gh/codex/gemini/cursor-agent/
  aider), `Update-AiClis.ps1` (best-effort npm-based updates), and
  `Get-McpServers.ps1` / `Add-McpServer.ps1` / `Remove-McpServer.ps1`
  wrapping `claude mcp list/add/remove`, using the existing active-project
  system to target a specific project's MCP scope.

### Fixed

- **A real "Select an app to open" dialog bug**, hit while building the
  Agents & MCP pack: on a machine with more than one `gh` on PATH,
  `Get-Command`'s first match can be an extension-less shim rather than a
  `.exe`/`.cmd` wrapper, and invoking that with PowerShell's `&` operator
  makes it fall back to ShellExecute, popping a real Windows dialog instead
  of failing cleanly. Added `Get-DevKitWindowsExecutable` (`lib\DevKit-
  Common.ps1`) - resolves to only a recognized Windows-executable match (or
  a native PS command, which never hits ShellExecute) - and use it anywhere
  this codebase invokes a user-installed CLI by name.
- A background build-time agent for this release ran `Reset-WindowsUpdate.ps1`
  for real instead of the instructed `-DryRun` while self-testing; the
  safety system blocked it before any change landed (independently
  confirmed via service-state event logs and folder timestamps). See
  `AGENTS.md`'s Security Considerations for the guardrail this added.

## [3.0.0] - 2026-07-11

A full review-driven overhaul: every confirmed critical/high bug fixed, a
browsable project-linking system (the headline ask for this release), and
a manifest-driven menu architecture that replaces ~40 duplicated blocks of
dispatch logic with one reusable implementation.

### Added

- **Browsable project linking.** Every tool that needs a project directory
  now goes through a shared picker instead of a bare typed prompt: pick
  from previously-linked projects (sorted by pinned, then most recently
  used), browse for a folder via a real Windows folder dialog, use the
  current directory, or type a path manually. Whatever you choose becomes
  the **Active Project**, shown in the header and reused silently by every
  subsequent tool for the rest of the session. Append `p` to any menu
  number (e.g. `4p`) to use a different project for one run without
  disturbing the active one. New `[10] Projects` menu to set/clear the
  active project and manage the linked list (rename/pin/unlink/relink).
- **Manifest-driven tool menus.** Each tool category (Port/Node/Next.js/
  Vite/Git/Docker/System/Workflow/Diagnostics/WiFi Tools) is now described
  by a small `_module.psd1` data file instead of a hand-written menu
  function. Adding a new tool to an existing category is a manifest entry,
  not a `DevKit.ps1` edit.
- **Search/jump** (`/` from the Main Menu): search every tool category's
  items by keyword and jump straight to one instead of drilling through
  submenus by number.
- **A reusable confirmation gate** (`Confirm-DevKitDestructiveAction`) and
  a settings file (`%LOCALAPPDATA%\NorthstarDevKit\settings.json`,
  `preferences.confirmDestructive`) so destructive actions share one
  correctly-implemented (case-sensitive typed-phrase, or y/N) prompt.
  `docker\Docker-Nuke.ps1` now uses it as the reference example.
- **Pester test suite** (`tests/Unit`, wired into CI) covering the parsers
  and converters this release's review found real bugs in: package-manager
  detection, PATH de-duplication, the `.env` template parser, the git-
  remote-to-browsable-URL converter, and the WiFi network scan parser.
- `node\Check-NpmCacheSize.bat` (the one script in the repo missing its
  batch wrapper).

### Fixed

Selected highlights - see the full 3.0 code review for the complete list
of ~150 confirmed findings:

- **`system\Env-Restore.ps1` could not run at all.** Loose top-level code
  sat between `param()` and an explicit `begin {}` block, which made
  PowerShell treat the literal token `begin` as a command name instead of
  a pipeline block - every invocation threw `The term 'begin' is not
  recognized...`. Pre-existing; found and fixed during this release.
- `workflow\Open-Repo.ps1`: the resolved URL is now validated as a real
  `http(s)://` address before being handed to `Start-Process`, closing a
  local-code-execution path via a malicious/tampered git remote.
- `git\Git-SyncFork.ps1`: rebase-sync now force-pushes with
  `--force-with-lease` (fetching the remote ref first) instead of a plain
  `-f`.
- `git\Git-Cleanup.ps1`: merged-branch detection now compares against the
  repo's actual default branch instead of bare `HEAD`, so an unmerged
  branch can no longer be offered for deletion.
- `wifi\WiFi-Scan.ps1`: fixed the SSID/BSSID regex collision that meant
  the scanner had never successfully parsed a single network.
- `wifi\WiFi-FastMode.ps1`: fixed a guaranteed parameter-binding crash when
  launched from the DevKit.ps1 menu.
- `docker\Docker-Nuke.ps1`: the "type NUKE" confirmation is now
  case-sensitive (typing `nuke` no longer silently proceeds).
- `docker\Docker-QuickLogs.ps1`: fixed a single-container array-collapse
  bug and a `-Follow $false` positional-parameter-binding trap.
- `node\Nuke-And-Reinstall.ps1` / `nextjs\Next-FullClean.ps1`: package
  manager is no longer silently re-detected (and downgraded to npm) after
  the project's own lock file has already been deleted.
- `nextjs\Next-FullClean.ps1`: `-StartDev` now launches the dev server
  from the actual project directory, not wherever the process happened to
  be beforehand.
- `ports\Kill-Port.ps1`, `Kill-AllNode.ps1`, `Scan-Ports.ps1`: process
  identity is now re-verified immediately before `Stop-Process`, closing a
  time-of-check-to-time-of-use gap between showing a process and killing
  it.
- `.bat` wrappers across the repo now propagate real script failures
  correctly instead of always exiting 0.
- Color-output convention corrected repo-wide: Yellow is reserved for real
  warnings; routine progress/chrome text moved off Yellow; a handful of
  messages that hard-`exit`ed were relabeled from "WARNING" to "ERROR" to
  match what they actually do.

### Changed

- `DevKit.ps1` dropped from 691 lines to ~180: it now dot-sources
  `lib\DevKit-Common.ps1` (previously the one script in the repo that
  didn't) and delegates all ten tool-category submenus to the generic
  manifest dispatcher.
- Version banner and `.VERSION` metadata bumped to 3.0.0 across
  `DevKit.ps1` and `lib\DevKit-Common.ps1`.

## [2.1.0] - prior to this repository's public history

Unified the toolkit under a shared helper module (`lib\DevKit-Common.ps1`),
added package-manager auto-detection, completed batch-wrapper coverage,
and fixed a series of PowerShell 7 / path-validation / process-killing
bugs. Recorded here retrospectively; see git history for specifics.
