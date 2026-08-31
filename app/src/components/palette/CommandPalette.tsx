import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { useQuery } from "@tanstack/react-query";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { emitTo } from "@tauri-apps/api/event";
import { AnimatePresence, motion, useReducedMotion, type Transition } from "framer-motion";
import clsx from "clsx";
import { rpcCall, showWindow } from "../../lib/ipc";
import { asArray } from "../../lib/arrays";
import { playSound } from "../../lib/sounds";
import { useProjectStore } from "../../stores/useProjectStore";
import { ensureProjectsLoaded, notifyProjectsChanged, useProjectManagerStore } from "../projects/ensureProjects";
import { GlassPanel } from "../primitives/GlassPanel";
import { Badge } from "../primitives/Badge";
import { highlightSegments, scoreCandidate } from "./fuzzy";
import {
  PALETTE_DANCE_EVENT,
  PALETTE_TOOL_EVENT,
  usePaletteStore,
  type PaletteToolRequest,
} from "./paletteStore";
import type { Catalog, LinkedProject } from "../../lib/types";
import "./CommandPalette.css";

const GROUP_ORDER = ["Actions", "Projects", "Tools", "Secret"] as const;
type GroupName = (typeof GROUP_ORDER)[number];

/**
 * The one entry you can't browse to. Matched as a whole word - with or
 * without the leading slash people expect from a chat command - instead of
 * going through the fuzzy scorer, because "hidden" has to survive the
 * palette's own helpfulness: it never joins `entries`, so an empty query
 * can't list it and no loose fuzzy run (d-a-n across some tool's help text)
 * can stumble onto it. You have to know the word.
 */
const DANCE_QUERY = /^\/?dance$/i;

interface PaletteEntry {
  id: string;
  group: GroupName;
  title: string;
  subtitle?: string;
  /** Extra text the fuzzy matcher may hit, never rendered. */
  keywords?: string[];
  badges?: { label: string; tone: "neutral" | "accent" | "danger" | "success" | "warning" }[];
  /** Right-aligned hint (a tool's script path, a project's tags). */
  meta?: string;
  run: () => void | Promise<void>;
}

interface ScoredEntry {
  entry: PaletteEntry;
  score: number;
  positions: number[];
}

/** One flat row in the rendered list - headers are skipped by arrow navigation. */
type Row = { kind: "header"; group: GroupName } | { kind: "item"; index: number; scored: ScoredEntry };

/** Hard cap so an empty query doesn't render every one of ~65 tools at once. */
const MAX_RESULTS = 60;

function newRequestId(): string {
  return typeof crypto !== "undefined" && "randomUUID" in crypto ? crypto.randomUUID() : String(Math.random()).slice(2);
}

function Highlighted({ text, positions }: { text: string; positions: number[] }): ReactNode {
  const segments = highlightSegments(text, positions);
  return (
    <>
      {segments.map((seg, i) =>
        seg.match ? (
          <mark key={i} className="command-palette__hit">
            {seg.text}
          </mark>
        ) : (
          <span key={i}>{seg.text}</span>
        ),
      )}
    </>
  );
}

/**
 * Ctrl+K / Cmd+K command palette, mounted once per window from main.tsx so
 * the widget and the Control Center both get it.
 *
 * It searches three things: every catalog tool, every linked project, and a
 * handful of app-level actions. Tools are the interesting case, because
 * only the Control Center can render a tool's run dialog:
 *
 *   - in the Control Center, a tool selection goes into usePaletteStore's
 *     `toolRequest`, which ControlCenterApp watches and turns into an open
 *     <ToolRunDialog/> for exactly that tool;
 *   - in the widget, the same request is emitted to the control-center
 *     window (PALETTE_TOOL_EVENT) right after showWindow() surfaces it, so
 *     the selection carries across rather than just opening the window and
 *     dumping the user in the catalog.
 */
export function CommandPalette() {
  const open = usePaletteStore((s) => s.open);
  const openPalette = usePaletteStore((s) => s.openPalette);
  const closePalette = usePaletteStore((s) => s.closePalette);
  const requestTool = usePaletteStore((s) => s.requestTool);
  const openManager = useProjectManagerStore((s) => s.openManager);
  const projects = useProjectStore((s) => s.linked);
  const activeProject = useProjectStore((s) => s.active);
  const reducedMotion = useReducedMotion();

  const [query, setQuery] = useState("");
  const [cursor, setCursor] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const inputRef = useRef<HTMLInputElement>(null);
  const listRef = useRef<HTMLDivElement>(null);

  const windowLabel = useMemo(() => {
    try {
      return getCurrentWindow().label;
    } catch {
      return "widget";
    }
  }, []);
  const isControlCenter = windowLabel === "control-center";

  // Catalog fetch is lazy and shares react-query's cache with the Control
  // Center's own ["catalog.get"] query, so opening the palette there is a
  // cache hit rather than a second sidecar round-trip.
  //
  // `isError` is load-bearing, not decoration. The palette is mounted
  // OUTSIDE the error boundary precisely so it survives a crashed window
  // tree, which is also when the sidecar is most likely to be unreachable;
  // without this flag a failed catalog is indistinguishable from a catalog
  // with no matches, and the palette used to answer a search for a tool it
  // simply never loaded with `Nothing matches "backup"` while 65 tools
  // existed. Projects and app actions are built locally, so they keep
  // working either way - the palette degrades, it doesn't die.
  const {
    data: catalog,
    isLoading: catalogLoading,
    isError: catalogFailed,
    error: catalogError,
  } = useQuery({
    queryKey: ["catalog.get"],
    queryFn: () => rpcCall<Catalog>("catalog.get"),
    staleTime: 60_000,
    enabled: open,
  });
  const catalogErrorText = catalogError instanceof Error && catalogError.message ? catalogError.message : null;

  // ---------- global hotkey ----------
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (!(e.ctrlKey || e.metaKey) || e.altKey) return;
      if (e.key !== "k" && e.key !== "K") return;
      // The widget's embedded terminal owns Ctrl+K (kill-to-end-of-line in
      // most shells) - never steal it out from under xterm.
      if (e.target instanceof Element && e.target.closest(".xterm")) return;
      e.preventDefault();
      if (usePaletteStore.getState().open) {
        closePalette();
      } else {
        playSound("swoosh");
        openPalette();
      }
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [openPalette, closePalette]);

  // ---------- open/close side effects ----------
  useEffect(() => {
    if (!open) return;
    setQuery("");
    setCursor(0);
    void ensureProjectsLoaded(true);
    // Focus after paint so the input exists and the spring-in has started.
    const id = window.requestAnimationFrame(() => inputRef.current?.focus());
    return () => window.cancelAnimationFrame(id);
  }, [open]);

  const runTool = useCallback(
    async (folder: string, script: string, key: string, label: string) => {
      const request: PaletteToolRequest = { id: newRequestId(), folder, script, key, label };
      if (isControlCenter) {
        requestTool(request);
        return;
      }
      // Cross-window: surface the Control Center, then hand it the pick.
      // Both windows are created at startup (tauri.conf.json), so its
      // listener is already live; the delayed second emit is belt-and-braces
      // for a webview that hasn't finished booting, and is free because
      // usePaletteStore.requestTool de-dupes on `id`.
      await showWindow("control-center");
      await emitTo("control-center", PALETTE_TOOL_EVENT, request);
      window.setTimeout(() => {
        void emitTo("control-center", PALETTE_TOOL_EVENT, request).catch(() => {});
      }, 500);
    },
    [isControlCenter, requestTool],
  );

  const startDance = useCallback(async () => {
    playSound("success");
    // The gauges live only in the widget, so surface it first - a /dance run
    // from the Control Center with the widget hidden would otherwise be a
    // party in an empty room. Same double-emit as runTool, for the same
    // reason (a widget webview still booting misses the first); GaugesPanel
    // drops the repeat rather than restarting the animation.
    await showWindow("widget");
    await emitTo("widget", PALETTE_DANCE_EVENT);
    window.setTimeout(() => {
      void emitTo("widget", PALETTE_DANCE_EVENT).catch(() => {});
    }, 500);
  }, []);

  const danceEntry = useMemo<PaletteEntry>(
    () => ({
      id: "secret:dance",
      group: "Secret",
      title: "🕺 Dance",
      subtitle: "Make the gauges bounce",
      meta: "you found it",
      run: () => startDance(),
    }),
    [startDance],
  );

  // useProjectStore.setActive already does the projects.setActive RPC and a
  // full store refresh; the broadcast is what carries the switch to the
  // other window's store.
  const selectProject = useCallback(async (project: LinkedProject) => {
    await useProjectStore.getState().setActive(project.id);
    notifyProjectsChanged();
  }, []);

  // ---------- entries ----------
  const entries = useMemo<PaletteEntry[]>(() => {
    const out: PaletteEntry[] = [];

    out.push({
      id: "action:control-center",
      group: "Actions",
      title: "Open Control Center",
      subtitle: "Browse and run every DevKit tool",
      keywords: ["window", "catalog", "tools", "devkit"],
      run: () => showWindow("control-center"),
    });
    out.push({
      id: "action:widget",
      group: "Actions",
      title: "Show Widget",
      subtitle: "Bring the DevKit sidebar to the front",
      keywords: ["sidebar", "dock", "gauges", "panel"],
      // `show_window` routes the widget label through commands::surface_widget,
      // so this un-minimizes and slides a collapsed sidebar back out as well as
      // showing it. It used to show()+focus() only, which on a collapsed
      // sidebar "succeeded" by surfacing an ~11-logical-px sliver.
      run: () => showWindow("widget"),
    });
    out.push({
      id: "action:projects",
      group: "Actions",
      title: "Manage Linked Projects",
      subtitle: "Rename, pin, repair or unlink linked project folders",
      keywords: ["project", "link", "unlink", "remove", "repair", "missing", "pin"],
      run: () => openManager(),
    });

    for (const project of asArray(projects)) {
      const tags = asArray(project.tags);
      out.push({
        id: `project:${project.id}`,
        group: "Projects",
        title: project.name,
        subtitle: project.path,
        keywords: tags,
        meta: tags.join(" "),
        badges: [
          ...(activeProject?.id === project.id ? ([{ label: "Active", tone: "accent" as const }] as const) : []),
          ...(project.Missing ? ([{ label: "Missing", tone: "danger" as const }] as const) : []),
          ...(project.pinned ? ([{ label: "Pinned", tone: "neutral" as const }] as const) : []),
        ],
        run: () => selectProject(project),
      });
    }

    // asArray on both levels: a catalog with a single module (or a module
    // with a single tool) can come off the wire as a bare object, and
    // silently listing no tools is the same class of lie as the one above.
    for (const module of asArray(catalog?.modules)) {
      for (const item of asArray(module.items)) {
        out.push({
          id: `tool:${module.folder}:${item.key}:${item.script}`,
          group: "Tools",
          title: item.label,
          subtitle: item.help,
          keywords: [module.name, module.group, module.folder, item.script, item.key],
          meta: `${module.folder}/${item.script}`,
          badges: [
            ...(item.requiresProject ? ([{ label: "Project", tone: "accent" as const }] as const) : []),
            ...(item.prompts && item.prompts.length > 0 ? ([{ label: "Input", tone: "neutral" as const }] as const) : []),
            ...(item.caution ? ([{ label: "Caution", tone: "danger" as const }] as const) : []),
          ],
          run: () => runTool(module.folder, item.script, item.key, item.label),
        });
      }
    }

    return out;
  }, [projects, activeProject, catalog, openManager, runTool, selectProject]);

  // ---------- ranking ----------
  const { rows, items } = useMemo(() => {
    const q = query.trim();
    const scored: ScoredEntry[] = [];

    for (const entry of entries) {
      if (!q) {
        scored.push({ entry, score: 0, positions: [] });
        continue;
      }
      const match = scoreCandidate(q, entry.title, [entry.subtitle ?? "", ...(entry.keywords ?? [])]);
      if (match) scored.push({ entry, score: match.score, positions: match.positions });
    }

    // Injected here rather than in `entries` so it exists only for the exact
    // query that summons it (see DANCE_QUERY). An unbeatable score keeps it
    // on top - and puts its group first - so the payoff is one Enter away.
    if (DANCE_QUERY.test(q)) {
      scored.push({ entry: danceEntry, score: Number.MAX_SAFE_INTEGER, positions: [] });
    }

    // With a query, one global ranking decides both row order and which
    // group leads; without one, the fixed Actions/Projects/Tools order and
    // each source's natural order are more predictable than any score.
    if (q) {
      scored.sort((a, b) => b.score - a.score || a.entry.title.length - b.entry.title.length);
    }

    const capped = scored.slice(0, MAX_RESULTS);

    const byGroup = new Map<GroupName, ScoredEntry[]>();
    for (const s of capped) {
      const bucket = byGroup.get(s.entry.group);
      if (bucket) bucket.push(s);
      else byGroup.set(s.entry.group, [s]);
    }

    const groups = Array.from(byGroup.keys());
    if (q) {
      // Best-scoring group first - `capped` is already sorted, so a group's
      // first member is its best.
      groups.sort((a, b) => (byGroup.get(b)![0]?.score ?? 0) - (byGroup.get(a)![0]?.score ?? 0));
    } else {
      groups.sort((a, b) => GROUP_ORDER.indexOf(a) - GROUP_ORDER.indexOf(b));
    }

    const nextRows: Row[] = [];
    const nextItems: ScoredEntry[] = [];
    for (const group of groups) {
      nextRows.push({ kind: "header", group });
      for (const s of byGroup.get(group)!) {
        nextRows.push({ kind: "item", index: nextItems.length, scored: s });
        nextItems.push(s);
      }
    }
    return { rows: nextRows, items: nextItems };
  }, [entries, query, danceEntry]);

  // Any change to the result set puts the cursor back on the best row.
  useEffect(() => {
    setCursor(0);
  }, [query, items.length]);

  useEffect(() => {
    if (!open) return;
    listRef.current?.querySelector(`[data-index="${cursor}"]`)?.scrollIntoView({ block: "nearest" });
  }, [cursor, open]);

  /**
   * Runs one entry, and closes the palette only once it actually succeeded -
   * a failure keeps the surface up with an inline message instead of
   * vanishing. (Closing first and reopening on error can't work: the
   * open-transition effect above resets the palette, which would wipe the
   * message it was reopened to show.) Selections that are instant anyway -
   * a tool picked inside the Control Center - are closed synchronously by
   * usePaletteStore.requestTool, so this await is never visible for them.
   */
  const activate = useCallback(
    async (scored: ScoredEntry | undefined) => {
      if (!scored) return;
      playSound("click");
      setError(null);
      try {
        await scored.entry.run();
        closePalette();
      } catch (err) {
        playSound("error");
        setError(`Couldn't run "${scored.entry.title}": ${err instanceof Error ? err.message : String(err)}`);
      }
    },
    [closePalette],
  );

  function onKeyDown(e: React.KeyboardEvent<HTMLInputElement>) {
    if (e.key === "ArrowDown") {
      e.preventDefault();
      if (items.length) setCursor((c) => (c + 1) % items.length);
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      if (items.length) setCursor((c) => (c - 1 + items.length) % items.length);
    } else if (e.key === "Home") {
      e.preventDefault();
      setCursor(0);
    } else if (e.key === "End") {
      e.preventDefault();
      if (items.length) setCursor(items.length - 1);
    } else if (e.key === "Enter") {
      e.preventDefault();
      void activate(items[cursor]);
    } else if (e.key === "Escape") {
      e.preventDefault();
      // Other surfaces (SettingsDialog, the project manager) close on a
      // window-level Escape. The palette can be opened on top of them, so
      // stop here rather than dismissing whatever it's covering as well.
      e.stopPropagation();
      closePalette();
    }
  }

  // "No result" has three different causes and only one of them is
  // "there is no such thing" - say which one it actually is.
  const emptyMessage = catalogLoading
    ? "Loading the tool catalog..."
    : catalogFailed
      ? `Nothing in projects or actions matches "${query.trim()}" - and the tool catalog couldn't be loaded.`
      : `Nothing matches "${query.trim()}"`;

  const overlayTransition: Transition = reducedMotion ? { duration: 0 } : { duration: 0.16, ease: [0.2, 0.8, 0.2, 1] };
  const panelTransition: Transition = reducedMotion
    ? { duration: 0 }
    : { type: "spring", stiffness: 460, damping: 34, mass: 0.85 };

  return (
    <AnimatePresence>
      {open && (
        <motion.div
          className="command-palette__overlay devkit-no-drag"
          onClick={closePalette}
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          exit={{ opacity: 0 }}
          transition={overlayTransition}
          role="presentation"
        >
          <motion.div
            className="command-palette__positioner"
            initial={reducedMotion ? false : { opacity: 0, scale: 0.97, y: -12 }}
            animate={{ opacity: 1, scale: 1, y: 0 }}
            exit={reducedMotion ? { opacity: 0 } : { opacity: 0, scale: 0.98, y: -8 }}
            transition={panelTransition}
          >
            <GlassPanel strong className="command-palette" padded={false}>
              <div
                className="command-palette__inner"
                role="dialog"
                aria-modal="true"
                aria-label="Command palette"
                onClick={(e) => e.stopPropagation()}
              >
                <div className="command-palette__search">
                  <span className="command-palette__search-icon" aria-hidden="true">
                    {"\u{1F50D}"}
                  </span>
                  <input
                    ref={inputRef}
                    className="command-palette__input"
                    placeholder="Search tools, projects and actions..."
                    value={query}
                    role="combobox"
                    aria-expanded
                    aria-controls="command-palette-list"
                    aria-activedescendant={items.length ? `command-palette-option-${cursor}` : undefined}
                    aria-autocomplete="list"
                    autoComplete="off"
                    spellCheck={false}
                    onChange={(e) => {
                      setQuery(e.target.value);
                      setError(null);
                    }}
                    onKeyDown={onKeyDown}
                  />
                  <kbd className="command-palette__kbd">Esc</kbd>
                </div>

                {error && <div className="command-palette__error">{error}</div>}

                {/* Quieter than __error on purpose: nothing the user did
                    failed, part of the search index just isn't there. */}
                {catalogFailed && (
                  <div className="command-palette__notice" role="status">
                    Tools couldn&apos;t be loaded{catalogErrorText ? ` - ${catalogErrorText}` : "."} Projects and actions
                    below still work.
                  </div>
                )}

                <div className="command-palette__list" id="command-palette-list" role="listbox" ref={listRef}>
                  {items.length === 0 ? (
                    <div className="command-palette__empty">{emptyMessage}</div>
                  ) : (
                    rows.map((row) =>
                      row.kind === "header" ? (
                        <div key={`h-${row.group}`} className="command-palette__group" role="presentation">
                          {row.group}
                        </div>
                      ) : (
                        <div
                          key={row.scored.entry.id}
                          id={`command-palette-option-${row.index}`}
                          data-index={row.index}
                          role="option"
                          aria-selected={row.index === cursor}
                          className={clsx(
                            "command-palette__option",
                            row.index === cursor && "command-palette__option--active",
                          )}
                          onMouseMove={() => setCursor(row.index)}
                          onClick={() => void activate(row.scored)}
                        >
                          <div className="command-palette__option-main">
                            <div className="command-palette__option-title">
                              <Highlighted text={row.scored.entry.title} positions={row.scored.positions} />
                              {row.scored.entry.badges?.map((b) => (
                                <Badge key={b.label} tone={b.tone}>
                                  {b.label}
                                </Badge>
                              ))}
                            </div>
                            {row.scored.entry.subtitle && (
                              <div className="command-palette__option-sub">{row.scored.entry.subtitle}</div>
                            )}
                          </div>
                          {row.scored.entry.meta && (
                            <div className="command-palette__option-meta">{row.scored.entry.meta}</div>
                          )}
                        </div>
                      ),
                    )
                  )}
                </div>

                <div className="command-palette__footer">
                  <span>
                    <kbd className="command-palette__kbd">↑</kbd>
                    <kbd className="command-palette__kbd">↓</kbd> navigate
                  </span>
                  <span>
                    <kbd className="command-palette__kbd">↵</kbd> select
                  </span>
                  {!isControlCenter && <span>Tools open in the Control Center</span>}
                </div>
              </div>
            </GlassPanel>
          </motion.div>
        </motion.div>
      )}
    </AnimatePresence>
  );
}
