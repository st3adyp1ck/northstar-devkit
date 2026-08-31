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

/// True when Admin Mode has taken ownership of Start-with-Windows.
///
/// `Set-DevKitAdminMode.ps1` deletes the HKCU Run value and moves autostart
/// onto its scheduled task's logon trigger - Windows will not auto-start an
/// ELEVATED app from the Run key, so that move is the whole point. But
/// `tauri_plugin_autostart` only ever reads the Run key, so it reported OFF
/// while DevKit really did still start with Windows, and ticking the item
/// wrote the Run value back: a second, NON-elevated autostart racing the
/// elevated task, which single-instance then resolves in whichever order
/// they happen to launch.
///
/// Read from the marker the script already writes, so there is exactly one
/// source of truth and no new contract. Absent, unreadable or malformed all
/// mean "not managed" - this must never be the reason the tray fails to
/// build. `-Off` deletes the marker and hands the Run key back.
fn admin_mode_owns_autostart() -> bool {
    let Some(local) = std::env::var_os("LOCALAPPDATA") else {
        return false;
    };
    let marker = std::path::Path::new(&local)
        .join("NorthstarDevKit")
        .join("admin-mode.json");
    let Ok(text) = std::fs::read_to_string(marker) else {
        return false;
    };
    // Windows PowerShell 5.1's `Set-Content -Encoding UTF8` writes a BOM
    // (PowerShell 7's does not), and the .bat wrapper can land on either.
    // serde_json rejects a leading BOM outright.
    let text = text.trim_start_matches('\u{feff}');
    serde_json::from_str::<serde_json::Value>(text)
        .ok()
        .and_then(|v| v.get("autostartMoved").and_then(|b| b.as_bool()))
        .unwrap_or(false)
}

/// The autostart item's label and whether it accepts clicks, from both
/// sources of truth: the Run key, and Admin Mode's marker.
fn autostart_state(app: &AppHandle) -> (&'static str, bool) {
    if admin_mode_owns_autostart() {
        // Ticked, because the logon trigger really does start DevKit.
        // Greyed, because from here a click could only ever ADD the
        // duplicate - the task's trigger is not ours to remove.
        ("Start with Windows  ✓  (managed by Admin Mode)", false)
    } else {
        (
            autostart_label(app.autolaunch().is_enabled().unwrap_or(false)),
            true,
        )
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

    let (autostart_text, autostart_clickable) = autostart_state(app);
    let start_with_windows = MenuItem::with_id(
        app,
        "toggle_autostart",
        autostart_text,
        autostart_clickable,
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
                // The item is built and refreshed disabled while Admin Mode
                // owns autostart, so this should be unreachable then - but a
                // stale menu is cheap to guard against and writing the Run
                // value back here is exactly the duplicate-autostart bug.
                if admin_mode_owns_autostart() {
                    tracing::info!(
                        "ignoring Start-with-Windows toggle: Admin Mode owns autostart (use Set-DevKitAdminMode.ps1 -Off)"
                    );
                } else {
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
                    // Admin Mode can be switched on or off from the Control
                    // Center while the app runs, so the enabled state is
                    // re-read here too, not just the label.
                    let (text, clickable) = autostart_state(tray.app_handle());
                    if let Err(e) = autostart_on_open.set_text(text) {
                        tracing::warn!(error = %e, "failed to refresh the autostart menu label");
                    }
                    if let Err(e) = autostart_on_open.set_enabled(clickable) {
                        tracing::warn!(error = %e, "failed to refresh the autostart menu enabled state");
                    }
                }
                _ => {}
            }
        })
        .build(app)?;

    Ok(())
}
