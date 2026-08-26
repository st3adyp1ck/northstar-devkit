mod commands;
mod paths;
mod terminal;
mod tray;

use commands::{emit_visibility, set_window_visible};
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

    let file_appender = tracing_appender::rolling::daily(&log_dir, "devkit.log");
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

fn run_app() {
    tauri::Builder::default()
        // Must be registered before any other plugin/setup work per the
        // plugin's own docs: it needs to intercept a second launch as early
        // as possible.
        .plugin(tauri_plugin_single_instance::init(|app, _argv, _cwd| {
            // A second launch (e.g. clicking the Start Menu icon again)
            // surfaces the widget instead of spawning a duplicate process -
            // mirrors the old widget's named-mutex + named-event behavior.
            if let Some(w) = app.get_webview_window("widget") {
                let _ = set_window_visible(&w, true);
            }
        }))
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_window_state::Builder::default().build())
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            None,
        ))
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(tauri_plugin_process::init())
        .manage(terminal::TerminalRegistry::default())
        .invoke_handler(tauri::generate_handler![
            commands::rpc_call,
            commands::sidecar_status,
            commands::sidecar_restart,
            commands::toggle_window,
            commands::show_window,
            commands::set_widget_dock,
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
            let mut events = host.subscribe_events();
            let emit_handle = handle.clone();
            tauri::async_runtime::spawn(async move {
                while let Ok(evt) = events.recv().await {
                    if let Err(e) = emit_handle.emit("devkit://event", &evt) {
                        tracing::warn!(error = %e, "failed to forward sidecar event");
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
            // Hard floor on the widget's size, enforced at the event level:
            // the config's minWidth/minHeight SHOULD cover this, but a
            // user-reported real-machine case still shrank the undecorated
            // window below them (tao's custom resize borders + restored
            // window-state interact unreliably here), which breaks the UI
            // layout. Re-clamp after any resize that lands under the floor.
            if window.label() == "widget" {
                if let WindowEvent::Resized(size) = event {
                    let scale = window.scale_factor().unwrap_or(1.0);
                    // Absolute floor only - per-mode minimums are governed
                    // by set_min_size in commands::set_widget_dock (docked:
                    // 380 wide, work-area height; floating: 480x560). This
                    // backstop must sit at the LOWEST legitimate width or
                    // it would fight a narrowed docked sidebar forever.
                    let min_w = (380.0 * scale) as u32;
                    let min_h = (560.0 * scale) as u32;
                    if size.width < min_w || size.height < min_h {
                        let _ = window.set_size(tauri::PhysicalSize::new(
                            size.width.max(min_w),
                            size.height.max(min_h),
                        ));
                    }
                }
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
