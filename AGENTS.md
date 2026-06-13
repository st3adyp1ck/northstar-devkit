# Northstar DevKit - Agent Documentation

## Project Overview

**Northstar DevKit** is a comprehensive PowerShell-based Windows toolkit for web developers. It provides utilities for port management, Node.js/Next.js/Vite cache clearing, Git repository management, Docker container cleanup, system environment management, and WiFi network optimization.

- **Created by:** Northstar Software Development
- **Website:** https://www.northstarcoding.com
- **License:** MIT
- **Language:** English (all comments and documentation)
- **Version:** 2.1.0

## Technology Stack

- **Primary Language:** PowerShell 5.1+ or PowerShell 7+ (pwsh)
- **Secondary:** Batch files (.bat) as wrappers for GUI/click execution
- **Platform:** Windows 10/11
- **No external dependencies:** Uses built-in Windows PowerShell cmdlets and system utilities

## Project Structure

```
DevKit/
├── DevKit.bat              # Main launcher (batch wrapper)
├── DevKit.ps1              # Main interactive menu (PowerShell)
├── Setup-Path.bat          # Adds DevKit to PATH for global access
├── README.md               # User documentation
├── LICENSE                 # MIT License
├── AGENTS.md               # This file
├── .gitignore              # Git ignore rules
│
├── lib/                    # Shared PowerShell helpers
│   └── DevKit-Common.ps1   # Common functions used by scripts
│
├── ports/                  # Port management tools
│   ├── Scan-Ports.ps1      # Scan common dev ports (3000, 5173, etc.)
│   ├── Scan-Ports.bat      # Batch wrapper
│   ├── Kill-Port.ps1       # Kill process by port or PID
│   └── Kill-AllNode.ps1    # Kill all Node.js processes
│
├── node/                   # Node.js utilities
│   ├── Clear-NpmCache.ps1  # Clear NPM cache
│   ├── Remove-NodeModules.ps1  # Delete node_modules
│   ├── Nuke-And-Reinstall.ps1  # Full reset + reinstall
│   └── Nuke-And-Reinstall.bat  # Batch wrapper
│
├── nextjs/                 # Next.js specific tools
│   ├── Clear-NextCache.ps1     # Clear .next build cache
│   ├── Clear-TurboCache.ps1    # Clear Turbopack cache
│   ├── Next-DevFresh.ps1       # Clear cache + start dev server
│   ├── Next-DevFresh.bat       # Batch wrapper
│   ├── Next-FullClean.ps1      # Full clean + reinstall
│   └── Next-FullClean.bat      # Batch wrapper
│
├── vite/                   # Vite tools
│   ├── Vite-DevFresh.ps1       # Fresh dev server start
│   ├── Vite-DevFresh.bat
│   ├── Vite-PreviewBuild.ps1   # Build and preview
│   └── Vite-PreviewBuild.bat
│
├── git/                    # Git tools
│   ├── Git-Cleanup.ps1         # Prune branches, gc, cleanup
│   ├── Git-Cleanup.bat
│   ├── Git-StatusAll.ps1       # Status across multiple repos
│   ├── Git-StatusAll.bat
│   ├── Git-SyncFork.ps1        # Sync fork with upstream
│   └── Git-SyncFork.bat
│
├── docker/                 # Docker tools
│   ├── Docker-Nuke.ps1         # Remove all Docker resources
│   ├── Docker-Nuke.bat
│   ├── Docker-Cleanup.ps1      # Selective cleanup
│   ├── Docker-Cleanup.bat
│   ├── Docker-QuickLogs.ps1    # Multi-container log tailing
│   └── Docker-QuickLogs.bat
│
├── system/                 # System environment tools
│   ├── Edit-Path.ps1           # PATH variable editor
│   ├── Edit-Path.bat
│   ├── Env-Backup.ps1          # Backup env variables
│   ├── Env-Restore.ps1         # Restore env variables
│   ├── Shell-Reload.ps1        # Reload shell environment
│   └── *.bat
│
├── workflow/               # Developer workflow tools
│   ├── Code-Here.ps1           # Open VS Code/Cursor
│   ├── Code-Here.bat
│   ├── Open-Repo.ps1           # Open repo in browser
│   ├── Open-Repo.bat
│   ├── Copy-EnvTemplate.ps1    # Copy .env template
│   └── Copy-EnvTemplate.bat
│
├── diagnostics/            # Health check tools
│   ├── DevKit-Doctor.ps1       # Environment health check
│   ├── DevKit-Doctor.bat
│   ├── System-DevInfo.ps1      # System info summary
│   └── System-DevInfo.bat
│
└── wifi/                   # WiFi optimization tools
    ├── WiFi-Optimize.ps1   # Full optimization (DNS, TCP/IP, speed test)
    ├── WiFi-Optimize.bat   # Batch wrapper
    ├── WiFi-FastMode.ps1   # Quick optimization (no speed test)
    ├── WiFi-FastMode.bat   # Batch wrapper
    ├── WiFi-Scan.ps1       # Network scanner with signal analysis
    └── WiFi-Scan.bat       # Batch wrapper
```

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
Write-Host "Info message" -ForegroundColor Cyan
Write-Host "Secondary info" -ForegroundColor Gray
Write-Host "Highlight" -ForegroundColor Magenta
```

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

### Port Tools (`ports/`)
- **Common ports scanned:** 3000, 3001, 3002, 3003, 5173, 5174, 8000, 8080, 8081, 9000, 4200, 5000, 5500, 1337, 5432, 3306, 6379, 27017
- Uses `Get-NetTCPConnection` for port detection
- Uses `Get-Process` and `Stop-Process` for process management

### Node.js Tools (`node/`)
- Auto-detects package manager (npm/yarn/pnpm/bun) from lock files
- Executes the correct cache clean command for the detected package manager
- Recursively removes `node_modules` directories using long-path-safe deletion
- Supports `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, and `bun.lockb` cleanup

### Next.js Tools (`nextjs/`)
- Auto-detects package manager (npm/yarn/pnpm/bun) from lock files
- Removes `.next/` build cache directory
- Clears Turbopack cache from `.next/cache`, `node_modules/.cache`, `.turbo`
- Runs the detected package manager's dev command after cache clearing
- Disables Next.js telemetry: `$env:NEXT_TELEMETRY_DISABLED = "1"`

### Vite Tools (`vite/`)
- Clears `.vite/` cache directory and build artifacts
- Supports custom port configuration
- Build and preview production builds

### Git Tools (`git/`)
- Prunes merged branches with `git branch -d`
- Runs garbage collection with `git gc --aggressive`
- Optionally clears reflog
- Scans multiple repositories for status
- Syncs forks with upstream using merge or rebase

### Docker Tools (`docker/`)
- Uses `docker ps`, `docker rm`, `docker rmi`, `docker volume rm` for cleanup
- Supports dry-run mode for safety
- Multi-container log tailing with color coding
- Selective cleanup of dangling images and unused volumes

### System Tools (`system/`)
- Uses `[Environment]::GetEnvironmentVariable` and `SetEnvironmentVariable`
- Supports both User and Machine environment scopes
- Interactive PATH editor with duplicate detection
- JSON backup/restore for environment variables

### Workflow Tools (`workflow/`)
- Detects VS Code and Cursor installations
- Opens repositories in browser (GitHub, GitLab, Bitbucket, Azure DevOps)
- Parses `.env.example` templates for variable extraction
- Converts SSH URLs to HTTPS for browser opening

### Diagnostics (`diagnostics/`)
- Checks tool installations and versions
- Validates Git configuration
- Detects Docker daemon status
- Reports disk space and memory
- Exports system info to JSON

### WiFi Tools (`wifi/`)
- Uses `netsh` commands for network operations
- Uses `Get-NetAdapter` and `Set-DnsClientServerAddress` for DNS management
- Cloudflare DNS (1.1.1.1 / 2606:4700:4700::1111) and Google DNS (8.8.8.8 / 2001:4860:4860::8888) testing
- Speed test via Cloudflare's speed endpoint
- Requires administrator privileges; warns about required reboot after TCP/IP reset

## Usage Patterns

### Interactive Menu Mode
```batch
.\DevKit.bat
```
Launches the main interactive menu for navigation via keyboard input.

### Direct PowerShell Execution
```powershell
.\ports\Kill-Port.ps1 -Port 3000
.\node\Nuke-And-Reinstall.ps1 -Path "C:\my-project"
.\nextjs\Next-DevFresh.ps1 -Port 3001
.\vite\Vite-DevFresh.ps1
.\git\Git-Cleanup.ps1 -DryRun
.\docker\Docker-Nuke.ps1 -DryRun
.\system\Edit-Path.ps1 -Show
.\diagnostics\DevKit-Doctor.ps1
.\wifi\WiFi-Optimize.ps1 -Fast
```

### Batch Wrapper Execution
```batch
.\ports\Scan-Ports.bat
.\git\Git-Cleanup.bat
.\docker\Docker-Nuke.bat
.\diagnostics\DevKit-Doctor.bat
.\wifi\WiFi-Optimize.bat
```

## Security Considerations

- **Administrator privileges** are required for:
  - WiFi optimization features (script checks and warns if not admin)
  - Editing system (Machine) PATH
  - Restoring Machine environment variables
- Batch wrappers use `-NoProfile -ExecutionPolicy Bypass` for fast, predictable launches
- All scripts use `ErrorAction SilentlyContinue` where appropriate to prevent unnecessary failures
- Force flags (`-Force`) are available to skip confirmation prompts for automation
- Docker Nuke requires explicit confirmation (type 'NUKE') to prevent accidents

## Testing

This project does not have automated tests. Testing is done manually:

1. Run scripts in a PowerShell window to observe output
2. Verify colored output displays correctly
3. Test both success and error paths
4. Confirm batch wrappers launch PowerShell correctly
5. Test DryRun modes where available (Docker, Git cleanup)
6. Verify error handling with invalid inputs

## Adding New Tools

When adding a new tool to DevKit:

1. Create the PowerShell script in the appropriate subdirectory
2. Dot-source `lib/DevKit-Common.ps1` for shared helpers (admin checks, path validation, safe deletion, etc.)
3. Include proper comment-based help (SYNOPSIS, DESCRIPTION, PARAMETERS, EXAMPLES)
4. Add a batch wrapper for double-click execution
5. Update `DevKit.ps1` main menu if the tool should be accessible from the interactive menu
6. Update `README.md` with documentation
7. Update `AGENTS.md` with module details
8. Follow existing naming conventions and output styling
9. Test the tool thoroughly

## Common Development Tasks

### Adding a new module category
1. Create a new subdirectory (e.g., `docker/`, `git/`)
2. Add PowerShell scripts and batch wrappers
3. Add menu function to `DevKit.ps1`
4. Update `Show-MainMenu` to include new option
5. Update documentation files

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
- Version 2.1 unifies the toolkit under a shared helper module (`lib/DevKit-Common.ps1`), adds package-manager auto-detection, completes batch-wrapper coverage, and fixes PowerShell 7 / path-validation / process-killing bugs
