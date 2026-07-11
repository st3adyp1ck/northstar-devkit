# Changelog

All notable changes to Northstar DevKit are documented here.

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
