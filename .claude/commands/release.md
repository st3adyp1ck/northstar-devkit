---
description: Cut a DevKit release end-to-end — gates, version bump, CHANGELOG rollover, commit, push, tag, watch the build, and verify the updater actually serves it
---

# RELEASE — the one trigger for the whole pipeline

Cut a release of Northstar DevKit, start to finish. The tag IS the release
(`release.yml` has `releaseDraft: false`, since commit b0791e6 — v4.2.0
itself was still a draft, published by hand; v4.3.0 is the first tag this
applies to): pushing `vX.Y.Z` builds, signs, and PUBLISHES, and every
installed copy is offered it. So this command is deliberately paranoid —
nothing gets tagged until every gate is green and every number agrees.

`dev/RELEASING.md` is the long-form runbook this automates and the source
of truth for WHY each step exists; if the two ever disagree, STOP and
reconcile them before releasing — don't guess which one is stale.

## Arguments

- `/release` — infer the bump from CHANGELOG's `[Unreleased]` section
  (anything under `### Added`/`### Changed` → minor; only `### Fixed` →
  patch; breaking/architecture → major) and CONFIRM the number with me
  before writing anything.
- `/release minor` | `patch` | `major` — bump that part; still show me the
  resulting number in the final confirmation before the tag is pushed.
- `/release X.Y.Z` — use exactly that version.

## 0. Preconditions — abort (report, don't fix silently) if any fails

- Working tree is clean, on `main`, and in sync with `origin/main`. If
  there are uncommitted changes, ask whether they belong in this release —
  never tag around them.
- The target tag does not already exist, locally or on the remote
  (`git tag -l` + `git ls-remote --tags origin`). A tag can never be
  reused: the version triple is baked into signed artifacts.
- The previous release run actually PUBLISHED. Check
  `gh release list --limit 3` — a tag with no release means a dead CI run
  (v4.1.0 sat 57 hours without a runner and was cancelled; nobody noticed
  for days). Flag it; it doesn't block this release but I should know.
- CI is green on current HEAD (`gh run list --branch main --limit 1`), or
  the local gates below all pass.

## 1. Run every gate locally

Same set as CI (`.github/workflows/ci.yml` is the source of truth for the
gate set — this list and `dev/RELEASING.md` §3 both mirror it; update all
three together if CI changes), plus the one CI can't do (the version check
comes after the bump). All must pass — paste real failures, never
summaries:

```powershell
Invoke-Pester -Path tests/Unit
Invoke-ScriptAnalyzer -Path . -Recurse -Severity ParseError, Error -ExcludeRule PSAvoidUsingComputerNameHardcoded
cargo check --workspace          # cargo is at $env:USERPROFILE\.cargo\bin in a fresh shell
cargo clippy --workspace --all-targets
cargo test --workspace
cd app
pnpm install --frozen-lockfile
npx tsc --noEmit
npx vitest run                   # no "test" script in package.json — invoke directly
npx vite build
```

If `Invoke-ScriptAnalyzer` isn't on the default module path, try
`Install-Module PSScriptAnalyzer -Force -SkipPublisherCheck` (what
`ci.yml` does) first. A machine that happens to have a vendored copy at
`.kimi/psmodules/PSScriptAnalyzer/<version>/PSScriptAnalyzer.psd1` (a
git-ignored, machine-local cache — not something every checkout has) can
`Import-Module` that exact path instead.

## 2. Bump the version — all FOUR files, atomically

The triple that must agree (the one people forget is `tauri.conf.json`,
and it is the one that breaks the updater — see `dev/RELEASING.md` §1):

1. `VERSION` — the whole file, e.g. `4.3.0`
2. `Cargo.toml` — `[workspace.package]` `version`
3. `app/src-tauri/tauri.conf.json` — `"version"`
4. `Cargo.lock` — regenerate by running `cargo check --workspace` AFTER
   editing Cargo.toml, then VERIFY the lock diff is exactly the three
   workspace crates' version lines (`git diff Cargo.lock`) — any
   dependency churn in that diff is a red flag, stop and look.

Then replicate CI's own verify-version logic locally: read all four
sources, assert strict `MAJOR.MINOR.PATCH`, assert all identical, and
identical to the tag about to be created.

## 3. Roll the CHANGELOG

Rename `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD` (today, local). If
there was no `[Unreleased]` section, something is wrong — every release
should have accumulated notes; stop and ask me. Do NOT create a fresh
empty `[Unreleased]` stub (the next change adds it).

## 4. Commit and push main

```
chore: vX.Y.Z
```

One commit with the four version files + CHANGELOG. Push `main`, then wait
for the FULL CI run on this exact commit to finish green — all four jobs,
not just `verify-version`. `validate-powershell` in particular checks
things no local gate does (an AST parse of every `.ps1`/`.psm1`/`.psd1`,
and an `Import-PowerShellDataFile` load of every `tools/*/_module.psd1`
manifest), so a fast green `verify-version` is not permission to move on.

```powershell
$sha = git rev-parse HEAD
$runId = (gh run list --branch main --workflow CI --json databaseId,headSha --limit 5 |
  ConvertFrom-Json | Where-Object headSha -eq $sha | Select-Object -First 1).databaseId
gh run watch $runId --exit-status
```

With auto-publish, a tag on a red main ships a red build — do not tag
until this exits 0. If `$runId` comes back empty, the run hasn't been
picked up by GitHub yet; wait and retry rather than guessing at
`gh run list --limit 1`, which returns whatever ran most recently and may
not be this push.

## 5. Tag — the point of no return

Annotated, matching the existing convention:

```powershell
git tag -a vX.Y.Z -m "Northstar DevKit vX.Y.Z"
git push origin vX.Y.Z
```

This is the ONE step that needs my explicit go-ahead if anything earlier
raised a flag. A clean run through steps 0-4 with a version I already
confirmed does not need a second ask.

## 6. Watch the build to completion — never fire and forget

```powershell
$runId = (gh run list --workflow release.yml --limit 1 --json databaseId,headBranch |
  ConvertFrom-Json | Where-Object headBranch -eq "vX.Y.Z").databaseId
gh run watch $runId --exit-status
```

Confirm `headBranch` really is the tag just pushed before watching — the
most recent `release.yml` run is not necessarily this one if something
else tagged in the same window. If the list comes back empty, GitHub
hasn't picked up the push yet; wait and retry.

The v4.1.0 lesson: a cancelled or stuck run means the tag exists but no
release does, and nothing tells you. If the run fails: report it with the
failing step's log. Do NOT delete the tag or retag on your own — a repair
needs me.

## 7. Verify the updater actually serves it

The build succeeding is not the finish line. Confirm all three:

```powershell
gh release view vX.Y.Z    # draft: false, marked Latest, 3 assets (setup.exe, .sig, latest.json)
curl -sL https://github.com/st3adyp1ck/northstar-devkit/releases/latest/download/latest.json
```

`latest.json` must report the NEW version — that URL is exactly what
installed copies hit. If it still shows the previous version, the release
did not publish and no amount of "Check for Updates" will help.

## 8. Report

Version, release URL, what `latest.json` now serves, and the one-line
reminder: machines pick it up within 24h, or immediately via
Check for Updates.
