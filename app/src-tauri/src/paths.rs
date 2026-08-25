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
        let resource_dir = app.path().resource_dir()?;
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
            default_timeout: Duration::from_secs(30),
        }
    }
}
