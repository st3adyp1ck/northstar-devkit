import type { ErrorEntry, ErrorSeverity } from "../../stores/useErrorStore";

/** Milliseconds since epoch for an entry timestamp, or NaN if it's unparseable. */
export function entryTime(timestamp: string): number {
  return new Date(timestamp).getTime();
}

/** Newest first, with unparseable timestamps sinking to the bottom rather than throwing off the sort. */
export function byNewest(a: ErrorEntry, b: ErrorEntry): number {
  const at = entryTime(a.timestamp);
  const bt = entryTime(b.timestamp);
  if (Number.isNaN(at) && Number.isNaN(bt)) return 0;
  if (Number.isNaN(at)) return 1;
  if (Number.isNaN(bt)) return -1;
  return bt - at;
}

const MINUTE = 60_000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

/** "just now" / "12m ago" / "3h ago" / "2d ago" / a date once it's a week old. */
export function formatRelative(timestamp: string, now: number = Date.now()): string {
  const then = entryTime(timestamp);
  if (Number.isNaN(then)) return "unknown time";
  const delta = now - then;
  if (delta < 0) return "just now";
  if (delta < MINUTE) return "just now";
  if (delta < HOUR) return `${Math.floor(delta / MINUTE)}m ago`;
  if (delta < DAY) return `${Math.floor(delta / HOUR)}h ago`;
  if (delta < 7 * DAY) return `${Math.floor(delta / DAY)}d ago`;
  return new Date(then).toLocaleDateString();
}

/** Full local date + time for the detail view - the exact moment, not a rounded one. */
export function formatExact(timestamp: string): string {
  const then = entryTime(timestamp);
  if (Number.isNaN(then)) return timestamp;
  return new Date(then).toLocaleString(undefined, {
    year: "numeric",
    month: "short",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
}

export const SEVERITY_LABEL: Record<ErrorSeverity, string> = {
  critical: "Critical",
  error: "Error",
  warning: "Warning",
};

/** camelCase / PascalCase / snake_case meta key -> "Record id", "Provider name". */
export function humanizeKey(key: string): string {
  const spaced = key
    .replace(/[_-]+/g, " ")
    .replace(/([a-z0-9])([A-Z])/g, "$1 $2")
    .trim();
  if (!spaced) return key;
  return spaced.charAt(0).toUpperCase() + spaced.slice(1).toLowerCase();
}

/** Renders any meta value as one readable line (or block, for nested objects). */
export function formatMetaValue(value: unknown): string {
  if (value === null || value === undefined) return "—";
  if (typeof value === "string") return value;
  if (typeof value === "number" || typeof value === "boolean") return String(value);
  try {
    return JSON.stringify(value, null, 2);
  } catch {
    return String(value);
  }
}

/**
 * The whole entry as plain text, for the copy-to-clipboard button - shaped
 * to paste straight into an issue or a chat message.
 */
export function entryToText(entry: ErrorEntry): string {
  const lines: string[] = [];
  lines.push(`[${SEVERITY_LABEL[entry.severity].toUpperCase()}] ${entry.title}`);
  lines.push(`Source:      ${entry.source === "system" ? "Windows Event Log" : "DevKit"}`);
  lines.push(`When:        ${formatExact(entry.timestamp)}  (${entry.timestamp})`);
  if (entry.origin) lines.push(`Origin:      ${entry.origin}`);
  if (entry.count > 1) lines.push(`Occurrences: ${entry.count}`);
  const meta = entry.meta ? Object.entries(entry.meta) : [];
  if (meta.length > 0) {
    lines.push("");
    for (const [key, value] of meta) {
      lines.push(`${humanizeKey(key)}: ${formatMetaValue(value)}`);
    }
  }
  lines.push("");
  lines.push("---");
  lines.push(entry.detail);
  return lines.join("\n");
}
