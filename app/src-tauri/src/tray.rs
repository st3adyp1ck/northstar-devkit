//! System tray icon + menu. Replaces the widget's hand-rolled tray code
//! (balloon hints, dark right-click menu, Explorer-restart resilience) with
//! `tauri::tray` + the single-instance plugin, which together give us that
//! behavior for free.

use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Manager};
use tauri_plugin_autostart::ManagerExt;

use crate::commands::{set_window_visible, toggle_window_visibility};

pub fn build(app: &AppHandle) -> tauri::Result<()> {
    let show_hide = MenuItem::with_id(app, "show_hide", "Show/Hide Widget", true, None::<&str>)?;
    let open_control_center = MenuItem::with_id(
        app,
        "open_control_center",
        "Open DevKit Control Center",
        true,
        None::<&str>,
    )?;
    let separator = PredefinedMenuItem::separator(app)?;

    let autostart_enabled = app.autolaunch().is_enabled().unwrap_or(false);
    let start_with_windows = MenuItem::with_id(
        app,
        "toggle_autostart",
        if autostart_enabled {
            "Start with Windows  ✓"
        } else {
            "Start with Windows"
        },
        true,
        None::<&str>,
    )?;

    let quit = MenuItem::with_id(app, "quit", "Exit", true, None::<&str>)?;

    let menu = Menu::with_items(
        app,
        &[
            &show_hide,
            &open_control_center,
            &separator,
            &start_with_windows,
            &separator,
            &quit,
        ],
    )?;

    let icon = app
        .default_window_icon()
        .cloned()
        .expect("bundle.icon must be configured");

    TrayIconBuilder::with_id("devkit-tray")
        .icon(icon)
        .tooltip("Northstar DevKit")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| match event.id.as_ref() {
            "show_hide" => {
                if let Some(w) = app.get_webview_window("widget") {
                    let _ = toggle_window_visibility(&w);
                }
            }
            "open_control_center" => {
                if let Some(w) = app.get_webview_window("control-center") {
                    let _ = set_window_visible(&w, true);
                }
            }
            "toggle_autostart" => {
                let mgr = app.autolaunch();
                let enabled = mgr.is_enabled().unwrap_or(false);
                let result = if enabled { mgr.disable() } else { mgr.enable() };
                if let Err(e) = result {
                    tracing::warn!(error = %e, "failed to toggle autostart");
                }
            }
            "quit" => {
                app.exit(0);
            }
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                let app = tray.app_handle();
                if let Some(w) = app.get_webview_window("widget") {
                    let _ = toggle_window_visibility(&w);
                }
            }
        })
        .build(app)?;

    Ok(())
}
