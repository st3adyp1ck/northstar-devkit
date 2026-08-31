import { useEffect, useMemo, useState, type ReactNode } from "react";
import { useQuery } from "@tanstack/react-query";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { AnimatePresence, motion, MotionConfig, type Transition } from "framer-motion";
import clsx from "clsx";
import { rpcCall } from "../../lib/ipc";
import { useSettingsStore } from "../../stores/useSettingsStore";
import { useSyncAnimationsAttribute } from "../../hooks/useSyncAnimationsAttribute";
import { TitleBar } from "../../components/TitleBar";
import { ProjectPicker } from "../../components/ProjectPicker";
import { GlassPanel } from "../../components/primitives/GlassPanel";
import { Badge } from "../../components/primitives/Badge";
import { Button } from "../../components/primitives/Button";
import { ConfirmDialogHost } from "../../components/ConfirmDialogHost";
import {
  PALETTE_TOOL_EVENT,
  usePaletteStore,
  type PaletteToolRequest,
} from "../../components/palette/paletteStore";
import { ToolRunDialog } from "./ToolRunDialog";
import type { Catalog, CatalogItem, CatalogModule } from "../../lib/types";
import "./ControlCenterApp.css";

/** Small curated glyph per catalog group - not a general icon system, just enough to scan the nav at a glance. */
const GROUP_ICON: Record<string, string> = {
  Development: "\u{1F4BB}", // laptop
  "Version Control & Containers": "\u{1F500}", // twisted arrows
  "System & Workflow": "\u{2699}️", // gear
  "Maintenance & Agents": "\u{1F9F0}", // toolbox
  Network: "\u{1F4E1}", // satellite antenna
};
const ALL_ICON = "\u{1F5C2}️"; // card index dividers
const DEFAULT_GROUP_ICON = "\u{1F9E9}"; // puzzle piece, for any future/unmapped group

/**
 * Tracks the OS reduced-motion preference so the framer-motion transitions
 * below (shared-layout nav highlight, grid reflow, dialog spring) can be
 * switched to instant when the user has asked for it - CSS keyframes
 * elsewhere in this window get this for free via tokens.css's
 * `--duration-*` zeroing, but JS-driven transitions with their own
 * hardcoded/spring values (not sourced from a --duration-* token) need this
 * explicit check. This only covers the OS-level signal; the in-app
 * "Animations" setting is layered on top via <MotionConfig> below, which
 * makes framer-motion's own reduced-motion handling (transform/layout
 * animations specifically) additionally respect enableAnimations for any
 * motion.* element that doesn't consult this hook.
 */
function usePrefersReducedMotion(): boolean {
  const [reduced, setReduced] = useState(
    () => typeof window !== "undefined" && window.matchMedia("(prefers-reduced-motion: reduce)").matches,
  );
  useEffect(() => {
    const mql = window.matchMedia("(prefers-reduced-motion: reduce)");
    const onChange = () => setReduced(mql.matches);
    mql.addEventListener("change", onChange);
    return () => mql.removeEventListener("change", onChange);
  }, []);
  return reduced;
}

interface EmptyStateProps {
  icon: ReactNode;
  title: string;
  description?: string;
  action?: ReactNode;
  tone?: "default" | "danger";
}

/** Centered placeholder for loading / error / zero-result states - replaces the old plain text line. */
function EmptyState({ icon, title, description, action, tone = "default" }: EmptyStateProps) {
  return (
    <div className={clsx("control-center__state", tone === "danger" && "control-center__state--danger")}>
      <div className="control-center__state-icon">{icon}</div>
      <div className="control-center__state-title">{title}</div>
      {description && <p className="control-center__state-desc">{description}</p>}
      {action && <div className="control-center__state-action">{action}</div>}
    </div>
  );
}

export function ControlCenterApp({ embedded = false }: { embedded?: boolean }) {
  useSyncAnimationsAttribute();
  const enableAnimations = useSettingsStore((s) => s.settings?.preferences.enableAnimations);
  const {
    data: catalog,
    isLoading,
    isError,
    error,
    isFetching,
    refetch,
  } = useQuery({
    queryKey: ["catalog.get"],
    queryFn: () => rpcCall<Catalog>("catalog.get"),
    staleTime: 60_000,
  });

  const [activeGroup, setActiveGroup] = useState<string | null>(null);
  const [search, setSearch] = useState("");
  const [selected, setSelected] = useState<{ module: CatalogModule; item: CatalogItem } | null>(null);
  const [missingTool, setMissingTool] = useState<string | null>(null);
  const reducedMotion = usePrefersReducedMotion();

  const openPalette = usePaletteStore((s) => s.openPalette);
  const toolRequest = usePaletteStore((s) => s.toolRequest);
  const requestTool = usePaletteStore((s) => s.requestTool);
  const clearToolRequest = usePaletteStore((s) => s.clearToolRequest);

  /*
   * A tool picked in the WIDGET's command palette arrives here as a Tauri
   * event (the widget has no ToolRunDialog of its own), and gets funnelled
   * into the very same `toolRequest` slot the palette uses when it's
   * running inside this window - so both paths open the real run dialog
   * rather than dropping the user in the catalog to find the tool again.
   * usePaletteStore.requestTool de-dupes on the request id, which is what
   * makes the palette's deliberate double-emit safe.
   */
  useEffect(() => {
    // The standalone window stays the command palette's tool-run target.
    // With BOTH instances listening (the tray pane plus the hidden - not
    // destroyed - window), one event would open the same dialog twice.
    if (embedded) return;
    let unlisten: UnlistenFn | undefined;
    let cancelled = false;
    listen<PaletteToolRequest>(PALETTE_TOOL_EVENT, (e) => requestTool(e.payload))
      .then((fn) => {
        if (cancelled) fn();
        else unlisten = fn;
      })
      .catch(() => {
        /* no listener is survivable - the in-window palette path still works */
      });
    return () => {
      cancelled = true;
      unlisten?.();
    };
  }, [requestTool]);

  // Resolve a pending request against the catalog. Held (not dropped) while
  // the catalog is still loading, so a request that arrives before the fetch
  // resolves still opens once it does - and held through a failed load too,
  // so hitting Retry on the error state opens the tool the user asked for
  // instead of silently forgetting it.
  useEffect(() => {
    if (!toolRequest) return;
    const modules = catalog?.modules ?? [];
    if (modules.length === 0) {
      if (isLoading || isFetching || isError) return; // still arriving, or retryable - keep waiting
      setMissingTool(toolRequest.label);
      clearToolRequest();
      return;
    }
    const module = modules.find(
      (m) => m.folder === toolRequest.folder && m.items.some((i) => i.key === toolRequest.key && i.script === toolRequest.script),
    );
    const item = module?.items.find((i) => i.key === toolRequest.key && i.script === toolRequest.script);
    if (module && item) {
      setMissingTool(null);
      setSelected({ module, item });
    } else {
      setMissingTool(toolRequest.label);
    }
    clearToolRequest();
  }, [toolRequest, catalog, isLoading, isFetching, isError, clearToolRequest]);

  const groups = useMemo(() => {
    const set = new Set<string>();
    for (const m of catalog?.modules ?? []) set.add(m.group);
    return Array.from(set);
  }, [catalog]);

  const visibleModules = useMemo(() => {
    const modules = catalog?.modules ?? [];
    const q = search.trim().toLowerCase();
    return modules.filter((m) => {
      if (activeGroup && m.group !== activeGroup) return false;
      if (!q) return true;
      return (
        m.name.toLowerCase().includes(q) ||
        m.items.some((i) => i.label.toLowerCase().includes(q) || i.help.toLowerCase().includes(q))
      );
    });
  }, [catalog, activeGroup, search]);

  const navTransition: Transition = reducedMotion
    ? { duration: 0 }
    : { type: "spring", stiffness: 480, damping: 38, mass: 0.9 };
  const listTransition: Transition = reducedMotion ? { duration: 0 } : { duration: 0.22, ease: [0.2, 0.8, 0.2, 1] };
  const cardInitial = reducedMotion ? false : { opacity: 0, y: 8, scale: 0.97 };
  const cardExit = reducedMotion ? undefined : { opacity: 0, scale: 0.97 };

  return (
    // "never" (not "user") matches MotionConfig's own default - i.e. this is a
    // no-op when animations are enabled, leaving usePrefersReducedMotion above
    // as the sole OS-level check for the transitions computed from it. "always"
    // additionally reduces any *other* motion.* element under this root (e.g.
    // GlassPanel's mount fade, ConfirmDialogHost's own dialog transition) that
    // doesn't already branch on reducedMotion itself.
    <MotionConfig reducedMotion={enableAnimations === false ? "always" : "never"}>
      <ConfirmDialogHost>
        <div className={clsx("control-center", embedded && "control-center--embedded")}>
          {!embedded && (
            <TitleBar
              title="DevKit Control Center"
              showMaximize
              actions={
                <button
                  type="button"
                  className="control-center__palette-btn devkit-no-drag"
                  title="Command palette (Ctrl+K)"
                  aria-label="Open command palette"
                  onClick={openPalette}
                >
                  <kbd>Ctrl</kbd>
                  <kbd>K</kbd>
                </button>
              }
            >
              {/*
                The project picker lives in this window's chrome now, not just
                the widget's. Each Tauri window is its own webview with its own
                zustand stores, so without a picker here the Control Center's
                project store stayed empty forever and ToolRunDialog's
                `requiresProject && !active` check hard-disabled Run on every
                project-scoped tool in the catalog - while telling the user to
                go pick a project they had, in fact, already picked.
              */}
              <div className="control-center__chrome">
                <ProjectPicker className="devkit-project-picker--chrome" />
                <input
                  className="control-center__search"
                  placeholder="Search tools... (name, description)"
                  value={search}
                  onChange={(e) => setSearch(e.target.value)}
                />
              </div>
            </TitleBar>
          )}
          {embedded && (
            // Tray mode: no TitleBar (a pane has no window chrome to drag or
            // close), no ProjectPicker (the widget's own picker shares this
            // window's store, so ToolRunDialog's project gating is already
            // driven), no palette button (the widget has its own Ctrl+K).
            <div className="control-center__chrome control-center__chrome--embedded">
              <input
                className="control-center__search"
                placeholder="Search tools... (name, description)"
                value={search}
                onChange={(e) => setSearch(e.target.value)}
              />
            </div>
          )}
          <div className="control-center__body">
            <nav className="control-center__nav">
              <button
                className={clsx("control-center__nav-item", activeGroup === null && "control-center__nav-item--active")}
                onClick={() => setActiveGroup(null)}
              >
                {activeGroup === null && (
                  <motion.span
                    layoutId="control-center-nav-active"
                    className="control-center__nav-active-bg"
                    transition={navTransition}
                  />
                )}
                <span className="control-center__nav-icon" aria-hidden="true">{ALL_ICON}</span>
                <span className="control-center__nav-label">All Categories</span>
              </button>
              {groups.map((g) => (
                <button
                  key={g}
                  className={clsx("control-center__nav-item", activeGroup === g && "control-center__nav-item--active")}
                  onClick={() => setActiveGroup(g)}
                >
                  {activeGroup === g && (
                    <motion.span
                      layoutId="control-center-nav-active"
                      className="control-center__nav-active-bg"
                      transition={navTransition}
                    />
                  )}
                  <span className="control-center__nav-icon" aria-hidden="true">{GROUP_ICON[g] ?? DEFAULT_GROUP_ICON}</span>
                  <span className="control-center__nav-label">{g}</span>
                </button>
              ))}
            </nav>
            <main className="control-center__main">
              {missingTool && (
                <div className="control-center__notice" role="status">
                  <span>
                    <strong>{missingTool}</strong> isn't in the current catalog any more, so its run dialog couldn't be
                    opened.
                  </span>
                  <Button size="sm" variant="ghost" onClick={() => setMissingTool(null)}>
                    Dismiss
                  </Button>
                </div>
              )}

              {isLoading && (
                <EmptyState
                  icon={<span className="control-center__spinner" aria-hidden="true" />}
                  title="Loading catalog..."
                  description="Fetching the tool catalog from the DevKit sidecar."
                />
              )}

              {!isLoading && isError && (
                <EmptyState
                  tone="danger"
                  icon="⚠️"
                  title="Couldn't load the tool catalog"
                  description={
                    error instanceof Error
                      ? error.message
                      : "The sidecar didn't respond. Check that DevKit's background process is running."
                  }
                  action={
                    <Button variant="subtle" onClick={() => refetch()} disabled={isFetching}>
                      {isFetching ? "Retrying..." : "Retry"}
                    </Button>
                  }
                />
              )}

              {!isLoading && !isError && visibleModules.length === 0 && (
                search.trim() ? (
                  <EmptyState
                    icon={"\u{1F50D}"}
                    title={`No tools match "${search.trim()}"`}
                    description="Try a different search term, or clear it to browse all tools."
                    action={
                      <Button variant="subtle" onClick={() => setSearch("")}>
                        Clear search
                      </Button>
                    }
                  />
                ) : activeGroup ? (
                  <EmptyState
                    icon={ALL_ICON}
                    title={`No tools in ${activeGroup}`}
                    description="This category doesn't have any tools right now."
                    action={
                      <Button variant="subtle" onClick={() => setActiveGroup(null)}>
                        View all categories
                      </Button>
                    }
                  />
                ) : (
                  <EmptyState icon={ALL_ICON} title="No tools available" description="The catalog loaded, but it's empty." />
                )
              )}

              {!isLoading && !isError && (
                <AnimatePresence mode="popLayout">
                  {visibleModules.map((module) => {
                    const q = search.trim().toLowerCase();
                    const items = module.items.filter(
                      (item) => !q || item.label.toLowerCase().includes(q) || item.help.toLowerCase().includes(q),
                    );
                    return (
                      <motion.section
                        key={module.folder}
                        layout
                        initial={cardInitial}
                        animate={{ opacity: 1, y: 0, scale: 1 }}
                        exit={cardExit}
                        transition={listTransition}
                        className="control-center__section"
                      >
                        <h2 className="control-center__section-title">{module.name}</h2>
                        <p className="control-center__section-desc">{module.description}</p>
                        <motion.div layout className="control-center__grid">
                          <AnimatePresence mode="popLayout">
                            {items.map((item) => (
                              <motion.div
                                key={`${module.folder}-${item.key}-${item.script}`}
                                layout
                                initial={cardInitial}
                                animate={{ opacity: 1, y: 0, scale: 1 }}
                                exit={cardExit}
                                transition={listTransition}
                              >
                                {/*
                                  Plain (non-motion) inner wrapper for the CSS hover
                                  lift/shadow: framer-motion writes its own
                                  transform as an inline style on the motion.div
                                  above (for layout/enter/exit), which would always
                                  beat a `:hover` rule targeting the same element -
                                  splitting the two onto separate nested elements
                                  keeps them independent.
                                */}
                                <div className="control-center__card-wrap">
                                  <GlassPanel
                                    className={clsx("control-center__card", item.caution && "control-center__card--caution")}
                                    padded
                                  >
                                    <button className="control-center__card-btn" onClick={() => setSelected({ module, item })}>
                                      <div className="control-center__card-title">{item.label}</div>
                                      <div className="control-center__card-chips">
                                        {item.requiresProject && <Badge tone="accent">Project</Badge>}
                                        {item.prompts && item.prompts.length > 0 && <Badge tone="neutral">Input</Badge>}
                                        {item.caution && <Badge tone="danger">Caution</Badge>}
                                      </div>
                                      <p className="control-center__card-help">{item.help}</p>
                                    </button>
                                  </GlassPanel>
                                </div>
                              </motion.div>
                            ))}
                          </AnimatePresence>
                        </motion.div>
                      </motion.section>
                    );
                  })}
                </AnimatePresence>
              )}
            </main>
          </div>
          <AnimatePresence>
            {selected && (
              <ToolRunDialog module={selected.module} item={selected.item} onClose={() => setSelected(null)} />
            )}
          </AnimatePresence>
        </div>
      </ConfirmDialogHost>
    </MotionConfig>
  );
}
