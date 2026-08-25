import { create } from "zustand";
import { rpcCall, RpcClientError } from "../lib/ipc";
import type { DevKitSettings } from "../lib/types";

interface SettingsState {
  settings: DevKitSettings | null;
  /** Message from the most recent failed refresh/update, if any - callers render this rather than letting the rejection vanish silently. */
  error: string | null;
  refresh: () => Promise<void>;
  update: (patch: Partial<DevKitSettings["preferences"]>) => Promise<void>;
}

function describeSettingsError(err: unknown, fallback: string): string {
  return err instanceof RpcClientError ? err.message : fallback;
}

export const useSettingsStore = create<SettingsState>((set, get) => ({
  settings: null,
  error: null,

  refresh: async () => {
    try {
      const settings = await rpcCall<DevKitSettings>("settings.get");
      set({ settings, error: null });
    } catch (err) {
      set({ error: describeSettingsError(err, "Could not load settings.") });
    }
  },

  update: async (patch) => {
    const current = get().settings;
    if (!current) return;
    const next: DevKitSettings = {
      ...current,
      preferences: { ...current.preferences, ...patch },
    };
    set({ error: null });
    try {
      const saved = await rpcCall<DevKitSettings>("settings.set", { settings: next });
      set({ settings: saved });
    } catch (err) {
      set({ error: describeSettingsError(err, "Could not save settings.") });
    }
  },
}));
