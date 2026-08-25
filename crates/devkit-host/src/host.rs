//! Owns the long-lived `pwsh` sidecar process and multiplexes concurrent
//! RPC calls over its stdin/stdout using the NDJSON protocol in
//! [`crate::protocol`].
//!
//! Isolation model mirrors the old WPF widget's `MetricsRunspace` /
//! `McpRunspace` / `WorkRunspace` split (see `gui/DevKit-Widget.ps1`): the
//! sidecar itself fans work out across a PowerShell `RunspacePool` on lanes
//! named in each request's `method` prefix (`metrics.*`, `slow.*`,
//! `work.*`), so a slow `gh pr list` call can never stall a metrics poll.
//! From the Rust side that's opaque - this client just sees one stdout
//! stream and demuxes by request id.

use std::collections::HashMap;
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

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

    /// Send a request and await its response, with the spec's default
    /// timeout. On a dead sidecar this transparently respawns once (with
    /// exponential backoff tracked across calls) before retrying.
    pub async fn call(&self, method: &str, params: Option<Value>) -> HostResult<Value> {
        self.call_with_timeout(method, params, self.inner.spec.default_timeout)
            .await
    }

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
    pub async fn ensure_alive(&self) -> HostResult<()> {
        if self.is_alive() {
            return Ok(());
        }

        let mut guard = self.inner.running.lock().await;
        if self.is_alive() {
            return Ok(());
        }

        let attempt = self.inner.respawn_attempts.fetch_add(1, Ordering::SeqCst);
        if attempt > 0 {
            let backoff_ms = (200u64 * (1 << attempt.min(5))).min(10_000);
            debug!(attempt, backoff_ms, "backing off before sidecar respawn");
            tokio::time::sleep(Duration::from_millis(backoff_ms)).await;
        }

        let spec = &self.inner.spec;
        let mut cmd = Command::new(&spec.program);
        cmd.arg("-NoLogo")
            .arg("-NoProfile")
            .arg("-NonInteractive")
            .arg("-ExecutionPolicy")
            .arg("Bypass")
            .arg("-File")
            .arg(&spec.script)
            .current_dir(&spec.cwd)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);

        let mut child = cmd.spawn()?;
        let stdin = child.stdin.take().expect("piped stdin");
        let stdout = child.stdout.take().expect("piped stdout");
        let stderr = child.stderr.take().expect("piped stderr");

        // Fresh per-generation pending map (see [`PendingMap`]'s doc comment)
        // - never shared with a previous or future spawn of the sidecar.
        let pending: PendingMap = Arc::new(Mutex::new(HashMap::new()));
        let pending_for_reader = pending.clone();
        let events_tx = self.inner.events_tx.clone();
        let alive_flag = {
            // Cloning the Arc<Inner> itself (via a weak-free approach) so the
            // reader task can flip `alive` back to false on EOF without
            // holding `running`'s lock re-entrantly.
            let inner = self.inner.clone();
            move || inner.alive.store(false, Ordering::SeqCst)
        };

        let reader_task = tokio::spawn(async move {
            let mut lines = BufReader::new(stdout).lines();
            loop {
                match lines.next_line().await {
                    Ok(Some(line)) => {
                        if line.trim().is_empty() {
                            continue;
                        }
                        match serde_json::from_str::<SidecarMessage>(&line) {
                            Ok(SidecarMessage::Response(resp)) => {
                                if let Some(tx) = pending_for_reader.lock().await.remove(&resp.id) {
                                    let _ = tx.send(resp);
                                }
                            }
                            Ok(SidecarMessage::Event(evt)) => {
                                let _ = events_tx.send(evt);
                            }
                            Err(e) => {
                                error!(error = %e, raw = %line, "unparseable sidecar line");
                            }
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
            alive_flag();
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

        self.inner.alive.store(true, Ordering::SeqCst);
        self.inner.respawn_attempts.store(0, Ordering::SeqCst);
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
        // Only send the RPC "shutdown" call if a sidecar is actually up.
        // `call_with_timeout` would otherwise transparently respawn a dead
        // sidecar (via `ensure_alive`, its normal behavior for any call)
        // just to immediately kill the fresh process below - a needless
        // 300-800ms cold start (or, worse, a full backoff wait if the
        // previous respawn attempt is what's still failing) on every
        // shutdown-after-crash or repeated shutdown() call.
        if self.is_alive() {
            let _ = self
                .call_with_timeout("shutdown", None, Duration::from_millis(2000))
                .await;
        }

        let mut guard = self.inner.running.lock().await;
        if let Some(mut running) = guard.take() {
            self.inner.alive.store(false, Ordering::SeqCst);
            // Keep the reader task alive (rather than aborting it up front)
            // while we wait for exit, so the sidecar's stdout pipe never
            // backs up mid-drain - which could otherwise stall its own
            // WriteLine calls and turn a slow-but-healthy shutdown into a
            // deadlocked one.
            let exited = tokio::time::timeout(Duration::from_secs(8), running.child.wait()).await;
            running.reader_task.abort();
            if exited.is_err() {
                warn!("sidecar did not exit within the shutdown grace period, force-killing");
                let _ = running.child.start_kill();
            }
        }
    }
}
