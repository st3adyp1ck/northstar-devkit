//! Startup elevation gate - DevKit is an admin-only application.
//!
//! Release builds refuse to run with a filtered (non-Administrator) token.
//! The gate runs at the very top of `run()`, BEFORE the Tauri builder and its
//! plugins exist, which matters for two reasons:
//!
//! - `tauri-plugin-single-instance` only ever sees elevated processes: a
//!   non-elevated launch redirects through the elevation task and exits
//!   before registering as an instance, so the tray/Control Center never
//!   mix tokens and second launches surface the running (elevated) window
//!   exactly as before.
//! - The redirect is invisible to the rest of the app: everything after
//!   this gate can assume the Administrator token, which is what makes the
//!   "no other mode" promise true for the sidecar, `tool.run` children, and
//!   the embedded terminal.
//!
//! The elevation mechanism itself is the existing
//! `tools/system/Set-DevKitAdminMode.ps1` scheduled-task machinery (a
//! `NorthstarDevKit-Admin` task with RunLevel Highest), not anything new:
//!
//! - Already elevated -> start normally.
//! - Not elevated, task present -> `schtasks /run /tn <task>`, exit. The
//!   task relaunches this exe with its full token, silently - the same
//!   command the 'DevKit (Admin)' VBS launcher uses. Presence is judged by
//!   `schtasks /query` (whose exit code is reliable); `/run`'s exit code
//!   is NOT - it reports success even for a task that does not exist.
//! - Not elevated, task missing -> native consent MessageBox, then the
//!   setup script (`-Force`, `-ExePath <self>`) whose built-in
//!   self-elevation is the ONE UAC prompt a user ever sees; then `schtasks
//!   /run` and exit. The script is re-run-safe: its logon-trigger
//!   preservation keeps Start-with-Windows intact on a re-register.
//!
//! Because the gate fronts every entry point, each one self-corrects: NSIS
//! shortcuts point at the raw exe, Start-with-Windows still writes the HKCU
//! Run key (Windows refuses to auto-start elevated apps from it, so the
//! non-elevated launch redirects through the task at logon), and the
//! updater's post-install relaunch inherits its elevated parent.
//!
//! Two deliberate escapes from "no other mode": debug builds
//! (`cfg!(debug_assertions)`) skip the gate entirely so `pnpm tauri dev`
//! and debug runs stay prompt-free, and `DEVKIT_ALLOW_UNELEVATED=1` exists
//! as an undocumented support hatch.
//!
//! Known trade-offs (documented in README/CHANGELOG): an always-elevated
//! window cannot accept drag-and-drop from non-elevated Explorer (UIPI), and
//! everything spawned while elevated - all tools, the sidecar, the terminal
//! - runs as Administrator, permanently.

use std::path::PathBuf;
use std::process::Command;

use anyhow::Context as _;
use windows_sys::Win32::Foundation::CloseHandle;
use windows_sys::Win32::Security::{
    GetTokenInformation, TokenElevation, TOKEN_ELEVATION, TOKEN_QUERY,
};
use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    MessageBoxW, IDOK, MB_ICONERROR, MB_ICONINFORMATION, MB_OK, MB_OKCANCEL,
};

/// The scheduled task `Set-DevKitAdminMode.ps1` registers and this gate starts.
const TASK_NAME: &str = "NorthstarDevKit-Admin";

/// Support/debug escape hatch: set to any value to run un-elevated.
const SKIP_ENV: &str = "DEVKIT_ALLOW_UNELEVATED";

/// What the gate should do with this process. `StartTask`/`SetupThenStart`
/// both end in `process::exit`; only `Proceed` returns to the caller.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum GateAction {
    /// Running with the Administrator token - start normally.
    Proceed,
    /// The elevation task exists - start it and exit; it relaunches us elevated.
    StartTask,
    /// No elevation task - run the one-time setup, then start it.
    SetupThenStart,
}

/// The whole gate as a pure table, so the branching is unit-testable without
/// elevation or a real task. `task_present` is the result of
/// `schtasks /query` (see its caveats there).
fn decide_action(elevated: bool, task_present: bool) -> GateAction {
    if elevated {
        GateAction::Proceed
    } else if task_present {
        GateAction::StartTask
    } else {
        GateAction::SetupThenStart
    }
}

/// True when this process carries the Administrator token. Any API failure
/// answers false - the gate treats "cannot tell" as "not elevated" and
/// redirects, never silently proceeds.
pub fn is_elevated() -> bool {
    unsafe {
        let mut token = std::ptr::null_mut();
        if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) == 0 {
            return false;
        }
        let mut elevation: TOKEN_ELEVATION = std::mem::zeroed();
        let mut size = 0u32;
        let ok = GetTokenInformation(
            token,
            TokenElevation,
            &mut elevation as *mut _ as *mut _,
            std::mem::size_of::<TOKEN_ELEVATION>() as u32,
            &mut size,
        );
        CloseHandle(token);
        ok != 0 && elevation.TokenIsElevated != 0
    }
}

/// Entry point from `run()`. Returns only when the app may start; otherwise
/// exits the process (after redirecting elevation through the task).
pub fn enforce_or_redirect() {
    // Debug builds stay prompt-free for the dev loop; the env var is the
    // support hatch. Both are deliberately undocumented in the UI.
    if cfg!(debug_assertions) || std::env::var_os(SKIP_ENV).is_some() {
        return;
    }

    if is_elevated() {
        tracing::debug!("elevation gate: already elevated, proceeding");
        return;
    }
    tracing::info!("elevation gate: not elevated, redirecting through the elevation task");

    // A task that exists but elevates a DIFFERENT exe than this one (stale
    // copy, moved install, repo build tested before the installed one) must
    // not be trusted: re-registering for the current exe is the setup path.
    let task_usable = task_present() && !task_points_elsewhere();
    match decide_action(false, task_usable) {
        GateAction::Proceed => {}
        GateAction::StartTask => {
            run_elevation_task();
            std::process::exit(0);
        }
        GateAction::SetupThenStart => setup_then_start_or_exit(),
    }
}

/// Does the state marker's recorded exe path differ from this process's exe?
/// False when the marker is missing/unreadable or the paths match - this is a
/// staleness check, not an authenticity one.
fn task_points_elsewhere() -> bool {
    let Some(local) = std::env::var_os("LOCALAPPDATA") else {
        return false;
    };
    let marker = std::path::Path::new(&local)
        .join("NorthstarDevKit")
        .join("admin-mode.json");
    let Ok(text) = std::fs::read_to_string(&marker) else {
        return false;
    };
    let Some(recorded) = exe_path_from_marker(&text) else {
        return false;
    };
    let Ok(current) = std::env::current_exe() else {
        return false;
    };
    let recorded = dunce::simplified(std::path::Path::new(&recorded));
    let current = dunce::simplified(&current);
    !recorded
        .as_os_str()
        .eq_ignore_ascii_case(current.as_os_str())
}

/// The exePath string from the marker JSON, when present and a string.
fn exe_path_from_marker(text: &str) -> Option<String> {
    let json: serde_json::Value = serde_json::from_str(text).ok()?;
    json.get("exePath")?.as_str().map(str::to_owned)
}

/// Does the elevation task exist? `schtasks /query`'s exit code IS reliable
/// (it is 1 with empty stdout for a missing task), but the task-name check
/// on the CSV output is belt-and-braces - this value drives whether the user
/// gets a first-run consent dialog, so a false positive would be a silent
/// no-start.
fn task_present() -> bool {
    match Command::new("schtasks")
        .args(["/query", "/tn", TASK_NAME, "/fo", "csv"])
        .output()
    {
        Ok(out) => {
            out.status.success()
                && String::from_utf8_lossy(&out.stdout)
                    .to_ascii_lowercase()
                    .contains(&TASK_NAME.to_ascii_lowercase())
        }
        Err(e) => {
            tracing::warn!(error = %e, "elevation gate: could not query scheduled tasks");
            false
        }
    }
}

/// `schtasks /run` on the elevation task, best-effort: `/run`'s exit code
/// cannot distinguish "started" from "refused", and both are acceptable
/// here - a refused start under the task's default IgnoreNew policy means an
/// instance is already running, which is the outcome this gate wants.
fn run_elevation_task() {
    match Command::new("schtasks").args(["/run", "/tn", TASK_NAME]).status() {
        Ok(status) if status.success() => {
            tracing::info!("elevation gate: started the elevation task");
        }
        Ok(status) => {
            tracing::warn!(
                code = %status,
                "elevation gate: task start returned failure (task missing or already running)"
            );
        }
        Err(e) => {
            tracing::warn!(error = %e, "elevation gate: could not spawn schtasks");
        }
    }
}

/// The task does not exist yet. Before asking to set it up, rule out the
/// benign case: an instance is already running (e.g. a dev build launched
/// with the skip env var) - then there is nothing to set up, exit quietly
/// and let the running instance be the app.
fn setup_then_start_or_exit() -> ! {
    if app_process_already_running() {
        tracing::info!("elevation gate: no task but an instance is already running; exiting");
        std::process::exit(0);
    }

    if message_box(
        "DevKit runs only with administrator privileges, so its tools, terminal, \
         and system features always have full access.\n\n\
         Click OK to set this up once. Windows will ask for your permission (UAC) \
         a single time - after that, DevKit starts elevated automatically with no \
         more prompts.",
        "DevKit - Administrator Required",
        MB_ICONINFORMATION | MB_OKCANCEL,
    ) != IDOK
    {
        tracing::info!("elevation gate: setup consent declined; exiting without starting");
        std::process::exit(1);
    }

    match run_setup() {
        Ok(true) if task_present() => {
            run_elevation_task();
            tracing::info!("elevation gate: setup done, elevation task started; exiting");
            std::process::exit(0);
        }
        Ok(true) => {
            tracing::error!("elevation gate: setup succeeded but the task is not registered");
            show_setup_failure_and_exit();
        }
        Ok(false) => {
            // Exit code 1 from the setup script is its "elevation was
            // declined or could not start" path - usually a cancelled or
            // timed-out UAC consent, which deserves its own explanation
            // (and a nudge to just run DevKit again) rather than the
            // generic setup-failure text.
            tracing::info!("elevation gate: setup consent was declined or timed out");
            message_box(
                "The administrator permission request was cancelled or timed out, \
                 so DevKit could not finish its one-time setup and cannot start.\n\n\
                 Run DevKit again and approve the Windows permission prompt when \
                 it appears.",
                "DevKit - Permission Needed",
                MB_ICONINFORMATION | MB_OK,
            );
            std::process::exit(1);
        }
        Err(e) => {
            tracing::error!(error = %e, "elevation gate: setup failed");
            show_setup_failure_and_exit();
        }
    }
}

fn show_setup_failure_and_exit() -> ! {
    message_box(
        "DevKit could not set up its administrator launch, so it cannot start.\n\n\
         Try again, or reinstall DevKit. (An elevated terminal can also run \
         tools\\system\\Set-DevKitAdminMode.ps1 directly.)",
        "DevKit - Setup Failed",
        MB_ICONERROR | MB_OK,
    );
    std::process::exit(1);
}

/// Runs the one-time setup ELEVATED, via `ShellExecuteExW` with the `runas`
/// verb - the canonical installer self-elevation mechanism. Asking for
/// elevation HERE, from the gate process the user just clicked OK in,
/// instead of letting the script self-elevate via its own internal
/// `Start-Process -Verb RunAs`, matters in practice: the consent prompt is
/// then requested by a process with fresh user interaction, so the secure
/// desktop appears immediately and reliably. The nested-ShellExecute
/// variant wedged repeatedly in real testing - the consent either rendered
/// unreliably or left a suspended child behind.
///
/// The elevated script gets a VISIBLE console (SW_SHOW): its Write-Host
/// progress is the setup UI, like a traditional installer's status window,
/// and it makes failures diagnosable. `Ok(true)` = script exited 0;
/// `Ok(false)` = the user declined/cancelled UAC (ERROR_CANCELLED);
/// `Err` = anything else.
fn run_setup() -> anyhow::Result<bool> {
    let (script, exe) = setup_script_and_exe()?;
    let pwsh = crate::paths::which_pwsh()?;
    let parameters = format!(
        "-NoLogo -NoProfile -ExecutionPolicy Bypass -File \"{}\" -Force -ExePath \"{}\"",
        script.display(),
        exe.display()
    );
    tracing::info!(script = %script.display(), exe = %exe.display(), "elevation gate: running Admin Mode setup elevated");

    use windows_sys::Win32::Foundation::GetLastError;
    use windows_sys::Win32::System::Threading::{GetExitCodeProcess, WaitForSingleObject};
    use windows_sys::Win32::UI::Shell::{
        ShellExecuteExW, SHELLEXECUTEINFOW, SEE_MASK_FLAG_NO_UI, SEE_MASK_NOCLOSEPROCESS,
    };
    use windows_sys::Win32::UI::WindowsAndMessaging::SW_SHOW;

    const ERROR_CANCELLED: u32 = 1223;
    const INFINITE: u32 = 0xFFFF_FFFF;

    let verb = wide("runas");
    let file = wide(&pwsh.to_string_lossy());
    let params = wide(&parameters);

    let mut info: SHELLEXECUTEINFOW = unsafe { std::mem::zeroed() };
    info.cbSize = std::mem::size_of::<SHELLEXECUTEINFOW>() as u32;
    info.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_FLAG_NO_UI;
    info.lpVerb = verb.as_ptr();
    info.lpFile = file.as_ptr();
    info.lpParameters = params.as_ptr();
    info.nShow = SW_SHOW;

    // SEE_MASK_FLAG_NO_UI: no system error dialog on failure - we surface
    // our own MessageBox instead, with context and a retry hint.
    if unsafe { ShellExecuteExW(&mut info) } == 0 {
        let err = unsafe { GetLastError() };
        if err == ERROR_CANCELLED {
            return Ok(false);
        }
        anyhow::bail!("could not start the elevated setup (Windows error {err})");
    }
    if info.hProcess.is_null() {
        anyhow::bail!("ShellExecuteEx did not return a process handle for the setup");
    }

    unsafe {
        WaitForSingleObject(info.hProcess, INFINITE);
        let mut code = 0u32;
        GetExitCodeProcess(info.hProcess, &mut code);
        CloseHandle(info.hProcess);
        Ok(code == 0)
    }
}

/// Where the setup script lives, paired with this exe as the task target.
/// A repo `target\release` build prefers the checkout two levels up (a prior
/// `tauri build` may have left STAGED resource copies next to the exe - fine
/// today, but the checkout is the source of truth when there is one); a
/// bundled install finds its copy next to the exe, the same layout
/// `paths.rs` relies on for the sidecar.
fn setup_script_and_exe() -> anyhow::Result<(PathBuf, PathBuf)> {
    let exe = std::env::current_exe().context("could not resolve own exe path")?;
    let exe_dir = exe
        .parent()
        .ok_or_else(|| anyhow::anyhow!("own exe path has no parent directory"))?;

    let mut roots = Vec::new();
    if let Some(repo_root) = exe_dir.parent().and_then(|p| p.parent()) {
        roots.push(repo_root.to_path_buf());
    }
    roots.push(exe_dir.to_path_buf());
    for root in &roots {
        let script = root.join("tools").join("system").join("Set-DevKitAdminMode.ps1");
        if script.exists() {
            return Ok((script, exe));
        }
    }
    anyhow::bail!(
        "Set-DevKitAdminMode.ps1 not found next to {} or in the repo checkout",
        exe.display()
    )
}

/// Cheap "is another instance already running" probe via `tasklist` in CSV
/// mode (image-name enumeration is allowed from a filtered token even for
/// elevated processes). tasklist also lists THIS process, so the own-PID
/// row must be excluded - without that, the probe is trivially always true
/// and the setup path never runs.
fn app_process_already_running() -> bool {
    let own_pid = std::process::id().to_string();
    match Command::new("tasklist").args(["/fo", "csv"]).output() {
        Ok(out) => String::from_utf8_lossy(&out.stdout)
            .lines()
            .any(|line| tasklist_row_is_other_instance(line, &own_pid)),
        Err(e) => {
            tracing::warn!(error = %e, "elevation gate: could not spawn tasklist");
            false
        }
    }
}

/// One tasklist CSV row names another devkit-app.exe instance: matches the
/// image name and has a PID that is not ours. The PID is the second quoted
/// field (`"devkit-app.exe","1234",...`); memory sizes may contain commas,
/// which is why the field is indexed rather than the line split loosely.
fn tasklist_row_is_other_instance(line: &str, own_pid: &str) -> bool {
    if !line.to_ascii_lowercase().contains("devkit-app.exe") {
        return false;
    }
    line.split(',').nth(1).map(|f| f.trim_matches('"')) != Some(own_pid)
}

/// Wide-char, NUL-terminated copy of a Rust string (MessageBoxW and
/// ShellExecuteExW both take PCWSTR; `windows_sys::w!` only accepts literals).
fn wide(s: &str) -> Vec<u16> {
    use std::ffi::OsStr;
    use std::os::windows::ffi::OsStrExt;

    OsStr::new(s)
        .encode_wide()
        .chain(std::iter::once(0))
        .collect()
}

/// Blocking native MessageBox.
fn message_box(text: &str, caption: &str, style: u32) -> i32 {
    let text = wide(text);
    let caption = wide(caption);
    unsafe { MessageBoxW(std::ptr::null_mut(), text.as_ptr(), caption.as_ptr(), style) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decide_action_elevated_proceeds_regardless_of_task() {
        assert_eq!(decide_action(true, true), GateAction::Proceed);
        assert_eq!(decide_action(true, false), GateAction::Proceed);
    }

    #[test]
    fn decide_action_not_elevated_task_present_redirects() {
        assert_eq!(decide_action(false, true), GateAction::StartTask);
    }

    #[test]
    fn decide_action_not_elevated_task_absent_needs_setup() {
        assert_eq!(decide_action(false, false), GateAction::SetupThenStart);
    }

    #[test]
    fn tasklist_probe_excludes_own_row() {
        let own = "4242";
        let row = "\"devkit-app.exe\",\"4242\",\"Console\",\"1\",\"57,632 K\"";
        assert!(!tasklist_row_is_other_instance(row, own));
    }

    #[test]
    fn tasklist_probe_finds_other_instance_despite_comma_memory() {
        let own = "4242";
        let row = "\"devkit-app.exe\",\"4060\",\"Console\",\"1\",\"57,632 K\"";
        assert!(tasklist_row_is_other_instance(row, own));
    }

    #[test]
    fn tasklist_probe_ignores_other_images() {
        let own = "4242";
        let row = "\"devkit.exe\",\"4060\",\"Console\",\"1\",\"12,000 K\"";
        assert!(!tasklist_row_is_other_instance(row, own));
    }

    #[test]
    fn marker_exe_path_reads_and_ignores_garbage() {
        let marker = r#"{ "exePath": "C:\\DevKit\\devkit-app.exe", "taskName": "NorthstarDevKit-Admin" }"#;
        assert_eq!(
            exe_path_from_marker(marker).as_deref(),
            Some("C:\\DevKit\\devkit-app.exe")
        );
        assert_eq!(exe_path_from_marker("not json"), None);
        assert_eq!(exe_path_from_marker("{ \"taskName\": \"x\" }"), None);
    }
}
