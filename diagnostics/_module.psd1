@{
    Name        = "Diagnostics"
    Description = "Read-only checks and reports on your local development environment - tool/version health checks, a system info snapshot, and a DevKit release-update check. Nothing in this category mutates real system state (System Dev Info can optionally write a JSON export file to the current directory if you pass -Export)."
    Items       = @(
        @{
            Key    = '1'
            Label  = 'DevKit Doctor (health check)'
            Script = 'DevKit-Doctor.ps1'
            Help   = "Checks installed dev-tool versions (Node, NPM, Yarn/PNPM/Bun, Git, Docker, VS Code, Cursor, GitHub CLI, Python, WSL), Git user.name/user.email config, Windows version, administrator rights, execution policy, disk space, and RAM, and flags anything missing, outdated, or misconfigured. Supports -Quiet to only show failed/warning checks (passing checks are hidden). Use this first when your setup 'feels broken' or before onboarding a new machine. Read-only - makes no changes, though it exits with code 1 when real issues (not just warnings) are found, which is useful when scripted."
        }
        @{
            Key    = '2'
            Label  = 'System Dev Info'
            Script = 'System-DevInfo.ps1'
            Help   = "Prints a snapshot of installed tool versions (PowerShell, Node, NPM, Git, Docker, Python, VS Code), local IP/gateway, common dev ports currently in use, per-drive disk space, RAM, PATH entry count, execution policy, and admin status. -Export writes it to a timestamped JSON file in the current directory - the export includes username, computer name, and local IP/gateway, so review it before sharing, or pass -Redact alongside -Export to replace those fields with a non-reversible hash. -Clipboard copies a short text summary instead. Use this to grab a quick environment snapshot to share or compare across machines. Read-only aside from the optional -Export file write."
        }
        @{
            Key    = '3'
            Label  = 'Check for Updates'
            Script = 'Test-DevKitUpdate.ps1'
            Help   = "Compares your installed DevKit version (the repo's VERSION file) against the latest GitHub Release tag via a single read-only HTTPS GET to the GitHub Releases API. Rate-limited to once per 24 hours (and gated by settings.json's preferences.updateCheckEnabled) unless -Force is passed. Use this to check whether a newer DevKit release is available. Read-only network call - by design the only one in DevKit that isn't about networking itself; the only local write is updating its own last-checked timestamp in settings.json."
        }
    )
}
