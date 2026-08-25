//! Resolves where the PowerShell sidecar lives, in both `tauri dev` (repo
//! checkout) and a bundled install (resources copied next to the exe - see
//! the `bundle.resources` map in `tauri.conf.json`).

use std::path::PathBuf;
use std::time::Duration;

use tauri::Manager;

pub struct ResolvedPaths {
    pub pwsh: PathBuf,
    pub rpc_script: PathBuf,
    pub sidecar_cwd: PathBuf,
}

pub fn resolve(app: &tauri::AppHandle) -> anyhow::Result<ResolvedPaths> {
    let pwsh = which_pwsh()?;

    let (rpc_script, sidecar_cwd) = if cfg!(debug_assertions) {
        // CARGO_MANIFEST_DIR is .../app/src-tauri at compile time.
        let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let repo_root = manifest_dir
            .parent()
            .and_then(|p| p.parent())
            .ok_or_else(|| anyhow::anyhow!("could not walk up from CARGO_MANIFEST_DIR to repo root"))?
            .to_path_buf();
        (repo_root.join("core").join("Invoke-DevKitRpc.ps1"), repo_root)
    } else {
        // resource_dir() canonicalizes on Windows, which returns a
        // `\\?\C:\...` verbatim path. pwsh will happily RUN a script from a
        // verbatim path, but $PSScriptRoot then inherits the prefix and
        // PowerShell's own providers reject it - Test-Path returns false
        // for files that exist (reproduced on pwsh 7.6.5), so
        // DevKit.Core.psm1's library-existence checks throw and every lane
        // dies at init. dunce::simplified strips the prefix whenever the
        // path is representable without it (always, for a normal install
        // path); dev builds never hit this since CARGO_MANIFEST_DIR is a
        // plain path.
        let resource_dir = dunce::simplified(&app.path().resource_dir()?).to_path_buf();
        (
            resource_dir.join("core").join("Invoke-DevKitRpc.ps1"),
            resource_dir,
        )
    };

    if !rpc_script.exists() {
        anyhow::bail!(
            "sidecar entry point not found at {}",
            rpc_script.display()
        );
    }

    Ok(ResolvedPaths {
        pwsh,
        rpc_script,
        sidecar_cwd,
    })
}

fn which_pwsh() -> anyhow::Result<PathBuf> {
    if let Ok(path) = which::which("pwsh") {
        return Ok(path);
    }
    if let Ok(path) = which::which("powershell") {
        return Ok(path);
    }
    anyhow::bail!("neither pwsh.exe (PowerShell 7+) nor powershell.exe was found on PATH")
}

impl ResolvedPaths {
    pub fn to_sidecar_spec(&self) -> devkit_host::SidecarSpec {
        devkit_host::SidecarSpec {
            program: self.pwsh.clone(),
            script: self.rpc_script.clone(),
            cwd: self.sidecar_cwd.clone(),
            // The sidecar's "alive" flag flips true as soon as pwsh.exe
            // spawns, not once DevKit.Core.psm1 (which dot-sources ~7
            // files, some multiple thousand lines) has actually finished
            // importing in its lane runspace - a request sent in that
            // window just queues until the lane starts consuming. On a
            // freshly-installed exe that cold-import can be materially
            // slower than on a dev machine that's already run it dozens of
            // times (AV real-time scanning of newly-written files, no OS
            // page-cache warmth, etc.) - 60s gives that real headroom
            // instead of hard-failing every panel on first launch.
            default_timeout: Duration::from_secs(60),
        }
    }
}
