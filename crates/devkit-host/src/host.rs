//! Owns the long-lived `pwsh` sidecar process and multiplexes concurrent
//! RPC calls over its stdin/stdout using the NDJSON protocol in
//! [`crate::protocol`].
//!
//! Isolation model mirrors the old WPF widget's `MetricsRunspace` /
//! `McpRunspace` / `WorkRunspace` split (see `gui/DevKit-Widget.ps1`): the
//! sidecar itself fans work out across a PowerShell `RunspacePool` on
//! lanes, routed by method-name prefix in the sidecar's
//! `Get-DevKitRpcLaneForMethod`, so a slow `gh pr list` call can never
//! stall a metrics poll. From the Rust side that's opaque - this client
//! just sees one stdout stream and demuxes by request id.

use std::collections::HashMap;
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::{broadcast, oneshot, Mutex};
use tracing::{debug, error, warn};

use crate::protocol::{RpcError, RpcEvent, RpcRequest, RpcResponse, SidecarMessage};

#[derive(Debug, thiserror::Error)]
pub enum HostError {
    #[error("sidecar failed to start: {0}")]
    Spawn(#[from] std::io::Error),
    #[error("sidecar call timed out after {0:?}")]
    Timeout(Duration),
    #[error("sidecar process is not running")]
    Dead,
    #[error("sidecar returned an error: {0} ({1})")]
    Remote(String, String),
    #[error("failed to encode/decode sidecar message: {0}")]
    Codec(#[from] serde_json::Error),
    #[error("sidecar exited before responding")]
    Disconnected,
}

pub type HostResult<T> = Result<T, HostError>;

/// First rung of the respawn ladder (the delay before respawn attempt #1).
const BACKOFF_BASE_MS: u64 = 200;
/// Ceiling of the respawn ladder. A sidecar that can never come up costs
/// one `pwsh` cold start per this interval, forever - not one per poll.
const BACKOFF_MAX_MS: u64 = 10_000;
/// How long a spawned generation must survive - *and* have actually spoken
/// well-formed NDJSON on stdout at least once - before we accept it as
/// genuinely working and clear the respawn ladder. See
/// [`generation_proved_healthy`].
const HEALTHY_UPTIME: Duration = Duration::from_secs(10);
/// How long [`PsHost::shutdown`] waits for the child to exit on its own
/// after acking the `shutdown` RPC. Must comfortably cover the sidecar's
/// own ~7s worst-case drain (see that method's doc comment).
const SHUTDOWN_GRACE: Duration = Duration::from_secs(8);
/// How long [`PsHost::shutdown`] then lets the reader task observe EOF and
/// fail any still-pending requests before aborting it.
const READER_DRAIN_GRACE: Duration = Duration::from_millis(250);

/// Delay to wait before respawn attempt number `attempt`, where `attempt`
/// is the count of spawn attempts already made since the sidecar was last
/// known-healthy. `attempt == 0` is the very first spawn (and the first
/// respawn after a healthy run) and must not sleep at all - a transient
/// death should be recovered from instantly.
///
/// Doubles from [`BACKOFF_BASE_MS`], clamped at [`BACKOFF_MAX_MS`]:
/// 0, 200ms, 400ms, 800ms, 1.6s, 3.2s, 6.4s, 10s, 10s, ...
fn respawn_backoff(attempt: u64) -> Duration {
    if attempt == 0 {
        return Duration::ZERO;
    }
    // Clamp the shift well below u64's width: `u64::checked_shl` only
    // validates the shift amount, it does NOT saturate the value, so a big
    // `attempt` would otherwise shift the 200 clean off the top and yield
    // a *zero* backoff - reintroducing the exact storm this guards against.
    let shift = (attempt - 1).min(32) as u32;
    Duration::from_millis((BACKOFF_BASE_MS << shift).min(BACKOFF_MAX_MS))
}

/// Whether a sidecar generation has earned the right to clear the respawn
/// ladder.
///
/// The bug this exists to prevent: the counter used to be reset the instant
/// `Command::spawn` returned Ok, but `spawn` succeeding only means
/// *`pwsh.exe` launched* - it says nothing about whether the script then
/// threw at import (an AV quarantine of a `core/` file, an AppLocker/WDAC
/// block, a broken pwsh) and exited 200ms later. That is by far the more
/// likely failure, and it made every respawn look like attempt #0, so the
/// ladder slept zero milliseconds and the 2s/3s metric polls spawned a
/// fresh 300-800ms pwsh cold start roughly once a second, forever.
///
/// So a generation counts as healthy only when BOTH hold:
/// - `spoke`: it emitted at least one well-formed protocol line. The
///   sidecar is silent on stdout until it answers a request, so this
///   proves pwsh launched, the script parsed, `DevKit.Core.psm1` imported,
///   the lane runspaces came up, and the writer runspace is flushing.
/// - `uptime >= HEALTHY_UPTIME`: it did not die right after doing so. This
///   catches the nastier variant where the sidecar answers a request or
///   two and *then* falls over, which proof-of-life alone would treat as a
///   success and reset the ladder on every crash.
fn generation_proved_healthy(spoke: bool, uptime: Duration) -> bool {
    spoke && uptime >= HEALTHY_UPTIME
}

/// Everything needed to (re)spawn the sidecar process identically.
#[derive(Debug, Clone)]
pub struct SidecarSpec {
    /// Path to `pwsh.exe` (or `powershell.exe` fallback), resolved once at
    /// startup by the caller.
    pub program: PathBuf,
    /// Path to `core/Invoke-DevKitRpc.ps1`.
    pub script: PathBuf,
    /// Working directory the sidecar should run from (repo root / install
    /// root), so its relative `tools/`, `core/` dot-sources resolve.
    pub cwd: PathBuf,
    pub default_timeout: Duration,
}

/// Per-spawn generation's pending-request table. Owned by the
/// [`RunningSidecar`] it was created for (not shared across respawns) so
/// that a dead generation's cleanup can never race with a live generation's
/// requests - see the note in [`PsHost::ensure_alive`].
type PendingMap = Arc<Mutex<HashMap<u64, oneshot::Sender<RpcResponse>>>>;

struct RunningSidecar {
    child: Child,
    stdin: ChildStdin,
    reader_task: tokio::task::JoinHandle<()>,
    /// This generation's pending-request table (see [`PendingMap`]).
    pending: PendingMap,
}

struct Inner {
    spec: SidecarSpec,
    running: Mutex<Option<RunningSidecar>>,
    next_id: AtomicU64,
    events_tx: broadcast::Sender<RpcEvent>,
    alive: AtomicBool,
    respawn_attempts: AtomicU64,
    /// Bumped once per spawn. Every reader task captures the generation it
    /// was born into and only ever mutates shared state (`alive`,
    /// `respawn_attempts`) while it still owns the latest one - so a dying
    /// old generation observing EOF *after* a fresh one is already serving
    /// can neither mark the live sidecar dead nor clear a ladder that the
    /// live sidecar has not earned.
    generation: AtomicU64,
    /// Set for the duration of [`PsHost::shutdown`]. Makes `ensure_alive` a
    /// hard no-op so nothing respawns a sidecar we are in the middle of
    /// killing - see the note in `shutdown`.
    shutting_down: AtomicBool,
}

impl Inner {
    /// Clear the respawn ladder, but only on behalf of the generation that
    /// currently owns the host.
    fn mark_generation_healthy(&self, generation: u64) {
        if self.generation.load(Ordering::SeqCst) != generation {
            return;
        }
        let previous = self.respawn_attempts.swap(0, Ordering::SeqCst);
        if previous > 1 {
            debug!(
                generation,
                previous, "sidecar proved healthy, respawn backoff cleared"
            );
        }
    }
}

/// Sets `shutting_down` for as long as it lives. RAII rather than a pair of
/// stores so that an early return - or the shutdown future simply being
/// dropped mid-await - can never strand the flag set, which would wedge the
/// host permanently unable to respawn.
struct ShutdownGuard(Arc<Inner>);

impl ShutdownGuard {
    fn arm(inner: &Arc<Inner>) -> Self {
        inner.shutting_down.store(true, Ordering::SeqCst);
        Self(inner.clone())
    }
}

impl Drop for ShutdownGuard {
    fn drop(&mut self) {
        self.0.shutting_down.store(false, Ordering::SeqCst);
    }
}

/// Handle to the sidecar. Cheap to clone (wraps an `Arc`); intended to be
/// held once in Tauri managed state or the CLI's runtime and shared across
/// tasks/commands.
#[derive(Clone)]
pub struct PsHost {
    inner: Arc<Inner>,
}

impl PsHost {
    pub async fn spawn(spec: SidecarSpec) -> HostResult<Self> {
        let (events_tx, _rx) = broadcast::channel(1024);
        let inner = Arc::new(Inner {
            spec,
            running: Mutex::new(None),
            next_id: AtomicU64::new(1),
            events_tx,
            alive: AtomicBool::new(false),
            respawn_attempts: AtomicU64::new(0),
            generation: AtomicU64::new(0),
            shutting_down: AtomicBool::new(false),
        });
        let host = Self { inner };
        host.ensure_alive().await?;
        Ok(host)
    }

    pub fn subscribe_events(&self) -> broadcast::Receiver<RpcEvent> {
        self.inner.events_tx.subscribe()
    }

    pub fn is_alive(&self) -> bool {
        self.inner.alive.load(Ordering::SeqCst)
    }

    /// The timeout [`PsHost::call`] applies when the caller does not name
    /// one, straight off the [`SidecarSpec`]. Exposed so a caller applying
    /// a per-method timeout policy (e.g. hours for `tool.*`, the normal
    /// budget for everything else) can express "the usual" without having
    /// to keep its own copy of the spec in sync with this one.
    pub fn default_timeout(&self) -> Duration {
        self.inner.spec.default_timeout
    }

    /// Send a request and await its response, with the spec's default
    /// timeout. On a dead sidecar this transparently respawns once (with
    /// exponential backoff tracked across calls) before retrying.
    pub async fn call(&self, method: &str, params: Option<Value>) -> HostResult<Value> {
        self.call_with_timeout(method, params, self.inner.spec.default_timeout)
            .await
    }

    /// [`PsHost::call_with_timeout`] where `None` means "the spec's
    /// default" - the shape a passthrough command wants when its timeout
    /// arrives as an optional argument from the frontend, or is chosen by
    /// a lookup that may not have an opinion about this method.
    pub async fn call_with_optional_timeout(
        &self,
        method: &str,
        params: Option<Value>,
        timeout: Option<Duration>,
    ) -> HostResult<Value> {
        self.call_with_timeout(
            method,
            params,
            timeout.unwrap_or(self.inner.spec.default_timeout),
        )
        .await
    }

    /// Send a request and await its response with an explicit timeout.
    ///
    /// The timeout is per-call and unbounded upward: a caller that gives a
    /// `tool.*` method a multi-hour budget costs nothing extra here. The
    /// `running` lock is held only across the stdin write, never across the
    /// wait for the reply, so an in-flight multi-hour call never blocks
    /// another call, a respawn, or shutdown. (The sidecar's own lane split
    /// keeps it from blocking the *work* either - see the module docs.)
    pub async fn call_with_timeout(
        &self,
        method: &str,
        params: Option<Value>,
        timeout: Duration,
    ) -> HostResult<Value> {
        if !self.is_alive() {
            self.ensure_alive().await?;
        }

        let id = self.inner.next_id.fetch_add(1, Ordering::SeqCst);
        let (tx, rx) = oneshot::channel();

        let req = RpcRequest::new(id, method, params);
        let mut line = serde_json::to_vec(&req)?;
        line.push(b'\n');

        // Insert into (and, on failure, remove from) the CURRENTLY running
        // generation's own pending map, captured once while holding
        // `running`'s lock, and reused for the timeout-path removal below.
        // This is deliberate: `pending` used to live on `Inner` and be
        // shared across every respawn, which opened a real race - ids are
        // monotonic and never reused, but the shared map was not
        // generation-scoped, so a dying generation's reader task could
        // still be mid-`drain()` (its cleanup on EOF) after a respawn had
        // already inserted a brand-new id for the NEW generation into that
        // same map, wiping out the new generation's pending entry and
        // handing its caller a spurious "disconnected" error instead of the
        // real response that later arrived with nowhere to be delivered.
        // Giving each generation its own map (owned by `RunningSidecar`)
        // makes that race impossible by construction, matching the
        // single-writer-by-construction philosophy of the PowerShell side.
        let pending = {
            let mut guard = self.inner.running.lock().await;
            match guard.as_mut() {
                Some(running) => {
                    let pending = running.pending.clone();
                    pending.lock().await.insert(id, tx);
                    if let Err(e) = running.stdin.write_all(&line).await {
                        warn!(error = %e, "sidecar stdin write failed, marking dead");
                        self.inner.alive.store(false, Ordering::SeqCst);
                        pending.lock().await.remove(&id);
                        return Err(HostError::Disconnected);
                    }
                    if let Err(e) = running.stdin.flush().await {
                        warn!(error = %e, "sidecar stdin flush failed, marking dead");
                        self.inner.alive.store(false, Ordering::SeqCst);
                        pending.lock().await.remove(&id);
                        return Err(HostError::Disconnected);
                    }
                    pending
                }
                None => {
                    return Err(HostError::Dead);
                }
            }
        };

        match tokio::time::timeout(timeout, rx).await {
            Ok(Ok(resp)) => {
                if resp.ok {
                    Ok(resp.result.unwrap_or(Value::Null))
                } else {
                    let err = resp.error.unwrap_or(RpcError {
                        kind: "Unknown".into(),
                        message: "sidecar returned ok=false with no error payload".into(),
                        detail: None,
                    });
                    Err(HostError::Remote(err.kind, err.message))
                }
            }
            Ok(Err(_canceled)) => Err(HostError::Disconnected),
            Err(_elapsed) => {
                pending.lock().await.remove(&id);
                Err(HostError::Timeout(timeout))
            }
        }
    }

    /// Idempotent: no-op if a healthy process is already running. Serializes
    /// concurrent respawn attempts via the `running` mutex itself.
    ///
    /// The respawn ladder is driven by [`respawn_backoff`] and is only ever
    /// cleared by a generation that [`generation_proved_healthy`] accepts -
    /// never merely by `Command::spawn` returning Ok. See that function for
    /// why the distinction is the whole point.
    pub async fn ensure_alive(&self) -> HostResult<()> {
        if self.is_alive() {
            return Ok(());
        }
        if self.inner.shutting_down.load(Ordering::SeqCst) {
            return Err(HostError::Dead);
        }

        let mut guard = self.inner.running.lock().await;
        if self.is_alive() {
            return Ok(());
        }
        // Re-checked under the lock: `shutdown` holds `running` for as long
        // as it waits on the child, so a call that raced in ahead of it can
        // land here seconds later, with the process already killed. Without
        // this it would respawn a sidecar the app is actively tearing down
        // - and now that the ladder actually works, potentially sleep a
        // full 10s doing it, on the exit path, with the user waiting.
        if self.inner.shutting_down.load(Ordering::SeqCst) {
            return Err(HostError::Dead);
        }

        let attempt = self.inner.respawn_attempts.fetch_add(1, Ordering::SeqCst);
        let backoff = respawn_backoff(attempt);
        if !backoff.is_zero() {
            debug!(
                attempt,
                backoff_ms = backoff.as_millis() as u64,
                "backing off before sidecar respawn"
            );
            tokio::time::sleep(backoff).await;
        }

        let spec = &self.inner.spec;
        // Last line of defense against `\\?\`-prefixed verbatim paths, which
        // PowerShell's own providers reject (see app/src-tauri/src/paths.rs).
        // The app side already simplifies, but the CLI path does not - so
        // simplify here regardless of which host built the spec.
        let script = dunce::simplified(&spec.script);
        let cwd = dunce::simplified(&spec.cwd);
        let mut cmd = Command::new(&spec.program);
        cmd.arg("-NoLogo")
            .arg("-NoProfile")
            .arg("-NonInteractive")
            .arg("-ExecutionPolicy")
            .arg("Bypass")
            .arg("-File")
            .arg(script)
            .current_dir(cwd)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);

        // Piped stdio redirects the STREAMS but does not, on its own, stop
        // Windows from showing a console window for a console-subsystem
        // child like pwsh.exe - without this flag a real (non-dev-loopback)
        // launch shows an empty console window sitting behind the app,
        // since all of pwsh's actual output goes through the pipes instead
        // of that console. CREATE_NO_WINDOW (0x08000000) only prevents the
        // window from being SHOWN - the child still gets a console object
        // (which is why e.g. [Console]::InputEncoding works inside the
        // sidecar). See std::os::windows::process::CommandExt.
        #[cfg(windows)]
        {
            // tokio::process::Command exposes creation_flags() natively on
            // Windows (no std::os::windows::process::CommandExt import
            // needed - that's only for std::process::Command).
            const CREATE_NO_WINDOW: u32 = 0x0800_0000;
            cmd.creation_flags(CREATE_NO_WINDOW);
        }

        let mut child = cmd.spawn()?;
        let stdin = child.stdin.take().expect("piped stdin");
        let stdout = child.stdout.take().expect("piped stdout");
        let stderr = child.stderr.take().expect("piped stderr");

        // Fresh per-generation pending map (see [`PendingMap`]'s doc comment)
        // - never shared with a previous or future spawn of the sidecar.
        let pending: PendingMap = Arc::new(Mutex::new(HashMap::new()));
        let pending_for_reader = pending.clone();
        let events_tx = self.inner.events_tx.clone();
        // Claimed before the reader task exists so the task can compare
        // against it (see `Inner::generation`).
        let generation = self.inner.generation.fetch_add(1, Ordering::SeqCst) + 1;
        let spawned_at = Instant::now();
        // The reader task needs `Inner` to flip `alive` on EOF and to clear
        // the ladder once this generation proves itself - both without
        // re-entrantly holding `running`'s lock.
        let inner = self.inner.clone();

        // Ordered deliberately BEFORE the reader task is spawned: a
        // generation that dies almost immediately (pwsh launched, the
        // script threw at import, EOF within ~200ms) would otherwise have
        // its `alive = false` overwritten by a `true` stored down here,
        // leaving the host convinced a corpse is serving requests. Callers
        // can't observe the window - `call_with_timeout` blocks on the
        // `running` lock we are still holding.
        self.inner.alive.store(true, Ordering::SeqCst);

        let reader_task = tokio::spawn(async move {
            let mut lines = BufReader::new(stdout).lines();
            // "This generation emitted at least one well-formed protocol
            // line", i.e. it got far enough to actually serve RPC. Garbage
            // on stdout deliberately does not count.
            let mut spoke = false;
            let mut cleared_backoff = false;
            loop {
                match lines.next_line().await {
                    Ok(Some(line)) => {
                        if line.trim().is_empty() {
                            continue;
                        }
                        match serde_json::from_str::<SidecarMessage>(&line) {
                            Ok(SidecarMessage::Response(resp)) => {
                                spoke = true;
                                if let Some(tx) = pending_for_reader.lock().await.remove(&resp.id) {
                                    let _ = tx.send(resp);
                                }
                            }
                            Ok(SidecarMessage::Event(evt)) => {
                                spoke = true;
                                let _ = events_tx.send(evt);
                            }
                            Err(e) => {
                                error!(error = %e, raw = %line, "unparseable sidecar line");
                            }
                        }
                        // Clear the ladder as soon as this generation has
                        // earned it, rather than waiting for it to die: a
                        // sidecar that comes up healthy after a rough patch
                        // must not carry an elevated backoff around for the
                        // rest of the session, or a single unrelated
                        // transient death hours later would eat a 10s stall.
                        if !cleared_backoff
                            && generation_proved_healthy(spoke, spawned_at.elapsed())
                        {
                            inner.mark_generation_healthy(generation);
                            cleared_backoff = true;
                        }
                    }
                    Ok(None) => {
                        debug!("sidecar stdout closed (EOF)");
                        break;
                    }
                    Err(e) => {
                        error!(error = %e, "sidecar stdout read error");
                        break;
                    }
                }
            }

            let uptime = spawned_at.elapsed();
            // Generation-guarded (see `Inner::generation`): if a respawn has
            // already happened, the live sidecar owns `alive` and this dead
            // one must not stomp it - which would make the very next call
            // tear down a perfectly healthy process.
            if inner.generation.load(Ordering::SeqCst) == generation {
                inner.alive.store(false, Ordering::SeqCst);
            }
            // The quiet-sidecar counterpart to the in-loop clear above: a
            // generation that served a request and then sat idle for its
            // whole life still earned a clean slate, and only finds out here.
            if !cleared_backoff {
                if generation_proved_healthy(spoke, uptime) {
                    inner.mark_generation_healthy(generation);
                } else {
                    warn!(
                        generation,
                        spoke,
                        uptime_ms = uptime.as_millis() as u64,
                        "sidecar generation died without proving healthy, keeping respawn backoff"
                    );
                }
            }
            // Fail every still-pending request rather than leaving callers
            // hung until their timeout. Only ever touches THIS generation's
            // own map (see [`PendingMap`]) - a concurrently-respawned new
            // generation's in-flight requests live in a different map and
            // are untouched by this drain.
            let mut map = pending_for_reader.lock().await;
            for (_, tx) in map.drain() {
                let _ = tx.send(RpcResponse {
                    id: 0,
                    ok: false,
                    result: None,
                    error: Some(RpcError {
                        kind: "SidecarDisconnected".into(),
                        message: "sidecar process exited".into(),
                        detail: None,
                    }),
                    ms: None,
                });
            }
        });

        // Sidecar stderr is diagnostic-only (pwsh startup warnings, dot-source
        // errors) - forward to tracing rather than the RPC channel.
        tokio::spawn(async move {
            let mut lines = BufReader::new(stderr).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                warn!(target: "devkit_sidecar_stderr", "{line}");
            }
        });

        // NOTE: the respawn ladder is deliberately NOT cleared here. Having
        // spawned proves only that pwsh.exe launched; the reader task
        // clears it once this generation actually behaves like a working
        // sidecar. See `generation_proved_healthy`.
        *guard = Some(RunningSidecar {
            child,
            stdin,
            reader_task,
            pending,
        });
        Ok(())
    }

    /// Best-effort graceful shutdown: ask the sidecar to exit cleanly, give
    /// it a moment, then kill. Safe to call even if already dead.
    ///
    /// Timeout budget, reconciled against `Invoke-DevKitRpc.ps1`'s own
    /// SHUTDOWN section: the sidecar's main loop acks the `shutdown` RPC
    /// call *immediately* on reading it (before it starts draining
    /// anything), so a short timeout on the ack itself is fine. But the
    /// process doesn't actually *exit* until it has drained all three lane
    /// runspaces (up to a 5s deadline there) and then the writer runspace
    /// (up to a further 2s deadline) - up to ~7s worst case. Our own
    /// post-ack wait for the child to exit has to comfortably cover that
    /// worst case, or we'd force-kill the sidecar mid-drain (e.g. cutting
    /// off a `tool.run` that's still streaming a child process's output)
    /// on every slow shutdown instead of only on a truly hung one.
    pub async fn shutdown(&self) {
        // Latched for the whole teardown so nothing respawns underneath us.
        // The `is_alive()` check below is necessary but NOT sufficient on
        // its own: it is a check-then-act against a flag any reader task
        // can flip, and any *concurrent* call (a metrics poll, a `tool.run`
        // that just lost its sidecar) reaching `ensure_alive` would happily
        // cold-start a fresh 300-800ms pwsh - now potentially after a full
        // 10s backoff sleep, since the ladder finally works - purely to be
        // killed here microseconds later. With the latch, calls that race
        // shutdown fail fast with `Dead` instead.
        let _shutdown_guard = ShutdownGuard::arm(&self.inner);

        // Only send the RPC "shutdown" call if a sidecar is actually up:
        // `call_with_timeout` on a dead one would (modulo the latch above)
        // respawn it just to kill it.
        if self.is_alive() {
            let _ = self
                .call_with_timeout("shutdown", None, Duration::from_millis(2000))
                .await;
        }

        let mut guard = self.inner.running.lock().await;
        if let Some(mut running) = guard.take() {
            self.inner.alive.store(false, Ordering::SeqCst);
            // A deliberate stop is not a failed spawn attempt. Clearing the
            // ladder here is what keeps `sidecar_restart` (shutdown +
            // ensure_alive) instant even when the user is restarting
            // *because* the sidecar had been crash-looping - the restart is
            // an explicit, human-paced action, not the automatic poll storm
            // the backoff exists to damp.
            self.inner.respawn_attempts.store(0, Ordering::SeqCst);
            // Keep the reader task alive (rather than aborting it up front)
            // while we wait for exit, so the sidecar's stdout pipe never
            // backs up mid-drain - which could otherwise stall its own
            // WriteLine calls and turn a slow-but-healthy shutdown into a
            // deadlocked one.
            let exited = tokio::time::timeout(SHUTDOWN_GRACE, running.child.wait()).await;
            if exited.is_err() {
                warn!("sidecar did not exit within the shutdown grace period, force-killing");
                let _ = running.child.start_kill();
            }
            // `child.wait()` returns the moment the process is gone, which
            // is typically *before* the reader task has observed EOF and run
            // its drain. Aborting straight away (as this used to) truncated
            // that drain, so a long-running in-flight call - a `tool.run`
            // with an hours-long timeout, exactly the caller most likely to
            // still be pending at shutdown - was woken by its oneshot sender
            // merely being dropped, surfacing a bare `Disconnected` instead
            // of the drain's explicit "sidecar process exited". Give the
            // drain a brief window, then abort so a wedged pipe still can't
            // hold up app exit. Either way no caller hangs: the abort drops
            // the senders, which cancels every waiting `rx`.
            if tokio::time::timeout(READER_DRAIN_GRACE, &mut running.reader_task)
                .await
                .is_err()
            {
                running.reader_task.abort();
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn first_spawn_and_first_respawn_after_health_do_not_sleep() {
        // attempt 0 is both the cold start and the first respawn after a
        // healthy run (the ladder having been cleared). A transient death
        // must be recovered from immediately, not penalised.
        assert_eq!(respawn_backoff(0), Duration::ZERO);
    }

    #[test]
    fn backoff_doubles_from_200ms_and_caps_at_10s() {
        assert_eq!(respawn_backoff(1), Duration::from_millis(200));
        assert_eq!(respawn_backoff(2), Duration::from_millis(400));
        assert_eq!(respawn_backoff(3), Duration::from_millis(800));
        assert_eq!(respawn_backoff(4), Duration::from_millis(1_600));
        assert_eq!(respawn_backoff(5), Duration::from_millis(3_200));
        assert_eq!(respawn_backoff(6), Duration::from_millis(6_400));
        assert_eq!(respawn_backoff(7), Duration::from_millis(BACKOFF_MAX_MS));
    }

    #[test]
    fn backoff_stays_capped_for_absurd_attempt_counts() {
        // Regression guard for the shift: `200u64 << 64` is UB-adjacent
        // (checked_shl only validates the shift amount, it does not
        // saturate the value), and a wrapped result of 0 would silently
        // restore the once-a-second respawn storm this whole ladder exists
        // to prevent. Every rung past the cap must be exactly the cap.
        for attempt in [8u64, 64, 128, 4096, u64::MAX] {
            assert_eq!(
                respawn_backoff(attempt),
                Duration::from_millis(BACKOFF_MAX_MS),
                "attempt {attempt} escaped the cap"
            );
        }
    }

    #[test]
    fn backoff_is_monotonic_up_to_the_cap() {
        let mut previous = respawn_backoff(0);
        for attempt in 1..40u64 {
            let current = respawn_backoff(attempt);
            assert!(
                current >= previous,
                "attempt {attempt} went backwards: {current:?} < {previous:?}"
            );
            assert!(current <= Duration::from_millis(BACKOFF_MAX_MS));
            previous = current;
        }
    }

    #[test]
    fn spawning_alone_never_counts_as_healthy() {
        // THE bug: `Command::spawn` returning Ok only means pwsh.exe
        // launched. A sidecar that dies at import has said nothing at all,
        // so no amount of elapsed time may clear the ladder.
        assert!(!generation_proved_healthy(false, Duration::ZERO));
        assert!(!generation_proved_healthy(
            false,
            Duration::from_millis(200)
        ));
        assert!(!generation_proved_healthy(false, HEALTHY_UPTIME));
        assert!(!generation_proved_healthy(
            false,
            Duration::from_secs(60 * 60)
        ));
    }

    #[test]
    fn answering_then_dying_immediately_is_still_a_failed_attempt() {
        // The nastier variant: the sidecar comes up, serves a poll or two,
        // then falls over. Proof-of-life alone would reset the ladder on
        // every crash and hand back the storm.
        assert!(!generation_proved_healthy(true, Duration::ZERO));
        assert!(!generation_proved_healthy(true, Duration::from_secs(1)));
        assert!(!generation_proved_healthy(
            true,
            HEALTHY_UPTIME - Duration::from_millis(1)
        ));
    }

    #[test]
    fn speaking_and_surviving_clears_the_ladder() {
        assert!(generation_proved_healthy(true, HEALTHY_UPTIME));
        assert!(generation_proved_healthy(
            true,
            HEALTHY_UPTIME + Duration::from_secs(1)
        ));
        assert!(generation_proved_healthy(true, Duration::from_secs(86_400)));
    }

    #[test]
    fn healthy_uptime_clears_a_pwsh_cold_start() {
        // The threshold has to sit comfortably beyond a legitimate slow
        // cold start (pwsh launch plus DevKit.Core.psm1's dot-sourced
        // import, worst case on a cold AV-scanned install), or a machine
        // that is merely slow would be misread as one that is broken.
        assert!(HEALTHY_UPTIME >= Duration::from_secs(5));
    }
}
