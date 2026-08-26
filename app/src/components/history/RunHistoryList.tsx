import { memo, useCallback, useEffect, useRef, useState } from "react";
import clsx from "clsx";
import { useRunHistoryStore, type RunHistoryEntry } from "../../stores/useRunHistoryStore";
import { useConfirmDestructive } from "../../hooks/useConfirmDestructive";
import { Badge } from "../primitives/Badge";
import { Button } from "../primitives/Button";
import { ToolConsole } from "../ToolConsole";
import "./RunHistoryList.css";

interface RunHistoryListProps {
  /**
   * Re-executes a recorded run. The list applies the caution gate itself
   * (see runAgain below), so hosts pass their plain execute function - the
   * confirm prompt can't be forgotten at a call site.
   */
  onRunAgain?: (entry: RunHistoryEntry) => void;
  /** Denser type and padding for the widget's narrow column. */
  compact?: boolean;
  /** Rows rendered; the store retains settings.preferences.runHistoryLimit. */
  maxRows?: number;
  /** The host already has a run in flight - "Run again" would collide. */
  busy?: boolean;
}

/** Wall-clock ages tick over while the list is open, so re-render slowly. */
const TICK_MS = 30_000;

function relativeTime(iso: string, now: number): string {
  const at = Date.parse(iso);
  if (!Number.isFinite(at)) return "";
  const seconds = Math.max(0, Math.round((now - at) / 1000));
  if (seconds < 45) return "just now";
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.round(hours / 24);
  if (days < 7) return `${days}d ago`;
  return new Date(at).toLocaleDateString();
}

function formatDuration(startedAt: string, finishedAt: string | null): string {
  const from = Date.parse(startedAt);
  const to = finishedAt ? Date.parse(finishedAt) : NaN;
  if (!Number.isFinite(from) || !Number.isFinite(to)) return "";
  const ms = Math.max(0, to - from);
  if (ms < 1000) return `${ms}ms`;
  if (ms < 10_000) return `${(ms / 1000).toFixed(1)}s`;
  if (ms < 60_000) return `${Math.round(ms / 1000)}s`;
  const minutes = Math.floor(ms / 60_000);
  const seconds = Math.round((ms % 60_000) / 1000);
  return `${minutes}m ${seconds}s`;
}

function ExitBadge({ entry }: { entry: RunHistoryEntry }) {
  if (entry.finishedAt === null) return <Badge tone="accent">running</Badge>;
  if (entry.detached || entry.exitCode === null) return <Badge tone="warning">unknown</Badge>;
  return <Badge tone={entry.exitCode === 0 ? "success" : "danger"}>exit {entry.exitCode}</Badge>;
}

interface RunHistoryRowProps {
  entry: RunHistoryEntry;
  now: number;
  compact: boolean;
  busy: boolean;
  onRunAgain?: (entry: RunHistoryEntry) => void;
}

/**
 * Memoized because the store's `entries` array changes identity on every
 * streamed output line of an in-flight run: without this, one chatty tool
 * would re-render all 50 rows - transcripts included - per line. Only the
 * row whose entry object actually changed re-renders, which is why the
 * list hands rows a stable `onRunAgain` (see RunHistoryList).
 */
const RunHistoryRow = memo(function RunHistoryRow({ entry, now, compact, busy, onRunAgain }: RunHistoryRowProps) {
  const [open, setOpen] = useState(false);
  // Same lazy-mount contract as the Expander primitive: with 50 rows in the
  // list there is no reason to build 50 consoles nobody has opened, but a
  // row that HAS been opened stays mounted so collapsing it still animates.
  const [everOpened, setEverOpened] = useState(false);
  const confirmDestructive = useConfirmDestructive();

  function toggle() {
    setOpen((v) => {
      if (!v) setEverOpened(true);
      return !v;
    });
  }

  function runAgain() {
    if (!onRunAgain || busy) return;
    // A caution tool stays a caution tool on its second run - same gate the
    // original went through in ToolRunDialog / QuickActionsPanel.
    if (entry.caution) {
      confirmDestructive(
        {
          title: `Run ${entry.label} again?`,
          description: (
            <>
              This re-runs <strong>{entry.label}</strong> ({entry.folder}/{entry.script}) with the same arguments - it is
              flagged as a caution tool and may make changes that can't be undone.
            </>
          ),
          confirmLabel: "Run",
          danger: true,
        },
        () => onRunAgain(entry),
      );
    } else {
      onRunAgain(entry);
    }
  }

  const duration = formatDuration(entry.startedAt, entry.finishedAt);

  return (
    <div className="run-history__row">
      <button type="button" className="run-history__trigger" aria-expanded={open} onClick={toggle}>
        <svg
          className={clsx("run-history__chevron", open && "run-history__chevron--open")}
          width="10"
          height="10"
          viewBox="0 0 10 10"
          aria-hidden="true"
        >
          <path d="M1 3 L5 7 L9 3" stroke="currentColor" strokeWidth="1.5" fill="none" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
        <span className="run-history__ident">
          <span className="run-history__label">{entry.label}</span>
          <span className="run-history__script">
            {entry.folder}/{entry.script}
          </span>
        </span>
        <span className="run-history__meta">
          <span>{relativeTime(entry.startedAt, now)}</span>
          {duration && <span className="run-history__duration">{duration}</span>}
          <ExitBadge entry={entry} />
        </span>
      </button>

      <div className={clsx("run-history__panel", open && "run-history__panel--open")}>
        <div className="run-history__panel-inner">
          {everOpened && (
            <div className="run-history__body">
              <div className="run-history__args">
                {entry.folder}/{entry.script}
                {entry.args.length > 0 ? ` ${entry.args.join(" ")}` : ""}
              </div>

              {entry.detached && (
                <div className="run-history__notice">
                  DevKit stopped watching this run before it reported an exit code - it may have finished, or may still be
                  running.
                </div>
              )}

              {entry.droppedLines > 0 && (
                <div className="run-history__notice">
                  Output truncated - {entry.droppedLines} earlier line{entry.droppedLines === 1 ? "" : "s"} dropped.
                </div>
              )}

              {entry.output.length > 0 ? (
                <ToolConsole lines={entry.output} className={compact ? "tool-console--compact" : undefined} />
              ) : (
                <div className="run-history__empty">No output was captured for this run.</div>
              )}

              {onRunAgain && (
                <div className="run-history__actions">
                  <Button size="sm" variant={entry.caution ? "danger" : "subtle"} disabled={busy} onClick={runAgain}>
                    Run again
                  </Button>
                </div>
              )}
            </div>
          )}
        </div>
      </div>
    </div>
  );
});

/**
 * Newest-first view of useRunHistoryStore: label, relative time, duration
 * and a colored exit-code badge per run, expanding to the run's captured
 * output in the same monospace console the live run streams into
 * (components/ToolConsole).
 *
 * Rendered inside a host that owns execution (ToolRunDialog, the widget's
 * QuickActionsPanel) - the host supplies `onRunAgain` and this component
 * supplies the confirm gate, so re-running Docker Nuke from history is
 * exactly as guarded as running it the first time.
 */
export function RunHistoryList({ onRunAgain, compact = false, maxRows, busy = false }: RunHistoryListProps) {
  const entries = useRunHistoryStore((s) => s.entries);
  const clear = useRunHistoryStore((s) => s.clear);
  const confirmDestructive = useConfirmDestructive();
  const [now, setNow] = useState(() => Date.now());

  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), TICK_MS);
    return () => clearInterval(timer);
  }, []);

  // Hosts rebuild their onRunAgain closure every render; rows need a stable
  // identity for memo to be worth anything, so the live one is read through
  // a ref at click time instead of being passed down directly.
  const runAgainRef = useRef(onRunAgain);
  useEffect(() => {
    runAgainRef.current = onRunAgain;
  }, [onRunAgain]);
  const handleRunAgain = useCallback((entry: RunHistoryEntry) => runAgainRef.current?.(entry), []);

  const rows = maxRows ? entries.slice(0, maxRows) : entries;

  function clearHistory() {
    confirmDestructive(
      {
        title: "Clear run history?",
        description: (
          <>
            This discards all {entries.length} recorded run{entries.length === 1 ? "" : "s"} and their captured output.
          </>
        ),
        confirmLabel: "Clear",
        danger: true,
      },
      clear,
    );
  }

  return (
    <div className={clsx("run-history", compact && "run-history--compact")}>
      <div className="run-history__toolbar">
        <span className="run-history__count">
          {entries.length === 0
            ? "No runs recorded yet."
            : `${entries.length} run${entries.length === 1 ? "" : "s"} recorded${
                rows.length < entries.length ? ` - showing ${rows.length}` : ""
              }`}
        </span>
        {entries.length > 0 && (
          <Button size="sm" variant="ghost" onClick={clearHistory}>
            Clear history
          </Button>
        )}
      </div>

      {rows.length > 0 && (
        <div className="run-history__list">
          {rows.map((entry) => (
            <RunHistoryRow
              key={entry.id}
              entry={entry}
              now={now}
              compact={compact}
              busy={busy}
              onRunAgain={onRunAgain ? handleRunAgain : undefined}
            />
          ))}
        </div>
      )}
    </div>
  );
}
