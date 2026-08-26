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

/// Docks the widget as a REAL sidebar, or releases it back to a floating
/// window. Backs the widgetDockMode setting ("Left" | "Right" |
/// "Floating"):
///
/// - Left/Right: the widget becomes a fixed sidebar - full work-area
///   height (taskbar-aware via Monitor::work_area), flush against that
///   edge, and NOT resizable (set_resizable(false) - combined with the
///   frontend removing the titlebar's drag region while docked, the
///   window genuinely cannot be moved or shrunk off its edge).
/// - Floating: resizable again, restored to the default 380x720 logical
///   size, position left wherever it is.
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

    // Sidebar width: 500 logical regardless of whatever the user had
    // resized the floating window to - a dock is a fixed-width surface,
    // and this also self-heals any window-state that was shrunk below the
    // intended minimum. 500 is the measured width at which the four
    // System gauges (4 x 108px gauge slots + panel and body padding)
    // fit on one row without clipping; 380 demonstrably cut off the
    // fourth gauge.
    let width = (500.0 * scale) as u32;
    let height = work.size.height;

    let x = if side.eq_ignore_ascii_case("left") {
        work.position.x
    } else if side.eq_ignore_ascii_case("right") {
        work.position.x + work.size.width as i32 - width as i32
    } else {
        return Err(format!(
            "unknown dock side '{side}' (expected Left, Right, or Floating)"
        ));
    };

    // Order matters: sizing while still resizable, then locking. (A
    // non-resizable window ignores set_size on some platforms.)
    window.set_resizable(true).map_err(|e| e.to_string())?;
    window
        .set_size(tauri::PhysicalSize::new(width, height))
        .map_err(|e| e.to_string())?;
    window
        .set_position(tauri::PhysicalPosition::new(x, work.position.y))
        .map_err(|e| e.to_string())?;
    window.set_resizable(false).map_err(|e| e.to_string())?;
    Ok(())
}
