import { useEffect, useRef } from "react";
import { useSettingsStore } from "../stores/useSettingsStore";
import { useUpdaterStore } from "../stores/useUpdaterStore";

const AUTO_CHECK_INTERVAL_MS = 24 * 60 * 60 * 1000;

function isStale(lastUpdateCheckUtc: string | null): boolean {
  if (!lastUpdateCheckUtc) return true;
  const last = new Date(lastUpdateCheckUtc).getTime();
  if (Number.isNaN(last)) return true; // malformed value on disk - treat as never checked
  return Date.now() - last > AUTO_CHECK_INTERVAL_MS;
}

/**
 * Owns the app's ONE auto-check-on-mount trigger. Call this exactly once,
 * from WidgetApp.tsx (the always-on window) - not from QuickActionsPanel
 * or anywhere else. Actual state lives in useUpdaterStore (shared across
 * every component in the window), so other consumers that just need to
 * read status or fire a manual check - QuickActionsPanel's button - should
 * select from useUpdaterStore directly instead of calling this hook again,
 * which would arm a second independent 24h-staleness check.
 *
 * On mount, once settings have loaded: if
 * settings.preferences.updateCheckEnabled is true and lastUpdateCheckUtc
 * is null or more than 24h old, silently kicks off a background check.
 * Never installs anything on its own - checkNow() only ever surfaces
 * that an update exists (see useUpdaterStore.checkNow); installation is a
 * separate, explicit user action via installAndRestart().
 *
 * lastUpdateCheckUtc itself is stamped by useUpdaterStore.checkNow after
 * every check (auto or manual) completes, success or failure - not here -
 * so a manual "Check for Updates" click from QuickActionsPanel also
 * resets the 24h clock without needing to go through this hook.
 */
export function useUpdateCheck() {
  const settings = useSettingsStore((s) => s.settings);
  const status = useUpdaterStore((s) => s.status);
  const update = useUpdaterStore((s) => s.update);
  const error = useUpdaterStore((s) => s.error);
  const progress = useUpdaterStore((s) => s.progress);
  const dismissed = useUpdaterStore((s) => s.dismissed);
  const checkNow = useUpdaterStore((s) => s.checkNow);
  const installAndRestart = useUpdaterStore((s) => s.installAndRestart);
  const dismiss = useUpdaterStore((s) => s.dismiss);

  const triggered = useRef(false);

  useEffect(() => {
    if (triggered.current || !settings) return;
    triggered.current = true;

    if (!settings.preferences.updateCheckEnabled) return;
    if (isStale(settings.preferences.lastUpdateCheckUtc)) {
      void checkNow();
    }
  }, [settings, checkNow]);

  return { status, update, error, progress, dismissed, checkNow, installAndRestart, dismiss };
}
