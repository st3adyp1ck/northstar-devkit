# Releasing Northstar DevKit

A short checklist for cutting a new version of the Tauri app (`app/`,
`cli/`, `crates/devkit-host`).

## 1. Bump the version

Keep these three in sync manually (not read from one file at runtime):

- `VERSION` (repo root)
- `app/src-tauri/tauri.conf.json`'s `"version"` field - this is what
  ends up in the built installer's filename and the updater's
  `latest.json`
- `crates/devkit-host` / `app/src-tauri` / `cli`'s `version.workspace = true`
  fields read `[workspace.package].version` in the root `Cargo.toml` -
  bump that once, it covers all three crates

## 2. Update `CHANGELOG.md`

New `## [x.y.z] - YYYY-MM-DD` section, following the existing Added /
Fixed / Changed structure.

## 3. Run the full check locally before tagging

```powershell
# PowerShell suite (still covers tools/lib, core/, tests/Unit - the RPC
# sidecar's logic layer)
Invoke-Pester -Path tests/Unit

# Rust workspace
cargo check --workspace
cargo clippy --workspace --all-targets
cargo test --workspace

# Frontend
cd app
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

## 5. Tag and push the tag

```powershell
git tag vX.Y.Z
git push origin vX.Y.Z
```

This triggers `.github/workflows/release.yml`: it builds the app on
`windows-latest`, signs the updater artifacts with the
`TAURI_SIGNING_PRIVATE_KEY` repo secret, and opens a **draft** GitHub
Release with the NSIS installer, its `.sig`, and `latest.json`.

## 6. Review and publish

Open the draft release, sanity-check the attached installer/assets, then
click **Publish release**. Only then does the in-app updater's endpoint
(`releases/latest/download/latest.json`) actually resolve to it - a
draft is invisible to installed copies of DevKit.

## Versioning

Semantic versioning (`MAJOR.MINOR.PATCH`):

- **MAJOR** - breaking changes, or an architecture change (e.g. the
  WPF -> Tauri v2 rewrite).
- **MINOR** - new panels/tools, new non-breaking features.
- **PATCH** - bug fixes only.

## Testing scope

No CI-runnable integration tests against real Docker, git remotes, or
network state - by design, since a hosted CI runner shouldn't have its
real PATH mutated or its containers destroyed. `tests/Unit` covers the
PowerShell logic layer (pure-logic parsers/converters, still shared by
the RPC sidecar); Rust has `cargo test` for `devkit-host`'s protocol
layer; everything else is verified manually per the checklist above.
