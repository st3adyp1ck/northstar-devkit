use std::path::PathBuf;
use std::time::Duration;

use devkit_host::SidecarSpec;

/// Standalone equivalent of `app/src-tauri/src/paths.rs` for the CLI binary
/// (no `tauri::AppHandle`/resource_dir available here). Walks up from the
/// exe's own directory to find a `core/Invoke-DevKitRpc.ps1` sibling, which
/// works both for `cargo run` (target/debug next to the workspace) and an
/// installed/portable layout where `devkit.exe` sits at the repo root next
/// to `core/` and `tools/`.
pub fn resolve() -> anyhow::Result<SidecarSpec> {
    let pwsh = which_pwsh()?;
    let cwd = find_repo_root()?;
    let script = cwd.join("core").join("Invoke-DevKitRpc.ps1");
    if !script.exists() {
        anyhow::bail!("sidecar entry point not found at {}", script.display());
    }
    Ok(SidecarSpec {
        program: pwsh,
        script,
        cwd,
        // See app/src-tauri/src/paths.rs's to_sidecar_spec() for why 60s,
        // not 30s: the sidecar's cold DevKit.Core.psm1 import can be slower
        // than a per-call timeout tuned around an already-warm process.
        default_timeout: Duration::from_secs(60),
    })
}

fn which_pwsh() -> anyhow::Result<PathBuf> {
    if let Ok(path) = which::which("pwsh") {
        return Ok(path);
    }
    if let Ok(path) = which::which("powershell") {
        tracing::warn!("pwsh 7 not found; falling back to Windows PowerShell 5.1");
        return Ok(path);
    }
    anyhow::bail!("neither pwsh.exe (PowerShell 7+) nor powershell.exe was found on PATH")
}

fn find_repo_root() -> anyhow::Result<PathBuf> {
    if cfg!(debug_assertions) {
        let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        if let Some(root) = manifest_dir.parent() {
            if root.join("core").is_dir() {
                return Ok(root.to_path_buf());
            }
        }
    }

    // Resolve symlinks before walking up: a devkit.exe reached via a
    // symlink would otherwise walk the symlink's tree, not the install's.
    // dunce (not fs::canonicalize) so we don't trade that bug for a `\\?\`
    // verbatim-path one; fall back to the raw path if canonicalize errors.
    let exe = std::env::current_exe()?;
    let exe = dunce::canonicalize(&exe).unwrap_or(exe);
    let mut dir = exe.parent().map(|p| p.to_path_buf());
    while let Some(candidate) = dir {
        if candidate.join("core").is_dir() && candidate.join("tools").is_dir() {
            return Ok(candidate);
        }
        dir = candidate.parent().map(|p| p.to_path_buf());
    }

    anyhow::bail!("could not locate a 'core/' + 'tools/' directory near the devkit executable")
}
