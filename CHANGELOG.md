# Changelog

All notable changes to Northstar DevKit are documented here.

## [3.5.0] - 2026-07-12

A gradient startup banner and spinner engine, in-menu help across every
tool category, a much wider (and more honest) AI-CLI tracking list, a
curated MCP server catalog with a scan-and-fill-gaps flow, and a batch of
real bugs found and fixed during the audit that produced all of the above.

### Added

- **Animation & color engine** (new `lib\DevKit-UI.ps1`):
  `Test-DevKitAnimationSupport` is a capability probe that fails closed to
  today's plain output on any doubt - it checks `NO_COLOR` is unset,
  `settings.json`'s new `preferences.enableAnimations` is true, console
  output isn't redirected, and a real Windows Console API probe
  (`GetStdHandle`/`GetConsoleMode`/`SetConsoleMode`) confirms virtual
  terminal processing can actually be enabled on the stdout handle.
  `Write-DevKitGradientText` renders 24-bit ANSI gradient text anchored on
  the existing brand blue `#00B4D8`. `Show-DevKitStartupBanner` prints a
  gradient banner exactly once per session - `DevKit.ps1` calls it once at
  startup, never on every menu redraw. `Invoke-DevKitWithSpinner` runs a
  scriptblock behind an animated braille spinner on a dedicated Runspace
  via `BeginInvoke`, for callers whose child output is already fully
  captured/buffered; it falls back to today's plain
  `Write-DevKitStep`/`-Done`/`-Error` sequence whenever animation isn't
  supported or spinner setup fails, invoking the scriptblock exactly once
  either way. `DevKit.ps1` also no longer hardcodes `v3.1.0` in its header
  banner - it now reads the repo-root `VERSION` file dynamically, closing
  a real pre-existing gap where every past version bump required
  remembering to hand-edit that literal string (nobody had, for 3.1.0).
- **In-menu help.** The `_module.psd1` manifest schema gained two optional
  keys: a top-level `Description` (one or two sentences about the whole
  category) and a per-item `Help` (what it does, when to use it, and any
  safety notes). `Show-DevKitModuleMenu` now prints a category's
  `Description` under its header, and `Start-DevKitModuleTools` gained a
  `?` entry that lists every item's Label and Help text. All twelve
  tool-category manifests - Agents & MCP, Ports, Node, Next.js, Vite, Git,
  Docker, System, Workflow, Diagnostics, WiFi, and Maintenance (14 items,
  the largest category) - now have this filled in for every item. The
  Main Menu also gained its own `?` "Getting Started" entry
  (`Show-DevKitGettingStarted`) explaining Active Project linking, the `p`
  suffix convention, `/` search, and the new per-category help.
- **CLI tracking expanded from 6 to 11 tools.** `Get-InstalledAiClis.ps1`
  and `Update-AiClis.ps1` now also detect Supabase CLI, Vercel CLI,
  Railway CLI, Kimi Code CLI, and Augment Code CLI (`auggie`), alongside
  the existing claude/gh/codex/gemini/cursor-agent/aider. Update now
  branches per tool on a real "channel" (`npm` / `npm+builtin` / `scoop` /
  `manual`) instead of assuming everything is an npm package - Supabase's
  CLI cannot be installed globally via npm at all (confirmed against a
  real upstream issue), so it's tracked via Scoop; Vercel and Railway
  prefer their own builtin `upgrade` subcommand before falling back to
  npm; Kimi is deliberately manual-only because the `kimi` command name is
  shared by two unrelated real-world tools (Moonshot AI's npm-based Kimi
  Code CLI and an older Python-based `kimi-cli`) - a live, confirmed
  ambiguity, not a theoretical one - so auto-updating it risked corrupting
  an unrelated tool; Augment Code CLI now shows an explicit
  "Windows support is WSL-only" note instead of a bare "not installed"
  when it's missing from native PATH.
- **MCP server catalog and scan** (new `lib\DevKit-McpCatalog.ps1`,
  `lib\DevKit-McpList.ps1`, `lib\DevKit-McpAddFlow.ps1`; new
  `agents\Add-McpServerFromCatalog.ps1`, `agents\Scan-McpServers.ps1`): a
  10-entry curated catalog of well-known MCP servers (Supabase, Sequential
  Thinking, Context7, GitHub, Filesystem, Notion, Jira/Atlassian, Linear,
  Stripe, Plaid), most offering one or more registration variants - many
  now default to a remote/OAuth-hosted HTTP server rather than a local
  npx package (Supabase, GitHub, Notion, Jira/Atlassian, Linear, and
  Stripe all default to remote; Sequential Thinking and Filesystem are
  local-only; Context7 defaults local with a remote alternate); Plaid is
  marked experimental with no automatable variant at all, since its MCP
  server needs a short-lived OAuth token refresh that a one-time
  registration can't sustain, so picking it just shows a docs pointer.
  `agents\Add-McpServer.ps1` gained a second parameter set
  (`-Transport http -Url -Headers`) - previously it could only register
  local stdio commands, so it structurally could not register 6 of the 10
  catalog entries. `agents\Get-McpServers.ps1`'s `-Scope` parameter is now
  real (it used to be purely informational, since `claude mcp list` has no
  scope flag) - it diffs a listing run from a neutral directory against
  one run from the active project directory to split user/global scope
  from project/local scope. `agents\Scan-McpServers.ps1` cross-references
  configured servers against the catalog per scope and interactively
  offers to add anything missing. `agents\_module.psd1` grew from 5 items
  to 7.

### Fixed

- **`wifi\WiFi-Scan.ps1`**: a PowerShell array-flattening bug made a
  single-network scan report the wrong count ("Found 4 network(s)" when
  only 1 was found), because a returned 1-element array flattened to a
  bare Hashtable whose `.Count` read as its key count instead. Fixed at
  both the function-return and pipeline-assignment sites; a new Pester
  regression test (`tests\Unit\WiFiScan-Parser.Tests.ps1`) was added using
  real captured single-network `netsh` output, since the pre-existing
  fixture only ever exercised 3-network input.
- **`lib\DevKit-McpList.ps1`**'s server-name parser was silently dropping
  server names containing spaces (e.g. a real connector named
  `claude.ai Notion`) due to an over-restrictive character-class regex;
  fixed to split on the first `': '` instead. Caught via a live run
  against this machine's actual configured MCP servers.
- **`docker\Docker-Nuke.ps1`**'s "nothing to nuke" early-exit check
  special-cased `-KeepVolumes` but not `-KeepImages`, so running
  `-KeepImages` on a machine with only images (no containers/volumes/
  networks) skipped straight to a live confirmation prompt for an
  operation that would end up deleting nothing. Fixed to mirror the
  existing `-KeepVolumes` pattern.
- **`diagnostics\System-DevInfo.ps1`**: (a) the disk-usage loop divided by
  zero on an empty/unmounted local-disk-type volume (`Size` 0 or null),
  which threw and silently dropped every disk enumerated after it from the
  report behind a misleading "Could not query WMI/CIM" message - it now
  skips just that one disk with a clear "unavailable" line and continues;
  (b) network-adapter selection picked whichever "Up" adapter enumerated
  first with no preference for one with a real default gateway, so a
  machine with a Hyper-V/WSL/VPN virtual adapter could report that
  adapter's NAT-only IP instead of the machine's real network identity -
  it now prefers an adapter with a non-null default gateway before falling
  back.
- **`node\Nuke-And-Reinstall.ps1`**: the pre-confirmation warning shown
  right before the typed-`nuke` safety gate didn't match what the script
  actually deletes (it claimed `dist` and `.vite` caches, which are never
  touched by default, and omitted `.turbo`, which always is). Fixed the
  displayed text only - no change to actual deletion behavior.
- **Repo-wide color-convention cleanup**: `AGENTS.md` documents Yellow as
  reserved for real warnings, not routine progress chrome. Roughly 25+
  stray Yellow progress-chrome lines were corrected to Cyan/Gray as
  appropriate across `ports/`, `node/`, `vite/`, `git/`, `docker/`,
  `system/`, `workflow/`, and `diagnostics/`.
- Small doc/comment accuracy fixes: missing `.PARAMETER` entries added
  (`system\Env-Backup.ps1`'s `-Force`, `wifi\WiFi-FastMode.ps1`'s
  `-KeepDNS`/`-Force`), a stale/missing script-header footer added
  (`node\Clear-NpmCache.ps1`), `.SYNOPSIS` lines brought in line with the
  repo-wide template (`system\Install-/Uninstall-ShellIntegration.ps1`),
  dead/unused variables removed (`git\Git-StatusAll.ps1`,
  `diagnostics\DevKit-Doctor.ps1`), and a missing version-display line
  added to `docker\Docker-Cleanup.ps1` to match its sibling
  `Docker-Nuke.ps1`.

### Known Issues

Real gaps found during this sprint's audit and deliberately left
unchanged, since fixing them would alter user-facing mutating behavior
rather than just correct wrong information:

- Many mutating scripts across `ports/`, `node/`, `nextjs/`, `vite/`,
  `git/`, `docker/`, `system/`, and `workflow/` predate the shared
  `Confirm-DevKitDestructiveAction` helper and hand-roll their own y/n
  prompts, so they don't honor `settings.json`'s global
  `confirmDestructive` toggle the way newer destructive scripts do
  (already documented in `AGENTS.md`).
- `maintenance\Repair-SystemFiles.ps1` and
  `maintenance\Reset-WindowsUpdate.ps1` both default to attempting the
  real mutating action behind just a confirmation prompt (`-DryRun` is
  opt-out, not opt-in) - the inverse of the safe-by-default pattern the
  rest of `maintenance/` follows, and structurally the same shape as the
  2026-07-11 incident `AGENTS.md` already documents for
  `Reset-WindowsUpdate.ps1` specifically.
- `git\Git-SyncFork.ps1` has no `-DryRun`/preview mode at all, unlike its
  sibling `Git-Cleanup.ps1`.
- `system\Uninstall-ShellIntegration.ps1` and
  `system\Unregister-DevKitTerminalProfile.ps1` delete real registry/file
  state with no confirmation prompt of any kind.
- `docker\Docker-Cleanup.ps1`'s displayed "Custom networks" count can
  overstate what `-AllUnused` actually prunes - Docker has no built-in
  "dangling" filter for networks, so the count includes in-use ones.
- A handful of judgment-call color/severity inconsistencies (e.g.
  `ports\Kill-AllNode.ps1`'s failure severity vs. its siblings,
  `maintenance\Manage-Services.ps1`'s disclaimer color) and duplicated
  logic (`system\Edit-Path.ps1`/`Shell-Reload.ps1` share a copy-pasted
  helper function; `diagnostics\DevKit-Doctor.ps1`/`System-DevInfo.ps1`
  each separately implement tool-version detection) were flagged but not
  changed.
- `AGENTS.md`'s Project Structure tree was missing a few files that exist
  on disk and now have in-menu help text (`node\Check-NpmCacheSize.ps1`,
  `nextjs`'s `Clear-NextCache.bat`/`Clear-TurboCache.bat`, and `system`'s
  four opt-in setup scripts) - fixed as part of this release's
  documentation pass.

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
