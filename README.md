<div align="center">

<img src="https://img.shields.io/badge/Northstar-DevKit-4.0.0-blue?style=for-the-badge&logo=powershell&logoColor=white" alt="Northstar DevKit">

<h3>A powerful, dependency-free Windows toolkit for modern web developers</h3>

<p>
  <a href="https://www.northstarcoding.com">
    <img src="https://img.shields.io/badge/Made%20by-Northstar.com-00b4d8?style=flat-square" alt="Made by Northstar">
  </a>
  <a href="https://github.com/st3adyp1ck/northstar-devkit/releases">
    <img src="https://img.shields.io/github/v/release/st3adyp1ck/northstar-devkit?style=flat-square&color=00b4d8" alt="Latest Release">
  </a>
  <a href="LICENSE">
    <img src="https://img.shields.io/badge/License-MIT-green?style=flat-square" alt="License">
  </a>
</p>

<p>
  <a href="#-download"><strong>Download</strong></a> •
  <a href="#-quick-start"><strong>Quick Start</strong></a> •
  <a href="#-features"><strong>Features</strong></a> •
  <a href="#-documentation"><strong>Docs</strong></a> •
  <a href="https://www.northstarcoding.com"><strong>Website</strong></a>
</p>

</div>

---

## ⬇️ Download

### Option 1: Installer (recommended)
<a href="https://github.com/st3adyp1ck/northstar-devkit/releases">
  <img src="https://img.shields.io/badge/Download-Installer-blue?style=for-the-badge&logo=github" alt="Download Installer">
</a>

1. Grab the latest `DevKit_x.y.z_x64-setup.exe` from [GitHub Releases](https://github.com/st3adyp1ck/northstar-devkit/releases)
2. Run it — a minisign-signed NSIS installer, fully per-user, **no admin rights needed**
3. Launch **DevKit** from the Start Menu or Desktop icon — it opens the companion widget
4. **Uninstall:** Settings > Apps > DevKit, like any other Windows app

The app checks for updates automatically (throttled to once per 24h) and via a **Check for Updates** button in the widget — download, install, and relaunch happen in place through a signed update feed.

### Option 2: Build from source
```bash
git clone https://github.com/st3adyp1ck/northstar-devkit.git
cd northstar-devkit/app
pnpm install
pnpm tauri build
```
Requires **Rust** (stable toolchain) and **Node.js + pnpm** — no other external dependencies. This builds the whole Cargo workspace, so the installer lands at the repo root's `target/release/bundle/nsis/DevKit_<version>_x64-setup.exe`.

> **The `devkit` CLI has no installer yet.** Build it from source instead — `cargo build --release -p devkit-cli` — and run the resulting `target/release/devkit.exe`.

---

## 🚀 Quick Start

1. Download the installer from [GitHub Releases](https://github.com/st3adyp1ck/northstar-devkit/releases) (or build from source — see above)
2. Run it — per-user install, no admin needed
3. Launch **DevKit** from the Start Menu/Desktop icon — it opens the companion widget
4. Click **DEVKIT** in the widget's title bar for the full Control Center

The **companion widget is the main face of DevKit** — a small always-on window with your system's vitals, running dev servers, git status, notes, and one-click tools. Its title-bar **DEVKIT** button opens the **DevKit Control Center**: every tool as a searchable card, with a dynamic form for whatever it needs and its real output streaming live into the dialog as it runs — no separate terminal window to babysit. For project-specific actions (Git, Next.js, Vite, etc.), DevKit prompts you with a picker: pick a previously-linked project, browse for a folder, use the current directory, or type a path — no more retyping the same path for every action. Whatever you pick becomes your **Active Project**, shared between the widget, the Control Center, and the `devkit` CLI.

---

## 🎉 New in Tauri v2

DevKit was rebuilt from the ground up — from a PowerShell/WPF app into a Tauri v2 desktop app. The 65 PowerShell tools underneath are untouched; everything around them is new:

- **A real cross-window app.** The companion **widget** and the **Control Center** are now two Tauri windows — React 19 + TypeScript over a Rust backend — replacing the old WPF widget/GUI pair panel-for-panel, plus a new `devkit` terminal CLI.
- **A long-lived PowerShell sidecar**, not a process-per-click. `core/Invoke-DevKitRpc.ps1` speaks NDJSON-RPC over stdin/stdout across three worker lanes plus a dedicated writer runspace, and the Rust side (`crates/devkit-host`) respawns it with backoff if it ever dies.
- **Tool output streams live**, inline, into the Control Center's run dialog or the widget's Quick Actions panel — no more a separate terminal window popping up per tool.
- **A new `devkit` CLI** — a ratatui terminal menu that replaces `DevKit.bat`, with arrow-key nav, `/` search, a `p`-suffix project override, digit-jump, and a native Windows file picker for tools that need one. Built from source only for now: `cargo build --release -p devkit-cli`.
- **A signed installer and real auto-update**, built and published through a GitHub Actions release pipeline — push a `vX.Y.Z` tag, the pipeline builds and signs it, a human reviews and publishes the draft release, and the in-app updater picks it up within 24h (or immediately via "Check for Updates").

See [AGENTS.md](AGENTS.md) for the full architecture writeup.

## 🎉 New in 4.0

> **Historical note:** this section, and every "New in …" section down through [New in 3.0](#-new-in-30), documents the release history of the original **PowerShell/WPF** app — including its own, separately-numbered "4.0" release. That app has since been fully replaced by the Tauri v2 rewrite described above; none of the `.bat` launchers or WPF UI described below exist in the repo anymore.

- **The widget is the app.** DevKit now opens as the little always-on companion window — from the Start Menu/Desktop icon or `Widget.bat` — with system vitals, dev servers, git status, and one-click tools up front, and the full Control Center one click away via the title-bar **DEVKIT** button. And it's a real Windows app now: a stepped installer (fully per-user, no admin needed) registers DevKit in Settings > Apps, and the matching uninstaller removes every trace — files, shortcuts, PATH, the startup entry, even your saved settings if you want them gone.
- **A lightweight pass you can feel.** Hovering the widget's gauges no longer spikes your CPU/GPU, its background checks stopped re-reading 150 KB of script every four seconds (nvidia-smi was being spawned on a loop), and a widget hidden to the tray now sleeps completely — every timer stops, so it costs essentially nothing until you bring it back.
- **A tidier repo.** All twelve tool categories and the shared libraries moved under `tools/`, maintainer-only files moved to `dev/`, and the root now holds just the launchers, the installer/uninstaller, and docs. Direct script invocations move with them: `.\tools\ports\Kill-Port.ps1 -Port 3000`.
- **`Setup-Path.bat` is retired** — the installer handles PATH (reversibly), shortcuts, and startup in one pass.

## 🎉 New in 3.8

- **A git graph worth looking at.** The widget's Git flyout now draws your project's history like a modern Git GUI: bright colored lanes, smooth gradient curves that flow from each branch into its parent, branch/tag pills, and a ring around HEAD — with ahead/behind counts in the header and fetch/pull/push underneath. No more ASCII art.
- **The widget became the mission control.** A Disk Free dial (disk-full breaks builds), process ages and a per-server kill button in the node table (plus ports you can click to open in the browser), a git badge under the project picker (branch, uncommitted, ahead/behind, stashes), an `.env` drift warning when your project is missing template keys, a "reboot pending" hint, and one-click Editor / Explorer / Terminal / Run Script launchers for the active project.
- **Both desktop apps got a fit-and-finish pass.** Themed thin scrollbars everywhere, destructive tools show an ember Run button, dialogs submit with Enter and close with Escape or an [x], search behaves the way you expect, cards react to hover, and the terminal UI's gradient now uses the real logo colors.
- **Eight new tools.** Reserved-port-range finder (why a "free" port won't bind), an HTTP health check for dev endpoints, `git standup` across your repos, a package.json script picker, stale `node_modules` reclaimer, a hosts-file editor, an `.env` drift checker, and a dev-text converter box (Base64/URL/timestamps/GUID/SHA-256/JWT).
- **A deep bug sweep.** Two notable fixes: the Agents "Manage..." dialog opened an invisible frozen window, and every MCP menu tool crashed on its second use in a session. Plus `Env-Restore` can no longer overwrite your real secrets with redacted placeholders. Full details in [CHANGELOG.md](CHANGELOG.md).

## 🎉 New in 3.7

- **A companion widget for your desktop.** Click the gauge icon in the DevKit title bar and a small always-on-top window keeps watching your system after DevKit closes: CPU, memory, and GPU load with temperatures (honest "n/a" when a sensor doesn't exist on your machine), the Node processes you're running with their ports, and quick-action buttons (Clear NPM Cache, Kill All Node, Kill Port, Doctor) that fire up the real tools.
- **Your AI tooling's wiring, at a glance.** Two expandable boxes show Claude Code and Kimi Code: CLI version plus every MCP server for you and for the selected project, with Connected / Disconnected / Requires Auth badges (Claude is health-checked live in the background; Kimi is read from its documented `mcp.json` files, since it has no headless status command).
- **It lives in the system tray.** Balloon hints, a dark branded right-click menu (Show/Hide, Open DevKit, Start with Windows, Exit), Explorer-restart resilience, and single-instance behavior — clicking the gauge again just brings the running widget back up. The project selector on top is the same Active Project shared with the GUI and terminal UI.

## 🎉 New in 3.6

- **A branded desktop app.** `DevKit-GUI.bat` opens a native dark UI themed on the Northstar compass-rose logo — custom window chrome, brushed-metal title, sapphire/ember accents — rendering all twelve tool categories as navigable cards with live search, chips showing what each tool needs (`PROJECT`/`FILE`/`INPUT`) and a `CAUTION` flag for state-changing tools, plus full linked-project management and a Getting Started page.
- **Zero changes to the tools themselves.** Pressing Run opens the tool in a real terminal window (Windows Terminal when installed) with the same menus, colors, spinners, and confirmations it always had — the GUI never re-implements or dumbs down a script. The classic terminal UI (`DevKit.bat`) is untouched and fully supported.
- **Still dependency-free.** The app is WPF hosted by PowerShell itself — no runtime to install, no build step, still a portable folder.

## 🎉 New in 3.5

- **Animated terminal experience.** A gradient startup banner and an animated spinner for longer-running steps, built on the existing brand blue — gracefully degrades to today's plain look on a console (or a `NO_COLOR`/redirected-output setup) that doesn't support it, and can be turned off entirely via the new `enableAnimations` setting.
- **In-menu help, everywhere.** Every tool category now has a `[?]` entry that lists what each numbered option does and when to use it, and the Main Menu has a new `[?] Getting Started` screen that walks first-time users through Active Project linking, the `p` suffix, and `/` search.
- **CLI tracking expanded from 6 to 11 tools.** Supabase CLI, Vercel CLI, Railway CLI, Kimi Code CLI, and Augment Code CLI (`auggie`) join claude/gh/codex/gemini/cursor-agent/aider — each is now updated through whichever channel actually fits it (npm, the tool's own built-in upgrade command, or Scoop) instead of assuming everything is npm.
- **MCP server catalog + scan.** A curated catalog of well-known MCP servers (Supabase, GitHub, Notion, Linear, Stripe, and more) turns adding one into a guided picker instead of hand-typing a `claude mcp add` command, and the new "Scan MCP Setup" option in the Agents & MCP menu checks your active project (and this machine) against the catalog and offers to add anything missing.

## 🎉 New in 3.1

- **Arrow-key navigation.** Every menu now supports Up/Down + Enter to move and select, Escape to go back — typing a number still works exactly as before, and it falls back automatically on a console that can't do raw key reads.
- **`[12] Maintenance`** — 14 real Windows maintenance/tuning tools: disk & storage cleanup, startup & services tuning, SFC/DISM repair + Windows Update reset, scheduled tasks & event log triage, power/performance tuning, and hardware health. Every mutating tool defaults to a safe report and, when run interactively, offers to apply its changes right after the report — flags + confirmation remain for automation.
- **`[13] Agents & MCP`** — detect and update installed AI CLIs (claude, gh, codex, gemini, cursor-agent, aider) and manage Claude Code's MCP servers globally or per linked project.

## 🎉 New in 3.0

- **Browsable project linking.** Link a project once (by browsing to it, or just using your current directory) and every tool reuses it silently for the rest of the session — no more retyping the same path over and over. Append `p` to any menu number (e.g. `4p`) to use a different project for a single run without disturbing your active one. Manage linked projects from the new `[10] Projects` menu.
- **Search** (`/` from the Main Menu) — jump straight to any tool by keyword instead of drilling through submenus.
- **~150 confirmed bugs fixed**, including a couple of genuinely serious ones: `Env-Restore.ps1` couldn't run at all, `WiFi-Scan.ps1` had never successfully parsed a network, and a Docker Nuke confirmation that accepted lowercase `nuke`. Full details in [CHANGELOG.md](CHANGELOG.md).
- **Manifest-driven menus** under the hood — every tool category is now a small `_module.psd1` data file instead of hand-written dispatch code, so adding a new tool no longer means editing `DevKit.ps1`.

---

## ✨ Features

### The App

| 🪟 **Companion Widget** | 🗂️ **Control Center** | ⌨️ **`devkit` CLI** | 🔄 **Auto-Update** |
|---|---|---|---|
| Gauges, Node/Ports, Git (commit graph), GitHub, MCP, Notes/On-Deck, Files, Quick Actions, and a collapsible embedded terminal — always-on, one click from the tray | Every tool as a searchable card with a dynamic form and live streamed output | A ratatui terminal menu — arrow keys, `/` search, digit-jump (build from source: `cargo build --release -p devkit-cli`) | Checks GitHub Releases on launch and on demand, then downloads, installs, and relaunches in place |

### The Tools

<div align="center">

| 🔌 **Ports** | 📦 **Node.js** | ▲ **Next.js** | ⚡ **Vite** |
|---|---|---|---|
| Scan & kill dev ports | Clear caches, nuke `node_modules` | Clean `.next` & Turbopack caches | Fresh dev server & preview builds |

| 🐙 **Git** | 🐳 **Docker** | 🛠️ **System** | 🔧 **Workflow** |
|---|---|---|---|
| Cleanup, status all repos, sync forks | Nuke containers & images, tail logs | Edit PATH, backup/restore env | Open IDE/repo, copy `.env` templates |

| 🔍 **Diagnostics** | 📡 **WiFi** | 📁 **Projects** |
|---|---|---|
| Health check & system info | Optimize DNS, scan networks, speed test | Link, switch, and manage project directories |

| 🧰 **Maintenance** | 🤖 **Agents & MCP** |
|---|---|
| Disk cleanup, startup/services tuning, SFC/DISM repair, Windows Update reset, scheduled tasks & event logs, power/performance tuning, hardware health | Detect/update 11 AI CLIs, add MCP servers from a curated catalog or by hand, and scan for missing ones, globally or per project |

</div>

---

## 🖥️ Usage

### Control Center
Open it two ways: docked, click the **DEVKIT** plate at the foot of the tray rail and it slides out as a tray inside the same window — or for the full-size standalone window, use the floating widget's title-bar **DEVKIT** button or the system-tray menu:

- **Browse or search** the full tool catalog — every tool rendered as a card from its `_module.psd1` manifest, grouped in the left rail (Development, Version Control & Containers, System & Workflow, Maintenance & Agents, Network) with live search across the top.
- Cards carry **Project** (runs against your Active Project), **Input** (needs parameters), and **Caution** (changes system state) badges at a glance.
- **Run** opens a dialog with a dynamic form built from the tool's manifest — text/number fields, yes/no toggles, a project picker when needed — and streams the tool's real stdout/stderr into that same dialog live as it runs. Nothing pops open in a separate terminal window.
- **Caution** tools ask for confirmation first (per the widget's **confirmDestructive** setting).

### Companion Widget
The widget is DevKit's main face — it opens from the Start Menu/Desktop icon straight to the desktop and tray. Docked, the **DEVKIT** plate at the foot of the tray rail slides the Control Center out as a tray in the same window; floating, the title-bar **DEVKIT** button opens it as its own window:

- **Gauges**: CPU / Memory / GPU dials with temperatures where the machine exposes them ("n/a" when it doesn't), plus a Disk Free dial and a reboot-pending hint. Click a dial for a flyout of its top processes with a guarded kill button; the Memory flyout adds a one-click **Free Memory**.
- **Node & Ports**: collapsed by default — expand it to see every running `node` process with its memory, age, and listening ports; click a port to open it in your browser, or kill just that one process. Flags ports stuck inside a Windows-reserved range (Hyper-V/winnat).
- **Git**: a drawn commit graph with colored lanes and gradient curves where a branch flows into its parent, branch/tag pills, a HEAD ring, open-PR pills (`#42`, drafts dashed) on the head commits they point at — click one for the PR's details, hover to see that PR's commits light up as a ribbon — ahead/behind counts and stash count, and fetch/pull/push. Click any commit to expand its details inline (message, author, per-file stats). Remote refs freshen themselves via a throttled background fetch (about once a minute per repo, and it can never pop a credential prompt), so bot-pushed branches like Dependabot's show up without you pressing Fetch first — and the log window grows from 40 up to 400 commits until every open PR's head fits, so a busy trunk can't push your PRs out of the chart.
- **GitHub**: the active project's open pull requests and issues, read straight from the `gh` CLI, one click to open either in the browser.
- **MCP**: expandable **Claude Code** / **Kimi Code** boxes listing that project's MCP servers alongside your user-scope ones, with Connected / Disconnected / Requires Auth badges.
- **Notes/On-Deck**: quick per-project sticky notes, plus an on-deck list whose items advance Not Started → In Progress → Done with a click.
- **Files**: a lightweight file explorer scoped to the active project.
- **Quick Actions**: **Doctor** (full environment check, reads only) and **Close-Out** (the one-click end-of-day cleanup — stops dev processes, frees their ports, clears temp/junk, trims memory back to the OS) with **Preview first** (dry run) and **Deep** (adds the Recycle Bin, the package-manager cache, and the active project's framework caches) beside it — each streams live into the same inline console — plus the widget's own **Settings** (confirm-before-destructive, animations, update checks) and an `.env` drift warning when the active project is missing template keys. An amber **ADMIN** badge in the title bar shows whenever the app is running elevated (see Admin Mode below).
- **Terminal**: collapsed by default; expand it for a real embedded terminal (ConPTY-hosted `pwsh`/`powershell`), already in your project folder — interactive CLIs just work because it genuinely is a terminal.
- **Project selector**: the same Active Project shared with the Control Center and the `devkit` CLI.
- **Tray**: closing the widget just hides it to the tray — right-click the icon for **Show/Hide Widget**, **Open DevKit Control Center**, **Start with Windows**, and **Exit**.

### Admin Mode (optional, always-elevated launching)
Some cleanup simply reaches further with Administrator rights — Close-Out's `Windows\Temp` and Windows Update cache, and working-set trims of elevated processes. If you want DevKit elevated by default, run `tools\system\Set-DevKitAdminMode.ps1` once (or **System Tools → Enable DevKit Admin Mode** in the app): after a single UAC consent it registers a scheduled task that launches the app with highest privileges, and puts a **DevKit (Admin)** shortcut on your Desktop and Start Menu — no UAC prompt ever again. Exit the tray app first, then relaunch via that shortcut; the title bar shows an amber **ADMIN** badge when it's really elevated, and Start-with-Windows moves from the registry Run key onto the task (Windows can't auto-start elevated apps from the Run key). `Set-DevKitAdminMode.ps1 -Off` removes every trace. The trade-off, stated plainly: while elevated, every tool and the embedded terminal run as Administrator.

### `devkit` CLI
There's no installer for the CLI yet — build it from source:

```powershell
cargo build --release -p devkit-cli
.\target\release\devkit.exe
```

It's an interactive ratatui terminal menu that replaces the old `DevKit.bat`, reading the same tool catalog the apps render:

```
↑/↓ move   Enter open/run   / search   p project   digits+Enter jump   Esc back/quit
```

- Arrow keys or a typed number both work; `/` jumps to search; typing digits (e.g. `12` then Enter) jumps straight to that entry.
- Append `p` to a selection to run it against a different project for just that one run, without disturbing your Active Project.
- A tool that needs a file prompts you with a real native Windows file picker (shells out to a hidden `System.Windows.Forms.OpenFileDialog`).
- One-shot subcommands: `devkit doctor` (pings the sidecar) and `devkit catalog` (prints the tool catalog as JSON).

### Run Individual Scripts
Every tool is a plain PowerShell script — the widget, the Control Center, and the CLI all run these exact same files under the hood, and you can run them directly too:

```powershell
# Kill a stuck port
.\tools\ports\Kill-Port.ps1 -Port 3000

# Full Next.js reset
.\tools\nextjs\Next-FullClean.ps1 -Path "C:\my-project"

# Clean a Git repo
.\tools\git\Git-Cleanup.ps1 -Path "C:\my-project"

# Check environment health
.\tools\diagnostics\DevKit-Doctor.ps1
```

---

## 📚 Documentation

These are the same 65 scripts the widget, the Control Center, and the `devkit` CLI all run under the hood — invoke them directly any time:

### Port Tools
```powershell
.\tools\ports\Scan-Ports.ps1
.\tools\ports\Kill-Port.ps1 -Port 3000
.\tools\ports\Kill-AllNode.ps1
.\tools\ports\Show-ExcludedPortRanges.ps1          # why a "free" port refuses to bind (Hyper-V/winnat)
.\tools\ports\Test-DevEndpoint.ps1 -Url "https://localhost:7181"   # HTTP status, latency, cert expiry
```

### Node.js Tools
```powershell
.\tools\node\Clear-NpmCache.ps1
.\tools\node\Remove-NodeModules.ps1 -Path "C:\my-project"
.\tools\node\Nuke-And-Reinstall.ps1 -Path "C:\my-project"
.\tools\node\Start-PackageScript.ps1 -Path "C:\my-project"        # arrow-key picker for package.json scripts
.\tools\node\Find-StaleNodeModules.ps1 -Path "C:\Projects"        # report sizes/ages, offer gated cleanup
```

### Next.js Tools
```powershell
.\tools\nextjs\Clear-NextCache.ps1
.\tools\nextjs\Next-DevFresh.ps1 -Path "C:\my-project"
.\tools\nextjs\Next-FullClean.ps1 -Path "C:\my-project"
```

### Vite Tools
```powershell
.\tools\vite\Vite-DevFresh.ps1 -Path "C:\my-project"
.\tools\vite\Vite-PreviewBuild.ps1 -Path "C:\my-project"
```

### Git Tools
```powershell
.\tools\git\Git-Cleanup.ps1 -Path "C:\my-project"
.\tools\git\Git-StatusAll.ps1 -Path "C:\Projects"
.\tools\git\Git-SyncFork.ps1 -Path "C:\my-project"
.\tools\git\Get-GitStandup.ps1 -Hours 48           # your recent commits across repos (standup notes)
```

### Docker Tools
```powershell
.\tools\docker\Docker-Nuke.ps1 -DryRun
.\tools\docker\Docker-Cleanup.ps1
.\tools\docker\Docker-QuickLogs.ps1
```

### System Tools
```powershell
.\tools\system\Edit-Path.ps1 -Show
.\tools\system\Edit-Path.ps1 -Clean
.\tools\system\Env-Backup.ps1 -OutputPath "C:\Backups"
.\tools\system\Env-Restore.ps1 -BackupFile "backup.json"
.\tools\system\Shell-Reload.ps1
.\tools\system\Edit-HostsFile.ps1 -Show            # view hosts entries; interactive add/remove/toggle
.\tools\system\Set-DevKitAdminMode.ps1 -DryRun     # preview Admin Mode (always-elevated launching)
.\tools\system\Set-DevKitAdminMode.ps1             # enable: one UAC consent, then no per-launch prompt
.\tools\system\Set-DevKitAdminMode.ps1 -Off        # disable, removing every trace
```

### Workflow Tools
```powershell
.\tools\workflow\Code-Here.ps1 -Path "C:\my-project"
.\tools\workflow\Open-Repo.ps1 -Path "C:\my-project"
.\tools\workflow\Copy-EnvTemplate.ps1 -Path "C:\my-project" -Interactive
.\tools\workflow\Compare-EnvFiles.ps1 -Path "C:\my-project"      # .env vs template drift (keys only)
.\tools\workflow\Convert-DevText.ps1                             # Base64/URL/timestamps/GUID/SHA-256/JWT
.\tools\workflow\Close-OutSession.ps1 -DryRun                    # preview the end-of-day cleanup
.\tools\workflow\Close-OutSession.ps1                            # stop dev processes, free ports, clear junk, trim memory
.\tools\workflow\Close-OutSession.ps1 -IncludeRecycleBin -IncludePackageCache -ProjectPath "C:\my-project"  # deep
```

### Diagnostics
```powershell
.\tools\diagnostics\DevKit-Doctor.ps1
.\tools\diagnostics\System-DevInfo.ps1 -Export
.\tools\diagnostics\Test-DevKitUpdate.ps1 [-Force]
```

### WiFi Tools
```powershell
.\tools\wifi\WiFi-Optimize.ps1
.\tools\wifi\WiFi-FastMode.ps1
.\tools\wifi\WiFi-Scan.ps1
```

### Maintenance
```powershell
.\tools\maintenance\Clear-DiskJunk.ps1                  # report, then offers to clean right away (or -Apply up front)
.\tools\maintenance\Manage-StartupPrograms.ps1          # list startup entries
.\tools\maintenance\Repair-SystemFiles.ps1 -DryRun      # preview the SFC/DISM plan
.\tools\maintenance\Reset-WindowsUpdate.ps1 -DryRun     # preview the WU reset plan
.\tools\maintenance\Get-ScheduledTasksReport.ps1 -NonMicrosoftOnly
.\tools\maintenance\Get-RecentEventErrors.ps1 -Hours 24
.\tools\maintenance\Set-PowerPlan.ps1 -List
.\tools\maintenance\Get-DiskHealthReport.ps1
.\tools\maintenance\Get-BatteryReport.ps1
```

### Agents & MCP
```powershell
.\tools\agents\Get-InstalledAiClis.ps1
.\tools\agents\Update-AiClis.ps1 -DryRun
.\tools\agents\Get-McpServers.ps1
.\tools\agents\Add-McpServer.ps1 -Name myserver -Command npx -CommandArgs '-y','my-mcp-server' -Scope user
.\tools\agents\Add-McpServerFromCatalog.ps1                    # pick a well-known server (Supabase, GitHub, Notion...) from a built-in catalog
.\tools\agents\Scan-McpServers.ps1                              # check configured servers against the catalog and offer to add what's missing
```

---

## ⚡ Quick Reference

| Problem | Solution |
|---|---|
| Port 3000 is stuck | `tools\ports\Kill-Port.ps1 -Port 3000` |
| Next.js cache issues | `tools\nextjs\Next-FullClean.bat` |
| Vite dev server issues | `tools\vite\Vite-DevFresh.bat` |
| `node_modules` corrupted | `tools\node\Nuke-And-Reinstall.bat` |
| Git repo is bloated | `tools\git\Git-Cleanup.bat` |
| Docker out of control | `tools\docker\Docker-Nuke.bat` |
| PATH has duplicates | `tools\system\Edit-Path.bat -Clean` |
| Check all repos | `tools\git\Git-StatusAll.bat` |
| Slow cafe WiFi | `tools\wifi\WiFi-Optimize.bat` |
| Environment health check | `tools\diagnostics\DevKit-Doctor.bat` |
| Retyping the same project path every time | Pick it once in the Project Picker (widget or Control Center) — it becomes your Active Project and stays picked everywhere |
| Can't remember which tool you need | Control Center → search box, or `devkit` → `/` |
| Disk filling up | `tools\maintenance\Clear-DiskJunk.bat` |
| Windows Update stuck | `tools\maintenance\Reset-WindowsUpdate.bat -DryRun` first, then for real |
| "Files or folders are corrupted" | `tools\maintenance\Repair-SystemFiles.bat` |
| Want to know what's slowing down boot | `tools\maintenance\Manage-StartupPrograms.bat` |
| Check drive/battery health | `tools\maintenance\Get-DiskHealthReport.bat` / `tools\maintenance\Get-BatteryReport.bat` |
| Which AI CLIs do I have installed | `tools\agents\Get-InstalledAiClis.bat` |
| Add/remove a Claude Code MCP server | `tools\agents\Add-McpServer.bat` / `tools\agents\Remove-McpServer.bat` |
| Don't know the exact command for a well-known MCP server | `tools\agents\Add-McpServerFromCatalog.bat` → pick it from the catalog |
| Not sure which MCP servers a project (or this machine) is missing | `tools\agents\Scan-McpServers.bat` |
| Port refuses to bind but nothing is listening (EACCES/10013) | `tools\ports\Show-ExcludedPortRanges.bat` |
| Is my dev server actually responding? | `tools\ports\Test-DevEndpoint.bat` |
| "What did I do yesterday?" (standup) | `tools\git\Get-GitStandup.bat` |
| Just want to run a package.json script | `tools\node\Start-PackageScript.bat` |
| Reclaim gigabytes of old node_modules | `tools\node\Find-StaleNodeModules.bat` |
| Map `myapp.test` to localhost | `tools\system\Edit-HostsFile.bat` |
| App broke after a pull (missing .env keys) | `tools\workflow\Compare-EnvFiles.bat` |
| Decode a JWT / Base64 / timestamp | `tools\workflow\Convert-DevText.bat` |

---

## 🏗️ Project Structure

```
DevKit/
├── app/                      # Tauri v2 desktop app (React 19 + TypeScript, Rust backend)
│   ├── src/                  # Frontend: two windows (widget, control-center) + shared UI/hooks/stores
│   ├── src-tauri/            # Rust backend: rpc_call command, tray, ConPTY terminal, window mgmt
│   ├── package.json          # pnpm scripts (dev, build, tauri)
│   └── tauri.conf.json       # Windows, NSIS installer, updater config
├── cli/                      # `devkit` - ratatui interactive terminal menu (builds from source)
├── core/                     # PowerShell RPC sidecar + shared pure logic
│   ├── Invoke-DevKitRpc.ps1    # NDJSON-RPC sidecar entry point (runspace pools + writer runspace)
│   ├── RpcMethods.ps1          # ~40-method dispatch table
│   ├── DevKit-WidgetCore.ps1 / DevKit-GuiCore.ps1 # pure logic (moved here from the old gui/)
│   └── DevKit.Core.psm1        # module wrapper the sidecar and the CLI both import
├── crates/devkit-host/       # Rust client that spawns/respawns the PowerShell sidecar
├── tools/                    # Everything the widget, Control Center, and CLI launch
│   ├── lib/                  # Shared PowerShell helpers (project picker, settings, etc.)
│   ├── ports/                # Port management            (+ _module.psd1 manifest)
│   ├── node/                 # Node.js utilities          (+ _module.psd1)
│   ├── nextjs/               # Next.js tools              (+ _module.psd1)
│   ├── vite/                 # Vite tools                 (+ _module.psd1)
│   ├── git/                  # Git tools                  (+ _module.psd1)
│   ├── docker/               # Docker tools               (+ _module.psd1)
│   ├── system/               # System environment         (+ _module.psd1)
│   ├── workflow/             # Developer workflow         (+ _module.psd1)
│   ├── diagnostics/          # Health checks              (+ _module.psd1)
│   ├── wifi/                 # WiFi optimization          (+ _module.psd1)
│   ├── maintenance/          # Windows maintenance/tuning (+ _module.psd1)
│   └── agents/               # AI CLI & MCP management    (+ _module.psd1)
├── tests/Unit/               # Pester tests (run via `Invoke-Pester -Path tests/Unit`)
├── dev/                      # Maintainer-only tooling (RELEASING.md release checklist)
├── .github/workflows/        # CI (ci.yml) and the signed release pipeline (release.yml)
├── Cargo.toml / Cargo.lock   # Rust workspace (app/src-tauri, cli, crates/devkit-host)
├── VERSION                   # Single source of truth for the version number
├── CHANGELOG.md              # Release history
├── README.md                 # This file
├── CONTRIBUTING.md           # Contribution guidelines
├── CODE_OF_CONDUCT.md        # Community standards
└── LICENSE                   # MIT License
```

Linked projects and settings are stored outside the repo, at
`%LOCALAPPDATA%\NorthstarDevKit\` (`projects.json`, `settings.json`) —
nothing project-specific is written into the DevKit install folder.

---

## 🛠️ Requirements

**To run the installed app:**

- **Windows 10/11**
- **PowerShell 5.1+** or **PowerShell 7+** (PowerShell 7 recommended) — the sidecar and every tool run on it, nothing else to install
- **Administrator privileges** recommended for certain tools (WiFi optimization, editing system PATH, restoring Machine environment variables) — DevKit prompts or self-elevates where needed
- Optional: **Node.js**, **Git**, **Docker Desktop**, **GitHub CLI (`gh`)** — for the respective tools and the widget's GitHub panel

**To build from source** (the app, or the `devkit` CLI):

- **Rust** (stable toolchain)
- **Node.js** + **pnpm**

---

## 🤝 Contributing

We welcome contributions! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

---

## 📝 License

Distributed under the MIT License. See [LICENSE](LICENSE) for details.

---

<div align="center">

**Made with ❤️ by [Northstar Software Development](https://www.northstarcoding.com)**

*Empowering developers, one tool at a time.*

[🌐 Website](https://www.northstarcoding.com) • [💬 Issues](https://github.com/st3adyp1ck/northstar-devkit/issues) • [⬇️ Download](https://github.com/st3adyp1ck/northstar-devkit/releases)

</div>
