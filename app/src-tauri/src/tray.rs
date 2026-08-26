//! System tray icon + menu. Replaces the widget's hand-rolled tray code
//! (balloon hints, dark right-click menu, Explorer-restart resilience) with
//! `tauri::tray` + the single-instance plugin, which together give us that
//! behavior for free.

use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Manager};
use tauri_plugin_autostart::ManagerExt;

use crate::commands::{set_window_visible, toggle_widget};

/// Text for the autostart entry. A plain `MenuItem` has no native check
/// state, so the mark lives in the label.
fn autostart_label(enabled: bool) -> &'static str {
    if enabled {
        "Start with Windows  ✓"
    } else {
        "Start with Windows"
    }
}

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
        autostart_label(autostart_enabled),
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

    // The autostart item's checkmark is baked into its TEXT (there is no
    // native check state on a plain MenuItem), so it has to be rewritten
    // every time the setting flips - the label used to be computed once here
    // at tray build and never touched again, which meant the "✓" reflected
    // whatever autostart was when DevKit started and then silently lied for
    // the rest of the session. Keep a handle (MenuItem is a cheap Arc clone)
    // and call set_text from the menu-event handler.
    let autostart_item = start_with_windows.clone();
    // A second handle, for the right-click that OPENS the menu. Our own toggle
    // is not the only thing that can change autostart: Task Manager's Startup
    // tab and Settings > Apps > Startup flip the same registry value behind
    // our back, and a label refreshed only by our own handler would go on
    // claiming the state DevKit last set. Re-reading on the button-down that
    // precedes the menu appearing costs one registry read per right-click.
    let autostart_on_open = start_with_windows.clone();

    TrayIconBuilder::with_id("devkit-tray")
        .icon(icon)
        .tooltip("Northstar DevKit")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(move |app, event| match event.id.as_ref() {
            // NOT a raw show/hide: a docked widget can be parked on its rail
            // ~97% off the monitor edge, and a minimized one still reports
            // itself visible - both of which made this item surface a sliver
            // (or hide a window that was not on screen in the first place).
            // `toggle_widget` is the one path every "show the widget" gesture
            // shares; see commands::surface_widget.
            "show_hide" => {
                if let Err(e) = toggle_widget(app) {
                    tracing::warn!(error = %e, "tray menu could not toggle the widget");
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
                // Re-read rather than assume `!enabled`: the toggle above can
                // fail (registry/Startup-folder permissions), and a label that
                // claims a state the OS never accepted is worse than no
                // feedback at all.
                let now_enabled = mgr.is_enabled().unwrap_or(enabled);
                if let Err(e) = autostart_item.set_text(autostart_label(now_enabled)) {
                    tracing::warn!(error = %e, "failed to update the autostart menu label");
                }
            }
            "quit" => {
                app.exit(0);
            }
            _ => {}
        })
        .on_tray_icon_event(move |tray, event| {
            let TrayIconEvent::Click {
                button,
                button_state,
                ..
            } = event
            else {
                return;
            };
            match (button, button_state) {
                // Same single path as the menu item above.
                (MouseButton::Left, MouseButtonState::Up) => {
                    if let Err(e) = toggle_widget(tray.app_handle()) {
                        tracing::warn!(error = %e, "tray click could not toggle the widget");
                    }
                }
                // The menu itself is shown by the platform on button-up (see
                // `show_menu_on_left_click(false)` above), so the label is
                // refreshed on the way down, before anything is drawn.
                (MouseButton::Right, MouseButtonState::Down) => {
                    let enabled = tray.app_handle().autolaunch().is_enabled().unwrap_or(false);
                    if let Err(e) = autostart_on_open.set_text(autostart_label(enabled)) {
                        tracing::warn!(error = %e, "failed to refresh the autostart menu label");
                    }
                }
                _ => {}
            }
        })
        .build(app)?;

    Ok(())
}
