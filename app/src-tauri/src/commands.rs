//! Tauri commands exposed to the frontend. Deliberately thin: `rpc_call` is
//! a single generic passthrough to the PowerShell sidecar so adding a new
//! RPC method (a new panel, a new tool) never requires touching Rust - only
//! `core/Invoke-DevKitRpc.ps1`'s method table and the frontend caller. See
//! `lib/ipc.ts` on the frontend side for the typed wrapper.
//!
//! The other half of this module is widget window geometry: docking,
//! sliding, flyouts, resizing. All of it lives in Rust (not the JS window
//! API) so no ACL grants are needed and the monitor math stays in one place;
//! physical pixels throughout so DPI scale factors don't skew anything. See
//! the banner above `DockSide` for the state machine that owns it.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::Duration;

use devkit_host::PsHost;
use serde_json::Value;
use tauri::{Emitter, Manager, PhysicalPosition, PhysicalSize, Runtime, State};
use tauri_plugin_global_shortcut::{GlobalShortcutExt, Shortcut, ShortcutEvent, ShortcutState};

/// Ceiling for a `tool.*` call, which is a completely different animal from
/// every other RPC method.
///
/// `paths.rs` gives the sidecar a 60s default timeout, sized for "a panel's
/// data query, plus headroom for the cold `DevKit.Core.psm1` import on first
/// launch". That is the right number for `git.*`, `mcp.*`, `metrics.*` and
/// friends - but `tool.run` shells out to catalog scripts the docs
/// themselves describe as "10-30+ minutes": `Repair-SystemFiles` runs
/// `sfc /scannow` and then DISM, `Reset-WindowsUpdate` stops services and
/// re-registers components, `Docker-Nuke` prunes whole image stores,
/// `Update-AiClis` npm-installs a pile of CLIs.
///
/// Timing those out at 60s was not merely cosmetic: the call errored, the UI
/// reported failure and unsubscribed from the run's events, but the tool
/// kept going, and since the sidecar routes every `tool.*` method to its
/// single `tool` lane (see `Get-DevKitRpcLaneForMethod`), that lane stayed
/// occupied - so every later `tool.run` queued invisibly behind the
/// abandoned one and timed out too. One long tool poisoned the session.
///
/// 6 hours is deliberately far past any plausible real tool: this timeout
/// exists only as a last-resort leak guard, not as a UX deadline. It costs
/// nothing to keep it generous because the genuine failure modes resolve
/// long before it - a dead sidecar fails every pending request immediately
/// (`PsHost`'s reader task drains the pending map with `SidecarDisconnected`
/// on EOF), and the user can always cancel a run from the UI. Non-`tool.*`
/// methods keep the 60s default, where a hang really is a bug worth
/// surfacing fast.
const TOOL_CALL_TIMEOUT: Duration = Duration::from_secs(6 * 60 * 60);

/// The docked sidebar's default AND minimum width is one quarter of the
/// monitor's work area - the owner's spec verbatim: "make sure our default and
/// smallest size of the devkit ui is 1/4th of the screen. adjustable bigger if
/// wanted." So there is no fixed logical floor any more, and no ceiling short
/// of the work area itself.
///
/// One documented exception, this constant. Below roughly a 1280-logical-px
/// work area a quarter stops being a usable sidebar (a quarter of a 1024-wide
/// panel is 256 logical px - narrower than a single gauge row), so the
/// absolute floor takes over down there. At or above 1280 logical px the
/// quarter is strictly the larger of the two and this never binds: a 1366px
/// laptop quarters to 341, comfortably past it. Both are finally capped by the
/// work area, so the floor can never climb above the ceiling.
const WIDGET_ABS_MIN_WIDTH_LOGICAL: f64 = 320.0;

/// Narrowest a flyout tray may be dragged down to. While a tray is out the
/// window's own minimum width becomes `sidebar + this`, which is precisely
/// what makes dragging the free outer edge resize the TRAY and leave the
/// sidebar column at the width the user chose for it.
const FLYOUT_MIN_WIDTH_LOGICAL: f64 = 200.0;

/// Fallback width of the sliver left on screen when the docked widget slides
/// off its edge.
///
/// A fallback only, and NOT `preferences.railWidth` - that setting sizes the
/// in-window ICON TAB RAIL (`--flyout-rail-w`), which is a completely
/// different strip that lives INSIDE the sidebar's own width. The sliver is
/// `.widget-rail` in WidgetApp.css, and its single owner is
/// `WIDGET_RAIL_LOGICAL` in WidgetApp.tsx: that constant sets the CSS
/// `--sliver-width` custom property AND is passed to `slide_widget` as
/// `railWidth`, so the glass the user sees and the gap Rust parks are the same
/// number by construction. (The CSS divides it by `--ui-scale` first - the
/// widget root carries a `zoom`, so a raw 18px rail RENDERS at 18 * uiScale
/// logical px, which is not what Rust reserves. Same idiom as
/// `--flyout-rail-w`.)
///
/// This constant exists solely so a slide arriving before settings load - or
/// after a webview reload, before the frontend has re-sent it - still parks
/// the window somewhere grabbable. Keep it equal to `WIDGET_RAIL_LOGICAL`.
const RAIL_FALLBACK_LOGICAL: f64 = 18.0;

/// Floating-mode minimum + default size (mirrors `tauri.conf.json`).
const FLOAT_MIN_WIDTH_LOGICAL: f64 = 480.0;
const FLOAT_MIN_HEIGHT_LOGICAL: f64 = 560.0;
const FLOAT_WIDTH_LOGICAL: f64 = 500.0;
const FLOAT_HEIGHT_LOGICAL: f64 = 720.0;

/// Monotonic generation shared by EVERY widget window animation (slide,
/// flyout) and every instantaneous re-position (dock, float). Each new
/// operation bumps it, and any in-flight animation task aborts as soon as it
/// notices it no longer owns the latest generation.
///
/// It has to be shared across all of them, not just slide-vs-slide: a slide
/// takes ~200ms, so re-docking to the other edge mid-slide used to leave the
/// slide task still stepping `set_position` toward the OLD edge's target,
/// with its final `set_position` landing after the dock's - window parked on
/// the wrong edge while the app believed otherwise.
static SLIDE_GEN: AtomicU64 = AtomicU64::new(0);

/// True while an animation task owns the window. Suppresses BOTH the
/// monitor-change revalidation in `lib.rs` (a mid-slide window straddles a
/// monitor boundary and `current_monitor()` legitimately flips, which would
/// otherwise snap the widget back to the edge mid-glide) and the user-resize
/// accounting in `on_widget_resized` (our own animation frames arrive as
/// `Resized` events and are emphatically not the user dragging an edge).
static ANIM_ACTIVE: AtomicBool = AtomicBool::new(false);

/// Debounce generation for `devkit://widget-geometry`. See
/// `schedule_geometry_emit`.
static GEOMETRY_EMIT_GEN: AtomicU64 = AtomicU64::new(0);

/// The accelerator currently registered as the global hotkey, so
/// `register_global_hotkey` can unbind it before binding a new one.
static HOTKEY_ACCEL: Mutex<Option<String>> = Mutex::new(None);

#[tauri::command]
pub async fn rpc_call(
    host: State<'_, PsHost>,
    method: String,
    params: Option<Value>,
) -> Result<Value, String> {
    // See TOOL_CALL_TIMEOUT: the `tool` lane runs catalog scripts measured
    // in tens of minutes, everything else is a sub-second query.
    let result = if method.starts_with("tool.") {
        host.call_with_timeout(&method, params, TOOL_CALL_TIMEOUT).await
    } else {
        host.call(&method, params).await
    };
    result.map_err(|e| e.to_string())
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
    if label == "widget" {
        return toggle_widget(&app);
    }
    let Some(window) = app.get_webview_window(&label) else {
        return Err(format!("no window with label '{label}'"));
    };
    toggle_window_visibility(&window)
}

#[tauri::command]
pub async fn show_window(app: tauri::AppHandle, label: String) -> Result<(), String> {
    // The widget is never just "shown": a docked one can be parked on its rail
    // ~97% off the monitor edge, so showing it without un-collapsing surfaces
    // an 18-logical-px sliver. See `surface_widget`.
    if label == "widget" {
        return surface_widget(&app);
    }
    let Some(window) = app.get_webview_window(&label) else {
        return Err(format!("no window with label '{label}'"));
    };
    set_window_visible(&window, true)
}

/// The ONE way anything brings the widget to the user.
///
/// Showing the widget is three things, not one, and for a long time only the
/// global hotkey did all three - so the tray icon's left click, the tray menu's
/// "Show/Hide Widget", the command palette's "Show Widget" and a second launch
/// of the executable each surfaced a window that was minimized, or parked off
/// its edge, or both, and left the user staring at a sliver. Rather than
/// repeat the fix in four places, every one of those paths now lands here:
///
///  1. un-minimize, so the window has a real rect again;
///  2. show + focus (via `set_window_visible`, which also emits
///     `devkit://visibility`);
///  3. un-collapse, if it is a docked sidebar sitting on its rail.
///
/// Step 3 needs no frontend round-trip: Rust owns `collapsed` in `WidgetState`,
/// so it can drive the same glide `slide_widget` would. The frontend finds out
/// the way it finds out about every other geometry change - the
/// `devkit://widget-geometry` payload carries `collapsed`, and WidgetApp
/// mirrors its React state from it.
pub fn surface_widget(app: &tauri::AppHandle) -> Result<(), String> {
    let Some(window) = app.get_webview_window("widget") else {
        return Err("widget window not found".into());
    };
    if is_iconic(&window) {
        window.unminimize().map_err(|e| e.to_string())?;
    }
    set_window_visible(&window, true)?;

    let st = widget_state();
    if st.collapsed {
        if let WidgetMode::Docked(side) = st.mode {
            let generation = claim_generation();
            {
                let mut guard = WIDGET.lock().unwrap_or_else(|e| e.into_inner());
                guard.collapsed = false;
            }
            apply_docked(&window, side, generation, true)?;
        } else {
            // Collapsed but no longer docked: nothing parks a floating window
            // on a rail, so this is stale bookkeeping - clear it rather than
            // leave the frontend rendering a rail over a normal window.
            let mut guard = WIDGET.lock().unwrap_or_else(|e| e.into_inner());
            guard.collapsed = false;
        }
    }
    // Unconditional, and deliberately not left to the glide's own landing
    // emit: the frontend needs `collapsed: false` NOW so the rail stops
    // claiming the pointer, not 200ms later.
    emit_widget_geometry(&window);
    Ok(())
}

/// Show/hide toggle for the WIDGET specifically - the tray icon's left click
/// and its "Show/Hide Widget" item.
///
/// Not `toggle_window_visibility`: a minimized window still reports
/// `is_visible() == true` on Windows, so the plain toggle answered a tray click
/// on a minimized widget by HIDING it, and the next click showed it back in the
/// taskbar rather than on screen. Minimized counts as not-shown here, and the
/// show half goes through `surface_widget` like every other show path.
pub fn toggle_widget(app: &tauri::AppHandle) -> Result<(), String> {
    let Some(window) = app.get_webview_window("widget") else {
        return Err("widget window not found".into());
    };
    let shown = window.is_visible().map_err(|e| e.to_string())? && !is_iconic(&window);
    if shown {
        set_window_visible(&window, false)
    } else {
        surface_widget(app)
    }
}


// ---------------------------------------------------------------------------
// Widget geometry
//
// ONE state machine owns the widget window. `WidgetState` holds
// (mode, base_width, flyout_width, collapsed, rail_width); `derive_rect` turns
// that plus the monitor into the COMPLETE window rect and its min/max bounds;
// `apply_docked` is the only thing that talks to the OS about any of it.
//
// Every command mutates the state and re-derives the whole rect. Nothing
// nudges the window by a delta, and - the important half - nothing infers the
// sidebar's own width back out of the live OS window. That inference is what
// used to let the stored base width and the installed bounds drift apart (a
// flyout still open when a dock re-apply landed, an animation superseded
// mid-glide, a window-state restore of a width that already had a tray baked
// into it) until the window sat pinned between a min and a max that described
// nothing: the reported "the width of both the devkit and the github tray were
// wrong and it wont let me resize either, its like jammed".
//
// PHYSICAL pixels throughout. The frontend thinks in logical px, so every
// value crossing that boundary - command arguments coming in, the
// `devkit://widget-geometry` payload going out - is converted by the monitor's
// scale factor at that boundary and nowhere else. tao writes min/max
// `PhysicalSize` straight into WM_GETMINMAXINFO and never rescales them on a
// DPI change, which is why `revalidate_widget_geometry` exists at all.
//
// COORDINATE SPACES. Physical px is only half the unit story: on Windows this
// window has TWO rects, and the runtime APIs are split between them.
//
// `decorations: false` + `shadow: true` + `resizable: true` (tauri.conf.json)
// makes this an `undecorated_with_shadows` window, and tao's WM_NCCALCSIZE
// still insets the CLIENT rect inside the WINDOW rect - by
// SM_CXSIZEFRAME + SM_CXPADDEDBORDER on left/right/bottom and round(dpi/96) on
// top (tao 0.35.3 event_loop.rs, `calculate_window_insets`). On a 2560x1600
// @150% panel that is 22 physical px of width and 13 of height. The inset is
// invisible - it is the resize grab margin and the DWM shadow - so the glass
// the user sees is the CLIENT rect, not the window rect.
//
//   outer_position(), outer_size()             -> OUTER (GetWindowRect)
//   inner_position(), inner_size()             -> CLIENT
//   set_position                               -> OUTER (set_outer_position)
//   set_size                                   -> CLIENT (set_inner_size, which
//        adds the measured offset back before SetWindowPos)
//   set_min_size / set_max_size                -> OUTER. They store an inner
//        constraint, but WM_GETMINMAXINFO emits it as ptMin/MaxTrackSize after
//        `adjust_size(.., is_decorated = false)`, which strips WS_CAPTION and
//        WS_SIZEBOX and therefore adjusts by nothing - so the number lands
//        verbatim as an OUTER track size.
//   WindowEvent::Resized (WM_SIZE lParam)      -> CLIENT
//
// THIS MODULE'S MODEL IS CLIENT SPACE, deliberately: the client rect is the
// visible glass, so "a quarter of the work area" means a quarter of what the
// user can see, the collapsed sliver is exactly as wide as the CSS rail that
// draws it, and a docked edge is flush with the monitor edge instead of
// standing 11px off it. `FrameInset` is the ONE conversion, applied at the
// three OUTER-space call sites (`set_position`, `set_min_size`, `set_max_size`)
// and nowhere else, and `WidgetRect` is documented as client throughout.
//
// The frontend persists `preferences.widgetSavedWidth` from `innerSize()` -
// the SAME space `set_widget_dock` reads it back into. That identity is what
// makes N launches with no user resize leave the stored width unchanged;
// mixing the two spaces made every launch add one frame inset to the sidebar,
// permanently.
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum DockSide {
    Left,
    Right,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum WidgetMode {
    Floating,
    Docked(DockSide),
}

/// Everything the dock math needs about the monitor the sidebar lives on,
/// resolved once per operation. All fields are PHYSICAL pixels.
#[derive(Clone, Copy, Debug)]
pub(crate) struct DockGeometry {
    scale: f64,
    work_x: i32,
    work_y: i32,
    work_w: u32,
    work_h: u32,
    /// The quarter-screen floor. Guaranteed `>= 1` and `<= max_width`.
    min_width: u32,
    /// The work area itself: the sidebar may be dragged as wide as the screen.
    max_width: u32,
    /// Fingerprint of (scale, work area). Never 0, so 0 can mean "none
    /// stored". Compared to detect a monitor or DPI change.
    signature: u64,
}

/// The single source of truth for the widget window's shape. PHYSICAL px.
#[derive(Clone, Copy, Debug)]
struct WidgetState {
    mode: WidgetMode,
    /// The sidebar column's own width.
    ///
    /// NEVER includes the flyout tray, and never includes the in-window tab
    /// rail either: the rail is drawn INSIDE this width, so adding or
    /// subtracting a rail anywhere in this module is a bug by construction -
    /// it is exactly what left the window a rail wider than it started after a
    /// tray closed ("upon closing it the main ui gets bigger like its shifting
    /// the size of the right icon bar width"). The only rail measurement Rust
    /// legitimately holds is `rail_width` below, and it is used for one thing:
    /// how much of a collapsed window to leave on screen.
    base_width: u32,
    /// The open tray's width, 0 when none is out.
    flyout_width: u32,
    collapsed: bool,
    /// Sliver to leave on screen while collapsed. 0 means "the frontend has
    /// not told us yet" - see `RAIL_FALLBACK_LOGICAL`.
    rail_width: u32,
    /// The monitor the numbers above were last derived against.
    monitor: Option<DockGeometry>,
}

static WIDGET: Mutex<WidgetState> = Mutex::new(WidgetState {
    mode: WidgetMode::Floating,
    base_width: 0,
    flyout_width: 0,
    collapsed: false,
    rail_width: 0,
    monitor: None,
});

impl WidgetState {
    /// The collapsed sliver in physical px.
    fn rail_px(&self, g: &DockGeometry) -> u32 {
        if self.rail_width > 0 {
            self.rail_width
        } else {
            ((RAIL_FALLBACK_LOGICAL * g.scale).round() as u32).max(1)
        }
    }
}

fn widget_state() -> WidgetState {
    *WIDGET.lock().unwrap_or_else(|e| e.into_inner())
}

/// Claims the shared animation generation, cancelling any in-flight glide.
///
/// Every geometry-changing operation does this FIRST, including the ones that
/// turn out to be no-ops: already sitting at the target is exactly when a
/// stale animation heading somewhere else most needs cancelling.
fn claim_generation() -> u64 {
    SLIDE_GEN.fetch_add(1, Ordering::SeqCst) + 1
}

/// Parses the `side` argument shared by every widget geometry command.
/// `Ok(None)` means "Floating".
fn parse_side(side: &str) -> Result<Option<DockSide>, String> {
    if side.eq_ignore_ascii_case("left") {
        Ok(Some(DockSide::Left))
    } else if side.eq_ignore_ascii_case("right") {
        Ok(Some(DockSide::Right))
    } else if side.eq_ignore_ascii_case("floating") {
        Ok(None)
    } else {
        Err(format!(
            "unknown dock side '{side}' (expected Left, Right, or Floating)"
        ))
    }
}

fn require_docked_side(side: &str) -> Result<DockSide, String> {
    parse_side(side)?.ok_or_else(|| format!("'{side}' is not a docked side (expected Left or Right)"))
}

fn signature_of(scale: f64, x: i32, y: i32, w: u32, h: u32) -> u64 {
    // FNV-1a over the five scalars. Only ever compared for equality.
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for part in [
        scale.to_bits(),
        x as u32 as u64,
        y as u32 as u64,
        w as u64,
        h as u64,
    ] {
        hash ^= part;
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash | 1
}

// --- minimize + coordinate-space plumbing ---------------------------------

/// True while the widget window is minimized (iconic).
///
/// EVERY read of the window's geometry and every write to it stands down while
/// this holds, because a minimized window answers - and accepts - nonsense:
///
/// - tao 0.35.3 forwards WM_SIZE unconditionally (event_loop.rs:1227). Unlike
///   winit it has NO `SIZE_MINIMIZED` guard, so `WindowEvent::Resized` fires on
///   the way down carrying the iconic CLIENT size, 0x0.
/// - `outer_size()` meanwhile answers the ICONIC WINDOW rect - 237x39 physical
///   on the test machine, whatever the sidebar's real width was. So a
///   `size.width == 0` test does NOT detect this from the outer side: that is
///   precisely how `widgetSavedWidth: 158` (237 / 1.5, exactly) reached
///   settings.json.
/// - `set_size`/`set_position` on a minimized window rewrite its
///   `rcNormalPosition`, i.e. corrupt the rect Windows will restore it to.
///
/// Left unguarded the three compose into the reported jam: minimizing with a
/// tray open drove `flyout_width` down to its 200-logical floor, which makes
/// `derive_rect`'s `min_width` (base + flyout_floor) exactly equal `width` - so
/// the OS then refused every narrowing drag of either the sidebar or the tray.
///
/// No catch-up is needed on the way back: SIZE_RESTORED sends another WM_SIZE,
/// this time with the real client size, and `on_widget_resized` re-derives from
/// it like any other resize.
fn is_iconic(window: &tauri::WebviewWindow) -> bool {
    window.is_minimized().unwrap_or(false)
}

/// Largest frame inset this module will believe, physical px. A genuine
/// undecorated-with-shadows frame is a handful of px per side (22x13 total at
/// 150% on the test panel); anything larger means we measured a window in a
/// state that has no meaningful frame at all, and falling back to "no inset"
/// is far better than folding junk into every rect.
const MAX_FRAME_INSET: u32 = 128;

/// The invisible non-client frame around the widget window, physical px. See
/// the COORDINATE SPACES banner above.
///
/// `left`/`top` are how far the CLIENT origin sits inside the WINDOW rect;
/// `width`/`height` are the per-axis totals (outer - client). Measured live
/// rather than assumed, because the inset is derived from SM_CXSIZEFRAME +
/// SM_CXPADDEDBORDER and the window's DPI - it is not a constant across
/// monitors, and hard-coding it would reintroduce the same drift by a
/// different route.
#[derive(Clone, Copy, Debug, Default)]
struct FrameInset {
    left: i32,
    top: i32,
    width: u32,
    height: u32,
}

impl FrameInset {
    /// CLIENT origin -> the OUTER origin `set_position` expects.
    fn outer_origin(&self, x: i32, y: i32) -> PhysicalPosition<i32> {
        PhysicalPosition::new(x - self.left, y - self.top)
    }

    /// CLIENT size -> the OUTER track size `set_min_size`/`set_max_size` emit
    /// into WM_GETMINMAXINFO.
    fn outer_bound(&self, size: PhysicalSize<u32>) -> PhysicalSize<u32> {
        PhysicalSize::new(
            size.width.saturating_add(self.width),
            size.height.saturating_add(self.height),
        )
    }
}

/// Measures the live frame inset. Returns a zero inset (a harmless identity
/// conversion) if the window cannot be measured or the numbers are not
/// plausibly a frame - never a guess.
fn frame_inset(window: &tauri::WebviewWindow) -> FrameInset {
    let (Ok(outer_pos), Ok(inner_pos), Ok(outer), Ok(inner)) = (
        window.outer_position(),
        window.inner_position(),
        window.outer_size(),
        window.inner_size(),
    ) else {
        return FrameInset::default();
    };
    let left = inner_pos.x - outer_pos.x;
    let top = inner_pos.y - outer_pos.y;
    let width = outer.width.saturating_sub(inner.width);
    let height = outer.height.saturating_sub(inner.height);
    let cap = MAX_FRAME_INSET as i32;
    if !(0..=cap).contains(&left)
        || !(0..=cap).contains(&top)
        || width > MAX_FRAME_INSET
        || height > MAX_FRAME_INSET
    {
        return FrameInset::default();
    }
    FrameInset {
        left,
        top,
        width,
        height,
    }
}

/// The widget's live CLIENT rect: the visible glass, in screen coordinates.
/// The model's own space, so this is what every comparison against a derived
/// rect uses - `outer_size()`/`outer_position()` would be a frame inset off and
/// make a genuine no-op read as a change on every single call.
fn client_rect(window: &tauri::WebviewWindow) -> Result<(PhysicalPosition<i32>, PhysicalSize<u32>), String> {
    let pos = window.inner_position().map_err(|e| e.to_string())?;
    let size = window.inner_size().map_err(|e| e.to_string())?;
    Ok((pos, size))
}

fn monitor_of(window: &tauri::WebviewWindow) -> Result<tauri::window::Monitor, String> {
    if let Ok(Some(m)) = window.current_monitor() {
        return Ok(m);
    }
    window
        .primary_monitor()
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "no monitor available for the widget window".to_string())
}

/// Resolves the LIVE monitor geometry the widget window is currently on.
fn live_dock_geometry(window: &tauri::WebviewWindow) -> Result<DockGeometry, String> {
    let monitor = monitor_of(window)?;
    let scale = monitor.scale_factor();
    let work = monitor.work_area();
    let work_w = work.size.width.max(1);
    let work_h = work.size.height.max(1);

    // Quarter of the work area, with `WIDGET_ABS_MIN_WIDTH_LOGICAL` taking
    // over on panels too small for a quarter to be usable, and the work area
    // itself capping both.
    //
    // That final cap is not decoration. `Ord::clamp` PANICS when min > max,
    // and a panic inside an async Tauri command drops the responder - the
    // frontend's `await` never settles, so the dock button silently does
    // nothing forever (and re-panics at every startup, since the dock is
    // re-applied on load). Every bound in this module is validated where it is
    // built rather than trusted where it is used.
    let quarter = ((work_w as f64) / 4.0).round() as u32;
    let absolute = ((WIDGET_ABS_MIN_WIDTH_LOGICAL * scale).round() as u32).max(1);
    let min_width = quarter.max(absolute).max(1).min(work_w);
    // "adjustable bigger if wanted" - no ceiling short of the screen.
    let max_width = work_w;

    Ok(DockGeometry {
        scale,
        work_x: work.position.x,
        work_y: work.position.y,
        work_w,
        work_h,
        min_width,
        max_width,
        signature: signature_of(scale, work.position.x, work.position.y, work_w, work_h),
    })
}

/// The geometry an ANIMATED operation should reason about: the one last
/// applied, if it still describes a connected display, otherwise the live
/// monitor.
///
/// Slides and flyouts keep talking about the monitor the sidebar is docked to
/// even when `current_monitor()` would answer differently - which it genuinely
/// does once the window is slid ~97% off its edge and most of its rect
/// overlaps the neighbouring display.
fn active_geometry(window: &tauri::WebviewWindow) -> Result<DockGeometry, String> {
    if let Some(stored) = widget_state().monitor {
        // Stale-monitor guard. The display the sidebar was docked to can be
        // unplugged (or rescaled) while the widget sits collapsed on its rail,
        // which is exactly the state in which the monitor-change revalidation
        // deliberately stands down. Only trust the stored rect if some
        // currently-connected monitor still matches it exactly.
        match window.available_monitors() {
            Ok(monitors) => {
                let still_connected = monitors.iter().any(|m| {
                    let w = m.work_area();
                    signature_of(
                        m.scale_factor(),
                        w.position.x,
                        w.position.y,
                        w.size.width.max(1),
                        w.size.height.max(1),
                    ) == stored.signature
                });
                if still_connected {
                    return Ok(stored);
                }
                tracing::info!("the monitor the widget was docked to is gone - using the live one");
            }
            // Can't enumerate: the stored rect is still the better guess.
            Err(_) => return Ok(stored),
        }
    }
    live_dock_geometry(window)
}

/// Where the docked window's left edge belongs, for a window `width` wide.
/// `rail` is the sliver (physical px) left on screen while collapsed.
///
/// CLIENT space in, CLIENT space out - `width` is the visible glass and the
/// result is where its left edge belongs, so a docked edge is genuinely flush
/// with the work area and the collapsed sliver is genuinely `rail` px of glass.
/// The frame inset is folded in exactly once, by `apply_rect`, on the way to
/// `set_position`. Feeding a client width into these formulas and then treating
/// the answer as an OUTER x (which is what happened before the model was
/// pinned to one space) put the right-docked sidebar's outer edge at
/// `work_x + work_w + frame`, i.e. permanently 11 physical px off-screen, and
/// made the collapsed sliver `rail + 11` on Left but `rail - 11` on Right.
fn dock_x(side: DockSide, g: &DockGeometry, width: u32, collapsed: bool, rail: u32) -> i32 {
    let rail = rail.min(width) as i32;
    let w = width as i32;
    match (side, collapsed) {
        // Expanded: flush against the edge.
        (DockSide::Left, false) => g.work_x,
        (DockSide::Right, false) => g.work_x + g.work_w as i32 - w,
        // Collapsed: slid off-screen with a `rail`-wide sliver remaining on
        // the INNER edge.
        (DockSide::Left, true) => g.work_x - w + rail,
        (DockSide::Right, true) => g.work_x + g.work_w as i32 - rail,
    }
}

/// The complete window rect plus the OS size bounds implied by a
/// `WidgetState`.
///
/// Every field is PHYSICAL px in CLIENT space - the visible glass - including
/// `min`/`max`. `apply_rect` is the only place they become OUTER numbers, and
/// only for the three APIs that demand it. See the COORDINATE SPACES banner.
#[derive(Clone, Copy, Debug)]
struct WidgetRect {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    min: PhysicalSize<u32>,
    max: PhysicalSize<u32>,
}

/// Turns (state, side, monitor) into the one rect that state means. The whole
/// point of the module: there is no other function anywhere that decides how
/// wide the window should be or what it may be resized to.
fn derive_rect(st: &WidgetState, side: DockSide, g: &DockGeometry) -> WidgetRect {
    let base = st.base_width.clamp(g.min_width, g.max_width);
    // When the pair will not fit it is the TRAY that gets clipped, never the
    // sidebar: the user asked for a sidebar of this width with a tray beside
    // it, and a tray 40px narrower than requested still reads correctly where
    // a sidebar that silently shrank does not - and would then be "remembered"
    // at the shrunken width on the next close.
    let flyout = st.flyout_width.min(g.work_w.saturating_sub(base));
    let width = base.saturating_add(flyout).min(g.work_w).max(1);

    // Dragging the free outer edge while a tray is out must resize the TRAY,
    // so the window's floor moves up to "sidebar + narrowest useful pane" for
    // exactly as long as the tray is out. The OS then physically refuses to
    // let the drag eat into the sidebar column.
    //
    // `.min(width)` is the no-inversion guard: on a monitor too narrow to hold
    // both, `flyout` above is clipped and can land under the pane minimum, at
    // which point a floor above the size we are about to set would have the OS
    // fighting us on every frame.
    let flyout_floor = ((FLYOUT_MIN_WIDTH_LOGICAL * g.scale).round() as u32).max(1);
    let min_width = if flyout > 0 {
        base.saturating_add(flyout_floor)
    } else {
        g.min_width
    }
    .min(width)
    .min(g.work_w)
    .max(1);

    WidgetRect {
        x: dock_x(side, g, width, st.collapsed, st.rail_px(g)),
        y: g.work_y,
        width,
        height: g.work_h,
        // Equal min/max heights lock the vertical axis while the width stays
        // free - per-axis resizing without any per-axis API. The width ceiling
        // is the work area, which is `>= min_width` by the clamps above, so the
        // pair can never invert.
        min: PhysicalSize::new(min_width, g.work_h),
        max: PhysicalSize::new(g.max_width.max(min_width), g.work_h),
    }
}

/// Installs a derived rect on the OS window.
///
/// The order is load-bearing and not interchangeable: the ceiling goes on
/// first so it can never clamp the size about to be asked for, then the floor,
/// then the size, then the position. `derive_rect` guarantees
/// `min <= width <= max` on both axes, so no bound the window holds at any
/// instant of this sequence contradicts the rect it is being moved to.
/// The rect is CLIENT space (see `WidgetRect`); this is the one place it
/// becomes OUTER numbers, and each conversion is named at its call.
fn apply_rect(window: &tauri::WebviewWindow, rect: &WidgetRect) -> Result<(), String> {
    // Never write geometry to a minimized window: it rewrites the
    // rcNormalPosition it will be restored to. See `is_iconic`.
    if is_iconic(window) {
        return Ok(());
    }
    let frame = frame_inset(window);
    window.set_resizable(true).map_err(|e| e.to_string())?;
    // CLIENT -> OUTER: min/max land in WM_GETMINMAXINFO as ptMin/MaxTrackSize,
    // which bound the WINDOW rect. Uncoverted, the effective floor sat one
    // frame inset below the intended one and dragging to the minimum
    // rubber-banded.
    window
        .set_max_size(Some(frame.outer_bound(rect.max)))
        .map_err(|e| e.to_string())?;
    window
        .set_min_size(Some(frame.outer_bound(rect.min)))
        .map_err(|e| e.to_string())?;
    // CLIENT, verbatim: `set_size` is `set_inner_size`.
    window
        .set_size(PhysicalSize::new(rect.width, rect.height))
        .map_err(|e| e.to_string())?;
    // CLIENT -> OUTER: `set_position` is `set_outer_position`.
    window
        .set_position(frame.outer_origin(rect.x, rect.y))
        .map_err(|e| e.to_string())?;
    Ok(())
}

/// Re-derives and applies the ENTIRE docked rect from the current
/// `WidgetState`. Every docked command routes through here.
///
/// Re-entrant by design: `lib.rs` calls it again (via
/// `revalidate_widget_geometry`) whenever the widget's monitor or scale factor
/// changes, because tao writes a `PhysicalSize` min/max straight into
/// `WM_GETMINMAXINFO` and never rescales it on a DPI change. Docking on a
/// 4K/150% panel (work height ~2088 physical) and then unplugging it left the
/// widget on a 1080p screen with min AND max height both still 2088 - a
/// sidebar nearly twice the screen height that could not be resized out of.
///
/// Width on such a hand-off is re-clamped into the new monitor's range rather
/// than rescaled by the DPI ratio: Windows has usually already resized the
/// window itself by the time `ScaleFactorChanged` arrives, so applying our own
/// ratio on top would double-count.
fn apply_docked(
    window: &tauri::WebviewWindow,
    side: DockSide,
    generation: u64,
    animate: bool,
) -> Result<(), String> {
    // A minimized window cannot be measured or moved without corrupting its
    // restore rect (see `is_iconic`). Record the state change so the
    // bookkeeping stays honest and skip the OS half; the WM_SIZE that
    // SIZE_RESTORED sends re-derives and re-pins everything.
    if is_iconic(window) {
        let mut st = WIDGET.lock().unwrap_or_else(|e| e.into_inner());
        st.mode = WidgetMode::Docked(side);
        tracing::debug!("skipping dock geometry - the widget window is minimized");
        return Ok(());
    }

    // An explicit (re-)dock re-reads the LIVE monitor - that is the whole
    // point of one. A slide or a flyout deliberately keeps talking about the
    // monitor the sidebar was docked to; see `active_geometry`.
    let g = if animate {
        active_geometry(window)?
    } else {
        live_dock_geometry(window)?
    };

    let rect = {
        let mut st = WIDGET.lock().unwrap_or_else(|e| e.into_inner());
        st.mode = WidgetMode::Docked(side);
        // First dock of the session with nothing remembered: the quarter.
        if st.base_width == 0 {
            st.base_width = g.min_width;
        }
        st.base_width = st.base_width.clamp(g.min_width, g.max_width);
        st.monitor = Some(g);
        derive_rect(&st, side, &g)
    };

    // CLIENT, to match `rect`. Reading `outer_size()` here compared a window
    // rect against a client-space target, so a genuine no-op always read as a
    // change (off by exactly one frame inset) and `animate_widget` was seeded
    // with a start width one inset too large - every glide jumped on frame 1.
    let (pos, size) = client_rect(window)?;

    // Animating is only ever a width/x glide. Anything else - the height
    // changing as floating hands over to docked, a monitor swap - lands
    // instantly, which also spares `travel_min` below from having to reason
    // about the vertical axis at all.
    let glide =
        animate && size.height == rect.height && (pos.x != rect.x || size.width != rect.width);

    if !glide {
        ANIM_ACTIVE.store(false, Ordering::SeqCst);
        apply_rect(window, &rect)?;
        emit_widget_geometry(window);
        return Ok(());
    }

    // The bounds have to admit every intermediate frame, not just the two
    // ends, or the OS clamps one and the glide lands somewhere nobody asked
    // for. The ceiling is already the work area; only the floor can bite
    // (opening a tray raises it to sidebar+pane), so it is RELAXED to the
    // narrower of the two ends for the duration and `animate_widget` installs
    // the real one on landing. Relaxing - never tightening - is what keeps
    // min <= max true at every instant of the animation.
    let travel_min = PhysicalSize::new(rect.min.width.min(size.width).max(1), rect.height);
    // CLIENT -> OUTER for both, same as `apply_rect`.
    let frame = frame_inset(window);
    window
        .set_max_size(Some(frame.outer_bound(rect.max)))
        .map_err(|e| e.to_string())?;
    window
        .set_min_size(Some(frame.outer_bound(travel_min)))
        .map_err(|e| e.to_string())?;

    // Both seeds are CLIENT, matching `rect`.
    animate_widget(window.clone(), generation, pos.x, size.width, rect);
    Ok(())
}

/// Releases the widget back to a normal window: min restored to 480x560
/// logical, no max, size restored to the 500x720 default - AND moved back
/// fully on-screen.
///
/// The move is not cosmetic. A docked widget that has been collapsed to its
/// rail is parked ~97% off its edge; without repositioning, switching to
/// Floating produced a 500x720 window whose only visible part was an 18px
/// strip, with no titlebar drag region to grab it by (the frontend withholds
/// that while docked) - unrecoverable without editing settings.json by hand.
fn float_widget(window: &tauri::WebviewWindow) -> Result<(), String> {
    window.set_resizable(true).map_err(|e| e.to_string())?;
    // Max first: a leftover docked max would clamp the size we set below.
    window
        .set_max_size(None::<tauri::LogicalSize<f64>>)
        .map_err(|e| e.to_string())?;

    match monitor_of(window) {
        Ok(monitor) => {
            let scale = monitor.scale_factor();
            let work = monitor.work_area();
            let work_w = work.size.width.max(1);
            let work_h = work.size.height.max(1);
            // Never demand more than the work area can give, or the floating
            // minimum immediately fights the monitor on small/high-DPI panels.
            let min_w = ((FLOAT_MIN_WIDTH_LOGICAL * scale).round() as u32)
                .max(1)
                .min(work_w);
            let min_h = ((FLOAT_MIN_HEIGHT_LOGICAL * scale).round() as u32)
                .max(1)
                .min(work_h);
            let want_w = ((FLOAT_WIDTH_LOGICAL * scale).round() as u32).clamp(min_w, work_w);
            let want_h = ((FLOAT_HEIGHT_LOGICAL * scale).round() as u32).clamp(min_h, work_h);

            // CLIENT -> OUTER, same reason as `apply_rect`: an unconverted
            // floor is enforced one frame inset low, so `enforce_floating_floor`
            // (which reasons in client px) and the OS disagreed about the
            // minimum and the drag rubber-banded at the bottom of its range.
            let frame = frame_inset(window);
            window
                .set_min_size(Some(frame.outer_bound(PhysicalSize::new(min_w, min_h))))
                .map_err(|e| e.to_string())?;
            window
                .set_size(PhysicalSize::new(want_w, want_h))
                .map_err(|e| e.to_string())?;
            // Centre on the work area - guaranteed fully on-screen whatever
            // off-edge position the dock left behind. CLIENT x/y in, converted
            // on the way to `set_position` like everywhere else.
            let x = work.position.x + ((work_w as i32 - want_w as i32) / 2).max(0);
            let y = work.position.y + ((work_h as i32 - want_h as i32) / 2).max(0);
            window
                .set_position(frame.outer_origin(x, y))
                .map_err(|e| e.to_string())?;
        }
        Err(e) => {
            // No monitor at all (mid-resume, all displays detached): still
            // restore sane logical bounds so the window isn't left locked to
            // a stale dock's min/max.
            tracing::warn!(error = %e, "floating the widget without monitor geometry");
            window
                .set_min_size(Some(tauri::LogicalSize::new(
                    FLOAT_MIN_WIDTH_LOGICAL,
                    FLOAT_MIN_HEIGHT_LOGICAL,
                )))
                .map_err(|e| e.to_string())?;
            window
                .set_size(tauri::LogicalSize::new(
                    FLOAT_WIDTH_LOGICAL,
                    FLOAT_HEIGHT_LOGICAL,
                ))
                .map_err(|e| e.to_string())?;
            window.center().map_err(|e| e.to_string())?;
        }
    }

    Ok(())
}

/// The single eased stepper behind every widget window animation. Steps
/// position and size together (the right-dock flyout needs both: the outer
/// screen edge stays pinned, so x moves left by exactly what width gains),
/// and aborts the moment it stops owning `SLIDE_GEN`.
///
/// `start_x`/`start_w` and `rect` are all CLIENT space; the frame inset is
/// measured once here and folded into every `set_position` (OUTER), while
/// `set_size` takes the client width verbatim.
fn animate_widget(
    window: tauri::WebviewWindow,
    generation: u64,
    start_x: i32,
    start_w: u32,
    rect: WidgetRect,
) {
    ANIM_ACTIVE.store(true, Ordering::SeqCst);
    // Measured once, not per frame: the frame inset cannot change mid-glide
    // (only a DPI change moves it, and that re-docks instantly rather than
    // gliding), and re-measuring it against a window we are actively resizing
    // would sample it mid-flight.
    let frame = frame_inset(&window);
    // Growing: move first, then widen, so the pinned outer edge never
    // overshoots outward. Shrinking: the reverse, for the same reason.
    let growing = rect.width > start_w;
    tauri::async_runtime::spawn(async move {
        const STEPS: u32 = 14;
        const STEP_MS: u64 = 14;
        let mut last_w = start_w;
        for i in 1..=STEPS {
            if SLIDE_GEN.load(Ordering::SeqCst) != generation {
                return; // superseded - leave ANIM_ACTIVE to the new owner
            }
            // Minimized mid-glide (the user hit the taskbar button): every
            // remaining frame would write to the restore rect. Release the
            // animation lock so `on_widget_resized` is live again for the
            // SIZE_RESTORED that follows, and stop.
            if is_iconic(&window) {
                ANIM_ACTIVE.store(false, Ordering::SeqCst);
                return;
            }
            let t = i as f64 / STEPS as f64;
            let eased = 1.0 - (1.0 - t).powi(3); // ease-out cubic
            let x = start_x + ((rect.x - start_x) as f64 * eased).round() as i32;
            let w = (start_w as f64 + (rect.width as f64 - start_w as f64) * eased).round() as u32;
            if growing {
                let _ = window.set_position(frame.outer_origin(x, rect.y));
                if w != last_w {
                    let _ = window.set_size(PhysicalSize::new(w, rect.height));
                }
            } else {
                if w != last_w {
                    let _ = window.set_size(PhysicalSize::new(w, rect.height));
                }
                let _ = window.set_position(frame.outer_origin(x, rect.y));
            }
            last_w = w;
            tokio::time::sleep(Duration::from_millis(STEP_MS)).await;
        }
        if SLIDE_GEN.load(Ordering::SeqCst) == generation {
            // Land on the exact rect, unconditionally. `last_w` is what we
            // ASKED for, not what the OS granted, so skipping the final
            // `set_size` when they happen to match would leave the window one
            // refused frame short of the target - permanently, since nothing
            // else recomputes it.
            let _ = window.set_size(PhysicalSize::new(rect.width, rect.height));
            let _ = window.set_position(frame.outer_origin(rect.x, rect.y));
            // Hand the real bounds back only now that the rect they describe
            // is the one the window actually holds. CLIENT -> OUTER, as in
            // `apply_rect`.
            let _ = window.set_max_size(Some(frame.outer_bound(rect.max)));
            let _ = window.set_min_size(Some(frame.outer_bound(rect.min)));
            ANIM_ACTIVE.store(false, Ordering::SeqCst);
            // Deterministic catch-up for the monitor check that was suppressed
            // for the duration of the glide (and, before that, for as long as
            // the widget was collapsed): expanding a sidebar whose monitor was
            // unplugged in the meantime lands it on a live display instead of
            // the coordinates of a screen that is gone. A no-op whenever the
            // monitor is unchanged, which is the norm.
            revalidate_widget_geometry(&window, false);
            emit_widget_geometry(&window);
        }
    });
}

// ---------------------------------------------------------------------------
// Geometry reporting (the frontend owns settings.json, Rust does not)
// ---------------------------------------------------------------------------

/// The widget's geometry in LOGICAL px, the units the frontend and
/// settings.json both speak.
fn widget_geometry_payload(window: &tauri::WebviewWindow) -> Value {
    let st = widget_state();
    let g = st.monitor.or_else(|| live_dock_geometry(window).ok());
    let scale = g
        .map(|g| g.scale)
        .unwrap_or_else(|| window.scale_factor().unwrap_or(1.0));
    let scale = if scale.is_finite() && scale > 0.0 {
        scale
    } else {
        1.0
    };
    let logical = |px: u32| (px as f64 / scale).round();

    serde_json::json!({
        "side": match st.mode {
            WidgetMode::Floating => "Floating",
            WidgetMode::Docked(DockSide::Left) => "Left",
            WidgetMode::Docked(DockSide::Right) => "Right",
        },
        "baseWidth": logical(st.base_width),
        "flyoutWidth": logical(st.flyout_width),
        "minWidth": g.map(|g| logical(g.min_width)),
        "maxWidth": g.map(|g| logical(g.max_width)),
        "collapsed": st.collapsed,
    })
}

/// Broadcasts `devkit://widget-geometry`.
///
/// Rust cannot write settings.json - the PowerShell sidecar owns it - so the
/// remembered width has to round-trip through the frontend: Rust reports what
/// the window IS, the frontend persists it as `preferences.widgetSavedWidth`
/// and hands it back as `set_widget_dock`'s `savedWidth` on the next launch.
fn emit_widget_geometry(window: &tauri::WebviewWindow) {
    let payload = widget_geometry_payload(window);
    let _ = window.emit("devkit://widget-geometry", payload);
}

/// Coalesces the burst of `Resized` events one mouse drag produces into a
/// single event for the frontend to persist.
///
/// Windows delivers WM_SIZE per mouse move and tao surfaces no "resize
/// finished" edge (WM_EXITSIZEMOVE never reaches us), so the settle has to be
/// timed rather than observed.
fn schedule_geometry_emit(window: &tauri::WebviewWindow) {
    let generation = GEOMETRY_EMIT_GEN.fetch_add(1, Ordering::SeqCst) + 1;
    let window = window.clone();
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(Duration::from_millis(220)).await;
        if GEOMETRY_EMIT_GEN.load(Ordering::SeqCst) == generation {
            emit_widget_geometry(&window);
        }
    });
}

/// Reports the widget's geometry in logical px - the same payload
/// `devkit://widget-geometry` carries. For the frontend paths that need the
/// number right now (persisting `widgetSavedWidth` as the window hides)
/// instead of waiting for the next event.
///
/// JS: `invoke("widget_geometry")`.
#[tauri::command]
pub async fn widget_geometry(app: tauri::AppHandle) -> Result<Value, String> {
    let Some(window) = app.get_webview_window("widget") else {
        return Err("widget window not found".into());
    };
    Ok(widget_geometry_payload(&window))
}

// ---------------------------------------------------------------------------
// Geometry commands
// ---------------------------------------------------------------------------

/// Turns a `savedWidth` off disk into a `base_width` we are willing to install,
/// or `None` to fall back to the quarter-screen default.
///
/// settings.json is a plain file: the user can edit it, a sync tool can merge
/// it, and - as happened here - an earlier build can write junk into it. The
/// live file on the reporting machine holds `widgetSavedWidth: 158`, which is
/// the minimized window's iconic outer width (237) divided by the 1.5 scale
/// factor, i.e. an artefact of the bug `is_iconic` now prevents rather than a
/// width any user ever chose. Restoring it verbatim would hand the sidebar a
/// value less than half the quarter-screen floor.
///
/// So the value is validated here rather than trusted downstream: NaN,
/// infinity and non-positive numbers are rejected outright, anything past what
/// this monitor could ever show is rejected as "not a width", and the rest is
/// clamped into the same range `derive_rect` would enforce anyway - but with a
/// log line, so a nonsense value on disk is visible instead of silent.
fn sanitize_saved_width(saved: Option<f64>, g: &DockGeometry) -> Option<u32> {
    let saved = saved?;
    if !saved.is_finite() || saved <= 0.0 {
        return None;
    }
    let physical = saved * g.scale;
    // `as u32` saturates in Rust, so an absurd value cannot wrap - but it also
    // cannot be meaningful, so treat "wider than any monitor" as absent
    // instead of silently clamping it to full screen.
    if physical > (g.max_width as f64) * 4.0 {
        tracing::warn!(
            saved_logical = saved,
            "ignoring an implausible widgetSavedWidth - using the quarter-screen default"
        );
        return None;
    }
    let px = physical.round() as u32;
    let clamped = px.clamp(g.min_width, g.max_width).max(1);
    if clamped != px {
        tracing::warn!(
            saved_logical = saved,
            saved_physical = px,
            applied_physical = clamped,
            "widgetSavedWidth is outside what this monitor allows - clamped"
        );
    }
    Some(clamped)
}

/// Docks the widget as a real sidebar, or releases it back to a floating
/// window. Backs the widgetDockMode setting ("Left" | "Right" | "Floating").
///
/// `savedWidth` (LOGICAL px, from `preferences.widgetSavedWidth`) is the width
/// the widget was last closed at. It applies to the FIRST dock of the session
/// only - after that the live state is the truth, and a settings value that
/// has not caught up yet must not undo a resize the user has since made.
/// Omitted or null means "use the quarter-screen default".
///
/// A dock change always lands the widget expanded with no tray out, and the
/// sidebar keeps its own width across a Left <-> Right flip.
///
/// JS: `invoke("set_widget_dock", { side, savedWidth })`.
#[tauri::command]
pub async fn set_widget_dock(
    app: tauri::AppHandle,
    side: String,
    saved_width: Option<f64>,
) -> Result<(), String> {
    let Some(window) = app.get_webview_window("widget") else {
        return Err("widget window not found".into());
    };
    let target = parse_side(&side)?;

    // A dock change is an explicit "put the window HERE", and the one geometry
    // command for which standing down on a minimized window would be wrong -
    // there would be nothing left to re-apply it afterwards (a floating widget
    // never reaches `revalidate_widget_geometry`). Restore it first so
    // everything below measures and writes a real rect. See `is_iconic`.
    if is_iconic(&window) {
        if let Err(e) = window.unminimize() {
            tracing::warn!(error = %e, "could not restore the minimized widget before re-docking");
        }
    }

    // Joins the shared generation counter so an in-flight slide/flyout can't
    // keep stepping toward the OLD layout's target after the re-pin and land
    // its final `set_position` last.
    let generation = claim_generation();
    ANIM_ACTIVE.store(false, Ordering::SeqCst);

    match target {
        None => {
            {
                let mut st = WIDGET.lock().unwrap_or_else(|e| e.into_inner());
                st.mode = WidgetMode::Floating;
                st.flyout_width = 0;
                st.collapsed = false;
                st.monitor = None;
                // `base_width` is deliberately KEPT: flipping to Floating and
                // back should return the sidebar to the width the user had,
                // not to the quarter-screen default.
            }
            let result = float_widget(&window);
            emit_widget_geometry(&window);
            result
        }
        Some(dock) => {
            let g = live_dock_geometry(&window)?;
            {
                let mut st = WIDGET.lock().unwrap_or_else(|e| e.into_inner());
                st.collapsed = false;
                st.flyout_width = 0;
                if st.base_width == 0 {
                    if let Some(width) = sanitize_saved_width(saved_width, &g) {
                        st.base_width = width;
                    }
                }
            }
            apply_docked(&window, dock, generation, false)
        }
    }
}

/// Slides the DOCKED widget off its edge like a tray, leaving a
/// `railWidth`-wide sliver on screen (collapsed=true), or slides it back fully
/// on screen (collapsed=false). Animates the OS window position itself
/// (~200ms ease-out at ~60fps) so the whole glass surface physically glides -
/// the JARVIS-tray behavior - rather than just hiding content.
///
/// `railWidth` is LOGICAL px and is `WIDGET_RAIL_LOGICAL` from WidgetApp.tsx -
/// NOT `preferences.railWidth`, which sizes the in-window icon tab rail and has
/// nothing to do with the sliver. The frontend draws the grab-rail, so the
/// frontend owns how wide it is; the same constant sets the CSS `--sliver-width`
/// the strip is rendered at, which is what keeps the glass and the gap equal.
/// The value is remembered, so a later re-dock or monitor change parks the
/// window against the same sliver. Omitted or null keeps whatever was last
/// passed (or `RAIL_FALLBACK_LOGICAL`, if nothing ever was - which is what
/// every session used to run on, since the only caller passed nothing at all).
///
/// JS: `invoke("slide_widget", { side, collapsed, railWidth })`.
#[tauri::command]
pub async fn slide_widget(
    app: tauri::AppHandle,
    side: String,
    collapsed: bool,
    rail_width: Option<f64>,
) -> Result<(), String> {
    let Some(window) = app.get_webview_window("widget") else {
        return Err("widget window not found".into());
    };
    let dock = require_docked_side(&side)?;
    // Refuse rather than half-apply docked bounds to a floating window:
    // `apply_docked` installs a work-area-height min/max, which on a floating
    // widget would silently stretch it to full screen height.
    if matches!(widget_state().mode, WidgetMode::Floating) {
        return Err("the widget is not docked - only a docked sidebar slides to a rail".into());
    }
    let g = active_geometry(&window)?;
    let generation = claim_generation();
    {
        let mut st = WIDGET.lock().unwrap_or_else(|e| e.into_inner());
        st.collapsed = collapsed;
        if let Some(rail) = rail_width.filter(|w| w.is_finite() && *w > 0.0) {
            st.rail_width = ((rail * g.scale).round() as u32).max(1);
        }
    }
    apply_docked(&window, dock, generation, true)
}

/// Animates the DOCKED widget's WIDTH so a flyout tray can slide out BESIDE
/// the sidebar instead of covering it.
///
/// - Left dock: x stays put, width animates between base and base+flyout.
/// - Right dock: the outer screen edge stays pinned, so x moves left by
///   exactly the amount the width grows (both animate together).
///
/// The sidebar's own width is not touched here, in either direction. Opening
/// adds the tray beside it and closing removes exactly that again, so a close
/// always lands on the width the sidebar had before the open - not base+rail,
/// not base+1. (The in-window tab rail is drawn INSIDE the sidebar width and
/// is not part of this arithmetic anywhere.) A resize the user performs WHILE
/// a tray is out is attributed to the TRAY by `on_widget_resized`, so closing
/// after such a drag still returns the sidebar to its own width.
///
/// `flyoutWidth` is LOGICAL px; if the pair would exceed the work area it is
/// the tray that gets clipped, never the sidebar.
///
/// JS: `invoke("set_widget_flyout", { side, open, flyoutWidth })`.
#[tauri::command]
pub async fn set_widget_flyout(
    app: tauri::AppHandle,
    side: String,
    open: bool,
    flyout_width: f64,
) -> Result<(), String> {
    let Some(window) = app.get_webview_window("widget") else {
        return Err("widget window not found".into());
    };
    let dock = require_docked_side(&side)?;
    if matches!(widget_state().mode, WidgetMode::Floating) {
        return Err("the widget is not docked - a flyout can only widen a docked sidebar".into());
    }
    if open && (!flyout_width.is_finite() || flyout_width <= 0.0) {
        return Err(format!("invalid flyoutWidth {flyout_width}"));
    }
    let g = active_geometry(&window)?;
    let generation = claim_generation();
    {
        let mut st = WIDGET.lock().unwrap_or_else(|e| e.into_inner());
        st.flyout_width = if open {
            ((flyout_width * g.scale).round() as u32).max(1)
        } else {
            0
        };
    }
    apply_docked(&window, dock, generation, true)
}

// ---------------------------------------------------------------------------
// Window-event feedback (driven from lib.rs)
// ---------------------------------------------------------------------------

/// Every `Resized` the widget window reports, from `lib.rs`.
///
/// This is where a user dragging a window edge becomes state. While a tray is
/// out the delta belongs to the TRAY and the sidebar column keeps its width;
/// with no tray out it belongs to the sidebar. Either way the rect is
/// re-derived from scratch afterwards, which is also what enforces the
/// quarter-screen floor and re-pins the docked edge.
///
/// `size` is the WM_SIZE client size - the model's own space (see the
/// COORDINATE SPACES banner), so it is used verbatim.
pub(crate) fn on_widget_resized(window: &tauri::WebviewWindow, size: PhysicalSize<u32>) {
    // Our own animation frames arrive here too; they are not the user.
    if ANIM_ACTIVE.load(Ordering::SeqCst) {
        return;
    }
    // A minimize is not a resize. tao has no SIZE_MINIMIZED guard, so this
    // fires with a 0x0 client size on the way down - and 0 minus the sidebar
    // clamps `flyout_width` to its floor (jamming the window between a min and
    // a max that describe nothing) or `base_width` to the quarter-screen
    // minimum, and then writes both back to a window whose restore rect it
    // corrupts. See `is_iconic`.
    if is_iconic(window) || size.width == 0 || size.height == 0 {
        return;
    }
    let WidgetMode::Docked(side) = widget_state().mode else {
        enforce_floating_floor(window, size);
        return;
    };
    let Ok(g) = active_geometry(window) else {
        return;
    };

    let (rect, changed) = {
        let mut st = WIDGET.lock().unwrap_or_else(|e| e.into_inner());
        let changed = if st.flyout_width > 0 {
            // A drag while a tray is out belongs to the tray. The window's own
            // minimum (sidebar + FLYOUT_MIN, installed by `derive_rect`) is
            // what stops the drag eating into the sidebar in the first place;
            // this clamp is the backstop for the frames where the OS has not
            // applied it yet.
            let ceiling = g.work_w.saturating_sub(st.base_width).max(1);
            let floor = ((FLYOUT_MIN_WIDTH_LOGICAL * g.scale).round() as u32)
                .max(1)
                .min(ceiling);
            let next = size
                .width
                .saturating_sub(st.base_width)
                .clamp(floor, ceiling);
            let changed = next != st.flyout_width;
            st.flyout_width = next;
            changed
        } else {
            let next = size.width.clamp(g.min_width, g.max_width);
            let changed = next != st.base_width;
            st.base_width = next;
            changed
        };
        st.monitor = Some(g);
        (derive_rect(&st, side, &g), changed)
    };

    // Re-pin. Dragging the DOCKED edge (rather than the free one) would walk
    // the sidebar off the monitor edge it is welded to; this puts it back. A
    // no-op for an ordinary free-edge drag, where the OS already holds the
    // opposite edge fixed - so it cannot loop.
    //
    // `inner_position()`, not `outer_position()`: `rect` is CLIENT space, and
    // comparing it against a window rect made every single resize event look
    // like a mispin and fire a `set_position` that moved the window by a frame
    // inset - which arrives as another event, and so on.
    let frame = frame_inset(window);
    if let Ok(pos) = window.inner_position() {
        if pos.x != rect.x || pos.y != rect.y {
            let _ = window.set_position(frame.outer_origin(rect.x, rect.y));
        }
    }
    // Only when the derived rect actually disagrees with what the OS did -
    // true when a drag went past a floor, and otherwise not, so this does not
    // fight the drag frame by frame.
    if size.width != rect.width || size.height != rect.height {
        let _ = window.set_size(PhysicalSize::new(rect.width, rect.height));
    }
    if changed {
        schedule_geometry_emit(window);
    }
}

/// Hard floor for the FLOATING widget, enforced at the event level: the
/// config's minWidth/minHeight SHOULD cover this, but a user-reported
/// real-machine case still shrank the undecorated window below them (tao's
/// custom resize borders + restored window-state interact unreliably here),
/// which breaks the UI layout. Both axes are capped by the work area so the
/// floor can never exceed what the monitor can actually show.
///
/// The docked case does NOT come through here: its floor is the quarter-screen
/// minimum in `derive_rect`, applied by `on_widget_resized` above.
/// CLIENT space on both sides: `size` is the WM_SIZE client size and `set_size`
/// is `set_inner_size`, so no conversion belongs here. The matching OUTER track
/// floor is installed by `float_widget`.
fn enforce_floating_floor(window: &tauri::WebviewWindow, size: PhysicalSize<u32>) {
    let scale = window.scale_factor().unwrap_or(1.0);
    let (work_w, work_h) = monitor_of(window)
        .map(|m| {
            let w = m.work_area();
            (w.size.width.max(1), w.size.height.max(1))
        })
        .unwrap_or((u32::MAX, u32::MAX));
    let min_w = ((FLOAT_MIN_WIDTH_LOGICAL * scale).round() as u32)
        .max(1)
        .min(work_w);
    let min_h = ((FLOAT_MIN_HEIGHT_LOGICAL * scale).round() as u32)
        .max(1)
        .min(work_h);
    if size.width < min_w || size.height < min_h {
        let _ = window.set_size(PhysicalSize::new(
            size.width.max(min_w),
            size.height.max(min_h),
        ));
    }
}

/// Re-applies the dock when the widget's monitor or scale factor changes.
/// Called from `lib.rs`'s window-event handler; a no-op unless something
/// actually moved, so the `set_position`/`set_size` it performs (which fire
/// more `Moved`/`Resized` events) cannot loop.
pub(crate) fn revalidate_widget_geometry(window: &tauri::WebviewWindow, force: bool) {
    let st = widget_state();
    let WidgetMode::Docked(side) = st.mode else {
        return; // floating: the user owns the geometry
    };
    // A window mid-glide straddles a monitor boundary, and a collapsed one
    // sits almost entirely on the NEXT display - `current_monitor()` answers
    // truthfully in both cases and re-docking on that answer would yank the
    // widget back or hand it to the wrong screen.
    // A minimized window is on no monitor in any meaningful sense, and
    // re-docking one writes its restore rect. See `is_iconic`.
    if ANIM_ACTIVE.load(Ordering::SeqCst) || st.collapsed || is_iconic(window) {
        return;
    }
    let Ok(live) = live_dock_geometry(window) else {
        return;
    };
    if !force && st.monitor.map(|g| g.signature) == Some(live.signature) {
        return;
    }
    tracing::info!(
        scale = live.scale,
        work_w = live.work_w,
        work_h = live.work_h,
        "widget monitor/scale changed - re-applying dock geometry"
    );
    if let Err(e) = apply_docked(window, side, claim_generation(), false) {
        tracing::warn!(error = %e, "failed to re-apply dock geometry");
    }
}

// ---------------------------------------------------------------------------
// Global hotkey
// ---------------------------------------------------------------------------

/// Binds `accelerator` (Tauri accelerator syntax, e.g.
/// `"CommandOrControl+Alt+D"`) as a system-wide hotkey, replacing whatever
/// was bound before. An empty/whitespace accelerator unbinds and registers
/// nothing - that is how the frontend disables the feature.
///
/// Registration lives entirely in Rust: the frontend calls this one command,
/// so `capabilities/default.json` needs no `global-shortcut:*` grants at all.
/// Nothing is registered at startup; the frontend calls this once settings
/// load and again whenever the preference changes.
///
/// On press the widget is surfaced by `surface_widget` - shown, focused,
/// un-minimized and un-collapsed, exactly as the tray and the command palette
/// surface it. (`collapsed` lives in `WidgetState` here in Rust, so no frontend
/// round-trip is involved; `devkit://hotkey` is still emitted, but purely as a
/// notification.)
///
/// Errors (bad syntax, or an accelerator another application already owns)
/// come back as a plain `Err(String)` for the caller to surface; nothing
/// panics, and a failed registration leaves the PREVIOUS binding in place
/// rather than silently disabling the hotkey.
///
/// JS: `invoke("register_global_hotkey", { accelerator })`.
#[tauri::command]
pub async fn register_global_hotkey(
    app: tauri::AppHandle,
    accelerator: String,
) -> Result<(), String> {
    let wanted = accelerator.trim().to_string();
    let shortcuts = app.global_shortcut();
    let mut current = HOTKEY_ACCEL.lock().unwrap_or_else(|e| e.into_inner());

    if current.as_deref() == Some(wanted.as_str()) {
        return Ok(()); // already bound to exactly this
    }

    let previous = current.take();
    if let Some(prev) = previous.as_deref() {
        if let Err(e) = shortcuts.unregister(prev) {
            tracing::warn!(accelerator = %prev, error = %e, "failed to unregister previous global hotkey");
        }
    }

    if wanted.is_empty() {
        tracing::info!("global hotkey disabled");
        return Ok(());
    }

    match shortcuts.on_shortcut(wanted.as_str(), on_hotkey_pressed) {
        Ok(()) => {
            tracing::info!(accelerator = %wanted, "global hotkey registered");
            *current = Some(wanted);
            Ok(())
        }
        Err(e) => {
            // Put the old binding back so a rejected new accelerator doesn't
            // cost the user the hotkey they already had working.
            if let Some(prev) = previous {
                if shortcuts.on_shortcut(prev.as_str(), on_hotkey_pressed).is_ok() {
                    *current = Some(prev);
                }
            }
            Err(format!(
                "could not register global hotkey '{wanted}': {e} \
                 (it may already be taken by another application)"
            ))
        }
    }
}

fn on_hotkey_pressed(app: &tauri::AppHandle, shortcut: &Shortcut, event: ShortcutEvent) {
    // The OS reports both edges; only act on the press.
    if event.state != ShortcutState::Pressed {
        return;
    }
    // Same path as the tray, the palette and a second launch - including the
    // un-collapse, which used to be the hotkey's own private extra step,
    // performed by a listener in WidgetApp.tsx that nothing else triggered.
    if let Err(e) = surface_widget(app) {
        tracing::warn!(error = %e, "global hotkey could not surface the widget");
    }
    // Still emitted: it is a public signal that the accelerator fired, and the
    // Settings dialog and any future listener may care. It is no longer load-
    // bearing for un-collapsing.
    let _ = app.emit(
        "devkit://hotkey",
        serde_json::json!({ "accelerator": shortcut.into_string() }),
    );
}
