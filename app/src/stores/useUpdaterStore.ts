import { create } from "zustand";
import { checkForUpdate, installAndRelaunch, type Update, type UpdateDownloadProgress } from "../lib/updater";
import { useSettingsStore } from "./useSettingsStore";

export type UpdateCheckStatus = "idle" | "checking" | "available" | "up-to-date" | "error" | "downloading" | "installing";

interface UpdaterState {
  status: UpdateCheckStatus;
  update: Update | null;
  error: string | null;
  progress: UpdateDownloadProgress | null;
  /**
   * True once the user has dismissed the currently-known update via
   * "Later." Consumers that decide whether to *show* the dialog (see
   * WidgetApp.tsx) should treat status "available" as dismissible via
   * this flag; every other status (checking/downloading/installing) is
   * either not yet dismissible or already past the point of dismissing.
   * Cleared at the start of every fresh checkNow() so a manual re-check
   * (or the next scheduled auto-check) can surface the prompt again.
   */
  dismissed: boolean;
  checkNow: () => Promise<void>;
  installAndRestart: () => Promise<void>;
  dismiss: () => void;
}

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

/**
 * Single shared source of truth for the app's update-check/download/
 * install state - a zustand store (same pattern as useSettingsStore,
 * useProjectStore) rather than plain component state so every consumer
 * in the widget window (WidgetApp's dialog, QuickActionsPanel's manual
 * button + inline indicator) reads and drives the exact same in-flight
 * check instead of each owning its own copy.
 *
 * The mount-time "auto-check if stale" decision does NOT live here - it
 * needs settings.preferences (updateCheckEnabled, lastUpdateCheckUtc)
 * and a "have I already tried this mount" guard, both of which are React
 * lifecycle concerns. That lives in hooks/useUpdateCheck.ts, which is
 * meant to be called exactly once (from WidgetApp.tsx). Everything else
 * - including QuickActionsPanel's manual "Check for Updates" - should
 * read/drive this store directly so there is only ever one 24h-throttled
 * auto-check source of truth.
 */
export const useUpdaterStore = create<UpdaterState>((set, get) => ({
  status: "idle",
  update: null,
  error: null,
  progress: null,
  dismissed: false,

  checkNow: async () => {
    const { status } = get();
    if (status === "checking" || status === "downloading" || status === "installing") return;

    set({ status: "checking", error: null, dismissed: false });
    try {
      const update = await checkForUpdate();
      set(update ? { status: "available", update } : { status: "up-to-date", update: null });
    } catch (err) {
      set({ status: "error", error: errorMessage(err) });
    } finally {
      // Record the attempt regardless of outcome, so a persistent offline
      // state or a broken feed doesn't turn into a check running on every
      // single app start - see useUpdateCheck.ts's staleness math.
      void useSettingsStore.getState().update({ lastUpdateCheckUtc: new Date().toISOString() });
    }
  },

  installAndRestart: async () => {
    const { update, status } = get();
    if (!update || status === "downloading" || status === "installing") return;

    set({ status: "downloading", progress: { downloaded: 0, total: null }, error: null });
    try {
      await installAndRelaunch(update, (progress) => set({ progress }));
      // Reached only if relaunch() resolved without the process actually
      // exiting (unusual) - otherwise the app is gone before this runs.
      set({ status: "installing" });
    } catch (err) {
      set({ status: "error", error: errorMessage(err) });
    }
  },

  dismiss: () => set({ dismissed: true }),
}));
