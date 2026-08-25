import { useEffect, useState } from "react";
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
 * the `document.hidden` listener below is still there as a second,
 * independent way to end up in the correct state.
 */
export function useVisibility(): boolean {
  const [visible, setVisible] = useState(!document.hidden);

  useEffect(() => {
    const onDocumentChange = () => setVisible(!document.hidden);
    document.addEventListener("visibilitychange", onDocumentChange);

    let unlisten: (() => void) | undefined;
    let cancelled = false;

    void (async () => {
      const label = getCurrentWindow().label;
      const un = await listen<VisibilityEventPayload>("devkit://visibility", (e) => {
        if (e.payload.label === label) setVisible(e.payload.visible);
      });
      // The effect may have been torn down while `listen` was still
      // resolving (e.g. a fast unmount) - unlisten right away instead of
      // stashing a handle nothing will ever call.
      if (cancelled) {
        un();
      } else {
        unlisten = un;
      }
    })();

    return () => {
      cancelled = true;
      document.removeEventListener("visibilitychange", onDocumentChange);
      unlisten?.();
    };
  }, []);

  return visible;
}
