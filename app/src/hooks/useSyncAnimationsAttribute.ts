import { useEffect } from "react";
import { useSettingsStore } from "../stores/useSettingsStore";
import { applyAnimationsAttribute } from "../lib/appearance";

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
 * Deliberately leaves the attribute ALONE - neither set nor cleared - while
 * settings are still loading or failed to load. Before settings arrive the
 * root carries whatever main.tsx painted from the previous session's
 * snapshot (lib/appearance.ts's applyCachedAppearance): "off" for a user
 * who turned animations off, absent otherwise. Clearing it here on the
 * loading pass would flash animations back on for the seconds the sidecar
 * takes to answer settings.get; defaulting to "off" would flash them off
 * for everyone else. Only a loaded settings object gets a say. The JS-side
 * twin - framer entrances gated by useAnimationsPreference - reads the same
 * snapshot for the same window of time, so the two axes agree from boot.
 */
export function useSyncAnimationsAttribute(): void {
  const settings = useSettingsStore((s) => s.settings);
  const refresh = useSettingsStore((s) => s.refresh);

  useEffect(() => {
    refresh();
  }, [refresh]);

  useEffect(() => {
    if (!settings) return;
    applyAnimationsAttribute(document.documentElement, settings.preferences.enableAnimations !== false);
  }, [settings]);
}
