# Releasing Northstar DevKit

A short checklist for cutting a new version of the Tauri app (`app/`,
`cli/`, `crates/devkit-host`).

> **Automated:** the `/release` command (`.claude/commands/release.md`)
> runs this whole checklist end-to-end - gates, bump, CHANGELOG, tag,
> build watch, and the updater check. This file remains the authority on
> WHY each step exists; if the two ever disagree, reconcile before
> releasing.

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

Notes accumulate under `## [Unreleased]` as work happens (`### Added` /
`### Changed` / `### Fixed`). At release time, RENAME that header to
`## [x.y.z] - YYYY-MM-DD` (today, local) - don't add a new section above
or below it, and don't leave a fresh empty `[Unreleased]` stub behind (the
next change adds one). If there is no `[Unreleased]` section when you go
to release, something is wrong - every release should have accumulated
notes; stop and figure out why before proceeding.

## 3. Run the full check locally before tagging

This is the same set CI runs. (No CLI pre-staging is needed today:
`tauri.conf.json` does not yet list `bin/devkit.exe` as a resource, so
bare cargo commands work on a fresh clone - see "When the CLI bundling
lands" below for what changes on the day it does.)

```powershell
# 1. PowerShell suite (covers tools/lib, core/, tests/Unit - the RPC
#    sidecar's logic layer) plus the enforced analyzer gate
Invoke-Pester -Path tests/Unit
Invoke-ScriptAnalyzer -Path . -Recurse -Severity ParseError, Error -ExcludeRule PSAvoidUsingComputerNameHardcoded

# 2. Rust workspace
cargo check --workspace
cargo clippy --workspace --all-targets
cargo test --workspace

# 3. Frontend (vitest is invoked directly - package.json has no "test"
#    script, so `pnpm test` would silently run nothing)
cd app
pnpm install --frozen-lockfile
npx tsc --noEmit
npx vitest run
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
git commit -m "chore: vX.Y.Z"
git push origin main
```

CI (`.github/workflows/ci.yml`) runs four parallel jobs on
`windows-latest`: the version triple, PowerShell (analyzer gate, syntax
check over `.ps1`/`.psm1`/`.psd1`, Pester), the Rust workspace
(check/clippy/test), and the frontend (`tsc --noEmit`, `vitest run`, and
a production `vite build`). It deliberately does **not** build the
installer - that is release-only.

## 5. Tag and push the tag

Annotated, not lightweight - every existing tag (v4.0.0-v4.2.0) carries a
message, and tooling that reads tag annotations (`git for-each-ref`, GitHub's
own release-from-tag view) expects one:

```powershell
git tag -a vX.Y.Z -m "Northstar DevKit vX.Y.Z"
git push origin vX.Y.Z
```

This triggers `.github/workflows/release.yml`: it verifies the tag against
the version triple, builds the app on `windows-latest`, signs the updater
artifacts with the `TAURI_SIGNING_PRIVATE_KEY` repo secret, and **publishes**
a GitHub Release with the NSIS installer, its `.sig`, and `latest.json`.

## 6. Confirm it went live

The release publishes itself - there is no second click. `releaseDraft:
false` landed in commit b0791e6 ("ci: publish releases on tag instead of
leaving a draft"), pushed AFTER the v4.2.0 tag - so v4.2.0 itself was
built as a draft and published by hand, and v4.3.0 is the first tag this
auto-publish path actually applies to. A draft resolves for nobody: the
updater's endpoint only ever points at published releases, so a tag whose
release is left in draft reaches no machine at all - which is exactly why
the flip was made.

So the tag IS the release. Check it actually landed:

```powershell
gh release view vX.Y.Z            # draft: false, and marked Latest
curl -sL https://github.com/st3adyp1ck/northstar-devkit/releases/latest/download/latest.json
```

That second command is the exact URL installed copies of DevKit hit; the
`version` it reports is what they will be offered. If it still shows the
PREVIOUS version, the release did not publish and no amount of pressing
"Check for Updates" will help.

**This means a bad build ships the moment you tag it**, and a machine that
has already updated stays on it until the next tag - deleting the release
un-advertises it but rolls nobody back. Tag from a green `main`.

## What the installer ships

`bundle.resources` in `app/src-tauri/tauri.conf.json` copies these into the
install root (`%LOCALAPPDATA%\DevKit\`, since `installMode` is
`currentUser`):

| Source | Installed as |
| --- | --- |
| `core/` | `<installroot>\core\` - the RPC sidecar |
| `tools/` | `<installroot>\tools\` - the ~65 tool scripts |
| `VERSION` | `<installroot>\VERSION` |

**The `devkit` CLI is NOT bundled yet.** `release.yml` builds and stages
`app/src-tauri/bin/devkit.exe` on every tag, but `tauri.conf.json` neither
runs that staging in `beforeBuildCommand` nor lists `bin/devkit.exe` as a
resource, so the staged exe is ignored and an installed app has no
`<installroot>\devkit.exe`. `tools\system\Install-ShellIntegration.ps1`
and `Register-DevKitTerminalProfile.ps1` both probe that exact path first
and hard-exit when it is missing, so shell/terminal integration works only
from a source checkout for now.

### When the CLI bundling lands

Applying it is two edits to `tauri.conf.json` - a `beforeBuildCommand`
that runs `cargo build --release -p devkit-cli` and copies the exe to
`app/src-tauri/bin/`, plus a `"bin/devkit.exe": "devkit.exe"` resources
entry - and it carries a real ordering constraint: `tauri-build`
hard-fails with `ResourcePathNotFound` when a configured resource is
missing, and build scripts run under `cargo check` too, so from that
moment on EVERY cargo command that touches `app/src-tauri` on a fresh
clone fails until the CLI has been built and staged:

```powershell
cargo build --release -p devkit-cli
New-Item -ItemType Directory -Force -Path app/src-tauri/bin | Out-Null
Copy-Item -Force target/release/devkit.exe app/src-tauri/bin/devkit.exe
```

`app/src-tauri/bin/` will also need a `.gitignore` entry, and this
runbook's "run the full check locally" section will need the staging step
put back at the top. The staging copy (rather than pointing the resource
inside `target/`) is deliberate: a resource at `target/release/devkit.exe`
would let a **debug** app build copy the release CLI over
`target/debug/devkit.exe` while Cargo still considers that path fresh, so
`cargo run -p devkit-cli` would silently run the release binary.
See also the matching section in `CLAUDE.md`.

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
- **Frontend** - `tsc --noEmit`, the vitest suite, and a production `vite build`.

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
