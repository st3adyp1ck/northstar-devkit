@{
    Name        = "Next.js Tools"
    Description = "Cache-clearing and reset tools for Next.js projects: clear the .next build cache or Turbopack-related caches, start the dev server fresh, or do a full clean (node_modules + lock file + cache wipe, then reinstall). All four scripts auto-detect the project's package manager (npm/yarn/pnpm/bun) from its lock file."
    Items       = @(
        @{
            Key             = '1'
            Label           = 'Clear .next Build Cache'
            Script          = 'Clear-NextCache.ps1'
            RequiresProject = $true
            Help            = "Deletes the project's .next build cache folder. If .next doesn't exist, reports that and exits without doing anything. Use this for a quick, narrow cache clear when something looks stale but you don't want to touch Turbopack or node_modules caches. Safety note: mutates the project directory (deletes .next) - prompts for y/n confirmation unless -Force is passed."
        }
        @{
            Key             = '2'
            Label           = 'Clear Turbopack Cache'
            Script          = 'Clear-TurboCache.ps1'
            RequiresProject = $true
            Help            = "Deletes Turbopack-related caches: .next, node_modules/.cache, node_modules/.vite, and .turbo (note this also removes the entire .next folder, not just an isolated Turbopack subfolder - it's effectively a superset of 'Clear .next Build Cache'). Reports 'no caches found' and exits if none of those paths exist. Use this when Turbopack itself seems to be serving stale output. Safety note: mutates the project directory - prompts for y/n confirmation unless -Force is passed."
        }
        @{
            Key             = '3'
            Label           = 'Full Clean (.next + node_modules + reinstall)'
            Script          = 'Next-FullClean.ps1'
            RequiresProject = $true
            Help            = "The most destructive option in this category: stops locally running node/bun processes for the project, clears all Next.js/Turbopack caches and build output (.next, .turbo, node_modules/.cache, node_modules/.vite, dist, .vite), deletes node_modules and all lock files (package-lock.json, yarn.lock, pnpm-lock.yaml, bun.lockb), clears the package manager's own cache, and reinstalls. Use this when a project is genuinely broken and a narrower cache clear hasn't fixed it. Safety note: mutates the project directory extensively - shows a summary of what will be deleted and requires y/n confirmation unless -Force is passed; pass -StartDev to also launch the dev server once cleaning finishes."
        }
        @{
            Key             = '4'
            Label           = 'Dev Server (Fresh Start)'
            Script          = 'Next-DevFresh.ps1'
            RequiresProject = $true
            Help            = "Clears the .next cache (and, if you answer yes to the Turbopack prompt, the Turbopack-related caches too), then starts the dev server via the auto-detected package manager with Next.js telemetry disabled. Optionally set a port to run on. Use this when you want a guaranteed-clean dev server start in one step. Safety note: deletes cache folders with no confirmation prompt (unlike the standalone cache-clear tools above), then starts a long-running dev server process that keeps running until you stop it (Ctrl+C) - it will not return to the menu on its own."
            Prompts         = @(
                @{ Name = 'Turbo'; Type = 'YesNo'; Prompt = 'Clear Turbopack cache too?'; Optional = $true }
                @{ Name = 'Port'; Type = 'Int'; Prompt = 'Port (press Enter for default)'; Optional = $true; Min = 1; Max = 65535 }
            )
        }
    )
}
