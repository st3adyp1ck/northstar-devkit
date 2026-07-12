@{
    Name        = "Workflow Tools"
    Description = "Everyday shortcuts scoped to a linked project: open it in VS Code or Cursor, open its Git remote (GitHub, GitLab, Bitbucket, Azure DevOps) in a browser, or copy a detected .env template into it. Each tool prompts you to pick a project first and runs with its default (non-interactive, non-dry-run) flags from this menu; less common options - recent-projects picker, Cursor preference, a specific remote/branch/PR/issues/actions page, interactive value prompts, dry run - are only available via direct command-line invocation."
    Items       = @(
        @{
            Key             = '1'
            Label           = 'Code Here (open VS Code/Cursor)'
            Script          = 'Code-Here.ps1'
            RequiresProject = $true
            Help            = "Opens the selected project folder in VS Code (preferred) or Cursor, whichever is detected - checks PATH, then (for Cursor, which doesn't always add itself to PATH) common per-user install folders and the Windows App Paths registry key. Use this to jump straight into an editor for a linked project instead of opening it by hand. Supports -Recent (browse a picker of recently-opened folders instead of the project path), -Cursor (prefer Cursor, falling back to VS Code with a warning if Cursor isn't found), and -Wait (block until the editor window closes) when run directly from the command line - this menu item always opens the project path with none of those switches set. Not destructive: launches a real external application, never modifies files."
        }
        @{
            Key             = '2'
            Label           = 'Open Repo in Browser'
            Script          = 'Open-Repo.ps1'
            RequiresProject = $true
            Help            = "Opens the selected project's Git remote in your default browser. Resolves the 'origin' remote, converts SSH/ssh:// remote URLs to a browsable https:// URL (GitHub, GitLab, Bitbucket, Azure DevOps, and self-hosted equivalents), and links to the current branch when the platform is recognized; refuses to open anything that isn't a well-formed http(s) URL rather than risk launching a malformed or malicious remote. Use this to jump to a repo's web page without hand-converting the remote URL. Supports -Remote, -Branch, -PullRequest, -Issues, and -Actions when run directly from the command line to open a different remote/branch or jump straight to the PR/issues/actions page - this menu item always opens the repo root at the current branch on 'origin'. Not destructive: launches a browser tab, never modifies files."
        }
        @{
            Key             = '3'
            Label           = 'Copy .env Template'
            Script          = 'Copy-EnvTemplate.ps1'
            RequiresProject = $true
            Help            = "Copies a detected .env template (.env.example, .env.template, .env.sample, .env.local.example, .env.development.example, .env.production.example, or env.example, checked in that order, or a specific file via -Template) to .env in the selected project, using each variable's template default value as-is. Use this to bootstrap local environment config for a project you just cloned or linked. Safety note: writes a real file into the project - if .env already exists it asks a plain y/n before overwriting (skipped, i.e. always overwrites, when -Force is passed; this is a script-local y/n prompt, not the shared Confirm-DevKitDestructiveAction gate, so it is not affected by the confirmDestructive setting). Supports -Interactive (prompt for each variable's value instead of taking the template default) and -DryRun (preview the .env content with no file written) when run directly from the command line - this menu item always writes non-interactively. Reminds you to keep .env out of Git when the source template was .env.example or .env.template."
        }
    )
}
