import { useEffect, useRef } from "react";
import { invoke } from "@tauri-apps/api/core";
import { useReducedMotion } from "framer-motion";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { emit } from "@tauri-apps/api/event";
import { useSettingsStore } from "../stores/useSettingsStore";
import {
  appearanceProperties,
  appearanceStorage,
  bootAppearanceHint,
  pickAppearance,
  rootAppearance,
  SCALE_PROPS,
  uiScaleProperties,
  writeCachedAppearance,
} from "../lib/appearance";

// The pure pieces (clampUiScale, uiScaleProperties, the property derivation)
// live in lib/appearance.ts so main.tsx can run them before React mounts.

/**
 * Writes a UI scale to the document root immediately - the live preview
 * behind the Settings slider, which would otherwise wait out the debounced
 * save. Writes (or clears) BOTH properties together so the preview and
 * useApplyAppearance's own write can never disagree.
 */
export function previewUiScale(scale: number): void {
  const style = document.documentElement.style;
  const props = uiScaleProperties(scale);
  if (Object.keys(props).length === 0) {
    for (const prop of SCALE_PROPS) style.removeProperty(prop);
    return;
  }
  for (const [prop, value] of Object.entries(props)) style.setProperty(prop, value);
}

/**
 * The Animations preference as it stood when this window booted - the same
 * snapshot main.tsx paints `data-animations` from - so the JS-driven motion
 * gates below start in agreement with the CSS tokens instead of waiting on
 * settings.get. True when there is no snapshot, matching the preference's
 * default. Settings replace it the moment they arrive.
 */
const bootAnimationsHint: boolean = bootAppearanceHint()?.enableAnimations ?? true;

/**
 * The in-app Animations setting alone (no OS axis): false only when the user
 * turned it off. While settings are still loading (or failed to load) this
 * is the boot snapshot rather than a guess, so a user who turned animations
 * off never sees every panel's entrance play for the seconds the sidecar
 * takes to answer, and everyone else never sees them flash off and back on.
 * The <MotionConfig> at each window root and useAnimationsEnabled both read
 * this; nothing should read preferences.enableAnimations off the store
 * directly for a motion decision.
 */
export function useAnimationsPreference(): boolean {
  const enabled = useSettingsStore((s) => s.settings?.preferences.enableAnimations);
  return enabled === undefined ? bootAnimationsHint : enabled !== false;
}

/**
 * True when entrance/exit motion should actually play.
 *
 * Two independent axes, both of which must be clear: the OS
 * prefers-reduced-motion query AND the in-app Animations setting. Framer's
 * own `useReducedMotion()` only ever reads the media query, and
 * `MotionConfig reducedMotion="always"` only snaps POSITIONAL keys
 * (x/y/width/height/insets) - opacity and scale keep animating - so any
 * component that animates opacity or scale has to consult this to honour
 * the setting. Purely token-driven motion (CSS transitions, motion.ts's
 * motionDuration/motionReduced) already covers both via tokens.css's
 * `:root[data-animations="off"]` block and needs nothing here.
 */
export function useAnimationsEnabled(): boolean {
  const osReducedMotion = useReducedMotion();
  const enabled = useAnimationsPreference();
  return !osReducedMotion && enabled;
}

/**
 * Applies the appearance side of settings.preferences to the current
 * window, live: theme custom-property overrides (lib/themes.ts), the
 * optional accentColor ramp layered on top, the fontFamily --font-sans
 * override, and uiScale via the root element's `zoom` (well supported in
 * WebView2/Chromium). Mounted once per window from TitleBar - which both
 * windows render - so a settings change in either window restyles that
 * window without either App root needing changes.
 *
 * Everything is written as inline style on document.documentElement, which
 * outranks tokens.css's :root block, through lib/appearance.ts's shared
 * applier: it tracks exactly which properties were set and removes the
 * stale ones on every change, so switching back to northstar (empty
 * override set) genuinely returns to the stylesheet defaults instead of
 * leaving another theme's values behind. The data-animations attribute is
 * useSyncAnimationsAttribute's job - never touched here.
 *
 * FIRST PAINT. settings.get cannot answer until the PowerShell sidecar has
 * finished importing DevKit.Core.psm1 - seconds on a cold start - while
 * Rust shows the widget as soon as setup completes. So this hook also
 * persists the appearance slice to localStorage after every apply, and
 * main.tsx paints that snapshot before React mounts (applyCachedAppearance).
 * Sharing the applier is what makes that safe: the first apply here sweeps
 * whatever boot painted that settings.json turns out not to want.
 *
 * Also owns the one-shot "apply widgetDockMode on first settings load"
 * (widget window only) - the setting persisted for ages but nothing ever
 * applied it at startup until now.
 */
export function useApplyAppearance(): void {
  const settings = useSettingsStore((s) => s.settings);
  const refresh = useSettingsStore((s) => s.refresh);
  // A failed save leaves `settings` untouched, so the apply effect would
  // never re-run - and any live preview written straight to the root (the
  // Settings UI-scale slider) would stay stuck at a value that was never
  // persisted. Re-asserting on the error edge makes that self-healing even
  // if the dialog that wrote the preview has already closed.
  const saveError = useSettingsStore((s) => s.error);
  const dockApplied = useRef(false);

  // Same guard style as ConfirmDialogHost: fetch only if nothing has yet -
  // both App roots already refresh, this just makes the hook self-sufficient.
  useEffect(() => {
    if (!settings) void refresh();
  }, [settings, refresh]);

  useEffect(() => {
    // While loading (or failed to load), leave the root alone: it carries
    // either the stylesheet defaults or the previous session's snapshot,
    // both better than a guess.
    if (!settings) return;
    const appearance = pickAppearance(settings.preferences);
    rootAppearance.apply(document.documentElement.style, appearanceProperties(appearance));
    // What the next launch paints on its first frame. Written after the
    // apply so the snapshot never gets ahead of what is actually on screen.
    writeCachedAppearance(appearanceStorage(), appearance);
  }, [settings, saveError]);

  // No unmount reset, deliberately. The hook never unmounts in practice
  // (TitleBar lives as long as its window), and the last look applied is
  // the persisted preference - snapping to the stylesheet defaults on the
  // way out would read as a theme reset, and under StrictMode's dev-only
  // mount/unmount/mount it would wipe the boot snapshot before settings
  // have loaded, reintroducing the very flash this file exists to prevent.

  useEffect(() => {
    if (!settings || dockApplied.current) return;
    // One-shot per window lifetime either way - only the widget window
    // actually docks, but marking the others done skips re-checking.
    dockApplied.current = true;
    if (getCurrentWindow().label !== "widget") return;
    // Floating mode at startup: do nothing - the window-state plugin has
    // already restored the user's floating size/position, and calling the
    // dock command would clobber that with the default size. Docked modes
    // always re-pin (the whole point: the sidebar reasserts itself every
    // launch regardless of what state was saved).
    if (settings.preferences.widgetDockMode === "Floating") return;
    // savedWidth is the whole point of the remembered-width feature: WidgetApp
    // persists the sidebar's logical width on every settled resize, and this
    // is the ONLY call that hands it back. Without it Rust falls back to its
    // quarter-screen default and the width silently resets every launch.
    // Rust applies it only on the session's FIRST dock, so a stale settings
    // value can never undo a resize the user just made.
    invoke("set_widget_dock", {
      side: settings.preferences.widgetDockMode,
      savedWidth: settings.preferences.widgetSavedWidth ?? null,
    }).catch((err) => {
      // Startup positioning is best-effort - a missing monitor mid-resume
      // shouldn't break anything else, so log rather than surface.
      console.warn("set_widget_dock (startup) failed:", err);
    });
  }, [settings]);

  // Global hotkey. Rust owns the binding (commands.rs::register_global_hotkey,
  // which unbinds any previous accelerator first), but it deliberately
  // registers NOTHING at startup - it cannot know the user's preference, which
  // lives in settings.json. So the frontend has to drive it, and until it did
  // the whole feature was dead code: the default CommandOrControl+Alt+D did
  // nothing on any machine.
  //
  // Widget window only. Both windows mount a TitleBar (and therefore this
  // hook), but the accelerator is process-global - registering from both would
  // have the second window's call unbind and rebind the first's for no reason.
  //
  // Re-runs whenever the preference changes, which now includes changes made
  // in the OTHER window, since the settings store is fed by the
  // devkit://settings-changed broadcast.
  const hotkey = settings?.preferences.globalHotkey;
  useEffect(() => {
    if (hotkey === undefined) return; // settings not loaded yet
    if (getCurrentWindow().label !== "widget") return;
    invoke("register_global_hotkey", { accelerator: hotkey }).catch((err) => {
      // Expected whenever another app already owns the combination. This is
      // the ONLY place startup registration happens, and it used to stop at
      // console.warn - so a hotkey taken by another app looked identical to
      // the feature not existing. SettingsDialog listens for this event and
      // renders it in the error slot beside the field, from whichever window
      // has Settings open, so emit app-wide rather than window-scoped.
      const message = err instanceof Error ? err.message : String(err);
      console.warn(`register_global_hotkey(${hotkey}) failed:`, err);
      void emit("devkit://hotkey-error", { accelerator: hotkey, error: message });
    });
  }, [hotkey]);
}
