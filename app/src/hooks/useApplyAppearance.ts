import { useEffect, useRef } from "react";
import { invoke } from "@tauri-apps/api/core";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { useSettingsStore } from "../stores/useSettingsStore";
import { deriveAccentRamp, getThemePreset } from "../lib/themes";

/** Clamp uiScale to the supported zoom range; non-finite/legacy values fall back to 1. */
export function clampUiScale(scale: number): number {
  if (!Number.isFinite(scale)) return 1;
  return Math.min(1.4, Math.max(0.8, scale));
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

    const scale = clampUiScale(prefs.uiScale);
    if (scale !== 1) desired["zoom"] = String(scale);

    const style = document.documentElement.style;
    for (const prop of appliedProps.current) {
      if (!(prop in desired)) style.removeProperty(prop);
    }
    for (const [prop, value] of Object.entries(desired)) {
      style.setProperty(prop, value);
    }
    appliedProps.current = new Set(Object.keys(desired));
  }, [settings]);

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
    invoke("set_widget_dock", { side: settings.preferences.widgetDockMode }).catch((err) => {
      // Startup positioning is best-effort - a missing monitor mid-resume
      // shouldn't break anything else, so log rather than surface.
      console.warn("set_widget_dock (startup) failed:", err);
    });
  }, [settings]);
}
