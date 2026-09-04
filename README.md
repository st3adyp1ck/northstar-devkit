# Northstar DevKit

A Windows desktop app — an always-on widget plus a searchable Control Center — that runs 69
PowerShell tools with their output streaming live, so you never go hunting for a terminal.
Ships with `devkit`, a terminal CLI over the same tool catalog.

[![Latest release](https://img.shields.io/github/v/release/st3adyp1ck/northstar-devkit?style=flat-square&color=00b4d8)](https://github.com/st3adyp1ck/northstar-devkit/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-green?style=flat-square)](LICENSE)

<!-- TODO: capture and commit these two images, then uncomment. Create docs/images/ first.
     Check each capture before committing - the Git and GitHub panels render real project
     paths, private repo names, PR titles and branch names.
![The companion widget on the desktop](docs/images/widget.png)
![The Control Center running a tool with live output](docs/images/control-center.png)
-->

## What it is

Three surfaces over one set of plain PowerShell scripts:

- **Companion widget** — a small always-on window with CPU/memory/GPU/disk dials, running Node
  processes and their ports, a drawn git commit graph, open PRs and issues, MCP server status,
  per-project notes, and one-click tools. Lives in the tray; closing it just hides it.
- **Control Center** — every tool as a searchable card with a form built from the tool's manifest.
  Output streams into the run dialog as it runs; nothing opens a separate terminal window.
- **`devkit` CLI** — a terminal menu over the same catalog, for when you are already in a shell.

Pick a project once in the picker and it becomes your **Active Project**, shared across all three.

## Install

Download the latest `DevKit_x.y.z_x64-setup.exe` from
[Releases](https://github.com/st3adyp1ck/northstar-devkit/releases) and run it. The install is
per-user — no admin rights — and uninstalls from Settings > Apps like any other Windows app.

Two things worth knowing before you click:

- The installer is **not yet Authenticode code-signed**, so Windows SmartScreen will warn on first
  run: *More info > Run anyway*. The update artifacts are minisign-signed, and that signature is
  what the in-app updater verifies before installing anything.
- If the **WebView2 runtime** is missing, the installer downloads it from Microsoft, so a
  first-time install needs a network connection.

### Build from source

```powershell
git clone https://github.com/st3adyp1ck/northstar-devkit.git
cd northstar-devkit/app
pnpm install
pnpm tauri build
```

The installer lands at `target/release/bundle/nsis/DevKit_<version>_x64-setup.exe`, relative to the
repo root.

The `devkit` CLI has no installer yet and is not part of that build — build it separately:

```powershell
cargo build --release -p devkit-cli
.\target\release\devkit.exe
```

## Quick start

1. Launch **DevKit** from the Start Menu or Desktop icon — it opens the companion widget.
2. Pick your project in the widget's project selector.
3. Click the **DEVKIT** plate at the foot of the widget's tray rail to slide out the Control
   Center. (If you have set the widget to float, the button is in its title bar instead.)
4. Search for a tool, hit **Run**, and watch its output stream into the dialog.

## What's in it

| Category | What it does |
| --- | --- |
| Ports | Scan and kill dev ports, find Windows-reserved ranges, health-check an endpoint |
| Node.js | Clear caches, remove `node_modules`, reinstall, run a package.json script |
| Next.js | Clear `.next` and Turbopack caches, fresh dev server, full clean |
| Vite | Fresh dev server, preview builds |
| Git | Cleanup, status across all repos, sync forks, standup log |
| Docker | Nuke containers and images, cleanup, tail logs |
| System | Edit PATH, back up and restore env vars, hosts file, Admin Mode |
| Workflow | Open editor/repo, copy `.env` templates, `.env` drift check, end-of-day close-out |
| Diagnostics | Environment health check, system info export |
| WiFi | Optimize DNS, scan networks, speed test |
| Maintenance | Disk cleanup, startup/services tuning, SFC/DISM repair, Windows Update reset, power and hardware health |
| Agents & MCP | Detect and update AI CLIs, add MCP servers from a catalog or by hand, scan for missing ones |

Every tool is a plain PowerShell script under `tools/` — the widget, the Control Center and the
CLI all run these exact files, and so can you:

```powershell
.\tools\ports\Kill-Port.ps1 -Port 3000
.\tools\nextjs\Next-FullClean.ps1 -Path "C:\my-project"
.\tools\git\Git-Cleanup.ps1 -Path "C:\my-project"
.\tools\diagnostics\DevKit-Doctor.ps1
.\tools\workflow\Close-OutSession.ps1 -DryRun
```

For the full, always-current list, run `devkit catalog` (prints the catalog as JSON) or search the
Control Center. Tools that change system state are badged **Caution**, ask for confirmation, and
mostly support `-DryRun` — preview first.

## What it touches

- Linked projects and settings live in `%LOCALAPPDATA%\NorthstarDevKit\` (`projects.json`,
  `settings.json`). Nothing project-specific is written into the install folder.
- **Network access**, in full: the updater checks GitHub Releases (throttled to once per 24h, plus
  a manual **Check for Updates** button) and, when an update exists, downloads it, verifies its
  minisign signature, installs and relaunches in place; the widget's GitHub panel shells out to
  your own authenticated `gh` CLI to list pull requests and issues; the AI CLI updater queries the
  GitHub Releases API for the tools it manages; the installer fetches the Microsoft WebView2
  runtime if it is absent. No telemetry is collected.
- **Admin Mode** is optional and off by default. Enabling it registers a scheduled task that
  launches DevKit elevated without a per-launch UAC prompt. The trade-off, stated plainly: while
  elevated, every tool and the embedded terminal run as Administrator. It is fully reversible.

## Requirements

To run the installed app:

- Windows 10 or 11
- PowerShell 7 (`pwsh`) recommended — Windows PowerShell 5.1 works as a fallback
- Optional, per tool: Node.js, Git, Docker Desktop, GitHub CLI (`gh`)

To build from source: Rust (stable toolchain), Node.js and pnpm.

## Documentation

- [CHANGELOG.md](CHANGELOG.md) — release history
- [AGENTS.md](AGENTS.md) — architecture and repo layout
- [CONTRIBUTING.md](CONTRIBUTING.md) — how to contribute
- [SECURITY.md](SECURITY.md) — reporting a vulnerability
- [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) — community standards

## Support

- Bugs and feature requests:
  [open an issue](https://github.com/st3adyp1ck/northstar-devkit/issues/new/choose)
- Questions and ideas:
  [Discussions](https://github.com/st3adyp1ck/northstar-devkit/discussions)
- Security vulnerabilities: see [SECURITY.md](SECURITY.md) — please don't file a public issue
- Anything else: [thesage@northstarcoding.com](mailto:thesage@northstarcoding.com)

## License

MIT — see [LICENSE](LICENSE). Built by
[Northstar Software Development](https://www.northstarcoding.com).

Northstar DevKit is an independent project. It is not affiliated with, sponsored by, or endorsed
by GitHub, Inc. GitHub and the GitHub logo are trademarks of GitHub, Inc.
