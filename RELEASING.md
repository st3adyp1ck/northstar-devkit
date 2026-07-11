# Releasing Northstar DevKit

A short checklist for cutting a new version.

1. **Bump the version** in three places (they're kept in sync manually,
   not read from one file at runtime, to avoid adding a startup file-read
   to every launch):
   - `VERSION` (repo root - the single source of truth for what the
     number *should* be)
   - `DevKit.ps1` - the `.VERSION` comment-help field and the banner text
     inside `Show-Header`
   - `lib\DevKit-Common.ps1` - the `.VERSION` comment-help field
2. **Update `CHANGELOG.md`** with a new `## [x.y.z] - YYYY-MM-DD` section.
   Follow the existing Added / Fixed / Changed structure.
3. **Run the full check locally** before tagging:
   ```powershell
   # Syntax (matches CI)
   Get-ChildItem -Recurse -Filter *.ps1 | ForEach-Object {
       $e=@(); [void][System.Management.Automation.PSParser]::Tokenize((Get-Content $_.FullName -Raw), [ref]$e)
       if ($e.Count) { "SYNTAX ERROR: $($_.FullName)" }
   }

   # Manifests
   Get-ChildItem -Recurse -Filter _module.psd1 | ForEach-Object { Import-PowerShellDataFile $_.FullName | Out-Null }

   # Tests
   Invoke-Pester -Path tests/Unit
   ```
4. **Commit** the version bump and changelog together:
   `git commit -m "Release vX.Y.Z"`.
5. **Tag and push:**
   ```
   git tag vX.Y.Z
   git push origin main --tags
   ```
6. **Cut a GitHub Release** from the tag, pasting the relevant
   `CHANGELOG.md` section as the release notes. Attach a zip of the repo
   (excluding `.git`) if you want a downloadable artifact for users who
   don't clone via git.

## Versioning

Semantic versioning (`MAJOR.MINOR.PATCH`):

- **MAJOR** - breaking changes to script parameters/behavior, or an
  architecture change like the 3.0 manifest-driven menu rewrite.
- **MINOR** - new tools, new menu options, new non-breaking features.
- **PATCH** - bug fixes only.

## Testing scope

This project has no CI-runnable integration tests against real Docker,
git remotes, or network state - by design, since a hosted CI runner
shouldn't have its real PATH mutated or its containers destroyed. `tests/
Unit` covers pure-logic parsers and converters; everything else is
verified manually per the checklist above, plus scripted smoke-tests
through the interactive menu (see recent commit messages for examples of
the exact input sequences used) when the menu-dispatch layer itself
changes.
