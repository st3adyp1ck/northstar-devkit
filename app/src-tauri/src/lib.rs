mod commands;
mod paths;
mod terminal;
mod tray;

use commands::{emit_visibility, set_window_visible, surface_widget};
use tauri::{Emitter, Manager, RunEvent, WindowEvent};
use tracing_subscriber::prelude::*;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    // A release build is `windows_subsystem = "windows"` (see main.rs) - it
    // has no console, so tracing::info!/warn!/error! previously went to a
    // stdout that doesn't exist anywhere. Log to a real file too (same
    // %LOCALAPPDATA%\NorthstarDevKit app-data folder settings.json already
    // uses), so a failure on a real install - like the sidecar never
    // becoming responsive - leaves an actual trail instead of nothing.
    // The WorkerGuard must outlive the whole run() call (dropping it stops
    // the background flush thread and can silently lose buffered lines),
    // so it's bound here, not thrown away.
    let _log_guard = init_logging();

    run_app();
}

/// Sets up tracing: always to a rotating file under
/// %LOCALAPPDATA%\NorthstarDevKit\logs\devkit.log, plus stdout in debug
/// builds only (harmless no-op in release, where stdout goes nowhere, but
/// keeps `pnpm tauri dev`'s terminal output unchanged). Returns the
/// non-blocking writer's guard, which the caller must keep alive for the
/// whole process lifetime - dropping it stops the flush thread and can
/// silently lose buffered lines.
fn init_logging() -> Option<tracing_appender::non_blocking::WorkerGuard> {
    fn make_env_filter() -> tracing_subscriber::EnvFilter {
        tracing_subscriber::EnvFilter::try_from_default_env()
            .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info"))
    }

    let log_dir = std::env::var_os("LOCALAPPDATA")
        .map(std::path::PathBuf::from)
        .map(|p| p.join("NorthstarDevKit").join("logs"));

    let Some(log_dir) = log_dir else {
        // No LOCALAPPDATA (shouldn't happen on real Windows) - fall back to
        // stdout-only rather than fail startup over a missing log file.
        tracing_subscriber::fmt().with_env_filter(make_env_filter()).init();
        return None;
    };

    if let Err(e) = std::fs::create_dir_all(&log_dir) {
        eprintln!("devkit: could not create log directory {}: {e}", log_dir.display());
        tracing_subscriber::fmt().with_env_filter(make_env_filter()).init();
        return None;
    }

    // Daily rotation with a 14-file retention cap. `rolling::daily` (the
    // one-liner this replaces) has NO max_log_files, so the logs folder grew
    // one file per day forever on a machine that keeps DevKit in the tray -
    // a few hundred stale files after a year, none of them ever read.
    // The `filename_prefix` + no-suffix pairing reproduces `rolling::daily`'s
    // exact naming (`devkit.log.<date>`), which also means the pruner - which
    // only ever deletes files matching the configured prefix/suffix - cleans
    // up files written before this cap existed.
    let file_appender = match tracing_appender::rolling::RollingFileAppender::builder()
        .rotation(tracing_appender::rolling::Rotation::DAILY)
        .filename_prefix("devkit.log")
        .max_log_files(14)
        .build(&log_dir)
    {
        Ok(appender) => appender,
        Err(e) => {
            eprintln!("devkit: could not open rolling log in {}: {e}", log_dir.display());
            tracing_subscriber::fmt().with_env_filter(make_env_filter()).init();
            return None;
        }
    };
    let (non_blocking, guard) = tracing_appender::non_blocking(file_appender);
    let file_layer = tracing_subscriber::fmt::layer()
        .with_writer(non_blocking)
        .with_ansi(false);
    let registry = tracing_subscriber::registry()
        .with(make_env_filter())
        .with(file_layer);

    #[cfg(debug_assertions)]
    registry.with(tracing_subscriber::fmt::layer()).init();
    #[cfg(not(debug_assertions))]
    registry.init();

    Some(guard)
}

/// Attaches the dev-only MCP bridge so an AI agent can drive a running
/// `pnpm tauri dev` session - screenshot the widget, read the DOM, click,
/// and replay `invoke` calls against the real command handlers. See the
/// dependency comment in Cargo.toml for why it is pinned to a rev.
///
/// A no-op unless the optional `mcp` feature is enabled (`pnpm dev:mcp`).
/// With it off the crate is not in the dependency graph at all, so there is
/// nothing to compile out; with it on in a release build the plugin still
/// refuses to open its socket unless `allow_release_builds` is set.
///
/// TCP rather than the default IPC transport because the two halves do not
/// agree on Windows - the TypeScript server hardcodes the pipe name
/// `\\.\pipe\tmp\tauri-mcp.sock` and ignores both its configured path and
/// TAURI_MCP_IPC_PATH, while the Rust side namespaces whatever `socket_path`
/// it was handed. Loopback TCP plus the generated `.token` sidecar avoids
/// that mismatch entirely.
///
/// `capture_rust_logs` is deliberately left at its default (off): it installs
/// a global `log` logger, and init_logging() above already owns global
/// subscriber state. JS console capture is unaffected by that flag, so
/// `query_logs` still sees the frontend.
fn attach_mcp_bridge<R: tauri::Runtime>(builder: tauri::Builder<R>) -> tauri::Builder<R> {
    #[cfg(feature = "mcp")]
    let builder = builder.plugin(tauri_plugin_mcp::init_with_config(
        tauri_plugin_mcp::PluginConfig::new("DevKit".to_string())
            .tcp_localhost(4000)
            // Both windows are the same index.html distinguished by a query
            // param; "widget" is the one an agent almost always means, so it
            // is the fallback target when a tool names no window.
            .default_webview_label("widget".to_string())
            // Tauri keeps no runtime registry of #[tauri::command] handlers,
            // so `manage_ipc(action="commands")` can otherwise only report
            // traffic it has already observed. Keep in sync with the
            // invoke_handler! list in run_app().
            .expose_commands([
                "rpc_call",
                "sidecar_status",
                "sidecar_restart",
                "toggle_window",
                "show_window",
                "set_widget_dock",
                "slide_widget",
                "set_widget_flyout",
                "widget_geometry",
                "register_global_hotkey",
                "terminal_spawn",
                "terminal_write",
                "terminal_resize",
                "terminal_kill",
            ]),
    ));

    builder
}

fn run_app() {
    let builder = tauri::Builder::default()
        // Must be registered before any other plugin/setup work per the
        // plugin's own docs: it needs to intercept a second launch as early
        // as possible.
        .plugin(tauri_plugin_single_instance::init(|app, _argv, _cwd| {
            // A second launch (e.g. clicking the Start Menu icon again)
            // surfaces the widget instead of spawning a duplicate process -
            // mirrors the old widget's named-mutex + named-event behavior.
            // Through `surface_widget`, so it also un-minimizes and slides a
            // collapsed sidebar back out; a bare `set_window_visible` here
            // answered the second launch with an 18px rail.
            if let Err(e) = surface_widget(app) {
                tracing::warn!(error = %e, "second launch could not surface the widget");
            }
        }));

    attach_mcp_bridge(builder)
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_window_state::Builder::default().build())
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            None,
        ))
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(tauri_plugin_process::init())
        // No `with_shortcut`/`with_handler` here on purpose: NOTHING is
        // registered at startup. The frontend calls `register_global_hotkey`
        // once settings load and again whenever the preference changes, and
        // that command owns the whole binding lifecycle - which is also why
        // capabilities/default.json needs no `global-shortcut:*` grants.
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .manage(terminal::TerminalRegistry::default())
        .invoke_handler(tauri::generate_handler![
            commands::rpc_call,
            commands::sidecar_status,
            commands::sidecar_restart,
            commands::toggle_window,
            commands::show_window,
            commands::set_widget_dock,
            commands::slide_widget,
            commands::set_widget_flyout,
            commands::widget_geometry,
            commands::register_global_hotkey,
            terminal::terminal_spawn,
            terminal::terminal_write,
            terminal::terminal_resize,
            terminal::terminal_kill,
        ])
        .setup(|app| {
            let handle = app.handle().clone();
            tracing::info!(version = env!("CARGO_PKG_VERSION"), "devkit starting");

            let resolved = paths::resolve(&handle)?;
            tracing::info!(
                pwsh = %resolved.pwsh.display(),
                script = %resolved.rpc_script.display(),
                cwd = %resolved.sidecar_cwd.display(),
                "resolved sidecar paths"
            );
            let spec = resolved.to_sidecar_spec();

            // Timed separately from "resolved sidecar paths" above: this
            // only measures how long the pwsh.exe process itself took to
            // spawn, NOT how long DevKit.Core.psm1's import inside it takes
            // (PsHost::spawn returns as soon as the child process exists,
            // before the sidecar has necessarily finished importing and
            // started consuming its lane queues - see host.rs). Logged
            // regardless so a slow spawn (vs. a slow-but-spawned sidecar)
            // is at least distinguishable after the fact.
            let spawn_started = std::time::Instant::now();
            let host = tauri::async_runtime::block_on(devkit_host::PsHost::spawn(spec))?;
            tracing::info!(elapsed_ms = spawn_started.elapsed().as_millis(), "sidecar process spawned");
            app.manage(host.clone());

            // Forward every sidecar event (streamed tool output, push
            // notifications from long-running RPC calls) to the frontend
            // as a single Tauri event; `lib/ipc.ts` demuxes by `runId`.
            //
            // NOT `while let Ok(evt) = events.recv().await`: a tokio
            // broadcast receiver that falls behind the 1024-slot ring
            // returns `Err(RecvError::Lagged(n))`, which is NOT a closed
            // channel - the receiver stays perfectly usable and resumes at
            // the oldest still-buffered event. Treating it as termination
            // meant one chatty tool (a build spewing thousands of
            // `tool.output` lines) permanently killed `devkit://event` for
            // the whole session: output stopped mid-run, `tool.finished`
            // never arrived, the Run button spun forever, and every later
            // run was dead until the app restarted. Log and CONTINUE on
            // Lagged; only `Closed` ends the forwarder.
            let mut events = host.subscribe_events();
            let emit_handle = handle.clone();
            tauri::async_runtime::spawn(async move {
                loop {
                    match events.recv().await {
                        Ok(evt) => {
                            if let Err(e) = emit_handle.emit("devkit://event", &evt) {
                                tracing::warn!(error = %e, "failed to forward sidecar event");
                            }
                        }
                        Err(tokio::sync::broadcast::error::RecvError::Lagged(dropped)) => {
                            // Tell the UI too - a run whose output has holes
                            // in it should say so rather than look complete.
                            tracing::warn!(dropped, "sidecar event stream lagged; events dropped");
                            let _ = emit_handle.emit(
                                "devkit://event",
                                serde_json::json!({
                                    "event": "host.lagged",
                                    "data": { "dropped": dropped },
                                }),
                            );
                        }
                        Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                            tracing::info!("sidecar event channel closed; forwarder stopping");
                            break;
                        }
                    }
                }
            });

            tray::build(&handle)?;

            // The widget is DevKit's main face (since 4.0) - show it once
            // setup completes. Windows are created hidden (see
            // tauri.conf.json) so window-state restore + the tray/menu
            // wiring above are ready before first paint. Goes through
            // `set_window_visible` (not a raw `.show()`) so the initial
            // `devkit://visibility` event fires - see that function's doc
            // comment for why `document.hidden` alone can't be trusted here.
            if let Some(widget) = app.get_webview_window("widget") {
                set_window_visible(&widget, true)?;
            }

            Ok(())
        })
        .on_window_event(|window, event| {
            // Closing the widget or control-center via the titlebar hides
            // to tray instead of quitting - the app only fully exits via
            // the tray's Exit item or an explicit process::exit command.
            if let WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
                emit_visibility(window, window.label(), false);
            }
            if window.label() != "widget" {
                return;
            }
            // The geometry helpers all speak `WebviewWindow`; `on_window_event`
            // hands us the plain `Window` behind it.
            let Some(widget) = window.app_handle().get_webview_window("widget") else {
                return;
            };
            match event {
                // Where a user dragging a window edge becomes state: while a
                // flyout tray is out the delta is credited to the TRAY and the
                // sidebar column keeps its width, otherwise to the sidebar.
                // The docked floor (a quarter of the work area) and the
                // re-pinning of the docked edge both fall out of the re-derive
                // this performs - see commands::on_widget_resized.
                WindowEvent::Resized(size) => {
                    commands::on_widget_resized(&widget, *size);
                }
                // tao writes a docked window's min/max `PhysicalSize`
                // straight into WM_GETMINMAXINFO and never rescales it, so
                // the dock has to be re-applied by hand whenever the widget
                // lands on a different monitor or its scale factor changes -
                // otherwise a sidebar docked on a 4K/150% panel keeps that
                // panel's work-area height as BOTH its min and its max after
                // the panel is unplugged. `Moved` is the cheap monitor probe
                // (a docked window only moves when something moved it);
                // `ScaleFactorChanged` is the DPI half and is forced, since
                // the work area can be identical across a scale change.
                WindowEvent::Moved(_) => {
                    commands::revalidate_widget_geometry(&widget, false);
                }
                WindowEvent::ScaleFactorChanged { .. } => {
                    commands::revalidate_widget_geometry(&widget, true);
                }
                _ => {}
            }
        })
        .build(tauri::generate_context!())
        .expect("error while building devkit application")
        .run(|app_handle, event| {
            if let RunEvent::ExitRequested { .. } = event {
                if let Some(host) = app_handle.try_state::<devkit_host::PsHost>() {
                    let host = host.inner().clone();
                    tauri::async_runtime::block_on(host.shutdown());
                }
                terminal::kill_all(app_handle);
            }
        });
}
