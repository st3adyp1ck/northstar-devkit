import { useEffect } from "react";
import { useSettingsStore } from "../stores/useSettingsStore";

/**
 * Keeps `<html data-animations="off">` (attribute absent otherwise) in sync
 * with `settings.preferences.enableAnimations` - the in-app "Animations"
 * checkbox in QuickActionsPanel. tokens.css's `:root[data-animations="off"]`
 * block is the app-level twin of its `prefers-reduced-motion` block: it
 * zeroes the exact same --duration-* custom properties, so every consumer
 * that already respects OS-level reduced motion (motion.ts's
 * motionReduced()/motionDuration(), GitGraph's draw-in, every plain-CSS
 * transition/animation built on the tokens) picks up the in-app setting too,
 * with no further wiring.
 *
 * Call this once per window root (WidgetApp, ControlCenterApp) rather than
 * per-panel - `document.documentElement` is shared per-window regardless of
 * how many components call it, so a second call (e.g. alongside
 * QuickActionsPanel's own `refresh()` in the widget window) is harmless,
 * just a redundant settings.get. The Control Center has no other reason to
 * load settings today, so its root needs this to populate the store at all.
 *
 * Deliberately leaves the attribute unset - never defaults to "off" - while
 * settings are still loading or failed to load, so a cold start (or a
 * settings.get error) never flashes animations off for a beat before
 * snapping back on.
 */
export function useSyncAnimationsAttribute(): void {
  const settings = useSettingsStore((s) => s.settings);
  const refresh = useSettingsStore((s) => s.refresh);

  useEffect(() => {
    refresh();
  }, [refresh]);

  useEffect(() => {
    const root = document.documentElement;
    if (settings?.preferences.enableAnimations === false) {
      root.dataset.animations = "off";
    } else {
      delete root.dataset.animations;
    }
  }, [settings]);
}
