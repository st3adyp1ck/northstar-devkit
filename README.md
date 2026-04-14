<div align="center">

<img src="https://img.shields.io/badge/Northstar-DevKit-2.0-blue?style=for-the-badge&logo=powershell&logoColor=white" alt="Northstar DevKit">

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

The interactive menu will guide you through every tool. For project-specific actions (Git, Next.js, Vite, etc.), DevKit automatically prompts you for the target directory — so you can run it from anywhere.

---

## ✨ Features

<div align="center">

| 🔌 **Ports** | 📦 **Node.js** | ▲ **Next.js** | ⚡ **Vite** |
|---|---|---|---|
| Scan & kill dev ports | Clear caches, nuke `node_modules` | Clean `.next` & Turbopack caches | Fresh dev server & preview builds |

| 🐙 **Git** | 🐳 **Docker** | 🛠️ **System** | 🔧 **Workflow** |
|---|---|---|---|
| Cleanup, status all repos, sync forks | Nuke containers & images, tail logs | Edit PATH, backup/restore env | Open IDE/repo, copy `.env` templates |

| 🔍 **Diagnostics** | 📡 **WiFi** |
|---|---|
| Health check & system info | Optimize DNS, scan networks, speed test |

</div>

---

## 🖥️ Usage

### Interactive Menu
Launch `DevKit.bat` and navigate with your keyboard:

```
=============================================
        Northstar DevKit v2.0
    Developer Toolkit by Northstar.com
=============================================
  Current: Main Menu

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

  Network:
    [10] WiFi Tools    - Optimize and Scan

    [0] Exit
```

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

---

## 🏗️ Project Structure

```
DevKit/
├── DevKit.bat              # Main launcher
├── DevKit.ps1              # Interactive menu
├── Setup-Path.bat          # Add to PATH utility
├── README.md               # This file
├── CONTRIBUTING.md         # Contribution guidelines
├── CODE_OF_CONDUCT.md      # Community standards
├── LICENSE                 # MIT License
│
├── ports/                  # Port management
├── node/                   # Node.js utilities
├── nextjs/                 # Next.js tools
├── vite/                   # Vite tools
├── git/                    # Git tools
├── docker/                 # Docker tools
├── system/                 # System environment
├── workflow/               # Developer workflow
├── diagnostics/            # Health checks
└── wifi/                   # WiFi optimization
```

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

**Made with ❤️ by [Northstar.com](https://www.northstarcoding.com)**

*Empowering developers, one tool at a time.*

[🌐 Website](https://www.northstarcoding.com) • [💬 Issues](https://github.com/st3adyp1ck/northstar-devkit/issues) • [⬇️ Download](https://github.com/st3adyp1ck/northstar-devkit/archive/refs/heads/main.zip)

</div>
