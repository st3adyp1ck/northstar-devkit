import { create } from "zustand";
import { useErrorStore } from "../../stores/useErrorStore";

/**
 * Open/closed state for the Error Center dialog, kept in a store rather than
 * component state so ANY control in a window can open it without the caller
 * having to own dialog state or thread a prop down: mount <ErrorCenterHost/>
 * once near the window root, then call openErrorCenter() from a titlebar
 * button, a rail button, a panel row - anywhere.
 *
 * Per-window, like every other zustand store here (each Tauri window is its
 * own webview). Opening the Error Center in the widget does not open it in
 * the Control Center.
 */
interface ErrorCenterState {
  open: boolean;
  openCenter: () => void;
  closeCenter: () => void;
  toggleCenter: () => void;
}

export const useErrorCenterStore = create<ErrorCenterState>((set) => ({
  open: false,
  openCenter: () => set({ open: true }),
  closeCenter: () => set({ open: false }),
  toggleCenter: () => set((s) => ({ open: !s.open })),
}));

/** Imperative opener for non-React call sites (event handlers, menus). */
export function openErrorCenter(): void {
  useErrorCenterStore.getState().openCenter();
}

export function closeErrorCenter(): void {
  useErrorCenterStore.getState().closeCenter();
}

export function toggleErrorCenter(): void {
  useErrorCenterStore.getState().toggleCenter();
}

/**
 * Reactive count of entries the user hasn't looked at yet - for a badge on
 * whatever control opens the Error Center. Returns a number (not a derived
 * array), so it's safe as a zustand selector.
 */
export function useUnseenErrorCount(): number {
  return useErrorStore((s) => s.entries.reduce((n, e) => (s.seen.has(e.id) ? n : n + 1), 0));
}

/** Reactive count of everything currently held, both sections. */
export function useErrorCount(): number {
  return useErrorStore((s) => s.entries.length);
}
