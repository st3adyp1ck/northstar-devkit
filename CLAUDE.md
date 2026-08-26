# Northstar DevKit — Claude Notes

Full architecture, conventions, and module docs live in **AGENTS.md** — read it
before substantive work. This file carries only what audits and quick sessions
need immediately.

## Audit gates (`/audit`, `/audit-quick` — "run the project's real verification" means THIS)

Run every gate whose layer the session touched; for `/audit`, run all of them.

**PowerShell (`core/`, `tools/`, `tests/`):**

```powershell
Invoke-Pester -Path tests/Unit
Invoke-ScriptAnalyzer -Path . -Recurse -Severity ParseError, Error -ExcludeRule PSAvoidUsingComputerNameHardcoded
```

PSScriptAnalyzer Warning-level findings are advisory here (Write-Host IS the
output contract for interactive tools); ParseError/Error severity is the
enforced gate, matching `.github/workflows/ci.yml`.

**Rust workspace (`app/src-tauri`, `cli/`, `crates/devkit-host`):**

```powershell
# NOTE: cargo is not on PATH in a fresh shell here:
#   $env:PATH = "$env:USERPROFILE\.cargoin;" + $env:PATH

cargo check --workspace
cargo clippy --workspace --all-targets
cargo test --workspace
```

**Frontend (`app/`):**

```powershell
cd app
npx tsc --noEmit
npx vitest run          # no "test" script in package.json — invoke vitest directly
npx vite build
```

**Version triple (if any release/version file was touched):** `VERSION`,
`Cargo.toml` `[workspace.package].version`, and `app/src-tauri/tauri.conf.json`
`"version"` must be identical — a stale tauri.conf.json silently breaks the
in-app updater.

## Contract danger zones (check BOTH sides on every audit)

These are the boundaries where this repo actually breaks. Any change near one
means reading both sides, not assuming:

1. **The RPC chain** — a method flows through all of:
   `app/src/lib/ipc.ts` + `app/src/lib/types.ts` (TS types) →
   `crates/devkit-host/src/protocol.rs` (Rust framing) →
   `core/RpcMethods.ps1` (dispatch) →
   `core/DevKit-WidgetCore.ps1` / `DevKit-GuiCore.ps1` (payload shapes).
   JSON property casing must agree end-to-end; there is no codegen keeping
   them in sync.
2. **`catalog.get` has TWO consumers** — `ControlCenterApp.tsx` (app) and
   `cli/src/catalog.rs` (CLI). A payload change must be verified in both, plus
   `devkit catalog` still parsing.
3. **Two tool-execution paths** — Control Center runs tools headless
   (`tool.run`, `-NonInteractive`, stdin closed); the CLI spawns them fully
   interactive. A tool working on one surface proves nothing about the other.
4. **Streamed events** — `tool.output`/`tool.finished` keyed by `runId`,
   `devkit://terminal`, `devkit://visibility`. Event names and payload shapes
   are stringly-typed across Rust and TS.
5. **Sidecar invariants** (`core/Invoke-DevKitRpc.ps1`) — single writer
   runspace owns stdout; three lanes route by method-name prefix. Read the
   file's threading comment before touching it.
6. **New features go in `RpcMethods.ps1`, not new Tauri commands** — Rust
   commands are only for genuine OS-level work (windows, tray, ConPTY).

## Hard safety rule for audits and testing

**Never execute a mutating tool script's real path to "test" it** — only its
documented `-DryRun`/`-WhatIf`/report invocation. This applies to
`tools/maintenance/` and `tools/agents/` especially, and to agents exactly as
much as humans (see AGENTS.md "Security Considerations" for the incident that
made this a rule). Destructive-action prompts route through
`Confirm-DevKitDestructiveAction` (PS) / `useConfirmDestructive()` (TS) — new
destructive paths must use those, never hand-rolled prompts.

## Not yet applied: bundling the CLI into the installer

`.github/workflows/{ci,release}.yml` already build and stage `devkit.exe`, but
`app/src-tauri/tauri.conf.json` does NOT yet reference it, so nothing bundles it
and `cargo check` needs no pre-staging today. Applying it is two edits — a
`beforeBuildCommand` that runs `cargo build --release -p devkit-cli` and copies
the exe to `app/src-tauri/bin/`, plus a `"bin/devkit.exe": "devkit.exe"`
resources entry — and it comes with a real ordering constraint:
`tauri_utils`'s `resource_from_path` hard-fails with `ResourcePathNotFound`
when the file is missing, and build scripts run under `cargo check`, so from
that moment on EVERY cargo command on a fresh clone fails until the CLI is
built and staged. `app/src-tauri/bin/` would also need a `.gitignore` entry.

Payoff when it lands: `tools/system/Install-ShellIntegration.ps1` and
`Register-DevKitTerminalProfile.ps1` both probe `<installroot>\devkit.exe`
first and currently hard-exit on any installed copy.
