import { useSyncExternalStore } from "react";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { listen } from "@tauri-apps/api/event";

interface VisibilityEventPayload {
  label: string;
  visible: boolean;
}

/**
 * True while this window is actually visible to the user. Backs every
 * panel's polling so a widget hidden to the tray costs ~0% CPU - the
 * single invariant the old WPF widget's whole 4.0 "lightweight pass" was
 * about (gui/DevKit-Widget.ps1: "every timer stops" when hidden).
 *
 * Combines two signals, last-write-wins:
 *  - The Page Visibility API (`document.hidden`), which correctly tracks
 *    things like minimize/restore - the OS window still exists then, just
 *    iconified/occluded, which WebView2's window-occlusion tracking picks
 *    up on its own.
 *  - An explicit `devkit://visibility` event, emitted by the Rust side
 *    right after every `window.hide()`/`show()` (see commands.rs's
 *    `set_window_visible`/`toggle_window_visibility`, used by every hide
 *    or show path - the tray icon, its menu, the widget's own hide button,
 *    the titlebar close button, and the initial post-setup show).
 *
 * The second signal isn't redundant belt-and-suspenders: Tauri's
 * `WebviewWindow::hide()`/`show()` only move the top-level OS window and
 * never call the embedded WebView2 controller's own `SetIsVisible` - the
 * API that actually drives `document.hidden` inside the page, per
 * WebView2's docs. That call happens exactly once, at webview creation,
 * using whatever visibility the window was created with. Every window here
 * is created hidden (see tauri.conf.json) and shown right after - without
 * the explicit event, `document.hidden` can end up permanently stuck
 * reporting `true`, with nothing left to ever correct it and polling never
 * starting at all. If that turns out not to hold on some WebView2 version,
 * the `document.hidden` listener is still there as a second, independent
 * way to end up in the correct state.
 *
 * Shared, not per-hook: a window mounts this hook ten-plus times (every
 * usePolledRpc instance, the TitleBar indicators, the CSS-animation gate),
 * and each instance used to attach its own `devkit://visibility` listener
 * and fire its own one-shot `isVisible()` IPC on mount. The signals are
 * window-global, so the module now keeps ONE subscription per window - the
 * first subscriber attaches it, the last detach tears it down - and every
 * hook instance just reads the shared value through useSyncExternalStore.
 * Initial state is unchanged: with no subscription started yet, the snapshot
 * falls back to `!document.hidden`, exactly what the old per-instance
 * useState seeded itself with.
 */

let current: boolean | undefined;
const listeners = new Set<() => void>();

// Bump-per-start generation token: async work from a torn-down subscription
// (a StrictMode remount, every consumer unmounting) can still resolve
// afterwards, and must neither leak a listener nor clobber the new
// generation's state. Same discipline as the old per-instance effect's
// `cancelled` flag.
let generation = 0;
let removeDocumentListener: (() => void) | undefined;
let unlistenDevkit: (() => void) | undefined;

function emit(gen: number, visible: boolean): void {
  if (gen !== generation) return;
  if (current === visible) return;
  current = visible;
  for (const notify of listeners) notify();
}

function startSharedSubscription(): void {
  const gen = ++generation;
  current = !document.hidden;
  const onDocumentChange = () => emit(gen, !document.hidden);
  document.addEventListener("visibilitychange", onDocumentChange);
  removeDocumentListener = () => document.removeEventListener("visibilitychange", onDocumentChange);

  void (async () => {
    const win = getCurrentWindow();
    const label = win.label;
    const un = await listen<VisibilityEventPayload>("devkit://visibility", (e) => {
      if (e.payload.label === label) emit(gen, e.payload.visible);
    });
    // The subscription may have been torn down while `listen` was resolving -
    // unlisten right away rather than stashing a handle the current
    // generation would never call.
    if (gen !== generation) {
      un();
    } else {
      unlistenDevkit = un;
    }
    // THEN ask the OS what is actually true right now. Neither signal above
    // covers a window that was created hidden and never shown: no
    // set_window_visible call has run for it, so the devkit:// event never
    // fires - and `document.hidden` turns out to be FALSE there anyway
    // (measured on WebView2 151: the webview reports "visible" for the
    // never-shown window, because Chromium disables occlusion tracking
    // entirely for transparent windows). That is exactly the Control Center
    // window at boot, which therefore spent its life polling and spinning a
    // loading spinner at 60fps into a window nobody had ever seen - about a
    // third of a core, measured.
    //
    // The OS answer is used AS-IS, not ANDed with !document.hidden: the
    // docstring's contingency is document.hidden stuck TRUE on a
    // created-hidden window, and folding it in here would nail this window
    // invisible forever on exactly that WebView2 version. This is a one-shot
    // seed in a last-write-wins design - the two listeners above keep
    // correcting it, and events/responses do not share one ordered channel,
    // so no ordering guarantee is claimed beyond "the seed reflects the OS
    // state at resolution time".
    try {
      const actuallyVisible = await win.isVisible();
      emit(gen, actuallyVisible);
    } catch {
      // Query failed - keep whatever the other two signals said.
    }
  })();
}

function stopSharedSubscription(): void {
  generation++;
  removeDocumentListener?.();
  removeDocumentListener = undefined;
  unlistenDevkit?.();
  unlistenDevkit = undefined;
  current = undefined;
}

function subscribe(notify: () => void): () => void {
  listeners.add(notify);
  if (listeners.size === 1) startSharedSubscription();
  return () => {
    listeners.delete(notify);
    if (listeners.size === 0) stopSharedSubscription();
  };
}

function getSnapshot(): boolean {
  return current ?? !document.hidden;
}

export function useVisibility(): boolean {
  return useSyncExternalStore(subscribe, getSnapshot);
}
