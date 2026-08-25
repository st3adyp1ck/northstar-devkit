@{
    Name        = "Docker Tools"
    Description = "Clean up Docker resources (containers, images, volumes, networks, build cache) - either a full teardown or a selective/unused-only pass - and tail logs from one or more running containers at once. All three tools require Docker Desktop or the Docker Engine CLI installed with the daemon running."
    Items       = @(
        @{
            Key    = '1'
            Label  = 'Docker Nuke (remove all)'
            Script = 'Docker-Nuke.ps1'
            Help   = "Stops and force-removes ALL containers, then removes all images (unless -KeepImages) and all volumes (unless -KeepVolumes), prunes custom networks and the build cache, and finishes with a final 'docker system prune' (adding --volumes unless -KeepVolumes). Use this when you want a completely clean Docker state and don't need anything currently on the machine. Safety note: mutates real Docker state - shows a per-resource-type count before acting, requires typing 'NUKE' (case-sensitive) via the shared Confirm-DevKitDestructiveAction gate unless -Force is passed, and supports -DryRun to list what would be removed with no changes made."
        }
        @{
            Key    = '2'
            Label  = 'Docker Cleanup (selective)'
            Script = 'Docker-Cleanup.ps1'
            Help   = "Selective, less destructive than Docker Nuke - removes stopped containers and dangling images by default; -AllUnused widens image removal to every unused (not just untagged) image and also prunes unused custom networks; -Volumes additionally prunes unused volumes. Also cleans the build cache and reports estimated reclaimable disk space. Use this for routine disk-space cleanup that leaves in-use resources alone. Safety note: mutates real Docker state - prompts with a plain y/n confirmation unless -Force is passed (this script predates the shared Confirm-DevKitDestructiveAction gate that Docker Nuke uses, so it does not honor the confirmDestructive setting); supports -DryRun to preview affected containers/images with no changes made."
        }
        @{
            Key    = '3'
            Label  = 'Quick Logs (multi-container)'
            Script = 'Docker-QuickLogs.ps1'
            Help   = "Tails 'docker logs' for one or more containers at once (all running containers by default, or specific names via -Container), with a distinct color prefix per container, an initial line count (-Lines, default 50), optional -Timestamps, and optional -Follow to keep streaming instead of printing the last N lines and exiting. Use this to watch several services' logs together during local development. Safety note: read-only against Docker (no containers/images/volumes are touched), but with -Follow it blocks the terminal indefinitely - press Ctrl+C to stop, and never invoke -Follow from an unattended/non-interactive context."
        }
    )
}
