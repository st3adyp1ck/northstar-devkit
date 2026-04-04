<div align="center">

<img src="https://img.shields.io/badge/Northstar-DevKit-2.0-blue?style=for-the-badge&logo=powershell&logoColor=white" alt="Northstar DevKit">

**A powerful Windows toolkit for modern web developers**

[![Made by Northstar](https://img.shields.io/badge/Made%20by-Northstar%20Software%20Development-00b4d8?style=flat-square)](https://www.northstarcoding.com)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?style=flat-square&logo=powershell)](https://docs.microsoft.com/powershell/)
[![License](https://img.shields.io/badge/License-MIT-green?style=flat-square)](LICENSE)

[Website](https://www.northstarcoding.com) • [Features](#-features) • [Installation](#-installation) • [Usage](#-usage) • [Documentation](#-documentation)

</div>

---

## 🚀 Overview

**Northstar DevKit** is a comprehensive PowerShell-based toolkit designed for developers working with Node.js, Next.js, Vite, Git, Docker, and more. Whether you're debugging port conflicts, clearing stubborn caches, syncing Git repositories, or optimizing public WiFi connections at your favorite coffee shop, DevKit has you covered.

Built by developers, for developers.

## ✨ Features

### 🔌 **Port Management**
- **Scan common dev ports** (3000, 3001, 5173, 8000, 8080, 9000, etc.)
- **Find and kill processes** by port number or PID
- **Kill all Node processes** with one command
- Interactive kill mode for safe process management

### 📦 **Node.js Tools**
- **Clear NPM cache** with verification
- **Delete node_modules** with size reporting
- **Nuclear option**: Clean cache, delete modules, remove lock file, reinstall
- Perfect for fixing "works on my machine" issues

### ▲ **Next.js Tools**
- **Clear .next build cache** for fresh builds
- **Clear Turbopack cache** for Turbopack users
- **Full clean**: Everything + npm install
- **Fresh dev start**: Clear cache and launch dev server

### ⚡ **Vite Tools**
- **Clear .vite cache** and build artifacts
- **Fresh dev server**: Clean start with cache clearing
- **Build and preview**: Production build with local preview

### 🐙 **Git Tools**
- **Git Cleanup**: Prune merged branches, run garbage collection, show size savings
- **Git Status All**: Check status across multiple repositories in a directory
- **Sync Fork**: Quickly sync your fork with upstream repository

### 🐳 **Docker Tools**
- **Docker Nuke**: The "node_modules" of Docker - stop all containers, remove all images/volumes/networks
- **Docker Cleanup**: Selective cleanup of dangling images, unused volumes, stopped containers
- **Quick Logs**: Tail logs from multiple containers with color-coded output

### 🛠️ **System Tools**
- **Edit PATH**: Interactive PATH variable editor (remove duplicates, reorder, validate)
- **Env Backup/Restore**: Save and restore environment variables
- **Shell Reload**: Refresh PowerShell environment without restarting

### 🔧 **Workflow Tools**
- **Code Here**: Open VS Code or Cursor with recent projects picker
- **Open Repo**: Open current Git repository in browser (GitHub, GitLab, Bitbucket, Azure DevOps)
- **Copy Env Template**: Copy `.env.example` to `.env` with interactive value filling

### 🔍 **Diagnostics**
- **DevKit Doctor**: Health check for development environment (versions, installations, common issues)
- **System Dev Info**: Quick summary of installed tools, ports, disk space, environment

### 📡 **WiFi Optimization**
- **Smart DNS switching**: Auto-tests Cloudflare (1.1.1.1) vs Google (8.8.8.8), picks the fastest
- **TCP/IP stack reset**: Fresh network state
- **Windows optimization**: Disables bandwidth-heavy background services
- **Speed test**: Verify your connection quality
- **WiFi scanner**: Find the best network with signal strength analysis

## 📥 Installation

### Option 1: Download & Run (Easiest)

1. Download the latest release
2. Extract to your desired location (e.g., `C:\Tools\DevKit`)
3. Double-click `DevKit.bat` to start

### Option 2: Add to PATH

Run `Setup-Path.bat` once, then use `devkit` from any terminal:

```batch
Setup-Path.bat
:: Restart your terminal
devkit
```

### Option 3: Clone the Repository

```bash
git clone https://github.com/yourusername/northstar-devkit.git
cd northstar-devkit
.\DevKit.bat
```

## 🖥️ Usage

### Interactive Menu

Launch the main menu and navigate with your keyboard:

```batch
.\DevKit.bat
```

```
=============================================
        Northstar DevKit v2.0
    Developer Toolkit by Northstar SD
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

### Direct Script Execution

Run individual scripts directly for quick tasks:

```powershell
# Port is stuck on 3000?
.\ports\Kill-Port.ps1 -Port 3000

# Next.js acting weird?
.\nextjs\Next-FullClean.ps1

# Just connected to cafe WiFi?
.\wifi\WiFi-Optimize.ps1

# Git repo getting bloated?
.\git\Git-Cleanup.ps1

# Docker containers out of control?
.\docker\Docker-Nuke.ps1 -DryRun

# Need to check all your repos?
.\git\Git-StatusAll.ps1 -Path "C:\Projects"

# PATH variable has duplicates?
.\system\Edit-Path.ps1 -Clean

# Environment acting weird?
.\diagnostics\DevKit-Doctor.ps1
```

### Batch Files (Double-Click)

All tools include `.bat` wrappers for easy execution:

| Tool | Batch File |
|------|-----------|
| Main Menu | `DevKit.bat` |
| Scan Ports | `ports\Scan-Ports.bat` |
| Clear Next.js Cache | `nextjs\Next-DevFresh.bat` |
| WiFi Optimizer | `wifi\WiFi-Optimize.bat` |
| Nuclear Reinstall | `node\Nuke-And-Reinstall.bat` |
| Git Cleanup | `git\Git-Cleanup.bat` |
| Docker Nuke | `docker\Docker-Nuke.bat` |
| DevKit Doctor | `diagnostics\DevKit-Doctor.bat` |

## 📚 Documentation

### Port Tools

```powershell
# Scan all common dev ports
.\ports\Scan-Ports.ps1

# Kill specific port
.\ports\Kill-Port.ps1 -Port 3000

# Kill specific PID
.\ports\Kill-Port.ps1 -PID 12345

# Kill all Node processes
.\ports\Kill-AllNode.ps1
```

### Node.js Tools

```powershell
# Clear NPM cache
.\node\Clear-NpmCache.ps1

# Delete node_modules only
.\node\Remove-NodeModules.ps1 -Path "C:\my-project"

# Nuclear option (everything)
.\node\Nuke-And-Reinstall.ps1 -Path "C:\my-project"
```

### Next.js Tools

```powershell
# Clear .next cache
.\nextjs\Clear-NextCache.ps1

# Clear Turbopack cache
.\nextjs\Clear-TurboCache.ps1

# Full clean and reinstall
.\nextjs\Next-FullClean.ps1

# Fresh dev server start
.\nextjs\Next-DevFresh.ps1
```

### Vite Tools

```powershell
# Fresh dev server start
.\vite\Vite-DevFresh.ps1

# With custom port
.\vite\Vite-DevFresh.ps1 -Port 3001

# Build and preview
.\vite\Vite-PreviewBuild.ps1
```

### Git Tools

```powershell
# Clean up repository (prune branches, gc)
.\git\Git-Cleanup.ps1

# Show what would be cleaned (dry run)
.\git\Git-Cleanup.ps1 -DryRun

# Check status of all repos in a directory
.\git\Git-StatusAll.ps1 -Path "C:\Projects"

# Sync fork with upstream
.\git\Git-SyncFork.ps1
.\git\Git-SyncFork.ps1 -Rebase
```

### Docker Tools

```powershell
# Nuclear option - remove everything
.\docker\Docker-Nuke.ps1

# Dry run to see what would be removed
.\docker\Docker-Nuke.ps1 -DryRun

# Keep volumes but nuke everything else
.\docker\Docker-Nuke.ps1 -KeepVolumes

# Selective cleanup
.\docker\Docker-Cleanup.ps1

# Remove all unused resources
.\docker\Docker-Cleanup.ps1 -AllUnused

# Tail logs from all containers
.\docker\Docker-QuickLogs.ps1
```

### System Tools

```powershell
# View PATH entries
.\system\Edit-Path.ps1 -Show

# Add to PATH
.\system\Edit-Path.ps1 -Add "C:\MyTools"

# Remove duplicate/invalid PATH entries
.\system\Edit-Path.ps1 -Clean

# Interactive PATH editor
.\system\Edit-Path.ps1

# Backup environment variables
.\system\Env-Backup.ps1 -OutputPath "C:\Backups"

# Restore from backup
.\system\Env-Restore.ps1 -BackupFile "backup.json"

# Reload shell environment
.\system\Shell-Reload.ps1
```

### Workflow Tools

```powershell
# Open VS Code in current directory
.\workflow\Code-Here.ps1

# Show recent projects picker
.\workflow\Code-Here.ps1 -Recent

# Open repository in browser
.\workflow\Open-Repo.ps1

# Open PRs page
.\workflow\Open-Repo.ps1 -PullRequest

# Copy .env.example to .env
.\workflow\Copy-EnvTemplate.ps1

# Interactive mode with prompts
.\workflow\Copy-EnvTemplate.ps1 -Interactive
```

### Diagnostics

```powershell
# Full health check
.\diagnostics\DevKit-Doctor.ps1

# Show only errors/warnings
.\diagnostics\DevKit-Doctor.ps1 -Quiet

# System info summary
.\diagnostics\System-DevInfo.ps1

# Export to JSON
.\diagnostics\System-DevInfo.ps1 -Export

# Copy to clipboard
.\diagnostics\System-DevInfo.ps1 -Clipboard
```

### WiFi Tools

```powershell
# Full WiFi optimization with speed test
.\wifi\WiFi-Optimize.ps1

# Fast mode (skip speed test)
.\wifi\WiFi-Optimize.ps1 -Fast

# Keep current DNS settings
.\wifi\WiFi-Optimize.ps1 -KeepDNS

# Scan nearby networks
.\wifi\WiFi-Scan.ps1
```

## 🏗️ Project Structure

```
DevKit/
├── DevKit.bat              # Main launcher (batch)
├── DevKit.ps1              # Main menu (PowerShell)
├── Setup-Path.bat          # Add to PATH utility
├── README.md               # This file
├── LICENSE                 # MIT License
│
├── ports/                  # Port management tools
│   ├── Scan-Ports.ps1
│   ├── Scan-Ports.bat
│   ├── Kill-Port.ps1
│   └── Kill-AllNode.ps1
│
├── node/                   # Node.js utilities
│   ├── Clear-NpmCache.ps1
│   ├── Remove-NodeModules.ps1
│   ├── Nuke-And-Reinstall.ps1
│   └── Nuke-And-Reinstall.bat
│
├── nextjs/                 # Next.js specific tools
│   ├── Clear-NextCache.ps1
│   ├── Clear-TurboCache.ps1
│   ├── Next-DevFresh.ps1
│   ├── Next-DevFresh.bat
│   ├── Next-FullClean.ps1
│   └── Next-FullClean.bat
│
├── vite/                   # Vite tools
│   ├── Vite-DevFresh.ps1
│   ├── Vite-DevFresh.bat
│   ├── Vite-PreviewBuild.ps1
│   └── Vite-PreviewBuild.bat
│
├── git/                    # Git tools
│   ├── Git-Cleanup.ps1
│   ├── Git-Cleanup.bat
│   ├── Git-StatusAll.ps1
│   ├── Git-StatusAll.bat
│   ├── Git-SyncFork.ps1
│   └── Git-SyncFork.bat
│
├── docker/                 # Docker tools
│   ├── Docker-Nuke.ps1
│   ├── Docker-Nuke.bat
│   ├── Docker-Cleanup.ps1
│   ├── Docker-Cleanup.bat
│   ├── Docker-QuickLogs.ps1
│   └── Docker-QuickLogs.bat
│
├── system/                 # System environment tools
│   ├── Edit-Path.ps1
│   ├── Edit-Path.bat
│   ├── Env-Backup.ps1
│   ├── Env-Restore.ps1
│   ├── Shell-Reload.ps1
│   └── *.bat
│
├── workflow/               # Developer workflow tools
│   ├── Code-Here.ps1
│   ├── Code-Here.bat
│   ├── Open-Repo.ps1
│   ├── Open-Repo.bat
│   ├── Copy-EnvTemplate.ps1
│   └── Copy-EnvTemplate.bat
│
├── diagnostics/            # Health check tools
│   ├── DevKit-Doctor.ps1
│   ├── DevKit-Doctor.bat
│   ├── System-DevInfo.ps1
│   └── System-DevInfo.bat
│
└── wifi/                   # WiFi optimization tools
    ├── WiFi-Optimize.ps1
    ├── WiFi-Optimize.bat
    ├── WiFi-FastMode.ps1
    ├── WiFi-FastMode.bat
    ├── WiFi-Scan.ps1
    └── WiFi-Scan.bat
```

## ⚡ Quick Reference

| Problem | Solution |
|---------|----------|
| Port 3000 is stuck | `ports\Kill-Port.ps1 -Port 3000` |
| Next.js cache issues | `nextjs\Next-FullClean.bat` |
| Vite dev server issues | `vite\Vite-DevFresh.bat` |
| node_modules corrupted | `node\Nuke-And-Reinstall.bat` |
| Git repo is bloated | `git\Git-Cleanup.bat` |
| Docker containers out of control | `docker\Docker-Nuke.bat` |
| PATH has duplicates | `system\Edit-Path.bat -Clean` |
| Need to check all repos | `git\Git-StatusAll.bat` |
| Slow cafe WiFi | `wifi\WiFi-Optimize.bat` |
| Check environment health | `diagnostics\DevKit-Doctor.bat` |

## 🛠️ Requirements

- **Windows 10/11** (PowerShell 5.1+ or PowerShell 7+)
- **Administrator privileges** recommended for:
  - WiFi optimization features
  - Editing system PATH
  - Restoring Machine environment variables
- **Node.js** (for Node.js/Next.js/Vite tools)
- **Git** (for Git tools)
- **Docker Desktop** (for Docker tools)
- **WiFi adapter** (for WiFi tools)

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

## 📝 License

Distributed under the MIT License. See `LICENSE` for more information.

## 🔗 Links

- **Website**: [https://www.northstarcoding.com](https://www.northstarcoding.com)
- **Report Bug**: [Issues](https://github.com/yourusername/northstar-devkit/issues)
- **Request Feature**: [Issues](https://github.com/yourusername/northstar-devkit/issues)

---

<div align="center">

**Made with ❤️ by [Northstar Software Development](https://www.northstarcoding.com)**

*Empowering developers, one tool at a time.*

</div>
