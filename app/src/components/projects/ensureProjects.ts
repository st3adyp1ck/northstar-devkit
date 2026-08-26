import { useEffect } from "react";
import { create } from "zustand";
import { emit, listen } from "@tauri-apps/api/event";
import { useProjectStore } from "../../stores/useProjectStore";

/**
 * Broadcast whenever the project registry changes (active project switched,
 * project linked / renamed / pinned / repaired / unlinked). Every window
 * that has ever called ensureProjectsLoaded listens and re-reads, which is
 * what keeps the widget's picker and the Control Center's picker from
 * drifting apart - they're separate webviews with separate stores, so a
 * mutation in one is otherwise invisible to the other until a reload.
 *
 * Fire-and-forget: emitters call notifyProjectsChanged() after a successful
 * mutation, and the emitting window receives its own broadcast too (one
 * redundant refresh, no loop - a refresh never emits).
 */
export const PROJECTS_CHANGED_EVENT = "devkit://projects-changed";

let inFlight: Promise<void> | null = null;
let loadedOnce = false;
let listening = false;

function installProjectsChangedListener(): void {
  if (listening) return;
  listening = true;
  listen(PROJECTS_CHANGED_EVENT, () => {
    void ensureProjectsLoaded(true);
  }).catch(() => {
    listening = false; // no cross-window sync in this window; local reads still work
  });
}

/** Tells every window (this one included) to re-read the project registry. */
export function notifyProjectsChanged(): void {
  void emit(PROJECTS_CHANGED_EVENT).catch(() => {});
}

/**
 * Idempotent "make sure this window's project store has data" call.
 *
 * The bug this exists to kill: useProjectStore is per-window (every Tauri
 * window is a separate webview with its own zustand instances), and the
 * only thing that ever called `refresh()` was <ProjectPicker/>, which was
 * mounted exclusively in the WIDGET's TitleBar. In the Control Center
 * `active` was therefore null forever, which made ToolRunDialog's
 * `requiresProject && !active` check permanently true and hard-disabled Run
 * for every project-scoped tool in the catalog.
 *
 * Rather than making one component's mount the load-bearing trigger, every
 * consumer that needs projects calls through here: the picker on mount, the
 * command palette when it opens, the project manager when it opens. The
 * in-flight promise collapses concurrent callers into one RPC round-trip,
 * and `force` lets a surface that's about to *show* the list ask for fresh
 * data (which also recovers from a first load that failed because the
 * sidecar wasn't up yet - useProjectStore.refresh swallows its own errors).
 */
export function ensureProjectsLoaded(force = false): Promise<void> {
  installProjectsChangedListener();
  if (inFlight) return inFlight;
  if (loadedOnce && !force) return Promise.resolve();
  inFlight = useProjectStore
    .getState()
    .refresh()
    .finally(() => {
      inFlight = null;
      loadedOnce = true;
    });
  return inFlight;
}

/** Mount-time form of ensureProjectsLoaded, for components that render project state. */
export function useEnsureProjects(): void {
  useEffect(() => {
    void ensureProjectsLoaded();
  }, []);
}

interface ProjectManagerState {
  open: boolean;
  openManager: () => void;
  closeManager: () => void;
}

/**
 * Open/close state for the project manager dialog, kept in a store rather
 * than local component state so surfaces that can't host the dialog can
 * still ask for it - specifically the command palette, which is mounted
 * above the app root (outside <ConfirmDialogHost/>) and so can't render a
 * dialog whose Remove action needs useConfirmDestructive. <ProjectPicker/>
 * owns the actual mount; anything can flip this.
 */
export const useProjectManagerStore = create<ProjectManagerState>((set) => ({
  open: false,
  openManager: () => set({ open: true }),
  closeManager: () => set({ open: false }),
}));
