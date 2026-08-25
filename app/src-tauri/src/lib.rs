mod commands;
mod paths;
mod terminal;
mod tray;

use commands::{emit_visibility, set_window_visible};
use tauri::{Emitter, Manager, RunEvent, WindowEvent};

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

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
            terminal::terminal_spawn,
            terminal::terminal_write,
            terminal::terminal_resize,
            terminal::terminal_kill,
        ])
        .setup(|app| {
            let handle = app.handle().clone();

            let resolved = paths::resolve(&handle)?;
            tracing::info!(
                pwsh = %resolved.pwsh.display(),
                script = %resolved.rpc_script.display(),
                "resolved sidecar paths"
            );
            let spec = resolved.to_sidecar_spec();

            let host = tauri::async_runtime::block_on(devkit_host::PsHost::spawn(spec))?;
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
