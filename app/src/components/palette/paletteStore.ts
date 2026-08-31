import { create } from "zustand";

/**
 * The tool one palette selection asked to run. Carries enough to find the
 * catalog entry again on the receiving side (folder + script + key), plus
 * the label so a "that tool is gone" message can name it.
 *
 * `id` is the de-dupe key. Cross-window delivery emits the same request
 * twice on purpose (see CommandPalette.tsx) to survive a cold receiving
 * webview, so the store drops a repeat of the id it already handled.
 */
export interface PaletteToolRequest {
  id: string;
  folder: string;
  script: string;
  key: string;
  label: string;
}

/**
 * Tauri event carrying a PaletteToolRequest from the widget window to the
 * Control Center - the only window that can actually render a tool's run
 * dialog. Emitted with `emitTo("control-center", ...)`; ControlCenterApp
 * listens and feeds the payload straight into `requestTool` below.
 */
export const PALETTE_TOOL_EVENT = "devkit://palette-run-tool";

/**
 * Tauri event asking the widget's gauges to bounce - the payload-free twin
 * of PALETTE_TOOL_EVENT, travelling the other way. The gauges only exist in
 * the widget window, so a `/dance` typed anywhere has to arrive as an event;
 * emitting to the widget's own label works even when the widget is the
 * window that asked, which keeps CommandPalette's two cases to one path.
 */
export const PALETTE_DANCE_EVENT = "devkit://palette-dance";

interface PaletteState {
  open: boolean;
  /** Pending tool selection awaiting a host that can open its run dialog. */
  toolRequest: PaletteToolRequest | null;
  /** Last id accepted by requestTool - makes duplicate deliveries idempotent. */
  lastRequestId: string | null;
  openPalette: () => void;
  closePalette: () => void;
  togglePalette: () => void;
  requestTool: (request: PaletteToolRequest) => void;
  clearToolRequest: () => void;
}

/**
 * Window-local palette state. Each Tauri window is its own webview with its
 * own module instances, so this store is per-window by construction - which
 * is exactly what's wanted: the palette is a per-window surface, and the
 * one thing that must cross windows (a tool selection made in the widget)
 * travels as a Tauri event instead.
 */
export const usePaletteStore = create<PaletteState>((set, get) => ({
  open: false,
  toolRequest: null,
  lastRequestId: null,

  openPalette: () => set({ open: true }),
  closePalette: () => set({ open: false }),
  togglePalette: () => set({ open: !get().open }),

  requestTool: (request) => {
    if (!request || !request.id || get().lastRequestId === request.id) return;
    set({ toolRequest: request, lastRequestId: request.id, open: false });
  },

  clearToolRequest: () => set({ toolRequest: null }),
}));
