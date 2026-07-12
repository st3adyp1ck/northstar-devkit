<div align="center">

<img src="https://img.shields.io/badge/Northstar-DevKit-3.5.0-blue?style=for-the-badge&logo=powershell&logoColor=white" alt="Northstar DevKit">

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
3. Double-click `DevKit.bat` to launch

### Option 2: Clone with Git
```bash
git clone https://github.com/st3adyp1ck/northstar-devkit.git
cd northstar-devkit
.\DevKit.bat
```

### Option 3: Add to PATH
Run `Setup-Path.bat` once, then launch DevKit from any terminal:
```batch
Setup-Path.bat
:: Restart your terminal
DevKit.bat
```

> **No installation required.** DevKit runs entirely with built-in Windows PowerShell — zero external dependencies.

---

## 🚀 Quick Start

```batch
:: 1. Download & extract
:: 2. Double-click DevKit.bat
:: 3. Pick a tool from the menu and go!
```

The interactive menu will guide you through every tool. For project-specific actions (Git, Next.js, Vite, etc.), DevKit prompts you with a picker: pick a previously-linked project, browse for a folder, use the current directory, or type a path — no more retyping the same path for every action. Whatever you pick becomes your **Active Project** for the rest of the session. See [New in 3.0](#-new-in-30) below.

---

## 🎉 New in 3.5

- **Animated terminal experience.** A gradient startup banner and an animated spinner for longer-running steps, built on the existing brand blue — gracefully degrades to today's plain look on a console (or a `NO_COLOR`/redirected-output setup) that doesn't support it, and can be turned off entirely via the new `enableAnimations` setting.
- **In-menu help, everywhere.** Every tool category now has a `[?]` entry that lists what each numbered option does and when to use it, and the Main Menu has a new `[?] Getting Started` screen that walks first-time users through Active Project linking, the `p` suffix, and `/` search.
- **CLI tracking expanded from 6 to 11 tools.** Supabase CLI, Vercel CLI, Railway CLI, Kimi Code CLI, and Augment Code CLI (`auggie`) join claude/gh/codex/gemini/cursor-agent/aider — each is now updated through whichever channel actually fits it (npm, the tool's own built-in upgrade command, or Scoop) instead of assuming everything is npm.
- **MCP server catalog + scan.** A curated catalog of well-known MCP servers (Supabase, GitHub, Notion, Linear, Stripe, and more) turns adding one into a guided picker instead of hand-typing a `claude mcp add` command, and the new "Scan MCP Setup" option in the Agents & MCP menu checks your active project (and this machine) against the catalog and offers to add anything missing.

## 🎉 New in 3.1

- **Arrow-key navigation.** Every menu now supports Up/Down + Enter to move and select, Escape to go back — typing a number still works exactly as before, and it falls back automatically on a console that can't do raw key reads.
- **`[12] Maintenance`** — 14 real Windows maintenance/tuning tools: disk & storage cleanup, startup & services tuning, SFC/DISM repair + Windows Update reset, scheduled tasks & event log triage, power/performance tuning, and hardware health. Every mutating tool defaults to a safe report and requires an explicit flag + confirmation to change anything.
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

### Interactive Menu
Launch `DevKit.bat` and navigate with your keyboard:

```
=============================================
       Northstar DevKit v3.5.0
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
.\ports\Kill-Port.ps1 -Port 3000

# Full Next.js reset
.\nextjs\Next-FullClean.ps1 -Path "C:\my-project"

# Clean a Git repo
.\git\Git-Cleanup.ps1 -Path "C:\my-project"

# Check environment health
.\diagnostics\DevKit-Doctor.ps1
```

---

## 📚 Documentation

### Port Tools
```powershell
.\ports\Scan-Ports.ps1
.\ports\Kill-Port.ps1 -Port 3000
.\ports\Kill-AllNode.ps1
```

### Node.js Tools
```powershell
.\node\Clear-NpmCache.ps1
.\node\Remove-NodeModules.ps1 -Path "C:\my-project"
.\node\Nuke-And-Reinstall.ps1 -Path "C:\my-project"
```

### Next.js Tools
```powershell
.\nextjs\Clear-NextCache.ps1
.\nextjs\Next-DevFresh.ps1 -Path "C:\my-project"
.\nextjs\Next-FullClean.ps1 -Path "C:\my-project"
```

### Vite Tools
```powershell
.\vite\Vite-DevFresh.ps1 -Path "C:\my-project"
.\vite\Vite-PreviewBuild.ps1 -Path "C:\my-project"
```

### Git Tools
```powershell
.\git\Git-Cleanup.ps1 -Path "C:\my-project"
.\git\Git-StatusAll.ps1 -Path "C:\Projects"
.\git\Git-SyncFork.ps1 -Path "C:\my-project"
```

### Docker Tools
```powershell
.\docker\Docker-Nuke.ps1 -DryRun
.\docker\Docker-Cleanup.ps1
.\docker\Docker-QuickLogs.ps1
```

### System Tools
```powershell
.\system\Edit-Path.ps1 -Show
.\system\Edit-Path.ps1 -Clean
.\system\Env-Backup.ps1 -OutputPath "C:\Backups"
.\system\Env-Restore.ps1 -BackupFile "backup.json"
.\system\Shell-Reload.ps1
```

### Workflow Tools
```powershell
.\workflow\Code-Here.ps1 -Path "C:\my-project"
.\workflow\Open-Repo.ps1 -Path "C:\my-project"
.\workflow\Copy-EnvTemplate.ps1 -Path "C:\my-project" -Interactive
```

### Diagnostics
```powershell
.\diagnostics\DevKit-Doctor.ps1
.\diagnostics\System-DevInfo.ps1 -Export
```

### WiFi Tools
```powershell
.\wifi\WiFi-Optimize.ps1
.\wifi\WiFi-FastMode.ps1
.\wifi\WiFi-Scan.ps1
```

### Maintenance
```powershell
.\maintenance\Clear-DiskJunk.ps1                  # report only; add -Apply to actually clean
.\maintenance\Manage-StartupPrograms.ps1          # list startup entries
.\maintenance\Repair-SystemFiles.ps1 -DryRun      # preview the SFC/DISM plan
.\maintenance\Reset-WindowsUpdate.ps1 -DryRun     # preview the WU reset plan
.\maintenance\Get-ScheduledTasksReport.ps1 -NonMicrosoftOnly
.\maintenance\Get-RecentEventErrors.ps1 -Hours 24
.\maintenance\Set-PowerPlan.ps1 -List
.\maintenance\Get-DiskHealthReport.ps1
.\maintenance\Get-BatteryReport.ps1
```

### Agents & MCP
```powershell
.\agents\Get-InstalledAiClis.ps1
.\agents\Update-AiClis.ps1 -DryRun
.\agents\Get-McpServers.ps1
.\agents\Add-McpServer.ps1 -Name myserver -Command npx -CommandArgs '-y','my-mcp-server' -Scope user
.\agents\Add-McpServerFromCatalog.ps1                    # pick a well-known server (Supabase, GitHub, Notion...) from a built-in catalog
.\agents\Scan-McpServers.ps1                              # check configured servers against the catalog and offer to add what's missing
```

---

## ⚡ Quick Reference

| Problem | Solution |
|---|---|
| Port 3000 is stuck | `ports\Kill-Port.ps1 -Port 3000` |
| Next.js cache issues | `nextjs\Next-FullClean.bat` |
| Vite dev server issues | `vite\Vite-DevFresh.bat` |
| `node_modules` corrupted | `node\Nuke-And-Reinstall.bat` |
| Git repo is bloated | `git\Git-Cleanup.bat` |
| Docker out of control | `docker\Docker-Nuke.bat` |
| PATH has duplicates | `system\Edit-Path.bat -Clean` |
| Check all repos | `git\Git-StatusAll.bat` |
| Slow cafe WiFi | `wifi\WiFi-Optimize.bat` |
| Environment health check | `diagnostics\DevKit-Doctor.bat` |
| Retyping the same project path every time | `DevKit.bat` → any tool → link it once, it's remembered |
| Can't remember which menu a tool is in | `DevKit.bat` → `/` → type a keyword |
| Disk filling up | `maintenance\Clear-DiskJunk.bat` |
| Windows Update stuck | `maintenance\Reset-WindowsUpdate.bat -DryRun` first, then for real |
| "Files or folders are corrupted" | `maintenance\Repair-SystemFiles.bat` |
| Want to know what's slowing down boot | `maintenance\Manage-StartupPrograms.bat` |
| Check drive/battery health | `maintenance\Get-DiskHealthReport.bat` / `Get-BatteryReport.bat` |
| Which AI CLIs do I have installed | `agents\Get-InstalledAiClis.bat` |
| Add/remove a Claude Code MCP server | `agents\Add-McpServer.bat` / `Remove-McpServer.bat` |
| Don't know the exact command for a well-known MCP server | `agents\Add-McpServerFromCatalog.bat` → pick it from the catalog |
| Not sure which MCP servers a project (or this machine) is missing | `agents\Scan-McpServers.bat` |

---

## 🏗️ Project Structure

```
DevKit/
├── DevKit.bat              # Main launcher
├── DevKit.ps1              # Interactive menu (manifest-driven dispatcher)
├── Setup-Path.bat          # Add to PATH utility
├── VERSION                 # Single source of truth for the version number
├── CHANGELOG.md            # Release history
├── RELEASING.md            # Maintainer release checklist
├── README.md               # This file
├── CONTRIBUTING.md         # Contribution guidelines
├── CODE_OF_CONDUCT.md      # Community standards
├── LICENSE                 # MIT License
│
├── lib/                    # Shared PowerShell helpers (project picker, menu
│                           # dispatcher, settings, confirmation gate, etc.)
├── ports/                  # Port management       (+ _module.psd1 menu manifest)
├── node/                   # Node.js utilities      (+ _module.psd1)
├── nextjs/                 # Next.js tools          (+ _module.psd1)
├── vite/                   # Vite tools             (+ _module.psd1)
├── git/                    # Git tools              (+ _module.psd1)
├── docker/                 # Docker tools           (+ _module.psd1)
├── system/                 # System environment     (+ _module.psd1)
├── workflow/                # Developer workflow     (+ _module.psd1)
├── diagnostics/            # Health checks           (+ _module.psd1)
├── wifi/                   # WiFi optimization       (+ _module.psd1)
├── maintenance/            # Windows maintenance/tuning (+ _module.psd1)
├── agents/                 # AI CLI & MCP management   (+ _module.psd1)
└── tests/Unit/             # Pester tests (run via `Invoke-Pester -Path tests/Unit`)
```

Linked projects and settings are stored outside the repo, at
`%LOCALAPPDATA%\NorthstarDevKit\` (`projects.json`, `settings.json`) —
nothing project-specific is written into the DevKit install folder.

---

## 🛠️ Requirements

- **Windows 10/11**
- **PowerShell 5.1+** or **PowerShell 7+** (PowerShell 7 recommended)
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
