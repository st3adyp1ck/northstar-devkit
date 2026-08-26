/**
 * Frontend fault capture - the "app" half of the Error Center's feed.
 *
 * Three producers land here, all of them shaped into stores/useErrorStore's
 * ErrorInput and recorded as source:"app":
 *   - uncaught exceptions           (window 'error')
 *   - unhandled promise rejections  (window 'unhandledrejection')
 *   - failed RPC round-trips        (lib/ipc.ts's rpcCall, before it rethrows)
 *   - React render crashes          (components/ErrorBoundary.tsx)
 *
 * Two invariants everything here is built around:
 *
 * 1. Reporting an error must never itself throw or change control flow.
 *    Every entry point is wrapped; rpcCall's caller still receives the exact
 *    same rejection it always did.
 *
 * 2. Dedupe keys must be STABLE across occurrences of the same fault. A
 *    broken 2-second poll fires ~1800 times an hour; the store collapses
 *    identical keys into one row with count=N, but only if the key doesn't
 *    carry per-occurrence noise. So keys are built from a *masked* first
 *    line (numbers, GUIDs and Windows paths replaced with placeholders) plus
 *    a stable locator (the RPC method, the source file, the component), and
 *    never from the raw message or a stack.
 */

import { useErrorStore, type ErrorInput } from "../stores/useErrorStore";

/** Stacks and event messages can be enormous; the detail view only needs so much. */
const MAX_DETAIL_CHARS = 8000;
/** Masked first line kept for the dedupe key - long enough to distinguish, short enough to stay stable. */
const MAX_KIND_CHARS = 80;
/**
 * A runaway loop (an error thrown inside an interval, a render crash that
 * retries) can fire hundreds of times a second. Recording each one would
 * re-render every Error Center subscriber that often. Instead the first
 * occurrence records immediately and further occurrences of the SAME key
 * inside the window are counted and replayed in one batch when it closes,
 * so the visible count stays honest without the render storm.
 */
const THROTTLE_MS = 400;
/** Ceiling on a single replay batch, so one pathological second can't add 10k counts. */
const MAX_REPLAY = 25;

/**
 * RPC methods whose failures are NOT recorded as app errors. The Error
 * Center's own fetches live here: they already surface through
 * useErrorStore.fetchError as a "this section is unavailable" notice, and
 * recording them would make the dialog report on its own inability to
 * report - a self-referential row that reappears every poll.
 */
const UNRECORDED_RPC_PREFIXES = ["errors."];

let installed = false;

// ---------------------------------------------------------------------------
// value description
// ---------------------------------------------------------------------------

interface Described {
  name: string;
  message: string;
  stack: string | null;
}

function describeThrown(value: unknown): Described {
  if (value instanceof Error) {
    return { name: value.name || "Error", message: value.message || value.name || "Error", stack: value.stack ?? null };
  }
  if (typeof value === "string") {
    return { name: "Error", message: value, stack: null };
  }
  if (value === null || value === undefined) {
    return { name: "Error", message: String(value), stack: null };
  }
  try {
    const json = JSON.stringify(value);
    return { name: "Error", message: json && json !== "{}" ? json : String(value), stack: null };
  } catch {
    return { name: "Error", message: String(value), stack: null };
  }
}

function titleFor(described: Described): string {
  const message = described.message.split("\n")[0].trim();
  if (!message) return described.name;
  return described.name && described.name !== "Error" ? `${described.name}: ${message}` : message;
}

function firstLine(text: string): string {
  return text.split("\n")[0].trim();
}

/**
 * Replaces the parts of a message that differ between two occurrences of the
 * SAME fault - GUIDs, Windows paths, and any run of digits (pids, ports,
 * byte counts, timestamps, memory addresses). What's left is the shape of
 * the message, which is what a dedupe key wants.
 */
function maskVolatile(text: string): string {
  return text
    .replace(/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi, "<guid>")
    .replace(/[A-Za-z]:\\[^\s"']+/g, "<path>")
    // No \b anchors: a unit-suffixed number ("5000ms", "3s") has no word
    // boundary before its suffix, and leaving those unmasked is exactly the
    // case that would defeat dedupe for a timeout that reports its elapsed
    // time. Over-masking is the safe direction here - two faults that differ
    // only in a number ARE the same fault for this purpose.
    .replace(/\d[\d.,:]*/g, "<n>");
}

/** The stable "kind" of an error message - see maskVolatile and the header note. */
export function errorKind(message: string): string {
  const masked = maskVolatile(firstLine(message));
  return masked.length > MAX_KIND_CHARS ? masked.slice(0, MAX_KIND_CHARS) : masked;
}

function truncate(text: string): string {
  if (text.length <= MAX_DETAIL_CHARS) return text;
  return `${text.slice(0, MAX_DETAIL_CHARS)}\n… ${text.length - MAX_DETAIL_CHARS} more characters truncated`;
}

function basename(path: string): string {
  const parts = path.split(/[\\/]/);
  return parts[parts.length - 1] || path;
}

/** Which webview this came from - both windows run this module independently. */
function windowLabel(): string {
  try {
    return new URLSearchParams(window.location.search).get("window") ?? "widget";
  } catch {
    return "widget";
  }
}

/** First component name out of a React component stack ("\n    at Foo (...)"). */
function firstComponent(componentStack: string): string | null {
  const match = /(?:^|\n)\s*(?:at\s+)?([A-Za-z0-9_$]+)/.exec(componentStack);
  return match ? match[1] : null;
}

// ---------------------------------------------------------------------------
// double-report suppression
// ---------------------------------------------------------------------------

/**
 * Errors already recorded by a more specific producer. An RpcClientError
 * that nobody catches reaches 'unhandledrejection' too; rpcCall's entry
 * (which knows the method name) is strictly more useful than a generic
 * "unhandled rejection" row, so the generic handler skips anything in here.
 */
const alreadyRecorded = new WeakSet<object>();

function markRecorded(value: unknown): void {
  if (value !== null && typeof value === "object") alreadyRecorded.add(value as object);
}

function wasRecorded(value: unknown): boolean {
  return value !== null && typeof value === "object" && alreadyRecorded.has(value as object);
}

// ---------------------------------------------------------------------------
// throttled recording
// ---------------------------------------------------------------------------

interface ThrottleState {
  suppressed: number;
  latest: ErrorInput;
  timer: number | null;
}

const throttled = new Map<string, ThrottleState>();

function openWindow(key: string, entry: ErrorInput): void {
  const state: ThrottleState = { suppressed: 0, latest: entry, timer: null };
  state.timer = window.setTimeout(() => closeWindowFor(key), THROTTLE_MS);
  throttled.set(key, state);
}

function closeWindowFor(key: string): void {
  const state = throttled.get(key);
  if (!state) return;
  if (state.suppressed <= 0) {
    throttled.delete(key);
    return;
  }
  const replay = Math.min(state.suppressed, MAX_REPLAY);
  const latest = state.latest;
  try {
    useErrorStore.getState().recordMany(new Array<ErrorInput>(replay).fill(latest));
  } catch {
    // never let error reporting throw
  }
  // Still failing - keep coalescing rather than reverting to one set() per fault.
  openWindow(key, latest);
}

/**
 * The single funnel every frontend producer goes through. Fills in a stable
 * dedupeKey when the caller didn't supply one, truncates the detail, and
 * applies the throttle described at the top of the file. Never throws.
 */
export function recordAppError(input: ErrorInput): void {
  try {
    const key = input.dedupeKey ?? `app|${input.severity}|${input.origin ?? ""}|${errorKind(input.title)}`;
    const entry: ErrorInput = { ...input, dedupeKey: key, detail: truncate(input.detail) };
    const state = throttled.get(key);
    if (state) {
      state.suppressed += 1;
      state.latest = entry;
      return;
    }
    useErrorStore.getState().record(entry);
    openWindow(key, entry);
  } catch {
    // Reporting a failure must never become a failure.
  }
}

// ---------------------------------------------------------------------------
// producers
// ---------------------------------------------------------------------------

/**
 * Records a failed rpcCall. `origin` is the method name and the dedupe key
 * is `rpc|<method>|<masked first line>` - deliberately NOT the full message,
 * so a poll failing every 2 seconds is one row with a climbing count instead
 * of an unbounded wall of near-identical rows.
 *
 * Called from lib/ipc.ts BEFORE it rethrows; the caller's rejection is
 * untouched.
 */
export function recordRpcFailure(method: string, err: unknown): void {
  for (const prefix of UNRECORDED_RPC_PREFIXES) {
    if (method.startsWith(prefix)) return;
  }
  markRecorded(err);
  const described = describeThrown(err);
  const kind = errorKind(described.message);
  recordAppError({
    source: "app",
    severity: "error",
    timestamp: new Date().toISOString(),
    title: `RPC failed: ${method}`,
    detail: described.stack ? `${described.message}\n\n${described.stack}` : described.message,
    origin: method,
    dedupeKey: `rpc|${method}|${kind}`,
    meta: { method, kind, window: windowLabel() },
  });
}

/**
 * Records a React render/lifecycle crash caught by ErrorBoundary. Critical,
 * because unlike everything else here it means a window went blank.
 */
export function recordRenderError(err: unknown, componentStack: string | null): void {
  markRecorded(err);
  const described = describeThrown(err);
  const component = componentStack ? firstComponent(componentStack) : null;
  const detailParts = [described.stack ?? described.message];
  if (componentStack) detailParts.push(`\nComponent stack:${componentStack}`);
  recordAppError({
    source: "app",
    severity: "critical",
    timestamp: new Date().toISOString(),
    title: titleFor(described),
    detail: detailParts.join("\n"),
    origin: component ? `<${component}>` : "React render",
    dedupeKey: `render|${component ?? ""}|${errorKind(described.message)}`,
    meta: {
      window: windowLabel(),
      component: component ?? null,
      componentStack: componentStack ?? null,
    },
  });
}

function onWindowError(event: ErrorEvent): void {
  const thrown = event.error ?? event.message;
  // Resource-load failures reach window listeners only in the capture phase,
  // which this isn't - but guard anyway so a payload-less event can't create
  // an empty row.
  if (thrown === undefined || thrown === null || thrown === "") return;
  if (wasRecorded(thrown)) return;
  markRecorded(thrown);
  const described = describeThrown(thrown);
  const where = event.filename ? `${basename(event.filename)}:${event.lineno ?? 0}` : "window";
  recordAppError({
    source: "app",
    severity: "error",
    timestamp: new Date().toISOString(),
    title: titleFor(described),
    detail: described.stack ?? described.message,
    origin: where,
    dedupeKey: `uncaught|${where}|${errorKind(described.message)}`,
    meta: {
      window: windowLabel(),
      file: event.filename || null,
      line: event.lineno ?? null,
      column: event.colno ?? null,
    },
  });
}

function onUnhandledRejection(event: PromiseRejectionEvent): void {
  const reason = event.reason;
  // Already reported with better context (an RPC method name, a component) -
  // one fault, one row.
  if (wasRecorded(reason)) return;
  markRecorded(reason);
  const described = describeThrown(reason);
  recordAppError({
    source: "app",
    severity: "error",
    timestamp: new Date().toISOString(),
    title: titleFor(described),
    detail: described.stack ?? described.message,
    origin: "unhandled rejection",
    dedupeKey: `rejection|${errorKind(described.message)}`,
    meta: { window: windowLabel(), reasonType: reason instanceof Error ? reason.name : typeof reason },
  });
}

/**
 * Installs the window-level hooks. Idempotent - safe to call once at startup
 * (main.tsx) and harmless if it ever gets called again; listeners are only
 * ever attached on the first call.
 */
export function initErrorCapture(): void {
  if (installed) return;
  installed = true;
  if (typeof window === "undefined") return;
  window.addEventListener("error", onWindowError);
  window.addEventListener("unhandledrejection", onUnhandledRejection);
}
