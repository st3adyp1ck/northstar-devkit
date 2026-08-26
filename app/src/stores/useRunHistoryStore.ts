import { create } from "zustand";
import { useSettingsStore } from "./useSettingsStore";

/**
 * Tool run history.
 *
 * Every `tool.run` the app launches used to stream its output into a
 * console that vanished the moment the dialog (or the widget panel) went
 * away. This store keeps the last N runs - what was run, with which args,
 * when, for how long, how it exited, and the output it produced - so a run
 * can be re-read afterwards and re-fired without retyping its prompts.
 *
 * Three separate ceilings keep a chatty tool from eating the process:
 *   - MAX_LINE_CHARS   - one absurd line (a base64 blob, a minified bundle)
 *                        is clipped rather than retained whole;
 *   - MAX_LINES_PER_RUN- only the newest lines of a run are kept, the count
 *                        of dropped ones lives in `droppedLines` so the UI
 *                        can say "output truncated";
 *   - MAX_TOTAL_CHARS  - a whole-history budget applied oldest-first, so 50
 *                        chatty runs can't add up to something huge even
 *                        when each one is individually under its cap.
 *
 * Persistence is localStorage, deliberately defensively: every single
 * access is wrapped (the accessor itself throws in some contexts, not just
 * the read), the serialized payload is capped, and anything that doesn't
 * round-trip cleanly is dropped rather than trusted. History is a
 * convenience - it must never be able to wedge startup.
 */

export interface RunHistoryLine {
  stream: string;
  line: string;
}

export interface RunHistoryEntry {
  /** The `runId` the run was launched with - stable, and unique per run. */
  id: string;
  folder: string;
  script: string;
  label: string;
  args: string[];
  /** ISO 8601. */
  startedAt: string;
  /** ISO 8601, or null while the run is still streaming. */
  finishedAt: string | null;
  /** null when the run was never seen to end (detached watcher, app restart). */
  exitCode: number | null;
  output: RunHistoryLine[];
  /** Lines dropped off the front of `output` by any of the three caps. */
  droppedLines: number;
  /** Caution tool - "Run again" re-applies the confirmDestructive gate. */
  caution: boolean;
  /** The watcher went away before `tool.finished` arrived; outcome unknown. */
  detached: boolean;
}

/** What a caller knows about a run at launch time. */
export interface RunSpec {
  folder: string;
  script: string;
  label: string;
  args: string[];
  caution?: boolean;
}

const STORAGE_KEY = "devkit.runHistory.v1";
const DEFAULT_LIMIT = 50;
/** Hard ceiling on retained runs regardless of the user's runHistoryLimit. */
const MAX_LIMIT = 200;
const MAX_LINES_PER_RUN = 300;
const MAX_LINE_CHARS = 1000;
/** Whole-history output budget, in UTF-16 code units (~4 MB of text). */
const MAX_TOTAL_CHARS = 2_000_000;
/** Serialized cap - localStorage quota is a few MB and shared app-wide. */
const MAX_SERIALIZED_CHARS = 200_000;
/** Trailing debounce for the mid-run persists (see schedulePersist). */
const PERSIST_DEBOUNCE_MS = 1500;

/* ------------------------------------------------------------------ */
/* localStorage                                                        */
/* ------------------------------------------------------------------ */

/** Even reaching for `window.localStorage` throws when site data is blocked. */
function storage(): Storage | null {
  try {
    if (typeof window === "undefined") return null;
    return window.localStorage ?? null;
  } catch {
    return null;
  }
}

function sanitizeLine(value: unknown): RunHistoryLine | null {
  if (!value || typeof value !== "object") return null;
  const raw = value as Record<string, unknown>;
  if (typeof raw.line !== "string") return null;
  return {
    stream: raw.stream === "stderr" ? "stderr" : "stdout",
    line: raw.line.length > MAX_LINE_CHARS ? raw.line.slice(0, MAX_LINE_CHARS) : raw.line,
  };
}

/**
 * Rebuilds an entry from whatever JSON.parse handed back. Anything missing
 * a required field is discarded - a half-written or hand-edited payload
 * must not reach the UI as `undefined.map(...)`.
 */
function sanitizeEntry(value: unknown): RunHistoryEntry | null {
  if (!value || typeof value !== "object") return null;
  const raw = value as Record<string, unknown>;
  if (typeof raw.id !== "string" || typeof raw.script !== "string" || typeof raw.startedAt !== "string") return null;

  const output: RunHistoryLine[] = [];
  if (Array.isArray(raw.output)) {
    for (const item of raw.output) {
      const line = sanitizeLine(item);
      if (line) output.push(line);
    }
  }

  return {
    id: raw.id,
    folder: typeof raw.folder === "string" ? raw.folder : "",
    script: raw.script,
    label: typeof raw.label === "string" && raw.label ? raw.label : raw.script,
    args: Array.isArray(raw.args) ? raw.args.filter((a): a is string => typeof a === "string") : [],
    startedAt: raw.startedAt,
    // A run persisted as still-running belongs to a process that is gone:
    // nothing in THIS process is listening for its tool.finished, so it can
    // never be finalized. Restore it as an ended run with an unknown
    // outcome rather than a row that spins forever.
    finishedAt: typeof raw.finishedAt === "string" ? raw.finishedAt : raw.startedAt,
    exitCode: typeof raw.exitCode === "number" ? raw.exitCode : null,
    output: output.slice(-MAX_LINES_PER_RUN),
    droppedLines: typeof raw.droppedLines === "number" && raw.droppedLines > 0 ? Math.floor(raw.droppedLines) : 0,
    caution: raw.caution === true,
    detached: raw.detached === true || typeof raw.exitCode !== "number",
  };
}

function parseEntries(raw: string | null): RunHistoryEntry[] {
  if (!raw) return [];
  try {
    const parsed: unknown = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    const entries: RunHistoryEntry[] = [];
    for (const item of parsed) {
      const entry = sanitizeEntry(item);
      if (entry) entries.push(entry);
    }
    return entries.slice(0, MAX_LIMIT);
  } catch {
    return [];
  }
}

function loadPersisted(): RunHistoryEntry[] {
  const store = storage();
  if (!store) return [];
  try {
    return parseEntries(store.getItem(STORAGE_KEY));
  } catch {
    return [];
  }
}

/** Metadata-only copy of an entry - keeps the row, drops the transcript. */
function stripOutput(entry: RunHistoryEntry): RunHistoryEntry {
  if (entry.output.length === 0) return entry;
  return { ...entry, output: [], droppedLines: entry.droppedLines + entry.output.length };
}

/**
 * Serializes under MAX_SERIALIZED_CHARS by giving up detail before giving
 * up rows: full transcripts for the newest few runs, then metadata-only
 * rows, then fewer rows. A history that cannot be shrunk to fit is simply
 * not written.
 */
function serialize(entries: RunHistoryEntry[]): string | null {
  let candidate = entries;
  let json = JSON.stringify(candidate);
  if (json.length <= MAX_SERIALIZED_CHARS) return json;

  for (const keepFull of [16, 8, 4, 2, 1, 0]) {
    candidate = entries.map((e, i) => (i < keepFull ? e : stripOutput(e)));
    json = JSON.stringify(candidate);
    if (json.length <= MAX_SERIALIZED_CHARS) return json;
  }

  // Still oversized with no transcripts at all: drop the oldest rows.
  let count = candidate.length;
  while (count > 0) {
    count = Math.floor(count / 2);
    json = JSON.stringify(candidate.slice(0, count));
    if (json.length <= MAX_SERIALIZED_CHARS) return json;
  }
  return null;
}

function persist(entries: RunHistoryEntry[]): void {
  const store = storage();
  if (!store) return;
  try {
    const json = serialize(entries);
    if (json === null) {
      store.removeItem(STORAGE_KEY);
      return;
    }
    store.setItem(STORAGE_KEY, json);
  } catch {
    // Quota exceeded, private mode, storage disabled - history stays
    // in-memory for this session. Never surfaced: it isn't the user's problem.
  }
}

let persistTimer: ReturnType<typeof setTimeout> | null = null;

function flushPersist(entries: RunHistoryEntry[]): void {
  if (persistTimer !== null) {
    clearTimeout(persistTimer);
    persistTimer = null;
  }
  persist(entries);
}

/**
 * Mid-run output arrives a line at a time; writing localStorage on each one
 * would serialize the whole history hundreds of times per run. Trailing
 * debounce instead - the run's start and its finish both flush immediately,
 * so the only thing a missed write can cost is the tail of a transcript
 * whose process died mid-run anyway.
 */
function schedulePersist(read: () => RunHistoryEntry[]): void {
  if (persistTimer !== null) return;
  persistTimer = setTimeout(() => {
    persistTimer = null;
    persist(read());
  }, PERSIST_DEBOUNCE_MS);
}

/* ------------------------------------------------------------------ */
/* memory budget                                                       */
/* ------------------------------------------------------------------ */

/**
 * Applies MAX_TOTAL_CHARS oldest-first: the newest runs keep their
 * transcripts, older ones are reduced to metadata until the whole history
 * is back under budget.
 */
function enforceBudget(entries: RunHistoryEntry[]): RunHistoryEntry[] {
  let total = 0;
  for (const entry of entries) {
    for (const line of entry.output) total += line.line.length;
  }
  if (total <= MAX_TOTAL_CHARS) return entries;

  const next = entries.slice();
  for (let i = next.length - 1; i >= 0 && total > MAX_TOTAL_CHARS; i--) {
    const entry = next[i];
    if (entry.output.length === 0) continue;
    for (const line of entry.output) total -= line.line.length;
    next[i] = stripOutput(entry);
  }
  return next;
}

function clampLimit(value: unknown): number {
  if (typeof value !== "number" || !Number.isFinite(value)) return DEFAULT_LIMIT;
  return Math.min(MAX_LIMIT, Math.max(1, Math.floor(value)));
}

/**
 * Union by run id, newest first. Used only by the cross-window storage
 * listener: the local copy wins whenever it is the richer one (this window
 * may be mid-run on an entry another window only ever saw as metadata).
 */
function mergeEntries(local: RunHistoryEntry[], incoming: RunHistoryEntry[], limit: number): RunHistoryEntry[] {
  const byId = new Map<string, RunHistoryEntry>();
  for (const entry of incoming) byId.set(entry.id, entry);
  for (const entry of local) {
    const other = byId.get(entry.id);
    if (!other) {
      byId.set(entry.id, entry);
      continue;
    }
    const localIsLive = entry.finishedAt === null;
    const localIsRicher = entry.output.length >= other.output.length;
    if (localIsLive || localIsRicher) byId.set(entry.id, entry);
  }
  return [...byId.values()]
    .sort((a, b) => Date.parse(b.startedAt) - Date.parse(a.startedAt))
    .slice(0, limit);
}

/* ------------------------------------------------------------------ */
/* store                                                               */
/* ------------------------------------------------------------------ */

interface RunHistoryState {
  /** Newest first. */
  entries: RunHistoryEntry[];
  /** Mirror of settings.preferences.runHistoryLimit, clamped. */
  limit: number;

  /** Records a run at launch. `id` is the runId passed to `tool.run`. */
  startRun: (id: string, spec: RunSpec) => void;
  appendLine: (id: string, stream: string, line: string) => void;
  finishRun: (id: string, exitCode: number) => void;
  /** The watcher is going away (dialog closed, user stopped watching). */
  detachRun: (id: string) => void;
  clear: () => void;
}

export const useRunHistoryStore = create<RunHistoryState>((set, get) => ({
  entries: loadPersisted(),
  limit: clampLimit(useSettingsStore.getState().settings?.preferences.runHistoryLimit),

  startRun: (id, spec) => {
    set((s) => {
      const entry: RunHistoryEntry = {
        id,
        folder: spec.folder,
        script: spec.script,
        label: spec.label,
        args: [...spec.args],
        startedAt: new Date().toISOString(),
        finishedAt: null,
        exitCode: null,
        output: [],
        droppedLines: 0,
        caution: spec.caution === true,
        detached: false,
      };
      return { entries: [entry, ...s.entries.filter((e) => e.id !== id)].slice(0, s.limit) };
    });
    flushPersist(get().entries);
  },

  appendLine: (id, stream, line) => {
    set((s) => {
      const index = s.entries.findIndex((e) => e.id === id);
      if (index < 0) return s;
      const prev = s.entries[index];
      const text = line.length > MAX_LINE_CHARS ? `${line.slice(0, MAX_LINE_CHARS)} …[line truncated]` : line;
      let output = [...prev.output, { stream: stream === "stderr" ? "stderr" : "stdout", line: text }];
      let droppedLines = prev.droppedLines;
      if (output.length > MAX_LINES_PER_RUN) {
        const excess = output.length - MAX_LINES_PER_RUN;
        output = output.slice(excess);
        droppedLines += excess;
      }
      const entries = s.entries.slice();
      entries[index] = { ...prev, output, droppedLines };
      return { entries };
    });
    schedulePersist(() => get().entries);
  },

  finishRun: (id, exitCode) => {
    set((s) => {
      const index = s.entries.findIndex((e) => e.id === id);
      if (index < 0) return s;
      const entries = s.entries.slice();
      entries[index] = {
        ...entries[index],
        finishedAt: new Date().toISOString(),
        exitCode,
        detached: false,
      };
      return { entries: enforceBudget(entries) };
    });
    flushPersist(get().entries);
  },

  detachRun: (id) => {
    set((s) => {
      const index = s.entries.findIndex((e) => e.id === id);
      if (index < 0 || s.entries[index].finishedAt !== null) return s;
      const entries = s.entries.slice();
      entries[index] = { ...entries[index], finishedAt: new Date().toISOString(), exitCode: null, detached: true };
      return { entries: enforceBudget(entries) };
    });
    flushPersist(get().entries);
  },

  clear: () => {
    set({ entries: [] });
    flushPersist([]);
  },
}));

/**
 * runHistoryLimit lives in settings.json, which is fetched asynchronously
 * per window - so the limit is picked up the same way sounds.ts picks up
 * uiSounds: read once now, then track the store. A lowered limit prunes
 * immediately rather than waiting for the next run.
 */
useSettingsStore.subscribe((state) => {
  const limit = clampLimit(state.settings?.preferences.runHistoryLimit);
  const current = useRunHistoryStore.getState();
  if (limit === current.limit) return;
  const entries = current.entries.length > limit ? current.entries.slice(0, limit) : current.entries;
  useRunHistoryStore.setState({ limit, entries });
  if (entries !== current.entries) flushPersist(entries);
});

/**
 * Each Tauri window is its own webview with its own store instances, but
 * they share one localStorage origin - so a run recorded in the Control
 * Center fires a `storage` event in the widget and vice versa. Merging
 * (never re-persisting, which would ping-pong) keeps the two views roughly
 * in step without any Tauri event plumbing. If the event doesn't fire in a
 * given host, nothing breaks: each window simply keeps its own view until
 * the next reload.
 */
try {
  if (typeof window !== "undefined") {
    window.addEventListener("storage", (event) => {
      if (event.key !== STORAGE_KEY) return;
      const incoming = parseEntries(event.newValue);
      const current = useRunHistoryStore.getState();
      useRunHistoryStore.setState({ entries: mergeEntries(current.entries, incoming, current.limit) });
    });
  }
} catch {
  // No window/event support - purely in-memory history for this context.
}
