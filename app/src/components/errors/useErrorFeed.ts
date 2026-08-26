import { useCallback, useEffect, useRef } from "react";
import { usePolledRpc } from "../../hooks/usePolledRpc";
import { rpcCall } from "../../lib/ipc";
import { asArray } from "../../lib/arrays";
import { useErrorStore, type ErrorInput, type ErrorSeverity, type ErrorSource } from "../../stores/useErrorStore";

/**
 * The backend half of the Error Center's feed: the two sidecar methods that
 * report faults DevKit itself didn't witness in-process.
 *
 *   errors.system  { hours, max } -> entries[]   Windows Event Log
 *   errors.app     { max }        -> entries[]   DevKit's own log file
 *   errors.clearAppLogs           -> { cleared }
 *
 * Both are polled on a deliberately slow, visibility-gated cadence
 * (usePolledRpc): Get-WinEvent is not free and system errors change on the
 * order of hours, not seconds. A manual Refresh covers the "I just saw
 * something break" case.
 *
 * Ingestion is idempotent. react-query hands back a NEW array reference on
 * every poll where anything changed, and re-recording an entry the store has
 * already seen would bump its `count` even though nothing happened again -
 * turning the dedupe counter into a poll counter. So each incoming entry
 * gets an ingest key (its Event Log record id when there is one, otherwise
 * timestamp + origin + title) and entries whose key was already ingested are
 * dropped. A genuinely new occurrence carries a new timestamp/record id, so
 * it still lands and still bumps the store's count exactly once.
 */

const SYSTEM_HOURS = 24;
const SYSTEM_MAX = 200;
const APP_MAX = 200;
/** System errors move slowly and Get-WinEvent is expensive - five minutes. */
const SYSTEM_INTERVAL_MS = 300_000;
/** DevKit's own log is cheap to read and more likely to change while you watch. */
const APP_INTERVAL_MS = 120_000;
/** Ingest-key memory ceiling - dropped wholesale once passed (worst case: a few re-counted rows). */
const MAX_INGEST_KEYS = 4000;

export interface ErrorFeed {
  /** Window the system query asks for, for honest empty-state copy. */
  systemHours: number;
  systemLoading: boolean;
  appLoading: boolean;
  /** Non-null when that section's fetch failed - render "unavailable", never an empty list. */
  systemError: string | null;
  appError: string | null;
  refreshing: boolean;
  refresh: () => void;
  /** Forget what's been ingested for a source, so a cleared section can refill on the next poll. */
  forgetIngested: (source: ErrorSource) => void;
  /** errors.clearAppLogs - resolves with the number of cleared lines, rejects on failure. */
  clearAppLogs: () => Promise<number>;
}

// ---------------------------------------------------------------------------
// wire normalization
// ---------------------------------------------------------------------------

/**
 * Keys consumed into first-class ErrorInput fields. Anything else on a wire
 * entry is folded into `meta` so the detail view really can show
 * "everything it can tell me" without this file needing to know the schema.
 */
const KNOWN_KEYS = new Set([
  "source",
  "Source",
  "severity",
  "Severity",
  "level",
  "Level",
  "timestamp",
  "Timestamp",
  "time",
  "Time",
  "timeCreated",
  "TimeCreated",
  "title",
  "Title",
  "detail",
  "Detail",
  "message",
  "Message",
  "origin",
  "Origin",
  "provider",
  "Provider",
  "providerName",
  "ProviderName",
  "meta",
  "Meta",
]);

function pick(obj: Record<string, unknown>, names: string[]): unknown {
  for (const name of names) {
    const value = obj[name];
    if (value !== undefined && value !== null && value !== "") return value;
  }
  return undefined;
}

function asText(value: unknown): string | undefined {
  if (typeof value === "string") return value;
  if (typeof value === "number" || typeof value === "boolean") return String(value);
  return undefined;
}

function normalizeSeverity(value: unknown): ErrorSeverity {
  const text = asText(value)?.toLowerCase().trim();
  if (text === "critical" || text === "error" || text === "warning") return text;
  // Windows Event Log numeric levels: 1 Critical, 2 Error, 3 Warning.
  if (text === "1") return "critical";
  if (text === "3") return "warning";
  if (text === "fatal") return "critical";
  if (text === "warn") return "warning";
  return "error";
}

function normalizeSource(value: unknown, fallback: ErrorSource): ErrorSource {
  const text = asText(value)?.toLowerCase().trim();
  return text === "system" || text === "app" ? text : fallback;
}

function normalizeTimestamp(value: unknown): string {
  if (typeof value === "number" && Number.isFinite(value)) {
    return new Date(value).toISOString();
  }
  const text = asText(value);
  if (text) {
    const parsed = new Date(text).getTime();
    if (!Number.isNaN(parsed)) return new Date(parsed).toISOString();
  }
  return new Date().toISOString();
}

/**
 * Accepts both casings. The sidecar's other methods serialize PascalCase
 * (see lib/types.ts) while this contract was specified lowercase, and a
 * casing mismatch would silently render a list of blank rows - cheap
 * insurance for something a separate agent is implementing.
 */
function normalizeEntry(raw: unknown, fallbackSource: ErrorSource): ErrorInput | null {
  if (!raw || typeof raw !== "object") return null;
  const obj = raw as Record<string, unknown>;

  const title = asText(pick(obj, ["title", "Title", "message", "Message"]))?.trim();
  if (!title) return null;

  const detail = asText(pick(obj, ["detail", "Detail", "message", "Message"])) ?? title;
  const origin = asText(pick(obj, ["origin", "Origin", "providerName", "ProviderName", "provider", "Provider"]));

  const wireMeta = pick(obj, ["meta", "Meta"]);
  const meta: Record<string, unknown> =
    wireMeta && typeof wireMeta === "object" && !Array.isArray(wireMeta) ? { ...(wireMeta as Record<string, unknown>) } : {};
  for (const [key, value] of Object.entries(obj)) {
    if (KNOWN_KEYS.has(key)) continue;
    if (value === undefined) continue;
    meta[key] = value;
  }

  return {
    source: normalizeSource(pick(obj, ["source", "Source"]), fallbackSource),
    severity: normalizeSeverity(pick(obj, ["severity", "Severity", "level", "Level"])),
    timestamp: normalizeTimestamp(pick(obj, ["timestamp", "Timestamp", "timeCreated", "TimeCreated", "time", "Time"])),
    title,
    detail,
    origin,
    meta: Object.keys(meta).length > 0 ? meta : undefined,
  };
}

/** Identity of one delivered occurrence - see the ingestion note above. */
function ingestKey(entry: ErrorInput): string {
  const recordId = entry.meta ? (entry.meta.recordId ?? entry.meta.RecordId ?? entry.meta.id ?? entry.meta.Id) : undefined;
  if (recordId !== undefined && recordId !== null && recordId !== "") {
    return `${entry.source}|rid:${String(recordId)}`;
  }
  return `${entry.source}|${entry.timestamp}|${entry.origin ?? ""}|${entry.title}`;
}

// ---------------------------------------------------------------------------
// the hook
// ---------------------------------------------------------------------------

export function useErrorFeed(): ErrorFeed {
  const recordMany = useErrorStore((s) => s.recordMany);
  const setFetchError = useErrorStore((s) => s.setFetchError);
  const ingested = useRef<Set<string>>(new Set());

  const systemQuery = usePolledRpc<unknown>("errors.system", { hours: SYSTEM_HOURS, max: SYSTEM_MAX }, SYSTEM_INTERVAL_MS);
  const appQuery = usePolledRpc<unknown>("errors.app", { max: APP_MAX }, APP_INTERVAL_MS);

  const ingest = useCallback(
    (payload: unknown, source: ErrorSource) => {
      const seen = ingested.current;
      if (seen.size > MAX_INGEST_KEYS) seen.clear();
      const fresh: ErrorInput[] = [];
      for (const raw of asArray(payload)) {
        const entry = normalizeEntry(raw, source);
        if (!entry) continue;
        const key = ingestKey(entry);
        if (seen.has(key)) continue;
        seen.add(key);
        fresh.push(entry);
      }
      if (fresh.length > 0) recordMany(fresh);
    },
    [recordMany],
  );

  const systemData = systemQuery.data;
  const appData = appQuery.data;

  useEffect(() => {
    if (systemData === undefined) return;
    ingest(systemData, "system");
  }, [systemData, ingest]);

  useEffect(() => {
    if (appData === undefined) return;
    ingest(appData, "app");
  }, [appData, ingest]);

  // usePolledRpc's honest-health flags (see PolledRpcStatus): `errorMessage`
  // is non-null whenever the LAST attempt failed - which is exactly the
  // condition where this dialog must say "couldn't ask" instead of showing a
  // list that reads as "all clear" - and `pending` is a first load with
  // nothing to show yet.
  const systemError = systemQuery.errorMessage;
  const appError = appQuery.errorMessage;

  // Mirror the fetch failures into the store too, so anything outside this
  // dialog (a badge, a future notification) can tell "no errors" apart from
  // "couldn't ask" without re-running the queries.
  useEffect(() => {
    const parts: string[] = [];
    if (systemError) parts.push(`System errors unavailable: ${systemError}`);
    if (appError) parts.push(`DevKit error log unavailable: ${appError}`);
    setFetchError(parts.length > 0 ? parts.join(" · ") : null);
  }, [systemError, appError, setFetchError]);

  const refetchSystem = systemQuery.refetch;
  const refetchApp = appQuery.refetch;
  const refresh = useCallback(() => {
    void refetchSystem();
    void refetchApp();
  }, [refetchSystem, refetchApp]);

  const forgetIngested = useCallback((source: ErrorSource) => {
    const seen = ingested.current;
    for (const key of Array.from(seen)) {
      if (key.startsWith(`${source}|`)) seen.delete(key);
    }
  }, []);

  const clearAppLogs = useCallback(async () => {
    const result = await rpcCall<{ cleared?: number; Cleared?: number } | null>("errors.clearAppLogs");
    const cleared = result ? (result.cleared ?? result.Cleared) : undefined;
    return typeof cleared === "number" ? cleared : 0;
  }, []);

  return {
    systemHours: SYSTEM_HOURS,
    systemLoading: systemQuery.pending,
    appLoading: appQuery.pending,
    systemError,
    appError,
    refreshing: systemQuery.isFetching || appQuery.isFetching,
    refresh,
    forgetIngested,
    clearAppLogs,
  };
}
