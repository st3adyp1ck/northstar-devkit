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

### Option 1: Download ZIP (Easiest)
<a href="https://github.com/st3adyp1ck/northstar-devkit/archive/refs/heads/main.zip">
  <img src="https://img.shields.io/badge/Download-ZIP-blue?style=for-the-badge&logo=github" alt="Download ZIP">
</a>

1. Click the button above to download the latest version
2. Extract the ZIP to a folder (e.g., `C:\Tools\DevKit`)
3. Run `Install.bat` (or `Install.ps1`) and follow the steps — it registers DevKit with Windows, creates shortcuts, and offers Start with Windows
4. Afterwards, launch from the Start Menu/Desktop icon (the widget) or `Widget.bat` from the folder

### Option 2: Clone with Git
```bash
git clone https://github.com/st3adyp1ck/northstar-devkit.git
cd northstar-devkit
.\Install.bat
```
Then launch from the Start Menu/Desktop icon (the widget) or `Widget.bat` from the folder.

### Option 3: Portable (no install)
Prefer not to install? Everything still runs straight from the folder — double-click `Widget.bat` (the companion widget), `DevKit-GUI.bat` (the Control Center), or `DevKit.bat` (the classic terminal menu). Nothing is registered with Windows in this mode.

> **No external dependencies.** DevKit runs entirely with built-in Windows PowerShell — zero external dependencies.
>
> **Uninstall:** Settings > Apps > Northstar DevKit, or run `Uninstall.ps1` — it removes files, shortcuts, PATH, and the startup entry, and (optionally) your saved settings.

---

## 🚀 Quick Start

```batch
:: 1. Download & extract
:: 2. Run Install.bat and follow the steps (fully per-user, no admin needed)
:: 3. Launch "Northstar DevKit" from the Start Menu/Desktop icon - the widget
:: 4. Click DEVKIT in the widget's title bar for the full Control Center
::    ...or run DevKit.bat for the classic terminal menu
```

The **companion widget is the main face of DevKit** — a small always-on window with your system's vitals, running dev servers, git status, and one-click tools. Its title-bar **DEVKIT** button opens the **DevKit Control Center**, the full desktop app: every tool as a card in one branded window — pick a category on the left (or search), press **Run**, and the tool opens in a terminal window with its full interactive UI. For project-specific actions (Git, Next.js, Vite, etc.), DevKit prompts you with a picker: pick a previously-linked project, browse for a folder, use the current directory, or type a path — no more retyping the same path for every action. Whatever you pick becomes your **Active Project** and is shared between the widget, the app, and the terminal UI. See [New in 3.0](#-new-in-30) below.

---

## 🎉 New in 4.0

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

### Desktop App (GUI)
Launch `DevKit-GUI.bat`:

- **Navigate** by category (left rail) or **search** (top of the rail, `Ctrl+F`) — every tool appears as a card with a one-line summary and the full details on hover.
- **Run** opens the tool in its own terminal window (Windows Terminal when available, classic console otherwise) with its complete interactive UI — long-running tools like dev servers simply live in that window until you close it.
- Cards marked **PROJECT** run against your **Active Project** automatically; manage linked projects from the **Projects** page in the rail. Cards marked **CAUTION** change system state — their terminal window always asks for confirmation first.
- Tools that need input (a port number, a file, a yes/no) ask with a small validated dialog before launching.
- "Restart as Administrator" (Getting Started page) relaunches the app elevated for the maintenance tools that need it.

### Companion Widget
The widget is DevKit's main face — launch it from the Start Menu/Desktop icon, or `Widget.bat` from the folder (it starts windowlessly, straight to the desktop and tray). It also opens from the gauge icon in the Control Center's title bar:

- **Metrics**: CPU / memory / GPU dials with temperatures where the machine exposes them (unavailable sensors show "n/a"), a **System Junk** dial with a one-click clean, and a **Disk Free** dial — plus a reboot-pending / long-uptime hint when Windows needs a restart.
- **Click a dial to manage it**: each gauge slides out a management panel from the widget's edge — CPU shows a live list of what's eating your processor, MEM shows what's holding memory (with a one-click **Free Memory** button that safely trims idle working sets — nothing is closed), and GPU shows your adapter (utilization/temp/VRAM on NVIDIA) plus which processes are using it. Every process row is badged **SAFE TO CLOSE** / **CAUTION** / **LEAVE ALONE** (system processes have no kill button at all), so cleanup candidates are unmistakable.
- **Cleanup without a terminal**: the junk dial's **Clean Now** runs entirely inside the widget — one Yes/No, then it clears temp files, the Recycle Bin, and (when the widget runs as administrator) Windows temp + the Windows Update cache, reporting exactly what each category freed and politely noting anything that needed admin. **Details...** shows the per-category breakdown. No command prompt, no typed confirmations, ever.
- **Node watch**: every running `node` process with its memory, age, and listening ports — click a port to open it in your browser, or kill just that one process (after a confirm). Warns you when a dev port is stuck inside a Windows-reserved range (Hyper-V/winnat).
- **Side tabs**: FILES, GIT, NOTES, and ON DECK slide out from the widget's edge (one at a time), each anchored across from its related section — files and git by the gauges, notes and on-deck by the drives — with TERMINAL lower by Quick Actions and a gradient divider line marking the strip. The **Files explorer** shows Material-style file-type icons; the **git panel** draws the commit graph with branch/tag/HEAD glyphs.
- **Terminal tab**: slides out a REAL terminal — Windows Terminal (your DevKit profile when registered) hosted inside the panel, already in your project folder. Interactive CLIs (kimi, claude) just work, because it genuinely is a terminal. It stays open alongside any other panel — watch the git graph while you run commands.
- **Git panel**: a drawn commit graph with colored lanes and merge curves, branch with ahead/behind, fetch/pull/push, and quick links to GitHub/Actions — for the project selected below. **Click any commit** to expand its details inline (full message, author, per-file change stats); click again to collapse.
- **Project selector**: the same Active Project as the GUI and terminal UI, with an ambient badge showing its branch + uncommitted/ahead/behind/stash counts, and a warning when its `.env` drifts from the template ("Fix..." copies the template in a terminal).
- **Quick actions**: Clear NPM Cache, Kill All Node, Kill Port..., Doctor, plus Editor / Explorer / Terminal / Run Script... launchers for the active project — each launches the real DevKit tool in a terminal window — and **Open DevKit Control Center** for the full toolkit (also reachable via the title-bar **DEVKIT** button).
- **Agents**: the expandable **Claude Code** / **Kimi Code** boxes show that project's MCP servers alongside your user-scope ones, with Connected / Disconnected / Requires Auth badges and working **Manage...** dialogs (re-check, sign in, add/remove servers).
- **Tray**: the widget keeps running in the system tray when you hide the window — and while hidden it genuinely sleeps: every refresh timer stops, so a tray-hidden widget uses essentially no CPU or GPU until you show it again (which triggers an immediate refresh). Left-click the icon to show/hide, right-click for the menu (Show, Open DevKit Control Center, Start with Windows, Exit). On Windows 11 look in the ^ overflow near the clock.

### Interactive Menu
Launch `DevKit.bat` and navigate with your keyboard:

```
=============================================
       Northstar DevKit v4.0.0
    Developer Toolkit by northstarcoding.com
=============================================
  Menu: Main Menu
  Active Project: acme-storefront  (C:\dev\acme-storefront)

  DevKit bundles your everyday Node/Next.js/Vite/Git/Docker tools into
  one menu. New here? Pick [?] Getting Started below.

  Development Tools:
    [1] Port Tools     - Scan and Kill
    [2] Node.js Tools  - Cache & Modules
    [3] Next.js Tools  - Build Cache
    [4] Vite Tools     - Dev Server

  Version Control & Containers:
    [5] Git Tools      - Repo Management
    [6] Docker Tools   - Container Cleanup

  System & Workflow:
    [7] System Tools   - PATH & Environment
    [8] Workflow       - IDE & Utils
    [9] Diagnostics    - Health Check

  Maintenance & Agents:
    [12] Maintenance   - Cleanup, Repair, Tuning
    [13] Agents & MCP  - AI CLI & MCP Servers

  Projects & Network:
    [10] Projects      - Link, Switch, Manage
    [11] WiFi Tools    - Optimize and Scan

    [/] Search tools
    [?] Getting Started
    [0] Exit
```

Use the arrow keys to move and Enter to select, or just type a number like before — both work everywhere.

### Run Individual Scripts
You can also run any tool directly from PowerShell or Command Prompt:

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
```

### Workflow Tools
```powershell
.\tools\workflow\Code-Here.ps1 -Path "C:\my-project"
.\tools\workflow\Open-Repo.ps1 -Path "C:\my-project"
.\tools\workflow\Copy-EnvTemplate.ps1 -Path "C:\my-project" -Interactive
.\tools\workflow\Compare-EnvFiles.ps1 -Path "C:\my-project"      # .env vs template drift (keys only)
.\tools\workflow\Convert-DevText.ps1                             # Base64/URL/timestamps/GUID/SHA-256/JWT
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
| Retyping the same project path every time | `DevKit.bat` → any tool → link it once, it's remembered |
| Can't remember which menu a tool is in | `DevKit.bat` → `/` → type a keyword |
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
├── Widget.bat              # Companion widget launcher (the main face of the app)
├── DevKit.bat              # Classic terminal menu launcher
├── DevKit.ps1              # Interactive menu (manifest-driven dispatcher)
├── DevKit-GUI.bat          # DevKit Control Center (desktop GUI) launcher
├── Install.ps1 / Install.bat  # Per-user installer wizard (no admin needed)
├── Uninstall.ps1           # Full uninstaller (removes every trace)
├── VERSION                 # Single source of truth for the version number
├── CHANGELOG.md            # Release history
├── README.md               # This file
├── CONTRIBUTING.md         # Contribution guidelines
├── CODE_OF_CONDUCT.md      # Community standards
├── LICENSE                 # MIT License
│
├── gui/                    # Control Center + companion widget: WPF windows, brand
│                           # theme, pure-logic cores, logo assets (Build-Assets.ps1)
├── tools/                  # Everything the menus launch
│   ├── lib/                # Shared PowerShell helpers (project picker, menu
│   │                       # dispatcher, settings, confirmation gate, etc.)
│   ├── ports/              # Port management          (+ _module.psd1 menu manifest)
│   ├── node/               # Node.js utilities        (+ _module.psd1)
│   ├── nextjs/             # Next.js tools            (+ _module.psd1)
│   ├── vite/               # Vite tools               (+ _module.psd1)
│   ├── git/                # Git tools                (+ _module.psd1)
│   ├── docker/             # Docker tools             (+ _module.psd1)
│   ├── system/             # System environment       (+ _module.psd1)
│   ├── workflow/           # Developer workflow       (+ _module.psd1)
│   ├── diagnostics/        # Health checks            (+ _module.psd1)
│   ├── wifi/               # WiFi optimization        (+ _module.psd1)
│   ├── maintenance/        # Windows maintenance/tuning (+ _module.psd1)
│   └── agents/             # AI CLI & MCP management  (+ _module.psd1)
├── tests/Unit/             # Pester tests (run via `Invoke-Pester -Path tests/Unit`)
└── dev/                    # Maintainer-only tooling (Build-UsbPortable.ps1/.bat,
                            # RELEASING.md release checklist)
```

Linked projects and settings are stored outside the repo, at
`%LOCALAPPDATA%\NorthstarDevKit\` (`projects.json`, `settings.json`) —
nothing project-specific is written into the DevKit install folder.

---

## 🛠️ Requirements

- **Windows 10/11**
- **PowerShell 5.1+** or **PowerShell 7+** (PowerShell 7 recommended)
- Optional: **Windows Terminal** (tools open in it instead of the classic console when installed)
- **Administrator privileges** recommended for:
  - WiFi optimization
  - Editing system PATH
  - Restoring Machine environment variables
- Optional: **Node.js**, **Git**, **Docker Desktop** (for respective tools)

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

[🌐 Website](https://www.northstarcoding.com) • [💬 Issues](https://github.com/st3adyp1ck/northstar-devkit/issues) • [⬇️ Download](https://github.com/st3adyp1ck/northstar-devkit/archive/refs/heads/main.zip)

</div>
