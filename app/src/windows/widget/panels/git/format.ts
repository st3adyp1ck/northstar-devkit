/** Small formatters shared by the Git flyout's sections and detail view. */

const RELATIVE = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" });

const UNITS: [Intl.RelativeTimeFormatUnit, number][] = [
  ["year", 365 * 24 * 60 * 60 * 1000],
  ["month", 30 * 24 * 60 * 60 * 1000],
  ["day", 24 * 60 * 60 * 1000],
  ["hour", 60 * 60 * 1000],
  ["minute", 60 * 1000],
];

/** "3 days ago" from an ISO timestamp; null when it isn't parseable. */
export function relativeTime(iso: string | undefined | null): string | null {
  if (!iso) return null;
  const then = Date.parse(iso);
  if (!Number.isFinite(then)) return null;
  const delta = then - Date.now();
  for (const [unit, ms] of UNITS) {
    if (Math.abs(delta) >= ms) return RELATIVE.format(Math.round(delta / ms), unit);
  }
  return RELATIVE.format(Math.round(delta / 1000), "second");
}

/** Absolute local timestamp for the metadata grid; null when unparseable. */
export function absoluteTime(iso: string | undefined | null): string | null {
  if (!iso) return null;
  const parsed = new Date(iso);
  if (Number.isNaN(parsed.getTime())) return null;
  return parsed.toLocaleString(undefined, {
    year: "numeric",
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

/**
 * Splits "src/components/Foo.tsx" into its dimmed directory and its
 * emphasised file name. Git always reports POSIX separators, but a path
 * pasted from Windows can carry backslashes - handle both.
 */
export function splitPath(path: string): { dir: string; name: string } {
  const cut = Math.max(path.lastIndexOf("/"), path.lastIndexOf("\\"));
  if (cut < 0) return { dir: "", name: path };
  return { dir: path.slice(0, cut + 1), name: path.slice(cut + 1) };
}

export function plural(count: number, one: string, many = `${one}s`): string {
  return count === 1 ? one : many;
}

/** "github.com/owner/repo" from any remote URL form (https, ssh, git@). */
export function prettyRemote(remote: string | null | undefined): string | null {
  if (!remote) return null;
  const trimmed = remote.trim().replace(/\.git$/i, "");
  const ssh = /^git@([^:]+):(.+)$/.exec(trimmed);
  if (ssh) return `${ssh[1]}/${ssh[2]}`;
  const url = /^[a-z+]+:\/\/(?:[^@/]+@)?(.+)$/i.exec(trimmed);
  if (url) return url[1];
  return trimmed;
}
