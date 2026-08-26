# Releasing Northstar DevKit

A short checklist for cutting a new version of the Tauri app (`app/`,
`cli/`, `crates/devkit-host`).

## 1. Bump the version

Three files declare a version and **all three must agree**:

| File | Field | Why it matters |
| --- | --- | --- |
| `VERSION` (repo root) | whole file | Shipped as a bundle resource; what the app reports about itself |
| `Cargo.toml` (repo root) | `[workspace.package]` `version` | Covers all three crates - `app/src-tauri`, `cli`, and `crates/devkit-host` each say `version.workspace = true` |
| `app/src-tauri/tauri.conf.json` | `"version"` | Installer filename, and the version the **updater** compares against |

Nothing reads one of these from another at runtime, so they drift silently.

**The one people forget is `tauri.conf.json`, and it is the one that breaks
the updater.** The in-app updater compares the running build against the
version baked in from `tauri.conf.json`. Tag `v4.0.1` while
`tauri.conf.json` still says `4.0.0` and you get an installer named
`DevKit_4.0.0_x64-setup.exe`, a `latest.json` advertising `4.0.0`, and
installed clients that either never see the release or are re-offered a
version they already have.

This is now enforced in two places, so a bad bump cannot reach a signed
installer:

- **`.github/workflows/ci.yml`** - the `verify-version` job fails any push
  or PR where the three disagree, or where a member crate stops saying
  `version.workspace = true`.
- **`.github/workflows/release.yml`** - the first step after checkout also
  compares all three against the pushed tag (`v4.0.1` -> `4.0.1`) and
  aborts before the ~15-minute build rather than after it.

Both gates require a strict `MAJOR.MINOR.PATCH` - no prerelease suffixes.
Adding `-beta.1` support means loosening the regex in both workflows and
setting `prerelease: true` in `release.yml`.

To check locally before you push:

```powershell
$version = (Get-Content VERSION -Raw).Trim()
$cargo   = (Select-String -Path Cargo.toml -Pattern '^version = "(.+)"').Matches[0].Groups[1].Value
$tauri   = (Get-Content app/src-tauri/tauri.conf.json -Raw | ConvertFrom-Json).version
"$version / $cargo / $tauri"
```

## 2. Update `CHANGELOG.md`

New `## [x.y.z] - YYYY-MM-DD` section, following the existing Added /
Fixed / Changed structure.

## 3. Run the full check locally before tagging

This is the same set CI runs, in the same order. **Build the CLI first** -
see the note below on why the Rust workspace will not even `cargo check`
without it.

```powershell
# 1. The devkit CLI, staged where the bundler expects it. Required before
#    any cargo command that touches app/src-tauri (see "Why the CLI must be
#    built first" below).
cargo build --release -p devkit-cli
New-Item -ItemType Directory -Force -Path app/src-tauri/bin | Out-Null
Copy-Item -Force target/release/devkit.exe app/src-tauri/bin/devkit.exe

# 2. PowerShell suite (covers tools/lib, core/, tests/Unit - the RPC
#    sidecar's logic layer)
Invoke-Pester -Path tests/Unit

# 3. Rust workspace
cargo check --workspace
cargo clippy --workspace --all-targets
cargo test --workspace

# 4. Frontend
cd app
pnpm install --frozen-lockfile
npx tsc --noEmit
npx vite build
```

Optionally, smoke-test a real build before tagging:

```powershell
cd app
pnpm tauri build
```

### Warning: test installers silently overwrite the real install

Tauri's NSIS installer remembers the previous install directory per-user
(in HKCU), so running a locally built test setup exe on a machine with a
production DevKit install will silently install OVER the real install's
location. This actually hijacked a production install during testing on
2026-08-25 - don't relearn it. Never run a test-built setup exe on a
machine with a production install, or uninstall the production copy first.

## 4. Commit and push

```powershell
git commit -m "Release vX.Y.Z"
git push origin main
```

CI (`.github/workflows/ci.yml`) runs four parallel jobs on
`windows-latest`: the version triple, PowerShell (analyzer gate, syntax
check over `.ps1`/`.psm1`/`.psd1`, Pester), the Rust workspace
(check/clippy/test), and the frontend (`tsc --noEmit` + `vite build`). It
deliberately does **not** build the installer - that is release-only.

## 5. Tag and push the tag

```powershell
git tag vX.Y.Z
git push origin vX.Y.Z
```

This triggers `.github/workflows/release.yml`: it verifies the tag against
the version triple, builds the app on `windows-latest`, signs the updater
artifacts with the `TAURI_SIGNING_PRIVATE_KEY` repo secret, and opens a
**draft** GitHub Release with the NSIS installer, its `.sig`, and
`latest.json`.

## 6. Review and publish

Open the draft release, sanity-check the attached installer/assets, then
click **Publish release**. Only then does the in-app updater's endpoint
(`releases/latest/download/latest.json`) actually resolve to it - a
draft is invisible to installed copies of DevKit.

## What the installer ships

`bundle.resources` in `app/src-tauri/tauri.conf.json` copies these into the
install root (`%LOCALAPPDATA%\DevKit\`, since `installMode` is
`currentUser`):

| Source | Installed as |
| --- | --- |
| `core/` | `<installroot>\core\` - the RPC sidecar |
| `tools/` | `<installroot>\tools\` - the ~65 tool scripts |
| `VERSION` | `<installroot>\VERSION` |
| `app/src-tauri/bin/devkit.exe` | `<installroot>\devkit.exe` - the ratatui CLI |

Shipping the CLI is what makes `tools\system\Install-ShellIntegration.ps1`
and `tools\system\Register-DevKitTerminalProfile.ps1` work on an installed
app. Both resolve the install root as two levels above `tools\system\` and
probe `<installroot>\devkit.exe` **first**, falling back to
`target\release\devkit.exe` and `target\debug\devkit.exe`, which only exist
in a dev checkout. Before the CLI was bundled, both tools simply refused to
run on an installed copy.

### Why the CLI must be built first

`app/src-tauri/bin/devkit.exe` is a build artifact, not a checked-in file,
and `tauri-build`'s build script hard-fails with `ResourcePathNotFound`
when a configured resource is missing. Build scripts run under `cargo
check` too, so on a fresh clone **every** cargo command that touches
`app/src-tauri` fails until the CLI has been built and staged:

```powershell
cargo build --release -p devkit-cli
New-Item -ItemType Directory -Force -Path app/src-tauri/bin | Out-Null
Copy-Item -Force target/release/devkit.exe app/src-tauri/bin/devkit.exe
```

`pnpm tauri build` does this for you - it is the tail of
`beforeBuildCommand` in `tauri.conf.json` - so a full build is
self-contained. It is only the bare `cargo check` / `clippy` / `test` path
that needs the staging step run by hand once. Both CI workflows run it as
an explicit first step for the same reason.

The staging copy exists so that the resource never points inside `target/`
itself. Pointing it at `target/release/devkit.exe` directly would work for
a release build, but a **debug** build of the app would then copy the
release CLI over `target/debug/devkit.exe` while Cargo still considers that
path fresh - so `cargo run -p devkit-cli` would silently run the release
binary. `app/src-tauri/bin/` sidesteps that entirely.

### `devkit` is not on `PATH`, on purpose

The CLI installs to `<installroot>\devkit.exe`, but the installer does not
add that directory to the user `PATH`. It is possible - Tauri v2 supports
an NSIS `installerHooks` file exposing `NSIS_HOOK_POSTINSTALL` /
`NSIS_HOOK_POSTUNINSTALL` macros - but it is not clean:

- **Truncation.** The stock NSIS build Tauri downloads has
  `NSIS_MAX_STRLEN = 1024`. `ReadRegStr` on `HKCU\Environment` `Path`
  silently truncates a longer value, and writing the truncated string back
  destroys the tail of the user's `PATH`. Developer machines routinely
  exceed 1024 characters. The usual fix is the EnVar NSIS plugin, which
  reads and writes in chunks - but injecting a plugin DLL means replacing
  Tauri's whole NSIS template, which then has to be re-reconciled on every
  Tauri upgrade.
- **Duplicates.** Every upgrade re-runs the post-install hook, so the entry
  has to be scanned for before appending, in NSIS string primitives.
- **Removal.** The uninstall hook has to remove exactly its own entry
  without disturbing neighbours, with the same truncation risk. Tauri's
  upgrade flow also invokes the old uninstaller in some paths, so a
  careless implementation removes the entry immediately after adding it.

None of that is worth it, especially since the two shipped integrations
never rely on `PATH` - they both embed the absolute path to `devkit.exe`:

- **`Install-ShellIntegration.ps1`** - "Open Northstar DevKit Here" on the
  Explorer folder-background right-click menu.
- **`Register-DevKitTerminalProfile.ps1`** - a Windows Terminal profile
  fragment.

If a bare `devkit` command is wanted later, the right shape is a third
opt-in tool alongside those two - a PowerShell script that appends the
install root to `HKCU\Environment` `Path` and broadcasts
`WM_SETTINGCHANGE`, with a matching uninstaller. PowerShell has no
1024-character limit, can dedupe before appending, and can be reverted
cleanly. Do not do it from NSIS.

## Versioning

Semantic versioning (`MAJOR.MINOR.PATCH`):

- **MAJOR** - breaking changes, or an architecture change (e.g. the
  WPF -> Tauri v2 rewrite).
- **MINOR** - new panels/tools, new non-breaking features.
- **PATCH** - bug fixes only.

## Testing scope

No CI-runnable integration tests against real Docker, git remotes, or
network state - by design, since a hosted CI runner shouldn't have its
real PATH mutated or its containers destroyed. What CI does cover:

- **PowerShell** - `tests/Unit` (the pure-logic parsers/converters shared
  by the RPC sidecar), a syntax/AST parse of every tracked `.ps1`, `.psm1`
  and `.psd1`, an `Import-PowerShellDataFile` load of every
  `tools/*/_module.psd1` menu manifest, and a PSScriptAnalyzer gate.
- **Rust** - `cargo check`, `cargo clippy --all-targets` and `cargo test`
  across the whole workspace.
- **Frontend** - `tsc --noEmit` and a production `vite build`.

Everything else - real installs, the updater round-trip, tray behaviour,
the tool scripts against live systems - is verified manually per the
checklist above.

### The PSScriptAnalyzer gate is deliberately two-tier

`ci.yml` runs the analyzer twice, on purpose:

1. **Advisory** (`Error, Warning`) - prints a per-rule summary and never
   fails. Roughly 1090 of the ~1290 current findings are
   `PSAvoidUsingWriteHost`, and the tools are interactive console programs:
   `Write-Host` *is* the output contract here, not a defect.
2. **Enforced** (`ParseError, Error`) - fails the job. The only excluded
   rule is `PSAvoidUsingComputerNameHardcoded`, which fires three times in
   `tools/wifi/WiFi-Optimize.ps1` on `Measure-DevKitPingLatency
   -ComputerName 8.8.8.8 / 1.1.1.1` - public DNS resolvers used as latency
   probes, not a leaked internal hostname.

The previous single step passed `-Severity Warning` (which filters to
Warning *only*, hiding every Error-severity finding) and then printed the
results without ever setting a non-zero exit code, so it could not fail
under any circumstances.
