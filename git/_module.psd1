@{
    Name        = "Git Tools"
    Description = "Repository housekeeping and multi-repo visibility: prune merged branches and reclaim disk space in a single repo, scan git status across every repo under a directory tree, and sync a forked repo with its upstream remote via merge or rebase."
    Items       = @(
        @{
            Key             = '1'
            Label           = 'Git Cleanup (prune, gc, etc.)'
            Script          = 'Git-Cleanup.ps1'
            RequiresProject = $true
            Help            = "Fetches the remote, deletes local branches already merged into the repo's default branch, prunes stale remote-tracking refs, and can run 'git gc --aggressive --prune=now' and clear the reflog (-ClearReflog) to shrink repo size. Shows pack size before/after. Use this periodically on a repo with a lot of merged/stale branch history. Safety note: mutates real repository state - fetching and remote-tracking prune run automatically (skipped under -DryRun); deleting merged branches, running gc, and clearing the reflog each require a 'y/n' confirmation unless -Force is passed. -DryRun previews every step with zero changes made."
        }
        @{
            Key             = '2'
            Label           = 'Git Status All (scan repos)'
            Script          = 'Git-StatusAll.ps1'
            RequiresProject = $true
            Help            = "Recursively scans a directory tree (default depth 2, -Depth to override) for git repositories and prints a compact, color-coded status line per repo: branch, modified/untracked file counts, and ahead/behind vs. its upstream. A repo with no configured upstream is always shown, never treated as clean, since unpushed commits can't be counted without one. Use this for a bird's-eye view of every project under a folder. Read-only - makes no changes; -Fetch additionally runs 'git fetch' per repo first to refresh remote data. Clean repos are hidden by default (-ShowClean to include them)."
        }
        @{
            Key             = '3'
            Label           = 'Sync Fork with Upstream'
            Script          = 'Git-SyncFork.ps1'
            RequiresProject = $true
            Help            = "Fetches a named upstream remote (default 'upstream'), checks out the target branch (defaults to the current branch, falling back to 'main' or 'master'), merges or rebases (-Rebase) in the upstream changes, and pushes the result to origin - using --force-with-lease after a rebase. Refuses to run if there are uncommitted changes or a merge/rebase already in progress. Use this to keep a personal fork current with its upstream repository. Safety note: mutates real repository state and pushes to a real remote - prompts 'Sync <branch> with <upstream>/<branch>? (y/n)' before starting unless -Force is passed, but has no -DryRun/preview mode, so answering 'y' runs checkout, merge-or-rebase, and push immediately."
        }
        @{
            Key             = '4'
            Label           = 'Git Standup (Your Recent Commits)'
            Script          = 'Get-GitStandup.ps1'
            RequiresProject = $true
            Help            = "Collects YOUR recent commits (matched via 'git config user.email', falling back to user.name) across git repos - a quick 'what did I do recently?' for standups. Run from this menu it scans the selected project (the repo itself plus any nested repos, depth 2); run directly with the default -Path '.' it scans every linked project in the DevKit registry instead. Groups commits by repo as 'hash subject (relative time)' lines, newest first. Fully read-only - never fetches, never mutates; repos with no commits in the window are omitted, and an empty overall result says so honestly."
            Prompts         = @(
                @{ Name = 'Hours'; Type = 'Int'; Prompt = 'How many hours back? (blank = 24)'; Min = 1; Max = 720; Optional = $true; InvalidMessage = 'Invalid hours.' }
            )
        }
    )
}
