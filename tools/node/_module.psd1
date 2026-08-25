@{
    Name        = "Node.js Tools"
    Description = "Node.js dependency and package-manager cache tools: auto-detects npm/yarn/pnpm/bun from the project's lock file (or package.json's packageManager field) and dispatches to the matching command to check cache size, clear that cache, delete node_modules, or do a full nuke-and-reinstall."
    Items = @(
        @{
            Key    = '1'
            Label  = 'Clear NPM Cache'
            Script = 'Clear-NpmCache.ps1'
            Help   = "Clears the local package-manager cache for the project at -Path (defaults to the current directory). Auto-detects npm/yarn/pnpm/bun from lock files and runs the matching cache-clean command (npm cache clean --force / pnpm store prune / yarn cache clean --all / bun pm cache rm). -Verify additionally runs 'npm cache verify' afterward (npm only - other package managers have no equivalent). Use this when installs are behaving oddly and you want a clean package-manager cache without touching node_modules or any project files. Safety note: mutates the package manager's own (global, per-user) cache - runs immediately with no confirmation prompt and no -Force/-DryRun switch, unlike the other mutating tools in this category."
        }
        @{
            Key             = '2'
            Label           = 'Delete node_modules'
            Script          = 'Remove-NodeModules.ps1'
            RequiresProject = $true
            Help            = "Deletes node_modules from the selected project (RequiresProject - the menu prompts you to pick a linked project first; from the command line, use -Path). Reports the folder's approximate size (flagged as an estimate if some long paths couldn't be measured), then asks 'Delete node_modules? (y/n)' unless -Force is passed. Deletion uses the long-path-safe robocopy-mirror method. -Reinstall additionally reinstalls dependencies afterward via the auto-detected package manager. Use this for a plain clean reinstall without touching lock files or the package-manager cache. Safety note: mutates real project files (deletes node_modules) - gated by a y/n confirmation unless -Force."
        }
        @{
            Key             = '3'
            Label           = 'Delete node_modules + Lock + Reinstall'
            Script          = 'Nuke-And-Reinstall.ps1'
            RequiresProject = $true
            Help            = "The nuclear option for a broken project (RequiresProject - the menu prompts you to pick a linked project first; from the command line, use -Path): stops local node/bun processes running under the project path, clears .next/node_modules\.cache/node_modules\.vite/.turbo caches, deletes node_modules, deletes all known lock files (package-lock.json, yarn.lock, pnpm-lock.yaml, bun.lock/bun.lockb), clears the package manager's cache (skip with -SkipCacheClear), then reinstalls with the same package manager detected at the start. Use this when a project's dependencies are corrupted beyond what a plain node_modules delete fixes. Safety note: mutates real project files extensively (node_modules, all lock files, framework caches) - requires typing 'nuke' to confirm unless -Force is passed."
        }
        @{
            Key    = '4'
            Label  = 'Check NPM Cache Size'
            Script = 'Check-NpmCacheSize.ps1'
            Help   = "Read-only report of the package-manager cache location for the project at -Path (defaults to current directory), and its size where the package manager exposes one: npm via 'npm cache verify', pnpm/yarn/bun by measuring the reported cache/store folder directly (bun's cache path is a documented fixed per-user location, not queried from bun itself). Use this before deciding whether a cache clear is worth running. Makes no changes."
        }
        @{
            Key             = '5'
            Label           = 'Run Package Script (npm run picker)'
            Script          = 'Start-PackageScript.ps1'
            RequiresProject = $true
            Help            = "The daily-driver 'npm run' picker (RequiresProject - the menu prompts you to pick a linked project first; from the command line, use -Path): lists the scripts defined in the project's package.json in an arrow-key menu and runs the chosen one with the project's detected package manager via '<pm> run <name>' (works for npm/pnpm/yarn/bun). Pass -Name to skip the picker and run a script directly. Use this instead of typing npm run dev / npm test / npm run build by hand. Safety note: this runs the project's OWN package.json script verbatim - whatever command the project author put there - with no confirmation, since running scripts is the entire point of the tool; DevKit itself never installs, deletes, or modifies anything."
        }
        @{
            Key             = '6'
            Label           = 'Find Stale node_modules'
            Script          = 'Find-StaleNodeModules.ps1'
            RequiresProject = $true
            Help            = "Reclaims disk space across projects (RequiresProject - the menu prompts you to pick a linked folder first; from the command line, use -Path with e.g. your dev root): recursively finds node_modules folders up to -Depth levels deep (default 3, nested node_modules inside an already-found one are pruned), measures each (flagged as an estimate when long paths can't be read), and reports size plus last-write age, largest first, with a total-reclaimable line. Report-only by default - from this menu it ends by asking whether to delete the listed folders (the prompt is skipped on redirected input, keeping piped runs report-only; -Apply skips the prompt). Safety note: deletion is gated by the shared confirmation prompt listing every affected folder unless -Force is passed, and uses the same long-path-safe robocopy-mirror method as Delete node_modules."
        }
    )
}
