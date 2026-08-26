import { useEffect, useMemo, useState, type ReactNode } from "react";
import { AnimatePresence, motion, useReducedMotion, type Transition } from "framer-motion";
import clsx from "clsx";
import { useErrorStore, type ErrorEntry, type ErrorSeverity } from "../../stores/useErrorStore";
import { useConfirmDestructive } from "../../hooks/useConfirmDestructive";
import { playSound } from "../../lib/sounds";
import { Badge } from "../primitives/Badge";
import { Button } from "../primitives/Button";
import { GlassPanel } from "../primitives/GlassPanel";
import { ErrorRow } from "./ErrorRow";
import { byNewest } from "./format";
import { useErrorFeed, type ErrorFeed } from "./useErrorFeed";
import { useErrorCenterStore } from "./useErrorCenterStore";
import "./ErrorCenter.css";

type SeverityFilter = "all" | ErrorSeverity;

const SEVERITY_FILTERS: { id: SeverityFilter; label: string }[] = [
  { id: "all", label: "All" },
  { id: "critical", label: "Critical" },
  { id: "error", label: "Errors" },
  { id: "warning", label: "Warnings" },
];

/**
 * Mount once per window, near the root and INSIDE <ConfirmDialogHost/> (so
 * the destructive clears get the shared confirm prompt rather than falling
 * back to running immediately). Renders nothing until something calls
 * openErrorCenter().
 *
 * It also owns the feed, which is why it lives outside the dialog: polling
 * errors.system / errors.app whenever the window is mounted - not only while
 * the dialog happens to be open - is what lets a badge on the opener control
 * light up before the user goes looking.
 */
export function ErrorCenterHost() {
  const open = useErrorCenterStore((s) => s.open);
  const closeCenter = useErrorCenterStore((s) => s.closeCenter);
  const feed = useErrorFeed();

  return <AnimatePresence>{open && <ErrorCenter feed={feed} onClose={closeCenter} />}</AnimatePresence>;
}

interface ErrorCenterProps {
  feed: ErrorFeed;
  onClose: () => void;
}

/**
 * The review surface: a big SYSTEM section (Windows Event Log) over a
 * smaller DEVKIT section (the app's own faults - sidecar log lines plus
 * whatever lib/errorCapture.ts caught in-process).
 *
 * Same overlay/backdrop-blur/GlassPanel/spring-in family as ConfirmDialog
 * and SettingsDialog. Sits at a LOWER z-index than ConfirmDialog on purpose
 * (see ErrorCenter.css) so a "clear this?" prompt raised from in here lands
 * on top of it instead of behind it.
 */
export function ErrorCenter({ feed, onClose }: ErrorCenterProps) {
  const entries = useErrorStore((s) => s.entries);
  const storeFetchError = useErrorStore((s) => s.fetchError);
  const dismiss = useErrorStore((s) => s.dismiss);
  const clearSource = useErrorStore((s) => s.clearSource);
  const clearAll = useErrorStore((s) => s.clearAll);
  const markAllSeen = useErrorStore((s) => s.markAllSeen);
  const confirmDestructive = useConfirmDestructive();
  const reducedMotion = useReducedMotion();

  const [query, setQuery] = useState("");
  const [severity, setSeverity] = useState<SeverityFilter>("all");
  const [expandedId, setExpandedId] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [clearingLogs, setClearingLogs] = useState(false);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  // Looking at the list IS seeing it - mark on the way in (clears the badge)
  // and again on the way out (covers anything that arrived while it was open).
  useEffect(() => {
    markAllSeen();
    return () => markAllSeen();
  }, [markAllSeen]);

  useEffect(() => {
    playSound("swoosh");
  }, []);

  const bySource = useMemo(() => {
    const system: ErrorEntry[] = [];
    const app: ErrorEntry[] = [];
    for (const entry of entries) (entry.source === "system" ? system : app).push(entry);
    system.sort(byNewest);
    app.sort(byNewest);
    return { system, app };
  }, [entries]);

  const filter = useMemo(() => {
    const needle = query.trim().toLowerCase();
    return (entry: ErrorEntry) => {
      if (severity !== "all" && entry.severity !== severity) return false;
      if (!needle) return true;
      return (
        entry.title.toLowerCase().includes(needle) || (entry.origin ?? "").toLowerCase().includes(needle)
      );
    };
  }, [query, severity]);

  const systemRows = useMemo(() => bySource.system.filter(filter), [bySource.system, filter]);
  const appRows = useMemo(() => bySource.app.filter(filter), [bySource.app, filter]);

  const filtersActive = severity !== "all" || query.trim() !== "";
  const total = entries.length;

  const overlayTransition: Transition = reducedMotion ? { duration: 0 } : { duration: 0.18, ease: [0.2, 0.8, 0.2, 1] };
  const panelTransition: Transition = reducedMotion
    ? { duration: 0 }
    : { type: "spring", stiffness: 420, damping: 32, mass: 0.9 };

  function toggleRow(id: string) {
    setExpandedId((current) => (current === id ? null : id));
  }

  function clearSystemList() {
    confirmDestructive(
      {
        title: "Clear the system error list?",
        description: (
          <>
            Removes the <strong>{bySource.system.length}</strong> system{" "}
            {bySource.system.length === 1 ? "entry" : "entries"} listed here. Windows keeps its own Event Log, so
            entries can reappear on the next refresh.
          </>
        ),
        confirmLabel: "Clear list",
        danger: true,
      },
      () => {
        feed.forgetIngested("system");
        clearSource("system");
        setExpandedId(null);
      },
    );
  }

  function clearAppLogs() {
    confirmDestructive(
      {
        title: "Clear DevKit's error log?",
        description: (
          <>
            Empties DevKit&rsquo;s own log file on disk and clears the <strong>DevKit errors</strong> list here.
            Windows system errors are not affected.
          </>
        ),
        confirmLabel: "Clear log",
        danger: true,
      },
      async () => {
        setActionError(null);
        setClearingLogs(true);
        try {
          await feed.clearAppLogs();
          feed.forgetIngested("app");
          clearSource("app");
          setExpandedId(null);
          playSound("success");
        } catch (err) {
          // The file didn't clear - say so instead of emptying the list and
          // implying it did.
          setActionError(`Could not clear DevKit's log: ${err instanceof Error ? err.message : String(err)}`);
          playSound("error");
        } finally {
          setClearingLogs(false);
        }
      },
    );
  }

  function clearEverything() {
    confirmDestructive(
      {
        title: "Clear every entry?",
        description: (
          <>
            Clears both lists inside DevKit. This does not touch the Windows Event Log or DevKit's log file on disk -
            use <strong>Clear log</strong> in the DevKit section for that.
          </>
        ),
        confirmLabel: "Clear all",
        danger: true,
      },
      () => {
        feed.forgetIngested("system");
        feed.forgetIngested("app");
        clearAll();
        setExpandedId(null);
      },
    );
  }

  return (
    <motion.div
      className="error-center__overlay devkit-no-drag"
      onClick={onClose}
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      exit={{ opacity: 0 }}
      transition={overlayTransition}
    >
      <motion.div
        className="error-center__positioner"
        initial={reducedMotion ? false : { opacity: 0, scale: 0.94, y: 16 }}
        animate={{ opacity: 1, scale: 1, y: 0 }}
        exit={reducedMotion ? { opacity: 0 } : { opacity: 0, scale: 0.96, y: 8 }}
        transition={panelTransition}
      >
        <GlassPanel strong padded={false} noAnimate className="error-center">
          <div
            className="error-center__inner"
            role="dialog"
            aria-modal="true"
            aria-label="Error Center"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="error-center__header">
              <div className="error-center__heading">
                <span className="error-center__title">Error Center</span>
                <span className="error-center__subtitle">
                  {total === 0 ? "Nothing recorded" : `${total} ${total === 1 ? "entry" : "entries"}`}
                </span>
              </div>
              <Button size="sm" variant="subtle" loading={feed.refreshing} onClick={feed.refresh}>
                Refresh
              </Button>
              <button type="button" className="error-center__close" aria-label="Close Error Center" onClick={onClose}>
                &#10005;
              </button>
            </div>

            <div className="error-center__toolbar">
              <input
                type="search"
                className="error-center__search"
                placeholder="Filter by title or origin…"
                aria-label="Filter errors"
                value={query}
                onChange={(e) => setQuery(e.target.value)}
              />
              <div className="error-center__segmented" role="group" aria-label="Severity filter">
                {SEVERITY_FILTERS.map((f) => (
                  <button
                    key={f.id}
                    type="button"
                    className={clsx(
                      "error-center__segment",
                      severity === f.id && "error-center__segment--active",
                    )}
                    aria-pressed={severity === f.id}
                    onClick={() => setSeverity(f.id)}
                  >
                    {f.label}
                  </button>
                ))}
              </div>
              <Button size="sm" variant="ghost" disabled={total === 0} onClick={clearEverything}>
                Clear all
              </Button>
            </div>

            {actionError && <div className="error-center__notice error-center__notice--danger">{actionError}</div>}
            {storeFetchError && !feed.systemError && !feed.appError && (
              <div className="error-center__notice">{storeFetchError}</div>
            )}

            <div className="error-center__body">
              <Section
                title="System errors"
                hint={`Windows Event Log · last ${feed.systemHours} hours`}
                count={bySource.system.length}
                action={
                  <Button size="sm" variant="ghost" disabled={bySource.system.length === 0} onClick={clearSystemList}>
                    Clear list
                  </Button>
                }
                fetchError={feed.systemError}
                onRetry={feed.refresh}
                loading={feed.systemLoading && bySource.system.length === 0}
                empty={
                  filtersActive && bySource.system.length > 0
                    ? "No system errors match this filter."
                    : `No system errors in the last ${feed.systemHours} hours.`
                }
                rows={systemRows}
                expandedId={expandedId}
                onToggle={toggleRow}
                onDismiss={dismiss}
              />

              <Section
                title="DevKit errors"
                hint="This app's own failures - sidecar, RPC, and UI"
                count={bySource.app.length}
                compact
                action={
                  // Never disabled on an empty list: the log FILE can still
                  // hold entries the user has dismissed from this view.
                  <Button size="sm" variant="ghost" loading={clearingLogs} onClick={clearAppLogs}>
                    Clear log
                  </Button>
                }
                fetchError={feed.appError}
                onRetry={feed.refresh}
                loading={feed.appLoading && bySource.app.length === 0}
                empty={
                  filtersActive && bySource.app.length > 0
                    ? "No DevKit errors match this filter."
                    : "No DevKit errors recorded."
                }
                rows={appRows}
                expandedId={expandedId}
                onToggle={toggleRow}
                onDismiss={dismiss}
              />
            </div>
          </div>
        </GlassPanel>
      </motion.div>
    </motion.div>
  );
}

// ---------------------------------------------------------------------------
// section
// ---------------------------------------------------------------------------

interface SectionProps {
  title: string;
  hint: string;
  count: number;
  compact?: boolean;
  action: ReactNode;
  /** Non-null = this section's fetch failed. Shown INSTEAD of an empty state, which would read as "all clear". */
  fetchError: string | null;
  onRetry: () => void;
  loading: boolean;
  empty: string;
  rows: ErrorEntry[];
  expandedId: string | null;
  onToggle: (id: string) => void;
  onDismiss: (id: string) => void;
}

function Section({
  title,
  hint,
  count,
  compact,
  action,
  fetchError,
  onRetry,
  loading,
  empty,
  rows,
  expandedId,
  onToggle,
  onDismiss,
}: SectionProps) {
  return (
    <section className={clsx("error-section", compact && "error-section--compact")}>
      <header className="error-section__head">
        <h3 className="error-section__title">{title}</h3>
        {count > 0 && <Badge tone={compact ? "neutral" : "danger"}>{count}</Badge>}
        <span className="error-section__hint">{hint}</span>
        <span className="error-section__spacer" />
        {action}
      </header>

      {/* A failed fetch is shown ALONGSIDE whatever did make it in - and it
          suppresses the empty state entirely, because "No errors" under a
          fetch that never answered reads as "all clear" when the truth is
          "we don't know". */}
      {fetchError && (
        <div className="error-section__unavailable">
          <span className="error-section__unavailable-text">
            Couldn&rsquo;t read this source, so this list may be incomplete &mdash; {fetchError}
          </span>
          <Button size="sm" variant="ghost" onClick={onRetry}>
            Retry
          </Button>
        </div>
      )}

      {loading ? (
        <div className="error-section__skeletons" aria-busy="true" aria-label="Loading">
          <div className="devkit-skeleton error-section__skeleton" />
          <div className="devkit-skeleton error-section__skeleton" />
          <div className="devkit-skeleton error-section__skeleton" />
        </div>
      ) : rows.length > 0 ? (
        <div className="error-section__rows">
          {rows.map((entry) => (
            <ErrorRow
              key={entry.id}
              entry={entry}
              compact={compact}
              expanded={expandedId === entry.id}
              onToggle={() => onToggle(entry.id)}
              onDismiss={() => onDismiss(entry.id)}
            />
          ))}
        </div>
      ) : fetchError ? null : (
        <div className="error-section__empty">{empty}</div>
      )}
    </section>
  );
}
