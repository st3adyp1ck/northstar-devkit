//! Embedded ConPTY terminal sessions.
//!
//! This is a separate capability from the RPC sidecar (`devkit-host` /
//! `commands::rpc_call`): a session here is a plain interactive `pwsh.exe`
//! process running inside a real pseudo-console, wired directly to an
//! xterm.js instance in the frontend (see
//! `src/components/TerminalView.tsx`). It replaces the old WPF widget's
//! "launch an external Windows Terminal window" flyout with a real PTY
//! living inside the app.
//!
//! Output is forwarded to the frontend as UTF-8 (lossy) string chunks on
//! the `devkit://terminal` event, `{ sessionId, data }` - raw string
//! rather than base64 because xterm.js consumes text/ANSI directly and
//! this avoids a decode step in the hot path; `from_utf8_lossy` handles a
//! chunk boundary landing mid multi-byte character by substituting U+FFFD
//! for the split bytes rather than panicking or blocking for more data.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::Mutex;

use portable_pty::{native_pty_system, Child, CommandBuilder, MasterPty, PtySize};
use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, State};
use uuid::Uuid;

struct TerminalSession {
    master: Box<dyn MasterPty + Send>,
    writer: Box<dyn Write + Send>,
    child: Box<dyn Child + Send + Sync>,
}

/// Tauri-managed registry of live terminal sessions, keyed by session id.
/// `TerminalSession`'s fields are all `Send`, so the session type is
/// `Send`, which is what makes `Mutex<HashMap<..>>` itself `Send + Sync`
/// and therefore valid as Tauri-managed state.
#[derive(Default)]
pub struct TerminalRegistry(Mutex<HashMap<String, TerminalSession>>);

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct TerminalChunk {
    session_id: String,
    data: String,
}

/// Locates a PowerShell executable the same way `paths::which_pwsh` does
/// (pwsh.exe preferred, powershell.exe fallback). Duplicated locally
/// rather than shared: this module is intentionally decoupled from the
/// RPC sidecar's path resolution (different process, different lifetime).
fn locate_shell() -> Result<std::path::PathBuf, String> {
    which::which("pwsh")
        .or_else(|_| which::which("powershell"))
        .map_err(|_| "neither pwsh.exe nor powershell.exe was found on PATH".to_string())
}

/// Spawns a new interactive `pwsh` session inside a pseudo-console.
/// Returns the new session's id; a background thread is started that
/// reads PTY output for the lifetime of the session and emits it as
/// `devkit://terminal` events.
#[tauri::command]
pub async fn terminal_spawn(
    app: AppHandle,
    registry: State<'_, TerminalRegistry>,
    cwd: Option<String>,
    cols: Option<u16>,
    rows: Option<u16>,
) -> Result<String, String> {
    let shell = locate_shell()?;

    let pty_system = native_pty_system();
    // Open at the caller's REAL size (xterm has already measured its host
    // when it calls this), not a nominal 80x24. Spawning wide and then
    // shrinking mid-profile-load is what made PSReadLine's ListView
    // prediction initialize against a width that was about to vanish - the
    // tray pane is ~42 columns, ListView needs 50 - so every tray open
    // printed its yellow "temporarily disabled" warning across the boot.
    let pair = pty_system
        .openpty(PtySize {
            rows: rows.filter(|r| *r > 0).unwrap_or(24),
            cols: cols.filter(|c| *c > 0).unwrap_or(80),
            pixel_width: 0,
            pixel_height: 0,
        })
        .map_err(|e| e.to_string())?;

    let mut cmd = CommandBuilder::new(shell);
    cmd.arg("-NoLogo");
    if let Some(cwd) = cwd {
        cmd.cwd(cwd);
    }

    let child = pair.slave.spawn_command(cmd).map_err(|e| e.to_string())?;
    // The slave handle isn't needed once the child is spawned - dropping
    // it here (rather than holding it for the session's lifetime) matches
    // portable-pty's own example and avoids holding the console handle
    // open longer than necessary on Windows.
    drop(pair.slave);

    let reader = pair.master.try_clone_reader().map_err(|e| e.to_string())?;
    let writer = pair.master.take_writer().map_err(|e| e.to_string())?;

    let session_id = Uuid::new_v4().to_string();

    registry.0.lock().unwrap().insert(
        session_id.clone(),
        TerminalSession {
            master: pair.master,
            writer,
            child,
        },
    );

    spawn_reader_thread(app, session_id.clone(), reader);

    Ok(session_id)
}

/// Reads PTY output on a dedicated OS thread (PTY reads are blocking I/O,
/// not a good fit for the async runtime) and forwards each chunk as a
/// `devkit://terminal` event until the pty closes (child exited, or
/// `terminal_kill` dropped the session's handles), then removes the
/// session from the registry if it's still present.
fn spawn_reader_thread(app: AppHandle, session_id: String, mut reader: Box<dyn Read + Send>) {
    std::thread::spawn(move || {
        let mut buf = [0u8; 4096];
        loop {
            match reader.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    let data = String::from_utf8_lossy(&buf[..n]).into_owned();
                    let _ = app.emit(
                        "devkit://terminal",
                        TerminalChunk {
                            session_id: session_id.clone(),
                            data,
                        },
                    );
                }
                Err(_) => break,
            }
        }
        // The pty closed - either the shell process exited on its own
        // (e.g. the user typed `exit`) or `terminal_kill` dropped the
        // session's master/writer. Either way, tell the frontend so an
        // idle xterm instance doesn't just go silently dead, then reap
        // the registry entry (a no-op if `terminal_kill` already did).
        let _ = app.emit(
            "devkit://terminal",
            TerminalChunk {
                session_id: session_id.clone(),
                data: "\r\n\x1b[90m[session ended]\x1b[0m\r\n".to_string(),
            },
        );
        if let Some(registry) = app.try_state::<TerminalRegistry>() {
            registry.0.lock().unwrap().remove(&session_id);
        }
    });
}

#[tauri::command]
pub async fn terminal_write(
    registry: State<'_, TerminalRegistry>,
    session_id: String,
    data: String,
) -> Result<(), String> {
    let mut sessions = registry.0.lock().unwrap();
    let session = sessions
        .get_mut(&session_id)
        .ok_or_else(|| format!("no terminal session '{session_id}'"))?;
    session.writer.write_all(data.as_bytes()).map_err(|e| e.to_string())?;
    session.writer.flush().map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn terminal_resize(
    registry: State<'_, TerminalRegistry>,
    session_id: String,
    cols: u16,
    rows: u16,
) -> Result<(), String> {
    let sessions = registry.0.lock().unwrap();
    let session = sessions
        .get(&session_id)
        .ok_or_else(|| format!("no terminal session '{session_id}'"))?;
    session
        .master
        .resize(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        })
        .map_err(|e| e.to_string())
}

/// Kills and unregisters one session. Idempotent - killing an
/// already-gone session (e.g. the shell process exited on its own and the
/// reader thread already reaped it) is not an error.
#[tauri::command]
pub async fn terminal_kill(registry: State<'_, TerminalRegistry>, session_id: String) -> Result<(), String> {
    let mut sessions = registry.0.lock().unwrap();
    if let Some(mut session) = sessions.remove(&session_id) {
        let _ = session.child.kill();
    }
    Ok(())
}

/// Kills every live session - called from the app's `ExitRequested`
/// handler in `lib.rs` so quitting DevKit doesn't leave orphaned
/// `pwsh.exe` processes behind. Best-effort: any session whose kill()
/// fails is still dropped from the registry.
pub fn kill_all(app: &AppHandle) {
    let Some(registry) = app.try_state::<TerminalRegistry>() else {
        return;
    };
    let mut sessions = registry.0.lock().unwrap();
    for (_, mut session) in sessions.drain() {
        let _ = session.child.kill();
    }
}
