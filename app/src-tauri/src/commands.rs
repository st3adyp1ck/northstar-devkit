//! Tauri commands exposed to the frontend. Deliberately thin: `rpc_call` is
//! a single generic passthrough to the PowerShell sidecar so adding a new
//! RPC method (a new panel, a new tool) never requires touching Rust - only
//! `core/Invoke-DevKitRpc.ps1`'s method table and the frontend caller. See
//! `lib/ipc.ts` on the frontend side for the typed wrapper.

use devkit_host::PsHost;
use serde_json::Value;
use tauri::{Emitter, Manager, Runtime, State};

#[tauri::command]
pub async fn rpc_call(
    host: State<'_, PsHost>,
    method: String,
    params: Option<Value>,
) -> Result<Value, String> {
    host.call(&method, params).await.map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn sidecar_status(host: State<'_, PsHost>) -> Result<bool, String> {
    Ok(host.is_alive())
}

#[tauri::command]
pub async fn sidecar_restart(host: State<'_, PsHost>) -> Result<(), String> {
    host.shutdown().await;
    host.ensure_alive().await.map_err(|e| e.to_string())
}

/// Shows+focuses or hides `window`, then emits `devkit://visibility` with
/// `{ label, visible }` so the frontend's `useVisibility` hook has an
/// authoritative signal to pair with (or, if it turns out to be needed,
/// stand in for) `document.hidden`.
///
/// This isn't belt-and-suspenders paranoia: `WebviewWindow::hide()`/`show()`
/// only move the top-level OS window (tauri-runtime-wry's
/// `WindowMessage::Show`/`Hide` call `tao::Window::set_visible`, full stop).
/// They never call the embedded WebView2 controller's own `SetIsVisible`
/// (the API wry's *own* `WebView::set_visible` does call, and the one
/// Microsoft's WebView2 docs say is what actually drives the page's
/// `document.visibilityState`) - that only ever happens once, at webview
/// creation, from the window's initial visibility. Since every window here
/// is created hidden (see tauri.conf.json) and then shown via this
/// function, `document.hidden` can easily end up permanently stuck rather
/// than tracking reality. Route every show/hide through here (see
/// `toggle_window_visibility` below for the tray/menu paths) rather than
/// raw `window.show()`/`hide()` so this signal stays complete.
pub fn set_window_visible<R: Runtime>(
    window: &tauri::WebviewWindow<R>,
    visible: bool,
) -> Result<(), String> {
    if visible {
        window.show().map_err(|e| e.to_string())?;
        window.set_focus().map_err(|e| e.to_string())?;
    } else {
        window.hide().map_err(|e| e.to_string())?;
    }
    emit_visibility(window, window.label(), visible);
    Ok(())
}

/// Toggles a window between shown+focused and hidden - used by the tray
/// "Show/Hide" entry, its left-click handler, and the widget's own hide
/// button so clicking the tray icon again always surfaces it, even on
/// shells that hide new tray icons by default.
pub fn toggle_window_visibility<R: Runtime>(window: &tauri::WebviewWindow<R>) -> Result<(), String> {
    let visible = window.is_visible().map_err(|e| e.to_string())?;
    set_window_visible(window, !visible)
}

/// Emits the `devkit://visibility` event (see `set_window_visible` above).
/// Broadcast app-wide like every other event here (`devkit://event`,
/// `devkit://terminal`) rather than scoped with `emit_to`, so the frontend
/// filters by the `label` field - `useVisibility` only acts on events for
/// its own window.
pub(crate) fn emit_visibility<R: Runtime, E: Emitter<R>>(emitter: &E, label: &str, visible: bool) {
    let _ = emitter.emit(
        "devkit://visibility",
        serde_json::json!({ "label": label, "visible": visible }),
    );
}

#[tauri::command]
pub async fn toggle_window(app: tauri::AppHandle, label: String) -> Result<(), String> {
    let Some(window) = app.get_webview_window(&label) else {
        return Err(format!("no window with label '{label}'"));
    };
    toggle_window_visibility(&window)
}

#[tauri::command]
pub async fn show_window(app: tauri::AppHandle, label: String) -> Result<(), String> {
    let Some(window) = app.get_webview_window(&label) else {
        return Err(format!("no window with label '{label}'"));
    };
    set_window_visible(&window, true)
}

/// Docks the widget as a real sidebar, or releases it back to a floating
/// window. Backs the widgetDockMode setting ("Left" | "Right" |
/// "Floating"):
///
/// - Left/Right: full work-area height (taskbar-aware via
///   Monitor::work_area), flush against that edge, vertically LOCKED but
///   horizontally resizable: min and max size share the work-area height
///   (so only the width can change - dragging the inner border widens or
///   narrows the sidebar while the outer edge stays anchored, which is
///   just how edge-resizing works), width floored at 380 logical and
///   capped at half the work area. Combined with the frontend removing
///   the titlebar's drag region while docked, the window cannot be MOVED
///   off its edge - only width-adjusted. The current width is kept when
///   re-docking (window-state restores it across launches, so a user's
///   chosen sidebar width sticks); a fresh install starts at the 500
///   default from tauri.conf.json.
/// - Floating: normal window again - min restored to 480x560 logical, no
///   max, size restored to the 500x720 default.
///
/// Rust-side (not the JS window API) so no ACL grants are needed and the
/// monitor math stays in one place. Physical pixels throughout so DPI
/// scale factors don't skew anything.
#[tauri::command]
pub async fn set_widget_dock(app: tauri::AppHandle, side: String) -> Result<(), String> {
    let Some(window) = app.get_webview_window("widget") else {
        return Err("widget window not found".into());
    };

    if side.eq_ignore_ascii_case("floating") {
        window.set_resizable(true).map_err(|e| e.to_string())?;
        window
            .set_max_size(None::<tauri::LogicalSize<f64>>)
            .map_err(|e| e.to_string())?;
        window
            .set_min_size(Some(tauri::LogicalSize::new(480.0, 560.0)))
            .map_err(|e| e.to_string())?;
        window
            .set_size(tauri::LogicalSize::new(500.0, 720.0))
            .map_err(|e| e.to_string())?;
        return Ok(());
    }

    let monitor = window
        .current_monitor()
        .map_err(|e| e.to_string())?
        .ok_or("no monitor for widget window")?;
    let scale = monitor.scale_factor();
    let work = monitor.work_area();

    let min_width = (380.0 * scale) as u32;
    let max_width = work.size.width / 2;
    // Keep whatever width the window currently has (a prior resize, or
    // window-state's restore of one), clamped into the dock's range.
    let current = window.outer_size().map_err(|e| e.to_string())?;
    let width = current.width.clamp(min_width, max_width);
    let height = work.size.height;

    let is_left = side.eq_ignore_ascii_case("left");
    if !is_left && !side.eq_ignore_ascii_case("right") {
        return Err(format!(
            "unknown dock side '{side}' (expected Left, Right, or Floating)"
        ));
    }
    let x = if is_left {
        work.position.x
    } else {
        work.position.x + work.size.width as i32 - width as i32
    };

    window.set_resizable(true).map_err(|e| e.to_string())?;
    // Equal min/max heights lock the vertical axis while the width stays
    // free between the floor and cap - per-axis resizing without any
    // per-axis API.
    window
        .set_min_size(Some(tauri::PhysicalSize::new(min_width, height)))
        .map_err(|e| e.to_string())?;
    window
        .set_max_size(Some(tauri::PhysicalSize::new(max_width, height)))
        .map_err(|e| e.to_string())?;
    window
        .set_size(tauri::PhysicalSize::new(width, height))
        .map_err(|e| e.to_string())?;
    window
        .set_position(tauri::PhysicalPosition::new(x, work.position.y))
        .map_err(|e| e.to_string())?;
    Ok(())
}
