import { create } from "zustand";
import { emit, listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { rpcCall, RpcClientError } from "../lib/ipc";
import type { DevKitSettings } from "../lib/types";

/**
 * App-wide broadcast fired by whichever window just persisted a settings
 * change, carrying the freshly re-read settings object.
 *
 * Every Tauri window is its own webview with its own module graph and its
 * own zustand stores, so without this a change made in the Control Center
 * never reaches the widget (or vice versa): the widget would keep a stale
 * `widgetDockMode` while Rust had already physically moved the window,
 * leaving a "floating" window whose drag region is still withheld.
 *
 * Emitted with `@tauri-apps/api/event`'s app-wide `emit` (NOT `emitTo`, and
 * NOT a window-scoped emit - neither reaches sibling webviews reliably) and
 * received by the module-level `listen` installed below, once per webview,
 * the first time this module is imported. That means EVERY consumer of this
 * store is cross-window fresh with zero per-component wiring.
 */
export const SETTINGS_CHANGED_EVENT = "devkit://settings-changed";

export interface SettingsChangedPayload {
  /** Label of the window that wrote the change: "widget" | "control-center". */
  source: string;
  /** Full settings object exactly as `settings.set` returned it (post-merge, re-read from disk). */
  settings: DevKitSettings;
}

interface SettingsState {
  settings: DevKitSettings | null;
  /** Message from the most recent failed refresh/update, if any - callers render this rather than letting the rejection vanish silently. */
  error: string | null;
  refresh: () => Promise<void>;
  /**
   * Persists a PARTIAL preferences patch. Only the keys in `patch` are sent;
   * the sidecar merges them over whatever is on disk right now, so a write
   * built from this window's (possibly stale) copy can never revert keys
   * another window changed in the meantime.
   */
  update: (patch: Partial<DevKitSettings["preferences"]>) => Promise<void>;
}

function describeSettingsError(err: unknown, fallback: string): string {
  return err instanceof RpcClientError ? err.message : fallback;
}

/** Current webview's window label, or "" outside a Tauri context (vite dev in a plain browser, tests). */
function currentWindowLabel(): string {
  try {
    return getCurrentWindow().label;
  } catch {
    return "";
  }
}

/**
 * Saves are serialized through this promise chain: two `update()` calls in
 * flight at once would each round-trip through the sidecar and each apply
 * its own response, so the slower one's (older) response could land last and
 * revert the faster one. One at a time, in call order, removes that race
 * entirely. A rejection never poisons the chain - `.catch` re-arms it.
 */
let saveChain: Promise<void> = Promise.resolve();
/** Number of `settings.set` round-trips currently outstanding in THIS window. */
let inFlightSaves = 0;

export const useSettingsStore = create<SettingsState>((set, get) => ({
  settings: null,
  error: null,

  refresh: async () => {
    try {
      const settings = await rpcCall<DevKitSettings>("settings.get");
      // A save that started while this read was in flight wrote newer state
      // than we just read; its own response is the authority, so drop this.
      if (inFlightSaves > 0) return;
      set({ settings, error: null });
    } catch (err) {
      set({ error: describeSettingsError(err, "Could not load settings.") });
    }
  },

  update: async (patch) => {
    if (Object.keys(patch).length === 0) return;

    const run = saveChain.then(async () => {
      // Read the current settings at RUN time, not call time - an earlier
      // queued save may have landed since, and we only need schemaVersion.
      // Nothing loaded yet (an early write, e.g. the updater stamping
      // lastUpdateCheckUtc): load first rather than dropping the patch.
      let current = get().settings;
      if (!current) {
        await get().refresh();
        current = get().settings;
      }
      if (!current) return;

      set({ error: null });
      inFlightSaves += 1;
      try {
        // PATCH ONLY. Set-DevKitSettings (tools/lib/DevKit-Common.ps1) reads
        // the file back, copies every property present on the caller's
        // `preferences` over the on-disk one (Add-Member -Force) and keeps
        // the rest, so omitted keys are preserved rather than reverted.
        // schemaVersion must be included: the same merge writes it through
        // unconditionally, and omitting it would persist a null.
        const saved = await rpcCall<DevKitSettings>("settings.set", {
          settings: { schemaVersion: current.schemaVersion, preferences: patch },
        });
        set({ settings: saved, error: null });
        void broadcastSettings(saved);
      } catch (err) {
        // Nothing was applied optimistically, so the store still holds the
        // last-persisted truth - callers with draft state (sliders) resync
        // off `error` flipping non-null.
        set({ error: describeSettingsError(err, "Could not save settings.") });
      } finally {
        inFlightSaves -= 1;
      }
    });

    saveChain = run.catch(() => {});
    return run;
  },
}));

/** Tells every other window what we just persisted. Best-effort: a failed emit only costs freshness. */
async function broadcastSettings(settings: DevKitSettings): Promise<void> {
  const payload: SettingsChangedPayload = { source: currentWindowLabel(), settings };
  try {
    await emit(SETTINGS_CHANGED_EVENT, payload);
  } catch (err) {
    console.warn("settings-changed broadcast failed:", err);
  }
}

let syncInstalled = false;

/**
 * Installs the cross-window listener. Called once at module scope - the
 * store itself owns the subscription so no window root or component has to
 * remember to opt in. Never unlistened: the subscription is meant to live
 * exactly as long as the webview does.
 */
function installCrossWindowSync(): void {
  if (syncInstalled) return;
  syncInstalled = true;
  const self = currentWindowLabel();

  listen<SettingsChangedPayload>(SETTINGS_CHANGED_EVENT, (evt) => {
    const payload = evt.payload;
    if (!payload) return;
    // Our own write - `emit` is app-wide and echoes back to the emitter. The
    // response from settings.set already applied it here.
    if (self && payload.source === self) return;

    if (inFlightSaves > 0) {
      // We have a write of our own outstanding. Applying a snapshot taken
      // before it would be a coin flip on arrival order, so wait for our
      // chain to drain and re-read the merged truth instead.
      saveChain = saveChain.then(() => useSettingsStore.getState().refresh()).catch(() => {});
      return;
    }

    if (payload.settings?.preferences) {
      useSettingsStore.setState({ settings: payload.settings, error: null });
    } else {
      // Payload shape we don't recognise (older/newer build): fall back to a
      // plain re-read rather than ignoring the change.
      void useSettingsStore.getState().refresh();
    }
  }).catch((err) => {
    // No Tauri IPC (browser dev server) or the event capability is missing:
    // the app still works, it just loses cross-window freshness.
    console.warn("settings-changed listener failed to attach:", err);
  });
}

installCrossWindowSync();
