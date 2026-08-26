import { create } from "zustand";

/**
 * Central error/diagnostics store.
 *
 * Two distinct streams share one shape so a single UI can render both:
 * - "system": Windows Event Log Critical/Error entries, fetched from the
 *   sidecar's errors.system RPC (see core/ - backed by the same
 *   Get-WinEvent approach as tools/maintenance/Get-RecentEventErrors.ps1).
 * - "app": DevKit's own failures - Rust/sidecar lines parsed out of
 *   %LOCALAPPDATA%\NorthstarDevKit\logs\devkit.log via errors.app, PLUS
 *   frontend faults captured live in-process (window.onerror, unhandled
 *   promise rejections, React render crashes via ErrorBoundary, and
 *   failed rpcCall round-trips).
 *
 * Entries are deduplicated by `dedupeKey`: an identical fault seen N
 * times becomes ONE entry with count=N and a refreshed `timestamp`,
 * rather than N rows burying everything else. That matters because a
 * broken poll can fire every 2 seconds indefinitely.
 */

export type ErrorSource = "system" | "app";
export type ErrorSeverity = "critical" | "error" | "warning";

export interface ErrorEntry {
  /** Stable id for React keys and dismissal. */
  id: string;
  source: ErrorSource;
  severity: ErrorSeverity;
  /** ISO 8601. For deduped entries this is the MOST RECENT occurrence. */
  timestamp: string;
  /** One-line summary shown in the list. */
  title: string;
  /** Full text: event message, stack trace, sidecar detail, etc. */
  detail: string;
  /** Where it came from: an event provider, a component name, an RPC method. */
  origin?: string;
  /** Occurrences collapsed into this entry (>=1). */
  count: number;
  /** Identical faults share this key - see the dedupe note above. */
  dedupeKey: string;
  /** Anything source-specific worth showing in the detail view. */
  meta?: Record<string, unknown>;
}

/** An entry as reported by a producer - the store fills in id/count/dedupeKey. */
export type ErrorInput = Omit<ErrorEntry, "id" | "count" | "dedupeKey"> & {
  dedupeKey?: string;
};

interface ErrorState {
  entries: ErrorEntry[];
  /** Entry ids the user has already looked at - drives the unseen badge. */
  seen: Set<string>;
  /** Most recent errors.system / errors.app fetch failure, if any. */
  fetchError: string | null;

  record: (input: ErrorInput) => void;
  recordMany: (inputs: ErrorInput[]) => void;
  dismiss: (id: string) => void;
  clearSource: (source: ErrorSource) => void;
  clearAll: () => void;
  markAllSeen: () => void;
  setFetchError: (message: string | null) => void;
  unseenCount: () => number;
}

/** Hard ceiling so a runaway producer can never grow this unbounded. */
const MAX_ENTRIES = 500;

function defaultDedupeKey(input: ErrorInput): string {
  // Title + origin + severity is a good identity for "the same fault
  // happening again"; detail is deliberately excluded because stack
  // traces and event messages often carry per-occurrence noise
  // (timestamps, pids, addresses) that would defeat deduplication.
  return `${input.source}|${input.severity}|${input.origin ?? ""}|${input.title}`;
}

function makeId(): string {
  try {
    return crypto.randomUUID();
  } catch {
    return `err-${Math.random().toString(36).slice(2)}`;
  }
}

function merge(entries: ErrorEntry[], input: ErrorInput): ErrorEntry[] {
  const key = input.dedupeKey ?? defaultDedupeKey(input);
  const existing = entries.findIndex((e) => e.dedupeKey === key);
  if (existing >= 0) {
    const prev = entries[existing];
    const updated: ErrorEntry = {
      ...prev,
      count: prev.count + 1,
      // Keep the newest occurrence's timestamp and detail - when something
      // is failing repeatedly, the latest instance is the useful one.
      timestamp: input.timestamp,
      detail: input.detail,
      meta: input.meta ?? prev.meta,
    };
    const next = entries.slice();
    next.splice(existing, 1);
    return [updated, ...next];
  }
  const entry: ErrorEntry = { ...input, id: makeId(), count: 1, dedupeKey: key };
  return [entry, ...entries].slice(0, MAX_ENTRIES);
}

export const useErrorStore = create<ErrorState>((set, get) => ({
  entries: [],
  seen: new Set<string>(),
  fetchError: null,

  record: (input) => set((s) => ({ entries: merge(s.entries, input) })),

  recordMany: (inputs) =>
    set((s) => {
      let next = s.entries;
      for (const input of inputs) next = merge(next, input);
      return { entries: next };
    }),

  dismiss: (id) => set((s) => ({ entries: s.entries.filter((e) => e.id !== id) })),

  clearSource: (source) => set((s) => ({ entries: s.entries.filter((e) => e.source !== source) })),

  clearAll: () => set({ entries: [], seen: new Set<string>() }),

  markAllSeen: () => set((s) => ({ seen: new Set(s.entries.map((e) => e.id)) })),

  setFetchError: (message) => set({ fetchError: message }),

  unseenCount: () => {
    const { entries, seen } = get();
    return entries.reduce((n, e) => (seen.has(e.id) ? n : n + 1), 0);
  },
}));
