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
//! Output is forwarded to the frontend as UTF-8 string chunks on the
//! `devkit://terminal` event, `{ sessionId, data }` - raw string rather
//! than base64 because xterm.js consumes text/ANSI directly and this
//! avoids a decode step in the hot path. A chunk that ends mid multi-byte
//! character is NOT lossy-decoded byte-by-byte: up to `MAX_UTF8_LEN - 1`
//! trailing bytes that form an incomplete UTF-8 prefix are carried into
//! the next read and decoded whole, because a per-chunk `from_utf8_lossy`
//! rendered a transient U+FFFD in xterm at every 4096-byte buffer boundary
//! that happened to split a character.
//!
//! SESSION LIFETIME. Sessions are scoped to the window that spawned them
//! (`TerminalSession::owner`): `lib.rs` kills a window's sessions on
//! `WindowEvent::Destroyed` - the widget's `CloseRequested` only hides to
//! the tray, so a hidden widget keeps its terminal, while a window that
//! actually closes (app exit reaps everything via `kill_all`) takes its
//! sessions down with it. That still leaves the webview-reload /
//! frontend-crash case: the window survives, the session doesn't, and
//! nothing calls `terminal_kill`. The idle reaper (`start_idle_reaper`)
//! sweeps every `IDLE_REAPER_INTERVAL` and kills sessions with no PTY
//! output AND no frontend writes for longer than `IDLE_TIMEOUT` (6 hours -
//! rationale documented on the constant).

use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use portable_pty::{native_pty_system, Child, CommandBuilder, MasterPty, PtySize};
use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, State};
use uuid::Uuid;

/// Longest UTF-8 encoding of one scalar value - 4 bytes. A chunk ending in
/// a byte run shorter than this may be an incomplete character (split
/// across read-buffer boundaries) rather than genuinely invalid data, so
/// those bytes are held for the next read instead of decoded early.
const MAX_UTF8_LEN: usize = 4;

/// How often the idle reaper sweeps the registry.
const IDLE_REAPER_INTERVAL: Duration = Duration::from_secs(30 * 60);
/// A session with no PTY output AND no frontend writes for this long is
/// abandoned. 6 hours is far past any legitimate interactive stretch (a
/// live session is being typed into, and even a silent overnight build gets
/// checked on within this) while still bounding how long a session
/// orphaned by a webview reload or frontend crash pins its `pwsh.exe` +
/// reader thread. Documented trade-off: a build deliberately left running
/// inside the tray terminal for >6h with zero output and zero keystrokes
/// is killed too - that is the accepted price of not leaking the
/// orphaned-session case forever.
const IDLE_TIMEOUT: Duration = Duration::from_secs(6 * 60 * 60);

struct TerminalSession {
    master: Box<dyn MasterPty + Send>,
    /// Behind its OWN mutex, shared with `terminal_write` via the Arc: the
    /// global registry mutex must never be held across the blocking PTY
    /// write+flush - a child that stopped reading its input would
    /// otherwise stall resize/kill/spawn for every other session too.
    writer: Arc<Mutex<Box<dyn Write + Send>>>,
    child: Box<dyn Child + Send + Sync>,
    /// Label of the window that spawned the session (see the module doc's
    /// SESSION LIFETIME paragraph).
    owner: String,
    /// Last time anything flowed through the session - PTY output (reader
    /// thread) or a frontend write. The idle reaper compares against this.
    last_activity: Arc<Mutex<Instant>>,
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
/// `devkit://terminal` events. The session is scoped to the invoking
/// window (its label is stored as the owner - see the module doc).
#[tauri::command]
pub async fn terminal_spawn(
    window: tauri::WebviewWindow,
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
    let activity = Arc::new(Mutex::new(Instant::now()));

    registry.0.lock().unwrap().insert(
        session_id.clone(),
        TerminalSession {
            master: pair.master,
            writer: Arc::new(Mutex::new(writer)),
            child,
            owner: window.label().to_string(),
            last_activity: activity.clone(),
        },
    );

    spawn_reader_thread(app, session_id.clone(), reader, activity);

    Ok(session_id)
}

/// Splits `chunk` into (decodable prefix length, incomplete trailing
/// prefix length). A trailing byte run is held back ONLY when it is a
/// plausible incomplete UTF-8 prefix (`Utf8Error::error_len() == None` -
/// "unexpected end of data", i.e. the run is a valid prefix of some
/// multi-byte character); genuinely invalid bytes stay in the decoded
/// portion so `from_utf8_lossy` renders U+FFFD and the stream resyncs
/// within the chunk.
fn split_incomplete_utf8_tail(chunk: &[u8]) -> (usize, usize) {
    match std::str::from_utf8(chunk) {
        Ok(_) => (chunk.len(), 0),
        Err(e) => {
            let valid = e.valid_up_to();
            let tail = chunk.len() - valid;
            if e.error_len().is_none() && tail < MAX_UTF8_LEN {
                (valid, tail)
            } else {
                (chunk.len(), 0)
            }
        }
    }
}

/// Incremental decoder for the PTY reader's 4096-byte chunks: a multi-byte
/// character split across two reads reassembles instead of rendering a
/// transient U+FFFD in xterm. `feed` returns the text safe to emit now
/// ("" when everything read so far is an incomplete prefix); `finish` is
/// for EOF and silently drops a truncated final character.
struct Utf8ChunkDecoder {
    carry: Vec<u8>,
}

impl Utf8ChunkDecoder {
    fn new() -> Self {
        Self {
            carry: Vec::with_capacity(MAX_UTF8_LEN - 1),
        }
    }

    fn feed(&mut self, bytes: &[u8]) -> String {
        let mut chunk = std::mem::take(&mut self.carry);
        chunk.extend_from_slice(bytes);
        let (decodable, tail) = split_incomplete_utf8_tail(&chunk);
        self.carry
            .extend_from_slice(&chunk[decodable..decodable + tail]);
        if decodable == 0 {
            return String::new();
        }
        String::from_utf8_lossy(&chunk[..decodable]).into_owned()
    }

    fn finish(self) {
        // Any bytes still in `carry` are a truncated final character -
        // dropped, not rendered.
    }
}

/// Reads PTY output on a dedicated OS thread (PTY reads are blocking I/O,
/// not a good fit for the async runtime) and forwards each chunk as a
/// `devkit://terminal` event until the pty closes (child exited, or
/// `terminal_kill` dropped the session's handles), then removes the
/// session from the registry if it's still present. Every read refreshes
/// `activity` (it is output, after all) for the idle reaper.
fn spawn_reader_thread(
    app: AppHandle,
    session_id: String,
    mut reader: Box<dyn Read + Send>,
    activity: Arc<Mutex<Instant>>,
) {
    std::thread::spawn(move || {
        let mut buf = [0u8; 4096];
        // A multi-byte character split across two reads decodes whole on
        // the second read instead of rendering a transient U+FFFD in xterm.
        let mut decoder = Utf8ChunkDecoder::new();
        loop {
            match reader.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    *activity.lock().unwrap() = Instant::now();
                    let data = decoder.feed(&buf[..n]);
                    if data.is_empty() {
                        // Everything read so far is still an incomplete
                        // character prefix - wait for more bytes.
                        continue;
                    }
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
        decoder.finish();
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
    // Clone the per-session handles out under the GLOBAL lock, then do the
    // blocking write under only the SESSION's writer lock: a child that
    // stopped reading its input must not stall resize/kill/spawn for every
    // other session behind the global registry mutex.
    let (writer, activity) = {
        let sessions = registry.0.lock().unwrap();
        let session = sessions
            .get(&session_id)
            .ok_or_else(|| format!("no terminal session '{session_id}'"))?;
        (session.writer.clone(), session.last_activity.clone())
    };
    let mut writer = writer.lock().unwrap();
    writer.write_all(data.as_bytes()).map_err(|e| e.to_string())?;
    writer.flush().map_err(|e| e.to_string())?;
    *activity.lock().unwrap() = Instant::now();
    Ok(())
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

/// Kills every live session owned by `label` - called from lib.rs's
/// `WindowEvent::Destroyed` handler so sessions die with the window that
/// owns them instead of leaking a `pwsh.exe` + reader thread until app
/// exit. Deliberately NOT tied to `CloseRequested`: hiding the widget to
/// the tray prevents the close, and the terminal must survive that.
pub fn kill_window_sessions(app: &AppHandle, label: &str) {
    let Some(registry) = app.try_state::<TerminalRegistry>() else {
        return;
    };
    let mut sessions = registry.0.lock().unwrap();
    let doomed: Vec<String> = sessions
        .iter()
        .filter(|(_, session)| session.owner == label)
        .map(|(id, _)| id.clone())
        .collect();
    for id in doomed {
        if let Some(mut session) = sessions.remove(&id) {
            let _ = session.child.kill();
        }
    }
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

/// Starts the periodic idle reaper - called once from lib.rs's setup, runs
/// for the app lifetime. Every [`IDLE_REAPER_INTERVAL`] it kills sessions
/// whose `last_activity` (PTY output or frontend write) is older than
/// [`IDLE_TIMEOUT`]; see that constant for the threshold's rationale. This
/// is the backstop for sessions orphaned by a webview reload or frontend
/// crash, where the owning window survives and nothing calls
/// `terminal_kill`.
pub fn start_idle_reaper(app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        loop {
            tokio::time::sleep(IDLE_REAPER_INTERVAL).await;
            let Some(registry) = app.try_state::<TerminalRegistry>() else {
                return;
            };
            let mut expired: Vec<(String, String, Duration)> = Vec::new();
            {
                let sessions = registry.0.lock().unwrap();
                for (id, session) in sessions.iter() {
                    let idle = session.last_activity.lock().unwrap().elapsed();
                    if idle >= IDLE_TIMEOUT {
                        expired.push((id.clone(), session.owner.clone(), idle));
                    }
                }
            }
            for (id, owner, idle) in expired {
                tracing::info!(
                    session_id = %id,
                    owner,
                    idle_hours = idle.as_secs() / 3600,
                    "reaping idle terminal session (no PTY output and no input for the idle threshold)"
                );
                let mut sessions = registry.0.lock().unwrap();
                if let Some(mut session) = sessions.remove(&id) {
                    let _ = session.child.kill();
                }
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn multibyte_character_split_across_chunks_reassembles() {
        let mut decoder = Utf8ChunkDecoder::new();
        // "€" is E2 82 AC; the read buffer boundary lands after E2 82.
        // Nothing is safe to emit from the first chunk...
        assert_eq!(decoder.feed(&[0xE2, 0x82]), "");
        // ...and the second chunk decodes the whole character - no U+FFFD.
        let out = decoder.feed(&[0xAC]);
        assert_eq!(out, "\u{20AC}");
        assert!(!out.contains('\u{FFFD}'));
        decoder.finish();
    }

    #[test]
    fn invalid_byte_at_chunk_end_is_emitted_not_buffered_forever() {
        let mut decoder = Utf8ChunkDecoder::new();
        // 0xFF can never begin a multi-byte character, so it must be
        // lossy-decoded NOW (U+FFFD) rather than held as a "prefix" that
        // would swallow every following chunk byte into the carry.
        let out = decoder.feed(b"a\xFF");
        assert_eq!(out, "a\u{FFFD}");
        assert_eq!(decoder.feed(b"b"), "b");
        decoder.finish();
    }

    #[test]
    fn trailing_incomplete_prefix_at_eof_is_dropped() {
        let mut decoder = Utf8ChunkDecoder::new();
        // 0xC3 is a valid two-byte lead with no continuation yet.
        assert_eq!(decoder.feed(b"ok\xC3"), "ok");
        // EOF with the prefix still pending: dropped, no panic, no
        // trailing replacement char emitted.
        decoder.finish();
    }

    #[test]
    fn ascii_passes_through_verbatim() {
        let mut decoder = Utf8ChunkDecoder::new();
        assert_eq!(decoder.feed(b"plain ascii\r\n"), "plain ascii\r\n");
        decoder.finish();
    }
}
