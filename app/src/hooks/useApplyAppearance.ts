import { useEffect, useRef } from "react";
import { invoke } from "@tauri-apps/api/core";
import { useReducedMotion } from "framer-motion";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { emit } from "@tauri-apps/api/event";
import { useSettingsStore } from "../stores/useSettingsStore";
import { deriveAccentRamp, getThemePreset } from "../lib/themes";

/** Clamp uiScale to the supported zoom range; non-finite/legacy values fall back to 1. */
export function clampUiScale(scale: number): number {
  if (!Number.isFinite(scale)) return 1;
  return Math.min(1.4, Math.max(0.8, scale));
}

/** The root properties that carry a UI scale. Written and cleared as a unit - never one without the other. */
const SCALE_PROPS = ["zoom", "--ui-scale"] as const;

/**
 * The custom properties a given UI scale needs - ALWAYS as a pair.
 *
 * CSS `zoom` scales rendered content but vh units still resolve against the
 * UNZOOMED viewport, so an element sized 100vh renders at only 100vh * scale
 * and leaves a transparent gap at the window bottom when scale < 1 (both
 * windows are transparent:true, so the gap is literally see-through -
 * 208px of it at 80%). The window roots compensate with
 * `height: calc(100vh / var(--ui-scale, 1))`, which only works if
 * --ui-scale is written at the same instant as `zoom`. Anything that
 * previews a scale must go through here rather than writing `zoom` alone.
 *
 * Empty at scale 1: the stylesheet default (--ui-scale fallback 1, no zoom)
 * is already correct, and writing nothing keeps the removal path simple.
 */
export function uiScaleProperties(scale: number): Record<string, string> {
  const clamped = clampUiScale(scale);
  if (clamped === 1) return {};
  return Object.fromEntries(SCALE_PROPS.map((prop) => [prop, String(clamped)]));
}

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
 *
 * While settings are still loading (or failed to load) motion is allowed,
 * matching useSyncAnimationsAttribute: never flash animations off and back on.
 */
export function useAnimationsEnabled(): boolean {
  const osReducedMotion = useReducedMotion();
  const enabled = useSettingsStore((s) => s.settings?.preferences.enableAnimations);
  return !osReducedMotion && enabled !== false;
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
 * outranks tokens.css's :root block; we track exactly which properties we
 * set and remove the stale ones on every change, so switching back to
 * northstar (empty override set) genuinely returns to the stylesheet
 * defaults instead of leaving another theme's values behind. The
 * data-animations attribute is useSyncAnimationsAttribute's job - never
 * touched here.
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
  const appliedProps = useRef<Set<string>>(new Set());
  const dockApplied = useRef(false);

  // Same guard style as ConfirmDialogHost: fetch only if nothing has yet -
  // both App roots already refresh, this just makes the hook self-sufficient.
  useEffect(() => {
    if (!settings) void refresh();
  }, [settings, refresh]);

  useEffect(() => {
    // While loading (or failed to load), leave the stylesheet defaults
    // alone - never flash a theme guess.
    if (!settings) return;
    const prefs = settings.preferences;

    const desired: Record<string, string> = { ...getThemePreset(prefs.appTheme).overrides };

    if (prefs.accentColor) {
      const ramp = deriveAccentRamp(prefs.accentColor);
      if (ramp) Object.assign(desired, ramp);
    }

    const family = prefs.fontFamily?.trim();
    if (family) {
      // A preset stack already carries its own fallbacks (has commas); a
      // bare custom family name gets the default stack appended behind it.
      desired["--font-sans"] = family.includes(",")
        ? family
        : `${family}, "Segoe UI Variable", "Segoe UI", system-ui, sans-serif`;
    }

    // zoom + --ui-scale, always together - see uiScaleProperties.
    Object.assign(desired, uiScaleProperties(prefs.uiScale));

    const style = document.documentElement.style;
    // Clear stale properties before writing the new ones. SCALE_PROPS are in
    // the sweep unconditionally, not just when this hook set them: the
    // Settings slider writes the same pair directly for its live preview, so
    // at uiScale 1 (where `desired` carries neither) an orphaned preview has
    // to be cleared by a hook that never set it. Removal + set happen in one
    // synchronous block, so there is no intermediate paint.
    for (const prop of new Set([...appliedProps.current, ...SCALE_PROPS])) {
      if (!(prop in desired)) style.removeProperty(prop);
    }
    for (const [prop, value] of Object.entries(desired)) {
      style.setProperty(prop, value);
    }
    appliedProps.current = new Set(Object.keys(desired));
  }, [settings, saveError]);

  // If the hook ever unmounts (it shouldn't - TitleBar lives as long as the
  // window), put the stylesheet back the way we found it.
  useEffect(() => {
    return () => {
      const style = document.documentElement.style;
      for (const prop of appliedProps.current) style.removeProperty(prop);
      appliedProps.current = new Set();
    };
  }, []);

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
